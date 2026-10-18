import ApplicationServices
import XCTest
@testable import Pretype

/// The pipeline as the fix flows see it, recording what they ask of it.
@MainActor
private final class FakeCorrectionHost: CorrectionHost, IndicatorHost {
    var typingContext = TypingContext()
    let engine: CompletionEngine
    var focusGeneration = 0
    var lastCaretRect: CGRect?
    var lastHostStyle = HostTextStyle()
    var hasActiveSuggestion = false
    var isWorking = false
    var engineState = EngineState.ready
    private(set) var events: [String] = []
    private(set) var typed: [(text: String, deleted: String, before: String?)] = []
    private(set) var completionsCleared = 0
    private(set) var refreshes = 0

    init(engine: CompletionEngine) { self.engine = engine }

    func noteCaret(_ rect: CGRect) { lastCaretRect = rect }
    func recoverCaret(_ rect: CGRect?) { if lastCaretRect == nil { lastCaretRect = rect } }
    func report(_ event: String) { events.append(event) }
    func currentTextElement() -> AXUIElement? { FakeWorld.element(1) }
    func clearActiveCompletion() { completionsCleared += 1 }
    func typeFix(_ text: String, deleting deleted: String, over before: String?) {
        typed.append((text, deleted, before))
        refreshes += 1
    }
}

/// The fix flows on a fake host: an inline fix shown over its token and
/// applied only while the field still holds it, ⎋ suppressing it, and an
/// engine fix of a selection previewed, then typed over it on ⏎.
@MainActor
final class CorrectionControllerTests: XCTestCase {
    private let world = FakeWorld()
    private lazy var host = FakeCorrectionHost(engine: world.engine)
    private lazy var indicator = CaretIndicator(host: host, window: world.window)
    private lazy var fixes = CorrectionController(host: host, env: world.env, indicator: indicator)
    private let caret = CGRect(x: 100, y: 100, width: 1, height: 16)

    override func tearDown() {
        fixes.reset()
        indicator.stop()
        super.tearDown()
    }

    private func read(_ before: String) -> TextContext {
        TextContext(textBeforeCaret: before, textAfterCaret: "", caretRect: caret, host: HostTextStyle())
    }

