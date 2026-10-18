import XCTest
@testable import Pretype

final class GatesTests: XCTestCase {
    // The output gate decides what raw model text reaches the user's keystrokes —
    // the single most safety-critical pure function in the app. Pin its rules.
    func testCompletionGatesPostProcess() {
        func pp(_ raw: String, prompt: String = "hello world", trailingSpaces: Int = 0,
                endsMidWord: Bool = false, endsCompleteWord: Bool = false,
                after: String = "") -> String? {
            CompletionGates.postProcess(
                raw, prompt: prompt, trailingSpaces: trailingSpaces,
                endsMidWord: endsMidWord, endsCompleteWord: endsCompleteWord,
                textAfterCaret: after)
        }

        // Control characters / the replacement char must never be typed back.
        XCTAssertNil(pp("a\u{07}b"))
        XCTAssertNil(pp("te\u{FFFD}xt"))
        // A CJK derail for a non-CJK prompt is rejected.
        XCTAssertNil(pp("你好 there", prompt: "hello world"))
        // Degenerate character repetition is rejected.
        XCTAssertNil(pp("юююю", prompt: "привет как дела друзья"))
        // A suggestion that fully echoes the typed text is rejected.
        XCTAssertNil(pp("hello world", prompt: "hello world"))
        // A partial echo of the prompt tail is stripped, keeping the continuation.
        XCTAssertEqual(pp(" world hi", prompt: "hello world"), " hi")
        // With a typed trailing space, a continuation must carry its own separator…
        XCTAssertNil(pp("morrow", prompt: "to", trailingSpaces: 1))
        // …and a leading space the model adds is normalized away.
        XCTAssertEqual(pp(" there", prompt: "hello", trailingSpaces: 1), "there")
        // Mid-word caret: a new word (leading space) is dropped unless the run is a
        // complete word, where the space is the separator the user hasn't typed yet.
        XCTAssertNil(pp(" world", prompt: "hel", endsMidWord: true, endsCompleteWord: false))
        XCTAssertEqual(pp(" world", prompt: "hello", endsMidWord: true, endsCompleteWord: true), " world")
        // Don't re-suggest what already follows the caret.
        XCTAssertNil(pp("world", prompt: "hello", after: "world tour"))
        // Trim at the first sentence boundary.
        XCTAssertEqual(pp("sure. and more", prompt: "ok"), "sure.")
        // …but never at an ender in first place: ". Then" goes on to its own end.
        XCTAssertEqual(pp(". Then we left. And more", prompt: "We arrived late"), ". Then we left.")
        // A CJK suggestion for a CJK prompt is no derail.
        XCTAssertEqual(pp("看看朋友", prompt: "我们明天去北京"), "看看朋友")
    }

    // A language flip is judged once the suggestion holds 12 characters: an
    // English continuation of Russian text is a derail, a short one isn't
    // enough to tell.
    func testALanguageFlipIsRejectedOnceThereIsEnoughToJudge() {
        func pp(_ raw: String, prompt: String) -> String? {
            CompletionGates.postProcess(raw, prompt: prompt, trailingSpaces: 0, endsMidWord: false,
                                        textAfterCaret: "", logRejects: false)
        }
        let russian = "Привет, как у тебя дела сегодня? Я хотел спросить про встречу"
        XCTAssertNil(pp(" and then we will talk about the project", prompt: russian))
        XCTAssertEqual(pp(" в пятницу утром у нас в офисе", prompt: russian), " в пятницу утром у нас в офисе")
        XCTAssertEqual(pp(" and so", prompt: russian), " and so", "too short to judge")
    }

