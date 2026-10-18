import XCTest
@testable import Pretype

/// The AX notifications' coalesced read and the keystroke's fallback re-read,
/// on a real controller with a clock that moves only when told.
@MainActor
final class RereadPipelineTests: PipelineTestCase {
    /// The app posts the edit's two notifications: selection, then value.
    private func notify() {
        controller.focusTracker.onTextChange?(false)
        controller.focusTracker.onTextChange?(true)
    }

    // An edit whose notifications came is read once, on them, and the
    // keystroke's fallback stands down. Every key starts over: the next one,
    // in an app whose notifications stopped (Electron), still gets its read.
    func testEachKeyGetsItsFallbackUnlessItsNotificationsWereRead() throws {
        fake.before = "Hi"
        try type("!")
        notify()
        fake.advance(0.01)
        XCTAssertEqual(fake.reads, 1, "one read answers both notifications")
        fake.advance(0.1)
        XCTAssertEqual(fake.reads, 1, "the fallback stood down")
        try type("?")
        fake.advance(0.1)
        XCTAssertEqual(fake.reads, 2)
    }

    // An accept's own re-read is no fallback: notifications read since the
    // last key don't stand it down — the keys it typed have to be seen.
    func testAnAcceptsReReadIsNoFallback() throws {
        showGhost("to be", on: "Hi ")
        fake.before = "Hi"
        try type("!")
        notify()
        fake.advance(0.01)
        fake.before = "Hi "
        let reads = fake.reads
        try press(KeyCode.tab, .maskShift)   // no ghost: the app's key
        showGhost("to be", on: "Hi ")
        let accepted = fake.reads
        try press(KeyCode.tab)
        fake.before = "Hi to"
        fake.advance(0.1)
        XCTAssertGreaterThan(accepted, reads)
        XCTAssertEqual(fake.reads, accepted + 1, "read after the accept's keys landed")
    }

    // The keystroke's fallback reads 60 ms after the key; the notifications'
    // coalesced read 4 ms after the first of them.
    func testTheReReadsTiming() throws {
        fake.before = "Hi"
        try type("!")
        fake.advance(0.05)
        XCTAssertEqual(fake.reads, 0)
        fake.advance(0.01)
        XCTAssertEqual(fake.reads, 1)
        notify()
        fake.advance(0.003)
        XCTAssertEqual(fake.reads, 1)
        fake.advance(0.001)
        XCTAssertEqual(fake.reads, 2)
    }

    // Only a read that got the field stands in for the fallback: one that
    // timed out (Electron) leaves the keystroke its second chance.
    func testAFailedNotificationReadKeepsTheFallback() throws {
        fake.before = "Hi"
        try type("!")
        notify()
        fake.readable = false
        fake.advance(0.01)
        XCTAssertEqual(fake.reads, 0)
        fake.readable = true
        fake.advance(0.1)
        XCTAssertEqual(fake.reads, 1)
    }
}
