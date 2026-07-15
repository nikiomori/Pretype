import XCTest
import CoreGraphics
@testable import Pretype

final class PretypeTests: XCTestCase {

    // The output gate decides what raw model text reaches the user's keystrokes —
    // the single most safety-critical pure function in the app. Pin its rules.
    func testCompletionGatesPostProcess() {
        func pp(_ raw: String, prompt: String = "hello world", trailingSpaces: Int = 0,
                endsMidWord: Bool = false, endsCompleteWord: Bool = false,
                after: String = "", singleWord: Bool = false) -> String? {
            CompletionGates.postProcess(
                raw, prompt: prompt, trailingSpaces: trailingSpaces,
                endsMidWord: endsMidWord, endsCompleteWord: endsCompleteWord,
                textAfterCaret: after, singleWord: singleWord)
        }

        // Control characters / the replacement char must never be typed back.
        XCTAssertNil(pp("a\u{07}b"))
        XCTAssertNil(pp("te\u{FFFD}xt"))
        // The model must not echo our own prompt scaffolding.
        XCTAssertNil(pp("Nearby on screen: foo", prompt: "ok"))
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
        // Single-word mode keeps only the leading separator + first word.
        XCTAssertEqual(pp(" tomorrow at noon", prompt: "i will see you", singleWord: true), " tomorrow")
    }

    // The hotkey matchers gate every text injection; lock their modifier rules.
    func testHotkeyMatchers() {
        let tab = KeyCode.tab
        let space = KeyCode.space

        // Tab style: bare Tab = accept word, ⇧Tab = accept all, ⌥Tab = correction.
        XCTAssertTrue(HotkeyStyle.tab.matchesAcceptWord(keyCode: tab, flags: []))
        XCTAssertFalse(HotkeyStyle.tab.matchesAcceptWord(keyCode: tab, flags: [.maskShift]))
        XCTAssertTrue(HotkeyStyle.tab.matchesAcceptAll(keyCode: tab, flags: [.maskShift]))
        XCTAssertTrue(HotkeyStyle.tab.matchesCorrection(keyCode: tab, flags: [.maskAlternate]))
        // A different key never matches.
        XCTAssertFalse(HotkeyStyle.tab.matchesAcceptWord(keyCode: space, flags: []))
        // Caps Lock is outside the modifier mask, so it doesn't break bare Tab.
        XCTAssertTrue(HotkeyStyle.tab.matchesAcceptWord(keyCode: tab, flags: [.maskAlphaShift]))

        // ⌘Space style.
        XCTAssertTrue(HotkeyStyle.cmdSpace.matchesAcceptWord(keyCode: space, flags: [.maskCommand]))
        XCTAssertFalse(HotkeyStyle.cmdSpace.matchesAcceptWord(keyCode: space, flags: []))
        XCTAssertTrue(HotkeyStyle.cmdSpace.matchesAcceptAll(keyCode: space, flags: [.maskCommand, .maskShift]))

        // Documented quirk: ⌘Space and ⌥Space share the ⌥⌘Space correction chord
        // (there is no "Opt+Opt"), so both match the same flags.
        XCTAssertTrue(HotkeyStyle.cmdSpace.matchesCorrection(keyCode: space, flags: [.maskCommand, .maskAlternate]))
        XCTAssertTrue(HotkeyStyle.optSpace.matchesCorrection(keyCode: space, flags: [.maskCommand, .maskAlternate]))
    }

    func testLevenshteinDistance() {
        XCTAssertTrue(CorrectionGates.isMinimalCorrection(original: "teh", fixed: "the"))
        XCTAssertTrue(CorrectionGates.isMinimalCorrection(original: "recei", fixed: "receive"))
        XCTAssertTrue(CorrectionGates.isMinimalCorrection(original: "привет", fixed: "привет!"))
        
        // Massive rewrites should be rejected
        XCTAssertFalse(CorrectionGates.isMinimalCorrection(original: "hello how are you", fixed: "goodbye my friend"))
    }
    
    func testCleanCorrectionOutput() {
        XCTAssertEqual(CorrectionGates.cleanCorrectionOutput("\"hello\""), "hello")
        XCTAssertEqual(CorrectionGates.cleanCorrectionOutput("«привет»"), "привет")
        XCTAssertEqual(CorrectionGates.cleanCorrectionOutput("“test”"), "test")
        XCTAssertEqual(CorrectionGates.cleanCorrectionOutput("  trimmed  \n  newline  "), "trimmed")
    }
    