    // An instruct answer comes back flush: the gate restores the separator
    // after a finished word (the space not typed yet) and drops it after a
    // typed one; a partial word's remainder stays glued on.
    func testAnInstructAnswerGetsItsSeparatorBack() throws {
        func gate(_ typed: String, completeWord: Bool) throws -> (String) -> String? {
            let request = CompletionRequest(textBeforeCaret: typed, endsOnCompleteWord: completeWord)
            return try XCTUnwrap(PreparedPrompt(typed, request: request, midWordFloor: 5, boundaryFloor: 8))
                .gate(cleanInstruct: true, logRejects: false)
        }
        XCTAssertEqual(try gate("See you at the", completeWord: true)("\"next week\""), " next week")
        XCTAssertEqual(try gate("See you at the ", completeWord: true)("next week"), "next week")
        XCTAssertEqual(try gate("See you at th", completeWord: false)("e gate"), "e gate")
        // A quoted answer that keeps its own space inside gets no second one.
        XCTAssertEqual(try gate("See you at the", completeWord: true)("\" next week\""), " next week")
        XCTAssertEqual(try gate("See you at the ", completeWord: true)("  next week \n"), "next week")
        // After a sentence or clause mark the separator comes back too
        // ("there." + "How" glued on the Apple Intelligence and API paths).
        XCTAssertEqual(try gate("Hello there.", completeWord: true)("How are you"), " How are you")
        XCTAssertEqual(try gate("Hi there Ann,", completeWord: false)("how are you"), " how are you")
        // …but not after anything else that ends no word: "5" + "pm".
        XCTAssertEqual(try gate("Call me at 5", completeWord: true)("pm"), "pm")
        // A base continuation brings its own separator and keeps its quotes.
        let typed = "She said "
        let base = try XCTUnwrap(PreparedPrompt(typed, request: CompletionRequest(textBeforeCaret: typed, endsOnCompleteWord: true),
                                                midWordFloor: 5, boundaryFloor: 8)).gate(cleanInstruct: false)
        XCTAssertEqual(base(" \"yes\""), "\"yes\"")
    }

    // What the prompt says about the caret: the separator typed, mid-word
    // or not, a finished word or not — and nothing to encode at all.
    func testThePreparedPromptReadsTheCaret() throws {
        func prepared(_ typed: String, completeWord: Bool = true) -> PreparedPrompt? {
            PreparedPrompt(typed, request: CompletionRequest(textBeforeCaret: typed, endsOnCompleteWord: completeWord),
                           midWordFloor: 5, boundaryFloor: 8)
        }
        let spaced = try XCTUnwrap(prepared("See you at the  "))
        XCTAssertEqual(spaced.text, "See you at the")
        XCTAssertEqual(spaced.trailingSpaces, 2)
        XCTAssertFalse(spaced.endsMidWord)
        XCTAssertFalse(spaced.endsCompleteWord)
        let ended = try XCTUnwrap(prepared("See you there."))
        XCTAssertFalse(ended.endsMidWord)
        XCTAssertFalse(ended.endsCompleteWord)
        let partial = try XCTUnwrap(prepared("See you at th", completeWord: false))
        XCTAssertTrue(partial.endsMidWord)
        XCTAssertFalse(partial.endsCompleteWord)
        XCTAssertTrue(try XCTUnwrap(prepared("See you at the")).endsCompleteWord)
        XCTAssertNil(prepared(String(repeating: " ", count: 10)), "nothing left to encode")
        // The floors: 5 characters mid-word, 8 at a boundary.
        XCTAssertNil(prepared("Hell"))
        XCTAssertNotNil(prepared("Hello"))
        XCTAssertNil(prepared("Hi you "))
        XCTAssertNotNil(prepared("Hi you, "))
        // The personal preamble rides the encoded text only.
        let request = CompletionRequest(textBeforeCaret: "See you at the")
        let withExamples = try XCTUnwrap(PreparedPrompt("See you at the", request: request, midWordFloor: 5, boundaryFloor: 8,
                                                        preamble: "see you then"))
        XCTAssertEqual(withExamples.text, "See you at the")
        XCTAssertEqual(withExamples.generationText, "see you then\n\nSee you at the")
    }

