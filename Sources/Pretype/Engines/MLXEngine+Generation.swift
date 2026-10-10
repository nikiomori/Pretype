import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

// MARK: - Generation core (KV-cache reuse, logit processors, token iteration)

extension MLXEngine {
    /// KV states reused between keystrokes. Two kinds per prompt:
    /// - `live` — the cache as decode left it (prompt + generated tokens).
    ///   Reusable only by TRIMMING back to the shared prefix, so only kept when
    ///   every layer's cache can trim.
    /// - `checkpoint` — a copy taken a few tokens before the prompt's end.
    ///   Reusable whenever the next prompt starts with exactly those tokens,
    ///   with NO trim — the only reuse a recurrent state (Qwen3.5's
    ///   gated-delta layers: `MambaCache` can't rewind) or a wrapped
    ///   sliding-window ring (Gemma past 512 tokens) admits. Without it both
    ///   re-prefilled the whole prompt on every keystroke (measured: Qwen3.5
    ///   reused 0% of keystrokes).
    /// Mutated only inside `container.perform`, which serializes access.
    final class PromptCache: @unchecked Sendable {
        /// A KV state covering exactly `tokens`.
        struct Snapshot {
            let tokens: [Int]
            let cache: [KVCache]
        }

        final class CacheEntry {
            let keyPrefix: [Int]
            let live: Snapshot?
            let checkpoint: Snapshot?
            let lastUsed = Date()

            init(keyPrefix: [Int], live: Snapshot?, checkpoint: Snapshot?) {
                self.keyPrefix = keyPrefix
                self.live = live
                self.checkpoint = checkpoint
            }
        }

        private var entries: [CacheEntry] = []
        private let maxEntries = 4

        /// The state sharing the longest usable prefix with `fullTokens`, with its
        /// entry **removed from the pool** — the caller owns (and mutates) the
        /// returned cache and re-inserts fresh states via `store`. A live cache is
        /// handed over itself (trimmed in place); a checkpoint only as a COPY, and
        /// the checkpoint comes back as `checkpoint` (when still a prefix of this
        /// prompt) for the caller to re-store — one checkpoint serves keystroke
        /// after keystroke. `reused` is how many leading tokens the returned cache
        /// holds (≤ count−1: the decode needs an input token). nil = nothing
        /// worth reusing.
        func take(for fullTokens: [Int]) -> (cache: [KVCache], reused: Int, checkpoint: Snapshot?)? {
            func common(_ snap: Snapshot) -> Int {
                var common = 0
                let limit = min(snap.tokens.count, fullTokens.count - 1)
                while common < limit, snap.tokens[common] == fullTokens[common] { common += 1 }
                return common
            }
            var best: (index: Int, snap: Snapshot, usable: Int, isLive: Bool)?
            for (index, entry) in entries.enumerated() {
                for (snap, isLive) in [(entry.live, true), (entry.checkpoint, false)] {
                    guard let snap, !snap.cache.isEmpty else { continue }
                    let usable = common(snap)
                    // Exact prefix: usable as-is by any cache type. Otherwise
                    // the cache must trim back to the shared prefix.
                    let exact = usable == snap.tokens.count
                    guard usable >= 16, exact || canTrimPromptCache(snap.cache) else { continue }
                    if usable > (best?.usable ?? 0) { best = (index, snap, usable, isLive) }
                }
            }
            guard let best else { return nil }
            let entry = entries.remove(at: best.index)
            let kept = entry.checkpoint.flatMap { common($0) == $0.tokens.count ? $0 : nil }
            let cache = best.isLive ? best.snap.cache : best.snap.cache.map { $0.copy() }
            let toTrim = best.snap.tokens.count - best.usable
            guard toTrim == 0 || trimPromptCache(cache, numTokens: toTrim) == toTrim else { return nil }
            return (cache, best.usable, kept)
        }

