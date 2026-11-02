import AppKit
import XCTest
@testable import Pretype

/// The request gates on a real controller: what a field pass reads, where
/// it stops, what it asks the engine, and what of an answer stays up.
@MainActor
final class RequestPipelineTests: PipelineTestCase {
    private let terminal = "com.apple.Terminal"

    // MARK: - Before the read

    // A capture owns the overlay: a field event mid-capture (its own
    // injection, a selection change) neither hides the pill nor reads.
    func testAFieldEventDuringACaptureLeavesItsPill() async {
        await startHandsFreeCapture()
        let pill = fake.window.currentMode
        XCTAssertNotNil(pill)
        let reads = fake.reads
        fake.before = "Hi "
        controller.textDidChange()
        XCTAssertEqual(fake.window.currentMode, pill)
        XCTAssertEqual(fake.reads, reads)
        XCTAssertNil(controller.queries.current)
    }

    // An app or a site Pretype stays out of: everything goes, and "Last:" says
    // which.
    func testWhereSuggestionsAreOffItSaysSo() async {
        set(\.userBlacklist, ["com.example.notes"])
        await enterApp("com.example.notes")
        fake.before = "Hi "
        controller.textDidChange()
        XCTAssertEqual(controller.lastEvent, "suggestions are off in blacklisted apps")
        XCTAssertNil(controller.queries.current)
    }

    // A selection just typed over may still read as selected while the
    // edit settles: looked at again shortly, not offered a "fix" pill — and
    // once settled, a selection still there gets one.
    func testASettlingSelectionIsLookedAtAgain() throws {
        showGhost("to be", on: "Hi ")
        try press(KeyCode.tab)
        fake.selected = SelectionInfo(text: "Hi to", rect: nil)
        controller.textDidChange()
        XCTAssertNotEqual(fake.window.currentMode.map(Self.isShortcut), true)
        fake.advance(0.2)
        XCTAssertNotEqual(fake.window.currentMode.map(Self.isShortcut), true, "still settling")
        fake.advance(0.3)
        XCTAssertEqual(fake.window.currentMode.map(Self.isShortcut), true)
    }

    // A settle window with nothing selected reads the field as usual.
    func testASettleWithoutASelectionStillReads() throws {
        showGhost("to be", on: "Hi ")
        try press(KeyCode.tab)
        fake.before = "Hi to"
        let reads = fake.reads
        controller.textDidChange()
        XCTAssertEqual(fake.reads, reads + 1)
        XCTAssertEqual(fake.window.ghost, " be")
    }

    private static func isShortcut(_ mode: SuggestionDisplayMode) -> Bool {
        if case .shortcut = mode { return true }
        return false
    }

    // In a terminal a selection is screen output and the fix chord is off;
    // ⇥/⎋ are the terminal's, so no inline pill either: the pass reads and
    // asks for a completion.
    func testATerminalHasNoFixPills() async {
        await enterApp(terminal)
        fake.terminalField = true
        fake.selected = SelectionInfo(text: "some output", rect: nil)
        fake.before = "❯ 12*7="
        controller.textDidChange()
        XCTAssertNil(fake.window.currentMode)
        XCTAssertEqual(controller.queries.current?.kind, .completion(before: "❯ 12*7=", after: ""))
    }

