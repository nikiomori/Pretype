import AppKit
import XCTest
@testable import Pretype

/// The pipeline on a real controller: the query lifecycle, the settle window,
/// ⌘Z, the reply, pointer and focus events, and dead handles.
@MainActor
final class SuggestionControllerTests: PipelineTestCase {
    // MARK: - Query lifecycle

    // One edit reaches the pipeline twice (the AX notification, then the
    // keystroke timer): the second read must not restart the query.
    func testOneEditRunsOneQuery() async throws {
        fake.before = "Hi "
        fake.engine.partials = ["the", "there"]
        controller.textDidChange()
        let first = controller.queries.current?.id
        XCTAssertEqual(controller.queries.current?.kind, .completion(before: "Hi ", after: ""))
        controller.textDidChange()
        XCTAssertEqual(controller.queries.current?.id, first)

        try await finishQuery()
        XCTAssertNil(controller.queries.current)
        XCTAssertEqual(fake.engine.requests.map(\.textBeforeCaret), ["Hi "])
        XCTAssertEqual(fake.window.ghost, "there")
        XCTAssertEqual(controller.field.ghost?.anchor, "Hi ")
        let latencies = fake.bookings.filter { if case .latency = $0 { return true } else { return false } }
        XCTAssertEqual(latencies.count, 1, "the wait the user feels: the first token, once a query")
    }

    // A result for text the user has since typed on from: usable while the
    // new keys match its head, dropped once they don't.
    func testAResultForStaleTextNarrowsOrDrops() async throws {
        fake.engine.partials = ["to be"]
        fake.before = "Hi "
        controller.textDidChange()
        fake.before = "Hi to "
        XCTAssertFalse(try type("to "))   // before the result came back
        XCTAssertEqual(controller.field.cache, "Hi to ")
        try await finishQuery()
        XCTAssertEqual(fake.window.ghost, "be", "the typed head is taken off")
        XCTAssertEqual(controller.field.ghost?.anchor, "Hi to ")

        controller.dismiss()
        fake.before = "Hi "
        controller.textDidChange()
        fake.before = "Hi y"
        try type("y")
        try await finishQuery()
        XCTAssertNil(fake.window.ghost, "typed past it")
        XCTAssertNil(controller.field.ghost)
    }

    // A query superseded before it ran never reaches the engine.
    func testASupersededQueryNeverRuns() async throws {
        fake.before = "Hi "
        controller.textDidChange()
        let stale = controller.queries.current?.task
        fake.before = "Hi t"
        controller.textDidChange()
        await stale?.value
        try await finishQuery()
        XCTAssertEqual(fake.engine.requests.map(\.textBeforeCaret), ["Hi t"])
    }

    // A ghost retired under its running query (here by a ⌘-chord, which can
    // rewrite the field) retires the query's dedupe too: the same text read
    // again must query again, not find "already running" and show nothing.
    func testARetiredQueryIsNotRevived() throws {
        showGhost("there", on: "Hi ")
        let first = controller.queries.current?.id
        try press(Self.keyC, .maskCommand, typing: "c")
        XCTAssertNil(controller.field.ghost)
        XCTAssertEqual(controller.queries.current?.kind, .retired)

        controller.textDidChange()   // the field still reads "Hi "
        XCTAssertNotEqual(controller.queries.current?.id, first)
        XCTAssertEqual(controller.queries.current?.kind, .completion(before: "Hi ", after: ""))
    }

    // A query slot left held over a task that never finishes reads as
    // "completing" forever — the thinking dots, the scroll monitor. Clearing
    // the field, or an engine that failed, frees it.
    func testNothingToCompleteFreesTheQuerySlot() {
        fake.before = "Hi "
        controller.textDidChange()
        XCTAssertTrue(controller.isCompleting)
        fake.before = "   "
        controller.textDidChange()
        XCTAssertFalse(controller.isCompleting, "nothing left to complete")

        fake.before = "Hi "
        controller.textDidChange()
        fake.engine.state = .failed("no model")
        fake.before = "Hi t"
        controller.textDidChange()
        XCTAssertFalse(controller.isCompleting, "the engine failed")
    }

    // ⇧⇥ took the whole ghost: its stream ends with it, or a later partial
    // would re-mint a continuation at the old caret.
    func testAFullAcceptEndsItsStream() async throws {
        fake.engine.partials = ["to be"]
        showGhost("to be", on: "Hi ")
        let stream = try XCTUnwrap(controller.queries.current?.task)
        XCTAssertTrue(try press(KeyCode.tab, .maskShift))
        XCTAssertNil(controller.queries.current)
        XCTAssertTrue(stream.isCancelled)
        await stream.value
        XCTAssertNil(fake.window.ghost)
    }