        func store(forFullTokens fullTokens: [Int], live: Snapshot?, checkpoint: Snapshot?) {
            guard live != nil || checkpoint != nil else { return }
            let prefix = Array(fullTokens.prefix(24))
            entries.removeAll { $0.keyPrefix == prefix }
            entries.append(CacheEntry(keyPrefix: prefix, live: live, checkpoint: checkpoint))
            if entries.count > maxEntries {
                entries.sort { $0.lastUsed < $1.lastUsed }
                entries.removeFirst()
            }
        }

        func clear() {
            entries.removeAll()
            encoder = PromptEncoder()
            templateSplice = TemplateSplice()
        }

        /// Raw-prompt tokenizer state; lives here because the cache is already
        /// the per-engine, `perform`-serialized home for keystroke-to-keystroke state.
        private(set) var encoder = PromptEncoder()
        /// Instruct-path counterpart of `encoder`.
        private(set) var templateSplice = TemplateSplice()
    }

    /// Re-tokenizes only the part of a raw prompt that changed. Consecutive
    /// keystroke prompts share all but their tail, yet a full encode re-ran
    /// BPE over the whole ~2.5k-char prompt each time (measured 9.5 ms on
    /// Qwen3.5, 2.6 ms on Gemma, per keystroke). Splits at a "safe junction" —
    /// a space between a non-space and a letter — where the pre-tokenizer
    /// boundary makes tokens(head) + tokens(tail) == tokens(head + tail)
    /// (0 mismatches over 5,530 junctions × 3 tokenizers × 17 languages). The
    /// first few splices are still checked against a full encode; one mismatch
    /// (an unvetted tokenizer, e.g. a fine-tune) switches this encoder to full
    /// encodes for good.
    final class PromptEncoder {
        private var anchor = ""
        private var anchorTokens: [Int] = []
        private var verified = 0
        private var disabled = false

        /// `addSpecialTokens: false` encodes a span that sits inside a larger
        /// prompt (the chat-template body), so no BOS lands mid-sequence.
        func encode(_ text: String, with tokenizer: MLXLMCommon.Tokenizer,
                    addSpecialTokens: Bool = true) -> [Int] {
            if !disabled, !anchor.isEmpty, text.hasPrefix(anchor) {
                let tail = text.dropFirst(anchor.count)
                // The junction must still be one in THIS text, and a long tail
                // means it's time to move the anchor forward.
                if tail.count <= 400, tail.first == " ", tail.dropFirst().first?.isLetter == true {
                    let tokens = anchorTokens + tokenizer.encode(text: String(tail), addSpecialTokens: false)
                    guard verified < 8 else { return tokens }
                    let full = tokenizer.encode(text: text, addSpecialTokens: addSpecialTokens)
                    if full == tokens { verified += 1 } else { disabled = true }
                    return full
                }
            }
            let full = tokenizer.encode(text: text, addSpecialTokens: addSpecialTokens)
            guard !disabled, let junction = Self.junction(in: text, atOrBefore: text.count - 64) else { return full }
            anchor = String(text.prefix(junction))
            anchorTokens = tokenizer.encode(text: anchor, addSpecialTokens: addSpecialTokens)
            return full
        }

        /// The last offset ≤ `limit` holding a space preceded by a non-space
        /// and followed by a letter.
        static func junction(in text: String, atOrBefore limit: Int) -> Int? {
            guard limit > 0 else { return nil }
            let chars = Array(text.prefix(limit + 2))
            var j = min(limit, chars.count - 2)
            while j >= 1 {
                if chars[j] == " ", !chars[j - 1].isWhitespace, chars[j + 1].isLetter { return j }
                j -= 1
            }
            return nil
        }
    }

    /// Prompt tokens a checkpoint sits before the prompt's end. Typing changes
    /// the tail: a char re-merges the trailing BPE token(s) of the word being
    /// typed, a backspace deletes them — a checkpoint this far back survives
    /// both, at the price of re-prefilling ~this many tokens per keystroke
    /// (one batched forward, ≈ one decode step on a memory-bound GPU).
    static let checkpointMargin = 8