    // The gate's finer rules: the first line only, the after-caret
    // duplicate from three characters on, CJK in the prompt's last 200
    // characters, kana and Hangul as derails, an all-blank answer.
    func testTheGatesFinerRules() {
        func pp(_ raw: String, prompt: String = "hello world", after: String = "") -> String? {
            CompletionGates.postProcess(raw, prompt: prompt, trailingSpaces: 0, endsMidWord: false,
                                        textAfterCaret: after, logRejects: false)
        }
        XCTAssertEqual(pp(" and more\nnext line"), " and more")
        XCTAssertNil(pp("\nnext line"), "an answer that opens a new line has nothing for this one")
        XCTAssertEqual(pp(" ab", after: "ab"), " ab", "two characters after the caret are no duplicate")
        XCTAssertNil(pp(" abc", after: " abc"), "three are")
        XCTAssertEqual(pp(" tour", after: "world tour"), " tour")
        let head = "abcdefghijklmnopqrstuvwx"
        XCTAssertNil(pp(head + "yz", prompt: "1234567890", after: head + "Q"), "the first 24 characters decide")
        XCTAssertNil(pp("   "))
        XCTAssertNil(pp("你好", prompt: "中" + String(repeating: "a ", count: 100)), "CJK only in the last 200")
        XCTAssertNil(pp("こんにちは"))
        XCTAssertNil(pp("안녕하세요"))
    }

    // Echo stripping reads the prompt's last 200 characters and 15 words,
    // word by word: a doubled space is no repeat.
    func testEchoStrippingWindow() {
        func pp(_ raw: String, prompt: String) -> String? {
            CompletionGates.postProcess(raw, prompt: prompt, trailingSpaces: 0, endsMidWord: false,
                                        textAfterCaret: "", logRejects: false)
        }
        let cut = "wonderful" + String(repeating: " ", count: 196)
        XCTAssertEqual(pp(" rful thing", prompt: cut), " thing", "\"rful\" is the tail's first word")
        let words = (1 ... 20).map { "w\($0)" }
        let sixteen = " " + words.suffix(16).joined(separator: " ") + " next"
        XCTAssertEqual(pp(sixteen, prompt: words.joined(separator: " ")), sixteen, "past 15 words")
        let fifteen = " " + words.suffix(15).joined(separator: " ") + " next"
        XCTAssertEqual(pp(fifteen, prompt: words.joined(separator: " ")), " next")
        XCTAssertEqual(pp(" at  the cafe", prompt: "see you at the"), " at  the cafe")
    }

    // The language flip judges 12 characters and more, on the prompt's last
    // 160 characters.
    func testTheLanguageFlipsEdges() {
        func pp(_ raw: String, prompt: String) -> String? {
            CompletionGates.postProcess(raw, prompt: prompt, trailingSpaces: 0, endsMidWord: false,
                                        textAfterCaret: "", logRejects: false)
        }
        let russian = "Привет, как у тебя дела сегодня? Я хотел спросить про встречу"
        XCTAssertEqual(pp(" I love you", prompt: russian), " I love you", "11 characters")
        XCTAssertNil(pp(" and then we", prompt: russian), "12 characters")
        let farBack = "ы" + String(repeating: " ", count: 160)
        XCTAssertEqual(pp(" and then we will talk", prompt: farBack), " and then we will talk")
    }

    // A rejection logs its reason and the raw text — unless the caller asked
    // for quiet (a stream's early partials); a final gate logs by default.
    func testARejectionIsLogged() throws {
        func logged(_ body: () -> Void) -> [DebugEntry] {
            let start = DebugLog.shared.snapshot().last?.id ?? -1
            body()
            return DebugLog.shared.snapshot().filter { $0.id > start && $0.category == "GATE" }
        }
        let loud = logged {
            XCTAssertNil(CompletionGates.postProcess("a\u{07}b", prompt: "hello", trailingSpaces: 0, endsMidWord: false,
                                                     textAfterCaret: ""))
        }
        XCTAssertEqual(loud.count, 1)
        XCTAssertTrue(loud.first?.detail?.contains("a\\u{07}b") ?? false, "\(loud)")
        XCTAssertTrue(logged {
            XCTAssertNil(CompletionGates.postProcess("a\u{07}b", prompt: "hello", trailingSpaces: 0, endsMidWord: false,
                                                     textAfterCaret: "", logRejects: false))
        }.isEmpty)
        let typed = "See you at the "
        let gate = try XCTUnwrap(PreparedPrompt(typed, request: CompletionRequest(textBeforeCaret: typed, endsOnCompleteWord: true),
                                                midWordFloor: 5, boundaryFloor: 8)).gate(cleanInstruct: true)
        XCTAssertEqual(logged { XCTAssertNil(gate("   ")) }.count, 1)
    }