    // In an agent's box the session's names complete at once, no model
    // asked: journaled as "names", taken whole with their space; the
    // session is read at the message's first word and kept after it.
    func testAnAgentsBoxCompletesTheSessionsNames() async throws {
        await enterApp(terminal)
        fake.terminalField = true
        fake.agentSession = "⏺ Updated Sources/Pretype/AgentPrompt.swift and SuggestionController."
        fake.before = "check Sugg"
        controller.textDidChange()
        XCTAssertEqual(fake.window.ghost, "estionController")
        XCTAssertNil(controller.queries.current, "no model asked")
        XCTAssertTrue(try press(KeyCode.tab))
        XCTAssertEqual(fake.keys, [.insert("estionController ")])
        XCTAssertEqual(controller.lastEvent, "accepted a name", "session text stays out of Diagnostics")
        controller.dismiss()
        XCTAssertEqual(fake.offers.last?.engine, "names")

        fake.advance(1)   // past the accept's settle
        fake.agentSession = nil   // read once per message: still kept
        fake.before = "and Sources/Pre"
        controller.textDidChange()
        XCTAssertEqual(fake.window.ghost, "type/AgentPrompt.swift", controller.lastEvent)
        fake.before = "and the tests"
        controller.textDidChange()
        XCTAssertEqual(controller.queries.current?.kind, .completion(before: "and the tests", after: ""))
        // The model reads the agent's turn ahead of the message, as a chat's OCR block.
        try await finishQuery()
        XCTAssertEqual(fake.engine.requests.last?.screenSummary,
                       "⏺ Updated Sources/Pretype/AgentPrompt.swift and SuggestionController.")
        await enterApp("com.apple.TextEdit")
        fake.terminalField = false
        XCTAssertNil(controller.promptContext.agentTurn, "the turn stays with its box")
    }

    // The reply chord in a terminal is ours on a read that found an agent's
    // box. An idle terminal posts nothing, so entering one, or clicking in
    // it, makes that read: the chord's first press must not reach the agent.
    func testTheReplyChordAnswersInAnIdleAgentBox() async throws {
        let chord: CGEventFlags = [.maskAlternate, .maskShift]
        set(\.repliesEnabled, true)
        await enterApp(terminal)
        fake.terminalField = true
        fake.agentSession = "⏺ Done."
        fake.advance(1)
        XCTAssertTrue(try press(KeyCode.tab, chord))

        controller.pointerPressed()
        XCTAssertNil(controller.field.cache)
        fake.advance(0.2)
        XCTAssertTrue(try press(KeyCode.tab, chord))
    }

    // A shell prompt has no agent: the chord stays the shell's.
    func testTheReplyChordPassesAtAShellPrompt() async throws {
        set(\.repliesEnabled, true)
        await enterApp(terminal)
        fake.terminalField = true
        fake.agentSession = nil
        fake.advance(1)
        XCTAssertFalse(try press(KeyCode.tab, [.maskAlternate, .maskShift]))
    }

    // Dots a query drew go with it when Words takes over and offers nothing.
    func testWordsTakingOverHidesAQuerysDots() {
        fake.window.show(mode: .thinking(2), at: CGRect(x: 10, y: 10, width: 1, height: 16))
        set(\.suggestionMode, .words)
        fake.before = "Hi there "
        controller.textDidChange()
        XCTAssertNil(fake.window.currentMode)
    }

    // A notice is not a query's: Words offering nothing leaves it up.
    func testWordsLeavesANoticeUp() {
        fake.window.show(mode: .hint("Undone"), at: CGRect(x: 10, y: 10, width: 1, height: 16))
        set(\.suggestionMode, .words)
        fake.before = "Hi there "
        controller.textDidChange()
        XCTAssertEqual(fake.window.currentMode, .hint("Undone"))
    }

    /// The app booked for each accepted chunk.
    private var acceptedApps: [String?] {
        fake.bookings.compactMap { if case .accepted(_, _, let app) = $0 { return .some(app) } else { return nil } }
    }

    // "Sou" with two paths: the ghost stops where they part, a partial name,
    // so ⇥ leaves no space for the next key to take back.
    func testAPartialNameTakesNoSpace() async throws {
        await enterApp(terminal)
        fake.terminalField = true
        fake.agentSession = "⏺ Sources/Pretype/Alpha.swift and Sources/Pretype/Beta.swift"
        fake.before = "see Sou"
        controller.textDidChange()
        XCTAssertEqual(fake.window.ghost, "rces/Pretype/")
        XCTAssertTrue(try press(KeyCode.tab))
        XCTAssertEqual(fake.keys, [.insert("rces/Pretype/")])
        XCTAssertNil(controller.provisionalSpace)
    }

