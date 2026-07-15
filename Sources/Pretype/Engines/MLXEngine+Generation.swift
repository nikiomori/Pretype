import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

// MARK: - Generation core (KV-cache reuse, logit processors, token iteration)

extension MLXEngine {
    /// Mutated only inside `container.perform`, which serializes access.
    final class PromptCache: @unchecked Sendable {
        final class CacheEntry {
            let keyPrefix: [Int]
            var cache: [KVCache]
            var tokens: [Int]
            var lastUsed: Date

            init(keyPrefix: [Int], cache: [KVCache], tokens: [Int]) {
                self.keyPrefix = keyPrefix
                self.cache = cache
                self.tokens = tokens
                self.lastUsed = Date()
            }
        }

        private var entries: [CacheEntry] = []
        private let maxEntries = 4

        /// Finds the entry sharing the longest token prefix with `fullTokens` and
        /// **removes it from the pool**, handing ownership to the caller. The reuse
        /// path mutates the entry's KV cache in place (trim, then extend during
        /// decode), so it must never stay in `entries` aliasing those live cache
        /// objects: when the shared prefix is `16 ≤ common < 24`, the entry's
        /// 24-token `keyPrefix` differs from the new prompt's, so `update` would not
        /// evict it — leaving a stale entry pointing at a mutated cache, which a
        /// later match would trim against the wrong token count and silently corrupt.
        /// Taking it out up front means the caller re-inserts the correct state via
        /// `update`, or drops the entry entirely on a failed trim.
        func takeBestEntry(for fullTokens: [Int]) -> (entry: CacheEntry, common: Int)? {
            var bestIndex: Int?
            var bestCommon = 0

            for (index, entry) in entries.enumerated() {
                guard !entry.cache.isEmpty, canTrimPromptCache(entry.cache) else { continue }
                var common = 0
                let limit = min(entry.tokens.count, fullTokens.count)
                while common < limit, entry.tokens[common] == fullTokens[common] {
                    common += 1
                }
                if common >= 16, common > bestCommon {
                    bestCommon = common
                    bestIndex = index
                }
            }

            guard let bestIndex else { return nil }
            return (entries.remove(at: bestIndex), bestCommon)
        }

        func update(cache: [KVCache], tokens: [Int], forFullTokens fullTokens: [Int]) {
            let prefixLen = min(24, fullTokens.count)
            let prefix = Array(fullTokens.prefix(prefixLen))

            // Remove any existing entry with the exact same prefix
            entries.removeAll { $0.keyPrefix == prefix }

            // Add new entry
            let newEntry = CacheEntry(keyPrefix: prefix, cache: cache, tokens: tokens)
            entries.append(newEntry)

            // If we exceed capacity, sort by lastUsed and evict/clean the oldest
            if entries.count > maxEntries {
                entries.sort { $0.lastUsed < $1.lastUsed }
                let oldest = entries.removeFirst()
                oldest.cache = [] // Clear KV-cache values eagerly
            }
        }

        func clear() {
            for entry in entries {
                entry.cache = []
            }
            entries.removeAll()
        }
    }

    // MARK: Personalization (favored-word logit bias)

    /// Favored words + strength for one generation (built from the user's
    /// accepted-completion history in `currentBias()`).
    struct PersonalizationBias {
        let words: [String]
        let weight: Float
    }

    /// Builds a logit processor that keeps the parameters' penalties (repetition
    /// etc.) and adds a flat bias to the favored words' *start* tokens. Returns
    /// nil if nothing resolves to a token.
    private static func makeBiasProcessor(
        _ bias: PersonalizationBias, context: ModelContext, inner: LogitProcessor?
    ) -> LogitProcessor? {
        // encode() prepends BOS (e.g. " appreciate" → [2, 14756]); bias the first
        // real content token (the "▁word" start), never BOS.
        let bosID = context.tokenizer.convertTokenToId("<bos>")
        var ids = Set<Int>()
        for word in bias.words {
            let tokens = context.tokenizer.encode(text: " " + word)
            if let id = tokens.first(where: { $0 != bosID }) {
                ids.insert(id)
            }
        }
        guard !ids.isEmpty else { return nil }
        return PersonalizationProcessor(inner: inner, favored: Array(ids), weight: bias.weight)
    }

