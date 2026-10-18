import XCTest
@testable import Pretype

/// A focus change on a real controller: what goes with the field left, and
/// what is made ready for the field entered — at once, and once the focus
/// has settled.
@MainActor
final class FocusPipelineTests: PipelineTestCase {
    /// The tracker reports a new field (`FocusTracker.onFocusChange`).
    private func focusMoves() {
        controller.focusTracker.onFocusChange?()
    }

    private var bigText: HostTextStyle {
        var style = HostTextStyle()
        style.font = .systemFont(ofSize: 20)
        return style
    }

    // The old field's caret and style say nothing about the next one: a
    // notice drawn before its first read would sit at the old caret.
    func testTheOldCaretGoesWithTheField() {
        controller.noteCaret(rect: CGRect(x: 5, y: 5, width: 1, height: 20), host: bigText)
        fake.tracked = nil
        focusMoves()
        XCTAssertNil(controller.lastCaretRect)
        XCTAssertEqual(controller.lastHostStyle, HostTextStyle())
    }

    // Entered while the model loads: its progress goes up at the new caret,
    // in the new field's style, before any key is typed.
    func testAFieldEnteredWhileTheModelLoadsShowsItsProgressThere() {
        fake.engine.state = .preparing("loading")
        fake.host = bigText
        focusMoves()
        XCTAssertEqual(controller.lastCaretRect, CGRect(x: 100, y: 100, width: 1, height: 16))
        XCTAssertEqual(controller.lastHostStyle, bigText)
        XCTAssertNotNil(controller.indicator.timer)
    }

    // The overlay forgets the old field's style, and a field the tracker
    // missed takes its site with it.
    func testTheOldFieldsStyleAndSiteStayBehind() {
        fake.tracked = nil
        fake.systemField = FakeWorld.element(5)
        fake.site = "bank.example.com"
        controller.textDidChange()
        XCTAssertEqual(controller.typingContext.site, "bank.example.com")
        focusMoves()
        XCTAssertEqual(fake.window.fieldChanges, 1)
        XCTAssertNil(controller.typingContext.site)
        controller.textDidChange()
        XCTAssertEqual(fake.siteReads, 2, "the same field, entered again, is read again")
    }

    // A field entered wakes the model — but not while paused or on battery,
    // nor outside a field we read.
    func testEnteringAFieldWakesTheModel() {
        focusMoves()
        XCTAssertEqual(fake.engine.prewarms, 1)
        set(\.enabled, false)
        focusMoves()
        set(\.enabled, true)
        fake.pausedForBattery = true
        focusMoves()
        fake.pausedForBattery = false
        fake.tracked = nil
        focusMoves()
        XCTAssertEqual(fake.engine.prewarms, 1)
    }

    // …nor in an app Pretype stays out of.
    func testAnAppWeStayOutOfIsNotWoken() async {
        set(\.userBlacklist, ["com.example.notes"])
        await enterApp("com.example.notes")
        XCTAssertEqual(fake.engine.prewarms, 0)
    }

    // …nor in one where its suggestions go unused (`Stats.isUnproductive`).
    func testAnAppWhereSuggestionsGoUnusedIsNotWoken() async {
        fake.unproductive = ["com.example.quiet"]
        await enterApp("com.example.quiet")
        XCTAssertEqual(fake.engine.prewarms, 0)
    }

    // A hands-free capture belongs to the field it started in.
    func testAFocusChangeEndsAHandsFreeCapture() async {
        await startHandsFreeCapture()
        focusMoves()
        XCTAssertFalse(controller.dictationController.isBusy)
    }

    // An inline fix ⎋-dismissed in one field is offered again in the next.
    func testAFixDismissedInOneFieldIsOfferedInTheNext() throws {
        fake.before = "Hi 12*7="
        controller.textDidChange()
        XCTAssertEqual(fake.window.currentMode, .correction(original: "12*7=", fix: "12*7=84"))
        try press(KeyCode.escape)
        controller.textDidChange()
        XCTAssertNil(fake.window.currentMode)
        focusMoves()
        controller.textDidChange()
        XCTAssertEqual(fake.window.currentMode, .correction(original: "12*7=", fix: "12*7=84"))
    }

    // The accepted phrases retrieved for one field stay out of the next
    // field's prompt.
    func testTheOldFieldsExamplesStayBehind() async throws {
        fake.phrases = [SuggestionJournal.AcceptedPhrase(ctx: "see you", next: " soon")]
        fake.before = "Hi, see you at"
        controller.textDidChange()
        try await finishQuery()
        let end = Date().addingTimeInterval(5)
        while fake.engine.warmed.isEmpty, Date() < end { await Task.yield() }
        fake.before = "Hi, see you at n"
        controller.textDidChange()
        try await finishQuery()
        XCTAssertEqual(fake.engine.requests.last?.personalExamples.count, 1)

        focusMoves()
        fake.before = "Hi, see you at no"
        controller.textDidChange()
        try await finishQuery()
        XCTAssertEqual(fake.engine.requests.last?.personalExamples.count, 0)
    }

    // MARK: - Once the focus has settled (0.8 s)

    // With no capture coming, the new field's prompt is warmed — once, for
    // the field the focus settled in.
    func testTheSettledFieldsPromptIsWarmed() {
        fake.before = "Hi "
        focusMoves()
        focusMoves()
        fake.advance(0.79)
        XCTAssertTrue(fake.engine.warmed.isEmpty, "not before the focus settled")
        fake.advance(0.01)
        XCTAssertEqual(fake.engine.warmed, ["Hi "])
    }

    // With screen context on, the window is read for the new field.
    func testTheSettledFieldsScreenIsRead() async {
        set(\.screenContextEnabled, true)
        await enterApp("com.example.notes")
        fake.advance(0.8)
        await settleMain()
        XCTAssertEqual(fake.captures.count, 1)
    }

    // In a chat, an empty message box is offered a reply instead.
    func testAnEmptyChatBoxIsOfferedAReply() async {
        set(\.autoReply, true)
        set(\.screenContextEnabled, true)
        fake.before = ""
        await enterApp("com.tinyspeck.slackmacgap")
        fake.advance(0.8)
        XCTAssertTrue(controller.queries.isReply)
        XCTAssertTrue(fake.engine.warmed.isEmpty)
    }

    // Not in a box with text in it — that one's screen is read for the
    // completion instead — nor outside a chat, nor with the offer off.
    func testOnlyAnEmptyChatBoxIsOfferedAReply() async {
        set(\.autoReply, true)
        set(\.screenContextEnabled, true)
        fake.before = "Hi "
        await enterApp("com.tinyspeck.slackmacgap")
        fake.advance(0.8)
        await settleMain()
        XCTAssertFalse(controller.queries.isReply)
        XCTAssertEqual(fake.captures, [ScreenContext.defaultMaxChars])

        fake.before = ""
        await enterApp("com.example.notes")
        fake.advance(0.8)
        XCTAssertFalse(controller.queries.isReply)

        set(\.autoReply, false)
        await enterApp("com.tinyspeck.slackmacgap")
        fake.advance(0.8)
        XCTAssertFalse(controller.queries.isReply)
    }

    // Leaving the app drops the ghost left at its caret.
    func testLeavingTheAppDropsTheGhost() {
        showGhost("to be", on: "Hi ")
        controller.focusTracker.onResignActiveApp?()
        XCTAssertNil(fake.window.ghost)
        XCTAssertNil(controller.field.ghost)
    }
}
