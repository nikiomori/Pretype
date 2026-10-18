import XCTest
@testable import Pretype

@MainActor
private final class FakeIndicatorHost: IndicatorHost {
    var lastCaretRect: CGRect? = CGRect(x: 10, y: 10, width: 1, height: 16)
    var lastHostStyle = HostTextStyle()
    var hasActiveSuggestion = false
    var isWorking = false
    var engineState = EngineState.ready
}

/// The indicator's beats, one `tick` at a time: dots only for a slow query,
/// a status only past a warm reload, and nothing ever drawn over a ghost.
@MainActor
final class CaretIndicatorTests: XCTestCase {
    private var host = FakeIndicatorHost()
    private var window = FakeOverlay()
    private var indicator: CaretIndicator?

    private func make() -> CaretIndicator {
        host = FakeIndicatorHost()
        window = FakeOverlay()
        let made = CaretIndicator(host: host, window: window)
        indicator = made
        return made
    }

    override func tearDown() {
        indicator?.stop()
        indicator = nil
        super.tearDown()
    }

    // Only a query slower than a blink earns dots: the first beat stays
    // silent, the second draws them — and never over a ghost.
    func testThinkingDotsWaitABeatAndNeverCoverAGhost() {
        let indicator = make()
        host.isWorking = true
        indicator.tick()
        XCTAssertNil(window.currentMode)
        indicator.tick()
        XCTAssertEqual(window.currentMode, .thinking(2))
        window.hide(force: true)
        host.hasActiveSuggestion = true
        indicator.tick()
        XCTAssertNil(window.currentMode)
    }

    // A warm reload finishes before a status could be read: only a load past
    // four beats (~0.9 s, a cold start or a download) shows one.
    func testALoadEarnsAStatusOnlyPastAWarmReload() {
        let indicator = make()
        host.engineState = .preparing("downloading 40%")
        for _ in 0..<3 { indicator.tick() }
        XCTAssertNil(window.currentMode)
        indicator.tick()
        XCTAssertEqual(window.currentMode, .status("downloading 40%"))
    }

    // Done and idle: the dots go — but a suggestion that landed keeps the window.
    func testIdleClearsTheDotsButNotAGhost() {
        let indicator = make()
        host.isWorking = true
        indicator.tick()
        indicator.tick()
        host.isWorking = false
        indicator.tick()
        XCTAssertNil(window.currentMode)
        window.show(mode: .suggestion("to be"), at: .zero)
        host.hasActiveSuggestion = true
        indicator.tick()
        XCTAssertEqual(window.currentMode, .suggestion("to be"))
    }

    func testAFailedEngineSaysSo() {
        let indicator = make()
        host.engineState = .failed("no model")
        indicator.tick()
        guard case .error = window.currentMode else { return XCTFail("no notice") }
    }

    // A notice never covers a live ghost. With the caret forgotten (a scroll)
    // it has nowhere to go — unless it answers an explicit chord, which goes
    // where the user is looking.
    func testANoticeNeverCoversAGhost() {
        let indicator = make()
        host.hasActiveSuggestion = true
        indicator.flashTransient(.hint("done"))
        XCTAssertNil(window.currentMode)
        host.hasActiveSuggestion = false
        host.lastCaretRect = nil
        indicator.flashTransient(.hint("done"))
        XCTAssertNil(window.currentMode)
        indicator.flashTransient(.hint("done"), orAtPointer: true)
        XCTAssertEqual(window.currentMode, .hint("done"))
    }
}