    // A letter or digit right after the caret splits a word: anything
    // accepted there fuses into its remainder ("hel|lo" + "p" → "helplo").
    func testNoSuggestionInsideAWord() {
        fake.before = "Hi "
        for next in ["5", "x"] {
            fake.after = next
            controller.textDidChange()
            XCTAssertNil(controller.queries.current, next)
        }
        fake.after = " "
        controller.textDidChange()
        XCTAssertEqual(controller.queries.current?.kind, .completion(before: "Hi ", after: " "))
    }

    // MARK: - Reply

    // ⌥⇧⇥ in an empty chat box: a fresh, wider capture of the conversation,
    // and the whole reply as one ghost — past the 120 characters a completion
    // is capped at, and never trimmed to the line — that ⇧⇥ types in full.
    func testTheReplyChordOffersTheWholeReply() async throws {
        set(\.screenContextEnabled, true)
        let reply = "Sure, noon works for me. I'll book the table by the window, and bring the slides so we can go"
            + " through them over coffee afterwards."
        fake.screen = "Alice: lunch at noon?"
        fake.engine.reply = reply
        fake.window.room = 20
        XCTAssertTrue(try press(KeyCode.tab, [.maskAlternate, .maskShift]))
        XCTAssertNil(controller.queries.current, "composed off the tap callback")
        fake.runHops()
        XCTAssertTrue(controller.queries.isReply)
        try await finishQuery()
        XCTAssertEqual(fake.captures, [1200])
        XCTAssertEqual(fake.engine.conversations, ["Alice: lunch at noon?"])
        XCTAssertGreaterThan(reply.count, 120)
        XCTAssertEqual(fake.window.ghost, reply)
        XCTAssertTrue(try press(KeyCode.tab, .maskShift))
        XCTAssertEqual(fake.keys, [.insert(reply)])
    }

    // A reply holds the query slot: typing while it is composed supersedes it.
    func testTypingSupersedesAReplyBeingComposed() async throws {
        set(\.screenContextEnabled, true)
        fake.screen = "Alice: lunch at noon?"
        fake.engine.reply = "Sure"
        XCTAssertTrue(controller.replyComposer.compose())
        let composing = controller.queries.current?.task
        fake.before = "Hi "
        controller.textDidChange()
        XCTAssertEqual(controller.queries.current?.kind, .completion(before: "Hi ", after: ""))
        await composing?.value
        XCTAssertTrue(fake.engine.conversations.isEmpty)
        XCTAssertNil(fake.window.ghost)
    }

    // An automatic offer runs only on a reply model already loaded — never the
    // download of one nobody asked for. Asked for, the reply runs regardless.
    func testAnAutomaticReplyWaitsForALoadedModel() {
        set(\.screenContextEnabled, true)
        fake.engine.correctionReady = false
        fake.before = ""
        XCTAssertFalse(controller.replyComposer.compose(auto: true))
        XCTAssertNil(controller.queries.current)
        XCTAssertTrue(controller.replyComposer.compose())
        XCTAssertTrue(controller.queries.isReply)
    }

    // Without the screen there is nothing to reply to: the chord says which of
    // the three is missing; an automatic offer stays silent.
    func testAReplyThatCannotReadTheScreenSaysWhy() {
        set(\.screenContextEnabled, true)
        fake.screenRecording = false
        XCTAssertFalse(controller.replyComposer.compose(auto: true))
        XCTAssertNil(fake.window.currentMode)
        XCTAssertEqual(controller.lastEvent, "waiting for typing")

        XCTAssertFalse(controller.replyComposer.compose())
        XCTAssertNil(controller.queries.current)
        XCTAssertTrue(controller.lastEvent.hasPrefix("reply: needs screen context"))
        guard case .hint = fake.window.currentMode else { return XCTFail("no notice at the caret") }
    }

    // Offered automatically only in an empty message box.
    func testAnAutomaticReplyOnlyInAnEmptyBox() {
        set(\.screenContextEnabled, true)
        fake.before = "Hi"
        XCTAssertFalse(controller.replyComposer.compose(auto: true))
        XCTAssertNil(controller.queries.current)
        fake.before = ""
        XCTAssertTrue(controller.replyComposer.compose(auto: true))
        XCTAssertTrue(controller.queries.isReply)
    }

    // MARK: - Accept and the settle window

