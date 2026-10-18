import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import XCTest
@testable import Pretype

/// The decode loop (`MLXEngine.generate`) on a tiny Gemma, on the CPU. Each
/// reuse test compares a warm decode with a cold one token by token: the
/// text and every shown token's log-probability. The tiny model's greedy
/// text barely moves with its context, the log-probabilities do.
final class GenerationTests: MLXTestCase {
    /// 96 one-character tokens.
    private let prompt = String(repeating: "the weekly update covers hiring and the roadmap ", count: 2)

    private struct Run {
        let text: String
        let logProbs: [Float]
    }

    /// `record`: collect each token's log-probability — off, the gate or
    /// trim under test is the only reason the decode records any.
    private func generate(_ container: ModelContainer, _ prompt: String, maxTokens: Int = 6,
                          cache: MLXEngine.PromptCache? = nil, prefillOnly: Bool = false,
                          gate: Double? = nil, trim: Float? = nil, entropy: Float? = nil, record: Bool = true,
                          partials: LockedValue<[String]>? = nil) async throws -> Run {
        let logProbs = LockedValue<[Float]>([])
        let text = try await MLXEngine.generate(
            in: container, makeTokens: { $0.tokenizer.encode(text: prompt) },
            parameters: GenerateParameters(maxTokens: maxTokens, temperature: 0), promptCache: cache,
            tokenLogProbSink: record ? logProbs : nil, trimLogProb: trim, trimEntropy: entropy, gateLogProb: gate,
            prefillOnly: prefillOnly, onPartial: partials.map { box in { text in box.mutate { $0.append(text) } } })
        return Run(text: text, logProbs: logProbs.get())
    }

    /// The same text, and each token's log-probability within float noise.
    private func assertSame(_ warm: Run, _ cold: Run, _ message: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(warm.text, cold.text, message, file: file, line: line)
        XCTAssertEqual(warm.logProbs.count, cold.logProbs.count, message, file: file, line: line)
        for (index, (w, c)) in zip(warm.logProbs, cold.logProbs).enumerated() {
            XCTAssertEqual(w, c, accuracy: 1e-4, "\(message), token \(index)", file: file, line: line)
        }
    }

    /// `text` with the character at `index` changed.
    private func edited(_ text: String, at index: Int) -> String {
        var characters = Array(text)
        characters[index] = characters[index] == "Q" ? "R" : "Q"
        return String(characters)
    }

    // Greedy decoding gives the same tokens every time, one character a
    // token here, and stops at the token limit — a shorter limit is a prefix.
    func testGreedyDecodeIsDeterministicAndStopsAtTheLimit() async throws {
        let container = try tinyContainer()
        let first = try await generate(container, prompt, maxTokens: 12)
        assertSame(try await generate(container, prompt, maxTokens: 12), first, "a second run")
        XCTAssertEqual(first.text.count, 12)
        XCTAssertEqual(first.logProbs.count, 12)
        let short = try await generate(container, prompt, maxTokens: 5)
        XCTAssertEqual(short.text, String(first.text.prefix(5)))
        let empty = try await MLXEngine.generate(in: container, makeTokens: { _ in [] },
                                                 parameters: GenerateParameters(maxTokens: 5, temperature: 0), promptCache: nil)
        XCTAssertEqual(empty, "", "an empty prompt decodes nothing")
    }

    // A turn ends, unshown, at an EOS id: the configuration's, or the
    // tokenizer's own EOS token.
    func testDecodeStopsAtEOS() async throws {
        let cold = try await generate(try tinyContainer(), prompt, maxTokens: 12).text
        let ids = cold.compactMap { CharTokenizer.alphabet.firstIndex(of: $0) }
        // The first token that hasn't come up before it: an EOS there stops
        // the decode there and nowhere earlier.
        let stop = try XCTUnwrap((1 ..< ids.count).first { !ids[..<$0].contains(ids[$0]) })
        let byConfig = try await generate(try tinyContainer(eos: [ids[stop]]), prompt, maxTokens: 12)
        XCTAssertEqual(byConfig.text, String(cold.prefix(stop)))
        let byTokenizer = try await generate(try tinyContainer(tokenizerEOS: ids[stop]), prompt, maxTokens: 12)
        XCTAssertEqual(byTokenizer.text, String(cold.prefix(stop)))
    }

