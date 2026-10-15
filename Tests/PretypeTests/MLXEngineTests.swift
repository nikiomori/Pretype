import MLXLMCommon
import XCTest
@testable import Pretype

final class MLXEngineTests: XCTestCase {
    // Keystroke-to-keystroke KV reuse: a checkpoint is reusable by ANY cache type
    // as an exact prefix (the only way a recurrent Qwen3.5 layer or a wrapped
    // Gemma ring can be reused), a live cache only by trimming; the longest
    // usable prefix wins and short (<16) matches are ignored.
    func testPromptCacheReuseRules() {
        typealias PC = MLXEngine.PromptCache
        let toks = Array(0 ..< 40)
        func trimmable(offset: Int) -> [KVCache] {
            let c = KVCacheSimple()
            c.offset = offset
            return [c]
        }

        // Recurrent checkpoint: exact prefix → reused; a prompt diverging inside
        // it can't rewind a recurrent state → no reuse.
        var pc = PC()
        let recurrent = MambaCache()
        pc.store(forFullTokens: toks, live: nil, checkpoint: .init(tokens: Array(toks[..<20]), cache: [recurrent]))
        let fromCheckpoint = pc.take(for: toks)
        XCTAssertEqual(fromCheckpoint?.reused, 20)
        // Handed out as a copy; the checkpoint itself comes back for re-storing.
        XCTAssertFalse((fromCheckpoint?.cache.first as AnyObject?) === recurrent)
        XCTAssertTrue((fromCheckpoint?.checkpoint?.cache.first as AnyObject?) === recurrent)
        pc = PC()
        pc.store(forFullTokens: toks, live: nil, checkpoint: .init(tokens: Array(toks[..<20]), cache: [MambaCache()]))
        XCTAssertNil(pc.take(for: Array(toks[..<18]) + [99, 98, 97]))

        // Trimmable live cache beats an older checkpoint: trimmed to the shared
        // prefix, capped at count−1 (the decode needs an input token).
        pc = PC()
        pc.store(forFullTokens: toks,
                 live: .init(tokens: toks, cache: trimmable(offset: 40)),
                 checkpoint: .init(tokens: Array(toks[..<32]), cache: trimmable(offset: 32)))
        let hit = pc.take(for: Array(toks[..<36]) + [77])
        XCTAssertEqual(hit?.reused, 36)
        XCTAssertEqual(hit?.cache.first?.offset, 36)
        XCTAssertNil(pc.take(for: toks), "a taken entry leaves the pool")

        // Below the 16-token floor nothing is reused.
        pc = PC()
        pc.store(forFullTokens: toks, live: .init(tokens: toks, cache: trimmable(offset: 40)), checkpoint: nil)
        XCTAssertNil(pc.take(for: Array(toks[..<10]) + [50, 51, 52, 53, 54, 55, 56, 57]))
    }

    // The incremental prompt encoder must return exactly what a full encode
    // would — and give up for good on a tokenizer whose splices aren't exact.
    func testPromptEncoderMatchesFullEncode() {
        let doc = (0 ..< 30).map { "word\($0) is typed here" }.joined(separator: " ")
        for tokenizer in [FakeTokenizer(), FakeTokenizer(mergeAcross: true)] {
            let encoder = MLXEngine.PromptEncoder()
            var text = String(doc.prefix(200))
            for ch in doc.dropFirst(200).prefix(300) {
                text.append(ch)
                XCTAssertEqual(encoder.encode(text, with: tokenizer), tokenizer.encode(text: text))
            }
        }
        XCTAssertEqual(MLXEngine.PromptEncoder.junction(in: "ab cd  ef", atOrBefore: 8), 2)
        XCTAssertNil(MLXEngine.PromptEncoder.junction(in: "abc", atOrBefore: 2))
    }

    // The instruct path splices the typed text between the chat template's
    // head and tail instead of re-rendering it; the result must equal a full
    // render, including on a tokenizer where splicing isn't exact.
    func testTemplateSpliceMatchesRender() {
        let doc = (0 ..< 30).map { "word\($0) is typed here" }.joined(separator: " ")
        for tokenizer in [FakeTokenizer(), FakeTokenizer(mergeAcross: true)] {
            let splice = MLXEngine.TemplateSplice()
            var text = String(doc.prefix(150))
            var renders = 0
            for ch in doc.dropFirst(150).prefix(250) {
                text.append(ch)
                let expected = [100] + tokenizer.encode(text: "Continue it.\n\nText:\n" + text, addSpecialTokens: false) + [200, 201]
                let got = splice.tokens(key: "Continue it.", text: text, tokenizer: tokenizer) {
                    renders += 1
                    return expected
                }
                XCTAssertEqual(got, expected)
            }
            // Exact splices stop rendering after the verification window.
            if !tokenizer.mergeAcross { XCTAssertLessThan(renders, 20) }
        }
    }