    // ⇥ types the ghost's next word, ⇧⇥ the rest: exactly those characters,
    // with the cache and the ⌘Z record moved in step.
    func testAcceptTypesExactlyWhatIsShown() throws {
        showGhost("there you", on: "Hi ")
        XCTAssertTrue(try press(KeyCode.tab))
        XCTAssertEqual(fake.keys, [.insert("there")])
        XCTAssertEqual(fake.window.ghost, " you")
        XCTAssertEqual(controller.field.cache, "Hi there")
        XCTAssertTrue(try press(KeyCode.tab, .maskShift))
        XCTAssertEqual(fake.keys, [.insert("there"), .insert(" you")])
        XCTAssertNil(controller.field.ghost)
        XCTAssertEqual(controller.field.cache, "Hi there you")
        XCTAssertEqual(controller.field.pendingUndo?.chunk, " you")
        XCTAssertFalse(try press(KeyCode.tab), "nothing left to accept: ⇥ is the app's")
    }

    // A key typed into the ghost shrinks it: ⇥ then types the rest of the
    // word, not the word again.
    func testTypingIntoTheGhostShrinksIt() throws {
        showGhost("to be", on: "Hi ")
        try type("t")
        XCTAssertEqual(controller.field.ghost?.text, "o be")
        try press(KeyCode.tab)
        XCTAssertEqual(fake.keys, [.insert("o")])
    }

    // Text typed where the tap never saw it (a menu paste, the system's own
    // dictation, an input method) narrows the ghost from the read alone.
    func testAReadNarrowsTheGhostByTextTypedUnseen() {
        showGhost("there", on: "Hi ")
        fake.before = "Hi th"
        controller.textDidChange()
        XCTAssertEqual(controller.field.ghost?.text, "ere")
        XCTAssertEqual(controller.field.ghost?.anchor, "Hi th")
        XCTAssertEqual(fake.window.ghost, "ere")
    }

    // AX reads trail synthetic keys: inside the settle window a read of the
    // pre-accept text must not regress the cache or drop the ghost, and a
    // streamed partial is dropped. The deadline bounds the wait.
    func testSettleWindowHoldsOffTrailingReads() throws {
        showGhost("to be", on: "Hi ")
        try press(KeyCode.tab)
        fake.now += 0.1
        controller.textDidChange()   // still reads "Hi "
        XCTAssertEqual(controller.field.cache, "Hi to")
        XCTAssertEqual(controller.field.ghost?.text, " be")

        fake.before = "Hi to"   // the host caught up, but no read has said so
        XCTAssertFalse(controller.apply("to be or", requestText: "Hi "), "a partial inside the window")
        XCTAssertEqual(controller.field.ghost?.text, " be")
        fake.runScheduled()
        XCTAssertFalse(controller.field.isSettling(at: fake.now))
        XCTAssertEqual(fake.window.ghost, " be")

        try press(KeyCode.tab)
        fake.now += 0.5   // a read that never catches up is believed once the window closes
        controller.textDidChange()
        XCTAssertEqual(controller.field.cache, "Hi to")
    }

    // ⎋ drops the ghost and still reaches the app; nothing is offered on that
    // field again — an AX notification that leaves the text alone re-runs the
    // pipeline — until it changes.
    func testEscapeDeclinesTheGhostUntilTheFieldChanges() throws {
        showGhost("to be", on: "Hi ")
        XCTAssertFalse(try press(KeyCode.escape))
        XCTAssertNil(fake.window.ghost)
        XCTAssertNil(controller.field.ghost)
        controller.textDidChange()
        XCTAssertNil(controller.queries.current, "declined: no query")
        XCTAssertNil(fake.window.ghost)
        fake.before = "Hi y"
        controller.textDidChange()
        XCTAssertEqual(controller.queries.current?.kind, .completion(before: "Hi y", after: ""))
    }

    // ⇥ accepts only what is on screen: a ghost a dictation pill (or a notice,
    // or a fix pill) has covered is no longer the thing the user sees.
    func testAGhostUnderAnotherOverlayIsNotAccepted() throws {
        showGhost("to be", on: "Hi ")
        controller.showOverlay(.listening("hello"), at: CGRect(x: 100, y: 100, width: 1, height: 16),
                               host: HostTextStyle())
        XCTAssertNotNil(controller.field.ghost)
        XCTAssertFalse(try press(KeyCode.tab))
        XCTAssertTrue(fake.keys.isEmpty)
    }

    // ⌘Z puts the field back to the text the ghost was offered on: the next
    // read must not draw — and ⇥ re-type — the same ghost (ee4a3f1).
    func testCommandZDeclinesTheGhostItUndid() throws {
        showGhost("there", on: "Hi ")
        try press(KeyCode.tab)
        fake.before = "Hi there"
        controller.undoAccept(try XCTUnwrap(controller.field.pendingUndo))   // the tap's hop off its callback
        XCTAssertEqual(fake.keys, [.insert("there"), .delete("there", perCharacter: false)])
        XCTAssertNil(controller.field.undoable)

        fake.before = "Hi "
        fake.now += 0.5
        controller.textDidChange()
        XCTAssertNil(controller.queries.current, "declined: no query")
        XCTAssertNil(fake.window.ghost)
        XCTAssertTrue(controller.field.isDeclined)

        fake.before = "Hi y"
        controller.textDidChange()
        XCTAssertFalse(controller.field.isDeclined)
        XCTAssertEqual(controller.queries.current?.kind, .completion(before: "Hi y", after: ""))
    }