    // A window wider than the prompt: the decode leaves a live cache, which
    // the next keystroke trims back to the shared prefix — past the tokens
    // it generated, or to an edit inside the prompt — and decodes on; typing
    // the suggestion itself reuses the tokens the decode fed back.
    func testATrimmedLiveCacheDecodesLikeAColdRun() async throws {
        let container = try tinyContainer(window: 512)
        let probe = MLXEngine.PromptCache()
        _ = try await generate(container, prompt, cache: probe)
        let reuse = try XCTUnwrap(probe.take(for: CharTokenizer().encode(text: prompt + "next week")))
        XCTAssertEqual(reuse.reused, 96, "the live cache, trimmed back past the generated tokens")
        XCTAssertNil(reuse.checkpoint, "no ring to wrap: no checkpoint")
        let typed = MLXEngine.PromptCache()
        let suggestion = try await generate(container, prompt, cache: typed)
        let sampled = suggestion.text.compactMap { CharTokenizer.alphabet.firstIndex(of: $0) }
        XCTAssertEqual(typed.take(for: CharTokenizer().encode(text: prompt) + sampled)?.reused, 96 + sampled.count - 1,
                       "typing the suggestion reuses its tokens, all but the last (never fed back)")

        let cache = MLXEngine.PromptCache()
        _ = try await generate(container, prompt, cache: cache)
        for next in [prompt + "next week", prompt + "next week and then", edited(prompt, at: 40)] {
            assertSame(try await generate(container, next, cache: cache), try await generate(container, next), next)
        }
    }

    // The warm decode reads what the cache holds: another prompt's state,
    // filed under this prompt's tokens, changes what it decodes.
    func testAWarmDecodeReadsTheCache() async throws {
        let container = try tinyContainer(window: 512)
        let other = edited(prompt, at: 0)
        let cache = MLXEngine.PromptCache()
        _ = try await generate(container, other, cache: cache)
        let stray = try XCTUnwrap(cache.take(for: CharTokenizer().encode(text: other + "x")))
        let tokens = CharTokenizer().encode(text: prompt)
        cache.store(forFullTokens: tokens, live: .init(tokens: Array(tokens.prefix(stray.reused)), cache: stray.cache),
                    checkpoint: nil)
        let next = prompt + "next week"
        let warm = try await generate(container, next, cache: cache), cold = try await generate(container, next)
        XCTAssertTrue(zip(warm.logProbs, cold.logProbs).contains { abs($0 - $1) > 1e-3 },
                      "a decode on the stray state is no cold run")
    }

    // A window narrower than the prompt: its ring wraps and can't be
    // trimmed back, so the decode reuses the checkpoint it took 8 tokens
    // short of the prompt's end — for a longer prompt; and for one edited
    // before that checkpoint, it starts afresh.
    func testACheckpointDecodesLikeAColdRun() async throws {
        let container = try tinyContainer(window: 8)
        let probe = MLXEngine.PromptCache()
        _ = try await generate(container, prompt, cache: probe)
        let reuse = try XCTUnwrap(probe.take(for: CharTokenizer().encode(text: prompt + "next week")))
        XCTAssertEqual(reuse.reused, 88, "the checkpoint, 8 tokens short of the prompt's end")
        let typedOn = MLXEngine.PromptCache()
        for keystroke in [prompt, prompt + "n"] { _ = try await generate(container, keystroke, cache: typedOn) }
        XCTAssertEqual(typedOn.take(for: CharTokenizer().encode(text: prompt + "next week"))?.reused, 88,
                       "one checkpoint serves the keystrokes within one forward of it")
        XCTAssertNil(probe.take(for: CharTokenizer().encode(text: edited(prompt, at: 40))),
                     "an edit before the checkpoint leaves nothing to reuse")

        let cache = MLXEngine.PromptCache()
        _ = try await generate(container, prompt, cache: cache)
        for next in [prompt + "next week", prompt + "next week and then", edited(prompt, at: 40)] {
            assertSame(try await generate(container, next, cache: cache), try await generate(container, next), next)
        }
    }

