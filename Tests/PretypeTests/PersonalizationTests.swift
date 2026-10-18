import XCTest
@testable import Pretype

final class PersonalizationTests: XCTestCase {
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
                shownForMs: 250, screen: false)
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
        XCTAssertNil(old.personalization)
        XCTAssertNil(old.firstWordLogProb)
        XCTAssertEqual(old.suggestion, " x")
        XCTAssertEqual(old.outcome, .accepted)

        // 2. A fully-stamped entry round-trips through encode → decode.
        var stamped = SuggestionJournal.Entry(
            ts: "t", app: "com.test", engine: "MLX",
            ctx: "привет, как", after: "", suggestion: " дела", outcome: .accepted,
            acceptedChars: 5, shownForMs: 250, screen: false)
        stamped.model = "gemma-4-e2b-8bit"
        stamped.style = "base"
        stamped.personalization = "subtle"
        stamped.firstWordLogProb = -0.42
        let back = try JSONDecoder().decode(
            SuggestionJournal.Entry.self, from: JSONEncoder().encode(stamped))
        XCTAssertEqual(back.model, "gemma-4-e2b-8bit")
        XCTAssertEqual(back.style, "base")
        XCTAssertEqual(back.personalization, "subtle")
        XCTAssertEqual(back.firstWordLogProb ?? .nan, -0.42, accuracy: 1e-9)

        // 3. nil optionals are omitted (synthesized encodeIfPresent) — a bare
        //    entry (undo / ngram / legacy) must not bloat the journal with null keys.
        let bare = SuggestionJournal.Entry(
            ts: "t", app: nil, engine: nil,
            ctx: "c", after: "", suggestion: "x", outcome: .diverged,
            acceptedChars: 0, shownForMs: 0, screen: false)
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(bare), encoding: .utf8))
        XCTAssertFalse(json.contains("firstWordLogProb"))
        XCTAssertFalse(json.contains("\"model\""))

        // 4. A row stamped before the `gate` field retired still decodes.
        let gated = #"{"ts":"t","engine":"MLX","gate":"off","personalization":"subtle+rag","ctx":"c","after":"","suggestion":"x","outcome":"accepted","acceptedChars":1,"shownForMs":0,"screen":false}"#
        let retired = try JSONDecoder().decode(SuggestionJournal.Entry.self, from: Data(gated.utf8))
        XCTAssertEqual(retired.personalization, "subtle+rag")
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
                acceptedChars: 0, shownForMs: 100, screen: false)
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
                acceptedChars: 0, shownForMs: 100, screen: false)
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
        // Prefix-bucketed vocabulary: case-folded lookup, every word counted once.
        XCTAssertEqual(ngram.completeWord(partial: "ник"), "ите")
        XCTAssertEqual(ngram.wordCount, 12)

        ngram.reset()
        XCTAssertNil(ngram.nextWord(after: "ну спасибо за быстрый "))
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
        XCTAssertEqual(ngram.wordCount, 3)   // передай, Никите, привет — nothing from slack
    }

    // Imported text must feed BOTH consumers off the one file: the n-gram's ctx
    // chain (deltas must reconstruct the text exactly once, in order) and the
    // RAG corpus (phrase(from:) only accepts .accepted/.typedThrough rows with
    // non-empty ctx+suggestion).
    func testJournalImport() throws {
        // `ingest` re-checks the kill switch on the journal queue (the race-free
        // "off means forget" guard); the test process's defaults may hold it
        // off, so the test must turn the switch on itself — and restore it.
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
        let entries = SuggestionJournal.importEntries(from: text, source: "thesis.txt", phraseLimit: 500)
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
}
