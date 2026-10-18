import HuggingFace
import MLX
import MLXLLM
import MLXLMCommon
import XCTest
@testable import Pretype

final class MLXEngineTests: MLXTestCase {
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
        XCTAssertEqual(pc.take(for: toks)?.reused, 20, "and left in the pool")

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

        // Storing nothing keeps the entry it would have replaced; a snapshot
        // of no layers is never reused.
        pc = PC()
        pc.store(forFullTokens: toks, live: .init(tokens: toks, cache: trimmable(offset: 40)), checkpoint: nil)
        pc.store(forFullTokens: toks, live: nil, checkpoint: nil)
        XCTAssertEqual(pc.take(for: toks + [1])?.reused, 40)
        pc.store(forFullTokens: toks, live: .init(tokens: toks, cache: []), checkpoint: nil)
        XCTAssertNil(pc.take(for: toks + [1]))

        // Four prompts at most (~30 MB of KV state each on E4B): a fifth
        // pushes out the oldest.
        pc = PC()
        let prompts = (0 ..< 5).map { k in (0 ..< 40).map { $0 + 100 * k } }
        for p in prompts { pc.store(forFullTokens: p, live: .init(tokens: p, cache: trimmable(offset: 40)), checkpoint: nil) }
        XCTAssertNil(pc.take(for: prompts[0] + [1]), "the oldest of five")
        for p in prompts.dropFirst() { XCTAssertNotNil(pc.take(for: p + [1])) }

        // 16 shared tokens are worth a reuse, 15 aren't — counted from the
        // first token.
        for (shared, reused) in [(16, 16 as Int?), (15, nil)] {
            pc = PC()
            pc.store(forFullTokens: toks, live: .init(tokens: toks, cache: trimmable(offset: 40)), checkpoint: nil)
            XCTAssertEqual(pc.take(for: Array(toks[..<shared]) + [90, 91, 92])?.reused, reused, "\(shared)")
        }
        pc = PC()
        pc.store(forFullTokens: [99] + toks.dropFirst(), live: .init(tokens: [99] + toks.dropFirst(),
                                                                    cache: trimmable(offset: 40)), checkpoint: nil)
        XCTAssertNil(pc.take(for: toks + [1]), "another first token")

        // A live state beats a checkpoint as good: handed over itself, no copy.
        pc = PC()
        let live = trimmable(offset: 20)
        pc.store(forFullTokens: toks, live: .init(tokens: Array(toks[..<20]), cache: live),
                 checkpoint: .init(tokens: Array(toks[..<20]), cache: trimmable(offset: 20)))
        XCTAssertTrue((pc.take(for: toks)?.cache.first as AnyObject?) === (live.first as AnyObject?))

