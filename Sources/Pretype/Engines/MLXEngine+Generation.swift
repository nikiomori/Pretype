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
        onPartial: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        try await container.perform { context in
            let maxTokens = parameters.maxTokens ?? 16
            let fullTokens = try makeTokens(context)
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
            var textTokens: [Int] = []
            var text = ""
            while fed.count < maxTokens, let token = iterator.next() {
                fed.append(token)
                if Task.isCancelled || eosIDs.contains(token) { break }
                textTokens.append(token)
                text = context.tokenizer.decode(tokenIds: textTokens, skipSpecialTokens: true)
                onPartial?(text)
                if text.contains("\n") { break }
            }
            let decodeSeconds = Date().timeIntervalSince(decodeStart)

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
}