    /// Until `condition` holds — the engine's answer hops off the main actor
    /// and back. The deadline only bounds a wedge.
    private func waitUntil(_ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(5)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(1)) }
    }

    // "12*7=" at the caret: its answer is offered over the token, preempting
    // a completion, and ⇥ types it — re-reading the field first, off the tap.
    func testAnInlineFixIsTypedOverItsTokenOnTab() {
        XCTAssertTrue(fixes.handleCaret(read("Hi 12*7=")))
        XCTAssertEqual(world.window.currentMode, .correction(original: "12*7=", fix: "12*7=84"))
        XCTAssertEqual(host.completionsCleared, 1)
        XCTAssertEqual(fixes.handleKey(keyCode: KeyCode.tab, flags: []), .consumed)
        XCTAssertNil(world.window.currentMode, "the pill goes at once")
        XCTAssertTrue(host.typed.isEmpty, "nothing typed inside the tap callback")
        world.before = "Hi 12*7="
        world.runHops()
        XCTAssertEqual(host.typed.map(\.text), ["12*7=84"])
        XCTAssertEqual(host.typed.first?.deleted, "12*7=")
        XCTAssertEqual(host.typed.first?.before, "Hi 12*7=")
        XCTAssertEqual(host.refreshes, 1)
    }

    // The pill is only re-validated on AX events, which trail typing: a ⇥
    // landing after the user typed on must not delete what is there now.
    func testAFixWhoseTokenChangedIsDropped() {
        XCTAssertTrue(fixes.handleCaret(read("Hi 12*7=")))
        XCTAssertEqual(fixes.handleKey(keyCode: KeyCode.tab, flags: []), .consumed)
        world.before = "Hi 12*7=9"
        world.runHops()
        XCTAssertTrue(host.typed.isEmpty)
    }

    // ⎋ keeps the original — still the app's key — and the same token is not
    // offered again until it changes.
    func testEscapeSuppressesTheFixUntilTheTokenChanges() {
        XCTAssertTrue(fixes.handleCaret(read("Hi 12*7=")))
        XCTAssertEqual(fixes.handleKey(keyCode: KeyCode.escape, flags: []), .passThrough)
        XCTAssertNil(world.window.currentMode)
        XCTAssertFalse(fixes.handleCaret(read("Hi 12*7=")))
        XCTAssertNil(world.window.currentMode)
        XCTAssertTrue(fixes.handleCaret(read("Hi 2*3=")))
    }

    // ⌥⇥ on a selection: the engine's fix is previewed — never applied
    // unasked — and ⏎ types it over the selection, re-checked live.
    func testASelectionFixIsPreviewedThenTypedOnReturn() async {
        world.selected = SelectionInfo(text: "teh cat", rect: caret)
        world.engine.correction = "the cat"
        XCTAssertTrue(fixes.handleSelection(FakeWorld.element(1)))
        guard case .shortcut = world.window.currentMode else { return XCTFail("no ⌥⇥ affordance") }
        XCTAssertEqual(fixes.handleKey(keyCode: KeyCode.tab, flags: .maskAlternate), .consumed)
        world.runHops()
        await waitUntil { world.window.currentMode == .fixPreview(original: "teh cat", fix: "the cat") }
        XCTAssertEqual(world.window.currentMode, .fixPreview(original: "teh cat", fix: "the cat"))
        XCTAssertTrue(host.typed.isEmpty)
        XCTAssertEqual(fixes.handleKey(keyCode: KeyCode.returnKey, flags: []), .consumed)
        world.runHops()
        XCTAssertEqual(host.typed.map(\.text), ["the cat"])
        XCTAssertEqual(host.typed.map(\.deleted), [""])
        XCTAssertEqual(host.typed.map(\.before), [nil], "typed over a selection: the text before is unknown")
    }

    // The engine answered after the focus moved: the fix belonged to the field
    // just left, and is dropped.
    func testAFixForTheFieldJustLeftIsDropped() async {
        world.selected = SelectionInfo(text: "teh cat", rect: caret)
        world.engine.correction = "the cat"
        XCTAssertTrue(fixes.handleSelection(FakeWorld.element(1)))
        XCTAssertEqual(fixes.handleKey(keyCode: KeyCode.tab, flags: .maskAlternate), .consumed)
        world.runHops()
        host.focusGeneration += 1
        await waitUntil { !fixes.inFlight }
        XCTAssertFalse(fixes.inFlight)
        guard case .shortcut = world.window.currentMode else { return XCTFail("no preview may replace the affordance") }
    }

    // MARK: - The key table

    func testTheFixKeyTable() {
        typealias S = CorrectionController.FixKeyState
        typealias K = CorrectionController.FixKey
        let alt = CGEventFlags.maskAlternate
        let rows: [(S, K, UInt)] = [
            // ⌥⇥ asks — for the selection when there is one — or acts on
            // what it asked for, but only on what can be seen.
            (S(keyCode: KeyCode.tab, flags: alt), .propose(selection: false), #line),
            (S(keyCode: KeyCode.tab, flags: alt, selection: true), .propose(selection: true), #line),
            (S(keyCode: KeyCode.tab, flags: alt, proposal: true, onScreen: true), .apply, #line),
            (S(keyCode: KeyCode.tab, flags: alt, proposal: true), .reshow, #line),
            (S(keyCode: KeyCode.tab, flags: alt, inline: true, onScreen: true), .propose(selection: false), #line),
            // Over the preview on screen: ⏎, ⌤ and ⇥ apply it, ⎋ keeps the original.
            (S(keyCode: KeyCode.returnKey, proposal: true, onScreen: true), .apply, #line),
            (S(keyCode: KeyCode.keypadEnter, proposal: true, onScreen: true), .apply, #line),
            (S(keyCode: KeyCode.tab, proposal: true, onScreen: true), .apply, #line),
            (S(keyCode: KeyCode.escape, proposal: true, onScreen: true), .cancel, #line),
            (S(keyCode: 0, proposal: true, onScreen: true), .none, #line),
            (S(keyCode: KeyCode.tab, flags: .maskShift, proposal: true, onScreen: true), .none, #line),
            // ...and a preview nobody can see takes no key but ⌥⇥.
            (S(keyCode: KeyCode.returnKey, proposal: true), .none, #line),
            (S(keyCode: KeyCode.escape, proposal: true), .none, #line),
            // The inline pill: ⇥ applies, ⎋ dismisses, ⏎ is the app's.
            (S(keyCode: KeyCode.tab, inline: true, onScreen: true), .applyInline, #line),
            (S(keyCode: KeyCode.escape, inline: true, onScreen: true), .dismissInline, #line),
            (S(keyCode: KeyCode.returnKey, inline: true, onScreen: true), .none, #line),
            (S(keyCode: KeyCode.tab, inline: true), .none, #line),
            // The preview outranks the pill.
            (S(keyCode: KeyCode.escape, proposal: true, inline: true, onScreen: true), .cancel, #line),
            (S(keyCode: 0, proposal: true, inline: true, onScreen: true), .none, #line),
            // Another hotkey style moves every key.
            (S(keyCode: KeyCode.space, flags: [.maskControl, .maskAlternate], style: .ctrlSpace), .propose(selection: false), #line),
            (S(keyCode: KeyCode.tab, style: .ctrlSpace, inline: true, onScreen: true), .none, #line),
            (S(keyCode: KeyCode.space, flags: .maskControl, style: .ctrlSpace, inline: true, onScreen: true), .applyInline, #line),
            (S(keyCode: KeyCode.space, flags: .maskControl, style: .ctrlSpace, proposal: true, onScreen: true), .apply, #line),
        ]
        for (state, want, line) in rows {
            XCTAssertEqual(CorrectionController.fixKey(state), want, line: line)
        }
        let outcomes: [(K, CorrectionController.KeyOutcome)] = [
            (.propose(selection: true), .consumed), (.reshow, .consumed), (.apply, .consumed),
            (.applyInline, .consumed), (.cancel, .passThrough), (.dismissInline, .passThrough), (.none, .ignored),
        ]
        for (key, outcome) in outcomes { XCTAssertEqual(key.outcome, outcome, "\(key)") }
    }

    // MARK: - Selections

    /// The ⌥⇥ affordance on a selection, or nil when none is drawn.
    private func affordance(over text: String) -> Bool {
        world.selected = SelectionInfo(text: text, rect: caret)
        XCTAssertTrue(fixes.handleSelection(FakeWorld.element(1)), "a selection takes the overlay")
        if case .shortcut = world.window.currentMode { return true }
        return false
    }

    // Fixable: three to 500 characters on one line. Anything else takes the
    // overlay with no affordance on it.
    func testOnlyAFixableSelectionGetsTheAffordance() {
        XCTAssertFalse(affordance(over: "ab"))
        XCTAssertTrue(affordance(over: "abc"))
        XCTAssertTrue(affordance(over: String(repeating: "a", count: 500)))
        XCTAssertFalse(affordance(over: String(repeating: "a", count: 501)))
        XCTAssertFalse(affordance(over: "two\nlines"))
        XCTAssertNil(world.window.currentMode)
        XCTAssertEqual(host.completionsCleared, 5, "a selection drops the completion either way")
    }

    /// ⌥⇥ on "teh cat" selected, the engine's answer previewed.
    private func previewSelectionFix() async {
        world.selected = SelectionInfo(text: "teh cat", rect: caret)
        world.engine.correction = "the cat"
        XCTAssertTrue(fixes.handleSelection(FakeWorld.element(1)))
        XCTAssertEqual(fixes.handleKey(keyCode: KeyCode.tab, flags: .maskAlternate), .consumed)
        world.runHops()
        await fixes.correctionTask?.value
        XCTAssertEqual(world.window.currentMode, .fixPreview(original: "teh cat", fix: "the cat"))
    }

    // The preview of a selection fix goes with its selection, and so does
    // the ⏎ that would have applied it — and ⌥⇥ asks anew, for the word.
    func testASelectionFixEndsWithItsSelection() async {
        await previewSelectionFix()
        world.selected = nil
        XCTAssertFalse(fixes.handleSelection(FakeWorld.element(1)))
        XCTAssertNil(world.window.currentMode)
        XCTAssertEqual(fixes.handleKey(keyCode: KeyCode.returnKey, flags: []), .ignored)
        world.before = "I saw teh"
        world.engine.correction = nil
        _ = fixes.handleKey(keyCode: KeyCode.tab, flags: .maskAlternate)
        XCTAssertNil(world.window.currentMode, "the old preview is not drawn again")
        world.runHops()
        await fixes.correctionTask?.value
        XCTAssertEqual(world.engine.corrected.last, "I saw teh")
    }

    // A selection that went away takes its ⌥⇥ with it: the chord fixes the
    // word before the caret, not text no longer selected.
    func testAGoneSelectionIsNotFixed() async {
        XCTAssertTrue(affordance(over: "teh cat"))
        world.selected = nil
        XCTAssertFalse(fixes.handleSelection(FakeWorld.element(1)))
        XCTAssertNil(world.window.currentMode, "its pill goes too")
        world.before = "I saw teh"
        world.engine.correction = nil
        XCTAssertEqual(fixes.handleKey(keyCode: KeyCode.tab, flags: .maskAlternate), .consumed)
        world.runHops()
        await fixes.correctionTask?.value
        XCTAssertEqual(world.engine.corrected, ["I saw teh"])
    }

    // The engine's answer for a selection is booked and said; ⏎ types it,
    // books a correction and says what it fixed.
    func testASelectionFixIsBookedAndSaid() async {
        await previewSelectionFix()
        XCTAssertEqual(host.events.last, "fix proposed — ⏎ to apply, esc to keep")
        XCTAssertTrue(world.bookings.contains { if case .latency = $0 { return true } else { return false } })
        _ = fixes.handleKey(keyCode: KeyCode.returnKey, flags: [])
        world.runHops()
        XCTAssertEqual(host.events.last, "fixed selection (7 chars)")
        XCTAssertTrue(world.bookings.contains { if case .correction = $0 { return true } else { return false } })
    }

    // Another selection replaces the preview with the affordance for it.
    func testAnotherSelectionDropsThePreview() async {
        await previewSelectionFix()
        XCTAssertTrue(affordance(over: "foo bar"))
        XCTAssertEqual(fixes.handleKey(keyCode: KeyCode.returnKey, flags: []), .ignored)
    }

    // While a fix is being written, a selection change neither redraws nor
    // forgets anything — the dots are up.
    func testASelectionChangeWhileAFixIsWrittenChangesNothing() {
        world.selected = SelectionInfo(text: "teh cat", rect: caret)
        XCTAssertTrue(fixes.handleSelection(FakeWorld.element(1)))
        _ = fixes.handleKey(keyCode: KeyCode.tab, flags: .maskAlternate)
        world.runHops()
        XCTAssertTrue(fixes.inFlight)
        world.window.show(mode: .thinking(2), at: caret)
        world.selected = SelectionInfo(text: "x", rect: caret)
        XCTAssertTrue(fixes.handleSelection(FakeWorld.element(1)))
        XCTAssertEqual(world.window.currentMode, .thinking(2))
        world.selected = SelectionInfo(text: "a longer one", rect: caret)
        XCTAssertTrue(fixes.handleSelection(FakeWorld.element(1)))
        XCTAssertEqual(world.window.currentMode, .thinking(2))
    }

    // ...and a selection fix at its selection.
    func testApplyingASelectionFixRecoversTheCaret() async {
        await previewSelectionFix()
        host.lastCaretRect = nil
        _ = fixes.handleKey(keyCode: KeyCode.returnKey, flags: [])
        world.runHops()
        XCTAssertEqual(host.lastCaretRect, caret)
    }

    // A fix applied after a scroll forgot the caret re-anchors it at the text.
    func testApplyingAFixRecoversTheCaret() async {
        await fixLastWord("I saw teh", fixed: "I saw the")
        host.lastCaretRect = nil
        _ = fixes.handleKey(keyCode: KeyCode.returnKey, flags: [])
        world.runHops()
        XCTAssertEqual(host.lastCaretRect, caret)
        XCTAssertEqual(host.typed.map(\.text), ["the"])
    }

    // A reset forgets the selection waiting for ⌥⇥ too.
    func testAResetForgetsTheSelection() async {
        XCTAssertTrue(affordance(over: "teh cat"))
        fixes.reset()
        world.before = "I saw teh"
        _ = fixes.handleKey(keyCode: KeyCode.tab, flags: .maskAlternate)
        world.runHops()
        await fixes.correctionTask?.value
        XCTAssertEqual(world.engine.corrected, ["I saw teh"])
    }

    // A selection that became unfixable gives the chord back to the word
    // before the caret; a second ⌥⇥ while the first is written asks nothing.
    func testAnUnfixableSelectionAndASecondChord() async {
        XCTAssertTrue(affordance(over: "teh cat"))
        XCTAssertFalse(affordance(over: "ab"))
        world.before = "I saw teh"
        _ = fixes.handleKey(keyCode: KeyCode.tab, flags: .maskAlternate)
        world.runHops()
        await fixes.correctionTask?.value
        XCTAssertEqual(world.engine.corrected, ["I saw teh"])

        XCTAssertTrue(affordance(over: "teh cat"))
        _ = fixes.handleKey(keyCode: KeyCode.tab, flags: .maskAlternate)
        _ = fixes.handleKey(keyCode: KeyCode.tab, flags: .maskAlternate)
        world.runHops()
        await fixes.correctionTask?.value
        XCTAssertEqual(world.engine.corrected, ["I saw teh", "teh cat"])
    }

    // The same selection read again keeps its preview up.
    func testTheSameSelectionKeepsItsPreview() async {
        await previewSelectionFix()
        world.window.hide()
        XCTAssertTrue(fixes.handleSelection(FakeWorld.element(1)))
        XCTAssertEqual(world.window.currentMode, .fixPreview(original: "teh cat", fix: "the cat"))
    }

    // ⏎ landing after the selection changed types nothing over it.
    func testAFixIsNotTypedOverAChangedSelection() async {
        await previewSelectionFix()
        XCTAssertEqual(fixes.handleKey(keyCode: KeyCode.keypadEnter, flags: []), .consumed)
        world.selected = SelectionInfo(text: "teh dog", rect: caret)
        world.runHops()
        XCTAssertTrue(host.typed.isEmpty)
        world.selected = nil
        XCTAssertEqual(fixes.handleKey(keyCode: KeyCode.returnKey, flags: []), .ignored, "applied or dropped, it is gone")
    }

    // A preview a notice has covered is drawn again on ⌥⇥ — never applied
    // unseen — and ⏎ under the notice is the app's (Enter-to-send).
    func testAPreviewNobodyCanSeeIsNeverApplied() async {
        await previewSelectionFix()
        world.window.showTransient(.hint("notice"), at: caret)
        XCTAssertEqual(fixes.handleKey(keyCode: KeyCode.returnKey, flags: []), .ignored)
        XCTAssertEqual(fixes.handleKey(keyCode: KeyCode.tab, flags: .maskAlternate), .consumed)
        XCTAssertEqual(world.window.currentMode, .fixPreview(original: "teh cat", fix: "the cat"))
        world.runHops()
        XCTAssertTrue(host.typed.isEmpty)
        XCTAssertEqual(fixes.handleKey(keyCode: KeyCode.tab, flags: .maskAlternate), .consumed)
        world.runHops()
        XCTAssertEqual(host.typed.map(\.text), ["the cat"])
    }

    // ⎋ over the preview keeps the original, says so, and still reaches the app.
    func testEscapeKeepsTheOriginal() async {
        await previewSelectionFix()
        XCTAssertEqual(fixes.handleKey(keyCode: KeyCode.escape, flags: []), .passThrough)
        XCTAssertNil(world.window.currentMode)
        XCTAssertEqual(host.events.last, "fix dismissed")
        world.runHops()
        XCTAssertTrue(host.typed.isEmpty)
    }

    // reset() mid-request: the late answer revives no preview and books
    // nothing — and a second ⌥⇥ is not refused as already running.
    func testAResetFixNeverComesBack() async {
        world.selected = SelectionInfo(text: "teh cat", rect: caret)
        world.engine.correction = "the cat"
        XCTAssertTrue(fixes.handleSelection(FakeWorld.element(1)))
        _ = fixes.handleKey(keyCode: KeyCode.tab, flags: .maskAlternate)
        world.runHops()
        let stale = fixes.correctionTask
        XCTAssertTrue(fixes.inFlight)
        fixes.reset()
        XCTAssertFalse(fixes.inFlight)
        XCTAssertNil(fixes.correctionTask)
        await stale?.value
        XCTAssertNotEqual(world.window.currentMode, .fixPreview(original: "teh cat", fix: "the cat"))
        XCTAssertEqual(world.bookings.count, 0, "nothing booked for a request called off")
        XCTAssertFalse(host.events.contains("fix proposed — ⏎ to apply, esc to keep"))
        XCTAssertEqual(fixes.handleKey(keyCode: KeyCode.returnKey, flags: []), .ignored)
    }

    // MARK: - Voice commands

    // A spoken instruction over the selection takes the overlay from the
    // completion, is measured at the selection, and — with nothing to
    // change — says so; one at a time.
    func testAVoiceCommandIsAFixOfTheSelection() async {
        let box = CGRect(x: 40, y: 40, width: 60, height: 16)
        world.selected = SelectionInfo(text: "hi there", rect: box)
        fixes.runVoiceCommand("make it formal", selection: "hi there")
        XCTAssertEqual(host.completionsCleared, 1)
        XCTAssertEqual(host.lastCaretRect, box)
        XCTAssertTrue(fixes.inFlight)
        fixes.runVoiceCommand("shorter", selection: "hi there")
        await fixes.correctionTask?.value
        XCTAssertEqual(world.engine.rewrites.map(\.instruction), ["make it formal"])
        XCTAssertEqual(host.events.last, "nothing to fix")
        XCTAssertEqual(world.window.currentMode, .hint("no change"))
    }

    // An answer for a fix whose caret a scroll forgot is said under the
    // pointer — "no change", or a failure — never dropped unseen.
    func testAnAnswerWithNoCaretIsSaidAtThePointer() async {
        world.selected = SelectionInfo(text: "hi there", rect: nil)
        fixes.runVoiceCommand("make it formal", selection: "hi there")
        await fixes.correctionTask?.value
        XCTAssertNil(host.lastCaretRect)
        XCTAssertEqual(world.window.currentMode, .hint("no change"))
        world.window.hide()
        world.engine.correctionError = URLError(.timedOut)
        world.selected = SelectionInfo(text: "teh cat", rect: nil)
        XCTAssertTrue(fixes.handleSelection(FakeWorld.element(1)))
        _ = fixes.handleKey(keyCode: KeyCode.tab, flags: .maskAlternate)
        world.runHops()
        await fixes.correctionTask?.value
        XCTAssertEqual(world.window.currentMode, .error("fix failed"))
        XCTAssertTrue(host.events.last?.hasPrefix("fix failed: ") ?? false)
    }

    // MARK: - The last word

    /// ⌥⇥ with nothing selected, the field reading `before`|`after`.
    private func fixLastWord(_ before: String, after: String = "", fixed: String? = "the") async {
        world.before = before
        world.after = after
        world.engine.correction = fixed
        XCTAssertFalse(fixes.handleSelection(FakeWorld.element(1)))
        XCTAssertEqual(fixes.handleKey(keyCode: KeyCode.tab, flags: .maskAlternate), .consumed)
        world.runHops()
        await fixes.correctionTask?.value
    }

    // ⌥⇥ after "teh": the word is fixed in its sentence, previewed, and ⏎
    // deletes the typo and types the fix.
    func testTheLastWordIsPreviewedThenFixed() async {
        await fixLastWord("I saw teh", fixed: "I saw the")
        XCTAssertEqual(world.window.currentMode, .fixPreview(original: "teh", fix: "the"))
        XCTAssertEqual(host.completionsCleared, 1, "the fix takes the overlay from the completion")
        XCTAssertEqual(host.events.last, "last-word fix proposed — ⏎ to apply, esc to keep")
        XCTAssertEqual(fixes.handleKey(keyCode: KeyCode.returnKey, flags: []), .consumed)
        world.runHops()
        XCTAssertEqual(host.typed.map(\.text), ["the"])
        XCTAssertEqual(host.typed.map(\.deleted), ["teh"])
        XCTAssertEqual(host.typed.map(\.before), ["I saw teh"])
        XCTAssertEqual(host.events.last, "fixed last word (3 chars)")
    }

    // Mid-word is the completion's job: no engine call, nothing cleared.
    func testNoLastWordFixMidWord() async {
        await fixLastWord("I saw teh", after: "re")
        XCTAssertEqual(world.engine.redactedCorrections, [])
        XCTAssertEqual(host.completionsCleared, 0)
        XCTAssertFalse(fixes.inFlight)
    }

    // A word of fewer than three letters, or more than forty, is not asked about.
    func testOnlyAWordOfThreeToFortyLettersIsFixed() async {
        await fixLastWord("I saw te")
        await fixLastWord("I saw " + String(repeating: "x", count: 41))
        XCTAssertEqual(world.engine.redactedCorrections, [])
        await fixLastWord("I saw " + String(repeating: "x", count: 40), fixed: nil)
        XCTAssertEqual(world.engine.redactedCorrections.count, 1)
        XCTAssertEqual(host.events.last, "nothing to fix")
    }

    // The user typed on while the engine ran: the fix is for text that's
    // gone, so it is never shown — and never eats the next ⏎.
    func testAFixForTextThatChangedIsDropped() async {
        world.before = "I saw teh"
        world.engine.correction = "I saw the"
        XCTAssertFalse(fixes.handleSelection(FakeWorld.element(1)))
        _ = fixes.handleKey(keyCode: KeyCode.tab, flags: .maskAlternate)
        world.runHops()
        world.before = "I saw teh cat"
        await fixes.correctionTask?.value
        XCTAssertNotEqual(world.window.currentMode, .fixPreview(original: "teh", fix: "the"))
        XCTAssertEqual(fixes.handleKey(keyCode: KeyCode.returnKey, flags: []), .ignored)
    }

    // The preview rides along while its word stays before the caret, and
    // goes once the caret moves into a word or on past it.
    func testALastWordPreviewFollowsItsWord() async {
        await fixLastWord("I saw teh", fixed: "I saw the")
        world.window.hide()
        XCTAssertTrue(fixes.handleCaret(read("I saw teh")))
        XCTAssertEqual(world.window.currentMode, .fixPreview(original: "teh", fix: "the"))
        let midWord = TextContext(textBeforeCaret: "I saw teh", textAfterCaret: "x", caretRect: caret, host: HostTextStyle())
        XCTAssertFalse(fixes.handleCaret(midWord))
        XCTAssertNil(world.window.currentMode)
        XCTAssertEqual(fixes.handleKey(keyCode: KeyCode.returnKey, flags: []), .ignored)
    }

    // A preview whose word went is gone for good: ⌥⇥ asks anew instead of
    // drawing it again.
    func testALastWordPreviewWhoseWordWentIsNotReshown() async {
        await fixLastWord("I saw teh", fixed: "I saw the")
        XCTAssertFalse(fixes.handleCaret(read("I saw teh cat")))
        world.before = "I saw teh cat"
        world.engine.correction = nil
        _ = fixes.handleKey(keyCode: KeyCode.tab, flags: .maskAlternate)
        XCTAssertNotEqual(world.window.currentMode, .fixPreview(original: "teh", fix: "the"))
        world.runHops()
        await fixes.correctionTask?.value
        XCTAssertEqual(world.engine.corrected.last, "I saw teh cat")
    }

    // A preview needs a caret rect to stay drawn at; a read with none drops it.
    func testALastWordPreviewWithoutACaretIsDropped() async {
        await fixLastWord("I saw teh", fixed: "I saw the")
        let caretless = TextContext(textBeforeCaret: "I saw teh", textAfterCaret: "", caretRect: nil, host: HostTextStyle())
        XCTAssertFalse(fixes.handleCaret(caretless))
        XCTAssertNil(world.window.currentMode)
    }

    // MARK: - The inline fix

    // The pill sits over the word it corrects: ending at the caret, one
    // word-width to its left in the host's font — or a system font of the
    // caret's height when the field reports none — in the host's style.
    func testThePillSitsOverItsWord() throws {
        var style = HostTextStyle()
        style.font = NSFont(name: "Menlo", size: 14)
        let menlo = TextContext(textBeforeCaret: "Hi 12*7=", textAfterCaret: "", caretRect: caret, host: style)
        XCTAssertTrue(fixes.handleCaret(menlo))
        let drawn = try XCTUnwrap(world.window.drawnAt)
        let width = ceil(("12*7=" as NSString).size(withAttributes: [.font: try XCTUnwrap(style.font)]).width)
        XCTAssertEqual(drawn.rect, CGRect(x: caret.maxX - width, y: caret.minY, width: width, height: caret.height))
        XCTAssertEqual(drawn.host, style)
        XCTAssertEqual(host.lastCaretRect, caret)
        XCTAssertEqual(host.events.last, "typo \"12*7=\" → \"12*7=84\" (Tab to fix)")

        fixes.reset()
        XCTAssertTrue(fixes.handleCaret(read("Hi 2*3=")))
        let plain = ceil(("2*3=" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 16 / 1.30)]).width)
        XCTAssertEqual(world.window.drawnAt?.rect.width, plain)
    }

    // A selection reports where it is, else the last caret; with neither the
    // affordance isn't drawn — the selection still owns the overlay.
    func testTheAffordanceIsDrawnAtTheSelection() {
        let box = CGRect(x: 40, y: 40, width: 60, height: 16)
        world.selected = SelectionInfo(text: "teh cat", rect: box)
        XCTAssertTrue(fixes.handleSelection(FakeWorld.element(1)))
        XCTAssertEqual(world.window.drawnAt?.rect, box)
        world.window.hide()
        world.selected = SelectionInfo(text: "teh cat", rect: nil)
        host.lastCaretRect = caret
        XCTAssertTrue(fixes.handleSelection(FakeWorld.element(1)))
        XCTAssertEqual(world.window.drawnAt?.rect, caret)
        world.window.hide()
        host.lastCaretRect = nil
        XCTAssertTrue(fixes.handleSelection(FakeWorld.element(1)))
        XCTAssertNil(world.window.currentMode)
    }

    // The inline fixes: a typo's correction, a closed shortcode's emoji, an
    // expression's answer — never a spell-check of a shortcode, never under
    // a selection fix's preview, never without a caret to draw at.
    func testWhatTheInlineFixOffers() async {
        XCTAssertTrue(fixes.handleCaret(read("I saw teh")))
        XCTAssertEqual(world.window.currentMode, .correction(original: "teh", fix: "the"))
        fixes.reset()
        XCTAssertTrue(fixes.handleCaret(read("ok :shrug:")))
        XCTAssertEqual(world.window.currentMode, .correction(original: ":shrug:", fix: "🤷"))
        fixes.reset()
        world.window.hide()
        XCTAssertFalse(fixes.handleCaret(read("ok :asdfgh:")))
        XCTAssertNil(world.window.currentMode)
        let caretless = TextContext(textBeforeCaret: "I saw teh", textAfterCaret: "", caretRect: nil, host: HostTextStyle())
        XCTAssertFalse(fixes.handleCaret(caretless))

        await previewSelectionFix()
        XCTAssertFalse(fixes.handleCaret(read("I saw teh")), "a selection fix's preview outranks it")
        XCTAssertEqual(world.window.currentMode, .fixPreview(original: "teh cat", fix: "the cat"))
    }

    // ⎋ suppresses a token only until the caret leaves it: back on it later,
    // it is offered again.
    func testADismissedTokenIsOfferedAgainOnceTheCaretLeftIt() {
        XCTAssertTrue(fixes.handleCaret(read("Hi 12*7=")))
        XCTAssertEqual(fixes.handleKey(keyCode: KeyCode.escape, flags: []), .passThrough)
        XCTAssertFalse(fixes.handleCaret(read("Hi 12*7=")))
        XCTAssertFalse(fixes.handleCaret(read("Hi ")))
        XCTAssertTrue(fixes.handleCaret(read("Hi 12*7=")))
    }

    // A focus change forgets which token was dismissed.
    func testAFocusChangeForgetsTheDismissedToken() {
        XCTAssertTrue(fixes.handleCaret(read("Hi 12*7=")))
        _ = fixes.handleKey(keyCode: KeyCode.escape, flags: [])
        fixes.focusChanged()
        XCTAssertTrue(fixes.handleCaret(read("Hi 12*7=")))
    }

    // The pill goes with its token, and with a caret that moved into a word.
    func testThePillGoesWithItsToken() {
        XCTAssertTrue(fixes.handleCaret(read("Hi 12*7=")))
        XCTAssertFalse(fixes.handleCaret(read("Hi 12*7=84 ")))
        XCTAssertNil(world.window.currentMode)
        XCTAssertEqual(fixes.handleKey(keyCode: KeyCode.tab, flags: []), .ignored)
        let midWord = TextContext(textBeforeCaret: "Hi 12*7=", textAfterCaret: "x", caretRect: caret, host: HostTextStyle())
        XCTAssertFalse(fixes.handleCaret(midWord))
    }
}