    /// Masks the EOS tokens for the first `minTokens` decode steps so the model
    /// can't end the turn immediately — needed for the "prefill" prompt format,
    /// where Gemma otherwise emits end_of_turn right after the prefilled text.
    private final class MinTokensProcessor: LogitProcessor {
        private var inner: LogitProcessor?
        private let eosIDs: [Int]
        private let minTokens: Int
        private var step = 0
        private var mask: MLXArray?

        init(inner: LogitProcessor?, eosIDs: [Int], minTokens: Int) {
            self.inner = inner
            self.eosIDs = eosIDs
            self.minTokens = minTokens
        }

        func prompt(_ prompt: MLXArray) { inner?.prompt(prompt) }

        func process(logits: MLXArray) -> MLXArray {
            var l = inner?.process(logits: logits) ?? logits
            if step < minTokens {
                if mask == nil {
                    let vocab = logits.shape.last ?? 0
                    var v = [Float](repeating: 0, count: vocab)
                    for id in eosIDs where id >= 0 && id < vocab { v[id] = -1e9 }
                    mask = MLXArray(v).reshaped([1, vocab])
                }
                if let mask { l = l + mask }
            }
            return l
        }

        func didSample(token: MLXArray) {
            step += 1
            inner?.didSample(token: token)
        }
    }

    /// Runs the default penalty processor, then adds a flat additive bias to the
    /// favored token ids. The dense bias vector is built lazily on the first
    /// step, once the vocab size is known.
    private final class PersonalizationProcessor: LogitProcessor {
        private var inner: LogitProcessor?
        private let favored: [Int]
        private let weight: Float
        private var bias: MLXArray?

        init(inner: LogitProcessor?, favored: [Int], weight: Float) {
            self.inner = inner
            self.favored = favored
            self.weight = weight
        }

        func prompt(_ prompt: MLXArray) { inner?.prompt(prompt) }

        func process(logits: MLXArray) -> MLXArray {
            let processed = inner?.process(logits: logits) ?? logits
            if bias == nil {
                let vocab = logits.shape.last ?? 0
                var values = [Float](repeating: 0, count: vocab)
                for id in favored where id >= 0 && id < vocab { values[id] = weight }
                bias = MLXArray(values).reshaped([1, vocab])
            }
            guard let bias else { return processed }
            return processed + bias
        }

        func didSample(token: MLXArray) { inner?.didSample(token: token) }
    }

    // MARK: First-word confidence (live decode-loop capture)

    /// Records, for every sampled token, the (processed) logits it was sampled
    /// from — the raw material for the journal's `firstWordLogProb`. Costs no
    /// extra forward passes and, crucially, no per-step GPU sync: it only
    /// RETAINS the lazy logits arrays ([1, vocab] each, ≈0.5 MB fp16 × ≤~40
    /// steps) and defers all scalar extraction to `finish()`, after the decode
    /// loop, so the iterator's asyncEval pipelining is untouched.
    /// Created and consumed entirely inside `container.perform` (not Sendable,
    /// like the other processors here).
    final class LogProbRecorder: LogitProcessor {
        private var inner: LogitProcessor?
        private var last: MLXArray?
        private var steps: [(logits: MLXArray, token: MLXArray)] = []

        init(inner: LogitProcessor?) { self.inner = inner }

        func prompt(_ prompt: MLXArray) { inner?.prompt(prompt) }

        func process(logits: MLXArray) -> MLXArray {
            let processed = inner?.process(logits: logits) ?? logits
            last = processed
            return processed
        }

        func didSample(token: MLXArray) {
            if let logits = last { steps.append((logits, token)) }
            inner?.didSample(token: token)
        }

        /// Per-step log P(sampled token) under the recorded (processed) logits,
        /// index-aligned with the tokens the iterator returned. Call once, after
        /// the decode loop.
        func finish() -> [Float] {
            steps.map { step in
                let row = step.logits.reshaped([-1])   // [vocab]
                let id = step.token.reshaped([-1]).item(Int.self)
                return row[id].item(Float.self) - row.logSumExp().item(Float.self)
            }
        }
    }

