import XCTest
@testable import Pretype

/// What the pipeline books for an offer — the counters behind "accepted of
/// shown" and the journal the personalization learns from — seen through the
/// environment's books on a real controller.
@MainActor
final class OfferBookingTests: PipelineTestCase {
    // ⇥ took a word, then the user typed another way: booked as taken — or
    // accepted-of-shown passes 100 % — with how much of it was consumed.
    func testAWordAcceptThenADivergenceBooksWhatWasTaken() throws {
        showGhost("to be", on: "Hi ")
        try press(KeyCode.tab)
        try type("x")
        let offer = try XCTUnwrap(fake.offers.first)
        XCTAssertEqual(fake.offers.count, 1)
        XCTAssertEqual(offer.outcome, .diverged)
        XCTAssertEqual(offer.suggestion, "to be")
        XCTAssertEqual(offer.acceptedChars, 2)
        XCTAssertEqual(offer.consumedChars, 2)
    }

    // How long a ghost stayed up is on the pipeline's clock: the menu's
    // "glanced at, not ignored" split (`Stats.isChance`) reads it.
    func testAnOfferIsTimedFromShownToResolved() throws {
        showGhost("to be", on: "Hi ")
        fake.now += 1.25
        try press(KeyCode.escape)
        XCTAssertEqual(fake.offers.map(\.shownForMs), [1250])
    }

    // A stream whose ghost was retired under it (here by a ⌘-chord) and shows
    // again is a fresh offer: booked when it resolves, not shown — and
    // acceptable — with nothing behind it.
    func testAStreamShownAgainAfterItsGhostRetiredIsBookedAgain() throws {
        showGhost("to be", on: "Hi ")
        try press(Self.keyC, .maskCommand, typing: "c")
        XCTAssertEqual(fake.offers.map(\.outcome), [.abandoned])
        XCTAssertTrue(controller.apply("to be or", requestText: "Hi ", countShown: false))
        XCTAssertEqual(fake.window.ghost, "to be or")
        try press(KeyCode.escape)
        XCTAssertEqual(fake.offers.map(\.outcome), [.abandoned, .dismissed])
        XCTAssertEqual(fake.offers.last?.suggestion, "to be or")
    }
}
