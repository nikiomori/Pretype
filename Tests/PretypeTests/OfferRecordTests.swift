import XCTest
@testable import Pretype

/// The record of an offer from show to resolve: kept current while its ghost
/// grows, trims and is accepted, closed once, stamped with what it came to.
final class OfferRecordTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private func entry(ctx: String, suggestion: String) -> SuggestionJournal.Entry {
        SuggestionJournal.Entry(ts: "", app: "com.example.chat", engine: "fake", ctx: ctx, after: "",
                                suggestion: suggestion, outcome: .abandoned, acceptedChars: 0,
                                shownForMs: 0, screen: false)
    }

    func testAnOfferIsStampedWithWhatItCameTo() throws {
        var record = OfferRecord()
        XCTAssertFalse(record.isOpen)
        record.open(entry(ctx: "Hi ", suggestion: "to"), at: t0)
        XCTAssertTrue(record.isOpen)
        record.showing("to be or", at: "Hi ")      // streamed growth
        record.accepted("to")
        record.showing(" be", at: "Hi to")         // trimmed to the line after ⇥
        let resolved = try XCTUnwrap(record.resolve(.diverged, ghost: " be", at: t0.addingTimeInterval(0.25)))
        XCTAssertEqual(resolved.suggestion, "to be", "the offer as of its ctx")
        XCTAssertEqual(resolved.outcome, .diverged)
        XCTAssertEqual(resolved.shownForMs, 250)
        XCTAssertEqual(resolved.acceptedChars, 2)
        XCTAssertEqual(resolved.consumedChars, 2)
        XCTAssertEqual(resolved.app, "com.example.chat", "the app it was shown in")
        XCTAssertFalse(record.isOpen)
        XCTAssertNil(record.resolve(.dismissed, ghost: " be", at: t0), "the first resolution wins")
    }

    // Superseded: the ghost on screen is already the newer offer's.
    func testASupersededOfferTakesNothingFromTheScreen() throws {
        var record = OfferRecord()
        record.open(entry(ctx: "Hi ", suggestion: "to be"), at: t0)
        let resolved = try XCTUnwrap(record.resolve(.superseded, ghost: "so", at: t0))
        XCTAssertNil(resolved.consumedChars)
        record.showing("x", at: "Hi ")
        XCTAssertFalse(record.isOpen, "nothing to keep current")
    }

    // The record holds the whole offer as of its ctx, and how much of it the
    // user took — the live first-word signal journal-report.py reads.
    func testJournalOfferAndConsumed() {
        // A stream re-anchored after the user typed "hel": the rest is "lo world".
        XCTAssertEqual(OfferRecord.journalSuggestion("lo world", current: "Say hel", recordCtx: "Say "), "hello world")
        XCTAssertEqual(OfferRecord.journalSuggestion("hello", current: "Say ", recordCtx: "Say "), "hello")
        // Context jumped away from the record: nothing to prepend.
        XCTAssertEqual(OfferRecord.journalSuggestion("x", current: "Other", recordCtx: "Say "), "x")
        XCTAssertEqual(OfferRecord.journalSuggestion("x", current: "Say ", recordCtx: nil), "x")
        // Typed "hello" of "hello world", then went another way.
        XCTAssertEqual(OfferRecord.consumedChars(outcome: .diverged, offered: "hello world", remaining: " world"), 5)
        XCTAssertEqual(OfferRecord.consumedChars(outcome: .accepted, offered: "hello world", remaining: " world"), 11)
        // Typed all of it by hand: all of it was taken, whatever the screen still shows.
        XCTAssertEqual(OfferRecord.consumedChars(outcome: .typedThrough, offered: "hello world", remaining: " world"), 11)
        XCTAssertEqual(OfferRecord.consumedChars(outcome: .dismissed, offered: "hi", remaining: "hi there"), 0)
    }
}