    // A prompt that fits the ring but whose decode will wrap it needs its
    // checkpoint up front. And after an edit before that checkpoint — the old
    // one is no prefix any more — the decode takes a fresh one at the edited
    // prompt, not the stale one, so the keystroke after reuses past the edit.
    func testACheckpointForADecodeThatWillWrapTheRing() async throws {
        let container = try tinyContainer(window: 40)
        let start = String(prompt.prefix(30)), edit = edited(String(prompt.prefix(30)), at: 18)
        func replay(_ prompts: [String]) async throws -> MLXEngine.PromptCache {
            let cache = MLXEngine.PromptCache()
            for prompt in prompts { _ = try await generate(container, prompt, maxTokens: 12, cache: cache) }
            return cache
        }
        let first = try await replay([start])
        XCTAssertEqual(first.take(for: CharTokenizer().encode(text: start + "x"))?.reused, 22,
                       "30 tokens in a 40-token ring, 12 more to decode: a checkpoint at 22")
        let afterEdit = try await replay([start, edit])
        XCTAssertEqual(afterEdit.take(for: CharTokenizer().encode(text: edit + "x"))?.reused, 22,
                       "the edit's own checkpoint, past the edit at 18")

        let cache = try await replay([start])
        for next in [edit, edit + "x"] {
            assertSame(try await generate(container, next, maxTokens: 12, cache: cache),
                       try await generate(container, next, maxTokens: 12), next)
        }
    }

    // A context refresh prefills the prompt ahead of the keystroke
    // (`warmPrompt`): nothing is decoded, and the next keystroke decodes on
    // from that prefill as a cold run would — on a live cache and on a
    // checkpoint.
    func testAWarmedPromptDecodesLikeAColdRun() async throws {
        for window in [512, 8] {
            let container = try tinyContainer(window: window)
            let cache = MLXEngine.PromptCache()
            let warmed = try await generate(container, prompt, cache: cache, prefillOnly: true)
            XCTAssertEqual(warmed.text, "")
            for next in [prompt + "next week", prompt + "next week and then"] {
                assertSame(try await generate(container, next, cache: cache), try await generate(container, next),
                           "window \(window): \(next)")
            }
        }
    }

    // A layer that can't rewind (Qwen3.5's recurrent ones) leaves no live
    // cache to trim: the decode keeps a checkpoint 8 tokens short of the
    // prompt's end, even where no ring would wrap, and the next keystroke
    // decodes on from it as a cold run would.
    func testARecurrentLayerIsReusedThroughItsCheckpoint() async throws {
        let container = try tinyContainer(window: 512, recurrent: true)
        let probe = MLXEngine.PromptCache()
        _ = try await generate(container, prompt, cache: probe)
        let reuse = try XCTUnwrap(probe.take(for: CharTokenizer().encode(text: prompt + "next week")))
        XCTAssertEqual(reuse.reused, 88)
        XCTAssertNotNil(reuse.checkpoint)

        let cache = MLXEngine.PromptCache()
        _ = try await generate(container, prompt, cache: cache)
        for next in [prompt + "next week", prompt + "next week and then"] {
            assertSame(try await generate(container, next, cache: cache), try await generate(container, next), next)
        }
    }

    // Prompt lookup (the fix's decode) drafts from the prompt and keeps only
    // what greedy decoding would have produced: the same text. Not on a
    // layer that can't rewind a rejected draft — there it decodes plainly.
    func testALookupDecodeMatchesThePlainOne() async throws {
        // A ring of 104 holds the 96-token prompt and runs out mid-decode:
        // there a draft that couldn't be rewound must not be tried.
        for container in [try tinyContainer(window: 512), try tinyContainer(window: 512, recurrent: true),
                          try tinyContainer(window: 104)] {
            func decode(lookup: Bool) async throws -> String {
                try await MLXEngine.generate(
                    in: container, makeTokens: { $0.tokenizer.encode(text: self.prompt) },
                    parameters: GenerateParameters(maxTokens: 16, temperature: 0), promptCache: nil, lookup: lookup)
            }
            let plain = try await decode(lookup: false)
            let drafted = try await decode(lookup: true)
            XCTAssertEqual(drafted, plain)
        }
    }

