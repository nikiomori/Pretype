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
    }

    // A shell prompt reads nil on every key: a terminal never pays for the
    // liveness probe. Elsewhere a nil read probes the handle.
    func testATerminalIsNeverProbed() async {
        await enterApp(terminal)
        fake.readable = false
        controller.textDidChange()
        XCTAssertEqual(fake.probes, [])

        await enterApp("com.apple.TextEdit")
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
