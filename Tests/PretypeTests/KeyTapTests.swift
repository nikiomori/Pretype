import AppKit
import XCTest
@testable import Pretype

/// The key tap without a tap: how an event is routed, the report of a tap
/// macOS turned off, and the global scroll monitor's life.
@MainActor
final class KeyTapTests: XCTestCase {
    private func event() throws -> CGEvent {
        try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(KeyCode.tab), keyDown: true))
    }

    // A key-down is the handler's to swallow; a modifier edge is only
    // observed; anything else passes untouched.
    func testTheTapRoutesEachEvent() throws {
        let tap = KeyTap(), key = try event()
        XCTAssertFalse(tap.route(.keyDown, key), "no handler")
        var keys = 0, edges = 0
        tap.handler = { _ in
            keys += 1
            return true
        }
        tap.flagsHandler = { _ in edges += 1 }
        XCTAssertTrue(tap.route(.keyDown, key))
        XCTAssertFalse(tap.route(.flagsChanged, key))
        XCTAssertFalse(tap.route(.keyUp, key))
        XCTAssertEqual(keys, 1)
        XCTAssertEqual(edges, 1)
        tap.handler = { _ in false }
        XCTAssertFalse(tap.route(.keyDown, key))
    }

    // A tap macOS turned off is turned back on, and its owner hears of it
    // once the callback has returned.
    func testATapTurnedOffIsReported() async throws {
        let tap = KeyTap()
        var reenabled = 0
        tap.reenabledHandler = { reenabled += 1 }
        XCTAssertFalse(tap.route(.tapDisabledByTimeout, try event()))
        XCTAssertFalse(tap.route(.tapDisabledByUserInput, try event()))
        XCTAssertEqual(reenabled, 0, "not inside the callback")
        let done = expectation(description: "the main queue drained")
        DispatchQueue.main.async { done.fulfill() }
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(reenabled, 2)
    }

    // The global scroll monitor is up while wanted — one, however often it
    // is asked for — and gone when not; a tap never created is not active.
    func testTheScrollMonitorFollowsWantsScroll() {
        let tap = KeyTap()
        XCTAssertFalse(tap.isActive)
        XCTAssertNil(tap.scrollMonitor)
        tap.wantsScroll = true
        let monitor = tap.scrollMonitor as AnyObject?
        XCTAssertNotNil(monitor)
        tap.wantsScroll = true
        XCTAssertTrue(tap.scrollMonitor as AnyObject? === monitor, "one monitor, not one per request")
        tap.wantsScroll = false
        XCTAssertNil(tap.scrollMonitor)
        tap.wantsScroll = true
        tap.stop()
        XCTAssertNil(tap.scrollMonitor)
        XCTAssertFalse(tap.wantsScroll)
    }
}