        // One entry per prompt head (the first 24 tokens): a new prompt
        // with the same head replaces the old one, whatever follows.
        pc = PC()
        let other = Array(toks[..<24]) + (0 ..< 16).map { 500 + $0 }
        pc.store(forFullTokens: toks, live: .init(tokens: toks, cache: trimmable(offset: 40)), checkpoint: nil)
        pc.store(forFullTokens: other, live: .init(tokens: other, cache: trimmable(offset: 40)), checkpoint: nil)
        XCTAssertEqual(pc.take(for: toks + [1])?.reused, 24, "only the newer prompt's state is left")
        XCTAssertNil(pc.take(for: toks + [1]))
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
        XCTAssertEqual(MLXEngine.PromptEncoder.junction(in: "ab cd ef", atOrBefore: 5), 5, "at the limit itself")
        XCTAssertEqual(MLXEngine.PromptEncoder.junction(in: "a b", atOrBefore: 1), 1, "the first place one can be")
        XCTAssertEqual(MLXEngine.PromptEncoder.junction(in: "ab cd", atOrBefore: 10), 2, "a limit past the end")
        XCTAssertNil(MLXEngine.PromptEncoder.junction(in: " abc", atOrBefore: 2), "nothing before a leading space")
        XCTAssertNil(MLXEngine.PromptEncoder.junction(in: "ab cd", atOrBefore: 0))
    }

    // The encoder's work, keystroke by keystroke: its anchor at the last
    // junction 64 characters before the end; then each keystroke encodes
    // the text past the anchor, checked against a whole encode for its
    // first 8 splices and trusted after. A splice that fails the check
    // sends every keystroke after it to one whole encode, for good.
    func testPromptEncoderWork() {
        let doc = (0 ..< 30).map { "word\($0) is typed here" }.joined(separator: " ")
        let exact = CountingTokenizer(FakeTokenizer())
        let encoder = MLXEngine.PromptEncoder()
        var text = String(doc.prefix(200))
        _ = encoder.encode(text, with: exact)
        let anchor = try? XCTUnwrap(MLXEngine.PromptEncoder.junction(in: text, atOrBefore: text.count - 64))
        XCTAssertEqual(exact.lengths.get(), [text.count, anchor ?? -1], "the whole text, then its anchor")
        for keystroke in 1 ... 12 {
            exact.lengths.set([])
            text.append(doc[doc.index(doc.startIndex, offsetBy: text.count)])
            _ = encoder.encode(text, with: exact)
            let tail = text.count - (anchor ?? 0)
            XCTAssertEqual(exact.lengths.get(), keystroke <= 8 ? [tail, text.count] : [tail], "keystroke \(keystroke)")
        }

        let inexact = CountingTokenizer(FakeTokenizer(mergeAcross: true))
        let fallback = MLXEngine.PromptEncoder()
        text = String(doc.prefix(200))
        var failed = false
        for _ in 0 ..< 12 {
            inexact.lengths.set([])
            _ = fallback.encode(text, with: inexact)
            if failed { XCTAssertEqual(inexact.lengths.get(), [text.count], "after a failed splice: one whole encode") }
            failed = failed || inexact.lengths.get().count == 2 && inexact.lengths.get()[1] == text.count
            text.append(doc[doc.index(doc.startIndex, offsetBy: text.count)])
        }
        XCTAssertTrue(failed, "the merging tokenizer never failed a splice")
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
            // One render to learn the split, 8 to check it, then none.
            XCTAssertEqual(renders, 9, "mergeAcross: \(tokenizer.mergeAcross)")
        }
    }

    // The fix model's load progress shows while it runs and then simply goes
    // away — the primary's own state, whatever it became meanwhile, shows
    // through (a snapshot/restore once pinned "loading…" over a ready model).
    func testEngineLoadingIgnoresAFinishedFixModel() {
        XCTAssertTrue(ModelResidency.isLoading(primary: .ready, primaryTaskLive: true, correctionStatus: "loading fix model…"))
        XCTAssertFalse(ModelResidency.isLoading(primary: .ready, primaryTaskLive: true, correctionStatus: nil))
        XCTAssertTrue(ModelResidency.isLoading(primary: .preparing("loading…"), primaryTaskLive: true, correctionStatus: nil))
        // Idle-unloaded resting state, with or without a resident fix model.
        XCTAssertFalse(ModelResidency.isLoading(primary: .preparing("idle — model unloaded"), primaryTaskLive: false,
                                           correctionStatus: nil))
        XCTAssertFalse(ModelResidency.isLoading(primary: .failed("x"), primaryTaskLive: false, correctionStatus: nil))
    }

    // Fixes run on the primary whenever the sibling's weights are the ones it
    // holds. Compared by id, an old 8 GB install holding only Qwen3.5's
    // post-trained 4-bit loaded that build a second time on the first ⌥⇥.
    func testFixesRunOnThePrimaryWhenTheSiblingResolvesToItsWeights() {
        let qwen = "nikimori/Qwen3.5-2B-Base-6bit"
        let old = "mlx-community/Qwen3.5-2B-4bit"
        let slim = "nikimori/Qwen3.5-2B-4bit-slim"
        XCTAssertEqual(ModelCatalog.option(for: qwen)?.correctionModelID, old)
        func onPrimary(_ onDisk: [String], style: CompletionStyle = .base, _ primary: String = qwen) -> Bool {
            let repo = { ModelCatalog.repo(for: $0, isFetched: onDisk.contains) }
            return ModelResidency.fixesOnPrimary(style: style, primary: repo(primary),
                                            sibling: repo(ModelCatalog.option(for: primary)?.correctionModelID ?? old))
        }
        XCTAssertTrue(onPrimary([old]), "the 6-bit fetch declined: both resolve to the original")
        XCTAssertTrue(onPrimary([old, slim]), "the sibling's re-pack holds the same weights")
        XCTAssertFalse(onPrimary([old, qwen]))
        XCTAssertFalse(onPrimary([old, slim, qwen]))
        XCTAssertFalse(onPrimary([]), "a fresh install runs two models")
        // Models that are their own fix sibling, and instruct style, always.
        XCTAssertTrue(onPrimary([], "nikimori/Qwen3.5-2B-M40-6bit"))
        XCTAssertTrue(onPrimary([], "prism-ml/Ternary-Bonsai-4B-mlx-2bit"))
        XCTAssertFalse(onPrimary([], "mlx-community/gemma-4-e2b-4bit"))
        XCTAssertTrue(onPrimary([], style: .instruct, "mlx-community/gemma-4-e2b-4bit"))
    }

    // A slot answers with the weights it holds, not with what the disk would
    // resolve now: the hourly upgrade fetching Qwen3.5's 6-bit build while the
    // 4-bit serves must not move fixes to a second copy of that 4-bit.
    func testASlotNamesTheWeightsItHoldsNotTheDisksNewestBuild() {
        let qwen = "nikimori/Qwen3.5-2B-Base-6bit"
        let old = "mlx-community/Qwen3.5-2B-4bit"
        var onDisk = [old]
        let resolve = { (id: String) in ModelCatalog.repo(for: id, isFetched: onDisk.contains) }
        let primary = ModelResidency.Slot(id: qwen, drafterID: nil, retryCooldown: 30)
        let sibling = ModelResidency.Slot(id: old, drafterID: nil, retryCooldown: 0)
        primary.loadedRepo = resolve(qwen)
        XCTAssertEqual(primary.loadedRepo, old)
        onDisk.append(qwen)  // the 6-bit build lands
        XCTAssertEqual(resolve(qwen), qwen)
        XCTAssertEqual(primary.repo(resolve: resolve), old)
        XCTAssertTrue(ModelResidency.fixesOnPrimary(style: .base, primary: primary.repo(resolve: resolve),
                                               sibling: sibling.repo(resolve: resolve)))
        // Let go, it reloads the 6-bit build: from then on fixes take the sibling.
        primary.loadedRepo = nil
        XCTAssertFalse(ModelResidency.fixesOnPrimary(style: .base, primary: primary.repo(resolve: resolve),
                                                sibling: sibling.repo(resolve: resolve)))
    }

    // The primary and the fix sibling share one Slot; only the cooldown after
    // a failed load differs, and each idles on its own clock.
    func testSlotCooldownAndIdleClock() {
        let now = Date()
        let primary = ModelResidency.Slot(id: "p", drafterID: nil, retryCooldown: 30)
        let sibling = ModelResidency.Slot(id: "s", drafterID: nil, retryCooldown: 0)
        XCTAssertTrue(primary.mayLoad(at: now))
        primary.lastFailure = now.addingTimeInterval(-10)
        sibling.lastFailure = primary.lastFailure
        XCTAssertFalse(primary.mayLoad(at: now), "a failed primary must not hit the Hub on every keystroke")
        XCTAssertTrue(primary.mayLoad(at: now.addingTimeInterval(21)))
        XCTAssertTrue(sibling.mayLoad(at: now), "a ⌥⇥ is a deliberate retry")

        sibling.lastUse = now.addingTimeInterval(-600)
        XCTAssertFalse(sibling.isIdle(for: 300, at: now), "nothing loaded, nothing to free")
        sibling.task = Task { throw CancellationError() }
        XCTAssertTrue(sibling.isIdle(for: 300, at: now))
        XCTAssertFalse(sibling.isIdle(for: 900, at: now))
        sibling.inFlight = 1
        XCTAssertFalse(sibling.isIdle(for: 300, at: now), "never under a running fix")
    }

    // The drafter is decided once per load, whichever way the target loads:
    // on disk, load it; missing, fetch it for the next load — the HostPLE
    // build skipped the fetch, and one failed fetch lost MTP for good;
    // broken this launch, neither.
    func testDrafterPlan() {
        let id = "mlx-community/gemma-4-E2B-it-assistant-bf16"
        let here = URL(fileURLWithPath: "/tmp/drafter"), missing = { (_: String) -> URL? in nil }
        XCTAssertEqual(MLXEngine.drafterPlan(id, broken: [], onDisk: { _ in here }).load, here)
        XCTAssertNil(MLXEngine.drafterPlan(id, broken: [], onDisk: { _ in here }).fetch)
        XCTAssertNil(MLXEngine.drafterPlan(id, broken: [], onDisk: missing).load)
        XCTAssertEqual(MLXEngine.drafterPlan(id, broken: [], onDisk: missing).fetch, id)
        XCTAssertNil(MLXEngine.drafterPlan(id, broken: [id], onDisk: { _ in here }).load)
        XCTAssertNil(MLXEngine.drafterPlan(id, broken: [id], onDisk: missing).fetch)
        XCTAssertNil(MLXEngine.drafterPlan(nil, broken: [], onDisk: { _ in here }).load)
    }

    // The minute timer as a rule: past the limit with nothing running,
    // everything goes; short of it, the fix sibling may go on its own clock
    // and a minute without use trims — under "never" (limit 0) too.
    func testIdleTimerSteps() {
        typealias R = ModelResidency
        XCTAssertEqual(R.idleSteps(limit: 600, idle: 700, busy: false), [.unloadAll])
        XCTAssertEqual(R.idleSteps(limit: 600, idle: 700, busy: true), [.unloadIdleSibling], "never under a request")
        XCTAssertEqual(R.idleSteps(limit: 600, idle: 120, busy: false), [.unloadIdleSibling, .trim])
        XCTAssertEqual(R.idleSteps(limit: 600, idle: 30, busy: false), [.unloadIdleSibling])
        XCTAssertEqual(R.idleSteps(limit: 0, idle: 9_999, busy: false), [.trim])
        XCTAssertEqual(R.idleSteps(limit: 0, idle: 30, busy: false), [])
    }

    // Without Metal no model ever loads: `start` is never called, and every
    // request and prewarm abstains instead of loading.
    func testAResidencyThatNeverStartedServesNoRequest() throws {
        try withScratchHub {
            let residency = ModelResidency(primaryID: "nikimori/Qwen3.5-2B-Base-6bit", style: .base,
                                           promptCache: MLXEngine.PromptCache(), after: nil)
            residency.fail("Metal shaders missing")
            XCTAssertNil(residency.begin(.completion))
            XCTAssertNil(residency.begin(.fix))
            residency.prewarm(.completion)
            residency.prewarm(.fix)
            XCTAssertFalse(residency.primaryLoadedOrLoading)
            XCTAssertFalse(residency.isLoading)
            XCTAssertEqual(residency.state, .failed("Metal shaders missing"))
        }
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
        XCTAssertEqual(L.draft(after: prompt + [2, 3], promptCount: prompt.count, max: 1), [4], "a one-token draft")
        // The longest key is 3 tokens, then 2, then 1 — the newest place each fits.
        let twice = [9, 1, 2, 3, 50, 7, 1, 2, 3, 60, 8]
        XCTAssertEqual(L.draft(after: twice + [9, 1, 2, 3], promptCount: twice.count, max: 2), [60, 8], "not a 4-gram")
        let bigram = [1, 2, 9, 5, 2, 8, 0]
        XCTAssertEqual(L.draft(after: bigram + [1, 2], promptCount: bigram.count, max: 2), [9, 5], "the 2-gram before the 1-gram")
        // Occurrences anywhere from the prompt's start to the last place a
        // token still follows inside it.
        XCTAssertEqual(L.draft(after: [7, 8, 9, 7], promptCount: 4, max: 4), [8, 9, 7], "at the very start")
        XCTAssertEqual(L.draft(after: [3, 5, 7, 5, 8, 9, 5], promptCount: 5, max: 4), [8], "one before the prompt's end")
        XCTAssertEqual(L.draft(after: [5, 8, 5, 9, 5], promptCount: 3, max: 4), [8, 5], "never at the prompt's last token")
        XCTAssertEqual(L.draft(after: [4, 7, 7], promptCount: 3, max: 4), [7], "no output yet")
        XCTAssertEqual(L.draft(after: [7, 7], promptCount: 2, max: 4), [7], "a two-token prompt")
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
        XCTAssertNil(MLXEngine.tokenHealing(text: "see 她是个演员"), "no word to back up to in Han")
        // A letter-run past 24 is no word being typed (a paste); 24 still is.
        XCTAssertNil(MLXEngine.tokenHealing(text: "see " + String(repeating: "a", count: 25)))
        XCTAssertEqual(MLXEngine.tokenHealing(text: "see " + String(repeating: "a", count: 24))?.dropCount, 25)
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

    // MARK: - The completion path, on the tiny Gemma

    /// An engine on the tiny Gemma (CPU) in a scratch hub, under the settings
    /// it reads at init — pinned here, restored after. `loads` counts its
    /// model loads; `chats`, the chats its tokenizer renders.
    private func withEngine(_ modelID: String = "test/tiny", style: CompletionStyle = .base, gate: Bool = false,
                            recommended: Bool = false, loads: LockedValue<Int> = LockedValue(0),
                            chats: LockedValue<[String]>? = nil, _ body: (MLXEngine) async throws -> Void) async throws {
        try await withScratchHub {
            let saved = (Settings.completionStyle, Settings.completionLength, Settings.customInstructions,
                         Settings.logprobGate, Settings.useRecommendedSettings)
            defer {
                (Settings.completionStyle, Settings.completionLength, Settings.customInstructions,
                 Settings.logprobGate, Settings.useRecommendedSettings) = saved
            }
            (Settings.completionStyle, Settings.completionLength, Settings.customInstructions,
             Settings.logprobGate, Settings.useRecommendedSettings) = (style, .short, "", gate, recommended)
            let engine = MLXEngine(modelID: modelID, load: { _, _, _, _, _ in
                loads.mutate { $0 += 1 }
                return try tinyContainer(window: 512, chats: chats)
            }, shadersPresent: true)
            defer { engine.shutdown() }
            try await body(engine)
        }
    }

    private func complete(_ engine: MLXEngine, _ text: String) async throws -> String? {
        try await engine.complete(CompletionRequest(textBeforeCaret: text))
    }

    private func stream(_ engine: MLXEngine, _ text: String) async throws -> [String] {
        var yields: [String] = []
        for try await partial in engine.completions(for: CompletionRequest(textBeforeCaret: text)) { yields.append(partial) }
        return yields
    }

    /// Whether `engine`'s prompt cache holds a prefix of `text`'s prompt.
    private func cached(_ engine: MLXEngine, _ text: String) -> Bool {
        engine.promptCache.take(for: CharTokenizer().encode(text: text + "?")) != nil
    }

    // A stream ends on what the final gate shows: on the final text when the
    // partials stopped short of it, never on a repeat of the last partial;
    // on "" when the final gate rejects text the partials already showed;
    // on nothing at all when nothing was shown.
    func testTheCompletionStreamEndsOnWhatTheFinalGateShows() async throws {
        try await withEngine { engine in
            let shown = try await stream(engine, "abcdefghijklmnopqrstuvwxy")
            let final = try await complete(engine, "abcdefghijklmnopqrstuvwxy")
            XCTAssertGreaterThan(shown.count, 1, "partials, then the final")
            XCTAssertEqual(shown.last, try XCTUnwrap(final))
            XCTAssertFalse(shown.dropLast().contains(try XCTUnwrap(final)), "the last partial is not repeated")

            let retracted = try await stream(engine, "a1b2c3d4e5f6g7h8")
            let rejected = try await complete(engine, "a1b2c3d4e5f6g7h8")
            XCTAssertNil(rejected)
            XCTAssertGreaterThan(retracted.count, 1, "partials went out")
            XCTAssertEqual(retracted.last, "", "then the final gate took them back")

            let belowFloor = try await stream(engine, "0123456789")
            XCTAssertEqual(belowFloor, [], "below the context floor: nothing to take back")
        }
        // With the gate on, the decode holds partials back until the first
        // word's verdict, and the stream then ends on the final text.
        try await withEngine(gate: true) { engine in
            let shown = try await stream(engine, "abcdefghijklmnopqrstuvwxyz0123")
            let final = try await complete(engine, "abcdefghijklmnopqrstuvwxyz0123")
            XCTAssertEqual(shown.last, try XCTUnwrap(final))
        }
    }

    // The logprob gate abstains on a first word less likely than τ, but never
    // on a healed word: its logprob is the typed fragment's, another scale.
    // The engine's first-word logprob describes the suggestion shown — the
    // last one, or none after an abstain.
    func testTheLogprobGateAndTheFirstWordLogProb() async throws {
        let (unsure, confident, healed) = ("abcdefghijklmnopqrstuvwxyz", "abcdefghijklmnopqrstuvwxyz0123", "9876543210xyz")
        var ungated: [String: Double] = [:]
        try await withEngine { engine in
            for text in [unsure, confident, healed] {
                let shown = try await complete(engine, text)
                XCTAssertNotNil(shown, "\(text) shows ungated")
                ungated[text] = try XCTUnwrap(engine.lastFirstWordLogProb)
            }
        }
        let tau = Settings.logprobGateThreshold
        XCTAssertLessThan(ungated[unsure] ?? 0, tau)
        XCTAssertGreaterThan(ungated[confident] ?? -.infinity, tau)
        XCTAssertLessThan(ungated[healed] ?? 0, tau)
        try await withEngine(gate: true) { engine in
            XCTAssertEqual(engine.logprobGateThreshold, tau, "a hand-set gate (no recommended settings) is τ as set")
            let sure = try await complete(engine, confident)
            XCTAssertNotNil(sure)
            XCTAssertEqual(try XCTUnwrap(engine.lastFirstWordLogProb), ungated[confident] ?? 0, accuracy: 1e-4)
            let abstained = try await complete(engine, unsure)
            XCTAssertNil(abstained)
            XCTAssertNil(engine.lastFirstWordLogProb, "an abstain leaves no logprob behind")
            let healedWord = try await complete(engine, healed)
            XCTAssertNotNil(healedWord, "a healed word skips the gate")
            XCTAssertNotNil(engine.lastFirstWordLogProb)
        }
    }

    // The gate's τ: the model's recommended one under recommended settings,
    // the hand-set one without them, none with the gate off.
    func testTheGateThresholdFollowsTheSettings() async throws {
        let id = try XCTUnwrap(ModelCatalog.options.map(\.id).first {
            ModelCatalog.recommended(for: $0).logprobGateTau.map { $0 != Settings.logprobGateThreshold } ?? false
        }, "a model with a τ of its own")
        let recommended = ModelCatalog.recommended(for: id)
        try await withEngine(id, gate: true, recommended: true) { engine in
            XCTAssertEqual(engine.logprobGateThreshold, recommended.logprobGateTau)
            XCTAssertEqual(engine.scriptGateTau, recommended.scriptGateTau)
        }
        try await withEngine(id, gate: true) { engine in
            XCTAssertEqual(engine.logprobGateThreshold, Settings.logprobGateThreshold)
            XCTAssertEqual(engine.scriptGateTau, [:])
        }
        try await withEngine(id, recommended: true) { engine in
            XCTAssertNil(engine.logprobGateThreshold)
            // The confidence trim has no switch: on, at its calibrated −1.5.
            XCTAssertEqual(engine.trimLogProbThreshold, -1.5)
        }
    }

    // The dictation tidy-up runs a spoken sentence through the fix, and a
    // voice command speaks its instruction: docs/privacy.md promises
    // neither reaches the log. Then nothing the model was given or wrote
    // back is logged — lengths only — while a typed ⌥⇥ fix logs its text,
    // as the log export declares.
    func testSpokenTextNeverReachesTheLog() async throws {
        let chats = LockedValue<[String]>([])
        try await withEngine(chats: chats) { engine in
            // Loaded and warmed up: the warm-up's own lines are not this test's.
            _ = try await complete(engine, "abcdefghijklmnopqrstuvwxyz0123")
            let spoken = "Meet me at the Zanzibar cafe at noon."
            func logged(_ body: () async throws -> Void) async throws -> [String] {
                let start = DebugLog.shared.snapshot().last?.id ?? -1
                try await body()
                return DebugLog.shared.snapshot().filter { $0.id > start }.map { $0.message + " " + ($0.detail ?? "") }
            }
            let typed = try await logged { _ = try await engine.correct(selection: spoken, redactLog: false) }
            XCTAssertTrue(typed.contains { $0.contains("Zanzibar") }, "the check sees the text: \(typed)")
            let output = try XCTUnwrap(typed.compactMap { $0.firstMatch(of: #/raw: "([^"]+)"/#)?.1 }.last, "\(typed)")

            let dictated = try await logged { _ = try await engine.correct(selection: spoken, redactLog: true) }
            XCTAssertFalse(dictated.isEmpty)
            XCTAssertFalse(dictated.contains { $0.contains("Zanzibar") || $0.contains(output) }, "\(dictated)")

            var rewritten: String?
            let command = try await logged {
                rewritten = try await engine.rewrite(selection: spoken, instruction: "say it like a pirate")
            }
            let rewrite = try XCTUnwrap(rewritten)
            XCTAssertFalse(command.isEmpty)
            XCTAssertFalse(command.contains { $0.contains("Zanzibar") || $0.contains("pirate") || $0.contains(rewrite) },
                           "\(command)")
        }
    }

    // A context refresh prefills the prompt into the KV cache, ahead of the
    // keystroke — on a model resident or loading, leaving the shown
    // suggestion's logprob alone. An idle-unloaded model it leaves unloaded.
    func testAWarmedPromptPrefillsOnlyAModelInMemory() async throws {
        let loads = LockedValue(0)
        try await withEngine(loads: loads) { engine in
            let suggestion = try await complete(engine, "abcdefghijklmnopqrstuvwxyz0123")
            XCTAssertNotNil(suggestion)
            let shown = engine.lastFirstWordLogProb
            // Past one forward's worth of tokens, so the head is prefilled.
            let refreshed = "Zyxwvutsrqponmlkjihgfedcba9876543210zyxwvu1"
            engine.warmPrompt(for: CompletionRequest(textBeforeCaret: refreshed))
            var prefilled = false
            for _ in 0 ..< 500 {
                prefilled = cached(engine, refreshed)
                if prefilled { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(prefilled)
            XCTAssertEqual(engine.lastFirstWordLogProb, shown)

            for _ in 0 ..< 500 where engine.residency.primaryLoadedOrLoading {
                engine.releaseModelNow()
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertFalse(engine.residency.primaryLoadedOrLoading)
            engine.warmPrompt(for: CompletionRequest(textBeforeCaret: refreshed))
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertFalse(engine.residency.primaryLoadedOrLoading, "no load for a context refresh")
            XCTAssertEqual(loads.get(), 1)
        }
    }

    // A script the model never pays off in costs no decode; another script
    // the model has no rule for decodes as usual.
    func testASilentScriptCostsNoDecode() async throws {
        try await withEngine { engine in
            XCTAssertEqual(engine.silentScripts, [.kana])
            let kana = "かなかなかなかなかなかなかなかなかな。"
            let silent = try await complete(engine, kana)
            XCTAssertNil(silent)
            XCTAssertFalse(cached(engine, kana))
            let hebrew = "שלום לכם חברים יקרים מאוד."
            _ = try await complete(engine, hebrew)
            XCTAssertTrue(cached(engine, hebrew))
        }
    }

    // The instruct prompt: a gap to fill on a model that fills gaps, given
    // text after the caret; else a plain continuation — with the author's
    // profile and past continuations when there are any.
    func testTheInstructPromptCarriesTheGapThePersonaAndTheExamples() async throws {
        let text = "Let us meet at the cafe on Monday morning"
        let chats = LockedValue<[String]>([])
        try await withEngine("test/gemma-e4b", style: .instruct, chats: chats) { engine in
            engine.updateCompletion(length: .short, instructions: "Writes tersely.")
            var request = CompletionRequest(textBeforeCaret: text)
            request.textAfterCaret = "and then we left early."
            request.personalExamples = [.init(ctx: "see you", next: "tomorrow")]
            _ = try await engine.complete(request)
            let gap = try XCTUnwrap(chats.get().last)
            XCTAssertTrue(gap.contains("BEFORE: \(text)") && gap.contains("AFTER: and then we left early."), gap)
            XCTAssertTrue(gap.contains("Author profile") && gap.contains("Writes tersely."), gap)
            XCTAssertTrue(gap.contains("How the author continued") && gap.contains("Next: tomorrow"), gap)

            engine.updateCompletion(length: .short, instructions: "")
            _ = try await complete(engine, text)
            let plain = try XCTUnwrap(chats.get().last)
            XCTAssertTrue(plain.hasPrefix("Continue the text") && plain.hasSuffix("Text:\n\(text)"), plain)
            XCTAssertFalse(plain.contains("Author profile") || plain.contains("How the author continued"), plain)
        }
        try await withEngine("test/gemma-e2b", style: .instruct, chats: chats) { engine in
            var request = CompletionRequest(textBeforeCaret: text)
            request.textAfterCaret = "and then we left early."
            _ = try await engine.complete(request)
            XCTAssertTrue(try XCTUnwrap(chats.get().last).hasPrefix("Continue the text"), "no gap-filling below E4B")
        }
    }

    // Without MLX's Metal shaders an engine fails up front, loading
    // nothing, instead of crashing in C++ on its first load.
    func testAnEngineWithoutItsShadersFailsUpFront() throws {
        try withScratchHub {
            let loads = LockedValue(0)
            let engine = MLXEngine(modelID: "test/none", load: { _, _, _, _, _ in
                loads.mutate { $0 += 1 }
                return try tinyContainer()
            }, shadersPresent: false)
            defer { engine.shutdown() }
            guard case .failed = engine.state else { return XCTFail("\(engine.state)") }
            XCTAssertFalse(engine.residency.primaryLoadedOrLoading)
            XCTAssertNil(engine.residency.begin(.completion))
            XCTAssertEqual(loads.get(), 0)
        }
    }

    // The token cap: the length's, ×1.7 for mostly-Cyrillic text (twice the
    // tokens per word), capped harder in chat apps.
    func testTheTokenBudget() {
        func budget(_ text: String, _ length: CompletionLength, chat: Bool = false) -> Int {
            var request = CompletionRequest(textBeforeCaret: text)
            request.appBundleID = chat ? "com.tinyspeck.slackmacgap" : "com.apple.TextEdit"
            return MLXEngine.tokenBudget(for: request, length: length)
        }
        XCTAssertEqual(budget("See you at the meeting", .short), 6)
        XCTAssertEqual(budget("Увидимся на встрече", .short), 10)
        XCTAssertEqual(budget("Увидимся на встрече", .long), 37)
        XCTAssertEqual(budget("Увидимся на встрече", .long, chat: true), 13)
        XCTAssertEqual(budget("See you at the meeting", .long, chat: true), 8)
        XCTAssertEqual(budget("до", .short), 6, "too few letters to call the script")
        XCTAssertEqual(budget("привет 1234567890", .short), 10, "digits are no letters")
        XCTAssertEqual(budget("See you at the meeting, привет", .short), 6, "a Cyrillic minority")
    }
}

/// A tokenizer that records the length of every text it encodes.
private final class CountingTokenizer: MLXLMCommon.Tokenizer, @unchecked Sendable {
    let inner: any MLXLMCommon.Tokenizer
    let lengths = LockedValue<[Int]>([])
    init(_ inner: any MLXLMCommon.Tokenizer) { self.inner = inner }
    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        lengths.mutate { $0.append(text.count) }
        return inner.encode(text: text, addSpecialTokens: addSpecialTokens)
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