    // A name's ghost cut short after it was shown ends at no word's end, as
    // one cut when first shown does: ⇥ types what is drawn, with no space.
    func testANameTrimmedWhileTypingTakesNoSpace() async throws {
        await enterApp(terminal)
        fake.terminalField = true
        fake.agentSession = "⏺ Updated SuggestionController."
        fake.before = "check Sugg"
        controller.textDidChange()
        XCTAssertEqual(fake.window.ghost, "estionController")
        fake.window.room = 5
        try type("e")
        XCTAssertEqual(controller.field.ghost?.text, "stion")
        XCTAssertTrue(try press(KeyCode.tab))
        XCTAssertEqual(fake.keys, [.insert("stion")])
        XCTAssertNil(controller.provisionalSpace)
    }

    // A name cut to the line is a partial too.
    func testANameTrimmedToTheLineTakesNoSpace() async throws {
        await enterApp(terminal)
        fake.terminalField = true
        fake.agentSession = "⏺ Updated SuggestionController"
        fake.before = "check Sugg"
        fake.window.room = 5
        controller.textDidChange()
        XCTAssertEqual(fake.window.ghost, "estio")
        XCTAssertTrue(try press(KeyCode.tab))
        XCTAssertEqual(fake.keys, [.insert("estio")])
    }

    // A name's offer goes on the app's record, so its accept must too, or a
    // terminal reads as unproductive; a word's goes on neither.
    func testANamesAcceptCountsForTheAppAndAWordsDoesNot() async throws {
        await enterApp(terminal)
        fake.terminalField = true
        fake.agentSession = "⏺ Updated SuggestionController."
        fake.before = "check Sugg"
        controller.textDidChange()
        XCTAssertTrue(try press(KeyCode.tab))
        XCTAssertEqual(acceptedApps, [terminal])

        set(\.suggestionMode, .words)
        fake.terminalField = false
        fake.advance(1)
        await enterApp("com.apple.TextEdit")
        fake.before = "see you tomo"
        controller.textDidChange()
        XCTAssertEqual(fake.window.ghost, "rrow", controller.lastEvent)
        XCTAssertTrue(try press(KeyCode.tab))
        XCTAssertEqual(acceptedApps, [terminal, nil])
    }

    // What the app books reaches the record `Stats.isUnproductive` reads: a
    // name's offer and its accept, side by side; nothing of a word.
    func testTheAppsRecordSeesANamesAcceptAndNoWord() async throws {
        let text = "com.apple.TextEdit"
        Stats.clearRecord(for: terminal)
        Stats.clearRecord(for: text)
        defer {
            Stats.clearRecord(for: terminal)
            Stats.clearRecord(for: text)
        }
        try await testANamesAcceptCountsForTheAppAndAWordsDoesNot()
        controller.dismiss()
        fake.bookings.forEach(SuggestionController.Environment.book)
        XCTAssertEqual(Stats.record(for: terminal)?.shown, 1)
        XCTAssertEqual(Stats.record(for: terminal)?.accepted, 1)
        XCTAssertNil(Stats.record(for: text))
    }

    // A query still running when a name lands is cancelled: its stale partial
    // would hide the ghost and leave ⇥ armed on nothing.
    func testANameCancelsTheQueryInFlight() async throws {
        await enterApp(terminal)
        fake.terminalField = true
        fake.agentSession = "⏺ Updated SuggestionController."
        fake.engine.holdsStreams = true
        fake.before = "check the"
        controller.textDidChange()
        let held = try XCTUnwrap(controller.queries.current?.task)
        while fake.engine.stream == nil { await Task.yield() }
        fake.before = "check the Sugg"
        controller.textDidChange()
        XCTAssertNil(controller.queries.current)
        XCTAssertEqual(fake.window.ghost, "estionController")
        fake.engine.stream?.yield(" stale")
        fake.engine.stream?.finish()
        await held.value
        XCTAssertEqual(fake.window.ghost, "estionController")
        XCTAssertEqual(controller.field.ghost?.text, "estionController")
    }