    // ⌘Z is the tap's to swallow only while the field still reads as the
    // accept left it, and the delete runs off the tap callback, after a live
    // re-read. Redo, or ⌘Z once the caret moved, is the app's.
    func testCommandZThroughTheKeyTap() throws {
        showGhost("to be", on: "Hi ")
        try press(KeyCode.tab)
        XCTAssertTrue(try press(KeyCode.z, .maskCommand, typing: "z"))
        XCTAssertNil(controller.field.undoable)
        XCTAssertEqual(fake.keys, [.insert("to")], "nothing deleted inside the callback")
        fake.before = "Hi to"
        fake.runHops()
        XCTAssertEqual(fake.keys, [.insert("to"), .delete("to", perCharacter: false)])

        fake.now += 0.5
        showGhost("to be", on: "Hi ")
        try press(KeyCode.tab)
        XCTAssertFalse(try press(KeyCode.z, [.maskCommand, .maskShift], typing: "z"))

        fake.now += 0.5
        showGhost("to be", on: "Hi ")
        try press(KeyCode.tab)
        fake.before = "Hi t"
        fake.now += 0.5
        controller.textDidChange()
        XCTAssertFalse(try press(KeyCode.z, .maskCommand, typing: "z"))
        XCTAssertTrue(fake.hops.isEmpty)
        XCTAssertEqual(fake.keys.filter { if case .delete = $0 { return true }; return false }.count, 1)
    }

    // The inline ghost trims a suggestion to what fits on the line, and the
    // pill re-render after ⇥ can flip back into a trimmed ghost: ⇧⇥ types
    // exactly what was drawn, never the rest nobody saw.
    func testAcceptTakesOnlyWhatWasDrawn() throws {
        fake.window.room = 5
        fake.before = "Hi "
        controller.textDidChange()
        XCTAssertTrue(controller.apply("to be or", requestText: "Hi "))
        XCTAssertEqual(fake.window.ghost, "to be")
        XCTAssertTrue(try press(KeyCode.tab, .maskShift))
        XCTAssertEqual(fake.keys, [.insert("to be")])

        fake.window.room = nil
        fake.before = "Hi to be "
        fake.now += 0.5
        controller.textDidChange()
        XCTAssertTrue(controller.apply("so it is", requestText: "Hi to be "))
        fake.window.room = 3
        try press(KeyCode.tab)
        XCTAssertEqual(fake.window.ghost, " it")
        XCTAssertTrue(try press(KeyCode.tab, .maskShift))
        XCTAssertEqual(fake.keys, [.insert("to be"), .insert("so"), .insert(" it")])
    }

    // A ⌘Z whose re-read still trails the accept (Electron) skips the delete
    // but keeps the record: the next ⌘Z, once the field caught up, is ours.
    func testCommandZRetriesWhileTheFieldTrailsTheAccept() throws {
        showGhost("to be", on: "Hi ")
        try press(KeyCode.tab)
        XCTAssertTrue(try press(KeyCode.z, .maskCommand, typing: "z"))
        fake.runHops()
        XCTAssertEqual(fake.keys, [.insert("to")], "the field still read the old text")
        XCTAssertTrue(try press(KeyCode.z, .maskCommand, typing: "z"))
        fake.before = "Hi to"
        fake.runHops()
        XCTAssertEqual(fake.keys, [.insert("to"), .delete("to", perCharacter: false)])
    }

    // The ⌘Z runs off the tap callback, and a click can land in between:
    // the caret then sits after the user's own "to", not the accepted one.
    // Only the exact post-accept text proves the chunk is what precedes it.
    func testCommandZDeletesOnlyWhatTheAcceptLeft() throws {
        showGhost("to be", on: "Hi ")
        try press(KeyCode.tab)
        fake.before = "Hi to"
        XCTAssertTrue(try press(KeyCode.z, .maskCommand, typing: "z"))
        controller.pointerPressed()
        fake.before = "I want to"
        fake.runHops()
        XCTAssertEqual(fake.keys, [.insert("to")])
    }

