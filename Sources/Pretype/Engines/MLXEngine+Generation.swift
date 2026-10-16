import Foundation
import MLX
import MLXLMCommon

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

        /// Oldest first: `take` removes an entry and `store` re-appends it.
        private var entries: [(keyPrefix: [Int], live: Snapshot?, checkpoint: Snapshot?)] = []
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
            entries.append((prefix, live, checkpoint))
            if entries.count > maxEntries { entries.removeFirst() }
        }

        /// All but the newest entry — the field typed in last — go: after a
        /// pause a focus change re-warms its own prompt anyway, and each
        /// entry is ~30 MB of KV state (E4B).
        func keepNewest() {
            if entries.count > 1 { entries.removeFirst(entries.count - 1) }
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
    /// (an unvetted tokenizer) switches this encoder to full
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

    /// Tokens per speculative round (1 bonus + 2 drafted): block 3 measured
    /// best on E2B-it with a cached prompt (block 2 −5%, 4 −11%, 3 −18…−32%).
    static let mtpBlock = 3

    /// Longest draft a prompt-lookup round proposes. Past 8 the wider
    /// verify forward eats the gain on 4-bit weights: E4B-it fix, release,
    /// five interleaved rounds — draft 8 beat the MTP drafter in all five
    /// (median −11%), 16 tied it; E2B-it 109 → 78 ms at 8, 86 at 16.
    static let lookupDraft = 8

    /// Prompt-lookup decoding (LLMA, arXiv 2304.04487): a fix or a dictation
    /// tidy-up re-emits most of its input verbatim, so the
    /// draft is whatever followed the newest prompt occurrence of the last
    /// 1–3 output tokens. The target checks the whole draft in one forward
    /// and keeps the prefix its own greedy pick agrees with, plus that pick —
    /// the output is the greedy decode's, so temperature 0 only. No draft
    /// model; needs a cache that can rewind the rejected tail.
    /// eval-correct (680 rows, release, paired runs): fix p50 against the MTP
    /// drafter E2B-it 109 → 78 ms, E4B-it −11%, E4B-it-6bit a tie; against
    /// plain decoding Qwen2.5-0.5B-it 73 → 39, MiniCPM5-1B 177 → 66,
    /// Bonsai 265 → 216. Exact fixes unchanged; 6/680 outputs differ
    /// (argmax near-ties between the batched and the one-token forward).
    /// `Eval/runs-2026-10-11-lookup`.
    struct PromptLookupIterator {
        private let model: any LanguageModel
        private let cache: [KVCache]
        private let prompt: [Int]
        private let maxTokens: Int
        private let maxDraft: Int
        /// Tokens the next forward must feed before any draft: the unread
        /// prompt tail at first, then the last sampled token.
        private var feed: [Int]
        private var emitted: [Int] = []
        private var pending: ArraySlice<Int> = []
        private(set) var drafted = 0
        private(set) var accepted = 0

        init(input: [Int], prompt: [Int], model: any LanguageModel, cache: [KVCache],
             maxTokens: Int, maxDraft: Int = MLXEngine.lookupDraft) {
            self.feed = input
            self.prompt = prompt
            self.model = model
            self.cache = cache
            self.maxTokens = maxTokens
            self.maxDraft = maxDraft
        }

        mutating func next() -> Int? {
            if pending.isEmpty {
                guard emitted.count < maxTokens else { return nil }
                round()
            }
            return pending.popFirst()
        }

        private mutating func round() {
            // Drafts past the token budget would only be thrown away.
            var draft = Self.draft(after: prompt + emitted, promptCount: prompt.count,
                                   max: min(maxDraft, maxTokens - emitted.count - 1))
            if !draft.isEmpty, !cache.allSatisfy({ $0.isTrimmable(after: feed.count + draft.count) }) {
                draft = []
            }
            let input = MLXArray((feed + draft).map { Int32($0) })[.newAxis]
            let logits = model(input, cache: cache)
            // The pick after the last fed token, then one per draft position.
            let picks = argMax(logits[0, (feed.count - 1)...], axis: -1).asArray(Int.self)
            var agreed = 0
            while agreed < draft.count, draft[agreed] == picks[agreed] { agreed += 1 }
            if agreed < draft.count { trimPromptCache(cache, numTokens: draft.count - agreed) }
            let out = Array(draft[..<agreed]) + [picks[agreed]]
            drafted += draft.count
            accepted += agreed
            emitted += out
            pending = ArraySlice(out)
            feed = [picks[agreed]]
        }

        /// What followed the newest prompt occurrence of the sequence's last
        /// n tokens (n = 3, 2, 1 — the longest that matches), up to `max`.
        static func draft(after seq: [Int], promptCount: Int, max: Int) -> [Int] {
            guard max > 0 else { return [] }
            for n in stride(from: min(3, seq.count - 1), through: 1, by: -1) {
                let key = seq[(seq.count - n)...]
                // An occurrence needs ≥1 prompt token after it, and must not
                // be the key itself.
                var start = min(promptCount - 1, seq.count - 1) - n
                while start >= 0 {
                    if seq[start ..< start + n].elementsEqual(key) {
                        let from = start + n
                        return Array(seq[from ..< min(from + max, promptCount)])
                    }
                    start -= 1
                }
            }
            return []
        }
    }

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
        private let recordsEntropy: Bool
        /// One lazy scalar per sampled token, index-aligned with sampling order.
        private(set) var pending: [MLXArray] = []
        /// The entropy (nats) of the distribution each token was sampled from,
        /// index-aligned with `pending`; empty unless `recordsEntropy`.
        private(set) var entropies: [MLXArray] = []

        init(inner: LogitProcessor?, recordsEntropy: Bool = false) {
            self.inner = inner
            self.recordsEntropy = recordsEntropy
        }

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
                if recordsEntropy {
                    // H = logΣe^x − Σ softmax(x)·x, in float32.
                    let x = row.asType(.float32)
                    entropies.append((x.logSumExp() - (softmax(x) * x).sum()).reshaped([]))
                }
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
    /// `entropyThreshold` adds a second cut signal: a token sampled from a
    /// distribution flatter than that many nats (a name, a number — any slot
    /// the model is guessing at) ends the shown prefix too, even when the
    /// greedy pick itself clears `threshold`.
    static func confidenceTrimmed(
        text: String, textTokens: [Int], perToken: [Float],
        firstWordTokens: Int, threshold: Float,
        perEntropy: [Float] = [], entropyThreshold: Float? = nil,
        decode: ([Int]) -> String
    ) -> String? {
        let n = min(textTokens.count, perToken.count)
        let start = min(max(firstWordTokens, 1), n)
        func weak(_ i: Int) -> Bool {
            if perToken[i] < threshold { return true }
            guard let entropyThreshold, i < perEntropy.count else { return false }
            return perEntropy[i] > entropyThreshold
        }
        guard let cut = (start..<n).first(where: weak) else { return nil }
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

    static func generate(
        in container: ModelContainer,
        makeTokens: @Sendable @escaping (ModelContext) throws -> [Int],
        parameters: GenerateParameters,
        promptCache: PromptCache?,
        logProbSink: LockedValue<Double?>? = nil,
        trimLogProb: Float? = nil,
        /// Entropy trim (nats): see `confidenceTrimmed`. nil = off.
        trimEntropy: Float? = nil,
        /// Logprob-gate τ: abstain as soon as the first word's mean logprob is
        /// known to fall below it (the caller re-checks on the final result),
        /// and hold back partials until it is known to pass — so a gated
        /// stream never shows a suggestion the gate then retracts.
        gateLogProb: Double? = nil,
        healExpected: String? = nil,
        /// Prefill the prompt into the cache and stop — no decode, returns "".
        /// See `MLXEngine.warmPrompt`.
        prefillOnly: Bool = false,
        /// A Gemma 4 MTP drafter: decode speculatively (`MTPSpeculativeTokenIterator`,
        /// greedy-verified by the target) instead of token by token. Used only
        /// when nothing needs per-token logits — no healing and no logprob
        /// gate; the confidence trim and the first-word logprob
        /// are skipped on this path (the iterator exposes no per-token logits).
        drafter: (any MTPDrafterModel)? = nil,
        /// Copy-heavy output (fix, tidy-up): draft from the prompt
        /// itself (`PromptLookupIterator`) instead of the drafter. Greedy and
        /// processor-free generations only; anything else decodes as usual.
        lookup: Bool = false,
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
        // The drafter (an MLX module, not Sendable) is only touched inside this
        // perform, which serializes it with the target model.
        nonisolated(unsafe) let drafter = drafter
        return try await container.perform { (context: ModelContext) in
            let maxTokens = parameters.maxTokens ?? 16
            let fullTokens = try makeTokens(context)
            guard !fullTokens.isEmpty else { return "" }

            // The model's own eos_token_id list (config/generation_config), as
            // mlx-lm uses it: Gemma 4 -it ends a turn on `<turn|>`, which is
            // neither the tokenizer's `<eos>` nor Gemma 3's `<end_of_turn>`
            // (absent from Gemma 4's vocab). Without it E4B-it ran past its
            // reply into a "…thought" tail on 444/570 eval-reply rows.
            var eosIDs = context.configuration.eosTokenIds
            if let eos = context.tokenizer.eosToken,
               let id = context.tokenizer.convertTokenToId(eos) {
                eosIDs.insert(id)
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
                cache = try context.model.newCache(parameters: parameters)
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

            var processor: LogitProcessor? = parameters.processor()
            // Outermost, so it sees the logits the sampler actually samples from
            // (post-penalties) — that distribution is what "the
            // engine's confidence in what it showed" means.
            var recorder: LogProbRecorder?
            if logProbSink != nil || trimLogProb != nil || trimEntropy != nil || gateLogProb != nil {
                let r = LogProbRecorder(inner: processor, recordsEntropy: trimEntropy != nil)
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
                asyncEval([token] + (recorder?.pending.last.map { [$0] } ?? [])
                          + (recorder?.entropies.last.map { [$0] } ?? []))
                return token
            }

            // Pipelined decode: step t+1 is encoded while the GPU still runs
            // step t (the CPU's graph build + Metal encoding is the dominant
            // per-token cost on these small models). Only a stop we can't see
            // coming (EOS, newline, trim/gate verdict) wastes the step already
            // in flight; the token budget never does.
            let firstInput = MLXArray(fullTokens[splitAt...].map { Int32($0) })
            // Speculative path: drafts of `mtpBlock` tokens verified by the
            // target in one forward (block 3 measured best on E2B-it).
            var mtp: MTPSpeculativeTokenIterator?
            var copier: PromptLookupIterator?
            // A recurrent layer (Qwen3.5) can't rewind a rejected draft; there
            // the unpipelined rounds would only be slower than plain decoding.
            if lookup, processor == nil, parameters.temperature == 0,
               cache.allSatisfy(\.isTrimmable) {
                copier = PromptLookupIterator(
                    input: Array(fullTokens[splitAt...]), prompt: fullTokens, model: context.model,
                    cache: cache, maxTokens: maxTokens)
            } else if let drafter, healExpected == nil, gateLogProb == nil {
                mtp = try MTPSpeculativeTokenIterator(
                    input: LMInput(tokens: firstInput), mainModel: context.model, drafter: drafter,
                    mainCache: cache, parameters: parameters, blockSize: mtpBlock)
                recorder = nil
            }
            let speculative = mtp != nil || copier != nil
            var current: MLXArray? = speculative ? nil : step(firstInput)
            let decodeStart = Date()
            var generated: [Int] = []       // sampled tokens, in order
            var cachedGenerated = 0         // of those, how many the cache holds
            var liveMatchesPrompt = true    // false: speculative trim fell short
            var textTokens: [Int] = []
            var perToken: [Float] = []
            var perEntropy: [Float] = []
            var firstWordCount: Int?
            var gateOpen = gateLogProb == nil
            var text = ""
            while true {
                let token: Int
                var next: MLXArray?
                if mtp != nil {
                    guard let t = mtp?.next() else { break }
                    token = t
                } else if copier != nil {
                    guard let t = copier?.next() else { break }
                    token = t
                } else {
                    guard let cur = current else { break }
                    next = generated.count + 1 < maxTokens ? step(cur) : nil
                    if next != nil { cachedGenerated = generated.count + 1 }
                    token = cur.item(Int.self)
                }
                generated.append(token)
                if Task.isCancelled || eosIDs.contains(token) { break }
                textTokens.append(token)
                if let recorder, generated.count <= recorder.pending.count {
                    perToken.append(recorder.pending[generated.count - 1].item(Float.self))
                    if generated.count <= recorder.entropies.count {
                        perEntropy.append(recorder.entropies[generated.count - 1].item(Float.self))
                    }
                }
                text = context.tokenizer.decode(tokenIds: textTokens, skipSpecialTokens: true)

                // First word complete: the smallest token prefix whose text,
                // after leading separators, already holds a boundary after a
                // letter/number run (the gate's calibration unit; the boundary
                // token itself counts — one separator token of overshoot at most). No boundary by the end ⇒ every token. The
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
                if let fw = firstWordCount, textTokens.count - 1 >= fw,
                   let lp = perToken.last, perToken.count == textTokens.count {
                    if let trimLogProb, lp < trimLogProb { break }
                    if let trimEntropy, let h = perEntropy.last, perEntropy.count == textTokens.count,
                       h > trimEntropy { break }
                }
                if gateOpen { onPartial?(text) }
                if text.contains("\n") { break }
                if !speculative {
                    guard let next else { break }
                    current = next
                }
            }
            if speculative {
                // The speculative iterator leaves the cache holding the prompt
                // plus whatever it committed; bring it back to the prompt so the
                // live state below describes exactly `fullTokens`.
                let held = cache.first?.offset ?? n
                if held > n, canTrimPromptCache(cache) {
                    // A short trim leaves the cache longer than `fullTokens` (from
                    // mlx-swift-lm #622 it trims nothing if any layer can't rewind).
                    liveMatchesPrompt = trimPromptCache(cache, numTokens: held - n) == held - n
                }
                cachedGenerated = 0
            }
            let decodeSeconds = Date().timeIntervalSince(decodeStart)
            let prefillSeconds = decodeStart.timeIntervalSince(prefillStart)

            // Reduce the per-step log-probs to the first-word mean. perToken is
            // index-aligned with textTokens (EOS breaks before appending).
            if recorder != nil {
                let firstWord = firstWordCount ?? textTokens.count
                let n = min(firstWord, perToken.count)
                let firstWordSum = perToken.prefix(n).reduce(0.0) { $0 + Double($1) }
                logProbSink?.set(n > 0 ? firstWordSum / Double(n) : nil)
                // Confidence trim: show only the prefix before the first weak
                // token. Display-only — the KV cache is untouched.
                if trimLogProb != nil || trimEntropy != nil,
                   let trimmed = confidenceTrimmed(
                       text: text, textTokens: textTokens, perToken: perToken,
                       firstWordTokens: firstWord, threshold: trimLogProb ?? -.infinity,
                       perEntropy: perEntropy, entropyThreshold: trimEntropy,
                       decode: { context.tokenizer.decode(tokenIds: $0, skipSpecialTokens: true) }
                   ) {
                    DebugLog.shared.log(
                        "GATE",
                        "confidence-trim: weak tail (lp<\(trimLogProb.map { String(format: "%.2f", $0) } ?? "off")"
                            + (trimEntropy.map { String(format: " or H>%.1f", $0) } ?? "") + ")",
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
                let live = liveMatchesPrompt && canTrimPromptCache(cache)
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
                checkpoint?.tokens.count ?? 0,
                copier.map { " lookup=\($0.accepted)/\($0.drafted)" } ?? ""
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
}
