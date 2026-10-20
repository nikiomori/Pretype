import AppKit
import XCTest
@testable import Pretype

/// The controller's wiring and life: what its window, tracker and key tap
/// reach, the master switch, the scroll monitor, the overlay drops, the
/// query's ends and what an offer is stamped with.
@MainActor
final class PipelineLifecycleTests: PipelineTestCase {
    private let caret = CGRect(x: 100, y: 100, width: 1, height: 16)

    // MARK: - Wiring

    func testTheWindowTakesThePresentationSetting() {
        set(\.suggestionPresentation, .inline)
        controller.dismiss()
        controller = SuggestionController(env: fake.env)
        XCTAssertEqual(fake.window.presentation, .inline)
    }

    // The tracker's and the tap's events reach the pipeline.
    func testTheTrackerAndTheTapAreWired() throws {
        showGhost("to be", on: "Hi ")
        controller.focusTracker.onViewportChange?()
        XCTAssertNil(fake.window.ghost)
        XCTAssertEqual(controller.lastEvent, "dismissed — the window moved or resized")

        showGhost("to be", on: "Hi ")
        controller.focusTracker.onResignActiveApp?()
        XCTAssertNil(fake.window.ghost)
        XCTAssertEqual(controller.lastEvent, "dismissed — left the app")

        showGhost("to be", on: "Hi ")
        controller.keyTap.scrollHandler?(false)
        XCTAssertNil(fake.window.ghost)
        XCTAssertEqual(controller.lastEvent, "dismissed — the view scrolled")

        showGhost("to be", on: "Hi ")
        controller.keyTap.mouseDownHandler?()
        XCTAssertNil(fake.window.ghost)
        XCTAssertEqual(controller.lastEvent, "dismissed — mouse click")

        showGhost("to be", on: "Hi ")
        let tab = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(KeyCode.tab), keyDown: true))
        XCTAssertEqual(controller.keyTap.handler?(tab), true, "⇥ over a ghost is swallowed")
        XCTAssertEqual(fake.keys, [.insert("to")])

        let generation = controller.focusGeneration
        controller.focusTracker.onFocusChange?()
        XCTAssertEqual(controller.focusGeneration, generation + 1)

        fake.before = "Hi"
        controller.focusTracker.onTextChange?(true)
        fake.advance(0.01)
        XCTAssertEqual(controller.queries.current?.kind, .completion(before: "Hi", after: ""))
    }

    // macOS turned the tap off and keystrokes went by unseen: the ghost, its
    // query, the cache and the ⌘Z record are all stale.
    func testATapMacOSPausedForgetsWhatItCouldNotSee() throws {
        showGhost("to be", on: "Hi ")
        try press(KeyCode.tab)
        XCTAssertNotNil(controller.field.undoable)
        controller.keyTap.reenabledHandler?()
        XCTAssertNil(controller.field.undoable)
        XCTAssertNil(controller.field.ghost)
        XCTAssertNil(controller.field.cache)
        XCTAssertEqual(controller.lastEvent, "dismissed — the key tap was paused")
    }

    // ...but a capture's pill is its own.
    func testATapPausedDuringACaptureLeavesItsPill() async {
        await startHandsFreeCapture()
        let pill = fake.window.currentMode
        controller.keyTap.reenabledHandler?()
        XCTAssertEqual(fake.window.currentMode, pill)
    }

    // A modifier edge reaches dictation's hold and re-judges the scroll monitor.
    func testAModifierEdgeReachesDictationAndTheScrollMonitor() throws {
        set(\.dictationEnabled, true)
        set(\.dictationGesture, .option)
        controller.dictationController.hold.threshold = 3600
        let down = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(KeyCode.leftOption), keyDown: true))
        down.flags = .maskAlternate
        controller.keyTap.flagsHandler?(down)
        XCTAssertTrue(controller.dictationController.isHoldArmed)
        XCTAssertTrue(controller.keyTap.wantsScroll, "⌃-scroll zoom must not open the microphone")
    }

    // MARK: - Switches

    // Pause takes the microphone too; resume wakes the app in front, which
    // a paused Pretype never woke.
    func testTheMasterSwitch() async {
        await startHandsFreeCapture()
        controller.setEnabled(false)
        XCTAssertFalse(Settings.enabled)
        XCTAssertFalse(controller.dictationController.isBusy)

        await enterApp("com.apple.TextEdit")
        XCTAssertEqual(focusApp?.wakes, 0, "a paused Pretype never wakes an app")
        controller.setEnabled(true)
        XCTAssertTrue(Settings.enabled)
        XCTAssertEqual(focusApp?.wakes, 1)
        controller.setEnabled(false)
        XCTAssertEqual(focusApp?.wakes, 1)
    }

    // Following an app wakes its accessibility tree (Electron keeps it up
    // from then on) — not a password manager's.
    func testFollowingAnAppWakesIt() async {
        await enterApp("com.apple.TextEdit")
        XCTAssertEqual(focusApp?.wakes, 1)
        await enterApp("com.1password.1password")
        XCTAssertEqual(focusApp?.wakes, 0)
    }

    func testPausingDropsTheGhost() {
        showGhost("to be", on: "Hi ")
        controller.setEnabled(false)
        XCTAssertNil(fake.window.ghost)
        XCTAssertNil(controller.field.ghost)
    }

    // A ghost drawn the old way goes, so the next one renders the new way.
    func testThePresentationSwitch() {
        set(\.suggestionPresentation, .panel)
        showGhost("to be", on: "Hi ")
        controller.setSuggestionPresentation(.inline)
        XCTAssertEqual(Settings.suggestionPresentation, .inline)
        XCTAssertEqual(fake.window.presentation, .inline)
        XCTAssertNil(fake.window.ghost)
    }

    func testShutdownStopsTheMicrophoneAndTheEngine() async {
        await startHandsFreeCapture()
        controller.shutdown()
        XCTAssertFalse(controller.dictationController.isBusy)
        XCTAssertEqual(fake.engine.shutdowns, 1)
    }

    // MARK: - The scroll monitor

    // Up while a query, a ghost or anything on screen needs scrolls; the
    // per-keystroke bookkeeping only starts it, and the next edge that
    // re-judges it stops it.
    func testTheScrollMonitorRunsOnlyWhileSomethingNeedsIt() throws {
        let tap = controller.keyTap
        XCTAssertFalse(tap.wantsScroll)
        fake.before = "Hi "
        controller.textDidChange()
        XCTAssertTrue(tap.wantsScroll, "a query is on its way")
        controller.dismiss()
        XCTAssertTrue(tap.wantsScroll, "the bookkeeping never stops it")
        controller.updateScrollMonitoring()
        XCTAssertFalse(tap.wantsScroll)

        XCTAssertTrue(controller.apply("there", requestText: "Hi ", cachedContext: TextContext(
            textBeforeCaret: "Hi ", textAfterCaret: "", caretRect: caret, host: HostTextStyle())))
        XCTAssertTrue(tap.wantsScroll, "a ghost")
        controller.dismiss()
        controller.updateScrollMonitoring()
        XCTAssertFalse(tap.wantsScroll)

        fake.window.show(mode: .hint("notice"), at: caret)
        fake.window.onVisibilityChange?()
        XCTAssertTrue(tap.wantsScroll, "anything on screen")
        fake.window.hide()
        fake.window.onVisibilityChange?()
        XCTAssertFalse(tap.wantsScroll)
    }

    // MARK: - Overlay drops

    // Nothing up: a drop says nothing. A protected notice the caret left
    // behind goes with it.
    func testADropWithNothingUpSaysNothing() {
        controller.report("before")
        controller.focusTracker.onResignActiveApp?()
        XCTAssertEqual(controller.lastEvent, "before")

        fake.window.showTransient(.hint("notice"), at: caret, host: HostTextStyle(), protectFor: 5)
        XCTAssertTrue(fake.window.noticeProtected)
        controller.focusTracker.onResignActiveApp?()
        XCTAssertFalse(fake.window.noticeProtected)
        XCTAssertNil(fake.window.currentMode)
    }

    // A scroll under a reply in flight forgets the caret and hides the dots,
    // protected notice included; the reply lands on a fresh read.
    func testAScrollUnderAReplyClearsTheNotice() {
        set(\.screenContextEnabled, true)
        XCTAssertTrue(controller.replyComposer.compose())
        fake.window.showTransient(.hint("notice"), at: caret, host: HostTextStyle(), protectFor: 5)
        controller.scrolled(momentum: false)
        XCTAssertFalse(fake.window.noticeProtected)
        XCTAssertNil(fake.window.currentMode)
        XCTAssertTrue(controller.queries.isReply)
    }

    // A click during a capture leaves its pill: the capture owns the overlay.
    func testAClickDuringACaptureLeavesItsPill() async {
        await startHandsFreeCapture()
        let pill = fake.window.currentMode
        XCTAssertNotNil(pill)
        controller.pointerPressed()
        XCTAssertEqual(fake.window.currentMode, pill)
        XCTAssertNil(controller.field.cache)
    }

    // A click with no ghost and only a reply in flight drops nothing.
    func testAClickLeavesAReplyAndANoticeAlone() {
        set(\.screenContextEnabled, true)
        XCTAssertTrue(controller.replyComposer.compose())
        controller.report("composing")
        controller.pointerPressed()
        XCTAssertEqual(controller.lastEvent, "composing")
        XCTAssertTrue(controller.queries.isReply)
    }

    // MARK: - The caret

    func testSideFlowsMeasureTheCaret() {
        var style = HostTextStyle()
        style.font = .systemFont(ofSize: 20)
        controller.noteCaret(rect: caret, host: style)
        XCTAssertEqual(controller.lastCaretRect, caret)
        XCTAssertEqual(controller.lastHostStyle, style)
        let other = CGRect(x: 5, y: 5, width: 1, height: 10)
        controller.recoverCaret(other)
        XCTAssertEqual(controller.lastCaretRect, caret, "only a forgotten caret is recovered")
        set(\.screenContextEnabled, true)
        XCTAssertTrue(controller.replyComposer.compose())
        controller.scrolled(momentum: false)
        XCTAssertNil(controller.lastCaretRect, "a scroll under a reply forgets it")
        controller.recoverCaret(other)
        XCTAssertEqual(controller.lastCaretRect, other)
    }

    // MARK: - A query's ends

    // The prompt sent and the result shown are kept for Diagnostics.
    func testAQueryLeavesItsPromptAndResult() async throws {
        fake.engine.partials = ["there"]
        fake.before = "Hi "
        controller.textDidChange()
        try await finishQuery()
        XCTAssertNotNil(controller.lastPromptDescription)
        XCTAssertEqual(controller.lastResultDescription, "there")
        XCTAssertNil(controller.indicator.timer, "the dots end with the query")
    }

    // An abstain records nothing shown and takes the dots down.
    func testAnAbstainTakesTheDotsDown() async throws {
        fake.before = "Hi "
        controller.textDidChange()
        fake.window.show(mode: .thinking(2), at: caret)
        try await finishQuery()
        XCTAssertNil(fake.window.currentMode)
        XCTAssertNil(controller.lastResultDescription)
        XCTAssertEqual(controller.lastEvent, "engine returned no suggestion")
    }

    // An engine error frees the slot, says so and stops the dots.
    func testAnEngineErrorIsSaid() async throws {
        fake.engine.completionError = URLError(.timedOut)
        fake.before = "Hi "
        controller.textDidChange()
        try await finishQuery()
        XCTAssertNil(controller.queries.current)
        XCTAssertTrue(controller.lastEvent.hasPrefix("engine error: "), controller.lastEvent)
        XCTAssertEqual(fake.window.currentMode, .error("engine error"))
        XCTAssertNil(controller.indicator.timer)
    }

    // A query called off between the engine's answer and its landing — a
    // partial, the end of the stream or an error already on its way back
    // to the main actor — lands nothing and says nothing.
    func testACalledOffQueryLandsNothing() async throws {
        let ends: [(String, (AsyncThrowingStream<String, Error>.Continuation) -> Void)] = [
            ("a partial", { $0.yield("there") }),
            ("the end", { $0.finish() }),
            ("an error", { $0.finish(throwing: URLError(.timedOut)) }),
        ]
        fake.engine.holdsStreams = true
        for (name, end) in ends {
            fake.before = "Hi "
            controller.textDidChange()
            let task = try XCTUnwrap(controller.queries.current?.task)
            let asked = fake.engine.requests.count, deadline = Date().addingTimeInterval(5)
            while fake.engine.requests.count == asked, Date() < deadline { await Task.yield() }
            for _ in 0..<5 { await Task.yield() }   // the consumer waits on the stream
            end(try XCTUnwrap(fake.engine.stream))
            controller.dismiss()
            controller.report("called off")
            await task.value
            XCTAssertNil(fake.window.ghost, name)
            XCTAssertNil(controller.field.ghost, name)
            XCTAssertEqual(controller.lastEvent, "called off", name)
            XCTAssertNil(controller.lastPromptDescription, name)
        }
    }

    // MARK: - An offer's record

    // The record is stamped when it resolves: the engine's model and its
    // first-word log-prob, a capped ctx, a timestamp.
    func testAnOfferIsStampedWhenItResolves() {
        let long = String(repeating: "word ", count: 300)
        showGhost("to be", on: long)
        fake.now += 1.5
        controller.dismiss()
        let entry = fake.offers.last
        XCTAssertEqual(entry?.ctx, String(long.suffix(1000)))
        XCTAssertEqual(entry?.ctx.count, 1000)
        XCTAssertFalse(entry?.ts.isEmpty ?? true)
        XCTAssertEqual(entry?.firstWordLogProb, -0.5)
        XCTAssertEqual(entry?.model, "fake-model")
        XCTAssertEqual(entry?.engine, "fake")
        XCTAssertEqual(entry?.shownForMs, 1500)
        XCTAssertEqual(entry?.outcome, .abandoned)
    }

    // An undo's journal row keeps the last 1000 characters of its context.
    func testAnUndoRowsContextIsCapped() throws {
        let long = String(repeating: "word ", count: 300)
        showGhost("so", on: long)
        try press(KeyCode.tab)
        fake.before = long + "so"
        XCTAssertTrue(try press(KeyCode.z, .maskCommand, typing: "z"))
        fake.runHops()
        XCTAssertEqual(fake.undos.first?.ctx, String(long.suffix(1000)))
    }

    // A ghost trimmed to the line is journaled as what was drawn.
    func testATrimmedGhostIsJournaledAsDrawn() throws {
        fake.window.room = 2
        fake.before = "Hi "
        controller.textDidChange()
        XCTAssertTrue(controller.apply("to be", requestText: "Hi "))
        XCTAssertEqual(controller.field.ghost?.text, "to")
        controller.dismiss()
        XCTAssertEqual(fake.offers.last?.suggestion, "to")
    }

    // No caret to hang the ghost on: nothing is shown at all.
    func testNoCaretNoGhost() {
        fake.before = "Hi "
        controller.textDidChange()
        XCTAssertFalse(controller.apply("there", requestText: "Hi ", cachedContext: TextContext(
            textBeforeCaret: "Hi ", textAfterCaret: "", caretRect: nil, host: HostTextStyle())))
        XCTAssertNil(fake.window.ghost)
        XCTAssertNil(controller.field.ghost)
        XCTAssertEqual(controller.lastEvent, "no caret geometry — cannot place overlay")
    }

    // MARK: - The reply's slot

    // A reply takes the slot and the window: the ghost up is retired, the
    // dots run while it composes, and its end frees the slot and stops them.
    func testAReplyTakesTheSlotAndTheWindow() async throws {
        set(\.screenContextEnabled, true)
        showGhost("to be", on: "Hi ")
        XCTAssertTrue(controller.replyComposer.compose())
        XCTAssertNil(controller.field.ghost)
        XCTAssertNil(fake.window.ghost)
        XCTAssertEqual(fake.offers.last?.outcome, .abandoned)
        XCTAssertNotNil(controller.indicator.timer, "the dots run while it composes")
        let task = try XCTUnwrap(controller.queries.current?.task)
        await task.value   // nothing on screen to answer
        XCTAssertNil(controller.queries.current)
        XCTAssertNil(controller.indicator.timer)
    }

    // The reply's own read becomes the cache an accept advances from.
    func testTheReplysReadBecomesTheCache() async throws {
        set(\.screenContextEnabled, true)
        fake.before = "Hi "
        controller.textDidChange()
        try press(Self.keyC, .maskCommand, typing: "c")
        XCTAssertNil(controller.field.cache)
        fake.screen = "Alice: lunch?"
        fake.engine.reply = "sure"
        XCTAssertTrue(controller.replyComposer.compose())
        XCTAssertEqual(controller.field.cache, "Hi ")
        try await finishQuery()
        XCTAssertEqual(fake.window.ghost, "sure")
        try press(KeyCode.tab, .maskShift)
        XCTAssertEqual(controller.field.cache, "Hi sure")
    }

    // MARK: - A field read

    // A read leaves its caret and style for the indicator and the side
    // flows, and refreshes the screen and the user's examples off it.
    func testAReadFeedsTheCaretTheScreenAndTheExamples() async {
        set(\.screenContextEnabled, true)
        await enterApp("com.apple.TextEdit")   // a window to read
        var style = HostTextStyle()
        style.font = .systemFont(ofSize: 20)
        fake.host = style
        fake.before = "see you at noon"
        controller.textDidChange()
        XCTAssertEqual(controller.lastCaretRect, caret)
        XCTAssertEqual(controller.lastHostStyle, style)
        XCTAssertTrue(controller.promptContext.screenCaptureInFlight)
        let deadline = Date().addingTimeInterval(5)
        while fake.phraseLookups == 0, Date() < deadline { await Task.yield() }
        XCTAssertEqual(fake.phraseLookups, 1)
    }

    // The caret moved into a word under a ghost: it goes, said, journaled.
    func testAGhostGoesWhenTheCaretSplitsAWord() {
        showGhost("to be", on: "Hi ")
        fake.after = "x"
        controller.textDidChange()
        XCTAssertNil(fake.window.ghost)
        XCTAssertNil(controller.field.ghost)
        XCTAssertEqual(controller.lastEvent, "caret splits a word — no suggestion")
        XCTAssertEqual(fake.offers.last?.outcome, .abandoned)
        XCTAssertNil(controller.indicator.timer)
    }

    // The caret moving into a word stops the dots of the query it ends.
    func testASplitWordStopsTheDots() {
        fake.before = "Hi "
        controller.textDidChange()
        XCTAssertNotNil(controller.indicator.timer)
        fake.after = "x"
        controller.textDidChange()
        XCTAssertNil(controller.indicator.timer)
        XCTAssertNil(controller.queries.current)
    }

    // An engine that failed to load says so at the caret, the usual time.
    func testAFailedEnginesNoticeLastsTheUsualTime() {
        fake.before = "Hi "
        controller.textDidChange()
        fake.engine.state = .failed("no model")
        controller.indicator.tick()
        XCTAssertEqual(fake.window.currentMode, .error("engine not working"))
        XCTAssertEqual(fake.window.noticeTimes?.hideAfter, 1.8)
    }

    // Nothing left to complete: the dots drawn for the last query go too.
    func testAClearedFieldTakesTheDotsDown() {
        fake.before = "Hi "
        controller.textDidChange()
        fake.window.show(mode: .thinking(2), at: caret)
        fake.before = "  "
        controller.textDidChange()
        XCTAssertNil(fake.window.currentMode)
        XCTAssertNil(controller.indicator.timer)
    }

    // The ghost is drawn at the read's caret, in the field's style; a
    // dictation notice at the last caret known, in the style known there.
    func testWhereThingsAreDrawn() throws {
        var style = HostTextStyle()
        style.font = .systemFont(ofSize: 20)
        fake.host = style
        showGhost("to be", on: "Hi ")
        XCTAssertEqual(fake.window.drawnAt?.rect, caret)
        XCTAssertEqual(fake.window.drawnAt?.host, style)
        controller.dismiss()
        fake.tracked = nil
        controller.insertDictated("hello")
        XCTAssertEqual(fake.window.drawnAt?.rect, caret)
        XCTAssertEqual(fake.window.drawnAt?.host, style)
    }

    // MARK: - What dictation asks of the pipeline

    // A capture starting takes the completion, a fix and the dots.
    func testACaptureStartingTakesTheDots() {
        fake.before = "Hi "
        controller.textDidChange()
        XCTAssertNotNil(controller.indicator.timer)
        controller.prepareForDictation()
        XCTAssertNil(controller.indicator.timer)
        XCTAssertNil(controller.queries.current)
    }

    // Each rescue puts the words on the clipboard and says why at the caret.
    func testEachRescueSaysWhy() {
        let reasons: [(DictationRescue, String)] = [
            (.focusMoved, "focus moved — dictation copied, ⌘V to paste"),
            (.caretMoved, "the caret moved — dictation copied, ⌘V to paste"),
            (.timedOut, "transcription timed out — the preview is copied, ⌘V to paste"),
            (.failed, "transcription failed — the preview is copied, ⌘V to paste"),
        ]
        fake.before = "Hi "
        controller.textDidChange()
        for (reason, notice) in reasons {
            controller.rescueDictated("hello", because: reason)
            XCTAssertEqual(fake.copied, ["hello"])
            XCTAssertEqual(fake.window.currentMode, .hint(notice))
            XCTAssertTrue(controller.lastEvent.hasPrefix("dictation copied to the clipboard — "))
            fake.window.hide(force: true)
            fake.pasteboard.clearContents()
        }
    }

    // Dictation's overlay calls: its pill hides, its busy edge re-judges the
    // scroll monitor.
    func testDictationsOverlayCalls() async {
        controller.showOverlay(.status("listening"), at: caret, host: HostTextStyle())
        controller.hideOverlay()
        XCTAssertNil(fake.window.currentMode)
        await startHandsFreeCapture()
        controller.keyTap.wantsScroll = false
        controller.dictationBusyChanged()
        XCTAssertTrue(controller.keyTap.wantsScroll)
    }

    // A ghost narrowed by the user typing its head asks the engine nothing.
    func testNarrowingAGhostAsksNothing() throws {
        showGhost("to be", on: "Hi ")
        let query = controller.queries.current?.id
        fake.before = "Hi t"
        try type("t")
        controller.textDidChange()
        XCTAssertEqual(fake.window.ghost, "o be")
        XCTAssertEqual(controller.queries.current?.id, query, "no new query")
    }

    // A completion is capped at 120 characters — a reply at 400.
    func testACompletionIsCapped() {
        fake.before = "Hi "
        controller.textDidChange()
        XCTAssertTrue(controller.apply(String(repeating: "word ", count: 30), requestText: "Hi "))
        XCTAssertEqual(controller.field.ghost?.text.count, 119, "120, less the space at the cut")
        let context = TextContext(textBeforeCaret: "Hi ", textAfterCaret: "", caretRect: caret, host: HostTextStyle())
        XCTAssertTrue(controller.offerReply(String(repeating: "x", count: 450), on: context))
        XCTAssertEqual(controller.field.ghost?.text.count, 400)
    }

    // An abstain after a shown answer clears what Diagnostics last showed.
    func testAnAbstainClearsTheLastResult() async throws {
        fake.engine.partials = ["there"]
        fake.before = "Hi "
        controller.textDidChange()
        try await finishQuery()
        XCTAssertEqual(controller.lastResultDescription, "there")
        controller.dismiss()
        fake.engine.partials = []
        fake.before = "Hi t"
        controller.textDidChange()
        try await finishQuery()
        XCTAssertNil(controller.lastResultDescription)
    }

    // A glued answer retires the ghost already up, with its record.
    func testAGluedAnswerRetiresTheGhostUp() {
        fake.before = "the quick bro"
        controller.textDidChange()
        XCTAssertTrue(controller.apply("wn", requestText: "the quick bro"))
        XCTAssertFalse(controller.apply("fox", requestText: "the quick bro"))
        XCTAssertNil(controller.field.ghost)
        XCTAssertNil(fake.window.ghost)
        XCTAssertEqual(fake.offers.last?.outcome, .abandoned)
    }

    // A reply's leading space is the model's own (`cleanReply` keeps one only
    // where the model wrote it), so it stays even where the two words would
    // make one: "так же" + " не" is not "жене".
    func testAReplyKeepsTheModelsOwnSpace() {
        fake.before = "так же"
        controller.textDidChange()
        XCTAssertTrue(controller.apply(" не забудь", requestText: "так же", reply: true))
        XCTAssertEqual(controller.field.ghost?.text, " не забудь")
    }

    // MARK: - Records

    // One stream is one offer, however many partials grow it.
    func testAStreamIsOneOffer() async throws {
        fake.engine.partials = ["the", "there", "there it"]
        fake.before = "Hi "
        controller.textDidChange()
        try await finishQuery()
        XCTAssertEqual(fake.window.ghost, "there it")
        controller.dismiss()
        XCTAssertEqual(fake.offers.map(\.outcome), [.abandoned])
        XCTAssertEqual(fake.offers.first?.suggestion, "there it")
    }

    // A fresh answer over a ghost still up closes that ghost's record as
    // superseded and opens its own.
    func testAFreshAnswerSupersedesTheGhostUp() {
        showGhost("to be", on: "Hi ")
        XCTAssertTrue(controller.apply("so", requestText: "Hi "))
        XCTAssertEqual(fake.offers.map(\.outcome), [.superseded])
        XCTAssertEqual(fake.offers.first?.suggestion, "to be")
        controller.dismiss()
        XCTAssertEqual(fake.offers.last?.suggestion, "so")
    }

    // MARK: - What a dismiss takes

    // The ghost, a fix in flight and the dots.
    func testADismissTakesAFixInFlightAndTheDots() throws {
        fake.before = "I saw teh"
        fake.engine.correction = "I saw the"
        XCTAssertTrue(try press(KeyCode.tab, .maskAlternate))
        fake.runHops()
        XCTAssertTrue(controller.correctionController.inFlight)
        XCTAssertNotNil(controller.indicator.timer)
        controller.dismiss()
        XCTAssertFalse(controller.correctionController.inFlight)
        XCTAssertNil(controller.indicator.timer)
    }

    // A query alone on its way is reason enough for a drop to dismiss.
    func testADropTakesAQueryWithNothingDrawn() {
        fake.before = "Hi "
        controller.textDidChange()
        controller.focusTracker.onViewportChange?()
        XCTAssertNil(controller.queries.current)
        XCTAssertEqual(controller.lastEvent, "dismissed — the window moved or resized")
    }

    // MARK: - An answer that can't land

    // The read now trails a key the tap saw, or can't be made: not shown,
    // and the dots go.
    func testAnAnswerForATrailingOrUnreadableFieldIsNotShown() throws {
        fake.before = "Hi "
        controller.textDidChange()
        try type("t")   // the cache says "Hi t", the field still "Hi "
        XCTAssertFalse(controller.apply("there", requestText: "Hi "))
        XCTAssertEqual(controller.lastEvent, "field read trails the last keystroke; result dropped")
        XCTAssertNil(fake.window.ghost)

        fake.window.show(mode: .thinking(2), at: caret)
        fake.readable = false
        XCTAssertFalse(controller.apply("there", requestText: "Hi t"))
        XCTAssertEqual(controller.lastEvent, "lost text element")
        XCTAssertNil(fake.window.currentMode)
    }

    // An answer the user typed past is hidden with the dots.
    func testAStaleAnswerTakesTheDotsDown() {
        fake.before = "Hi "
        controller.textDidChange()
        fake.before = "Ho"
        controller.textDidChange()
        fake.window.show(mode: .thinking(2), at: caret)
        XCTAssertFalse(controller.apply("there", requestText: "Hi "))
        XCTAssertEqual(controller.lastEvent, "context changed; dropped result")
        XCTAssertNil(fake.window.currentMode)
    }

    // MARK: - Diagnostics

    // The Diagnostics lines say what the pipeline sees: the field, the
    // engine, the prompt last sent (and its screen share), the last event.
    func testTheDiagnosticsSayWhatThePipelineSees() async throws {
        set(\.screenContextEnabled, true)
        await enterApp("com.apple.TextEdit")
        fake.screen = "Alice: lunch?"
        fake.engine.partials = ["there"]
        fake.before = "Hi "
        controller.textDidChange()
        try await finishQuery()
        let deadline = Date().addingTimeInterval(5)
        while controller.promptContext.screenCaptureInFlight, Date() < deadline { await Task.yield() }
        let lines = controller.diagnostics
        XCTAssertEqual(lines.count, 7)
        XCTAssertTrue(lines[0].hasPrefix("Accessibility: "))
        XCTAssertEqual(lines[1], "Key tap: NOT active ✗")
        XCTAssertEqual(lines[2], "Text element: detected ✓")
        XCTAssertEqual(lines[3], "Engine: fake")
        XCTAssertTrue(lines[4].hasPrefix("Dictation: "))
        let prompt = try XCTUnwrap(controller.lastPromptDescription)
        XCTAssertEqual(lines[5], "Prompt: \(prompt.count) chars (incl. 13 screen)")
        XCTAssertEqual(lines[6], "Last: suggesting \"there\"")

        fake.panelOwner = 4242   // a launcher holds the keys
        XCTAssertEqual(controller.diagnostics[2], "Text element: none")
    }

    // A notice raised with a moment of immunity (dictation's) outlives the
    // pipeline's ordinary dismissals in that moment; a drop that means the
    // caret moved takes it.
    func testAProtectedNoticeOutlivesThePipelinesChatter() {
        fake.tracked = nil
        controller.insertDictated("hello")   // no field: copied, said at the caret
        let notice = fake.window.currentMode
        XCTAssertNotNil(notice)
        XCTAssertTrue(fake.window.noticeTimes.map { $0 == (1.8, 1.2) } ?? false, "up the usual time, immune 1.2 s")
        controller.textDidChange()           // no field: an ordinary dismiss
        XCTAssertEqual(fake.window.currentMode, notice)
        controller.focusTracker.onViewportChange?()
        XCTAssertNil(fake.window.currentMode)
    }
}
