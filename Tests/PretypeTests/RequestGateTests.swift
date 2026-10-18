import XCTest
@testable import Pretype

/// The pipeline's request gates — `RequestGate` — row by row: when a field
/// pass reads the field, which reads ask nothing new, what the n-gram offers
/// instantly, and what of an engine answer lands.
@MainActor
final class RequestGateTests: XCTestCase {
    private typealias G = RequestGate

    // MARK: - Entry

    /// The verdict, and which lazy reads it made.
    private func entry(_ pass: G.Pass, field: Int? = 7, siteBlocked: Bool = false)
        -> (verdict: G.Entry<Int>, looked: Bool, askedSite: Bool) {
        var looked = false, askedSite = false
        let verdict = G.entry(pass, findField: { looked = true; return field },
                              siteBlocked: { askedSite = true; return siteBlocked })
        return (verdict, looked, askedSite)
    }

    func testEntryRows() {
        typealias Row = (pass: G.Pass, field: Int?, site: Bool, verdict: G.Entry<Int>, looked: Bool, line: UInt)
        let rows: [Row] = [
            (G.Pass(), 7, false, .read(7), true, #line),
            // Paused, or a capture owns the overlay: nothing at all, no read.
            (G.Pass(enabled: false), 7, false, .idle, false, #line),
            (G.Pass(dictating: true, ownWindowFrontmost: true), 7, false, .idle, false, #line),
            (G.Pass(enabled: false, appAllowed: false), 7, false, .idle, false, #line),
            // Our own window: everything goes, silently, before any read.
            (G.Pass(ownWindowFrontmost: true, appAllowed: false), 7, false, .dismiss(why: nil), false, #line),
            (G.Pass(appAllowed: false, hasGhost: true), 7, false,
             .dismiss(why: "suggestions are off in blacklisted apps"), false, #line),
            // No field: said only when a ghost goes with it.
            (G.Pass(hasGhost: true), nil, true, .dismiss(why: "lost text element"), true, #line),
            (G.Pass(), nil, true, .dismiss(why: nil), true, #line),
            (G.Pass(), 7, true, .dismiss(why: "suggestions are off on this site"), true, #line),
        ]
        for row in rows {
            let got = entry(row.pass, field: row.field, siteBlocked: row.site)
            XCTAssertEqual(got.verdict, row.verdict, line: row.line)
            XCTAssertEqual(got.looked, row.looked, "the field lookup is an AX read", line: row.line)
            XCTAssertEqual(got.askedSite, row.field != nil && row.looked, line: row.line)
        }
    }

    // MARK: - After the read

    func testACaretSplitsAWordBeforeALetterOrDigit() {
        for (after, splits) in [("", false), (" world", false), ("world", true), ("5", true), ("é", true),
                                (".", false), ("\nnext", false), ("-x", false)] {
            XCTAssertEqual(G.caretSplitsWord(before: after), splits, "\"\(after)\"")
        }
    }

    // The reasons in the order "Last:" gives them: the app's record first,
    // then the battery rule, then the decline.
    func testQuietReasonsInOrder() {
        let quiet = "quiet in this app — suggestions here are almost never taken"
        let battery = "paused on battery", declined = "dismissed — waiting for an edit"
        for unproductive in [false, true] {
            for onBattery in [false, true] {
                for isDeclined in [false, true] {
                    let want: String? = unproductive ? quiet : onBattery ? battery : isDeclined ? declined : nil
                    XCTAssertEqual(G.quietReason(unproductive: unproductive, onBattery: onBattery, declined: isDeclined),
                                   want, "\(unproductive) \(onBattery) \(isDeclined)")
                }
            }
        }
    }

    // MARK: - The n-gram's instant suggestion

    private lazy var ngram: PersonalNgram = {
        let ngram = PersonalNgram()
        for _ in 0..<3 { ngram.learn("thanks for the quick reply") }
        return ngram
    }()

    func testTheInstantSuggestion() {
        func instant(_ text: String, _ after: String = "") -> String? {
            G.instantSuggestion(text: text, after: after, ngram: ngram)
        }
        // After a space: the next word.
        XCTAssertEqual(instant("thanks for the quick "), "reply")
        // Mid-word: the rest of the word.
        XCTAssertEqual(instant("thanks for the qui"), "ck")
        // At the end of a complete word: a space and the next word.
        XCTAssertEqual(instant("thanks for the quick"), " reply")
        // Nothing after punctuation, and nothing the history doesn't know.
        XCTAssertNil(instant("thanks for the quick."))
        XCTAssertNil(instant("thanks for the slow "))
        // Twelve characters at least: a field that short says too little.
        XCTAssertNil(instant("Xthe quick "))
        XCTAssertEqual(instant("XYthe quick "), "reply")
        // Never what already follows the caret.
        XCTAssertNil(instant("thanks for the quick ", "reply soon"))
        XCTAssertNil(instant("thanks for the quick", "  reply"))
        XCTAssertEqual(instant("thanks for the quick ", "re"), "reply")
        // A partial word that is no word: nothing, though the history knows
        // what follows it as a word.
        let names = PersonalNgram()
        for _ in 0..<3 { names.learn("say the word zqxwv plugh") }
        XCTAssertNil(G.instantSuggestion(text: "say the word zqxwv", after: "", ngram: names))
        XCTAssertEqual(G.instantSuggestion(text: "say the word zqxwv ", after: "", ngram: names), "plugh")
    }

    // MARK: - An answer landing

    func testWhatOfAnAnswerLands() {
        typealias Row = (suggestion: String, asked: String, current: String, landing: G.Landing, line: UInt)
        let rows: [Row] = [
            ("there", "Hi ", "Hi ", .show("there"), #line),
            // Typed on meanwhile: what they typed is its head, the rest lands.
            ("there", "Hi ", "Hi th", .show("ere"), #line),
            ("there", "Hi ", "Hi there", .stale(why: "typed past the suggestion"), #line),
            ("there", "Hi ", "Hi x", .stale(why: "typed past the suggestion"), #line),
            ("there", "Hi ", "Ho", .stale(why: "context changed; dropped result"), #line),
            // Normalized: a stray separator, a doubled seam space, a capital.
            (" вет", "при", "при", .show("вет"), #line),
            (" ответ", "спасибо за ", "спасибо за ", .show("ответ"), #line),
            ("Поехать", "я хочу ", "я хочу ", .show("поехать"), #line),
            // A new word fused onto the half-typed one is retired; a word's
            // own ending, a fresh word after a space, or a seam that isn't
            // mid-word all land.
            ("fox", "the quick bro", "the quick bro", .glued, #line),
            ("wn fox", "the quick bro", "the quick bro", .show("wn fox"), #line),
            (" fox", "the quick brown", "the quick brown", .show(" fox"), #line),
            ("fox", "the quick ", "the quick ", .show("fox"), #line),
        ]
        for row in rows {
            XCTAssertEqual(G.landing(row.suggestion, askedOn: row.asked, current: row.current), row.landing,
                           line: row.line)
        }
    }

    // The glue rule on its own: only mid-word, only a flush answer, only a
    // real word fused into a non-word.
    func testWouldGlueMidWord() {
        let glue = SuggestionController.wouldGlueMidWord
        XCTAssertTrue(glue("the quick bro", "fox jumps"))
        XCTAssertFalse(glue("I really appreci", "ate it"), "appreci + ate is a word")
        XCTAssertFalse(glue("the quick bro", " fox"), "a space starts a new word")
        XCTAssertFalse(glue("the quick ", "fox"), "not mid-word")
        XCTAssertFalse(glue("the quick 12", "fox"), "a digit is no partial word")
        XCTAssertFalse(glue("the quick bro", "...fox"), "no first word to glue")
        XCTAssertFalse(glue("the quick bro", "xqzv"), "not a word on its own")
    }
}