    func testTrailingWord() {
        XCTAssertEqual(SpellChecker.trailingWord(of: "hello world"), "world")
        XCTAssertEqual(SpellChecker.trailingWord(of: "hello world "), "")
        XCTAssertEqual(SpellChecker.trailingWord(of: "hello-world"), "hello-world")
        XCTAssertEqual(SpellChecker.trailingWord(of: "don't"), "don't")
        XCTAssertEqual(SpellChecker.trailingWord(of: "привет"), "привет")
    }
    
    func testFirstWordChunk() {
        XCTAssertEqual(SuggestionController.firstWordChunk(of: " hello world"), " hello")
        XCTAssertEqual(SuggestionController.firstWordChunk(of: "word"), "word")
        XCTAssertEqual(SuggestionController.firstWordChunk(of: "   multiple   words"), "   multiple")
    }

    func testNarrowedSuggestion() {
        // Typing the suggestion's head shrinks it.
        XCTAssertEqual(SuggestionController.narrowedSuggestion("ing to the store", typedCharacters: "i"), "ng to the store")
        XCTAssertEqual(SuggestionController.narrowedSuggestion(" привет мир", typedCharacters: " "), "привет мир")
        // A diverging character invalidates it.
        XCTAssertNil(SuggestionController.narrowedSuggestion("ing to", typedCharacters: "x"))
        // Typing through the end leaves nothing to suggest.
        XCTAssertNil(SuggestionController.narrowedSuggestion("i", typedCharacters: "i"))
        // Control input (backspace, return, arrows/function keys) invalidates.
        XCTAssertNil(SuggestionController.narrowedSuggestion("ing to", typedCharacters: "\u{08}"))
        XCTAssertNil(SuggestionController.narrowedSuggestion("ing to", typedCharacters: "\r"))
        XCTAssertNil(SuggestionController.narrowedSuggestion("ing to", typedCharacters: "\u{F702}"))
    }

    func testStrippingStraySeparator() {
        // Prefix is a complete word AND the start of a longer one: the model is
        // finishing the current word, so the stray separator must go.
        XCTAssertEqual(SpellChecker.strippingStraySeparator(suggestion: " вет", before: "при"), "вет")
        XCTAssertEqual(SpellChecker.strippingStraySeparator(suggestion: " ма", before: "до"), "ма")
        // Genuine next word after a finished word keeps its separator.
        XCTAssertEqual(
            SpellChecker.strippingStraySeparator(suggestion: " как дела", before: "привет"),
            " как дела"
        )
        // No leading space, or caret not mid-word: untouched.
        XCTAssertEqual(SpellChecker.strippingStraySeparator(suggestion: "вет", before: "при"), "вет")
        XCTAssertEqual(SpellChecker.strippingStraySeparator(suggestion: " вет", before: "при "), " вет")
    }

    func testDecapitalizeContinuation() {
        // Mid-sentence capital from the model gets lowered.
        XCTAssertEqual(SpellChecker.decapitalizeContinuation("Поехать домой", before: "я хочу "), "поехать домой")
        XCTAssertEqual(SpellChecker.decapitalizeContinuation(" Как дела", before: "привет,"), " как дела")
        // Sentence start (after a terminator, or empty) keeps the capital.
        XCTAssertEqual(SpellChecker.decapitalizeContinuation("Как дела", before: "Привет. "), "Как дела")
        XCTAssertEqual(SpellChecker.decapitalizeContinuation("Hello", before: ""), "Hello")
        // English "I" / contractions stay capital.
        XCTAssertEqual(SpellChecker.decapitalizeContinuation("I think so", before: "well "), "I think so")
        XCTAssertEqual(SpellChecker.decapitalizeContinuation("I'm sure", before: "and "), "I'm sure")
        // Acronyms stay upper.
        XCTAssertEqual(SpellChecker.decapitalizeContinuation("API call", before: "the "), "API call")
    }