    // The script a prompt is typed in: the most frequent class of the last
    // 64 scalars, Latin and friends winning ties; any kana folds Han in.
    func testTheGateScriptCounts() {
        XCTAssertEqual(GateScript.of("a中文"), .han)
        XCTAssertNil(GateScript.of("ab中文"), "a tie goes to the rest")
        XCTAssertEqual(GateScript.of("a" + String(repeating: "中", count: 32) + String(repeating: "b", count: 31) + " "), .han,
                       "the 65th scalar from the end is out")
        XCTAssertNil(GateScript.of("abc中文"))
        XCTAssertNil(GateScript.of("abcかな"))
        XCTAssertNil(GateScript.of("abc안녕"))
        XCTAssertNil(GateScript.of("abcمر"))
        XCTAssertNil(GateScript.of("abcשל"))
        XCTAssertEqual(GateScript.of("中文中ab"), .han)
        XCTAssertEqual(GateScript.of("今日は"), .kana, "one kana makes it Japanese")
        XCTAssertEqual(GateScript.of("か"), .kana)
    }

    func testLevenshteinDistance() {
        XCTAssertTrue(CorrectionGates.isMinimalCorrection(original: "teh", fixed: "the"))
        XCTAssertTrue(CorrectionGates.isMinimalCorrection(original: "recei", fixed: "receive"))
        XCTAssertTrue(CorrectionGates.isMinimalCorrection(original: "привет", fixed: "привет!"))
        
        // Massive rewrites should be rejected
        XCTAssertFalse(CorrectionGates.isMinimalCorrection(original: "hello how are you", fixed: "goodbye my friend"))

        let minimal = CorrectionGates.isMinimalCorrection
        // Up to 12 characters, 70% may change (a transposition in a short
        // word is 67%); past that, half.
        XCTAssertTrue(minimal("abcdefghij", "abcXXXXXXX"), "7 of 10")
        XCTAssertTrue(minimal("abcdefghijkl", "abcdXXXXXXXX"), "8 of 12")
        XCTAssertFalse(minimal("abcdefghijklm", "abcdeXXXXXXXX"), "8 of 13")
        XCTAssertTrue(minimal("abcdefghijklmnopqrst", "abcdefghijXXXXXXXXXX"), "10 of 20")
        XCTAssertFalse(minimal("abcdefghijklmnopqrst", "abcdefghiXXXXXXXXXXX"), "11 of 20")
        // Doubled or halved is no fix, however few the edits.
        XCTAssertTrue(minimal("cat", "cat ok"))
        XCTAssertFalse(minimal("cat", "cat food"))
        XCTAssertTrue(minimal("cat ok", "cat"))
        XCTAssertFalse(minimal("cats food", "cat"))
        XCTAssertFalse(minimal("", "x"))
        XCTAssertFalse(minimal("x", " "))
        // Edits cost one each — a deletion too.
        XCTAssertTrue(minimal("abcdef", "abc"), "3 deletions of 6")
        XCTAssertFalse(minimal("abcdefgh", "wxyz"), "4 deletions and 4 substitutions of 8")
        XCTAssertTrue(minimal("abc", "abcdef"), "3 insertions of 6")
    }

    // ⌥⇥ on a selection: one line of up to 500 characters goes to the
    // model with the directive and a budget of its length (64 at least);
    // the answer comes back cleaned up, and an unchanged or rewritten one
    // is nothing to offer.
    func testTheFixGuardsWhatItAsksAndWhatComesBack() async throws {
        var asked: [(prompt: String, maxTokens: Int)] = []
        func fix(_ selection: String, _ answer: String?) async throws -> String? {
            try await CorrectionGates.fix(selection, redactLog: false, logTag: "TEST") { prompt, maxTokens in
                asked.append((prompt, maxTokens))
                return answer
            }
        }
        let fixed = try await fix("  teh  ", " \"the\"\nmore")
        XCTAssertEqual(fixed, "the")
        XCTAssertEqual(asked.last?.prompt, CorrectionGates.correctionDirective + "\n\nteh")
        XCTAssertEqual(asked.last?.maxTokens, 64)
        let edge = String(repeating: "x", count: 500)
        _ = try await fix(edge, nil)
        XCTAssertEqual(asked.last?.maxTokens, 500)
        let before = asked.count
        for selection in [edge + "x", "two\nlines", "  "] {
            let none = try await fix(selection, "anything")
            XCTAssertNil(none, selection)
        }
        XCTAssertEqual(asked.count, before, "never asked")

        let unchanged = try await fix("Hello there.", "Hello there.")
        XCTAssertNil(unchanged)
        let empty = try await fix("Hello there.", "")
        XCTAssertNil(empty)
        let rewritten = try await fix("I will see you tomorrow", "We never met at all")
        XCTAssertNil(rewritten)
        // A run-on cut starts near the original's end: a fix of two sentences
        // keeps both — cut at the first, it read as an over-rewrite.
        let two = try await fix("Hi ther. How are you?", "Hi there. How are you? Fine thanks")
        XCTAssertEqual(two, "Hi there. How are you?")
    }