    /// How many leading tokens of `textTokens` make up the first word: the
    /// smallest prefix whose decoded text, after any leading separators,
    /// already contains an in-word boundary (same non-alphanumeric convention
    /// as `gateFirstWord`, so calibration matches the gate's unit). Falls back
    /// to all tokens when the whole suggestion is a single word. Approximation:
    /// the boundary token itself is included in the mean — one separator token
    /// of overshoot at most.
    static func firstWordTokenCount(textTokens: [Int], tokenizer: MLXLMCommon.Tokenizer) -> Int {
        guard !textTokens.isEmpty else { return 0 }
        for k in 1 ..< textTokens.count {
            let decoded = tokenizer.decode(tokenIds: Array(textTokens.prefix(k)), skipSpecialTokens: true)
            let core = decoded.drop { !$0.isLetter && !$0.isNumber }
            guard !core.isEmpty else { continue }
            if core.contains(where: { !$0.isLetter && !$0.isNumber }) { return k }
        }
        return textTokens.count
    }

    /// Confidence trim: the decoded prefix cut just before the first token at
    /// or after the first word whose logprob falls below `threshold` — the
    /// tail of a fixed-budget completion is its weakest part, so showing only
    /// the confident prefix raises precision at zero extra decode cost, and
    /// (unlike the gates) it never abstains: the first word always survives.
    /// When the weak token would have CONTINUED a word, the stranded head of
    /// that word is dropped too. Returns nil when nothing needs trimming.
    /// `decode` abstracts the tokenizer so the boundary logic is testable.
    static func confidenceTrimmed(
        text: String, textTokens: [Int], perToken: [Float],
        firstWordTokens: Int, threshold: Float,
        decode: ([Int]) -> String
    ) -> String? {
        let n = min(textTokens.count, perToken.count)
        let start = min(max(firstWordTokens, 1), n)
        guard let cut = (start..<n).first(where: { perToken[$0] < threshold }) else { return nil }
        var kept = decode(Array(textTokens.prefix(cut)))
        func isWordChar(_ c: Character?) -> Bool { c.map { $0.isLetter || $0.isNumber } ?? false }
        if isWordChar(kept.last), isWordChar(decode([textTokens[cut]]).first) {
            while isWordChar(kept.last) { kept.removeLast() }
        }
        while kept.last?.isWhitespace == true { kept.removeLast() }
        return kept.isEmpty || kept.count >= text.count ? nil : kept
    }

    // MARK: Token iteration

    /// Wraps a partial-text callback so each raw decode snapshot is run through
    /// the same output `gate` as the final result, empty/rejected snapshots are
    /// dropped, and only *changed* gated text is forwarded — so the UI updates
    /// per new word, not per subword token. Returns nil when not streaming.
    static func makeStreamHandler(
        _ onPartial: (@Sendable (String) -> Void)?,
        gate: @escaping @Sendable (String) -> String?
    ) -> (@Sendable (String) -> Void)? {
        guard let onPartial else { return nil }
        let last = LockedValue<String?>(nil)
        return { raw in
            guard let gated = gate(raw), !gated.isEmpty else { return }
            if last.exchange(gated) != gated { onPartial(gated) }
        }
    }

    /// Raw continuation: encode the text directly, bypassing the chat
    /// template — the model just continues what's on screen.
    static func generate(
        in container: ModelContainer,
        prompt: String,
        parameters: GenerateParameters,
        extraEOSTokens: Set<String>,
        promptCache: PromptCache?,
        bias: PersonalizationBias? = nil,
        minTokens: Int = 0,
        logProbSink: LockedValue<Double?>? = nil,
        firstWordStats: LockedValue<(sum: Double, mean: Double)?>? = nil,
        forcedFirst: (token: Int, logProb: Float)? = nil,
        trimLogProb: Float? = nil,
        onPartial: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        try await generate(
            in: container,
            makeTokens: { context in context.tokenizer.encode(text: prompt) },
            parameters: parameters,
            extraEOSTokens: extraEOSTokens,
            promptCache: promptCache,
            bias: bias,
            minTokens: minTokens,
            logProbSink: logProbSink,
            firstWordStats: firstWordStats,
            forcedFirst: forcedFirst,
            trimLogProb: trimLogProb,
            onPartial: onPartial
        )
    }

