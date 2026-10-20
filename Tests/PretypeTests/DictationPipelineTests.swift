import AppKit
import XCTest
@testable import Pretype

/// Dictation's way into the pipeline, on a real controller: the transcript
/// typed through `insertDictated`, the Return a chat sends on, ⌘Z over what was
/// spoken, and the events that end a hold before it opens the microphone.
@MainActor
final class DictationPipelineTests: PipelineTestCase {
    /// The tracked field on a chat site that sends on Return after a dictation.
    private func focusChatThatSends() async {
        let app = FakeFocusApp()
        app.fields = [(FakeWorld.element(1), "Message")]
        app.focused = FakeWorld.element(1)
        app.site = "chat.example.com"
        _ = await trackRealFocus(app)
        set(\.dictationSendApps, ["site:chat.example.com"])
    }

    // Return sends the message: the text before the caret is gone with it, so
    // neither the cache nor ⌘Z may still claim it — the next ⌘Z is the app's.
    func testASentDictationLeavesNothingToUndo() async throws {
        await focusChatThatSends()
        fake.before = "Hi "
        controller.insertDictated("hello")
        XCTAssertEqual(fake.keys, [.insert("hello"), .returnKey])
        XCTAssertNil(controller.field.cache)
        XCTAssertNil(controller.field.undoable)
        XCTAssertFalse(try press(KeyCode.z, .maskCommand, typing: "z"))
    }

    // In a launcher opened over the chat (Spotlight, Raycast) the transcript
    // is typed into the launcher — and a Return there would run its search,
    // not send the message.
    func testADictationIntoALauncherIsNeverSent() async throws {
        await focusChatThatSends()
        fake.panelOwner = 999_999   // past macOS's highest pid: no app Pretype stays out of
        fake.launcherField = FakeWorld.element(9)
        fake.before = "Hi "
        controller.insertDictated("hello")
        XCTAssertEqual(fake.keys, [.insert("hello")])
        XCTAssertNil(controller.field.undoable, "a launcher's text is no ⌘Z of ours")
    }

    // ⌘Z takes a dictation back like an accepted suggestion — but what it
    // removes was spoken: named by its length only, and never journaled.
    // A suggestion's undo is journaled: the strongest "no" there is.
    func testUndoingADictationNeitherQuotesNorJournalsIt() throws {
        fake.before = "Hi "
        controller.insertDictated("hello")
        XCTAssertEqual(controller.field.undoable?.dictated, true)
        fake.before = "Hi hello"
        XCTAssertTrue(try press(KeyCode.z, .maskCommand, typing: "z"))
        fake.runHops()
        XCTAssertEqual(fake.keys, [.insert("hello"), .delete("hello", perCharacter: false)])
        XCTAssertEqual(controller.lastEvent, "undid a dictation of 5 characters")
        XCTAssertTrue(fake.undos.isEmpty)
        // Spoken words taken back are no "no" to a ghost: the next read of the
        // field as it was may offer one.
        fake.before = "Hi "
        fake.now += 0.5
        controller.textDidChange()
        XCTAssertFalse(controller.field.isDeclined)

        fake.now += 0.5
        showGhost("so", on: "Hi ")
        try press(KeyCode.tab)
        fake.before = "Hi so"
        XCTAssertTrue(try press(KeyCode.z, .maskCommand, typing: "z"))
        fake.runHops()
        XCTAssertEqual(fake.undos.map(\.suggestion), ["so"])
        XCTAssertEqual(fake.undos.map(\.screen), [false])
        XCTAssertEqual(fake.undos.map(\.outcome), [.undone])
        XCTAssertEqual(fake.undos.map(\.acceptedChars), [-2])
        XCTAssertEqual(fake.undos.map(\.shownForMs), [0])
        XCTAssertEqual(fake.undos.map(\.ctx), ["Hi "])
        XCTAssertEqual(fake.undos.map(\.engine), ["fake"])
        XCTAssertEqual(controller.lastEvent, "undid acceptance of \"so\"")
    }

    // The last checks before a transcript is typed, each one a place where
    // typing would go wrong: the words land on the clipboard instead, and
    // nothing is typed.