    // The field left and entered again: the agent's turn comes back with the
    // next read, mid-message, not with the next message.
    func testTheAgentsTurnSurvivesARefocus() async throws {
        await enterApp(terminal)
        fake.terminalField = true
        fake.agentSession = "⏺ Tests pass. Commit?"
        fake.before = "yes"
        controller.textDidChange()
        try await finishQuery()
        XCTAssertEqual(fake.engine.requests.last?.screenSummary, "⏺ Tests pass. Commit?")

        controller.focusTracker.onFocusChange?()
        fake.before = "yes and push"
        controller.textDidChange()
        try await finishQuery()
        XCTAssertEqual(fake.engine.requests.last?.screenSummary, "⏺ Tests pass. Commit?")
    }

    // A name is session text: its record keeps the counts, not the name —
    // shown, trimmed to the line, abandoned or taken — and ⌘Z books nothing.
    func testASessionsNameStaysOutOfTheJournal() async throws {
        let token = "sk-abcdefgh1234"
        await enterApp(terminal)
        fake.terminalField = true
        fake.agentSession = "⏺ The key is \(token) here"
        fake.window.room = 8
        fake.before = "use sk-a"
        controller.textDidChange()
        XCTAssertEqual(fake.window.ghost, "bcdefgh1")
        controller.dismiss()
        XCTAssertEqual(fake.offers.last?.engine, "names")
        XCTAssertEqual(fake.offers.last?.suggestion, "")
        XCTAssertEqual(fake.offers.last?.ctx, "use sk-a")
        XCTAssertEqual(fake.offers.last?.outcome, .abandoned)

        fake.window.room = nil
        fake.advance(1)
        controller.textDidChange()
        XCTAssertTrue(try press(KeyCode.tab))
        XCTAssertEqual(fake.offers.last?.outcome, .accepted)
        XCTAssertEqual(fake.offers.last?.suggestion, "")
        XCTAssertEqual(fake.offers.last?.acceptedChars, token.count - 4)

        fake.before = "use \(token) "
        XCTAssertTrue(try press(KeyCode.z, .maskCommand))
        fake.runHops()
        XCTAssertEqual(fake.keys.last, .delete("bcdefgh1234 ", perCharacter: true), "the ⌘Z went through")
        XCTAssertTrue(fake.undos.isEmpty)
        let log = DebugLog.shared.snapshot().map(\.message).joined(separator: "\n")
        XCTAssertFalse(log.contains("bcdefgh"), "the debug log is exportable")
    }

    // Words and fixes-only type on with no OCR and no retrieval.
    func testTypingSpendsNothingNobodyReads() async throws {
        set(\.screenContextEnabled, true)
        await enterApp("com.apple.TextEdit")
        fake.before = "see you at noon, then"
        fake.phrases = [SuggestionJournal.AcceptedPhrase(ctx: "see you", next: " soon")]
        for change in [{ self.set(\.suggestionMode, .words) },
                       { self.set(\.suggestionMode, .sentences); self.set(\.suggestionsEnabled, false) }] {
            change()
            controller.textDidChange()
            await settleMain()
            XCTAssertTrue(fake.captures.isEmpty)
            XCTAssertEqual(fake.phraseLookups, 0)
        }
        set(\.suggestionsEnabled, true)
        controller.textDidChange()
        let end = Date().addingTimeInterval(5)
        while fake.phraseLookups == 0, Date() < end { await Task.yield() }
        XCTAssertEqual(fake.phraseLookups, 1, "the guard's other side")
    }

    // A selection in a terminal inside an editor (Kelp) is screen output, as
    // in a terminal app: no fix pill, whatever the app's bundle says.
    func testASelectionInATerminalFieldGetsNoFixPill() async {
        await enterApp("dev.kelp.app")
        fake.terminalField = true
        fake.selected = SelectionInfo(text: "some output", rect: CGRect(x: 10, y: 10, width: 50, height: 16))
        fake.before = "❯ fix"
        controller.textDidChange()
        XCTAssertNil(fake.window.currentMode)
    }

    // A shell prompt reads nil on every key: a terminal — an app's, or one
    // inside an IDE (Kelp) — never pays for the liveness probe. Elsewhere a
    // nil read probes the handle.
    func testATerminalIsNeverProbed() async {
        await enterApp(terminal)
        fake.terminalField = true
        fake.readable = false
        controller.textDidChange()
        await enterApp("dev.kelp.app")
        controller.textDidChange()
        XCTAssertEqual(fake.probes, [])

        await enterApp("com.apple.TextEdit")
        fake.terminalField = false
        controller.textDidChange()
        XCTAssertEqual(fake.probes, [FakeWorld.element(1)])
    }

