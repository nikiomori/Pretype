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
}