    // A request called off while the model answered never surfaces its late
    // answer — fix, rewrite and reply alike.
    func testALateAnswerToACalledOffRequestIsDropped() async {
        let cancelling: CorrectionGates.Generate = { _, _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return "the answer"
        }
        let request = CompletionRequest(textBeforeCaret: "")
        let calls: [() async throws -> String?] = [
            { try await CorrectionGates.fix("teh", redactLog: false, logTag: "TEST", generate: cancelling) },
            { try await CorrectionGates.rewrite("hi", instruction: "formal", generate: cancelling) },
            { try await CorrectionGates.reply(to: "A: hi", request: request, instructions: "", generate: cancelling) },
        ]
        for call in calls {
            let result = await Task { try await call() }.result
            XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        }
    }

    // Voice command mode: the instruction and the text go to the model, the
    // rewrite comes back without its wrapping quotes and keeps its line
    // breaks; an unchanged one is nothing new.
    func testTheRewriteAsksWithTheInstructionAndDropsAnUnchangedAnswer() async throws {
        var asked: [(prompt: String, maxTokens: Int)] = []
        func rewrite(_ text: String, _ instruction: String, _ answer: String?) async throws -> String? {
            try await CorrectionGates.rewrite(text, instruction: instruction) { prompt, maxTokens in
                asked.append((prompt, maxTokens))
                return answer
            }
        }
        let formal = try await rewrite(" hi there ", " make it formal ", "«Good day.\nKind regards.»\n")
        XCTAssertEqual(formal, "Good day.\nKind regards.")
        XCTAssertTrue(asked.last?.prompt.hasPrefix("Rewrite the text below following this instruction: make it formal\n") ?? false)
        XCTAssertTrue(asked.last?.prompt.hasSuffix("\n\nhi there") ?? false)
        XCTAssertEqual(asked.last?.maxTokens, 64)
        let unchanged = try await rewrite("Hello there", "make it formal", " \"Hello there\" ")
        XCTAssertNil(unchanged)
        let blank = try await rewrite("Hello there", "make it formal", "  \n ")
        XCTAssertNil(blank)
        let long = String(repeating: "y", count: 2000)
        _ = try await rewrite(long, "shorter", "y")
        XCTAssertEqual(asked.last?.maxTokens, 1024)
        let before = asked.count
        for (text, instruction) in [(long + "y", "shorter"), ("  ", "shorter"), ("hi", " ")] {
            let none = try await rewrite(text, instruction, "anything")
            XCTAssertNil(none)
        }
        XCTAssertEqual(asked.count, before, "never asked")
    }

    // The reply chord: the reply prompt, a 200-token budget, the answer
    // cleaned up like any reply.
    func testTheReplyAsksForTheNextMessage() async throws {
        let request = CompletionRequest(textBeforeCaret: "")
        var asked: [(prompt: String, maxTokens: Int)] = []
        let reply = try await CorrectionGates.reply(to: "Ann: lunch at noon?", request: request, instructions: "") {
            asked.append(($0, $1))
            return "\"Sounds good, see you there\""
        }
        XCTAssertEqual(reply, "Sounds good, see you there")
        XCTAssertEqual(asked.first?.prompt, request.replyPrompt(conversation: "Ann: lunch at noon?", instructions: ""))
        XCTAssertEqual(asked.first?.maxTokens, 200)
        let declined = try await CorrectionGates.reply(to: "Ann: hi", request: request, instructions: "") { _, _ in nil }
        XCTAssertNil(declined)
    }