    static func generate(
        in container: ModelContainer,
        makeTokens: @Sendable @escaping (ModelContext) throws -> [Int],
        parameters: GenerateParameters,
        extraEOSTokens: Set<String>,
        promptCache: PromptCache?,
        bias: PersonalizationBias? = nil,
        minTokens: Int = 0,
        logProbSink: LockedValue<Double?>? = nil,
        firstWordStats: LockedValue<(sum: Double, mean: Double)?>? = nil,
        forcedFirst: (token: Int, logProb: Float)? = nil,
        trimLogProb: Float? = nil,
        onPartial: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        // Annotate the param: under `-enable-testing` (swift test) overload
        // resolution otherwise prefers the deprecated 2-arg `(LanguageModel,
        // Tokenizer)` perform (its sync closure matches our sync body more
        // tightly than the ModelContext overload's `async`), which then fails.
        try await container.perform { (context: ModelContext) in
            let maxTokens = parameters.maxTokens ?? 16
            // Beam branch: the forced candidate rides in as the last PROMPT
            // token (prefilled, not decoded) but is part of the visible text —
            // textTokens is seeded with it and its logprob is prepended to the
            // recorder's, so first-word scoring covers the whole word.
            var fullTokens = try makeTokens(context)
            if let forcedFirst { fullTokens.append(forcedFirst.token) }
            guard !fullTokens.isEmpty else { return "" }

            var eosIDs = Set<Int>()
            if let eos = context.tokenizer.eosToken,
               let id = context.tokenizer.convertTokenToId(eos) {
                eosIDs.insert(id)
            }
            for token in extraEOSTokens {
                if let id = context.tokenizer.convertTokenToId(token) {
                    eosIDs.insert(id)
                }
            }

            // Reuse the KV cache ONLY for true incremental typing: a
            // substantial shared prefix with a small new tail. Tiny or
            // divergent prefixes (field/app switches) get a fresh prefill —
            // cheap for short prompts and immune to trim edge cases.
            var cache: [KVCache]
            var inputTokens: [Int]
            var reused = false
            if let pc = promptCache, let match = pc.takeBestEntry(for: fullTokens) {
                // The iterator needs at least one input token.
                let common = min(match.common, fullTokens.count - 1)
                let tail = fullTokens.count - common
                if common >= 16, tail <= 32 {
                    let toTrim = match.entry.tokens.count - common
                    if trimPromptCache(match.entry.cache, numTokens: toTrim) == toTrim {
                        cache = match.entry.cache
                        inputTokens = Array(fullTokens[common...])
                        reused = true
                    } else {
                        cache = context.model.newCache(parameters: parameters)
                        inputTokens = fullTokens
                    }
                } else {
                    cache = context.model.newCache(parameters: parameters)
                    inputTokens = fullTokens
                }
            } else {
                cache = context.model.newCache(parameters: parameters)
                inputTokens = fullTokens
            }

            let prefillStart = Date()
            let lmInput = LMInput(tokens: MLXArray(inputTokens))
            // Compose the logit-processor chain: penalties → favored-word bias →
            // min-token EOS mask. Only take the custom path when something was
            // added; otherwise the plain parameters init (unchanged behaviour).
            var processor: LogitProcessor? = parameters.processor()
            var customized = false
            if let bias, let biased = makeBiasProcessor(bias, context: context, inner: processor) {
                processor = biased
                customized = true
            }
            if minTokens > 0, !eosIDs.isEmpty {
                processor = MinTokensProcessor(inner: processor, eosIDs: Array(eosIDs), minTokens: minTokens)
                customized = true
            }
            // Outermost, so it sees the logits the sampler actually samples from
            // (post-penalties, post-bias, post-EOS-mask) — that distribution is
            // what "the engine's confidence in what it showed" means.
            var recorder: LogProbRecorder?
            if logProbSink != nil || trimLogProb != nil || firstWordStats != nil {
                let r = LogProbRecorder(inner: processor)
                processor = r
                recorder = r
                customized = true
            }
            var iterator: TokenIterator
            if customized {
                iterator = try TokenIterator(
                    input: lmInput, model: context.model, cache: cache,
                    processor: processor, sampler: parameters.sampler(),
                    prefillStepSize: parameters.prefillStepSize, maxTokens: parameters.maxTokens
                )
            } else {
                iterator = try TokenIterator(
                    input: lmInput, model: context.model, cache: cache, parameters: parameters
                )
            }
            let prefillSeconds = Date().timeIntervalSince(prefillStart)

            // `fed` mirrors exactly what entered the cache (incl. a final EOS),
            // keeping the trim arithmetic exact on the next request.
            let decodeStart = Date()
            var fed: [Int] = []
            var textTokens: [Int] = forcedFirst.map { [$0.token] } ?? []
            // Seed the text too: an immediate EOS after a forced token must
            // still return that token's text, not "".
            var text = textTokens.isEmpty ? "" : context.tokenizer.decode(tokenIds: textTokens, skipSpecialTokens: true)
            while fed.count < maxTokens, let token = iterator.next() {
                fed.append(token)
                if Task.isCancelled || eosIDs.contains(token) { break }
                textTokens.append(token)
                text = context.tokenizer.decode(tokenIds: textTokens, skipSpecialTokens: true)
                onPartial?(text)
                if text.contains("\n") { break }
            }
            let decodeSeconds = Date().timeIntervalSince(decodeStart)

            // Reduce the recorded per-step log-probs to the first-word mean.
            // `fed` and the recorder's steps are index-aligned (one didSample per
            // next()), and textTokens is a prefix of fed (EOS breaks before
            // appending) — so entries 0..<textTokens.count score exactly the
            // visible text. A forced first token was prefilled, not decoded:
            // prepend its logprob to realign (raw scale vs the recorder's
            // post-processor scale — identical unless penalties/bias are on).
            if let recorder {
                var perToken = recorder.finish()
                if let forcedFirst { perToken.insert(forcedFirst.logProb, at: 0) }
                let firstWord = firstWordTokenCount(textTokens: textTokens, tokenizer: context.tokenizer)
                let n = min(firstWord, perToken.count)
                let firstWordSum = perToken.prefix(n).reduce(0.0) { $0 + Double($1) }
                if let logProbSink {
                    logProbSink.set(n > 0 ? firstWordSum / Double(n) : nil)
                }
                // Beam scoring: sum = log P(first word | ctx) — comparable
                // across candidate words; mean is the gate's calibrated scale.
                if let firstWordStats {
                    firstWordStats.set(n > 0 ? (sum: firstWordSum, mean: firstWordSum / Double(n)) : nil)
                }
                // Confidence trim: show only the prefix before the first weak
                // token. Display-only — `fed` (and thus the KV cache) is untouched.
                if let threshold = trimLogProb,
                   let trimmed = confidenceTrimmed(
                       text: text, textTokens: textTokens, perToken: perToken,
                       firstWordTokens: firstWord, threshold: threshold,
                       decode: { context.tokenizer.decode(tokenIds: $0, skipSpecialTokens: true) }
                   ) {
                    DebugLog.shared.log(
                        "GATE",
                        String(format: "confidence-trim: weak tail below %.2f", threshold),
                        detail: "kept \(trimmed.debugDescription) of \(text.debugDescription)"
                    )
                    text = trimmed
                }
            }

            if let pc = promptCache {
                pc.update(cache: cache, tokens: fullTokens + fed, forFullTokens: fullTokens)
            }
            let prefillRate = prefillSeconds > 0 ? Double(inputTokens.count) / prefillSeconds : 0
            let decodeRate = decodeSeconds > 0 ? Double(fed.count) / decodeSeconds : 0
            let summary = String(
                format: "reused=%@ prefill=%dtok/%.0fms (%.0f tok/s) decode=%dtok/%.0fms (%.0f tok/s)",
                String(reused), inputTokens.count, prefillSeconds * 1000, prefillRate,
                fed.count, decodeSeconds * 1000, decodeRate
            )
            DebugLog.shared.log("GEN", summary, detail: "raw: \(text.debugDescription)")
            if Self.debugLogging.get() {
                print("[gen] \(summary) raw=\(text.debugDescription)")
            }
            return text
        }
    }