    func testAppPolicyBlacklist() {
        // Save current blacklist
        let originalBlacklist = Settings.userBlacklist
        defer { Settings.userBlacklist = originalBlacklist }

        // Test terminal is blacklisted by default
        XCTAssertTrue(AppPolicy.isBlacklisted("com.apple.Terminal"))
        XCTAssertTrue(AppPolicy.isBlacklisted("com.googlecode.iterm2"))

        // Test normal app is NOT blacklisted by default
        XCTAssertFalse(AppPolicy.isBlacklisted("com.apple.mail"))

        // Add to blacklist
        Settings.userBlacklist = ["mail", "slack"]
        XCTAssertTrue(AppPolicy.isBlacklisted("com.apple.mail"))
        XCTAssertTrue(AppPolicy.isBlacklisted("com.tinyspeck.slackmacgap"))
        
        // Allows screen context should be false for blacklisted apps
        XCTAssertFalse(AppPolicy.allowsScreenContext("com.apple.mail"))
    }

    // The journal is the dataset every future personalization feature reads;
    // pin the append/decode round-trip and the size cap.
    func testSuggestionJournal() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-test-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = SuggestionJournal(url: url, maxBytes: 4000)

        func entry(_ suggestion: String, _ outcome: SuggestionJournal.Outcome) -> SuggestionJournal.Entry {
            SuggestionJournal.Entry(
                ts: SuggestionJournal.timestamp(), app: "com.test", engine: "MLX",
                ctx: "привет, как", after: "", suggestion: suggestion, outcome: outcome,
                acceptedChars: outcome == .accepted ? suggestion.count : 0,
                typed: nil, shownForMs: 250, screen: false)
        }

        journal.append(entry(" дела", .accepted))
        journal.append(entry(" ты?\nnewline", .diverged))   // newline must stay escaped
        XCTAssertGreaterThan(journal.fileSize, 0)           // fileSize syncs the queue

        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        let decoded = try JSONDecoder().decode(SuggestionJournal.Entry.self, from: Data(lines[0].utf8))
        XCTAssertEqual(decoded.suggestion, " дела")
        XCTAssertEqual(decoded.outcome, .accepted)
        XCTAssertEqual(decoded.acceptedChars, 5)