    func testSecureInputCopiesTheDictationInsteadOfTypingIt() {
        fake.secureInput = true
        controller.insertDictated("hello")
        XCTAssertEqual(fake.keys, [])
        XCTAssertEqual(fake.copied, ["hello"])
    }

    // An IME composition opened during the capture would swallow the keys
    // into its marked text.
    func testAnOpenCompositionCopiesTheDictationInsteadOfTypingIt() {
        fake.markedText = true
        controller.insertDictated("hello")
        XCTAssertEqual(fake.keys, [])
        XCTAssertEqual(fake.copied, ["hello"])
    }

    // A terminal took the words only inside an agent's input box; once that
    // closed, the caret is in a shell — where typed words would run.
    func testAClosedAgentPromptCopiesTheDictationInsteadOfTypingIt() async {
        let app = FakeFocusApp()
        app.fields = [(FakeWorld.element(1), "Prompt")]
        app.focused = FakeWorld.element(1)
        app.bundleID = "com.apple.Terminal"
        _ = await trackRealFocus(app)
        fake.readable = false
        controller.insertDictated("ls")
        XCTAssertEqual(fake.keys, [])
        XCTAssertEqual(fake.copied, ["ls"])
    }

    // A password manager's quick-access panel holds the keys the way a
    // launcher does — but its field is never read, and never typed into.
    func testAPasswordManagerPanelIsNeverTypedInto() {
        fake.panelOwner = 4242
        fake.bundles = [4242: "com.1password.1password"]
        fake.launcherField = FakeWorld.element(9)
        controller.insertDictated("hello")
        XCTAssertEqual(fake.keys, [])
        XCTAssertEqual(fake.copied, ["hello"])
    }

    // The field closed or lost focus while the words were written down.
    func testNoTextFieldCopiesTheDictationInsteadOfTypingIt() {
        fake.tracked = nil
        controller.insertDictated("hello")
        XCTAssertEqual(fake.keys, [])
        XCTAssertEqual(fake.copied, ["hello"])
    }

    // Settings came to the front: the keys would type into Pretype itself.
    func testOurOwnWindowCopiesTheDictationInsteadOfTypingIt() {
        fake.ownWindowFrontmost = true
        controller.insertDictated("hello")
        XCTAssertEqual(fake.keys, [])
        XCTAssertEqual(fake.copied, ["hello"])
    }

    // Paused while the words were being written down: nothing is typed.
    func testAPausedPretypeCopiesTheDictationInsteadOfTypingIt() {
        set(\.enabled, false)
        controller.insertDictated("hello")
        XCTAssertEqual(fake.keys, [])
        XCTAssertEqual(fake.copied, ["hello"])
    }

    // What was said never reaches the event line (exported with bug
    // reports): typed or copied, only its length does.
    func testTheTranscriptNeverReachesTheEventLine() {
        fake.before = "Hi "
        controller.insertDictated("hello")
        XCTAssertFalse(controller.lastEvent.contains("hello"), controller.lastEvent)
        fake.secureInput = true
        controller.insertDictated("hello")
        XCTAssertFalse(controller.lastEvent.contains("hello"), controller.lastEvent)
    }

    // The counter measures what was said: the seam space typing adds is not speech.
    func testADictationBooksTheSpokenCharacters() {
        fake.before = "Hi"
        controller.insertDictated("hello")
        XCTAssertEqual(fake.keys, [.insert(" hello")])
        let spoken = fake.bookings.compactMap { if case .dictated(let chars) = $0 { return chars } else { return nil } }
        XCTAssertEqual(spoken, [5])
    }