    // MARK: Log-probability scoring (offline: model ranking + gate calibration)

    /// Total log P(`continuation` | `context`) + scored-token count from a SINGLE
    /// causal forward pass — no decoding, so it's blind to paraphrase ("обязательно
    /// отвечу" vs "отвечу вам") the way exact-match isn't. Callers normalize:
    /// per-TOKEN is the gate-calibration scale (τ thresholds are defined on it),
    /// but it is confounded by tokenizer fertility across languages and model
    /// families (RU tokenizes ~2× denser than EN, MiniCPM's tokenizer ≠ Gemma's) —
    /// rank models/languages per-CHAR instead (`refLogProb`).
    ///
    /// One forward over [ctx+cont] with `cache: nil`: `createAttentionMask` is
    /// `.causal` for n>1, so position i attends only to ≤i — no answer leakage.
    /// Context is capped to a tail so the [1, L, vocab] logits stay bounded
    /// (L·262k floats materialized once, then reduced to scalars).
    static func logProbScore(in container: ModelContainer,
                             continuation: String, context: String) async -> (total: Double, tokens: Int)? {
        guard !continuation.isEmpty else { return nil }
        let ctxTail = String(context.suffix(600))  // ponytail: bound logits RAM; plenty of conditioning for a ranker
        return await container.perform { (ctx: ModelContext) in  // typed param — see `generate`'s note (swift test overload resolution)
            let ctxTokens = ctx.tokenizer.encode(text: ctxTail)
            let allTokens = ctx.tokenizer.encode(text: ctxTail + continuation)
            // Longest shared prefix — a boundary merge just shifts one token into
            // the scored span, still a valid P(text after the ctx prefix).
            var start = 0
            let lim = min(ctxTokens.count, allTokens.count)
            while start < lim, ctxTokens[start] == allTokens[start] { start += 1 }
            guard start >= 1, allTokens.count > start else { return nil }  // need ≥1 conditioning + ≥1 scored token
            let logits = ctx.model(MLXArray(allTokens, [1, allTokens.count]), cache: nil)
            eval(logits)  // materialize before pulling scalars (MLXArray must not escape `perform`)
            var total: Float = 0
            let n = allTokens.count - start
            for k in 0 ..< n {
                let row = logits[0, start - 1 + k]  // [vocab]: the position predicting allTokens[start+k]
                total += row[allTokens[start + k]].item(Float.self) - row.logSumExp().item(Float.self)
            }
            return (total: Double(total), tokens: n)
        }
    }