    // The fix model's load progress shows while it runs and then simply goes
    // away — the primary's own state, whatever it became meanwhile, shows
    // through (a snapshot/restore once pinned "loading…" over a ready model).
    func testEngineLoadingIgnoresAFinishedFixModel() {
        XCTAssertTrue(MLXEngine.isLoading(primary: .ready, primaryTaskLive: true, correctionStatus: "loading fix model…"))
        XCTAssertFalse(MLXEngine.isLoading(primary: .ready, primaryTaskLive: true, correctionStatus: nil))
        XCTAssertTrue(MLXEngine.isLoading(primary: .preparing("loading…"), primaryTaskLive: true, correctionStatus: nil))
        // Idle-unloaded resting state, with or without a resident fix model.
        XCTAssertFalse(MLXEngine.isLoading(primary: .preparing("idle — model unloaded"), primaryTaskLive: false,
                                           correctionStatus: nil))
        XCTAssertFalse(MLXEngine.isLoading(primary: .failed("x"), primaryTaskLive: false, correctionStatus: nil))
    }

    // Prompt lookup drafts the fix from its own input: longest n-gram first,
    // newest prompt occurrence, never past the prompt or the key itself.
    func testPromptLookupDraft() {
        typealias L = MLXEngine.PromptLookupIterator
        // prompt = 1 2 3 4 5 | 9 1 2 3 4 5 6 7 8 | 0 ; output so far: 2 3
        let prompt = [1, 2, 3, 4, 5, 9, 1, 2, 3, 4, 5, 6, 7, 8, 0]
        XCTAssertEqual(L.draft(after: prompt + [2, 3], promptCount: prompt.count, max: 4), [4, 5, 6, 7])
        // Budget and prompt end cap the draft.
        XCTAssertEqual(L.draft(after: prompt + [7], promptCount: prompt.count, max: 8), [8, 0])
        XCTAssertEqual(L.draft(after: prompt + [2, 3], promptCount: prompt.count, max: 0), [])
        // 3-gram miss falls back to the 1-gram.
        XCTAssertEqual(L.draft(after: prompt + [42, 9], promptCount: prompt.count, max: 2), [1, 2])
        // The prompt's own last token never matches itself; no match → no draft.
        XCTAssertEqual(L.draft(after: [5, 6, 7], promptCount: 3, max: 4), [])
        XCTAssertEqual(L.draft(after: prompt + [77], promptCount: prompt.count, max: 4), [])
    }

    // Confidence trim decides how much of a decoded suggestion the user actually
    // sees — pin the boundary rules (first word protected, stranded word heads
    // dropped, cut lands on a word boundary).
    func testConfidenceTrimmed() {
        let table = [1: " завтра", 2: " ве", 3: "чером", 4: " в", 5: " семь"]
        let decode: ([Int]) -> String = { $0.compactMap { table[$0] }.joined() }
        // The weak token CONTINUES a word → the stranded head is dropped too.
        XCTAssertEqual(
            MLXEngine.confidenceTrimmed(
                text: " завтра вечером", textTokens: [1, 2, 3], perToken: [-0.1, -0.2, -4.0],
                firstWordTokens: 2, threshold: -3.0, decode: decode),
            " завтра")
        // The weak token STARTS a word → the cut is already on a boundary.
        XCTAssertEqual(
            MLXEngine.confidenceTrimmed(
                text: " завтра в семь", textTokens: [1, 4, 5], perToken: [-0.1, -0.2, -3.5],
                firstWordTokens: 2, threshold: -3.0, decode: decode),
            " завтра в")
        // Confident everywhere → untouched.
        XCTAssertNil(MLXEngine.confidenceTrimmed(
            text: " завтра вечером", textTokens: [1, 2, 3], perToken: [-0.1, -0.2, -0.3],
            firstWordTokens: 2, threshold: -3.0, decode: decode))
        // A weak FIRST word is the logprob gate's job, never the trim's.
        XCTAssertNil(MLXEngine.confidenceTrimmed(
            text: " завтра", textTokens: [1], perToken: [-5.0],
            firstWordTokens: 1, threshold: -3.0, decode: decode))
    }