    /// Prompt tokens per prefill forward. MLX's generic 512 doubled the
    /// transient memory spike over the resident model (+546 → +337 MB on
    /// E4B-8bit, +494 → +241 MB on E2B-4bit for a 460-token cold prompt) for
    /// no speed gain — and on an 8–16 GB Mac that spike is what trips the
    /// memory-pressure unload. 128 halves it again but costs E2B ~25 ms.
    static let prefillChunk = 256

    /// The instruct path's per-keystroke tokenization without re-rendering the
    /// chat template: the rendered prompt is head + body(text) + tail, where
    /// only the text changes between keystrokes (directive, persona and turn
    /// markers hold still). The split is learned from one full render — the
    /// body's own tokens located inside it — and the body goes through the
    /// incremental `PromptEncoder`. Render + full encode measured ~2 ms per
    /// keystroke (Gemma-it, Qwen3.5); the first splices are checked against a
    /// full render and one mismatch falls back to rendering for good.
    final class TemplateSplice {
        private var key = ""
        private var head: [Int] = []
        private var tail: [Int] = []
        private let body = PromptEncoder()
        private var verified = 0
        private var disabled = false

        /// `key` identifies everything around the text (the directive); `render`
        /// is the full chat-template path, the ground truth.
        func tokens(key: String, text: String, tokenizer: MLXLMCommon.Tokenizer,
                    render: () throws -> [Int]) rethrows -> [Int] {
            if !disabled, key == self.key, !head.isEmpty {
                let spliced = head + body.encode(text, with: tokenizer, addSpecialTokens: false) + tail
                guard verified < 8 else { return spliced }
                let full = try render()
                if full == spliced { verified += 1 } else { disabled = true }
                return full
            }
            let full = try render()
            guard !disabled else { return full }
            let bodyTokens = body.encode(text, with: tokenizer, addSpecialTokens: false)
            // The text closes the user turn, so its tokens sit just before the
            // short turn-marker tail: search back from the end.
            self.key = ""
            guard !bodyTokens.isEmpty, full.count > bodyTokens.count else { return full }
            let latest = full.count - bodyTokens.count
            for start in stride(from: latest, through: max(0, latest - 32), by: -1)
            where full[start ..< start + bodyTokens.count].elementsEqual(bodyTokens) {
                head = Array(full[..<start])
                tail = Array(full[(start + bodyTokens.count)...])
                self.key = key
                return full
            }
            // The text doesn't tokenize standalone the way it does in place
            // (a merge across the template boundary): never splice here.
            disabled = true
            return full
        }
    }

    // MARK: Personalization (n-gram first-token boost)

    /// Personal next-word candidates → additive logit boost, for one generation
    /// (built from the n-gram evidence after the current context in `ngramBias`).
    struct PersonalizationBias {
        let weights: [String: Float]
    }