    /// Rank (0 = the model's top-1) of the FIRST token of `continuation` in the
    /// distribution at the end of `context` — one forward pass. Feeds top-k
    /// recall: how often the true continuation's first token sits in the model's
    /// top-k even when it isn't top-1. top-5 ≫ top-1 ⇒ the model "knows" the
    /// answer but mis-ranks it (selection/reranking headroom); top-5 ≈ top-1 ⇒ a
    /// genuine information gap (go to context/personalization).
    static func firstTokenRank(in container: ModelContainer,
                               continuation: String, context: String) async -> Int? {
        guard !continuation.isEmpty else { return nil }
        let ctxTail = String(context.suffix(600))
        return await container.perform { (ctx: ModelContext) in
            let ctxTokens = ctx.tokenizer.encode(text: ctxTail)
            let allTokens = ctx.tokenizer.encode(text: ctxTail + continuation)
            var start = 0
            let lim = min(ctxTokens.count, allTokens.count)
            while start < lim, ctxTokens[start] == allTokens[start] { start += 1 }
            guard start >= 1, allTokens.count > start else { return nil }
            let logits = ctx.model(MLXArray(allTokens, [1, allTokens.count]), cache: nil)
            let row = logits[0, start - 1]        // [vocab]: predicts allTokens[start]
            let target = row[allTokens[start]]    // its logit
            // rank = number of tokens strictly more likely than the true one.
            return (row .> target).sum().item(Int.self)
        }
    }

    // MARK: First-word beam rerank (PRETYPE_BEAM)