    // The dictation tidy-up hands the fix a spoken sentence, which
    // docs/privacy.md promises never reaches the log: a rejected fix logs
    // lengths only. A typed selection is logged as the export declares.
    func testARedactedFixLogsNoText() async throws {
        func entries(redact: Bool) async throws -> [DebugEntry] {
            let start = DebugLog.shared.snapshot().last?.id ?? -1
            let fixed = try await CorrectionGates.fix("I will see you tomorrow", redactLog: redact, logTag: "TEST") { _, _ in
                "We never met at all"
            }
            XCTAssertNil(fixed)
            return DebugLog.shared.snapshot().filter { $0.id > start }
        }
        func holdsText(_ entry: DebugEntry) -> Bool {
            let line = entry.message + (entry.detail ?? "")
            return line.contains("see you tomorrow") || line.contains("never met")
        }
        let typed = try await entries(redact: false)
        XCTAssertTrue(typed.contains(where: holdsText), "the check sees the text")
        let redacted = try await entries(redact: true)
        XCTAssertFalse(redacted.isEmpty, "the rejection is still logged")
        XCTAssertFalse(redacted.contains(where: holdsText), "\(redacted.map { $0.detail ?? "" })")
    }

    func testCleanCorrectionOutput() {
        XCTAssertEqual(CorrectionGates.cleanCorrectionOutput("\"hello\""), "hello")
        XCTAssertEqual(CorrectionGates.cleanCorrectionOutput("«привет»"), "привет")
        XCTAssertEqual(CorrectionGates.cleanCorrectionOutput("“test”"), "test")
        XCTAssertEqual(CorrectionGates.cleanCorrectionOutput("  trimmed  \n  newline  "), "trimmed")
        // A pair only, around something: an opening quote alone stays.
        XCTAssertEqual(CorrectionGates.cleanCorrectionOutput("\"a\""), "a")
        XCTAssertEqual(CorrectionGates.cleanCorrectionOutput("\"hello"), "\"hello")
        XCTAssertEqual(CorrectionGates.cleanCorrectionOutput("\"\""), "\"\"")
        XCTAssertEqual(CorrectionGates.cleanCorrectionOutput("\""), "\"")
    }