        // Blow past maxBytes: a fresh instance trims on init to the newest half,
        // cutting on a line boundary so every kept line still decodes.
        for i in 0..<40 { journal.append(entry("suggestion number \(i)", .abandoned)) }
        XCTAssertGreaterThan(journal.fileSize, 4000)
        let trimmed = SuggestionJournal(url: url, maxBytes: 4000)
        XCTAssertLessThanOrEqual(trimmed.fileSize, 4000)
        XCTAssertGreaterThan(trimmed.fileSize, 0)
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            XCTAssertNoThrow(try JSONDecoder().decode(SuggestionJournal.Entry.self, from: Data(line.utf8)))
        }

        journal.reset()
        XCTAssertEqual(journal.fileSize, 0)
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

    // The config stamp + first-word logprob are new OPTIONAL Entry fields. Pin the
    // serialization contract they depend on — the exact class of break that a
    // missing `= nil` caused: legacy lines still decode (fields nil), a populated
    // stamp round-trips, and nil fields are OMITTED so journals stay compact.
    func testJournalEntryStampCodable() throws {
        // 1. A legacy line — written before the fields existed, so none of the
        //    keys are present — must decode, with every new field nil, and the
        //    core fields intact. (Existing on-disk journals must stay readable.)
        let legacy = #"{"ts":"t","app":"a","engine":"MLX","ctx":"c","after":"","suggestion":" x","outcome":"accepted","acceptedChars":2,"shownForMs":100,"screen":false}"#
        let old = try JSONDecoder().decode(SuggestionJournal.Entry.self, from: Data(legacy.utf8))
        XCTAssertNil(old.model)
        XCTAssertNil(old.style)
        XCTAssertNil(old.gate)
        XCTAssertNil(old.personalization)
        XCTAssertNil(old.firstWordLogProb)
        XCTAssertEqual(old.suggestion, " x")
        XCTAssertEqual(old.outcome, .accepted)

        // 2. A fully-stamped entry round-trips through encode → decode.
        var stamped = SuggestionJournal.Entry(
            ts: "t", app: "com.test", engine: "MLX",
            ctx: "привет, как", after: "", suggestion: " дела", outcome: .accepted,
            acceptedChars: 5, typed: nil, shownForMs: 250, screen: false)
        stamped.model = "gemma-4-e2b-8bit"
        stamped.style = "base"
        stamped.gate = "off"
        stamped.personalization = "subtle+rag"
        stamped.firstWordLogProb = -0.42
        let back = try JSONDecoder().decode(
            SuggestionJournal.Entry.self, from: JSONEncoder().encode(stamped))
        XCTAssertEqual(back.model, "gemma-4-e2b-8bit")
        XCTAssertEqual(back.style, "base")
        XCTAssertEqual(back.gate, "off")
        XCTAssertEqual(back.personalization, "subtle+rag")
        XCTAssertEqual(back.firstWordLogProb ?? .nan, -0.42, accuracy: 1e-9)

        // 3. nil optionals are omitted (synthesized encodeIfPresent) — a bare
        //    entry (undo / ngram / legacy) must not bloat the journal with null keys.
        let bare = SuggestionJournal.Entry(
            ts: "t", app: nil, engine: nil,
            ctx: "c", after: "", suggestion: "x", outcome: .diverged,
            acceptedChars: 0, typed: nil, shownForMs: 0, screen: false)
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(bare), encoding: .utf8))
        XCTAssertFalse(json.contains("firstWordLogProb"))
        XCTAssertFalse(json.contains("\"model\""))
        XCTAssertFalse(json.contains("\"gate\""))
    }

    // Retrieval feeds the model the user's own phrases — pin that it finds the
    // overlapping phrase, drops ⌘Z-reverted ones, and indexes live appends.
    func testJournalRetrieval() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-rag-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        func entry(ctx: String, _ suggestion: String, _ outcome: SuggestionJournal.Outcome) -> SuggestionJournal.Entry {
            SuggestionJournal.Entry(
                ts: SuggestionJournal.timestamp(), app: "com.test", engine: "MLX",
                ctx: ctx, after: "", suggestion: suggestion, outcome: outcome,
                acceptedChars: 0, typed: nil, shownForMs: 100, screen: false)
        }

        let writer = SuggestionJournal(url: url)
        writer.append(entry(ctx: "обсудили проект с Никитой по", " дедлайнам", .accepted))
        writer.append(entry(ctx: "the quarterly report for marketing", " is ready", .accepted))
        writer.append(entry(ctx: "созвон с Никитой про проект завтра", " утром", .typedThrough))
        writer.append(entry(ctx: "", " дедлайнам", .undone))   // ⌘Z revert of the first
        _ = writer.fileSize   // drain the write queue

        // Fresh instance loads the corpus from disk: the reverted phrase is out,
        // the Никита/проект phrase wins on shared rare words, marketing doesn't match.
        let journal = SuggestionJournal(url: url)
        let found = journal.similarAcceptedPhrases(to: "надо обсудить проект с Никитой")
        XCTAssertEqual(found.map(\.next), [" утром"])

        // Under two meaningful shared words — no example beats a wrong example.
        XCTAssertTrue(journal.similarAcceptedPhrases(to: "проект").isEmpty)
        XCTAssertTrue(journal.similarAcceptedPhrases(to: "купить хлеб и молоко").isEmpty)

        // An accept recorded after the corpus loaded is retrievable immediately.
        journal.append(entry(ctx: "ужин с мамой в субботу вечером", " дома", .accepted))
        let live = journal.similarAcceptedPhrases(to: "планируем ужин в субботу вечером")
        XCTAssertEqual(live.map(\.next), [" дома"])
    }

    // The n-gram trainer must see each typed sentence once, not once per
    // keystroke snapshot — pin the delta-dedup and the per-app tracking.
    func testTypedStreamReconstruction() throws {
        // Pure delta function: growing snapshot → only the new tail.
        XCTAssertEqual(SuggestionJournal.newText(in: "привет как дела сегодня", since: "привет как дела"), " сегодня")
        // Slid capped window: prev's ending is found inside ctx → only what follows.
        let prev = "a very long sentence that keeps going and going until the window slides"
        let slid = String(prev.dropFirst(10)) + " and new words"
        XCTAssertEqual(SuggestionJournal.newText(in: slid, since: prev), " and new words")
        // Genuinely new context → counted whole.
        XCTAssertEqual(SuggestionJournal.newText(in: "совсем новый текст", since: prev), "совсем новый текст")

        // End to end through a journal file, with per-app separation.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-stream-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = SuggestionJournal(url: url)
        func entry(app: String, ctx: String) -> SuggestionJournal.Entry {
            SuggestionJournal.Entry(
                ts: SuggestionJournal.timestamp(), app: app, engine: "MLX",
                ctx: ctx, after: "", suggestion: " x", outcome: .diverged,
                acceptedChars: 0, typed: nil, shownForMs: 100, screen: false)
        }
        journal.append(entry(app: "mail", ctx: "привет как дела"))
        journal.append(entry(app: "slack", ctx: "другой чат про работу"))
        journal.append(entry(app: "mail", ctx: "привет как дела сегодня вечером"))
        _ = journal.fileSize   // drain the write queue
        XCTAssertEqual(journal.typedStreamChunks(),
                       ["привет как дела", "другой чат про работу", " сегодня вечером"])
    }

    // The instant fast-path types straight into the user's text — pin that it
    // only fires on emphatic evidence and preserves surface case (names).
    func testPersonalNgram() {
        let ngram = PersonalNgram()
        for _ in 0..<3 {
            ngram.learn("спасибо за быстрый ответ и помощь")
            ngram.learn("передай Никите привет")
        }

        // Trigram hit, dominant → predicted.
        XCTAssertEqual(ngram.nextWord(after: "ну спасибо за быстрый "), "ответ")
        // Bigram fallback when the trigram context is unseen; case preserved.
        XCTAssertEqual(ngram.nextWord(after: "завтра передай "), "Никите")
        // Unknown context → nil.
        XCTAssertNil(ngram.nextWord(after: "совсем другой контекст "))
        // Split evidence (50/50) is not dominant → nil.
        ngram.learn("иду в кино"); ngram.learn("иду в кино")
        ngram.learn("иду в магазин"); ngram.learn("иду в магазин")
        XCTAssertNil(ngram.nextWord(after: "я иду в "))

        // Mid-word completion: dominant vocabulary word → remainder.
        XCTAssertEqual(ngram.completeWord(partial: "спас"), "ибо")
        XCTAssertNil(ngram.completeWord(partial: "сп"))        // too short
        XCTAssertNil(ngram.completeWord(partial: "магази"))    // adds <2 chars
        // A near-tie in the vocabulary is ambiguous → nil.
        ngram.learn("спасение утопающих"); ngram.learn("спасение утопающих")
        XCTAssertNil(ngram.completeWord(partial: "спас"))

        // Beam-fusion evidence: unthresholded counts, fold-matched (ё→е, case),
        // trigram beats bigram when both hit; unseen → 0.
        XCTAssertEqual(ngram.count(of: "ответ", after: "ну спасибо за быстрый "), 3)
        XCTAssertEqual(ngram.count(of: "никите", after: "завтра передай "), 3)
        XCTAssertEqual(ngram.count(of: "кино", after: "я иду в "), 2)   // below nextWord's dominance bar, still counted
        XCTAssertEqual(ngram.count(of: "ответ", after: "совсем другой контекст "), 0)

        ngram.reset()
        XCTAssertNil(ngram.nextWord(after: "ну спасибо за быстрый "))
    }

    @MainActor
    func testSuggestionControllerUndo() {
        let controller = SuggestionController()
        let mirror = Mirror(reflecting: controller)

        // It should be nil on start
        let initial = mirror.descendant("lastAcceptedChunk") as? String?
        XCTAssertEqual(initial, nil)

        // Calling dismiss should clear it
        controller.dismiss()
        let afterDismiss = mirror.descendant("lastAcceptedChunk") as? String?
        XCTAssertEqual(afterDismiss, nil)
    }

    // The overlay's background probe decides dark-vs-light text from this mean;
    // pin the byte-order/color-space assumptions of the 1-px downsample.
    func testBackgroundProbeMeanLuminance() {
        func solidImage(white: CGFloat) -> CGImage {
            let ctx = CGContext(data: nil, width: 8, height: 4, bitsPerComponent: 8,
                                bytesPerRow: 32, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(srgbRed: white, green: white, blue: white, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
            return ctx.makeImage()!
        }
        let dark = BackgroundProbe.meanLuminance(of: solidImage(white: 0))!
        let light = BackgroundProbe.meanLuminance(of: solidImage(white: 1))!
        XCTAssertLessThan(dark, 0.1)
        XCTAssertGreaterThan(light, 0.9)
    }

    // ConfigProjection powers everything the settings UI claims a setting will
    // do — pin the cascade rules and the eval-backed figures it projects.
    func testConfigProjectionCascades() {
        let e4b6 = "mlx-community/gemma-4-e4b-6bit"
        let mini = "openbmb/MiniCPM5-1B-Base"
        var c = ProjectionConfig(modelID: e4b6, style: .base, length: .short,
                                 logprobGate: false, confidenceGate: true,
                                 useRecommended: false)

        // The gates are mutually exclusive, both ways.
        c = c.applying(.logprobGate(true))
        XCTAssertTrue(c.logprobGate); XCTAssertFalse(c.confidenceGate)
        c = c.applying(.confidenceGate(true))
        XCTAssertTrue(c.confidenceGate); XCTAssertFalse(c.logprobGate)

        // Instruct has no gate path.
        c = c.applying(.style(.instruct))
        XCTAssertFalse(c.confidenceGate); XCTAssertFalse(c.logprobGate)
        XCTAssertFalse(c.useRecommended)

        // Recommended mode snaps style/length to the model's measured best.
        c = c.applying(.useRecommended(true))
        XCTAssertEqual(c.style, ModelCatalog.recommended(for: e4b6).style)

        // Switching to a non-gate-capable model drops the consensus gate.
        var manual = ProjectionConfig(modelID: e4b6, style: .base, length: .short,
                                      logprobGate: false, confidenceGate: true,
                                      useRecommended: false)
        manual = manual.applying(.model(mini))
        XCTAssertFalse(manual.confidenceGate)

        // A model switch never carries Instruct onto a base-only model where
        // it's measured-broken — style snaps to Base even in manual mode.
        var instructed = ProjectionConfig(modelID: e4b6, style: .instruct, length: .short,
                                          logprobGate: false, confidenceGate: false,
                                          useRecommended: false)
        instructed = instructed.applying(.model(mini))
        XCTAssertEqual(instructed.style, .base)

        // In recommended mode a model switch re-snaps everything.
        var auto = ProjectionConfig(modelID: mini, style: .base, length: .long,
                                    logprobGate: true, confidenceGate: false,
                                    useRecommended: true)
        auto = auto.applying(.model(e4b6))
        XCTAssertEqual(auto.style, .instruct)  // E4B's measured best
        XCTAssertEqual(auto.length, .short)
        XCTAssertFalse(auto.logprobGate)
    }

    func testConfigProjectionFigures() {
        let e4b6 = "mlx-community/gemma-4-e4b-6bit"
        let mini = "openbmb/MiniCPM5-1B-Base"
        func cfg(_ id: String, _ style: CompletionStyle, _ length: CompletionLength = .short,
                 logprob: Bool = false, confidence: Bool = false) -> ConfigProjection {
            ConfigProjection.project(ProjectionConfig(
                modelID: id, style: style, length: length,
                logprobGate: logprob, confidenceGate: confidence, useRecommended: false))
        }

        // Plain base = the model's own eval row.
        let base = cfg(mini, .base)
        XCTAssertEqual(base.accuracyPct, 30)
        XCTAssertEqual(base.p50Ms, 49)
        XCTAssertEqual(base.ramGB, 2.2)
        XCTAssertFalse(base.broken)

        // Instruct on a base-only model is truthfully broken, not hidden.
        let broken = cfg(mini, .instruct)
        XCTAssertTrue(broken.broken)
        XCTAssertEqual(broken.accuracyPct, 0)

        // Instruct on E4B: measured sibling figures, second-model memory.
        let instruct = cfg(e4b6, .instruct)
        XCTAssertEqual(instruct.accuracyPct, 22)
        XCTAssertEqual(instruct.authoredPct, 85)
        XCTAssertEqual(instruct.p50Ms, 129)

        // Instruct on a tier with an unmeasured sibling: base figure stands in,
        // marked as an estimate — never a blank speed meter.
        let instructE2B = cfg("mlx-community/gemma-4-e2b-8bit", .instruct)
        XCTAssertEqual(instructE2B.p50Ms, 75)
        XCTAssertTrue(instructE2B.latencyText.hasPrefix("≈"))

        // Consensus gate: 39% @ 54% coverage, ×5 latency.
        let consensus = cfg(e4b6, .base, confidence: true)
        XCTAssertEqual(consensus.accuracyPct, 39)
        XCTAssertEqual(consensus.coveragePct, 54)
        XCTAssertEqual(consensus.p50Ms, 129 * 5)

        // Logprob gate on the calibration (default) model: the measured band.
        let gated = cfg(mini, .base, logprob: true)
        XCTAssertEqual(gated.accuracyText, "62–67%")
        XCTAssertEqual(gated.p50Ms, 49)

        // On any other model the gate figure is SCALED from that model's own
        // base accuracy (and says so) — different models project differently.
        let gatedE4B = cfg(e4b6, .base, logprob: true)
        XCTAssertEqual(gatedE4B.accuracyPct, Int((33.0 * 64.0 / 30.0).rounded()))
        XCTAssertTrue(gatedE4B.accuracyText.hasPrefix("≈"))
        XCTAssertTrue(gatedE4B.accuracySub.contains("not measured on this model"))
        let gatedLFM = cfg("LiquidAI/LFM2.5-1.2B-Base", .base, logprob: true)
        XCTAssertNotEqual(gatedE4B.accuracyPct, gatedLFM.accuracyPct)

        // Length scales latency by the measured sweep factor.
        XCTAssertEqual(cfg(mini, .base, .long).p50Ms, Int((49 * 3.5).rounded()))

        // System model: no app memory, compute is the Neural Engine.
        let ai = cfg(ModelCatalog.appleIntelligenceID, .instruct)
        XCTAssertEqual(ai.ramGB, 0)
        XCTAssertNil(ai.computeRel)
        XCTAssertEqual(ai.computeText, "ANE")

        // Deltas: switching MiniCPM base → E4B instruct costs memory, buys nothing real.
        let deltas = ConfigProjection.deltas(from: base, to: instruct)
        XCTAssertTrue(deltas.contains { $0.label == "Memory" && !$0.improved })
    }

    // Priority presets resolve by dominance rules over the measured catalog —
    // pin the current answers so a catalog edit that flips them is noticed.
    func testModelPriorityPicks() {
        XCTAssertEqual(ModelPriority.lightest.pick, "mlx-community/Qwen2.5-0.5B-bf16")   // 1.0 GB
        XCTAssertEqual(ModelPriority.accurate.pick, "mlx-community/gemma-4-e4b-6bit")    // 33%, lighter of the tied pair
        XCTAssertEqual(ModelPriority.quick.pick, "mlx-community/gemma-4-e2b-8bit")       // ≥31% at 75 ms
        XCTAssertEqual(ModelPriority.balanced.pick, ModelCatalog.defaultID)

        // A preset lands on the measured protocol its card advertises
        // (Base · Short — NOT the Gemma recommendation, which is Instruct and
        // measures 22% on real text), and preserves compatible gates.
        let custom = ProjectionConfig(modelID: ModelCatalog.defaultID, style: .instruct,
                                      length: .long, logprobGate: true,
                                      confidenceGate: false, useRecommended: false)
        let landed = custom.applying(.preset(ModelPriority.accurate.pick))
        XCTAssertEqual(landed.modelID, ModelPriority.accurate.pick)
        XCTAssertEqual(landed.style, .base)
        XCTAssertEqual(landed.length, .short)
        XCTAssertTrue(landed.logprobGate)        // user's gate survives
        XCTAssertFalse(landed.useRecommended)    // recommendation (Instruct) ≠ landing
        // Where the recommendation IS Base · Short, auto mode stays on.
        XCTAssertTrue(custom.applying(.preset(ModelPriority.balanced.pick)).useRecommended)

        // A map settings-dot jumps to its exact configuration, verbatim.
        let dot = ProjectionConfig(modelID: custom.modelID, style: .base, length: .medium,
                                   logprobGate: false, confidenceGate: false,
                                   useRecommended: false)
        XCTAssertEqual(custom.applying(.config(dot)), dot)
        // Runtime equivalence ignores only the auto-mode flag.
        var dotAuto = dot; dotAuto.useRecommended = true
        XCTAssertTrue(dot.sameRuntime(as: dotAuto))
        XCTAssertFalse(dot.sameRuntime(as: custom))
    }
}