    // Prompt lookup on a model that always predicts its input token + 1, so
    // greedy decoding copies an ascending run: a draft greedy agrees with is
    // taken whole in one forward; one it stops agreeing with is cut there,
    // its rejected tail rewound out of the cache; the draft never runs past
    // the token budget.
    func testPromptLookupTakesWhatGreedyAgreesWith() {
        func run(_ prompt: [Int], maxTokens: Int) -> (tokens: [Int], forwards: Int, cached: Int) {
            let model = SuccessorModel()
            let cache: [KVCache] = [KVCacheSimple()]
            _ = model(MLXArray(prompt.dropLast().map { Int32($0) })[.newAxis], cache: cache)
            model.forwards = 0
            var lookup = MLXEngine.PromptLookupIterator(input: [prompt[prompt.count - 1]], prompt: prompt, model: model,
                                                        cache: cache, maxTokens: maxTokens)
            var tokens: [Int] = []
            while let token = lookup.next() { tokens.append(token) }
            return (tokens, model.forwards, cache[0].offset)
        }
        // After the last 5, the prompt goes on 6…13: the 8-token draft and
        // greedy's own next pick, then one more token alone.
        let run1 = run(Array(1 ... 20) + [5], maxTokens: 10)
        XCTAssertEqual(run1.tokens, Array(6 ... 15))
        XCTAssertEqual(run1.forwards, 2)
        XCTAssertEqual(run1.cached, 21 + 9, "the prompt and every token fed back but the last")
        let run2 = run(Array(1 ... 20) + [5], maxTokens: 9)
        XCTAssertEqual(run2.tokens, Array(6 ... 14))
        XCTAssertEqual(run2.forwards, 1, "a draft of budget − 1 and greedy's pick fill the budget")
        let run3 = run(Array(1 ... 20) + [5], maxTokens: 8)
        XCTAssertEqual(run3.tokens, Array(6 ... 13))
        // After the last 3 the prompt goes on 4, 9: greedy takes the 4 and
        // its own 5; the rejected 9… leaves the cache.
        let run4 = run([1, 2, 3, 4, 9, 9, 7, 3], maxTokens: 4)
        XCTAssertEqual(run4.tokens, [4, 5, 6, 7])
        XCTAssertEqual(run4.cached, 8 + 3)
    }

    /// Decodes "Tv_Z11111111": a two-letter first word, closed by "_" —
    /// the gate's unit, its boundary token included.
    private let wordPrompt = "week-plan-re_do-hiring-the-and-"

    // The logprob gate decides once the first word is decoded: under τ the
    // decode stops there, unshown; over it the text streams from that word on.
    func testTheGateDecidesAtTheFirstWord() async throws {
        let container = try tinyContainer()
        let free = try await generate(container, wordPrompt, maxTokens: 12)
        let firstWord = try XCTUnwrap(free.text.firstIndex(of: "_")).utf16Offset(in: free.text) + 1
        XCTAssertEqual(firstWord, 3)
        let mean = Double(free.logProbs.prefix(firstWord).reduce(0, +)) / Double(firstWord)

        let shown = LockedValue<[String]>([])
        let passed = try await generate(container, wordPrompt, maxTokens: 12, gate: mean - 0.05, record: false,
                                        partials: shown)
        XCTAssertEqual(passed.text, free.text)
        XCTAssertEqual(shown.get().first, String(free.text.prefix(firstWord)), "nothing shown before the verdict")
        XCTAssertEqual(shown.get().last, free.text)

        let hidden = LockedValue<[String]>([])
        let stopped = try await generate(container, wordPrompt, maxTokens: 12, gate: mean + 0.05, record: false,
                                         partials: hidden)
        XCTAssertEqual(stopped.text, String(free.text.prefix(firstWord)), "no decode past the verdict")
        XCTAssertEqual(hidden.get(), [])

        // The first-word mean on its own: what the journal stores.
        let firstWordMean = LockedValue<Double?>(nil)
        _ = try await MLXEngine.generate(
            in: container, makeTokens: { $0.tokenizer.encode(text: self.wordPrompt) },
            parameters: GenerateParameters(maxTokens: 12, temperature: 0), promptCache: nil, logProbSink: firstWordMean)
        XCTAssertEqual(try XCTUnwrap(firstWordMean.get()), mean, accuracy: 1e-4)
    }

    // The confidence trim stops the decode at the first weak token past the
    // first word, so no partial runs past what the trimmed text shows; with
    // no weak token it cuts nothing.
    func testTheTrimStopsTheDecodeAtItsCut() async throws {
        let container = try tinyContainer()
        let free = try await generate(container, wordPrompt, maxTokens: 12)
        let weak = free.logProbs[3]
        XCTAssertLessThan(weak, free.logProbs[4], "the first token past the word is the weakest past it")

        let word = String(free.text.prefix(3))
        for (trim, entropy) in [(weak + 0.01, nil), (free.logProbs[2] + 0.01, nil), (nil, Float(0))] as [(Float?, Float?)] {
            let shown = LockedValue<[String]>([])
            let cut = try await generate(container, wordPrompt, maxTokens: 12, trim: trim, entropy: entropy,
                                         record: false, partials: shown)
            XCTAssertEqual(cut.text, word, "\(String(describing: trim)), \(String(describing: entropy))")
            XCTAssertEqual(shown.get().last, cut.text, "no partial past the cut, none short of it")
        }

        let whole = try await generate(container, wordPrompt, maxTokens: 12,
                                       trim: (free.logProbs.min() ?? 0) - 0.01, entropy: .infinity, record: false)
        XCTAssertEqual(whole.text, free.text)
    }

