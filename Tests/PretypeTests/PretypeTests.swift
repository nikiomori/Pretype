import XCTest
import Carbon
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

    // ⌘Z undo-accept must be an EXACT chord: ⇧⌘Z (redo) and ⌥⌘Z belong to the
    // app — matching them swallowed the app's redo and deleted text.
    func testPlainCommandZMatcher() {
        let z = KeyCode.z
        // QWERTY: ANSI Z produces "z".
        XCTAssertTrue(SuggestionController.isPlainCommandZ(keyCode: z, key: "z", flags: [.maskCommand]))
        // ЙЦУКЕН/Greek: no Latin letter produced → the physical ANSI key decides.
        XCTAssertTrue(SuggestionController.isPlainCommandZ(keyCode: z, key: "я", flags: [.maskCommand]))
        XCTAssertTrue(SuggestionController.isPlainCommandZ(keyCode: z, key: nil, flags: [.maskCommand]))
        // QWERTZ/AZERTY: the produced Latin letter decides, wherever Z sits.
        XCTAssertTrue(SuggestionController.isPlainCommandZ(keyCode: 16, key: "z", flags: [.maskCommand]))
        XCTAssertFalse(SuggestionController.isPlainCommandZ(keyCode: z, key: "y", flags: [.maskCommand]))
        // Extra chord modifiers belong to the app (⇧⌘Z redo, ⌥⌘Z, ⌃⌘Z).
        XCTAssertFalse(SuggestionController.isPlainCommandZ(keyCode: z, key: "z", flags: [.maskCommand, .maskShift]))
        XCTAssertFalse(SuggestionController.isPlainCommandZ(keyCode: z, key: "z", flags: [.maskCommand, .maskAlternate]))
        XCTAssertFalse(SuggestionController.isPlainCommandZ(keyCode: z, key: "z", flags: [.maskCommand, .maskControl]))
        XCTAssertFalse(SuggestionController.isPlainCommandZ(keyCode: z, key: "z", flags: []))
        // Caps Lock is outside the modifier mask, so it doesn't break ⌘Z.
        XCTAssertTrue(SuggestionController.isPlainCommandZ(keyCode: z, key: "z", flags: [.maskCommand, .maskAlphaShift]))
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

    // Fuel for the greedy first-token boost: every continuation with its
    // evidence count, unthresholded, trigram/bigram max.
    func testPersonalNgramContinuations() {
        let ngram = PersonalNgram()
        for _ in 0..<3 { ngram.learn("спасибо за быстрый ответ") }
        ngram.learn("спасибо за быстрый отклик")
        let counts = ngram.continuations(after: "и снова спасибо за быстрый ")
        XCTAssertEqual(counts["ответ"], 3)
        XCTAssertEqual(counts["отклик"], 1)
        XCTAssertTrue(ngram.continuations(after: "…—…").isEmpty)
    }

    // Live learning on the resolve path: the first ctx snapshot per app only
    // seeds the cursor (its text is already journaled); later snapshots
    // contribute their delta, per app.
    func testPersonalNgramObserve() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-observe-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let ngram = PersonalNgram()
        // Inert until the build FINISHED (before that, entries belong to the
        // build's own journal read — learning them live would double-count).
        ngram.observe(ctx: "передай Никите привет", app: "mail")
        XCTAssertEqual(ngram.wordCount, 0)
        ngram.prepareIfNeeded(journal: SuggestionJournal(url: url))   // empty journal
        let deadline = Date().addingTimeInterval(5)
        while !ngram.isPrepared, Date() < deadline { usleep(10_000) }
        XCTAssertTrue(ngram.isPrepared)
        // First snapshot per app: cursor seeded, nothing learned.
        ngram.observe(ctx: "передай Никите привет", app: "mail")
        XCTAssertNil(ngram.nextWord(after: "завтра передай "))
        var ctx = "передай Никите привет"
        for _ in 0..<3 {
            ctx += " и передай Никите привет"
            ngram.observe(ctx: ctx, app: "mail")
        }
        XCTAssertEqual(ngram.nextWord(after: "завтра передай "), "Никите")
        // A different app starts from its own cursor — no cross-app delta.
        ngram.observe(ctx: "совсем другое поле", app: "slack")
        XCTAssertEqual(ngram.count(of: "поле", after: "совсем другое "), 0)
    }

    // Base-path RAG: accepted phrases form a separate label-free preamble block
    // the engine prepends to the GENERATION prompt only — completionPrompt
    // (what the context floor, the gates and the n-gram context reason about)
    // must never contain it.
    func testPersonalPreambleBlock() {
        var request = CompletionRequest(textBeforeCaret: "пишу тебе про новый релиз")
        XCTAssertNil(request.personalPreambleBlock)
        request.personalExamples = [
            .init(ctx: "мы обсуждали релиз", next: " вчера вечером"),
            .init(ctx: "созвон в", next: " четверг"),
        ]
        XCTAssertEqual(request.personalPreambleBlock,
                       "мы обсуждали релиз вчера вечером\nсозвон в четверг")
        // The floor/gate prompt stays example-free.
        request.screenSummary = "чат про релиз"
        XCTAssertEqual(request.completionPrompt(maxChars: 1000),
                       "чат про релиз\n\nпишу тебе про новый релиз")
    }

    func testClipboardContextBlock() {
        var request = CompletionRequest(textBeforeCaret: "спасибо за письмо, отвечаю")
        request.clipboardContext = "Привет! Когда ждать релиз?"
        XCTAssertEqual(request.completionPrompt(maxChars: 1000),
                       "Привет! Когда ждать релиз?\n\nспасибо за письмо, отвечаю")
        // Clipboard reads as the earlier fragment, screen stays adjacent to the text.
        request.screenSummary = "чат про релиз"
        XCTAssertEqual(request.completionPrompt(maxChars: 1000),
                       "Привет! Когда ждать релиз?\n\nчат про релиз\n\nспасибо за письмо, отвечаю")
    }

    func testPerAppInstructions() {
        let saved = Settings.perAppInstructions
        defer { Settings.perAppInstructions = saved }
        Settings.perAppInstructions = ["com.apple.mail": "Formal, no emoji.", "com.blank.app": "   "]

        var request = CompletionRequest(textBeforeCaret: "hello")
        request.appBundleID = "com.apple.MAIL"  // engines match case-insensitively
        XCTAssertEqual(request.persona(global: "I write concisely."),
                       "I write concisely.\nFormal, no emoji.")
        XCTAssertEqual(request.persona(global: " "), "Formal, no emoji.")

        request.appBundleID = "com.blank.app"  // blank text = not configured
        XCTAssertEqual(request.persona(global: "I write concisely."), "I write concisely.")
        request.appBundleID = nil
        XCTAssertEqual(request.persona(global: "I write concisely."), "I write concisely.")
    }

    func testPerAppPresetTemplates() {
        // Exact catalog IDs and case-insensitivity.
        XCTAssertEqual(PerAppPresets.template(for: "com.apple.MAIL"), PerAppPresets.email)
        XCTAssertEqual(PerAppPresets.template(for: "ru.keepcoder.Telegram"), PerAppPresets.casualChat)
        // Heuristic for apps outside the catalog.
        XCTAssertEqual(PerAppPresets.template(for: "com.airmailapp.airmail-email"), PerAppPresets.email)
        XCTAssertEqual(PerAppPresets.template(for: "com.lukilabs.craft-notes"), PerAppPresets.notes)
        // Unknown kind starts blank rather than guessing wrong.
        XCTAssertNil(PerAppPresets.template(for: "com.example.mystery"))
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

    // The ghost takes dark-vs-light from the field's OWN text color, which is
    // what keeps it readable on a white page under a dark system (no screen
    // capture involved). Pin the polarity: a field's dark text must stay a dark
    // ghost, its light text a light one, whatever the hue.
    func testGhostNeutralGrayPolarity() {
        func gray(_ c: NSColor) -> CGFloat { SuggestionWindow.neutralGray(c)!.redComponent }
        XCTAssertLessThan(gray(.black), 0.1)
        XCTAssertGreaterThan(gray(.white), 0.9)
        // Hue drops out; only lightness survives, so a syntax-colored field
        // can't tint the ghost.
        XCTAssertEqual(gray(NSColor(srgbRed: 0.2, green: 0.2, blue: 0.2, alpha: 1)), 0.2, accuracy: 0.01)
        XCTAssertLessThan(gray(NSColor(srgbRed: 0.6, green: 0, blue: 0, alpha: 1)), 0.5)   // dark red text
        XCTAssertGreaterThan(gray(NSColor(srgbRed: 0.8, green: 1, blue: 0.8, alpha: 1)), 0.5) // pale green
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

        // Stale persisted state (gate set alongside Instruct, from before the
        // hygiene existed): a model switch heals it — Base-only gates never
        // survive an Instruct landing. The coordinator commits through this
        // same cascade, so preview and pipeline agree by construction.
        var stale = ProjectionConfig(modelID: e4b6, style: .instruct, length: .short,
                                     logprobGate: true, confidenceGate: false,
                                     useRecommended: false)
        stale = stale.applying(.model("mlx-community/gemma-4-e4b-8bit"))
        XCTAssertEqual(stale.style, .instruct)   // usable here, kept
        XCTAssertFalse(stale.logprobGate)        // but the gate cannot ride along

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
        XCTAssertEqual(base.accuracyPct, 28)
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
        XCTAssertEqual(gatedE4B.accuracyPct, Int((30.0 * 64.0 / 28.0).rounded()))
        XCTAssertTrue(gatedE4B.accuracyText.hasPrefix("≈"))
        XCTAssertTrue(gatedE4B.accuracySub.contains("not measured on this model"))
        let gatedQwen05 = cfg("mlx-community/Qwen2.5-0.5B-bf16", .base, logprob: true)
        XCTAssertNotEqual(gatedE4B.accuracyPct, gatedQwen05.accuracyPct)

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

    // Priority presets resolve by dominance rules over the measured catalog,
    // per accuracy axis — pin the current answers so a catalog edit that
    // flips them is noticed.
    func testModelPriorityPicks() {
        XCTAssertEqual(ModelPriority.lightest.pick(axis: "core"), "mlx-community/Qwen2.5-0.5B-bf16")   // 1.0 GB
        XCTAssertEqual(ModelPriority.accurate.pick(axis: "core"), "mlx-community/gemma-4-e4b-8bit")    // 31%; logP/char beats E2B-4bit's stale-sample tie
        XCTAssertEqual(ModelPriority.quick.pick(axis: "core"), "mlx-community/gemma-4-e2b-8bit")       // ≥29% at 75 ms
        XCTAssertEqual(ModelPriority.balanced.pick(axis: "core"), "openbmb/MiniCPM5-1B-Base")

        // Axis-dependence is the feature: on the all-languages average the
        // answers hold, but on Romanian E2B 8-bit measures BEST outright
        // (31 vs E4B's 30) — the cards must re-resolve per language.
        XCTAssertEqual(ModelPriority.accurate.pick(axis: "*"), "mlx-community/gemma-4-e4b-8bit")
        XCTAssertEqual(ModelPriority.quick.pick(axis: "*"), "mlx-community/gemma-4-e2b-8bit")
        XCTAssertEqual(ModelPriority.accurate.pick(axis: "ro"), "mlx-community/gemma-4-e2b-8bit")
        // Balanced follows the language: EN/RU keeps the fast specialist, any
        // other axis flips to the best small multilingual model — the same
        // split the keyboard-aware fresh-install default makes.
        XCTAssertEqual(ModelPriority.balanced.pick(axis: "ru"), "openbmb/MiniCPM5-1B-Base")
        XCTAssertEqual(ModelPriority.balanced.pick(axis: "ro"), "mlx-community/Qwen3.5-2B-4bit")
        XCTAssertEqual(ModelPriority.balanced.pick(axis: "*"), "mlx-community/Qwen3.5-2B-4bit")
        XCTAssertEqual(ModelCatalog.defaultID(forKeyboardLanguages: ["en", "ru"]),
                       "openbmb/MiniCPM5-1B-Base")
        XCTAssertEqual(ModelCatalog.defaultID(forKeyboardLanguages: []),
                       "openbmb/MiniCPM5-1B-Base")
        XCTAssertEqual(ModelCatalog.defaultID(forKeyboardLanguages: ["en", "ru", "de"]),
                       "mlx-community/Qwen3.5-2B-4bit")

        // The axis figures themselves: core = of-answered headline, "*" =
        // equal-weight mean of the booked per-language of-all cells.
        XCTAssertEqual(ModelMetrics.axisAccuracy(for: "mlx-community/gemma-4-e4b-8bit", axis: "core"), 31)
        XCTAssertEqual(ModelMetrics.axisAccuracy(for: "mlx-community/gemma-4-e4b-8bit", axis: "*"), 23)
        XCTAssertEqual(ModelMetrics.axisAccuracy(for: "mlx-community/gemma-4-e4b-8bit", axis: "cs"), 23)
        XCTAssertNil(ModelMetrics.axisAccuracy(for: "no-such-model", axis: "*"))
        XCTAssertEqual(ModelMetrics.axisBest("uk"), 24)  // Gemma E4B 8-bit
        XCTAssertEqual(ModelMetrics.evalLanguages.count, 17)

        // A preset lands on the measured protocol its card advertises
        // (Base · Short — NOT the Gemma recommendation, which is Instruct and
        // measures 22% on real text), and preserves compatible gates.
        let custom = ProjectionConfig(modelID: ModelCatalog.defaultID, style: .instruct,
                                      length: .long, logprobGate: true,
                                      confidenceGate: false, useRecommended: false)
        let landed = custom.applying(.preset(ModelPriority.accurate.pick(axis: "core")))
        XCTAssertEqual(landed.modelID, ModelPriority.accurate.pick(axis: "core"))
        XCTAssertEqual(landed.style, .base)
        XCTAssertEqual(landed.length, .short)
        XCTAssertTrue(landed.logprobGate)        // user's gate survives
        XCTAssertFalse(landed.useRecommended)    // recommendation (Instruct) ≠ landing
        // Where the recommendation IS Base · Short, auto mode stays on.
        XCTAssertTrue(custom.applying(.preset(ModelPriority.balanced.pick(axis: "core"))).useRecommended)

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

    // Per-model gate τ (split-half Q4 edges, runs-2026-07-16) — pin the values
    // so a catalog refactor can't silently unify them back to one global τ.
    func testPerModelGateTau() {
        func tau(_ id: String) -> Double? { ModelCatalog.recommended(for: id).logprobGateTau }
        XCTAssertEqual(tau("mlx-community/gemma-4-e4b-8bit"), -0.75)
        XCTAssertEqual(tau("mlx-community/gemma-4-e4b-6bit"), -0.79)
        XCTAssertEqual(tau("mlx-community/gemma-4-e2b-8bit"), -0.88)
        XCTAssertEqual(tau("mlx-community/gemma-4-e2b-4bit"), -0.94)
        XCTAssertEqual(tau("openbmb/MiniCPM5-1B-Base"), -1.00)
        XCTAssertEqual(tau("mlx-community/Qwen3.5-2B-4bit"), -1.00)
        XCTAssertEqual(tau("mlx-community/Qwen2.5-0.5B-bf16"), -1.12)
        XCTAssertNil(tau(ModelCatalog.appleIntelligenceID))   // no logprob to gate on
    }

    // The injection path chunks UTF-16 at 16 units; a surrogate pair straddling
    // a boundary must never be split (it would post as a broken glyph).
    func testInjectorSurrogateSafeChunking() {
        func chunks(_ s: String, size: Int = 16) -> [[UniChar]] {
            TextInjector.utf16Chunks(Array(s.utf16), chunkSize: size)
        }
        // Every chunk must reassemble to valid UTF-16 (no lone surrogate at an
        // interior chunk's edges) and the concatenation must be lossless.
        func assertClean(_ s: String, size: Int = 16) {
            let cs = chunks(s, size: size)
            XCTAssertEqual(cs.flatMap { $0 }, Array(s.utf16), "lossless round-trip")
            for (i, c) in cs.enumerated() {
                // A non-final chunk must not end on a high surrogate.
                if i < cs.count - 1, let last = c.last {
                    XCTAssertFalse((0xD800...0xDBFF).contains(last), "split surrogate at chunk \(i)")
                }
            }
        }
        // 15 ASCII + one emoji (2 units): the pair would land at units 15–16 and
        // split under naive fixed chunking. It must move whole into chunk 2.
        assertClean(String(repeating: "a", count: 15) + "😀")
        assertClean(String(repeating: "😀", count: 20))          // all astral
        assertClean("plain ascii text under the limit")
        assertClean("")                                            // empty → no chunks
        // Forced tiny size to exercise the boundary densely.
        assertClean("a😀b😀c😀d😀", size: 2)
        // Never emits an empty chunk / never loops forever.
        for c in chunks(String(repeating: "😀", count: 9), size: 2) {
            XCTAssertFalse(c.isEmpty)
        }
    }

    // A wrong answer here nags every user toward a downgrade, so pin the compare.
    @MainActor
    func testUpdateVersionCompare() {
        XCTAssertTrue(UpdateChecker.isNewer("0.2.0", than: "0.1.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.0", than: "0.9.9"))
        // The reason this isn't a string compare.
        XCTAssertTrue(UpdateChecker.isNewer("0.10.0", than: "0.9.1"))
        XCTAssertFalse(UpdateChecker.isNewer("0.9.1", than: "0.10.0"))
        // Equal, older, and shorter/longer forms of the same version.
        XCTAssertFalse(UpdateChecker.isNewer("0.1.0", than: "0.1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.1.0", than: "0.2.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0", than: "1.0.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.1", than: "1.0"))
        // A pre-release never outranks the final tag of the same version.
        XCTAssertFalse(UpdateChecker.isNewer("0.2.0-beta", than: "0.2.0"))
        // Garbage must not read as newer.
        XCTAssertFalse(UpdateChecker.isNewer("", than: "0.1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("nightly", than: "0.1.0"))
    }

    // The user blacklist holds lowercased *substring markers*, not exact bundle
    // IDs, so "enable here again" has to remove whichever entry matched — an
    // exact-ID remove would leave the menu item visibly stuck on "Enable in …".
    func testToggleUserBlacklist() {
        let original = Settings.userBlacklist   // shared with the developer's real app
        defer { Settings.userBlacklist = original }

        // Off → on stores the exact ID, lowercased.
        Settings.userBlacklist = []
        AppPolicy.toggleUserBlacklist("com.apple.Mail")
        XCTAssertEqual(Settings.userBlacklist, ["com.apple.mail"])
        XCTAssertTrue(AppPolicy.isBlacklisted("com.apple.Mail"))

        // On → off removes it again.
        AppPolicy.toggleUserBlacklist("com.apple.Mail")
        XCTAssertEqual(Settings.userBlacklist, [])
        XCTAssertFalse(AppPolicy.isBlacklisted("com.apple.Mail"))

        // A hand-typed fragment must be removed by the toggle, not shadowed by
        // an exact ID appended beside it (which would leave the app silenced).
        Settings.userBlacklist = ["mail", "slack"]
        XCTAssertEqual(AppPolicy.userBlacklistEntries(for: "com.apple.Mail"), ["mail"])
        AppPolicy.toggleUserBlacklist("com.apple.Mail")
        XCTAssertEqual(Settings.userBlacklist, ["slack"])
        XCTAssertFalse(AppPolicy.isBlacklisted("com.apple.Mail"))

        // Built-in blocks are not user entries: nothing to toggle, still blocked.
        Settings.userBlacklist = []
        XCTAssertTrue(AppPolicy.userBlacklistEntries(for: "com.apple.Terminal").isEmpty)
        XCTAssertTrue(AppPolicy.isBlacklisted("com.apple.Terminal"))
    }

    // Deleting model weights points `removeItem` at a cache shared with every
    // other Hugging Face tool on the Mac — pin what may and may not be a target,
    // and the symlink trap that would otherwise double every reported size.
    func testModelStorage() throws {
        // A local fine-tune folder is the user's OWN directory: never a cache repo.
        XCTAssertNil(ModelStorage.directory(for: "/Users/someone/models/my-finetune"))
        // The system model downloads nothing.
        XCTAssertNil(ModelStorage.directory(for: ModelCatalog.appleIntelligenceID))

        let repoDir = try XCTUnwrap(ModelStorage.directory(for: "mlx-community/gemma-4-e2b-4bit"))
        XCTAssertEqual(repoDir.lastPathComponent, "models--mlx-community--gemma-4-e2b-4bit")

        // Nothing is deletable when the entry being inspected is the selected one.
        XCTAssertTrue(ModelStorage.deletableRepos(
            for: "mlx-community/gemma-4-e2b-4bit",
            selected: "mlx-community/gemma-4-e2b-4bit"
        ).isEmpty)

        // The symlink trap: snapshots/ points into blobs/, and resourceValues
        // stats THROUGH symlinks, so a naive recursive walk reports double.
        let manager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ModelStorageTests-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }

        let fakeRepo = root.appendingPathComponent("models--acme--tiny")
        let blobs = fakeRepo.appendingPathComponent("blobs")
        let snapshot = fakeRepo.appendingPathComponent("snapshots/deadbeef")
        try manager.createDirectory(at: blobs, withIntermediateDirectories: true)
        try manager.createDirectory(at: snapshot, withIntermediateDirectories: true)
        for name in ["aaaa1111", "bbbb2222"] {
            let blob = blobs.appendingPathComponent(name)
            try Data(repeating: 0x41, count: 8 * 1024).write(to: blob)
            try manager.createSymbolicLink(
                at: snapshot.appendingPathComponent("\(name).safetensors"),
                withDestinationURL: blob
            )
        }

        let measured = ModelStorage.bytes(at: fakeRepo)
        XCTAssertGreaterThanOrEqual(measured, 16 * 1024)
        XCTAssertLessThan(measured, 24 * 1024, "snapshot symlinks are being counted as real bytes")
    }

    // Suppressing suggestions while an IME composes is all-or-nothing per input
    // source in the apps that don't expose a marked range, so the classification
    // decides whether a Japanese user keeps Tab for the English half of their day.
    func testCompositionInputModeClassification() {
        let mode = kTISTypeKeyboardInputMode as String
        let layout = kTISTypeKeyboardLayout as String

        // Every real IME input mode composes: half-typed romanisation in the
        // field, candidate window owning Tab.
        for modeID in ["com.apple.inputmethod.SCIM.ITABC",           // Pinyin – Simplified
                       "com.apple.inputmethod.Japanese",             // Kotoeri, kana
                       "com.apple.inputmethod.Korean.2SetKorean",    // Hangul
                       "com.apple.inputmethod.VietnameseTelex",      // Telex
                       "com.apple.inputmethod.TransliterationIM.hi"] // Hindi transliteration
        {
            XCTAssertTrue(AXText.isCompositionInputMode(type: mode, modeID: modeID), modeID)
        }

        // The one input mode that does not compose: a Japanese IME's
        // alphanumeric sub-mode reports exactly this for both Romaji and Kana
        // typing — the carve-out that keeps Tab alive for English.
        XCTAssertFalse(AXText.isCompositionInputMode(type: mode, modeID: "com.apple.inputmethod.Roman"))

        // A plain keyboard layout (ABC, "Russian – PC") never composes.
        XCTAssertFalse(AXText.isCompositionInputMode(type: layout, modeID: nil))
        XCTAssertFalse(AXText.isCompositionInputMode(type: layout, modeID: "com.apple.keylayout.ABC"))
    }

    // A shortcode fires an in-place replacement, so the scanner's guards are the
    // whole safety story: everything that merely ends in a colon must stay quiet.
    @MainActor
    func testEmojiShortcodeDetection() {
        // A closed shortcode is detected and resolves.
        XCTAssertEqual(EmojiShortcodes.trailingShortcode(in: "shrug :shrug:"), ":shrug:")
        XCTAssertEqual(EmojiShortcodes.emoji(for: ":shrug:"), "🤷")

        // Only through the system Unicode-name table (no alias entry for these).
        XCTAssertEqual(EmojiShortcodes.emoji(for: ":rocket:"), "🚀")
        XCTAssertEqual(EmojiShortcodes.emoji(for: ":pile_of_poo:"), "💩")
        // Text-presentation legacy dingbat gets VS16 so it renders as emoji.
        XCTAssertEqual(EmojiShortcodes.emoji(for: ":gear:"), "⚙\u{FE0F}")

        // Only through the alias table — Gemoji nicknames are not Unicode names.
        XCTAssertEqual(EmojiShortcodes.emoji(for: ":joy:"), "😂")
        XCTAssertEqual(EmojiShortcodes.emoji(for: ":tada:"), "🎉")

        // "+1"/"-1" are the two letterless bodies that ARE names — the reason
        // +/- are in the scanner's charset at all.
        XCTAssertEqual(EmojiShortcodes.trailingShortcode(in: "nice :+1:"), ":+1:")
        XCTAssertEqual(EmojiShortcodes.emoji(for: ":+1:"), "👍")
        XCTAssertEqual(EmojiShortcodes.emoji(for: ":-1:"), "👎")
        // …while a +1 glued to a number is still arithmetic, not a shortcode.
        XCTAssertNil(EmojiShortcodes.trailingShortcode(in: "3:+1:"))

        // Mid-typing must stay silent: nothing fires until the closing colon.
        XCTAssertNil(EmojiShortcodes.trailingShortcode(in: ":shru"))
        XCTAssertNil(EmojiShortcodes.trailingShortcode(in: "type :roc"))

        // Detected but unknown body → no emoji, so no pill.
        XCTAssertEqual(EmojiShortcodes.trailingShortcode(in: ":asdfqwer:"), ":asdfqwer:")
        XCTAssertNil(EmojiShortcodes.emoji(for: ":asdfqwer:"))

        // Every quiet case: times, ratios, URLs, code, bare colons.
        for quiet in ["10:30", "meet at 10:30:", "http://", "http:", ":", "::",
                      "foo:bar:", "ratio3:4:", "x :100:", ":a:", "ns::member:"] {
            XCTAssertNil(EmojiShortcodes.trailingShortcode(in: quiet), "should stay quiet: \(quiet)")
        }

        // lastToken is what every revalidation path uses: the shortcode when one
        // is closed at the caret, the plain word otherwise. lastWord alone stops
        // at ':' and would read the shortcode back as "".
        XCTAssertEqual(CorrectionController.lastToken(of: "hey :shrug:"), ":shrug:")
        XCTAssertEqual(CorrectionController.lastToken(of: "hey teh"), "teh")
        XCTAssertEqual(CorrectionController.lastWord(of: "hey :shrug:"), "")
    }

    // Imported text must feed BOTH consumers off the one file: the n-gram's ctx
    // chain (deltas must reconstruct the text exactly once, in order) and the
    // RAG corpus (phrase(from:) only accepts .accepted/.typedThrough rows with
    // non-empty ctx+suggestion).
    func testJournalImport() throws {
        // `ingest` re-checks the kill switch on the journal queue (the race-free
        // "off means forget" guard); registerDefaults() only runs in the app, so
        // the test must turn the switch on itself — and restore it.
        let journalWasOn = Settings.suggestionJournalEnabled
        Settings.suggestionJournalEnabled = true
        defer { Settings.suggestionJournalEnabled = journalWasOn }

        let s1 = "Никита пишет диссертацию про кварковые глюоны."
        let s2 = "Кварковые глюоны ведут себя странно при нагреве."
        let s3 = "Никита проверяет гипотезу на симуляции."
        let text = s1 + " " + s2 + " " + s3

        // phraseLimit is a hard cap — the importer passes the REMAINING budget
        // per file, so a limit of 1 must yield exactly 1 row, not limit+1.
        XCTAssertEqual(SuggestionJournal.importEntries(from: text, source: "t", phraseLimit: 1).count, 1)

        // Three sentences, two rows: the first is ctx-seed only.
        let entries = SuggestionJournal.importEntries(from: text, source: "thesis.txt")
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map(\.suggestion), [s2, s3])
        XCTAssertEqual(entries[0].app, "import:thesis.txt")
        XCTAssertEqual(entries[0].engine, "import")
        XCTAssertEqual(entries[0].outcome, .typedThrough)
        XCTAssertEqual(entries[0].ctx, s1 + " ")

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-import-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = SuggestionJournal(url: url)
        journal.ingest(entries)
        XCTAssertGreaterThan(journal.fileSize, 0)   // flush barrier

        // The ctx chain deltas out to every sentence but the last, exactly once
        // and in order — this is what breaks if the snapshots double-count.
        XCTAssertEqual(journal.typedStreamChunks().joined(), s1 + " " + s2 + " ")

        // A fresh instance loads the imported rows into the retrieval corpus —
        // this is what breaks if outcome/ctx make phrase(from:) reject them.
        let fresh = SuggestionJournal(url: url)
        let found = fresh.similarAcceptedPhrases(to: "кварковые глюоны разогрели")
        XCTAssertTrue(found.contains { $0.next == s2 }, "imported phrase not retrieved: \(found.map(\.next))")
    }

    // The login item's truth lives in launchd, so the only thing to pin is the
    // mapping: only .enabled is "on" — .requiresApproval is registered but held
    // by macOS, and a switch that shows it as on would be lying.
    func testLoginItemStatusMapping() {
        XCTAssertTrue(LoginItem.isOn(.enabled))
        XCTAssertFalse(LoginItem.isOn(.requiresApproval))
        XCTAssertFalse(LoginItem.isOn(.notRegistered))
        XCTAssertFalse(LoginItem.isOn(.notFound))
        // Held-by-macOS is the one state that needs its own explanation.
        XCTAssertNotNil(LoginItem.note(.requiresApproval))
    }
}