    func testTrimRunOn() {
        // The measured failure: exact fix + same-line junk (E4B-it-4bit, 39%
        // of eval-correct rows) — junk after the sentence terminal is cut.
        XCTAssertEqual(
            CorrectionGates.trimRunOn("Завтра уже уезжать, а я не собрал чемодан.гуглгугл",
                                      original: "Звтра уже уезжать, а я не собрал чемодан."),
            "Завтра уже уезжать, а я не собрал чемодан.")
        // Closing quote after the terminal survives the cut.
        XCTAssertEqual(
            CorrectionGates.trimRunOn("Он сказал: «Готово.» мусор",
                                      original: "Он сказал: «Готово.»"),
            "Он сказал: «Готово.»")
        // Apostrophes/quotes never start a cut (measured regressions).
        let apostrophe = "Il a rempli ma feuille d'impôts."
        XCTAssertEqual(CorrectionGates.trimRunOn(apostrophe, original: apostrophe), apostrophe)
        let tag = "You learned English from Miss Long, didn't you?"
        XCTAssertEqual(CorrectionGates.trimRunOn(tag + " junk", original: tag), tag)
        // Original without a sentence ending — the shape DICTATION always has,
        // since the system dictation model writes no punctuation. There is no
        // ending to anchor on, so length is the anchor: a tidy-up adds
        // punctuation and case, it does not add words.
        //
        // Reported from real use: strange characters at the end of a dictation,
        // CJK or stray Latin — an instruct model generating past its answer.
        let heard = "завтра уже уезжать а я не собрал чемодан"
        let tidied = "Завтра уже уезжать, а я не собрал чемодан."
        XCTAssertEqual(CorrectionGates.trimRunOn(tidied, original: heard), tidied,
                       "adding punctuation and case must survive untouched")
        XCTAssertEqual(CorrectionGates.trimRunOn(tidied + "你好世界你好世界", original: heard), tidied)
        XCTAssertEqual(CorrectionGates.trimRunOn(tidied + " fix.less than 100 words",
                                                 original: heard), tidied)
        // Junk with no sentence terminal anywhere to cut back to: hand back the
        // original, which makes the caller keep exactly what was heard.
        XCTAssertEqual(
            CorrectionGates.trimRunOn("Завтра уже уезжать а я не собрал чемодан 你好世界你好世界你好世界",
                                      original: heard),
            heard)
        // Growth within the budget is left alone — a short fix has room to
        // breathe (the +6 floor), so ordinary ⌥⇥ on a fragment still works.
        XCTAssertEqual(CorrectionGates.trimRunOn("fixed words", original: "fixd words"),
                       "fixed words")
        // …but a fragment the model CONTINUED instead of fixing is refused.
        XCTAssertEqual(CorrectionGates.trimRunOn("fixed words and then some more",
                                                 original: "fixd words"),
                       "fixd words")
        // Exact fix passes through untouched.
        let clean = "Nothing to trim here."
        XCTAssertEqual(CorrectionGates.trimRunOn(clean, original: clean), clean)
        // Multi-terminal endings ("...", "?!", "!!!") survive whole — the cut
        // keeps the full punctuation run, junk after it still goes.
        let ellipsis = "I don't know..."
        XCTAssertEqual(CorrectionGates.trimRunOn(ellipsis, original: "I dont know..."), ellipsis)
        XCTAssertEqual(CorrectionGates.trimRunOn(ellipsis + "junk", original: "I dont know..."),
                       ellipsis)
        XCTAssertEqual(CorrectionGates.trimRunOn("Really?!", original: "Realy?!"), "Really?!")
        let bang = "Ну и ну!!!"
        XCTAssertEqual(CorrectionGates.trimRunOn(bang, original: bang), bang)
        // A dot between digits is a decimal, not a sentence end.
        let decimal = "The total is 3.14159."
        XCTAssertEqual(CorrectionGates.trimRunOn(decimal, original: "The total is 3,14159."),
                       decimal)
        XCTAssertEqual(CorrectionGates.trimRunOn(decimal + "junk",
                                                 original: "The total is 3,14159."),
                       decimal)
        // Where the cut may start: 8 characters (a fifth, past 40) before
        // the original's end, never before the 5th character.
        XCTAssertEqual(CorrectionGates.trimRunOn("abcdefgh.jklmnop.", original: "abcdefghijklmnop."), "abcdefgh.jklmnop.")
        let fifty = String(repeating: "a", count: 49) + "."
        let early = String(repeating: "a", count: 40) + "." + String(repeating: "b", count: 20)
        XCTAssertEqual(CorrectionGates.trimRunOn(early, original: fifty), String(repeating: "a", count: 40) + ".")
        XCTAssertEqual(CorrectionGates.trimRunOn("abcd. efgh.", original: "ab."), "abcd.")
        XCTAssertEqual(CorrectionGates.trimRunOn("ab. cdefgh.", original: "ab."), "ab. cdefgh.")
        // A decimal dot is no end — at the very end of the text neither, and
        // only between two digits.
        XCTAssertEqual(CorrectionGates.trimRunOn("The total is 3.5", original: "The total is 3,5."), "The total is 3.5")
        XCTAssertEqual(CorrectionGates.trimRunOn("is 3.5 now. More", original: "is 3,5 now."), "is 3.5 now.")
        // Unpunctuated: the budget is the original plus 6 (an eighth past
        // 48); within it the fix stands, past it the last end inside it cuts.
        XCTAssertEqual(CorrectionGates.trimRunOn("fixed words ok", original: "fixd words"), "fixed words ok")
        XCTAssertEqual(CorrectionGates.trimRunOn("abcdefghi", original: "abc"), "abcdefghi")
        let long = String(repeating: "x", count: 72)
        XCTAssertEqual(CorrectionGates.trimRunOn(long + "yyyyyyyyy", original: long), long + "yyyyyyyyy")
        XCTAssertEqual(CorrectionGates.trimRunOn(".5 is a lot more than that", original: "abc"), ".")
        XCTAssertEqual(CorrectionGates.trimRunOn("3.5 and then more", original: "x"), "x")
        // CJK closing quote after the terminal survives the cut.
        XCTAssertEqual(CorrectionGates.trimRunOn("彼は「終わった。」ごみ", original: "彼は「終わった。」"),
                       "彼は「終わった。」")
    }