    // Our own keys come back through the tap: the accepted text as typing, a
    // Tab or ⌘Z of the user's own as a chord. Tagged ones are never ours to
    // act on — a ghost still up must not be accepted by the text it typed.
    func testOurOwnInjectedKeysPassStraightThrough() throws {
        showGhost("to be", on: "Hi ")
        let tab = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(KeyCode.tab), keyDown: true))
        tab.flags = []
        tab.setIntegerValueField(.eventSourceUserData, value: TextInjector.magicTag)
        XCTAssertFalse(controller.handleKeyDown(tab))
        XCTAssertEqual(fake.keys, [])
        XCTAssertEqual(controller.field.ghost?.text, "to be")
        XCTAssertEqual(controller.field.cache, "Hi ")
    }

    // ⇥ a word at a time is still one suggestion taken: counted once, or the
    // menu's "accepted of shown" passes 100 %.
    func testAWordByWordAcceptCountsOneSuggestion() throws {
        showGhost("there you are", on: "Hi ")
        try press(KeyCode.tab)
        try press(KeyCode.tab)
        try press(KeyCode.tab, .maskShift)
        XCTAssertEqual(fake.accepts, ["+there", " you", " are"])
    }

    // A fix is typed like an accept, then the field is re-read once its keys
    // landed — the read that retires the pill the old typo raised.
    func testAFixIsReReadOnceItsKeysLand() {
        fake.before = "Hi teh"
        controller.typeFix("the", deleting: "teh", over: "Hi teh")
        XCTAssertEqual(fake.keys, [.delete("eh", perCharacter: false), .insert("he")], "the shared head stays")
        XCTAssertEqual(controller.field.cache, "Hi the")
        let reads = fake.reads
        fake.before = "Hi the"
        fake.advance(0.11)
        XCTAssertEqual(fake.reads, reads, "not before the keys can have landed")
        fake.advance(0.01)
        XCTAssertEqual(fake.reads, reads + 1)
    }

    // ⌘Z takes an accept back only as the very next key. A ⎋, the fix or
    // reply chord, or a dead key (⌥E: nothing typed yet) in between leaves
    // the field as the accept did — and still makes the next ⌘Z the app's.
    func testOnlyTheNextKeyTakesAnAcceptBack() throws {
        let between: [(text: String, key: Int64, flags: CGEventFlags, typing: String)] = [
            ("Hi ", KeyCode.escape, [], "\u{1b}"),
            ("Yo ", KeyCode.tab, .maskAlternate, ""),
            ("Ya ", KeyCode.tab, [.maskAlternate, .maskShift], ""),
            ("Ok ", 14, .maskAlternate, ""),
            ("Um ", 74, [], ""),   // a key that types nothing at all, as a dead key's first press
        ]
        for (text, key, flags, typing) in between {
            fake.now += 0.5
            showGhost("to be", on: text)
            try press(KeyCode.tab)
            fake.before = text + "to"
            try press(key, flags, typing: typing)
            XCTAssertFalse(try press(KeyCode.z, .maskCommand, typing: "z"), "after key \(key)")
        }
    }

    // ⌃ with a printable key (⌃1 switches desktops) types nothing: the ghost
    // retires and the cache is dropped, as for a ⌘-chord.
    func testAControlChordTypesNothing() throws {
        showGhost("1 more", on: "Hi ")
        try press(18, .maskControl, typing: "1")
        XCTAssertNil(controller.field.ghost)
        XCTAssertNil(controller.field.cache)
    }

    // The words typed by ⇥ are re-read once they land, and so is the field a
    // ⌘Z put back — the reads AX trails are the ones that settle the cache.
    func testAnAcceptAndItsUndoAreReReadOnceTheyLand() throws {
        showGhost("to be", on: "Hi ")
        try press(KeyCode.tab)
        var reads = fake.reads
        fake.before = "Hi to"
        fake.advance(0.08)
        XCTAssertEqual(fake.reads, reads)
        fake.advance(0.01)
        XCTAssertEqual(fake.reads, reads + 1)

        XCTAssertTrue(try press(KeyCode.z, .maskCommand, typing: "z"))
        fake.runHops()
        XCTAssertEqual(fake.window.currentMode, .hint("Undone"))
        reads = fake.reads
        fake.before = "Hi "
        fake.advance(0.08)
        XCTAssertEqual(fake.reads, reads)
        fake.advance(0.01)
        XCTAssertEqual(fake.reads, reads + 1)
    }

    // The first ⇥ ever taken finishes onboarding.
    func testTheFirstAcceptFinishesOnboarding() throws {
        set(\.onboardingCompleted, false)
        showGhost("to be", on: "Hi ")
        try press(KeyCode.tab)
        XCTAssertTrue(Settings.onboardingCompleted)
    }

    /// ⌥ pressed and released, as the key tap's modifier handler sees it;
    /// `between` runs while it is down.
    private func tapOption(between: () throws -> Void = {}) throws {
        for down in [true, false] {
            let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(KeyCode.leftOption), keyDown: down))
            event.type = .flagsChanged
            event.flags = down ? .maskAlternate : []
            controller.keyTap.flagsHandler?(event)
            if down { try between() }
        }
    }

    // ⌥⌥ asks for a reply; ⌥ held over a key was a chord, not a tap.
    func testOnlyABareDoubleTapAsksForAReply() throws {
        try tapOption()
        try tapOption()
        XCTAssertEqual(fake.hops.count, 1)
        try tapOption()
        try tapOption { _ = try self.type("x") }
        XCTAssertEqual(fake.hops.count, 1)
    }

    // MARK: - Keys that are never the pipeline's

    // Settings in front: the tracked field is behind it, and the keys type
    // into our own fields. ⌘Z after an accept must not delete there, nor ⇥
    // type the old field's ghost.
    func testKeysInOurOwnWindowPassThrough() throws {
        showGhost("to be", on: "Hi ")
        try press(KeyCode.tab)
        fake.before = "Hi to"
        fake.ownWindowFrontmost = true
        XCTAssertFalse(try press(KeyCode.z, .maskCommand, typing: "z"))
        XCTAssertFalse(try press(KeyCode.tab))
        fake.runHops()
        XCTAssertEqual(fake.keys, [.insert("to")])
    }

    // Paused is off: no chord is swallowed — ⌘Z is the app's undo, ⌥⇥ the
    // app's key — and nothing reads the field.
    func testWhilePausedEveryKeyIsTheApps() throws {
        showGhost("to be", on: "Hi ")
        try press(KeyCode.tab)
        fake.before = "Hi to"
        set(\.enabled, false)
        XCTAssertFalse(try press(KeyCode.z, .maskCommand, typing: "z"))
        XCTAssertFalse(try press(KeyCode.tab, .maskAlternate))
        XCTAssertTrue(fake.hops.isEmpty)
    }

    // An app Pretype was told to stay out of keeps its chords: ⌥⇥ and the
    // reply chord are its own keys there.
    func testAnAppWeStayOutOfKeepsItsChords() async throws {
        let app = FakeFocusApp()
        app.fields = [(FakeWorld.element(1), "Notes")]
        app.focused = FakeWorld.element(1)
        app.bundleID = "com.example.notes"
        _ = await trackRealFocus(app)
        set(\.userBlacklist, ["com.example.notes"])
        fake.before = "Hi teh"
        XCTAssertFalse(try press(KeyCode.tab, .maskAlternate))
        XCTAssertTrue(fake.hops.isEmpty)
    }

    // A launcher (Spotlight) holds the keys over the tracked field: that
    // field is no ghost's anchor, and ⌥⇥ never reads it — its fix would be
    // typed into the launcher.
    func testALauncherHoldingTheKeysHidesTheFieldUnderIt() throws {
        fake.panelOwner = 999_999
        fake.before = "Hi teh"
        controller.textDidChange()
        XCTAssertNil(controller.queries.current)
        let reads = fake.reads
        try press(KeyCode.tab, .maskAlternate)
        fake.runHops()
        XCTAssertEqual(fake.reads, reads)
    }

    // A ⌘-chord may have been a copy: the clipboard, which heads the prompt,
    // is looked at once the copy landed. Other keys leave it alone.
    func testACommandChordLooksAtTheClipboard() throws {
        set(\.clipboardContextEnabled, true)
        func clipboardChecks() -> Int {
            fake.scheduled.filter { abs($0.due.timeIntervalSince(fake.now) - 0.15) < 1e-6 }.count
        }
        try press(Self.keyC, typing: "c")
        XCTAssertEqual(clipboardChecks(), 0)
        try press(Self.keyC, .maskCommand, typing: "c")
        XCTAssertEqual(clipboardChecks(), 1)
    }

    // The tracker missed the field (a web view only the system reports
    // focused): its page is read once per field, and a site switched off
    // stays off there too.
    func testAFieldTheTrackerMissedIsJudgedByItsSite() {
        fake.tracked = nil
        fake.systemField = FakeWorld.element(5)
        fake.site = "bank.example.com"
        set(\.userBlacklist, ["site:bank.example.com"])
        fake.before = "Hi "
        controller.textDidChange()
        XCTAssertNil(controller.queries.current)
        XCTAssertEqual(controller.typingContext.site, "bank.example.com")
    }

    // …and read once per field, not once per keystroke: it is an AX round
    // trip on the typing path.
    func testAMissedFieldsSiteIsReadOnce() {
        fake.tracked = nil
        fake.systemField = FakeWorld.element(5)
        fake.site = "news.example.com"
        fake.before = "Hi "
        controller.textDidChange()
        controller.textDidChange()
        XCTAssertEqual(fake.siteReads, 1)
    }

    // A key typed into the ghost redraws it, and that redraw can trim it to
    // the line: ⇧⇥ then types only what is drawn.
    func testTypingIntoTheGhostKeepsItToWhatIsDrawn() throws {
        showGhost("to be or", on: "Hi ")
        fake.window.room = 3
        try type("t")
        XCTAssertEqual(fake.window.ghost, "o b")
        XCTAssertTrue(try press(KeyCode.tab, .maskShift))
        XCTAssertEqual(fake.keys, [.insert("o b")])
    }

    // An xterm.js panel in VS Code or Cursor deletes a grapheme cluster per
    // Backspace though its app is no terminal: ⌘Z there must press once per
    // Character, or it eats into the user's own text.
    func testTerminalFieldInANonTerminalAppDeletesPerCharacter() throws {
        XCTAssertFalse(AppPolicy.isTerminal(controller.typingContext.bundleID))
        fake.terminalField = true
        showGhost("नमस्ते", on: "hi ")
        try press(KeyCode.tab)
        fake.before = "hi नमस्ते"
        controller.undoAccept(try XCTUnwrap(controller.field.pendingUndo))
        XCTAssertEqual(fake.keys.last, .delete("नमस्ते", perCharacter: true))

        fake.terminalField = false
        controller.inject("", deleting: "ते", over: "hi नमस्ते")
        XCTAssertEqual(fake.keys.last, .delete("ते", perCharacter: false))
    }

    // MARK: - Pointer and focus

    // A click can move the caret where no AX notification says so (Electron):
    // the ghost and a completion query at the old caret go, and the cache with
    // them. A reply in flight stays — it re-reads the field before it lands.
    func testAClickDropsTheGhostButNotAReply() {
        showGhost("to be", on: "Hi ")
        controller.pointerPressed()
        XCTAssertNil(controller.field.ghost)
        XCTAssertNil(fake.window.ghost)
        XCTAssertNil(controller.field.cache)
        XCTAssertNil(controller.queries.current)
        XCTAssertEqual(controller.lastEvent, "dismissed — mouse click")

        set(\.screenContextEnabled, true)
        XCTAssertTrue(controller.replyComposer.compose())
        controller.pointerPressed()
        XCTAssertTrue(controller.queries.isReply)
        XCTAssertNil(controller.field.cache)
    }

    // A scroll strands what is drawn: the ghost and its query go. A reply in
    // flight keeps running, with the caret and the cache forgotten so it lands
    // on a fresh read rather than at the pre-scroll spot.
    func testAScrollDropsTheOverlayButNotAReply() {
        showGhost("to be", on: "Hi ")
        controller.scrolled(momentum: false)
        XCTAssertNil(controller.field.ghost)
        XCTAssertNil(fake.window.ghost)
        XCTAssertNil(controller.queries.current)
        XCTAssertEqual(controller.lastEvent, "dismissed — the view scrolled")
        XCTAssertEqual(fake.hops.count, 1, "the scroll monitor is re-judged off the handler")

        set(\.screenContextEnabled, true)
        XCTAssertTrue(controller.replyComposer.compose())
        XCTAssertNotNil(controller.lastCaretRect)
        controller.scrolled(momentum: true)
        XCTAssertTrue(controller.queries.isReply)
        XCTAssertNil(controller.lastCaretRect)
        XCTAssertNil(controller.field.cache)
        XCTAssertFalse(fake.window.isVisible)
    }

    // The cache, a settle window and a decline describe the field just left:
    // carried over, the next keystroke would glue onto the old text and the
    // new field's reads would wait on the old one's settle.
    func testAFocusChangeForgetsTheField() async throws {
        let app = FakeFocusApp(), message = FakeWorld.element(1), search = FakeWorld.element(3)
        app.fields = [(message, "Message"), (search, "Search")]
        app.focused = message
        let tracker = await trackRealFocus(app)
        showGhost("to be", on: "Hi ")
        try press(KeyCode.tab)
        try press(KeyCode.escape)
        XCTAssertTrue(controller.field.isSettling(at: fake.now))
        XCTAssertTrue(controller.field.isDeclined)
        XCTAssertNotNil(controller.field.cache)

        app.focused = search
        tracker.handleNotification(kAXFocusedUIElementChangedNotification, element: app.element)
        await settleMain()
        XCTAssertEqual(controller.focusGeneration, 2)
        XCTAssertNil(controller.field.cache)
        XCTAssertFalse(controller.field.isSettling(at: fake.now))
        XCTAssertFalse(controller.field.isDeclined)
    }

    // A reply composed for one field is never drawn in the next: the focus
    // change cancels it while the engine is still writing it.
    func testAFocusChangeDropsAReplyInFlight() async throws {
        let app = FakeFocusApp(), message = FakeWorld.element(1), search = FakeWorld.element(3)
        app.fields = [(message, "Message"), (search, "Search")]
        app.focused = message
        let tracker = await trackRealFocus(app)
        set(\.screenContextEnabled, true)
        fake.screen = "Alice: lunch at noon?"
        fake.engine.reply = "Sure"
        let gate = HeldCall()
        fake.engine.replyGate = gate
        XCTAssertTrue(controller.replyComposer.compose())
        let composing = try XCTUnwrap(controller.queries.current?.task)
        var entered = gate.entered.makeAsyncIterator()
        _ = await entered.next()

        app.focused = search
        tracker.handleNotification(kAXFocusedUIElementChangedNotification, element: app.element)
        await settleMain()
        gate.open()
        await composing.value
        XCTAssertEqual(fake.engine.conversations, ["Alice: lunch at noon?"])
        XCTAssertNil(fake.window.ghost)
        XCTAssertNil(controller.field.ghost)
    }

    // MARK: - Dead handles

    // A web app re-mounting its node under the caret (an accept does it) is
    // re-latched quietly: the ghost and ⌘Z survive the swap (f1cca72).
    func testADeadWebHandleIsRelatched() throws {
        let old = try XCTUnwrap(fake.tracked), new = FakeWorld.element(2)
        showGhost("to be", on: "Hi ")
        try press(KeyCode.tab)
        fake.dead = [old]
        fake.replacement = new
        fake.before = "Hi to"
        fake.now += 0.5
        controller.textDidChange()
        XCTAssertEqual(fake.probes, [old])
        XCTAssertEqual(fake.tracked, new)
        XCTAssertEqual(controller.field.ghost?.text, " be")
        XCTAssertNotNil(controller.field.pendingUndo)

        fake.runScheduled()   // the retry reads the new handle
        XCTAssertEqual(fake.window.ghost, " be")
    }

    // A legitimate nil read (an IME composition) must not spend the probe for
    // a handle that answers again and is then replaced. Reads that keep
    // failing probe once a second; another handle is probed at once.
    func testDeadHandleProbeIsThrottledPerHandle() throws {
        let first = try XCTUnwrap(fake.tracked), second = FakeWorld.element(2)
        fake.before = "Hi "
        fake.readable = false
        controller.textDidChange()
        controller.textDidChange()
        XCTAssertEqual(fake.probes, [first], "a hung app pays once a second")

        fake.readable = true
        showGhost("there", on: "Hi ")
        try press(KeyCode.tab)
        fake.dead = [first]
        fake.replacement = second
        controller.textDidChange()
        XCTAssertEqual(fake.probes, [first, first], "it answered since")
        XCTAssertNotNil(controller.field.pendingUndo)

        fake.readable = false
        controller.textDidChange()
        XCTAssertEqual(fake.probes, [first, first, second], "a new handle")
        controller.textDidChange()
        fake.now += 1.1
        controller.textDidChange()
        XCTAssertEqual(fake.probes, [first, first, second, second])
    }

    // An app whose reads time out answers its probe slowly: even with reads
    // it answers in between — Electron alternating with timeouts — it pays
    // for one probe a second, on the main thread the key tap runs on.
    func testASlowAppIsProbedAtMostOnceASecond() throws {
        let handle = try XCTUnwrap(fake.tracked)
        fake.probeTakes = FieldState.fastProbe * 2
        fake.before = "Hi "
        fake.readable = false
        controller.textDidChange()
        fake.readable = true
        controller.textDidChange()
        fake.readable = false
        controller.textDidChange()
        XCTAssertEqual(fake.probes, [handle])
        fake.now += 1
        controller.textDidChange()
        XCTAssertEqual(fake.probes, [handle, handle])
    }

    // End to end with the real tracker: after the quiet re-latch, the app's
    // next focus notification for the same field is no focus change — the
    // ghost and ⌘Z survive it too.
    func testAQuietRelatchSurvivesTheNextFocusNotification() async throws {
        let app = FakeFocusApp(), old = FakeWorld.element(1), new = FakeWorld.element(2)
        app.fields = [(old, "Message"), (new, "Message")]
        app.focused = old
        let tracker = await trackRealFocus(app)
        XCTAssertEqual(controller.focusGeneration, 1)

        fake.engine.partials = ["to be"]
        showGhost("to be", on: "Hi ")
        try await finishQuery()   // its query streams the same ghost
        try press(KeyCode.tab)
        app.dead = [old]
        fake.dead = [old]
        app.focused = new
        fake.before = "Hi to"
        fake.now += 0.5
        controller.textDidChange()
        XCTAssertEqual(tracker.focusedTextElement, new)

        tracker.handleNotification(kAXFocusedUIElementChangedNotification, element: app.element)
        await settleMain()
        XCTAssertEqual(controller.focusGeneration, 1, "the same field")
        XCTAssertEqual(controller.field.ghost?.text, " be")
        XCTAssertNotNil(controller.field.pendingUndo)
    }
}