    // A parked transcript stays on this Mac and out of clipboard history.
    func testAParkedTranscriptIsMarkedTransient() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let other = NSPasteboard.PasteboardType("com.example.other")
        board.declareTypes([other], owner: nil)
        board.setData(Data([1]), forType: other)
        SuggestionController.copyTranscript("hello", to: board)
        XCTAssertFalse(board.types?.contains(other) ?? true, "the board is the transcript's alone")
        XCTAssertEqual(board.string(forType: .string), "hello")
        XCTAssertTrue(board.types?.contains(SuggestionController.transientType) ?? false)
    }

    // A transcript takes the field: the ghost offered on the old text and the
    // query composing the next one go before the words are typed.
    func testADictationRetiresTheGhostFirst() {
        showGhost("to be", on: "Hi ")
        controller.insertDictated("hello")
        XCTAssertNil(controller.field.ghost)
        XCTAssertNil(controller.queries.current)
        XCTAssertNil(fake.window.ghost)
        XCTAssertEqual(fake.offers.map(\.outcome), [.abandoned])
    }

    // Dictated mid-line, the words take the spaces they need on both sides:
    // the text after the caret decides the trailing one.
    func testADictationIsSpacedOnBothSides() {
        fake.before = "Hi"
        fake.after = "there"
        controller.insertDictated("hello")
        XCTAssertEqual(fake.keys, [.insert(" hello ")])
    }

    // The words are typed blind: the field is re-read once they have landed.
    func testADictationIsReReadOnceItLands() {
        fake.before = "Hi "
        controller.insertDictated("hello")
        let reads = fake.reads
        fake.before = "Hi hello"
        fake.advance(0.08)
        XCTAssertEqual(fake.reads, reads, "not before the keys can have landed")
        fake.advance(0.01)
        XCTAssertEqual(fake.reads, reads + 1)
    }

    // A hands-free capture ignores typing, and the chords with it: ⌥⇥ goes
    // to the app rather than fixing a field the words are about to land in.
    func testAHandsFreeCaptureLeavesTheFixChordToTheApp() async throws {
        await startHandsFreeCapture()
        XCTAssertTrue(controller.dictationController.isBusy)
        fake.before = "Hi teh"
        XCTAssertFalse(try press(KeyCode.tab, .maskAlternate))
        XCTAssertTrue(fake.hops.isEmpty)
    }

    // Why nothing can start now — the reply chord and the prompt warm-up both
    // stop on it, and the menu's "Last:" line names it.
    func testTheBusyReasonNamesWhatHoldsThePipeline() async {
        XCTAssertNil(controller.busyReason)
        fake.ownWindowFrontmost = true
        XCTAssertEqual(controller.busyReason, "our own window is frontmost")
        fake.ownWindowFrontmost = false
        set(\.enabled, false)
        XCTAssertEqual(controller.busyReason, "Pretype is paused")
        set(\.enabled, true)
        await startHandsFreeCapture()
        XCTAssertEqual(controller.busyReason, "dictation is listening")
    }

    // Outside a terminal, a field that publishes no caret yet (a web input
    // before its first key) still gets what was said — with no seam to
    // judge and no snapshot for ⌘Z.
    func testAFieldThatReadsNothingStillGetsTheWords() {
        fake.readable = false
        controller.insertDictated("hello")
        XCTAssertEqual(fake.keys, [.insert("hello")])
        XCTAssertNil(controller.field.undoable)
    }

    // In a launcher the seams are judged by the launcher's own field, not
    // the one under it.
    func testALauncherIsSpacedByItsOwnText() {
        fake.before = "Hi"
        fake.panelOwner = 999_999
        fake.launcherField = FakeWorld.element(9)
        controller.insertDictated("hello")
        XCTAssertEqual(fake.keys, [.insert("hello")])
    }

    // A capture takes the caret: the completion's query and its thinking
    // dots go before the pill is drawn.
    func testACaptureStartingClearsTheCompletion() {
        fake.before = "Hi "
        controller.textDidChange()
        XCTAssertNotNil(controller.indicator.timer)
        controller.prepareForDictation()
        XCTAssertNil(controller.queries.current)
        XCTAssertNil(controller.indicator.timer)
    }

    // "Make it formal" over a selection goes to the engine as a rewrite.
    func testAVoiceCommandRewritesTheSelection() async {
        controller.applyVoiceCommand("make it formal", to: "hi there")
        let end = Date().addingTimeInterval(5)
        while fake.engine.rewrites.isEmpty, Date() < end { await Task.yield() }
        XCTAssertEqual(fake.engine.rewrites.map(\.instruction), ["make it formal"])
        XCTAssertEqual(fake.engine.rewrites.map(\.selection), ["hi there"])
    }

    // The fix model is warmed for a tidy-up only once it is on disk.
    func testATidyUpWarmsOnlyAModelOnDisk() {
        controller.prewarmTidy()
        fake.engine.correctionReady = false
        controller.prewarmTidy()
        XCTAssertEqual(fake.engine.correctionPrewarms, 1)
    }

    // A fix model not on disk can't tidy this sentence: it is fetched for the
    // next one — on an unmetered network only.
    func testATidyUpWithoutTheFixModelFetchesItOnlyUnmetered() async {
        fake.engine.correctionReady = false
        let first = await controller.tidyDictation("hello")
        XCTAssertNil(first)
        XCTAssertEqual(fake.engine.correctionPrewarms, 1)
        fake.networkUnmetered = false
        _ = await controller.tidyDictation("hello")
        XCTAssertEqual(fake.engine.correctionPrewarms, 1)
    }

    // A tidy-up that comes back empty or unchanged leaves the words as heard.
    func testAnEmptyTidyUpKeepsTheWordsAsHeard() async {
        fake.engine.correction = ""
        let empty = await controller.tidyDictation("hello")
        XCTAssertNil(empty)
        fake.engine.correction = "Hello."
        let tidied = await controller.tidyDictation("hello")
        XCTAssertEqual(tidied, "Hello.")
    }

    // Nothing heard: nothing typed, and the ghost up stays up.
    func testAnEmptyTranscriptChangesNothing() {
        showGhost("to be", on: "Hi ")
        controller.insertDictated("")
        XCTAssertEqual(fake.window.ghost, "to be")
        XCTAssertTrue(fake.bookings.isEmpty)
    }

    // A terminal's agent prompt that is still open takes the words.
    func testAnOpenAgentPromptGetsTheWords() async {
        let app = FakeFocusApp()
        app.fields = [(FakeWorld.element(1), "Prompt")]
        app.focused = FakeWorld.element(1)
        app.bundleID = "com.apple.Terminal"
        _ = await trackRealFocus(app)
        fake.before = "> "
        controller.insertDictated("ls")
        XCTAssertEqual(fake.keys, [.insert("ls")])
    }

    // Where a hold would type: a field, or none to say so about.
    func testTheDictationFocusIsTheFieldOrNone() {
        XCTAssertEqual(controller.dictationFocus(), .field)
        fake.tracked = nil
        XCTAssertEqual(controller.dictationFocus(), .noField)
    }

    // A fix pill up when a capture starts is gone: ⇥ no longer applies it.
    func testACaptureStartingDropsAFixPill() throws {
        fake.before = "Hi 12*7="
        controller.textDidChange()
        XCTAssertEqual(fake.window.currentMode, .correction(original: "12*7=", fix: "12*7=84"))
        controller.prepareForDictation()
        XCTAssertFalse(try press(KeyCode.tab))
        XCTAssertTrue(fake.hops.isEmpty)
    }

    // The selection is read only for voice commands — the text they act on.
    func testTheSelectionIsReadOnlyForVoiceCommands() {
        fake.selected = SelectionInfo(text: "hi there", rect: CGRect(x: 100, y: 100, width: 40, height: 16))
        XCTAssertEqual(controller.dictationAnchor()?.selectedText, "")
        set(\.dictationCommands, true)
        XCTAssertEqual(controller.dictationAnchor()?.selectedText, "hi there")
    }

    // An empty web field reads as nothing to the completion pipeline, but a
    // dictation still finds its caret there.
    func testAnEmptyWebFieldStillAnchorsADictation() {
        fake.emptyReadsNil = true
        XCTAssertNotNil(controller.dictationAnchor())
    }

    // A capture's own pill outranks a protected notice — "starting
    // dictation…" must not wait behind the last one.
    func testACapturesPillOutranksAProtectedNotice() {
        let caret = CGRect(x: 100, y: 100, width: 1, height: 16)
        controller.showTransientOverlay(.hint("dictation stopped"), at: caret, host: HostTextStyle())
        controller.showOverlay(.status("starting dictation…"), at: caret, host: HostTextStyle())
        XCTAssertEqual(fake.window.currentMode, .status("starting dictation…"))
    }

    // A dictation notice takes the window — and retires the ghost under it,
    // or ⇥ would accept text nobody can see.
    func testADictationNoticeRetiresTheGhost() {
        showGhost("to be", on: "Hi ")
        controller.showTransientOverlay(.hint("dictation cancelled"),
                                        at: CGRect(x: 100, y: 100, width: 1, height: 16), host: HostTextStyle())
        XCTAssertEqual(fake.window.currentMode, .hint("dictation cancelled"))
        XCTAssertNil(controller.field.ghost)
    }

    // A rescue notice is the only sign that the words went to the clipboard,
    // so it stays up long enough to read; a short notice, the usual time.
    func testARescueNoticeStaysUpLongEnoughToRead() {
        controller.rescueDictated("hello", because: .focusMoved)
        let rescue = fake.window.noticeTimes?.hideAfter ?? 0
        XCTAssertGreaterThan(rescue, 3)
        controller.showTransientOverlay(.hint("nothing heard"),
                                        at: CGRect(x: 100, y: 100, width: 1, height: 16), host: HostTextStyle())
        XCTAssertEqual(fake.window.noticeTimes?.hideAfter, 1.8)
        XCTAssertEqual(SuggestionController.noticeSeconds(for: .hint(String(repeating: "a", count: 500))), 7)
    }

    // What is tidied was spoken: the engine keeps it out of its log.
    func testATidyUpKeepsTheSpokenTextOutOfTheLog() async {
        _ = await controller.tidyDictation("hello")
        XCTAssertEqual(fake.engine.redactedCorrections, [true])
    }

    // ⎋ ends a hands-free capture and is swallowed — unless the capture began
    // in a launcher, whose ⎋ also closes it.
    func testEscapeCancelsAHandsFreeCapture() async throws {
        await startHandsFreeCapture()
        XCTAssertTrue(try press(KeyCode.escape))
        XCTAssertFalse(controller.dictationController.isBusy)

        fake.panelOwner = 999_999
        fake.launcherField = FakeWorld.element(9)
        await startHandsFreeCapture()
        XCTAssertTrue(controller.dictationController.isBusy)
        XCTAssertFalse(try press(KeyCode.escape))
        XCTAssertFalse(controller.dictationController.isBusy)
    }

    // While the words are being written down a scroll moves nothing, and they
    // are typed; a click moved the caret, and they go to the clipboard.
    func testWhileWritingDownOnlyAClickParksTheWords() async {
        set(\.dictationPolish, false)
        for click in [false, true] {
            let session = HeldSession(transcript: "hello")
            await startHandsFreeCapture(session: session)
            controller.dictationController.toggleLatch()
            var entered = session.gate.entered.makeAsyncIterator()
            _ = await entered.next()
            if click { controller.pointerPressed() } else { controller.scrolled(momentum: false) }
            session.gate.open()
            await controller.dictationController.sessionTask?.value
        }
        XCTAssertEqual(fake.keys, [.insert("hello")])
        XCTAssertEqual(fake.copied, ["hello"])
    }

    // MARK: - The latch chord

    /// ⌃⌥ and `key` — ⌃⌥D is the hands-free chord — as the key tap sees it.
    private func pressLatch(_ key: Int64 = KeyCode.d, autorepeat: Bool = false) throws -> Bool {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: true))
        event.flags = [.maskControl, .maskAlternate]
        if autorepeat { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        return controller.handleKeyDown(event)
    }

    // ⌃⌥D is ours while dictation can use it: swallowed, it toggles a
    // hands-free capture once per press — never once per autorepeat — and
    // the ⌘Z after it is the app's.
    func testTheLatchChordTogglesHandsFreeOncePerPress() throws {
        set(\.dictationEnabled, true)
        showGhost("to be", on: "Hi ")
        try press(KeyCode.tab)
        XCTAssertTrue(try pressLatch())
        XCTAssertEqual(fake.hops.count, 1)
        XCTAssertTrue(try pressLatch(autorepeat: true))
        XCTAssertEqual(fake.hops.count, 1)
        fake.before = "Hi to"
        XCTAssertFalse(try press(KeyCode.z, .maskCommand, typing: "z"))
    }

    // Everywhere else the chord is the app's: dictation off, no chord set,
    // another letter, our own window in front.
    func testTheLatchChordIsTheAppsWhereDictationCannotUseIt() throws {
        XCTAssertFalse(try pressLatch(), "dictation off")
        set(\.dictationEnabled, true)
        set(\.dictationLatch, .off)
        XCTAssertFalse(try pressLatch(), "no chord set")
        set(\.dictationLatch, .controlOptionD)
        XCTAssertFalse(try pressLatch(KeyCode.v), "another letter")
        fake.ownWindowFrontmost = true
        XCTAssertFalse(try pressLatch(), "our own window")
        XCTAssertTrue(fake.hops.isEmpty)
    }

    // An app Pretype stays out of keeps ⌃⌥D: `begin` would refuse there a
    // moment later, having eaten the key.
    func testTheLatchChordIsTheAppsInAnAppWeStayOutOf() async throws {
        let app = FakeFocusApp()
        app.fields = [(FakeWorld.element(1), "Notes")]
        app.focused = FakeWorld.element(1)
        app.bundleID = "com.example.notes"
        _ = await trackRealFocus(app)
        set(\.dictationEnabled, true)
        set(\.userBlacklist, ["com.example.notes"])
        XCTAssertFalse(try pressLatch())
        XCTAssertTrue(fake.hops.isEmpty)
    }

    // A password manager's panel holding the keys keeps ⌃⌥D too: `begin`
    // would refuse it silently. A capture already running still stops on it.
    func testTheLatchChordIsTheAppsInAPanelWeStayOutOf() async throws {
        set(\.dictationEnabled, true)
        fake.panelOwner = 4242
        fake.bundles = [4242: "com.1password.1password"]
        XCTAssertFalse(try pressLatch())
        XCTAssertTrue(fake.hops.isEmpty)
        fake.bundles = [4242: "com.raycast.macos"]
        XCTAssertTrue(try pressLatch(), "a launcher's field takes dictation")

        fake.panelOwner = nil
        await startHandsFreeCapture()
        fake.panelOwner = 4242
        fake.bundles = [4242: "com.1password.1password"]
        XCTAssertTrue(try pressLatch(), "the chord ends the capture it started")
    }

    // A web or Electron field whose node was replaced under the caret: the
    // tracked handle reads nothing, and the anchor re-resolves through the
    // system's focused element.
    func testTheAnchorReResolvesAReplacedNode() throws {
        fake.before = "Hi"
        let tracked = try XCTUnwrap(fake.tracked)
        fake.dead = [tracked]
        XCTAssertNil(controller.dictationAnchor(), "no other field to find")
        fake.systemField = FakeWorld.element(5)
        XCTAssertEqual(controller.dictationAnchor()?.textBeforeCaret, "Hi", "the re-resolve finds the replaced node")
    }

    /// ⌥ down: the dictation hold is armed (and would open the microphone
    /// past its threshold — an hour, here).
    private func armHold() throws {
        set(\.dictationEnabled, true)
        set(\.dictationGesture, .option)
        controller.dictationController.hold.threshold = 3600
        let down = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(KeyCode.leftOption), keyDown: true))
        down.flags = .maskAlternate
        controller.dictationController.modifierChanged(down)
        XCTAssertTrue(controller.dictationController.isHoldArmed)
    }

    // A flick's momentum keeps coasting for seconds after the finger left: a
    // hold started meanwhile is deliberate, and only a real scroll ends it.
    func testOnlyARealScrollEndsAHold() throws {
        try armHold()
        controller.scrolled(momentum: true)
        XCTAssertTrue(controller.dictationController.isHoldArmed)
        controller.scrolled(momentum: false)
        XCTAssertFalse(controller.dictationController.isHoldArmed)
    }

    // A click is an ordinary ⌥-gesture (⌥-click, ⌥-drag): a hold armed
    // through it never opens the microphone.
    func testAClickEndsAHold() throws {
        try armHold()
        controller.pointerPressed()
        XCTAssertFalse(controller.dictationController.isHoldArmed)
    }

    // A capture dies with the app it started in — the only signal when the
    // app switched to is Pretype itself, which fires no focus change.
    func testLeavingTheAppEndsAHold() throws {
        try armHold()
        controller.focusTracker.onResignActiveApp?()
        XCTAssertFalse(controller.dictationController.isHoldArmed)
    }
}