    /// Builds a logit processor that keeps the parameters' penalties (repetition
    /// etc.) and boosts each candidate word's *start* token on the FIRST decode
    /// step only — the step that picks the next word; later steps just spell it.
    /// Returns nil if nothing resolves to a token.
    private static func makeBiasProcessor(
        _ bias: PersonalizationBias, context: ModelContext, inner: LogitProcessor?
    ) -> LogitProcessor? {
        // encode() prepends BOS (e.g. " appreciate" → [2, 14756]); bias the first
        // real content token (the "▁word" start), never BOS. Related surface
        // forms sharing a start token keep the max boost, not the sum.
        let bosID = context.tokenizer.convertTokenToId("<bos>")
        var boosts: [Int: Float] = [:]
        for (word, weight) in bias.weights {
            let tokens = context.tokenizer.encode(text: " " + word)
            if let id = tokens.first(where: { $0 != bosID }) {
                boosts[id] = max(boosts[id] ?? 0, weight)
            }
        }
        guard !boosts.isEmpty else { return nil }
        return PersonalizationProcessor(inner: inner, boosts: boosts)
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
                if let mask { l += mask }
            }
            return l
        }

        func didSample(token: MLXArray) {
            step += 1
            inner?.didSample(token: token)
        }
    }

    /// Runs the default penalty processor, then adds the per-token boosts to
    /// the first decode step's logits; later steps pass through untouched.
    private final class PersonalizationProcessor: LogitProcessor {
        private var inner: LogitProcessor?
        private let boosts: [Int: Float]
        private var step = 0

        init(inner: LogitProcessor?, boosts: [Int: Float]) {
            self.inner = inner
            self.boosts = boosts
        }

        func prompt(_ prompt: MLXArray) { inner?.prompt(prompt) }

        func process(logits: MLXArray) -> MLXArray {
            let processed = inner?.process(logits: logits) ?? logits
            guard step == 0 else { return processed }
            // Scatter the ≤32 boosts on the GPU — a vocab-sized host array
            // (262k floats for Gemma) per keystroke was pure overhead.
            let vocab = logits.shape.last ?? 0
            let valid = boosts.filter { $0.key >= 0 && $0.key < vocab }
            guard !valid.isEmpty else { return processed }
            let delta = MLXArray.zeros(processed.shape, dtype: processed.dtype)
            delta[0..., MLXArray(valid.map { Int32($0.key) })] = MLXArray(valid.map { $0.value }).asType(processed.dtype)
            return processed + delta
        }

        func didSample(token: MLXArray) {
            step += 1
            inner?.didSample(token: token)
        }
    }

    // MARK: First-word confidence (live decode-loop capture)

    /// Records, for every sampled token, log P(token) under the (processed)
    /// logits it was sampled from — the raw material for the journal's
    /// `firstWordLogProb`, the logprob gate and the confidence trim. No extra
    /// forward passes and no extra GPU sync: each step's value is a LAZY scalar
    /// built next to the sampled token, which the decode loop evaluates in the
    /// same `asyncEval` as the token — so it is already materialized when the
    /// token is, and the loop can act on it (early stop) without stalling the
    /// pipeline. Created and consumed entirely inside `container.perform` (not
    /// Sendable, like the other processors here).
    final class LogProbRecorder: LogitProcessor {
        private var inner: LogitProcessor?
        private var last: MLXArray?
        /// One lazy scalar per sampled token, index-aligned with sampling order.
        private(set) var pending: [MLXArray] = []

        init(inner: LogitProcessor?) { self.inner = inner }

        func prompt(_ prompt: MLXArray) { inner?.prompt(prompt) }

        func process(logits: MLXArray) -> MLXArray {
            let processed = inner?.process(logits: logits) ?? logits
            last = processed
            return processed
        }

        func didSample(token: MLXArray) {
            if let row = last?.reshaped([-1]) {
                let picked = takeAlong(row, token.reshaped([1]).asType(.int32), axis: 0)
                // logSumExp in the logits' own dtype, difference in float32 —
                // bit-for-bit the arithmetic the τ thresholds were calibrated on.
                pending.append((picked.asType(.float32) - row.logSumExp().asType(.float32)).reshaped([]))
            }
            inner?.didSample(token: token)
        }
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

    // MARK: Healing-constrained decoding (mid-word caret)

    /// Indices of the `k` largest values, descending — one CPU pass over the
    /// vocab row. The constrained phase runs for ≤ a handful of steps, so a
    /// partial selection here beats shipping a GPU sort.
    static func topIndices(_ values: [Float], k: Int) -> [Int] {
        var top: [Int] = []
        top.reserveCapacity(k + 1)
        for i in values.indices {
            let v = values[i]
            if top.count == k, let last = top.last, v <= values[last] { continue }
            let pos = top.firstIndex { values[$0] < v } ?? top.count
            top.insert(i, at: pos)
            if top.count > k { top.removeLast() }
        }
        return top
    }

    /// First candidate (highest-logit first) whose JOINT decode with the already
    /// sampled tokens stays prefix-compatible with the typed fragment: either
    /// still inside it (decode ⊂ expected) or covering it (decode ⊇ expected).
    /// Joint decode, not per-token, so BPE merges can't fake a mismatch. A
    /// candidate that adds no text (special token stripped by the decoder) is
    /// skipped — forcing it would loop the constrained phase forever.
    static func healCompatibleToken(
        expected: String, sampled: [Int], candidates: [Int], decode: ([Int]) -> String
    ) -> Int? {
        let current = decode(sampled)
        for id in candidates {
            let cand = decode(sampled + [id])
            guard cand.count > current.count else { continue }
            if cand.hasPrefix(expected) || expected.hasPrefix(cand) { return id }
        }
        return nil
    }

    /// Constrained decoding for the token-healing path: while the decode has
    /// not yet reproduced the typed fragment, mask the logits to the most
    /// probable token that keeps the decode prefix-compatible with it (top-50
    /// scan); no compatible token → force EOS, which the fragment gate reads
    /// as an abstain, so precision is preserved by construction. Outermost in
    /// the chain so the LogProbRecorder beneath records honest PRE-mask logits
    /// (the healed gate/journal signal must be the model's true confidence in
    /// the fragment path, not ~0 from a one-hot mask). Match-only healing
    /// abstained whenever greedy top-1 disagreed with the fragment — 87%
    /// precision at 13% coverage (Eval/BASELINE.md 2026-07-17); this recovers
    /// the abstains whose fragment path exists but wasn't top-1.
    /// Created and consumed inside `container.perform` (not Sendable, like the
    /// other processors here).
    final class HealConstraintProcessor: LogitProcessor {
        private var inner: LogitProcessor?
        private let expected: String
        private let eosID: Int?
        private let decode: ([Int]) -> String
        private var sampled: [Int] = []
        private var active = true

        init(inner: LogitProcessor?, expected: String, eosID: Int?,
             decode: @escaping ([Int]) -> String) {
            self.inner = inner
            self.expected = expected
            self.eosID = eosID
            self.decode = decode
        }

        func prompt(_ prompt: MLXArray) { inner?.prompt(prompt) }

        func process(logits: MLXArray) -> MLXArray {
            let processed = inner?.process(logits: logits) ?? logits
            guard active else { return processed }
            let current = decode(sampled)
            guard current.count < expected.count, expected.hasPrefix(current) else {
                active = false   // fragment covered (or overshot) — decode freely
                return processed
            }
            // The host scan beats a GPU top-k here: argPartition over a 262k row
            // measured ~30 ms/step slower than one row copy + this CPU pass.
            let row = processed.reshaped([-1]).asArray(Float.self)
            let ranked = MLXEngine.topIndices(row, k: 50)
            let chosen = MLXEngine.healCompatibleToken(
                expected: expected, sampled: sampled, candidates: ranked, decode: decode)
            let keep: Int
            if let chosen {
                keep = chosen
            } else if let eosID {
                keep = eosID   // dead end: end the turn → fragment gate abstains
                active = false
            } else {
                return processed  // no EOS to force — stop constraining
            }
            // One-hot on the GPU: everything at −1e9 but the kept token's logit
            // (was a host-built vocab-sized mask uploaded per step).
            let masked = MLXArray.full(processed.shape, values: MLXArray(Float(-1e9)), dtype: processed.dtype)
            masked[0..., keep] = processed[0..., keep]
            return masked
        }

        func didSample(token: MLXArray) {
            if active { sampled.append(token.reshaped([-1]).item(Int.self)) }
            inner?.didSample(token: token)
        }
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
        gateLogProb: Double? = nil,
        healExpected: String? = nil,
        prefillOnly: Bool = false,
        logRaw: Bool = true,
        onPartial: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        try await generate(
            in: container,
            makeTokens: { context in
                promptCache?.encoder.encode(prompt, with: context.tokenizer)
                    ?? context.tokenizer.encode(text: prompt)
            },
            parameters: parameters,
            extraEOSTokens: extraEOSTokens,
            promptCache: promptCache,
            bias: bias,
            minTokens: minTokens,
            logProbSink: logProbSink,
            firstWordStats: firstWordStats,
            forcedFirst: forcedFirst,
            trimLogProb: trimLogProb,
            gateLogProb: gateLogProb,
            healExpected: healExpected,
            prefillOnly: prefillOnly,
            logRaw: logRaw,
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
        /// Logprob-gate τ: abstain as soon as the first word's mean logprob is
        /// known to fall below it (the caller re-checks on the final result),
        /// and hold back partials until it is known to pass — so a gated
        /// stream never shows a suggestion the gate then retracts.
        gateLogProb: Double? = nil,
        healExpected: String? = nil,
        /// Prefill the prompt into the cache and stop — no decode, returns "".
        /// See `MLXEngine.warmPrompt`.
        prefillOnly: Bool = false,
        /// False when the generated text is not ours to print: the dictation
        /// tidy-up pass hands this path a SPOKEN sentence, and the debug buffer
        /// is exported into bug reports under a dialog that only warns about
        /// text the user typed. Lengths still go out — the diagnostic value of
        /// this line is the timing, not the words.
        logRaw: Bool = true,
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

            // Reuse a cached KV state for incremental typing (see PromptCache):
            // the longest shared prefix wins, however long the new tail — a
            // tail prefill always beats re-reading the whole prompt.
            let n = fullTokens.count
            let cache: [KVCache]
            var start: Int
            let priorCheckpoint: PromptCache.Snapshot?
            if let pc = promptCache, let hit = pc.take(for: fullTokens) {
                cache = hit.cache
                start = hit.reused
                priorCheckpoint = hit.checkpoint
            } else {
                cache = context.model.newCache(parameters: parameters)
                start = 0
                priorCheckpoint = nil
            }
            // A checkpoint is needed when the cache this decode leaves behind
            // could not be trimmed back next keystroke: a recurrent layer, or a
            // sliding ring the prompt + decode will wrap.
            let needsCheckpoint = promptCache != nil && cache.contains { layer in
                !layer.isTrimmable || (layer.maxSize.map { n + maxTokens + 1 >= $0 } ?? false)
            }
            // Where the prompt splits into a cache-only head and the tail the
            // first decode step reads. Every split costs a second pass over the
            // weights, so short tails go through in one forward; a long head is
            // split off to skip its vocab projection (262k-wide on Gemma, which
            // the decode step computes for every position it's fed); and a new
            // checkpoint is taken only once the tail since the last one outgrows
            // that same budget.
            let oneForward = 32
            let splitAt: Int
            var takeCheckpoint = false
            if needsCheckpoint, priorCheckpoint.map({ n - $0.tokens.count > oneForward }) ?? true {
                // Give the new checkpoint its margin: a trimmable cache that
                // already holds more than that is rewound to it (free — the
                // tokens are re-read in the same forward as the tail).
                let target = n - checkpointMargin
                if start > target, target >= 16, canTrimPromptCache(cache),
                   trimPromptCache(cache, numTokens: start - target) == start - target {
                    start = target
                }
                splitAt = min(n - 1, max(start, target))
                takeCheckpoint = splitAt >= 16
            } else {
                splitAt = n - start > oneForward ? n - 1 : start
            }

            let prefillStart = Date()
            var pos = start
            while pos < splitAt {
                let end = min(splitAt, pos + prefillChunk)
                _ = context.model(MLXArray(fullTokens[pos ..< end].map { Int32($0) })[.newAxis], cache: cache)
                // Settle each full chunk (bounds memory on a long cold prompt);
                // the last one runs on asynchronously ahead of the first step.
                if end < splitAt { eval(cache) } else { asyncEval(cache) }
                pos = end
            }
            let checkpoint = takeCheckpoint
                ? PromptCache.Snapshot(tokens: Array(fullTokens[..<splitAt]), cache: cache.map { $0.copy() })
                : needsCheckpoint ? priorCheckpoint : nil
            if prefillOnly {
                eval(cache)
                promptCache?.store(
                    forFullTokens: fullTokens,
                    live: canTrimPromptCache(cache)
                        ? PromptCache.Snapshot(tokens: Array(fullTokens[..<splitAt]), cache: cache) : nil,
                    checkpoint: checkpoint)
                DebugLog.shared.log("GEN", String(
                    format: "prefill-only: %d of %d tok in %.0fms (reused %d)",
                    splitAt - start, n, Date().timeIntervalSince(prefillStart) * 1000, start))
                return ""
            }

            // Compose the logit-processor chain: penalties → personal first-token boost →
            // min-token EOS mask.
            var processor: LogitProcessor? = parameters.processor()
            if let bias, let biased = makeBiasProcessor(bias, context: context, inner: processor) {
                processor = biased
            }
            if minTokens > 0, !eosIDs.isEmpty {
                processor = MinTokensProcessor(inner: processor, eosIDs: Array(eosIDs), minTokens: minTokens)
            }
            // Outermost, so it sees the logits the sampler actually samples from
            // (post-penalties, post-bias, post-EOS-mask) — that distribution is
            // what "the engine's confidence in what it showed" means.
            var recorder: LogProbRecorder?
            if logProbSink != nil || trimLogProb != nil || firstWordStats != nil || gateLogProb != nil {
                let r = LogProbRecorder(inner: processor)
                processor = r
                recorder = r
            }
            // Healing constraint OUTERMOST — the recorder beneath must record the
            // honest pre-mask logits (see HealConstraintProcessor).
            if let healExpected {
                processor = HealConstraintProcessor(
                    inner: processor, expected: healExpected, eosID: eosIDs.first,
                    decode: { context.tokenizer.decode(tokenIds: $0, skipSpecialTokens: true) })
            }
            processor?.prompt(MLXArray(fullTokens.map { Int32($0) }))
            let sampler = parameters.sampler()

            /// One forward + sample, enqueued on the GPU together with the
            /// token's logprob; nothing here waits.
            func step(_ input: MLXArray) -> MLXArray {
                let logits = context.model(input[.newAxis], cache: cache)
                var last = logits[0..., -1, 0...]
                last = processor?.process(logits: last) ?? last
                let token = sampler.sample(logits: last)
                processor?.didSample(token: token)
                asyncEval([token] + (recorder?.pending.last.map { [$0] } ?? []))
                return token
            }

            // Pipelined decode: step t+1 is encoded while the GPU still runs
            // step t (the CPU's graph build + Metal encoding is the dominant
            // per-token cost on these small models). Only a stop we can't see
            // coming (EOS, newline, trim/gate verdict) wastes the step already
            // in flight; the token budget never does.
            let firstInput = MLXArray(fullTokens[splitAt...].map { Int32($0) })
            var current = step(firstInput)
            let decodeStart = Date()
            var generated: [Int] = []       // sampled tokens, in order
            var cachedGenerated = 0         // of those, how many the cache holds
            var textTokens: [Int] = forcedFirst.map { [$0.token] } ?? []
            var perToken: [Float] = forcedFirst.map { [$0.logProb] } ?? []
            var firstWordCount: Int?
            var gateOpen = gateLogProb == nil
            // Seed the text too: an immediate EOS after a forced token must
            // still return that token's text, not "".
            var text = textTokens.isEmpty ? "" : context.tokenizer.decode(tokenIds: textTokens, skipSpecialTokens: true)
            while true {
                let next: MLXArray? = generated.count + 1 < maxTokens ? step(current) : nil
                if next != nil { cachedGenerated = generated.count + 1 }
                let token = current.item(Int.self)
                generated.append(token)
                if Task.isCancelled || eosIDs.contains(token) { break }
                textTokens.append(token)
                if let recorder, generated.count <= recorder.pending.count {
                    perToken.append(recorder.pending[generated.count - 1].item(Float.self))
                }
                text = context.tokenizer.decode(tokenIds: textTokens, skipSpecialTokens: true)

                // First word complete: the smallest token prefix whose text,
                // after leading separators, already holds an in-word boundary
                // (gateFirstWord's convention, so calibration matches the gate's
                // unit; the boundary token itself counts — one separator token of
                // overshoot at most). No boundary by the end ⇒ every token. The
                // gate's verdict exists now — abstaining here skips the rest of a
                // decode whose result would be discarded anyway.
                if firstWordCount == nil {
                    let core = text.drop { !$0.isLetter && !$0.isNumber }
                    if !core.isEmpty, core.contains(where: { !$0.isLetter && !$0.isNumber }) {
                        firstWordCount = textTokens.count
                        if let gateLogProb, perToken.count >= textTokens.count {
                            // Same arithmetic as the sink below, so the caller's
                            // final re-check can't disagree with this verdict.
                            let mean = perToken.prefix(textTokens.count).reduce(0.0) { $0 + Double($1) }
                                / Double(textTokens.count)
                            if mean < gateLogProb { break }
                            gateOpen = true
                        }
                    }
                }
                // Confidence trim's cut point (see confidenceTrimmed): nothing
                // from this token on is ever shown, so stop decoding here.
                if let trimLogProb, let fw = firstWordCount, textTokens.count - 1 >= fw,
                   let lp = perToken.last, perToken.count == textTokens.count, lp < trimLogProb {
                    break
                }
                if gateOpen { onPartial?(text) }
                if text.contains("\n") { break }
                guard let next else { break }
                current = next
            }
            let decodeSeconds = Date().timeIntervalSince(decodeStart)
            let prefillSeconds = decodeStart.timeIntervalSince(prefillStart)

            // Reduce the per-step log-probs to the first-word mean. perToken is
            // index-aligned with textTokens (EOS breaks before appending); a
            // forced first token was prefilled, not decoded, and its logprob
            // was prepended above (raw scale vs the recorder's post-processor
            // scale — identical unless penalties/bias are on).
            if recorder != nil {
                let firstWord = firstWordCount ?? textTokens.count
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
                // token. Display-only — the KV cache is untouched.
                if let threshold = trimLogProb,
                   let trimmed = confidenceTrimmed(
                       text: text, textTokens: textTokens, perToken: perToken,
                       firstWordTokens: firstWord, threshold: threshold,
                       decode: { context.tokenizer.decode(tokenIds: $0, skipSpecialTokens: true) }
                   ) {
                    DebugLog.shared.log(
                        "GATE",
                        String(format: "confidence-trim: weak tail below %.2f", threshold),
                        detail: logRaw
                            ? "kept \(trimmed.debugDescription) of \(text.debugDescription)"
                            : "kept \(trimmed.count) of \(text.count) chars — redacted from log"
                    )
                    text = trimmed
                }
            }

            if let pc = promptCache {
                // The cache now holds the prompt + every sampled token that was
                // fed back in. Keep it only if it can trim back next time.
                let live = canTrimPromptCache(cache)
                    ? PromptCache.Snapshot(tokens: fullTokens + generated.prefix(cachedGenerated), cache: cache)
                    : nil
                pc.store(forFullTokens: fullTokens, live: live, checkpoint: checkpoint)
            }
            let prefilled = n - start
            let summary = String(
                format: "reused=%@ prefill=%dtok/%.0fms (%.0f tok/s) decode=%dtok/%.0fms (%.0f tok/s) ckpt=%d",
                String(start > 0), prefilled, prefillSeconds * 1000,
                prefillSeconds > 0 ? Double(prefilled) / prefillSeconds : 0,
                generated.count, decodeSeconds * 1000,
                decodeSeconds > 0 ? Double(generated.count) / decodeSeconds : 0,
                checkpoint?.tokens.count ?? 0
            )
            DebugLog.shared.log(
                "GEN", summary,
                detail: logRaw
                    ? "raw: \(text.debugDescription)"
                    : "\(text.count) chars — redacted from log")
            if Self.debugLogging.get() {
                print("[gen] \(summary) raw=\(logRaw ? text.debugDescription : "<redacted>")")
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