    // Token healing: a mid-word prompt is backed up to the word boundary and
    // the decode must reproduce the typed fragment (MLXEngine.tokenHealing).
    func testTokenHealing() {
        // Space-separated fragment: drop "goi" + the separator; the decode must
        // open with " goi", the suggestion is the remainder (" going to" → "ng to").
        let en = MLXEngine.tokenHealing(text: "you're goi")
        XCTAssertEqual(en?.dropCount, 4)
        XCTAssertEqual(en?.expected, " goi")
        // Cyrillic heals the same way.
        let ru = MLXEngine.tokenHealing(text: "мы пош")
        XCTAssertEqual(ru?.dropCount, 4)
        XCTAssertEqual(ru?.expected, " пош")
        // Fragment right after punctuation: no separator in the expectation.
        let flush = MLXEngine.tokenHealing(text: "see (fig")
        XCTAssertEqual(flush?.dropCount, 3)
        XCTAssertEqual(flush?.expected, "fig")
        // Word boundary / no head / CJK letter-run → no healing.
        XCTAssertNil(MLXEngine.tokenHealing(text: "okay."))
        XCTAssertNil(MLXEngine.tokenHealing(text: "goi"))
        XCTAssertNil(MLXEngine.tokenHealing(text: "她是个演员"))
    }

    // The constrained-decoding side of healing: candidate selection must accept
    // exactly the tokens whose joint decode stays inside/over the typed fragment.
    func testHealConstrainedChoice() {
        // Fake vocab: 1=" go" 2="ing" 3=" gone" 4="xx" 5=special (decodes to "").
        let vocab: [Int: String] = [1: " go", 2: "ing", 3: " gone", 4: "xx", 5: ""]
        func decode(_ ids: [Int]) -> String { ids.compactMap { vocab[$0] }.joined() }
        // Start of fragment " goi": " go" ⊂ " goi" is compatible, "xx" isn't.
        XCTAssertEqual(MLXEngine.healCompatibleToken(
            expected: " goi", sampled: [], candidates: [4, 1], decode: decode), 1)
        // Overshoot: " go"+"ing" = " going" ⊇ " goi" is compatible.
        XCTAssertEqual(MLXEngine.healCompatibleToken(
            expected: " goi", sampled: [1], candidates: [4, 2], decode: decode), 2)
        // " gone" diverges from " goi" mid-fragment → not compatible.
        XCTAssertNil(MLXEngine.healCompatibleToken(
            expected: " goi", sampled: [], candidates: [3, 4], decode: decode))
        // A zero-progress decode (stripped special token) must never be chosen —
        // forcing it would loop the constrained phase forever.
        XCTAssertNil(MLXEngine.healCompatibleToken(
            expected: " goi", sampled: [], candidates: [5], decode: decode))
        // topIndices: indices of the k largest values, descending.
        XCTAssertEqual(MLXEngine.topIndices([0.1, 3, -1, 2.5], k: 2), [1, 3])
        XCTAssertEqual(MLXEngine.topIndices([5], k: 3), [0])
    }
}

/// Word-level fake: a BOS, then one id per space-led word, a newline being a
/// word of its own (exact at space and newline junctions, like the real
/// BPEs at their pre-token boundaries). `mergeAcross` fuses every word pair
/// instead, so a split encode differs — the unvetted-tokenizer case.
private struct FakeTokenizer: MLXLMCommon.Tokenizer {
    var mergeAcross = false
    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        var words: [String] = []
        for ch in text {
            if ch == " " || ch == "\n" || words.isEmpty || words.last == "\n" {
                words.append(String(ch))
            } else {
                words[words.count - 1].append(ch)
            }
        }
        if mergeAcross {
            words = stride(from: 0, to: words.count, by: 2).map { words[$0] + (words.indices.contains($0 + 1) ? words[$0 + 1] : "") }
        }
        return (addSpecialTokens ? [0] : []) + words.map { abs($0.hashValue % 100_000) + 1 }
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] { [] }
}