    // A node replaced under the caret is re-latched and read again shortly —
    // 90 ms on, once the new node is up.
    func testAReplacedNodeIsReadAgainShortly() throws {
        let old = try XCTUnwrap(fake.tracked)
        fake.dead = [old]
        fake.replacement = FakeWorld.element(2)
        fake.before = "Hi "
        controller.textDidChange()
        XCTAssertEqual(fake.reads, 0)
        fake.advance(0.08)
        XCTAssertEqual(fake.reads, 0)
        fake.advance(0.01)
        XCTAssertEqual(fake.reads, 1)
    }

    // Only the tracker's own handle is probed: a field the system reported
    // in its place is not the tracker's to re-latch.
    func testAnUntrackedFieldIsNeverProbed() {
        fake.tracked = nil
        fake.systemField = FakeWorld.element(5)
        fake.readable = false
        controller.textDidChange()
        XCTAssertEqual(fake.probes, [])
    }

    // A web or Electron field emptied reads as no field at all — the ghost
    // goes, and the handle is probed in case the node was replaced.
    func testAnEmptiedWebFieldReadsAsNone() {
        fake.emptyReadsNil = true
        showGhost("to be", on: "Hi ")
        fake.before = ""
        controller.textDidChange()
        XCTAssertNil(controller.field.ghost)
        XCTAssertEqual(controller.lastEvent, "lost text element")
        XCTAssertEqual(fake.probes, [FakeWorld.element(1)])
    }

    // MARK: - After the read

    // Where suggestions go unused: no query, said in "Last:". A fix still
    // runs there, and a ghost already up still narrows as the user types.
    func testAnAppWhoseSuggestionsGoUnusedStillGetsFixes() async throws {
        await enterApp("com.example.quiet")
        showGhost("to be", on: "Hi ")
        fake.unproductive = ["com.example.quiet"]
        fake.before = "Hi t"
        try type("t")
        controller.textDidChange()
        XCTAssertEqual(fake.window.ghost, "o be")

        controller.dismiss()
        fake.before = "Hi to "
        controller.textDidChange()
        XCTAssertNil(controller.queries.current)
        XCTAssertEqual(controller.lastEvent, "quiet in this app — suggestions here are almost never taken")
        fake.before = "Hi 12*7="
        controller.textDidChange()
        XCTAssertEqual(fake.window.currentMode, .correction(original: "12*7=", fix: "12*7=84"))
    }

    // The same app gone quiet is not screenshotted, nor searched for examples:
    // the warm-up after them no-ops there.
    func testAnAppGoneQuietIsNotRead() async {
        set(\.screenContextEnabled, true)
        await enterApp("com.example.quiet")
        fake.unproductive = ["com.example.quiet"]
        fake.before = "Hello there, this is "
        controller.textDidChange()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(fake.captures, [])
        XCTAssertEqual(fake.phraseLookups, 0)
    }

    // A fix pill taking the overlay ends the pass: no completion is asked
    // for over it.
    func testAFixPillEndsThePass() {
        fake.before = "Hi 12*7="
        controller.textDidChange()
        XCTAssertEqual(fake.window.currentMode, .correction(original: "12*7=", fix: "12*7=84"))
        XCTAssertNil(controller.queries.current)
    }

    // On battery with the pause on: quiet the same way.
    func testOnBatteryNothingIsAsked() {
        set(\.pauseOnBattery, true)
        fake.pausedForBattery = true
        fake.before = "Hi "
        controller.textDidChange()
        XCTAssertNil(controller.queries.current)
        XCTAssertEqual(controller.lastEvent, "paused on battery")
    }