    // A decode whose text is not ours to print — the dictation tidy-up's —
    // logs lengths only, the trim line too.
    func testARedactedDecodeLogsNoText() async throws {
        let container = try tinyContainer()
        let free = try await generate(container, wordPrompt, maxTokens: 12)
        func run(raw: Bool) async throws -> (text: String, logged: [String]) {
            let start = DebugLog.shared.snapshot().last?.id ?? -1
            let text = try await MLXEngine.generate(
                in: container, makeTokens: { $0.tokenizer.encode(text: self.wordPrompt) },
                parameters: GenerateParameters(maxTokens: 12, temperature: 0), promptCache: nil,
                trimLogProb: free.logProbs[3] + 0.01, logRaw: raw)
            return (text, DebugLog.shared.snapshot().filter { $0.id > start }.map { $0.message + " " + ($0.detail ?? "") })
        }
        let typed = try await run(raw: true)
        let shown = typed.text.debugDescription
        XCTAssertTrue(typed.logged.contains { $0.contains("confidence-trim") && $0.contains(shown) }, "\(typed.logged)")
        let spoken = try await run(raw: false)
        XCTAssertEqual(spoken.text, typed.text)
        XCTAssertTrue(spoken.logged.contains { $0.contains("confidence-trim") }, "still logged")
        XCTAssertFalse(spoken.logged.contains { $0.contains(shown) }, "\(spoken.logged)")
    }

    // A trimmable cache read past where a new checkpoint goes is rewound to
    // it, so the checkpoint keeps its margin of 8 tokens — never below 16,
    // where it would be no checkpoint at all — and the decode on it reads as
    // a cold one would.
    func testACheckpointTakenOverALiveCacheKeepsItsMargin() async throws {
        // A ring of 40: 26 tokens and 2 decoded fit, 28 and 16 more wrap it.
        let container = try tinyContainer(window: 40)
        let short = String(prompt.prefix(26)), long = String(prompt.prefix(28))
        let cache = MLXEngine.PromptCache()
        _ = try await generate(container, short, maxTokens: 2, cache: cache)
        assertSame(try await generate(container, long, maxTokens: 16, cache: cache),
                   try await generate(container, long, maxTokens: 16), "on the rewound cache")
        XCTAssertEqual(cache.take(for: CharTokenizer().encode(text: long + "x"))?.reused, 20)

        // A ring of 24: 8 short of 20 tokens is under 16, so the checkpoint
        // stays where the cache already stood.
        let small = try tinyContainer(window: 24), smallCache = MLXEngine.PromptCache()
        _ = try await generate(small, String(prompt.prefix(18)), maxTokens: 2, cache: smallCache)
        _ = try await generate(small, String(prompt.prefix(20)), maxTokens: 12, cache: smallCache)
        XCTAssertEqual(smallCache.take(for: CharTokenizer().encode(text: String(prompt.prefix(20)) + "x"))?.reused, 18)
    }

    // A streamed decode shows each step's text, growing, and ends on the
    // very text the call returns.
    func testStreamingEndsOnTheReturnedText() async throws {
        let partials = LockedValue<[String]>([])
        let run = try await generate(try tinyContainer(), prompt, maxTokens: 8, partials: partials)
        let shown = partials.get()
        XCTAssertEqual(shown.last, run.text)
        XCTAssertEqual(shown.count, run.text.count)
        for (shorter, longer) in zip(shown, shown.dropFirst()) {
            XCTAssertTrue(longer.hasPrefix(shorter))
        }
    }
}

/// A model whose every next token is its input token + 1 — greedy decoding
/// counts up — that keeps a cache's offset honest and counts its forwards.
private final class SuccessorModel: Module, LLMModel {
    var forwards = 0

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        forwards += 1
        let n = inputs.dim(1)
        let filler = MLXArray.zeros([1, 1, n, 1])
        _ = cache?.first?.update(keys: filler, values: filler)
        let next = (inputs.reshaped([n]) + 1) % 64
        return MLX.where(MLXArray(0 ..< 64).reshaped([1, 1, 64]) .== next.reshaped([1, n, 1]), Float(1), Float(0))
    }

    func newCache(parameters: GenerateParameters?) throws -> [any KVCache] { [KVCacheSimple()] }
    var loraLayers: [Module] { [] }
}