    /// Top-k first-token candidates at the end of `prompt` — one raw forward
    /// pass (the decode-time processors — penalties, personalization bias —
    /// don't apply here, same scale caveat as `logProbScore`). EOS, special and
    /// newline-bearing tokens are skipped: a branch must start visible text.
    /// Best-first.
    static func topFirstTokens(in container: ModelContainer, prompt: String, k: Int,
                               extraEOSTokens: Set<String>) async -> [(token: Int, logProb: Float)] {
        await container.perform { (ctx: ModelContext) in
            let tokens = ctx.tokenizer.encode(text: prompt)
            guard !tokens.isEmpty else { return [] }
            var eosIDs = Set<Int>()
            if let eos = ctx.tokenizer.eosToken, let id = ctx.tokenizer.convertTokenToId(eos) {
                eosIDs.insert(id)
            }
            for token in extraEOSTokens {
                if let id = ctx.tokenizer.convertTokenToId(token) { eosIDs.insert(id) }
            }
            let logits = ctx.model(MLXArray(tokens, [1, tokens.count]), cache: nil)
            let row = logits[0, tokens.count - 1]
            let logProbs = row - row.logSumExp()
            eval(logProbs)
            // argSort is ascending; walk the tail (most likely first). The +8
            // headroom absorbs skipped EOS/special/newline candidates.
            let order = argSort(logProbs, axis: -1).asArray(Int32.self)
            var out: [(token: Int, logProb: Float)] = []
            for id32 in order.suffix(k + 8).reversed() {
                let id = Int(id32)
                guard !eosIDs.contains(id) else { continue }
                let piece = ctx.tokenizer.decode(tokenIds: [id], skipSpecialTokens: true)
                guard !piece.isEmpty, !piece.contains("\n") else { continue }
                out.append((token: id, logProb: logProbs[id].item(Float.self)))
                if out.count == k { break }
            }
            return out
        }
    }

    /// First-word beam rerank: decode one short branch per top-k first token
    /// and return the branch whose first WORD the model believes most, plus an
    /// optional personal-ngram boost (the fusion lever: "the user has typed
    /// this word here before").
    ///
    /// `scoreByMean` picks the branch statistic. Both cover the first word PLUS
    /// its boundary token (`firstWordTokenCount`'s one-token overshoot), so
    /// sum = log P(word · next-token-start) — a 1-step lookahead, length-biased
    /// against multi-token words; mean is the τ-gate's calibrated scale
    /// (measured monotone in correctness), length-normalized. Which ranks
    /// better is an empirical knob: sweep on the even half, verify on odd.
    ///
    /// Cost: one candidate forward + k short decodes; branches after the first
    /// reuse the shared prompt KV via `promptCache` (common=prompt, tail=1 —
    /// the incremental-typing path), so prompts ≥16 tokens prefill once.
    /// No streaming — the winner only exists after the last branch. The output
    /// gate runs on the winner only; a gated-out winner abstains even if a
    /// runner-up would have passed (rare, accepted).
    static func beamGenerate(
        in container: ModelContainer, prompt: String, k: Int,
        parameters: GenerateParameters, extraEOSTokens: Set<String>,
        promptCache: PromptCache?, bias: PersonalizationBias? = nil,
        logProbSink: LockedValue<Double?>? = nil, trimLogProb: Float? = nil,
        scoreByMean: Bool = true,
        ngramBoost: (@Sendable (String) -> Double)? = nil
    ) async throws -> String {
        let candidates = await topFirstTokens(
            in: container, prompt: prompt, k: k, extraEOSTokens: extraEOSTokens)
        guard candidates.count > 1 else {
            return try await generate(
                in: container, prompt: prompt, parameters: parameters,
                extraEOSTokens: extraEOSTokens, promptCache: promptCache,
                bias: bias, logProbSink: logProbSink, trimLogProb: trimLogProb)
        }
        var best: (score: Double, text: String, mean: Double)?
        for candidate in candidates {
            try Task.checkCancellation()
            let stats = LockedValue<(sum: Double, mean: Double)?>(nil)
            let text = try await generate(
                in: container, prompt: prompt, parameters: parameters,
                extraEOSTokens: extraEOSTokens, promptCache: promptCache,
                bias: bias, firstWordStats: stats, forcedFirst: candidate,
                trimLogProb: trimLogProb)
            guard let stat = stats.get(), !text.isEmpty else { continue }
            // Same fold as gateFirstWord (private to the other file).
            let word = text.lowercased().replacingOccurrences(of: "ё", with: "е")
                .split { !$0.isLetter && !$0.isNumber }.first.map(String.init) ?? ""
            let score = (scoreByMean ? stat.mean : stat.sum)
                + (word.isEmpty ? 0 : (ngramBoost?(word) ?? 0))
            if score > (best?.score ?? -.infinity) { best = (score, text, stat.mean) }
        }
        // Publish the winner's first-word mean — the gate/journal scale.
        logProbSink?.set(best?.mean)
        return best?.text ?? ""
    }
}