    // Typing retries a failed load — the engine's own retry lives in the
    // query it can't reach — and, still failed, says so at the caret. A load
    // the retry restarted lets the keystroke query like any other.
    func testTypingRetriesAFailedLoad() {
        fake.engine.state = .failed("no model")
        fake.before = "Hi "
        controller.textDidChange()
        XCTAssertEqual(fake.engine.prewarms, 1)
        XCTAssertNil(controller.queries.current)
        XCTAssertEqual(controller.lastEvent, "engine failed: no model")
        XCTAssertEqual(fake.window.currentMode, .error("engine not working"))

        fake.engine.prewarmRecovers = true
        controller.textDidChange()
        XCTAssertEqual(fake.engine.prewarms, 2)
        XCTAssertEqual(controller.queries.current?.kind, .completion(before: "Hi ", after: ""))
    }

    // A ready engine is not woken by typing.
    func testAReadyEngineIsNotRetried() {
        fake.before = "Hi "
        controller.textDidChange()
        XCTAssertEqual(fake.engine.prewarms, 0)
    }

    // MARK: - The n-gram

    private func learnPhrase() {
        set(\.personalizationLevel, .on)
        for _ in 0..<3 { fake.ngram.learn("thanks for the quick reply") }
    }

    // The user's own phrase shows at once, before the model answers — and
    // stays up when the model abstains: a confident personal phrase beats
    // showing nothing. It is journaled as the n-gram's.
    func testAnInstantGhostOutlivesTheModelsAbstain() async throws {
        learnPhrase()
        fake.before = "thanks for the quick "
        controller.textDidChange()
        XCTAssertEqual(fake.window.ghost, "reply")
        XCTAssertEqual(controller.field.ghost?.isInstant, true)
        try await finishQuery()
        XCTAssertEqual(fake.window.ghost, "reply")
        XCTAssertEqual(controller.lastResultDescription, "reply")
        controller.dismiss()
        XCTAssertEqual(fake.offers.last?.engine, "ngram")
        XCTAssertNil(fake.offers.last?.model)
    }

    // The model's answer supersedes it through the same path.
    func testTheModelSupersedesTheInstantGhost() async throws {
        learnPhrase()
        fake.engine.partials = ["reply soon"]
        fake.before = "thanks for the quick "
        controller.textDidChange()
        try await finishQuery()
        XCTAssertEqual(fake.window.ghost, "reply soon")
        XCTAssertEqual(controller.field.ghost?.isInstant, false)
        XCTAssertEqual(fake.offers.map(\.engine), ["ngram"], "the instant offer was superseded")
        XCTAssertEqual(fake.offers.first?.outcome, .superseded)
    }

    // Personalization off: the n-gram offers nothing.
    func testWithPersonalizationOffTheNgramOffersNothing() async throws {
        for _ in 0..<3 { fake.ngram.learn("thanks for the quick reply") }
        fake.before = "thanks for the quick "
        controller.textDidChange()
        XCTAssertNil(fake.window.ghost)
        XCTAssertNil(controller.field.ghost)
    }

    // MARK: - An answer landing

    // A whole new word fused onto the half-typed one is retired, not shown.
    func testAGluedAnswerIsRetired() {
        fake.before = "the quick bro"
        controller.textDidChange()
        XCTAssertFalse(controller.apply("fox", requestText: "the quick bro"))
        XCTAssertNil(fake.window.ghost)
        XCTAssertNil(controller.field.ghost)
        XCTAssertEqual(controller.lastEvent, "dropped mid-word glue suggestion")
    }

    // An empty answer is an abstain — or a stream's retract: the ghost the
    // partials showed goes, and can't be accepted hidden.
    func testAnEmptyAnswerRetiresTheGhost() throws {
        showGhost("to be", on: "Hi ")
        XCTAssertFalse(controller.apply("  ", requestText: "Hi "))
        XCTAssertNil(controller.field.ghost)
        XCTAssertNil(fake.window.ghost)
        XCTAssertEqual(controller.lastEvent, "engine returned no suggestion")
        XCTAssertFalse(try press(KeyCode.tab))
    }

    // Paused while the engine thought: nothing lands.
    func testNothingLandsWhilePaused() {
        fake.before = "Hi "
        controller.textDidChange()
        set(\.enabled, false)
        XCTAssertFalse(controller.apply("there", requestText: "Hi "))
        XCTAssertNil(fake.window.ghost)
    }
}