    // ⌥⇥ on the last word: the sentence goes to the model, only the word comes back.
    func testLastWordFix() async throws {
        XCTAssertEqual(CorrectionGates.lastWordContext("Hi. I went to the stor"), "I went to the stor")
        XCTAssertEqual(CorrectionGates.lastWordContext("Dear Ann,\nThanks for teh"), "Thanks for teh")
        XCTAssertEqual(CorrectionGates.lastWordContext("v1.2 is ot"), "v1.2 is ot")      // no space after the dot
        XCTAssertEqual(CorrectionGates.lastWordContext("今日は。天気が"), "天気が")
        let long = String(repeating: "word ", count: 60) + "endd"
        XCTAssertEqual(CorrectionGates.lastWordContext(long).count <= 200, true)
        XCTAssertTrue(CorrectionGates.lastWordContext(long).hasPrefix("word "))
        let r = { (c: String, w: String, f: String) in CorrectionGates.lastWordReplacement(context: c, word: w, fixed: f) }
        XCTAssertEqual(r("I went to the stor", "stor", "I went to the store."), "store")
        XCTAssertEqual(r("I like it alot", "alot", "I like it a lot"), "a lot")
        XCTAssertEqual(r("i went to teh", "teh", "I went to the"), "the")          // an earlier fix too
        XCTAssertEqual(r("I dont", "dont", "I don't"), "don't")
        // The token's lead changed (’ → '): which part is the word is unclear.
        XCTAssertNil(r("passent à l’atcion", "atcion", "Passent à l'action"))
        XCTAssertEqual(r("passent à l’atcion", "atcion", "Passent à l’action."), "action")
        XCTAssertNil(r("I went to the stor", "stor", "I went to the store and bought some milk"))
        XCTAssertNil(r("I went to the stor", "stor", "I went to the store and milk"), "two more words")
        XCTAssertNil(r("teh", "teh", "..."), "nothing left of the word")
        // The line the caret is on, even an empty one; an ender at the very
        // end starts nothing; 200 characters, from a word start.
        XCTAssertEqual(CorrectionGates.lastWordContext("Dear Ann,\n"), "")
        XCTAssertEqual(CorrectionGates.lastWordContext("Hello there."), "Hello there.")
        let twoHundred = "word" + String(repeating: " word", count: 38) + " ends!"
        XCTAssertEqual(twoHundred.count, 200)
        XCTAssertEqual(CorrectionGates.lastWordContext(twoHundred), twoHundred)
        let cut = String(repeating: "word ", count: 38) + "ends!"
        XCTAssertEqual(CorrectionGates.lastWordContext("x" + twoHundred), cut)
        XCTAssertEqual(CorrectionGates.lastWordContext(String(repeating: " word", count: 40) + " ends!"), cut)
        XCTAssertNil(r("I went to the stor", "stor", "We visited a shop"))
        // The model sees the sentence; a word that stays is no fix.
        var seen: [String] = []
        let fixed = try await CorrectionGates.fixLastWord("stor", before: "Hi. I went to the stor") {
            seen.append($0); return "I went to the store."
        }
        XCTAssertEqual(fixed, "store")
        XCTAssertEqual(seen, ["I went to the stor"])
        let kept = try await CorrectionGates.fixLastWord("store", before: "the store") { _ in "The store" }
        XCTAssertNil(kept)
        // A word that doesn't end the text goes alone too.
        _ = try await CorrectionGates.fixLastWord("teh", before: "I went to teh ") { seen.append($0); return "the" }
        XCTAssertEqual(seen.last, "teh")
        // The first word of a line has no sentence to add: the word goes alone.
        let alone = try await CorrectionGates.fixLastWord("teh", before: "teh") { seen.append($0); return "the" }
        XCTAssertEqual(alone, "the")
        XCTAssertEqual(seen.last, "teh")
    }
}
