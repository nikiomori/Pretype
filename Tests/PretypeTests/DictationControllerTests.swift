import AVFoundation
import CoreGraphics
import XCTest
@testable import Pretype

/// A wait the test ends by hand, where a sleep would race whatever the test
/// does meanwhile — and a loaded runner loses that race. A cancelled wait ends
/// early, as `Task.sleep` would.
private final class Gate: Sendable {
    private let stream: AsyncStream<Never>
    private let continuation: AsyncStream<Never>.Continuation

    init() { (stream, continuation) = AsyncStream.makeStream() }

    func open() { continuation.finish() }
    func wait() async { for await _ in stream {} }
}

/// A transcription session driven by the test instead of a microphone: partials
/// are pushed by hand, `finish` returns a scripted transcript once its gate is
/// open, and every `cancel` is counted.
private final class ScriptedSession: TranscriptionSession, @unchecked Sendable {
    var audioFormat: AVAudioFormat?
    var transcript = "hello world"
    /// Set: `finish` waits for it, so `.working` lasts exactly as long as the
    /// test needs. Never opened, it is a hung finalize.
    var finishGate: Gate?
    /// The hang shrugs off task cancellation — the shape of a genuinely
    /// deadlocked finalize, which the watchdog must abandon rather than await.
    var finishIgnoresCancellation = false
    /// Thrown by `finish` in place of a transcript: the final pass failed.
    var finishError: Error?
    /// Set: a speech API's take, kept for the on-device fallback.
    var unsentAudio: [Float]?
    /// The gated `finish` is under way, and then was cancelled mid-wait —
    /// an upload in flight, stopped.
    let finishStarted = LockedValue(false)
    let finishCancelled = LockedValue(false)
    var onPartial: (@Sendable (String) -> Void)?
    private(set) var cancelCount = 0

    func feed(_ buffer: AVAudioPCMBuffer) {}

    func finish() async throws -> String {
        finishStarted.set(true)
        if let finishGate {
            if finishIgnoresCancellation {
                // An unstructured task is not cancelled with its awaiter.
                await Task { await finishGate.wait() }.value
            } else {
                await finishGate.wait()
                if Task.isCancelled { finishCancelled.set(true) }
                try Task.checkCancellation()
            }
        }
        if let finishError { throw finishError }
        return transcript
    }

    func cancel() { cancelCount += 1 }
}

/// Counts starts and stops, and hands the device-change callback back to the
/// test so it can pull the microphone out from under a capture on cue.
@MainActor
private final class FakeAudioCapture: AudioCapturing {
    var failStart = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var onDeviceChange: (@Sendable () -> Void)?
    private(set) var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?

    func start(
        deviceUID: String?,
        outputFormat: AVAudioFormat?,
        onDeviceChange: @escaping @Sendable () -> Void,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) async throws {
        if failStart { throw AudioCapture.Failure.noInputDevice }
        startCount += 1
        self.onDeviceChange = onDeviceChange
        self.onBuffer = onBuffer
    }

    func stop() { stopCount += 1 }
}

/// Records everything the controller asks of its host: overlays shown,
/// transients flashed, transcripts inserted.
@MainActor
private final class MockDictationHost: DictationHost {
    private(set) var lastEvent = ""
    func report(_ event: String) { lastEvent = event }
    var typingContext = TypingContext()
    var focusGeneration = 0
    var focusIsInLauncher = false
    var isOwnUIFrontmost = false
    var isSecureInputActive = false
    var fallbackCaretRect: CGRect?
    var fallbackHostStyle = HostTextStyle()

    var focus = DictationFocus.field
    var composing = false
    var anchor: DictationAnchor? = DictationAnchor(
        caretRect: CGRect(x: 10, y: 10, width: 1, height: 18),
        host: HostTextStyle(), textBeforeCaret: "")
    private(set) var inserted: [String] = []
    private(set) var rescued: [String] = []
    private(set) var transientNotices: [SuggestionDisplayMode] = []
    private(set) var shownModes: [SuggestionDisplayMode] = []
    private(set) var hideCount = 0
    private(set) var prepares = 0
    var tidy: ((String) -> String?)?
    /// Set: the tidy-up waits for it — never opened, a model that never answers.
    var tidyGate: Gate?

    func dictationFocus() -> DictationFocus { focus }
    func isComposingInFocusedField() -> Bool { composing }
    func prepareForDictation() { prepares += 1 }
    private(set) var prewarms = 0
    func prewarmTidy() { prewarms += 1 }
    func dictationBusyChanged() {}
    func dictationAnchor() -> DictationAnchor? { anchor }
    func noteCaret(rect: CGRect, host: HostTextStyle) {}
    func showOverlay(_ mode: SuggestionDisplayMode, at rect: CGRect, host: HostTextStyle) {
        shownModes.append(mode)
    }
    func showTransientOverlay(_ mode: SuggestionDisplayMode, at rect: CGRect, host: HostTextStyle) {
        transientNotices.append(mode)
    }
    func hideOverlay() { hideCount += 1 }
    func insertDictated(_ text: String) { inserted.append(text) }
    private(set) var rescueReasons: [DictationRescue] = []
    func rescueDictated(_ text: String, because reason: DictationRescue) {
        rescued.append(text)
        rescueReasons.append(reason)
    }
    private(set) var commands: [(instruction: String, selection: String)] = []
    func applyVoiceCommand(_ instruction: String, to selection: String) {
        commands.append((instruction, selection))
    }
    func tidyDictation(_ text: String) async -> String? {
        await tidyGate?.wait()
        return tidy?(text)
    }
}

/// The dictation state machine end to end, with every environment dependency
/// faked: no microphone, no AX tree, no Speech framework, no frontmost app.
/// What is pinned here is the part that has to be right — which transcripts
/// land, which are dropped, and that nothing wedges in `.working`.
@MainActor
final class DictationControllerTests: XCTestCase {
    private var savedEnabled = false
    private var savedDictation = false
    private var savedGesture = DictationGesture.option
    private var savedPolish = false
    private var savedLatch = DictationLatch.off
    private var savedSilence: TimeInterval = 0

    override func setUp() {
        super.setUp()
        savedEnabled = Settings.enabled
        savedDictation = Settings.dictationEnabled
        savedGesture = Settings.dictationGesture
        savedPolish = Settings.dictationPolish
        savedLatch = Settings.dictationLatch
        savedSilence = Settings.dictationSilence
        Settings.enabled = true
        Settings.dictationEnabled = true
        Settings.dictationGesture = .option
        Settings.dictationPolish = false
        Settings.dictationCommands = false
        Settings.dictationLatch = .controlOptionD
        // Off unless a test asks for it: the silence clock is wall time unless
        // a test steps it (`stepClock`), and a default budget ticking under
        // every latch test would end captures the test believes it still owns.
        Settings.dictationSilence = 0
    }

    override func tearDown() {
        Settings.enabled = savedEnabled
        Settings.dictationEnabled = savedDictation
        Settings.dictationGesture = savedGesture
        Settings.dictationPolish = savedPolish
        Settings.dictationLatch = savedLatch
        Settings.dictationSilence = savedSilence
        super.tearDown()
    }

    // MARK: - Rig

    private struct Rig {
        let controller: DictationController
        let host: MockDictationHost
        let capture: FakeAudioCapture
        let session: ScriptedSession
    }

    private func makeRig(configure: (ScriptedSession) -> Void = { _ in }) -> Rig {
        let session = ScriptedSession()
        configure(session)
        let capture = FakeAudioCapture()
        let controller = DictationController(capture: capture)
        let host = MockDictationHost()
        controller.owner = host
        controller.hold.threshold = 0
        controller.gates.micBundled = { true }
        controller.gates.micStatus = { .authorized }
        controller.gates.transcriptionSupported = { true }
        controller.gates.startSession = { _, onPartial in
            session.onPartial = onPartial
            return session
        }
        return Rig(controller: controller, host: host, capture: capture, session: session)
    }

    /// A `.flagsChanged`-shaped event: `modifierChanged` only reads the keycode
    /// field and the flags, so a keyboard event carrying them is enough. ⌥ —
    /// the dictation gesture — unless told otherwise.
    private func modifierEvent(key: Int64 = KeyCode.leftOption, flag: CGEventFlags = .maskAlternate,
                               down: Bool) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: down)!
        event.flags = down ? flag : []
        return event
    }

    /// Pump until `condition` holds. A fixed margin that holds locally loses
    /// by an order of magnitude on a loaded CI runner — each `Task { @MainActor }`
    /// hop can take longer there than a whole 0.1 s pump window — so waits on
    /// the controller's async paths are stated as the condition they wait FOR.
    /// The deadline only bounds a genuine wedge: the assertions right after
    /// still run, and name the wedged state. It is generous because a passing
    /// run never reaches it — the wait ends the moment the condition holds.
    private func pump(until condition: () -> Bool, timeout: TimeInterval = 10) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
            await Task.yield()
        }
    }

    /// A gate opened at teardown if the test never did, so no task outlives
    /// its test parked on one.
    private func makeGate() -> Gate {
        let gate = Gate()
        addTeardownBlock { gate.open() }
        return gate
    }

    /// Press the dictation key and fire the arm timer by hand. The rig's
    /// threshold is zero, so the hold goes live right there — `begin` has run
    /// by the time this returns, with no timer left for a loaded runner to
    /// fire late. A press the controller never armed (under a latch) has no
    /// timer to fire.
    private func holdDown(_ controller: DictationController) {
        controller.modifierChanged(modifierEvent(down: true))
        controller.armTimer?.fire()
    }

    /// The key-up is applied synchronously (`modifierChanged`), so there is
    /// nothing to wait for.
    private func release(_ controller: DictationController) {
        controller.modifierChanged(modifierEvent(down: false))
    }

    /// Hold the key and wait until the capture is actually LIVE: `begin`
    /// crosses two awaits before `.listening`, and a partial poked (or a
    /// release applied) before they land exercises a different path than the
    /// one the test is about.
    private func startCapture(_ rig: Rig) async {
        holdDown(rig.controller)
        await pump(until: { rig.controller.phase == .listening("") })
    }

    /// Hold the capture in `.preparing` until the test opens the returned
    /// gate — a Bluetooth microphone spends seconds there and a first-use
    /// language pack minutes. A discard that cancels the start ends the wait.
    private func gatedStart(_ rig: Rig) -> Gate {
        let gate = makeGate()
        let session = rig.session
        rig.controller.gates.startSession = { _, onPartial in
            await gate.wait()
            try Task.checkCancellation()
            session.onPartial = onPartial
            return session
        }
        return gate
    }

    /// Park the write-down until the test opens the returned gate — on a
    /// hosted API, `.working` is the whole upload.
    private func holdFinish(_ rig: Rig) -> Gate {
        let gate = makeGate()
        rig.session.finishGate = gate
        return gate
    }

    /// Put the controller on a clock the test steps by hand: a silence budget
    /// is crossed by moving it, not by sleeping through it.
    private func stepClock(_ rig: Rig) -> LockedValue<Date> {
        let now = LockedValue(Date())
        rig.controller.clock = { now.get() }
        return now
    }

    /// Push a partial and wait until the controller has heard it.
    private func hear(_ text: String, in rig: Rig) async {
        rig.session.onPartial?(text)
        await pump(until: { rig.controller.phase == .listening(text) })
    }

    // MARK: - Tests

    func testCaptureToInsertion() async {
        let rig = makeRig()
        await startCapture(rig)
        XCTAssertEqual(rig.controller.phase, .listening(""))
        XCTAssertEqual(rig.capture.startCount, 1)
        XCTAssertEqual(rig.host.prewarms, 0, "polish off: nothing to load")
        await hear("say someth", in: rig)
        XCTAssertEqual(rig.controller.phase, .listening("say someth"))
        release(rig.controller)
        await pump(until: { !rig.host.inserted.isEmpty })
        XCTAssertEqual(rig.host.inserted, ["hello world"])
        XCTAssertEqual(rig.controller.phase, .idle)
        XCTAssertGreaterThanOrEqual(rig.capture.stopCount, 1)
    }

    /// A field that publishes no caret must still SHOW that it is listening.
    /// Web and Electron inputs report none before their first keystroke — and
    /// again once the app replaces the focused node, which typing a transcript
    /// into one does — so this is the ordinary case for a second dictation, not
    /// an exotic one. It recorded fine and drew nothing at all.
    func testListeningPillSurvivesACaretlessField() async {
        let rig = makeRig()
        rig.host.anchor = nil
        rig.host.fallbackCaretRect = CGRect(x: 40, y: 60, width: 1, height: 18)
        await startCapture(rig)
        XCTAssertEqual(rig.controller.phase, .listening(""))
        XCTAssertTrue(rig.host.shownModes.contains { if case .listening = $0 { return true }
                                                     return false },
                      "a capture with no readable caret still has to look like one")
        await hear("слышу", in: rig)
        guard case .listening(let text)? = rig.host.shownModes.last else {
            return XCTFail("partials must keep repainting the pill")
        }
        XCTAssertEqual(text, "слышу")
    }

    func testFocusChangeDropsTranscript() async {
        let rig = makeRig()
        await startCapture(rig)
        await hear("meant for the other field", in: rig)
        // Only the generation guard is under test here — the live app also
        // calls `invalidate()` on a real focus change.
        rig.host.focusGeneration += 1
        release(rig.controller)
        await pump(until: { rig.controller.phase == .idle })
        XCTAssertTrue(rig.host.inserted.isEmpty)
        XCTAssertEqual(rig.controller.phase, .idle)
    }

    /// Release-then-keep-typing: the finished sentence can't be typed at a
    /// caret that has moved, and must not be thrown away over one keystroke
    /// either — on a hosted API `.working` is the whole upload.
    func testKeystrokeDuringFinalizeRescuesToTheClipboard() async {
        let rig = makeRig()
        let writing = holdFinish(rig)
        await startCapture(rig)
        await hear("about to move", in: rig)
        release(rig.controller)
        XCTAssertEqual(rig.controller.phase, .working)
        rig.controller.keyPressed()
        XCTAssertEqual(rig.controller.phase, .working, "a keystroke no longer drops the take")
        writing.open()
        await pump(until: { !rig.host.rescued.isEmpty })
        XCTAssertEqual(rig.host.rescued, ["hello world"])
        XCTAssertTrue(rig.host.inserted.isEmpty, "the caret moved — the transcript must not follow it")
    }

    /// A voice command has nothing to rescue — its selection is what moved —
    /// so a keystroke mid-write still drops it, with the notice.
    func testKeystrokeDuringAVoiceCommandStillDropsIt() async {
        Settings.dictationCommands = true
        defer { Settings.dictationCommands = false }
        let rig = makeRig()
        let writing = holdFinish(rig)
        rig.host.anchor?.selectedText = "the draft paragraph"
        await startCapture(rig)
        await hear("make it shorter", in: rig)
        release(rig.controller)
        let write = rig.controller.sessionTask
        rig.controller.keyPressed()
        XCTAssertEqual(rig.controller.phase, .idle)
        guard case .hint(let notice)? = rig.host.transientNotices.last else {
            return XCTFail("a silently vanished command reads as a broken feature")
        }
        XCTAssertTrue(notice.contains("kept typing"), notice)
        // The transcript still arrives — and finds the command already dropped.
        writing.open()
        await write?.value
        XCTAssertTrue(rig.host.commands.isEmpty)
        XCTAssertTrue(rig.host.rescued.isEmpty)
    }

    func testSecondHoldQueuesBehindFinalize() async {
        let rig = makeRig()
        let writing = holdFinish(rig)
        await startCapture(rig)
        await hear("first sentence", in: rig)
        release(rig.controller)
        XCTAssertEqual(rig.controller.phase, .working)
        // Second hold while the first transcript is still being written down:
        // queued, not started — and NOT silently dropped either way.
        holdDown(rig.controller)
        XCTAssertEqual(rig.controller.phase, .working)
        XCTAssertEqual(rig.capture.startCount, 1)
        writing.open()
        await pump(until: { rig.capture.startCount == 2 })
        XCTAssertEqual(rig.host.inserted, ["hello world"])
        XCTAssertTrue(rig.controller.isCapturing, "the queued hold must start once the insert lands")
        XCTAssertEqual(rig.capture.startCount, 2)
    }

    /// A hold queued behind the write that another modifier joins (⌥ held,
    /// then ⇧) was a chord: only the queued hold goes. The take being written
    /// down still lands — a modifier moves no caret.
    func testAChordOnAQueuedHoldLeavesTheTakeBeingWritten() async {
        let rig = makeRig()
        let writing = holdFinish(rig)
        await startCapture(rig)
        await hear("first sentence", in: rig)
        release(rig.controller)
        holdDown(rig.controller)
        XCTAssertTrue(rig.controller.hold.isActive, "queued behind the write")
        rig.controller.modifierChanged(modifierEvent(key: KeyCode.leftShift,
                                                     flag: [.maskAlternate, .maskShift], down: true))
        XCTAssertEqual(rig.controller.phase, .working, "the chord must not drop the take")
        writing.open()
        await pump(until: { !rig.host.inserted.isEmpty })
        XCTAssertEqual(rig.host.inserted, ["hello world"])
        XCTAssertEqual(rig.capture.startCount, 1, "the chord never opens a microphone")
        XCTAssertTrue(rig.host.transientNotices.isEmpty, "\(rig.host.transientNotices)")
    }

    func testDeviceChangeWithoutPinnedFormatFinishes() async {
        let rig = makeRig()  // audioFormat nil: restart-in-place is unsound
        await startCapture(rig)
        await hear("already heard", in: rig)
        rig.capture.onDeviceChange?()
        await pump(until: { !rig.host.inserted.isEmpty })
        XCTAssertEqual(rig.host.inserted, ["hello world"],
                       "words already heard must be typed, not thrown away")
        XCTAssertEqual(rig.controller.phase, .idle)
    }

    func testDeviceLossHeardNothingFails() async {
        let rig = makeRig()
        await startCapture(rig)
        rig.capture.onDeviceChange?()
        await pump(until: { rig.controller.phase == .idle })
        XCTAssertTrue(rig.host.inserted.isEmpty)
        XCTAssertEqual(rig.controller.phase, .idle)
        guard case .error? = rig.host.transientNotices.last else {
            return XCTFail("device loss with nothing heard should surface an error")
        }
    }

    func testDeviceChangeWithPinnedFormatRestartsInPlace() async {
        let rig = makeRig {
            $0.audioFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)
        }
        await startCapture(rig)
        await hear("keep going", in: rig)
        rig.capture.onDeviceChange?()
        await pump(until: { rig.capture.startCount == 2 })
        XCTAssertEqual(rig.capture.startCount, 2, "AirPods arriving is a hiccup, not an ending")
        XCTAssertTrue(rig.controller.isCapturing)
        XCTAssertTrue(rig.host.inserted.isEmpty)
    }

    /// Selecting an input device reconfigures the engine, and a reconfiguration
    /// is itself reported as a device change — which restarts the tap, which
    /// reconfigures again. Measured in the wild as dozens of restarts a second,
    /// a transcript that never accumulated any audio, and a Bluetooth headset
    /// whose volume came back wrong from flipping profile on every cycle.
    /// The capture must end rather than keep restarting.
    func testRunawayDeviceChangesEndTheCapture() async {
        let rig = makeRig {
            $0.audioFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)
        }
        await startCapture(rig)
        await hear("что-то услышал", in: rig)
        // Poke-and-confirm, not a blind burst: the fake only holds the LATEST
        // restart's callback, so a poke that lands before the previous restart
        // was processed replays a stale epoch and is (correctly) dropped —
        // which would test the epoch guard, not the circuit breaker.
        var pokes = 0
        while rig.controller.isCapturing, pokes < 12 {
            pokes += 1
            let started = rig.capture.startCount
            rig.capture.onDeviceChange?()
            await pump(until: { rig.capture.startCount > started || !rig.controller.isCapturing },
                       timeout: 1)
        }
        await pump(until: { rig.controller.phase == .idle })
        XCTAssertEqual(rig.capture.startCount, 4,
                       "one open and three restarts, then the capture ends")
        XCTAssertEqual(rig.controller.phase, .idle)
        XCTAssertEqual(rig.host.inserted, ["hello world"],
                       "what was already heard is still typed")
    }

    /// Released while the start is only opening the microphone (no language
    /// pack downloading): the start is cancelled outright — so a second press
    /// can't race it — and the notice says what actually happened.
    func testReleaseDuringMicOpenCancelsTheStart() async {
        let rig = makeRig()
        // Never opened: only a cancel ends this wait — one left running would
        // sit on the gate until teardown.
        let opening = makeGate()
        let cancelled = LockedValue<Bool?>(nil)
        rig.controller.gates.startSession = { _, _ in
            await opening.wait()
            cancelled.set(Task.isCancelled)
            throw CancellationError()
        }
        holdDown(rig.controller)
        XCTAssertEqual(rig.controller.phase, .preparing)
        release(rig.controller)
        XCTAssertEqual(rig.controller.phase, .idle)
        guard case .hint(let notice)? = rig.host.transientNotices.last else {
            return XCTFail("a release during the mic open should say so")
        }
        XCTAssertTrue(notice.contains("microphone"),
                      "no download is running — 'getting the model ready' would be a lie: \(notice)")
        await pump(until: { cancelled.get() != nil })
        XCTAssertEqual(cancelled.get(), true, "the start must be cancelled, not left to race the next press")
        XCTAssertEqual(rig.capture.startCount, 0)
    }

    /// Released mid language-pack download: the start is left running (the
    /// next press would otherwise download again), and the session it
    /// produces belongs to a discarded capture, so it dies on arrival.
    func testReleaseDuringDownloadKeepsTheStartAndCancelsSessionOnArrival() async {
        let rig = makeRig()
        let session = rig.session
        let opening = gatedStart(rig)
        holdDown(rig.controller)
        XCTAssertEqual(rig.controller.phase, .preparing)
        Transcription.downloading.set(.languagePack)
        defer { Transcription.downloading.set(nil) }
        release(rig.controller)
        XCTAssertEqual(rig.controller.phase, .idle)
        guard case .hint(let notice)? = rig.host.transientNotices.last else {
            return XCTFail("a release mid-download should say so")
        }
        XCTAssertTrue(notice.contains("getting the dictation model ready"), notice)
        // The download lands: a start that had been cancelled would produce no
        // session at all.
        opening.open()
        await pump(until: { session.cancelCount == 1 })
        XCTAssertEqual(session.cancelCount, 1)
        XCTAssertEqual(rig.capture.startCount, 0)
    }

    /// Parakeet's 610 MB download (the Settings toggle's prefetch, say) holds
    /// up only the captures Parakeet would serve. One global flag refused
    /// every capture for the length of it — Apple's model and a hosted API
    /// included, neither of which touches Parakeet.
    func testParakeetsDownloadHoldsUpOnlyParakeetCaptures() async {
        let saved = (Settings.dictationParakeet, Settings.dictationLanguage)
        Settings.dictationLanguage = "ru"
        Transcription.downloading.set(.parakeet)
        defer {
            Transcription.downloading.set(nil)
            (Settings.dictationParakeet, Settings.dictationLanguage) = saved
        }
        Settings.dictationParakeet = false
        let other = makeRig()
        await startCapture(other)
        XCTAssertEqual(other.controller.phase, .listening(""), "this capture never touches Parakeet")

        Settings.dictationParakeet = true
        let waits = makeRig()
        holdDown(waits.controller)
        XCTAssertEqual(waits.controller.phase, .idle)
        guard case .hint(let notice)? = waits.host.transientNotices.last else {
            return XCTFail("a capture waiting on its own model's download should say so")
        }
        XCTAssertTrue(notice.contains("getting the dictation model ready"), notice)
    }

    // Our own Settings window in front: the field the hold would type into
    // is the tracked one behind it, and the keys go to Settings.
    func testOurOwnWindowRefusesBeforeOpeningMic() {
        let rig = makeRig()
        rig.host.isOwnUIFrontmost = true
        holdDown(rig.controller)
        XCTAssertEqual(rig.controller.phase, .idle)
        XCTAssertEqual(rig.capture.startCount, 0)
        XCTAssertEqual(rig.host.lastEvent, "dictation: our own window is frontmost")
    }

    func testSecureInputRefusesBeforeOpeningMic() {
        let rig = makeRig()
        rig.host.isSecureInputActive = true
        holdDown(rig.controller)
        XCTAssertEqual(rig.controller.phase, .idle)
        XCTAssertEqual(rig.capture.startCount, 0)
        guard case .hint? = rig.host.transientNotices.last else {
            return XCTFail("secure input should refuse with a visible hint")
        }
    }

    func testPolishPastBudgetFallsBackToRawTranscript() async {
        Settings.dictationPolish = true
        let rig = makeRig()
        rig.controller.polishSeconds = 0.05
        rig.host.tidy = { _ in "Polished." }
        rig.host.tidyGate = makeGate()
        await startCapture(rig)
        await hear("x", in: rig)
        release(rig.controller)
        await pump(until: { !rig.host.inserted.isEmpty })
        XCTAssertEqual(rig.host.inserted, ["hello world"],
                       "a slow tidy-up must not hold the sentence hostage")
    }

    func testPolishAppliesWithinBudget() async {
        Settings.dictationPolish = true
        let rig = makeRig()
        rig.host.tidy = { _ in "Hello, world." }
        await startCapture(rig)
        XCTAssertEqual(rig.host.prewarms, 1, "the tidy-up model loads while the user speaks")
        await hear("x", in: rig)
        release(rig.controller)
        await pump(until: { !rig.host.inserted.isEmpty })
        XCTAssertEqual(rig.host.inserted, ["Hello, world."])
    }

    func testEscapeDuringFinalizeSaysCancelled() async {
        let rig = makeRig()
        _ = holdFinish(rig)
        await startCapture(rig)
        await hear("never mind", in: rig)
        release(rig.controller)
        XCTAssertEqual(rig.controller.phase, .working)
        rig.controller.keyPressed(isEscape: true)
        guard case .hint(let notice)? = rig.host.transientNotices.last else {
            return XCTFail("escape should still show a notice")
        }
        XCTAssertTrue(notice.contains("cancelled"),
                      "a deliberate ⎋ must not be answered with 'you kept typing': \(notice)")
    }

    func testMicFailureCancelsFreshSession() async {
        let rig = makeRig()
        rig.capture.failStart = true
        holdDown(rig.controller)
        // The condition is the cancel, not `.idle`: the phase is also `.idle`
        // BEFORE the arm timer fires, so waiting on it could return early with
        // the whole begin-and-fail chain still queued.
        await pump(until: { rig.session.cancelCount == 1 })
        XCTAssertEqual(rig.controller.phase, .idle)
        XCTAssertEqual(rig.session.cancelCount, 1,
                       "a session started before the microphone failed must not leak")
        guard case .error? = rig.host.transientNotices.last else {
            return XCTFail("a dead microphone should surface an error")
        }
    }

    func testHungFinalizeTripsWatchdog() async {
        let rig = makeRig()
        _ = holdFinish(rig)  // never opened: only the watchdog can end it
        rig.controller.finalizeSeconds = 0.1
        await startCapture(rig)
        await hear("x", in: rig)
        release(rig.controller)
        await pump(until: { rig.controller.phase == .idle })
        XCTAssertEqual(rig.controller.phase, .idle, "a hung finalize must not wedge the pill")
        XCTAssertTrue(rig.host.inserted.isEmpty)
        // What the pill last showed is all that's left of the take: kept.
        XCTAssertEqual(rig.host.rescued, ["x"], "a timed-out take must leave its preview on the clipboard")
        XCTAssertEqual(rig.host.rescueReasons, [.timedOut])
    }

    /// The same for a final pass that fails outright — Parakeet erroring, a
    /// local server gone mid-take. Its preview is nearly the whole take, and
    /// an error notice in its place threw minutes of speech away.
    func testAFailedFinalPassRescuesThePreview() async {
        let failure = AudioCapture.Failure.sessionFailed("the server went away")
        let rig = makeRig { $0.finishError = failure }
        await startCapture(rig)
        await hear("minutes of speech", in: rig)
        release(rig.controller)
        await pump(until: { rig.controller.phase == .idle })
        XCTAssertEqual(rig.host.rescued, ["minutes of speech"])
        XCTAssertEqual(rig.host.rescueReasons, [.failed])
        XCTAssertTrue(rig.host.inserted.isEmpty)

        // Nothing heard, nothing to keep: the error is the news.
        let silent = makeRig { $0.finishError = failure }
        await startCapture(silent)
        release(silent.controller)
        await pump(until: { silent.controller.phase == .idle })
        XCTAssertTrue(silent.host.rescued.isEmpty)
        guard case .error(let why)? = silent.host.transientNotices.last else {
            return XCTFail("a failure with nothing to rescue must say so")
        }
        XCTAssertTrue(why.contains("went away"), why)
    }

    /// A voice command's preview is an instruction, not text: pasted, it
    /// would be the user's own words handed back. It fails instead.
    func testAFailedVoiceCommandIsNotRescued() async {
        Settings.dictationCommands = true
        defer { Settings.dictationCommands = false }
        let rig = makeRig { $0.finishError = AudioCapture.Failure.sessionFailed("the server went away") }
        rig.host.anchor?.selectedText = "the draft paragraph"
        await startCapture(rig)
        await hear("make it shorter", in: rig)
        release(rig.controller)
        await pump(until: { rig.controller.phase == .idle })
        XCTAssertTrue(rig.host.rescued.isEmpty)
        XCTAssertTrue(rig.host.commands.isEmpty)
        guard case .error? = rig.host.transientNotices.last else {
            return XCTFail("a failed command must say so")
        }
    }

    /// A speech API that failed the take — offline, an expired key, a second
    /// 5xx — or outran the watchdog. A hosted model sends no preview, so the
    /// take is written down on this Mac from the audio still in memory, typed
    /// as usual, and the notice says why.
    func testAFailedUploadIsWrittenDownOnThisMac() async {
        let failed = makeRig {
            $0.finishError = URLError(.notConnectedToInternet)
            $0.unsentAudio = [Float](repeating: 0, count: 16_000)
        }
        let handed = LockedValue<[Int]>([])
        failed.controller.gates.transcribeOnDevice = { audio, _ in
            handed.mutate { $0.append(audio.count) }
            return "written here"
        }
        await startCapture(failed)
        release(failed.controller)
        await pump(until: { failed.controller.phase == .idle })
        XCTAssertEqual(failed.host.inserted, ["written here"])
        XCTAssertEqual(handed.get(), [16_000], "the same audio, once")
        guard case .hint(let notice)? = failed.host.transientNotices.last else {
            return XCTFail("the words came from another engine: say so")
        }
        XCTAssertTrue(notice.contains("this Mac"), notice)

        // The watchdog that fired is not the fallback's limit.
        let hung = makeRig { $0.unsentAudio = [Float](repeating: 0, count: 16_000) }
        _ = holdFinish(hung)
        hung.controller.finalizeSeconds = 0.1
        hung.controller.gates.transcribeOnDevice = { _, _ in "written here" }
        await startCapture(hung)
        release(hung.controller)
        await pump(until: { hung.controller.phase == .idle })
        XCTAssertEqual(hung.host.inserted, ["written here"])
    }

    /// No engine on this Mac has the language, or it hangs past its own
    /// limit: the take fails exactly as it did before. And a take the user
    /// threw away is not written down anywhere.
    func testAFallbackThatCannotHelpKeepsTheErrorAndADiscardSkipsIt() async {
        let failure = AudioCapture.Failure.sessionFailed("the key was rejected")
        let fallbacks: [@Sendable ([Float], Locale) async throws -> String] = [
            { _, _ in throw TranscriptionError.notInstalled },
            { _, _ in await Gate().wait(); return "too late" },
        ]
        for transcribe in fallbacks {
            let rig = makeRig {
                $0.finishError = failure
                $0.unsentAudio = [0]
            }
            rig.controller.fallbackSeconds = 0.1
            rig.controller.gates.transcribeOnDevice = transcribe
            await startCapture(rig)
            release(rig.controller)
            await pump(until: { rig.controller.phase == .idle })
            XCTAssertTrue(rig.host.inserted.isEmpty)
            guard case .error(let why)? = rig.host.transientNotices.last else {
                return XCTFail("the upload's own error is the news")
            }
            XCTAssertTrue(why.contains("rejected"), why)
        }

        let cancelled = makeRig { $0.unsentAudio = [0] }
        _ = holdFinish(cancelled)
        let calls = LockedValue(0)
        cancelled.controller.gates.transcribeOnDevice = { _, _ in
            calls.mutate { $0 += 1 }
            return "unwanted"
        }
        await startCapture(cancelled)
        release(cancelled.controller)
        let write = cancelled.controller.sessionTask
        cancelled.controller.keyPressed(isEscape: true)
        await write?.value
        XCTAssertEqual(calls.get(), 0, "⎋ means the take is gone, not written down elsewhere")
        XCTAssertTrue(cancelled.host.inserted.isEmpty)
    }

    /// ⎋ while a take uploads stops the upload itself, not only the wait for
    /// it: a request left running is a take the provider still bills.
    func testEscapeWhileWritingDownStopsTheUploadInFlight() async {
        let rig = makeRig()
        _ = holdFinish(rig)  // never opened: only a cancel ends the upload
        rig.controller.finalizeSeconds = 60
        await startCapture(rig)
        await hear("never mind", in: rig)
        release(rig.controller)
        await pump(until: { rig.session.finishStarted.get() })
        rig.controller.keyPressed(isEscape: true)
        await pump(until: { rig.session.finishCancelled.get() })
        XCTAssertTrue(rig.session.finishCancelled.get(), "the upload kept running after ⎋")
    }

    func testHungFinalizeWithNothingHeardSurfacesTheTimeout() async {
        let rig = makeRig()
        _ = holdFinish(rig)
        rig.controller.finalizeSeconds = 0.1
        await startCapture(rig)
        release(rig.controller)
        await pump(until: { rig.controller.phase == .idle })
        XCTAssertTrue(rig.host.inserted.isEmpty)
        XCTAssertTrue(rig.host.rescued.isEmpty)
        guard case .error(let why)? = rig.host.transientNotices.last else {
            return XCTFail("the watchdog should surface an error")
        }
        XCTAssertTrue(why.contains("timed out"), why)
    }

    /// The keyboard gates ask what the window is SHOWING, not whether it is
    /// visible — the difference is whether ⇥ can insert text that something
    /// else (a dictation notice, an engine status) has covered up.
    func testOverlayOwnershipGates() {
        XCTAssertTrue(SuggestionWindow.offersSuggestion(.suggestion("inute")))
        XCTAssertTrue(SuggestionWindow.offersCorrection(.fixPreview(original: "recieve", fix: "receive")))
        XCTAssertTrue(SuggestionWindow.offersCorrection(.correction(original: "recieve", fix: "receive")))
        // Everything a notice, a status or a live capture can put on screen
        // belongs to nobody's accept key.
        for mode: SuggestionDisplayMode? in [
            .hint("dictation cancelled"), .error("no microphone found"),
            .status("writing it down…"), .thinking(1), .listening("hello"), nil,
        ] {
            XCTAssertFalse(SuggestionWindow.offersSuggestion(mode), "\(String(describing: mode))")
            XCTAssertFalse(SuggestionWindow.offersCorrection(mode), "\(String(describing: mode))")
        }
        // The two owners are never both armed by one overlay.
        XCTAssertFalse(SuggestionWindow.offersCorrection(.suggestion("inute")))
        XCTAssertFalse(SuggestionWindow.offersSuggestion(.fixPreview(original: "recieve", fix: "receive")))
    }

    func testWatchdogAbandonsUncancellableFinalize() async {
        let rig = makeRig { $0.finishIgnoresCancellation = true }
        _ = holdFinish(rig)  // opened only at teardown
        rig.controller.finalizeSeconds = 0.1
        await startCapture(rig)
        await hear("x", in: rig)
        release(rig.controller)
        // The hang outlives the test: the deadline must not wait for a
        // finalize that ignores cancellation.
        await pump(until: { rig.controller.phase == .idle })
        XCTAssertEqual(rig.controller.phase, .idle,
                       "an uncancellable hang must still trip the watchdog")
        XCTAssertTrue(rig.host.inserted.isEmpty)
        XCTAssertEqual(rig.host.rescued, ["x"])
    }

    /// Invariant 1, enforced by a test instead of convention: the transcript
    /// must never reach the log or the diagnostics line — the debug buffer is
    /// exportable for bug reports, and what was said aloud is as sensitive as
    /// the clipboard. Counts are fine; words are not.
    func testTranscriptNeverReachesLogsOrLastEvent() async {
        let spoken = "zanzibar-confidential-sentence"
        let rig = makeRig { $0.transcript = spoken }
        let before = DebugLog.shared.snapshot().count
        await startCapture(rig)
        await hear(spoken, in: rig)
        release(rig.controller)
        await pump(until: { !rig.host.inserted.isEmpty })
        XCTAssertEqual(rig.host.inserted, [spoken], "the capture itself must succeed")
        XCTAssertFalse(rig.host.lastEvent.contains(spoken), rig.host.lastEvent)
        for entry in DebugLog.shared.snapshot().dropFirst(before) {
            XCTAssertFalse(entry.message.contains(spoken), entry.message)
            XCTAssertFalse((entry.detail ?? "").contains(spoken), entry.detail ?? "")
        }
    }

    /// The 2-minute ceiling *finishes* a listening capture: the key-up was
    /// never delivered, but whatever was said still gets typed.
    func testCaptureCeilingFinishesInsteadOfDiscarding() async throws {
        let rig = makeRig()
        await startCapture(rig)
        await hear("still talking", in: rig)
        // Never released — the ceiling has to end it alone. Fired by hand: a
        // short real ceiling races the hops `startCapture` waits out, and on a
        // loaded runner it hit `.preparing` instead.
        try XCTUnwrap(rig.controller.limitTimer).fire()
        XCTAssertEqual(rig.controller.phase, .working)
        await pump(until: { rig.controller.phase == .idle })
        XCTAssertEqual(rig.controller.phase, .idle)
        XCTAssertEqual(rig.host.inserted, ["hello world"],
                       "the ceiling must finish, not discard")
    }

    /// The ceiling exists for a lost key-up, so it must let go of the hold
    /// too: otherwise the next press reads as the same hold, and does nothing.
    func testAfterTheCeilingWithALostReleaseTheNextHoldStarts() async throws {
        let rig = makeRig()
        await startCapture(rig)
        await hear("still talking", in: rig)
        try XCTUnwrap(rig.controller.limitTimer).fire()
        await pump(until: { rig.controller.phase == .idle })
        holdDown(rig.controller)  // the key-up was never delivered
        XCTAssertNotEqual(rig.controller.phase, .idle, "the next hold opens the microphone")
    }

    /// A final pass that fails rescues the preview to the clipboard with a
    /// notice; a hold queued behind it must not open a capture whose pill
    /// paints over that notice.
    func testAFailedPassRescueDropsTheQueuedHold() async {
        let rig = makeRig { $0.finishError = AudioCapture.Failure.sessionFailed("gone") }
        let writing = holdFinish(rig)
        await startCapture(rig)
        await hear("first", in: rig)
        release(rig.controller)
        let write = rig.controller.sessionTask
        holdDown(rig.controller)
        XCTAssertTrue(rig.controller.hold.isActive, "queued behind the write")
        writing.open()
        await write?.value
        XCTAssertEqual(rig.host.rescued, ["first"])
        XCTAssertEqual(rig.capture.startCount, 1, "nothing paints over the rescue notice")
        XCTAssertEqual(rig.controller.phase, .idle)
    }

    /// The same ceiling covers `.preparing`: a hung session start with the
    /// release never delivered must not say "starting dictation…" forever
    /// while suppressing the completion pipeline. Nothing was heard, so this
    /// one discards — with a notice.
    func testPreparingCeilingDiscardsAHungStart() async throws {
        let rig = makeRig()
        _ = gatedStart(rig)  // never opened: only the ceiling can end it
        holdDown(rig.controller)
        XCTAssertEqual(rig.controller.phase, .preparing)
        try XCTUnwrap(rig.controller.limitTimer).fire()
        XCTAssertEqual(rig.controller.phase, .idle,
                       "a hung start must not wedge `.preparing`")
        guard case .error? = rig.host.transientNotices.last else {
            return XCTFail("giving up on a hold deserves a visible notice")
        }
    }

    /// ...unless what it waits on is a first-use model download. That is
    /// still running (and kept), so the notice says so — not a red "couldn't
    /// start" that the next press then contradicts with the download wording.
    func testPreparingCeilingDuringADownloadSaysSoInsteadOfFailing() async throws {
        let rig = makeRig()
        let session = rig.session
        let opening = gatedStart(rig)
        rig.controller.toggleLatch()
        XCTAssertEqual(rig.controller.phase, .preparing)
        Transcription.downloading.set(.languagePack)
        defer { Transcription.downloading.set(nil) }
        try XCTUnwrap(rig.controller.limitTimer).fire()
        XCTAssertEqual(rig.controller.phase, .idle)
        guard case .hint(let notice)? = rig.host.transientNotices.last else {
            return XCTFail("a download is not a failure: \(rig.host.transientNotices)")
        }
        XCTAssertTrue(notice.contains("getting the dictation model ready"), notice)
        opening.open()
        await pump(until: { session.cancelCount == 1 })
        XCTAssertEqual(session.cancelCount, 1, "the download was left to finish")
    }

    /// Every interrupt rule in one table — `DictationController.action(for:)`,
    /// which every interrupt entry point routes through.
    func testInterruptTable() {
        typealias C = DictationController
        let live = C.Phase.listening("words")
        let cancelled = C.InterruptAction.discard(.hint("dictation cancelled"))
        let rows: [(interrupt: C.Interrupt, phase: C.Phase, trigger: C.Trigger,
                    command: Bool, origin: Bool, heard: Bool, expect: C.InterruptAction)] = [
            // A hold: everything ends it, and keystrokes say so.
            (.key, live, .hold, false, true, false, cancelled),
            (.escape, live, .hold, false, false, false, cancelled),
            (.chord, live, .hold, false, true, false, cancelled),
            (.click, live, .hold, false, true, false, .discard(nil)),
            (.scroll, live, .hold, false, true, false, .discard(nil)),
            (.focusLost, live, .hold, false, true, false, .discard(nil)),
            // A latch: only ⎋ at its origin and a focus loss reach it.
            (.key, live, .latch, false, true, false, .ignore),
            (.click, live, .latch, false, true, false, .ignore),
            (.scroll, live, .latch, false, true, false, .ignore),
            (.chord, live, .latch, false, true, false, .ignore),
            (.escape, live, .latch, false, true, false, cancelled),
            (.escape, live, .latch, false, false, false, .ignore),  // closing Spotlight
            (.focusLost, live, .latch, false, true, true, .finish),
            (.focusLost, live, .latch, false, true, false, .discard(.hint("dictation stopped — the focus moved"))),
            // Being written down: the take is finished, whatever started it.
            (.key, .working, .hold, false, true, false, .rescue),
            (.click, .working, .latch, false, true, false, .rescue),
            (.key, .working, .hold, true, true, false, .discard(.hint("dictation dropped — you kept typing"))),
            (.click, .working, .latch, true, true, false, .discard(.hint("dictation dropped — the caret moved"))),
            (.escape, .working, .hold, true, true, false, cancelled),
            (.escape, .working, .latch, false, false, false, .ignore),  // pressed in another app
            (.scroll, .working, .hold, false, true, false, .ignore),  // moves no caret
            (.scroll, .working, .latch, true, true, false, .ignore),
            (.chord, .working, .hold, false, true, false, .ignore),
            (.focusLost, .working, .latch, false, true, false, .ignore),  // `finish` rescues it
        ]
        for row in rows {
            // `.preparing` is part of the live capture: same rules.
            for phase in row.phase == live ? [live, .preparing] : [row.phase] {
                XCTAssertEqual(C.action(for: row.interrupt, phase: phase, trigger: row.trigger, isCommand: row.command,
                                        atOrigin: row.origin, heard: row.heard), row.expect, "\(row) in \(phase)")
            }
        }
        for interrupt: C.Interrupt in [.key, .escape, .click, .scroll, .chord, .focusLost] {
            XCTAssertEqual(C.action(for: interrupt, phase: .idle, trigger: .latch, isCommand: false,
                                    atOrigin: true, heard: true), .ignore, "nothing to interrupt")
        }
    }

    /// A click mid-`.working` moves the caret a *finished* sentence was headed
    /// for — it goes to the clipboard, the same as after a keystroke.
    /// Mid-`.listening` it stays silent: the pill vanishing under the click is
    /// its own explanation.
    func testPointerDuringWorkingRescuesListeningStaysSilent() async {
        let rig = makeRig()
        let writing = holdFinish(rig)
        await startCapture(rig)
        await hear("about to move", in: rig)
        release(rig.controller)
        XCTAssertEqual(rig.controller.phase, .working)
        rig.controller.pointerInterrupted()
        writing.open()
        await pump(until: { !rig.host.rescued.isEmpty })
        XCTAssertEqual(rig.host.rescued, ["hello world"], "a clicked-away finished sentence is kept")
        XCTAssertTrue(rig.host.inserted.isEmpty)

        let quiet = makeRig()
        await startCapture(quiet)
        XCTAssertEqual(quiet.controller.phase, .listening(""))
        quiet.controller.pointerInterrupted()
        XCTAssertEqual(quiet.controller.phase, .idle)
        XCTAssertTrue(quiet.host.transientNotices.isEmpty,
                      "a listening capture interrupted by the pointer stays silent")
    }

    /// An open IME composition refuses the capture outright: synthetic
    /// keystrokes land inside the marked text and garble or force-commit it.
    func testComposingFieldRefusesCapture() {
        let rig = makeRig()
        rig.host.composing = true
        holdDown(rig.controller)
        XCTAssertEqual(rig.controller.phase, .idle)
        XCTAssertEqual(rig.capture.startCount, 0, "the microphone must never open")
        guard case .hint(let notice)? = rig.host.transientNotices.last else {
            return XCTFail("an IME refusal must be visible")
        }
        XCTAssertTrue(notice.contains("composing"), notice)
    }

    /// Starting a capture prepares the host, which cancels an in-flight ⌥⇥
    /// fix: its preview would land mid-capture and fight the listening pill.
    func testBeginPreparesTheHost() {
        let rig = makeRig()
        holdDown(rig.controller)
        XCTAssertEqual(rig.host.prepares, 1)
    }

    /// A hold that queued behind a finalize and was released before it
    /// resolved never opened the microphone — the spoken sentence is gone, and
    /// silence there reads as the feature eating it. Sentence one must still
    /// land; sentence two's loss must be said out loud.
    func testQueuedHoldReleasedBeforeInsertGetsNotice() async {
        let rig = makeRig()
        let writing = holdFinish(rig)
        await startCapture(rig)
        await hear("first sentence", in: rig)
        release(rig.controller)
        XCTAssertEqual(rig.controller.phase, .working)
        // Second hold queues behind the write…
        holdDown(rig.controller)
        // …and is released before the write resolves.
        release(rig.controller)
        writing.open()
        await pump(until: { !rig.host.inserted.isEmpty })
        XCTAssertEqual(rig.host.inserted, ["hello world"])
        await pump(until: { !rig.host.transientNotices.isEmpty })
        guard case .hint(let notice)? = rig.host.transientNotices.last else {
            return XCTFail("a swallowed queued hold must be said out loud")
        }
        XCTAssertTrue(notice.contains("wasn't listening"), notice)
    }

    // MARK: - Hands-free

    /// Press the chord and wait until the capture is actually live — the same
    /// reasoning as `startCapture`, minus the arm timer a latch doesn't use.
    private func startLatched(_ rig: Rig) async {
        rig.controller.toggleLatch()
        await pump(until: { rig.controller.phase == .listening("") })
    }

    func testLatchStartsAndStopsWithoutAKeyHeldDown() async {
        let rig = makeRig()
        await startLatched(rig)
        XCTAssertEqual(rig.controller.phase, .listening(""))
        XCTAssertEqual(rig.controller.trigger, .latch)
        XCTAssertEqual(rig.capture.startCount, 1)
        await hear("a whole paragraph", in: rig)
        rig.controller.toggleLatch()
        await pump(until: { !rig.host.inserted.isEmpty })
        XCTAssertEqual(rig.host.inserted, ["hello world"])
        XCTAssertEqual(rig.controller.phase, .idle)
    }

    /// Minutes of hands-free speech survive the focus moving away: the
    /// capture is finished, and the transcript goes to the clipboard instead
    /// of being typed into the wrong field — or thrown away.
    func testFocusChangeRescuesAHandsFreeTranscript() async {
        let rig = makeRig()
        await startLatched(rig)
        await hear("a whole paragraph", in: rig)
        rig.host.focusGeneration += 1
        rig.controller.invalidate()
        await pump(until: { !rig.host.rescued.isEmpty })
        XCTAssertEqual(rig.host.rescued, ["hello world"])
        XCTAssertTrue(rig.host.inserted.isEmpty)
        await pump(until: { rig.controller.phase == .idle })
        XCTAssertEqual(rig.controller.phase, .idle)
    }

    /// A hosted API sends no preview, so its take stays `.listening("")` to
    /// the end. Speech the meter heard is still speech: a focus change or a
    /// lost microphone finishes it instead of throwing the take away.
    func testATakeWithoutAPreviewStillFinishesWhenItHeardVoice() async {
        let moved = makeRig()
        await startLatched(moved)
        moved.capture.onBuffer?(toneBuffer(amplitude: 0.25))
        moved.host.focusGeneration += 1
        moved.controller.invalidate()
        await pump(until: { !moved.host.rescued.isEmpty })
        XCTAssertEqual(moved.host.rescued, ["hello world"])

        let unplugged = makeRig()
        await startCapture(unplugged)
        unplugged.capture.onBuffer?(toneBuffer(amplitude: 0.25))
        unplugged.capture.onDeviceChange?()
        await pump(until: { !unplugged.host.inserted.isEmpty })
        XCTAssertEqual(unplugged.host.inserted, ["hello world"])
    }

    /// A launcher (Spotlight) closed during the capture fires no focus change,
    /// so the transcript meant for its search field would type into the
    /// document underneath — it goes to the clipboard instead. Spoken and
    /// finished inside the launcher, it is typed there.
    func testLauncherClosingMidCaptureRescuesTheTranscript() async {
        let rig = makeRig()
        rig.host.focusIsInLauncher = true
        await startCapture(rig)
        await hear("weather tomorrow", in: rig)
        rig.host.focusIsInLauncher = false
        release(rig.controller)
        await pump(until: { !rig.host.rescued.isEmpty })
        XCTAssertEqual(rig.host.rescued, ["hello world"])
        XCTAssertTrue(rig.host.inserted.isEmpty)

        let stays = makeRig()
        stays.host.focusIsInLauncher = true
        await startCapture(stays)
        await hear("weather tomorrow", in: stays)
        release(stays.controller)
        await pump(until: { !stays.host.inserted.isEmpty })
        XCTAssertEqual(stays.host.inserted, ["hello world"])
    }

    /// The launcher rule: a launcher's field takes dictation; a credential
    /// app's quick-access panel, which takes keys the same non-activating way,
    /// does not — nor a terminal's hotkey window, nor a launcher the user
    /// switched off. Judged by the panel's own app, because `begin`'s app check
    /// only ever sees the one underneath — and judged before anything in the
    /// panel is read: arrowed down into a password manager's item list,
    /// nothing editable is focused, and "no field" drew its pill over the vault.
    func testPanelsAreJudgedByTheAppThatOwnsThem() {
        let saved = Settings.userBlacklist
        defer { Settings.userBlacklist = saved }
        Settings.userBlacklist = []
        for launcher in ["com.apple.Spotlight", "com.raycast.macos", "com.runningwithcrayons.Alfred"] {
            XCTAssertEqual(DictationFocus.panel(ownedBy: launcher) { true }, .field, launcher)
            XCTAssertEqual(DictationFocus.panel(ownedBy: launcher) { false }, .noField, launcher)
        }
        for vault in ["com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
                      "com.apple.Passwords", "com.apple.Passwords.MenuBarExtra", "com.apple.keychainaccess",
                      "com.googlecode.iterm2"] {
            let focus = DictationFocus.panel(ownedBy: vault) {
                XCTFail("\(vault): an off-limits panel must not be read")
                return false
            }
            XCTAssertEqual(focus, .offLimits, vault)
        }
        Settings.userBlacklist = ["raycast"]
        XCTAssertEqual(DictationFocus.panel(ownedBy: "com.raycast.macos") { true }, .offLimits)
    }

    /// A password manager's panel over an app that is on is refused like the
    /// app it belongs to: silently. "Click into a text field" would be drawn
    /// over the password manager, at someone already in one.
    func testAnOffLimitsPanelRefusesWithoutAPill() {
        let rig = makeRig()
        rig.host.focus = .offLimits
        holdDown(rig.controller)
        release(rig.controller)
        rig.controller.toggleLatch()
        XCTAssertEqual(rig.controller.phase, .idle)
        XCTAssertEqual(rig.host.prepares, 0, "nothing may be read or opened")
        XCTAssertTrue(rig.host.transientNotices.isEmpty, "\(rig.host.transientNotices)")
        // With no field at all, the advice is right and still said out loud.
        rig.host.focus = .noField
        holdDown(rig.controller)
        guard case .hint(let notice)? = rig.host.transientNotices.last else {
            return XCTFail("a missing field must still be explained")
        }
        XCTAssertTrue(notice.contains("click into a text field"), notice)
    }

    /// Voice command mode: with text selected, the transcript is an instruction
    /// for it — handed to the host (which previews a rewrite), never typed and
    /// never tidied up.
    func testVoiceCommandOverASelectionIsAnInstructionNotText() async {
        Settings.dictationCommands = true
        Settings.dictationPolish = true
        defer { Settings.dictationCommands = false; Settings.dictationPolish = false }
        let rig = makeRig()
        rig.host.anchor?.selectedText = "the draft paragraph"
        await startCapture(rig)
        await hear("make it shorter", in: rig)
        release(rig.controller)
        await pump(until: { !rig.host.commands.isEmpty })
        XCTAssertEqual(rig.host.commands.map(\.instruction), ["hello world"])
        XCTAssertEqual(rig.host.commands.map(\.selection), ["the draft paragraph"])
        XCTAssertTrue(rig.host.inserted.isEmpty, "an instruction is never typed")
    }

    /// A command whose field lost focus is dropped — its selection is gone —
    /// but out loud, like every other drop.
    func testAVoiceCommandDroppedByAFocusChangeSaysSo() async {
        Settings.dictationCommands = true
        defer { Settings.dictationCommands = false }
        let rig = makeRig()
        rig.host.anchor?.selectedText = "the draft paragraph"
        await startCapture(rig)
        await hear("make it shorter", in: rig)
        rig.host.focusGeneration += 1
        release(rig.controller)
        await pump(until: { rig.controller.phase == .idle })
        XCTAssertTrue(rig.host.commands.isEmpty)
        guard case .hint(let notice)? = rig.host.transientNotices.last else {
            return XCTFail("a silently dropped command reads as a broken feature")
        }
        XCTAssertTrue(notice.contains("voice command dropped"), notice)
    }

    /// Off (the default), dictating over a selection types — replacing it.
    func testWithoutVoiceCommandsASelectionIsDictatedOver() async {
        let rig = makeRig()
        rig.host.anchor?.selectedText = "the draft paragraph"
        await startCapture(rig)
        await hear("hello world", in: rig)
        release(rig.controller)
        await pump(until: { !rig.host.inserted.isEmpty })
        XCTAssertEqual(rig.host.inserted, ["hello world"])
        XCTAssertTrue(rig.host.commands.isEmpty)
    }

    /// An app switch fires two invalidations milliseconds apart (focus change,
    /// then resign-active). The second must not discard the finish the first
    /// one started — it would bump the generation and drop the transcript.
    func testAppSwitchDoubleInvalidateStillRescues() async {
        let rig = makeRig()
        let writing = holdFinish(rig)
        await startLatched(rig)
        await hear("a whole paragraph", in: rig)
        rig.host.focusGeneration += 1
        rig.controller.invalidate()
        rig.controller.invalidate()
        writing.open()
        await pump(until: { !rig.host.rescued.isEmpty })
        XCTAssertEqual(rig.host.rescued, ["hello world"])
        XCTAssertTrue(rig.host.inserted.isEmpty)
    }

    /// Once the transcript is headed for the clipboard, a click or keystroke
    /// can't land it behind anything — it is kept. So is a ⎋: pressed in the
    /// app the focus moved to, it was meant for that app, and goes through.
    func testClickKeyOrEscapeDuringRescueKeepTheTranscript() async {
        let rig = makeRig()
        let writing = holdFinish(rig)
        await startLatched(rig)
        await hear("a whole paragraph", in: rig)
        rig.host.focusGeneration += 1
        rig.controller.invalidate()
        XCTAssertEqual(rig.controller.phase, .working)
        rig.controller.pointerInterrupted()
        rig.controller.keyPressed()
        XCTAssertFalse(rig.controller.keyPressed(isEscape: true), "the other app's ⎋ goes through")
        XCTAssertEqual(rig.controller.phase, .working)
        writing.open()
        await pump(until: { !rig.host.rescued.isEmpty })
        XCTAssertEqual(rig.host.rescued, ["hello world"])
    }

    /// The same for a take a click sent to the clipboard with the focus where
    /// it was: past cancelling, so the ⎋ after it is the app's.
    func testEscapeAfterAClickRescuedTheTakeLeavesItBe() async {
        let rig = makeRig()
        let writing = holdFinish(rig)
        await startCapture(rig)
        await hear("about to move", in: rig)
        release(rig.controller)
        rig.controller.pointerInterrupted()
        XCTAssertFalse(rig.controller.keyPressed(isEscape: true))
        XCTAssertEqual(rig.controller.phase, .working)
        writing.open()
        await pump(until: { !rig.host.rescued.isEmpty })
        XCTAssertEqual(rig.host.rescued, ["hello world"])
    }

    /// ⌘Space opens Spotlight over a hands-free capture with no focus change,
    /// so the capture stays live — and the ⎋ that closes Spotlight was meant
    /// for Spotlight. Minutes of speech must not go with it.
    func testEscapeInALauncherOverAHandsFreeCaptureLeavesItRunning() async {
        let rig = makeRig()
        await startLatched(rig)
        await hear("a long paragraph", in: rig)
        rig.host.focusIsInLauncher = true
        XCTAssertFalse(rig.controller.keyPressed(isEscape: true), "Spotlight's ⎋ goes to Spotlight")
        XCTAssertEqual(rig.controller.phase, .listening("a long paragraph"))
        rig.host.focusIsInLauncher = false
        rig.controller.toggleLatch()
        await pump(until: { !rig.host.inserted.isEmpty })
        XCTAssertEqual(rig.host.inserted, ["hello world"])
    }

    /// A scroll while the take is written down moves no caret — `TextInjector`
    /// types at keyboard focus — so the take lands where it was going, not on
    /// the clipboard behind a false "the caret moved".
    func testScrollWhileWritingDownLetsTheTakeLand() async {
        let rig = makeRig()
        let writing = holdFinish(rig)
        await startCapture(rig)
        await hear("still here", in: rig)
        release(rig.controller)
        XCTAssertEqual(rig.controller.phase, .working)
        rig.controller.pointerInterrupted(isScroll: true)
        writing.open()
        await pump(until: { !rig.host.inserted.isEmpty })
        XCTAssertEqual(rig.host.inserted, ["hello world"])
        XCTAssertTrue(rig.host.rescued.isEmpty)
    }

    /// A rescued take's notice is how the user learns the words are on the
    /// clipboard, and a capture queued behind it would paint over it at once
    /// — so the queue goes with the rescue; the next press starts it.
    func testARescuedTakeDropsTheCaptureQueuedBehindIt() async {
        let rig = makeRig()
        let writing = holdFinish(rig)
        await startLatched(rig)
        await hear("first", in: rig)
        rig.controller.toggleLatch()
        let write = rig.controller.sessionTask
        rig.controller.toggleLatch()
        rig.controller.pointerInterrupted()
        writing.open()
        await write?.value
        XCTAssertEqual(rig.host.rescued, ["hello world"])
        XCTAssertEqual(rig.capture.startCount, 1, "nothing may paint over the rescue notice")
        XCTAssertEqual(rig.controller.phase, .idle)
    }

    /// A focus change under a queued hold: the hold died with the focus, and
    /// "wasn't listening yet" must not replace "focus moved — dictation copied".
    func testAFocusChangeUnderAQueuedHoldLeavesOnlyTheRescueNotice() async {
        let rig = makeRig()
        let writing = holdFinish(rig)
        await startCapture(rig)
        await hear("first", in: rig)
        release(rig.controller)
        let write = rig.controller.sessionTask
        holdDown(rig.controller)
        XCTAssertTrue(rig.controller.hold.isActive, "queued behind the write")
        rig.host.focusGeneration += 1
        rig.controller.invalidate()
        writing.open()
        await write?.value
        XCTAssertEqual(rig.host.rescued, ["hello world"])
        XCTAssertTrue(rig.host.transientNotices.isEmpty, "\(rig.host.transientNotices)")
    }

    /// The rule that makes hands-free worth having. Under a hold, every one of
    /// these means "that was a chord, not talking" and kills the capture — and
    /// applied to a latch they would make it a hold with extra steps.
    func testTypingClickingAndScrollingLeaveAHandsFreeCaptureAlone() async {
        let rig = makeRig()
        await startLatched(rig)
        await hear("still going", in: rig)
        rig.controller.keyPressed()
        rig.controller.pointerInterrupted()
        rig.controller.pointerInterrupted(isScroll: true)
        XCTAssertEqual(rig.controller.phase, .listening("still going"),
                       "hands-free means the user keeps working while it runs")
        XCTAssertTrue(rig.host.inserted.isEmpty)
        rig.controller.toggleLatch()
        await pump(until: { !rig.host.inserted.isEmpty })
        XCTAssertEqual(rig.host.inserted, ["hello world"])
    }

    /// ⎋ is the one keystroke that still means something: Settings promises it
    /// discards a running capture, and that promise is not per-gesture.
    func testEscapeStillCancelsAHandsFreeCapture() async {
        let rig = makeRig()
        await startLatched(rig)
        await hear("never mind", in: rig)
        XCTAssertTrue(rig.controller.keyPressed(isEscape: true), "a cancel at its origin is ours to swallow")
        await pump(until: { rig.controller.phase == .idle })
        XCTAssertEqual(rig.controller.phase, .idle)
        XCTAssertTrue(rig.host.inserted.isEmpty)
        XCTAssertGreaterThanOrEqual(rig.capture.stopCount, 1)
    }

    /// A modifier held while a latch runs is someone reaching for a chord. Fed
    /// to `ModifierHold` it would arm, open a SECOND microphone under the first,
    /// and — worse — leave the hold believing it owns a capture, so the release
    /// would end one it never started.
    func testAHeldModifierCannotOpenASecondCaptureUnderALatch() async {
        let rig = makeRig()
        await startLatched(rig)
        holdDown(rig.controller)
        XCTAssertFalse(rig.controller.isHoldArmed, "the hold never even arms")
        XCTAssertEqual(rig.capture.startCount, 1, "one capture, one microphone")
        XCTAssertEqual(rig.controller.phase, .listening(""))
        // And the release of that modifier must not end the latched capture.
        release(rig.controller)
        XCTAssertEqual(rig.controller.phase, .listening(""))
        XCTAssertTrue(rig.host.inserted.isEmpty)
    }

    /// Silence is what stops a capture nobody is holding. It FINISHES rather
    /// than discards: the words were said, and making the user say them again
    /// because they paused too long is the worst possible answer.
    func testSilenceEndsAHandsFreeCaptureAndTypesWhatItHeard() async throws {
        Settings.dictationSilence = 5
        let rig = makeRig()
        let now = stepClock(rig)
        await startLatched(rig)
        // A partial is what tells the meter someone spoke — without it the
        // capture is still inside the far longer opening budget.
        await hear("said something", in: rig)
        now.mutate { $0 += 4 }
        try XCTUnwrap(rig.controller.silenceTimer).fire()
        XCTAssertEqual(rig.controller.phase, .listening("said something"), "a pause inside the budget")
        now.mutate { $0 += 2 }
        try XCTUnwrap(rig.controller.silenceTimer, "re-armed by the tick before").fire()
        XCTAssertEqual(rig.controller.phase, .working)
        await pump(until: { !rig.host.inserted.isEmpty })
        XCTAssertEqual(rig.host.inserted, ["hello world"])
        XCTAssertEqual(rig.controller.phase, .idle)
    }

    /// Before the first word the budget is the long one. Someone who pressed
    /// the chord and is still gathering their thoughts has said nothing to
    /// measure, and holding them to a mid-sentence pause budget would break the
    /// feature for the long-form dictation it exists for.
    func testSilenceBeforeTheFirstWordGetsTheLongerBudget() async throws {
        Settings.dictationSilence = 5
        let rig = makeRig()
        let now = stepClock(rig)
        await startLatched(rig)
        now.mutate { $0 += rig.controller.openingSilenceSeconds - 1 }
        try XCTUnwrap(rig.controller.silenceTimer).fire()
        XCTAssertEqual(rig.controller.phase, .listening(""),
                       "nothing said yet is not the same as having stopped talking")
        now.mutate { $0 += 2 }
        try XCTUnwrap(rig.controller.silenceTimer).fire()
        XCTAssertEqual(rig.controller.phase, .working, "...but the long budget runs out too")
    }

    /// A held key already says when the user is done. Cutting one short on a
    /// thinking pause would take away the single thing a hold is unambiguous
    /// about.
    func testAHeldCaptureIsNeverCutShortBySilence() async {
        Settings.dictationSilence = 5
        let rig = makeRig()
        await startCapture(rig)
        await hear("mid sentence", in: rig)
        XCTAssertNil(rig.controller.silenceTimer, "no silence clock runs under a held key")
        XCTAssertEqual(rig.controller.phase, .listening("mid sentence"))
    }

    /// The two ceilings mean different things: 120 s is a safety net under a
    /// key-up the event tap may have swallowed, which a latch has no need of.
    /// A latch bound by the hold's ceiling would cut a long dictation off at
    /// two minutes for a reason that does not apply to it.
    func testAHandsFreeCaptureRunsPastTheHoldCeiling() async throws {
        let rig = makeRig()
        await startLatched(rig)
        let ceiling = try XCTUnwrap(rig.controller.limitTimer).fireDate.timeIntervalSinceNow
        XCTAssertEqual(ceiling, rig.controller.maxLatchedSeconds, accuracy: 5)
        XCTAssertGreaterThan(ceiling, rig.controller.maxCaptureSeconds)
    }

    /// ...and it does have a ceiling of its own. Nothing was ever going to
    /// arrive to end a forgotten latch, so this is the only bound on it — and
    /// like the hold's, it finishes rather than discarding.
    func testAForgottenLatchStillHitsItsOwnCeiling() async throws {
        let rig = makeRig()
        await startLatched(rig)
        await hear("left running", in: rig)
        try XCTUnwrap(rig.controller.limitTimer).fire()
        await pump(until: { !rig.host.inserted.isEmpty })
        XCTAssertEqual(rig.host.inserted, ["hello world"])
        XCTAssertEqual(rig.controller.phase, .idle)
    }

    /// Pressed again while the last transcript is still being written down. A
    /// chord is its own toggle, so the second press takes the queued capture
    /// back off rather than stacking a third.
    func testAQueuedHandsFreeCaptureCanBeTakenBack() async {
        let rig = makeRig()
        let writing = holdFinish(rig)
        await startLatched(rig)
        await hear("first", in: rig)
        rig.controller.toggleLatch()
        XCTAssertEqual(rig.controller.phase, .working)
        let write = rig.controller.sessionTask
        rig.controller.toggleLatch()
        rig.controller.toggleLatch()
        writing.open()
        await write?.value
        XCTAssertEqual(rig.controller.phase, .idle)
        XCTAssertEqual(rig.host.inserted, ["hello world"])
        XCTAssertEqual(rig.capture.startCount, 1, "the queued capture was taken back")
    }

    /// An empty take is no ⎋, focus change or failure: a hands-free capture
    /// queued during "writing it down…" still starts after "nothing heard",
    /// or the user speaks into a closed microphone.
    func testNothingHeardStillStartsTheQueuedHandsFreeCapture() async {
        let rig = makeRig { $0.transcript = "" }
        let writing = holdFinish(rig)
        await startLatched(rig)
        rig.controller.toggleLatch()
        XCTAssertEqual(rig.controller.phase, .working)
        let write = rig.controller.sessionTask
        rig.controller.toggleLatch()
        writing.open()
        await write?.value
        XCTAssertEqual(rig.host.transientNotices, [.hint("nothing heard")])
        await pump(until: { rig.controller.phase == .listening("") })
        XCTAssertEqual(rig.capture.startCount, 2, "the queued capture started")
    }

    /// `.preparing` is inside the hands-free window, not outside it. Scoping
    /// the relaxed rules to `.listening` alone meant a scroll while the model
    /// was still coming down tore the capture apart with no pill and no notice
    /// — and "press the chord, then go and find what I was going to say" is
    /// the hands-free case exactly.
    func testInterruptsDuringAHandsFreeStartLeaveItAlone() async {
        let rig = makeRig()
        let opening = gatedStart(rig)
        rig.controller.toggleLatch()
        XCTAssertEqual(rig.controller.phase, .preparing)
        rig.controller.pointerInterrupted()
        rig.controller.keyPressed()
        XCTAssertEqual(rig.controller.phase, .preparing,
                       "the wait for the microphone is still part of the capture")
        opening.open()
        await pump(until: { rig.controller.phase == .listening("") })
        XCTAssertEqual(rig.controller.phase, .listening(""))
        XCTAssertEqual(rig.capture.startCount, 1)
    }

    /// ...and ⎋ during that same wait is still an explicit cancel, with the
    /// wording Settings promises rather than a silent teardown.
    func testEscapeDuringAHandsFreeStartSaysCancelled() async {
        let rig = makeRig()
        _ = gatedStart(rig)
        rig.controller.toggleLatch()
        XCTAssertEqual(rig.controller.phase, .preparing)
        rig.controller.keyPressed(isEscape: true)
        XCTAssertEqual(rig.controller.phase, .idle)
        guard case .hint(let notice)? = rig.host.transientNotices.last else {
            return XCTFail("a deliberate cancel has to say so")
        }
        XCTAssertTrue(notice.contains("cancelled"), notice)
    }

    /// Reaching for ⌃⌥D with ⌥ already down. The chord deliberately no longer
    /// disarms the hold (that is what used to destroy the sentence a previous
    /// hold had just finished), so the hold's arm timer fires *inside* the
    /// hands-free capture. Swallowing that `.begin` without clearing it left
    /// `ModifierHold` believing it owned a capture it never started — and the
    /// first modifier released afterwards then read as a cancel and threw the
    /// paragraph away.
    func testAModifierHeldIntoALatchLeavesNoPhantomHold() async {
        let rig = makeRig()
        let writing = holdFinish(rig)
        rig.controller.modifierChanged(modifierEvent(down: true))
        rig.controller.toggleLatch()
        await pump(until: { rig.controller.phase == .listening("") })
        // The arm timer fires inside the capture: its `.begin`, swallowed
        // under the latch, disarms the hold. (A real fire may have beaten
        // this one to it — the same handler either way.)
        rig.controller.armTimer?.fire()
        XCTAssertFalse(rig.controller.isHoldArmed)
        XCTAssertEqual(rig.controller.phase, .listening(""))
        XCTAssertEqual(rig.capture.startCount, 1, "one capture, not two")
        await hear("the whole paragraph", in: rig)
        rig.controller.toggleLatch()
        XCTAssertEqual(rig.controller.phase, .working)
        // ⌃ lifts before ⌥ — the coin flip that used to end in a cancel.
        rig.controller.modifierChanged(modifierEvent(key: KeyCode.leftControl, flag: .maskControl, down: false))
        rig.controller.modifierChanged(modifierEvent(down: false))
        writing.open()
        await pump(until: { !rig.host.inserted.isEmpty })
        XCTAssertEqual(rig.host.inserted, ["hello world"],
                       "letting go of a modifier must not cancel what was already said")
    }

    /// The pre-first-word budget belongs to the microphone being open, not to
    /// the keypress. The meter has to be built before the capture starts, but
    /// measured from there a first-use language-pack download spends the whole
    /// budget before a word can be said — and the first check after the wait
    /// ends the capture as "nothing heard".
    func testTheOpeningSilenceBudgetStartsWhenTheMicrophoneDoes() async throws {
        Settings.dictationSilence = 5
        let rig = makeRig()
        let now = stepClock(rig)
        let opening = gatedStart(rig)
        rig.controller.toggleLatch()
        // A wait longer than the whole opening budget, then the microphone.
        now.mutate { $0 += rig.controller.openingSilenceSeconds + 30 }
        opening.open()
        await pump(until: { rig.controller.phase == .listening("") })
        now.mutate { $0 += 1 }
        try XCTUnwrap(rig.controller.silenceTimer).fire()
        XCTAssertEqual(rig.controller.phase, .listening(""),
                       "the wait for the model must not be charged to the speaker")
    }

    /// ⎋ has to mean cancelled, not paused. A second press of the chord during
    /// the write-down queues another capture, and the resume that honours it
    /// runs from `discard` too — so without an explicit rule the microphone
    /// re-opens on the far side of the cancel, and `begin`'s repaint wipes the
    /// "dictation cancelled" pill on its way past.
    func testCancellingAQueuedHandsFreeCaptureDoesNotReopenTheMicrophone() async {
        let rig = makeRig()
        let writing = holdFinish(rig)
        await startLatched(rig)
        await hear("first", in: rig)
        rig.controller.toggleLatch()
        XCTAssertEqual(rig.controller.phase, .working)
        let write = rig.controller.sessionTask
        rig.controller.toggleLatch()
        rig.controller.keyPressed(isEscape: true)
        // The cancelled take's transcript still arrives, and must reopen nothing.
        writing.open()
        await write?.value
        XCTAssertEqual(rig.controller.phase, .idle, "⎋ means cancelled, not paused")
        XCTAssertEqual(rig.capture.startCount, 1, "the microphone must not re-open after a cancel")
        XCTAssertTrue(rig.host.inserted.isEmpty)
    }

    /// The same rule for a focus change: it ends the capture *and* the queue
    /// behind it, rather than opening the microphone in the app just moved to.
    func testAFocusChangeDoesNotHandTheQueuedCaptureToTheNextApp() async {
        let rig = makeRig()
        let writing = holdFinish(rig)
        await startLatched(rig)
        await hear("first", in: rig)
        rig.controller.toggleLatch()
        let write = rig.controller.sessionTask
        rig.controller.toggleLatch()
        rig.controller.invalidate()
        writing.open()
        await write?.value
        XCTAssertEqual(rig.capture.startCount, 1)
        XCTAssertEqual(rig.controller.phase, .idle)
    }

    /// Standing down from the interrupts is about the LISTENING window. Once
    /// the chord has been pressed again and the words are being written down,
    /// a click has moved the caret they are about to be typed at — so they go
    /// to the clipboard instead, whatever started the capture.
    func testAClickWhileWritingAHandsFreeTranscriptDownRescuesIt() async {
        let rig = makeRig()
        let writing = holdFinish(rig)
        await startLatched(rig)
        await hear("about to land", in: rig)
        rig.controller.toggleLatch()
        XCTAssertEqual(rig.controller.phase, .working)
        rig.controller.pointerInterrupted()
        writing.open()
        await pump(until: { rig.controller.phase == .idle })
        XCTAssertTrue(rig.host.inserted.isEmpty,
                      "the caret moved — the transcript must not follow it")
        XCTAssertEqual(rig.host.rescued, ["hello world"], "minutes of speech are kept, not dropped")
    }

    /// `fire()` runs a timer's block whether or not anything scheduled it, so
    /// every hand-fired test above would pass on a timer the run loop never
    /// sees, and on a ceiling left armed after its replacement. These are the
    /// live ones — and the ones that must be dead.
    func testTheTimersAreLiveOnTheMainRunLoop() async throws {
        Settings.dictationSilence = 5
        let rig = makeRig()
        rig.controller.modifierChanged(modifierEvent(down: true))
        assertLiveOnMain(rig.controller.armTimer, "arm")
        let arm = try XCTUnwrap(rig.controller.armTimer)
        release(rig.controller)
        XCTAssertFalse(arm.isValid, "a released key must not start a capture later")

        let opening = gatedStart(rig)
        rig.controller.toggleLatch()
        let short = try XCTUnwrap(rig.controller.limitTimer)
        assertLiveOnMain(short, "short ceiling")
        opening.open()
        await pump(until: { rig.controller.phase == .listening("") })
        let long = try XCTUnwrap(rig.controller.limitTimer)
        XCTAssertFalse(short === long)
        XCTAssertFalse(short.isValid, "the short bound must not outlive the re-arm")
        assertLiveOnMain(long, "long ceiling")
        let silence = try XCTUnwrap(rig.controller.silenceTimer)
        assertLiveOnMain(silence, "silence")

        rig.controller.keyPressed(isEscape: true)
        XCTAssertFalse(long.isValid, "a discarded capture leaves no ceiling behind")
        XCTAssertFalse(silence.isValid, "...and no silence clock")
    }

    /// Valid, and in the main run loop's default mode — where
    /// `Timer.scheduledTimer` puts it and where its handler may assume the
    /// main actor.
    private func assertLiveOnMain(_ timer: Timer?, _ what: String, line: UInt = #line) {
        guard let timer else { return XCTFail("no \(what) timer", line: line) }
        XCTAssertTrue(timer.isValid, "\(what) timer invalidated", line: line)
        XCTAssertTrue(CFRunLoopContainsTimer(CFRunLoopGetMain(), unsafeBitCast(timer, to: CFRunLoopTimer.self),
                                             .defaultMode),
                      "\(what) timer is not scheduled on the main run loop", line: line)
    }

    /// A latched capture's long ceiling is about how long someone may SPEAK.
    /// Applied to a session that never opened it would leave "starting
    /// dictation…" on screen for ten minutes with the completion pipeline
    /// suppressed behind `isBusy` the whole time.
    func testAHungHandsFreeStartGivesUpOnTheShortCeiling() throws {
        let rig = makeRig()
        _ = gatedStart(rig)  // never opened: only the ceiling can end it
        rig.controller.toggleLatch()
        XCTAssertEqual(rig.controller.phase, .preparing)
        let ceiling = try XCTUnwrap(rig.controller.limitTimer)
        XCTAssertEqual(ceiling.fireDate.timeIntervalSinceNow, rig.controller.maxCaptureSeconds, accuracy: 5,
                       "a hung start wedges the whole pipeline — the long ceiling is not for it")
        ceiling.fire()
        XCTAssertEqual(rig.controller.phase, .idle)
    }

    /// The chord matcher is exact about modifiers: ⌃⌥D must not fire on ⌃⌥⇧D
    /// or on plain D, or it would eat a keystroke meant for the app.
    func testLatchChordDemandsExactModifiers() {
        let latch = DictationLatch.controlOptionD
        XCTAssertTrue(latch.matches(keyCode: KeyCode.d, flags: [.maskControl, .maskAlternate]))
        XCTAssertFalse(latch.matches(keyCode: KeyCode.d, flags: [.maskControl, .maskAlternate, .maskShift]))
        XCTAssertFalse(latch.matches(keyCode: KeyCode.d, flags: [.maskControl]))
        XCTAssertFalse(latch.matches(keyCode: KeyCode.d, flags: []))
        XCTAssertFalse(latch.matches(keyCode: KeyCode.space, flags: [.maskControl, .maskAlternate]))
        XCTAssertFalse(DictationLatch.off.matches(keyCode: KeyCode.d,
                                                  flags: [.maskControl, .maskAlternate]))
    }

    // MARK: - Voice meter

    /// One buffer of a tone at `amplitude`, in the mono float format the
    /// analyzer asks for.
    private func toneBuffer(amplitude: Float, frames: Int = 800) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let channel = buffer.floatChannelData![0]
        for index in 0..<frames {
            channel[index] = amplitude * sin(Float(index) * 0.3)
        }
        return buffer
    }

    func testVoiceMeterHearsSpeechOverALearnedRoomFloor() {
        let meter = VoiceMeter()
        XCTAssertFalse(meter.heardVoice)
        // Room tone, however long it runs. The floor learns its way down to it
        // and the margin keeps it under the bar the whole time.
        for _ in 0..<200 { meter.feed(toneBuffer(amplitude: 0.002)) }
        XCTAssertFalse(meter.heardVoice, "a steady room must never read as speech")
        meter.feed(toneBuffer(amplitude: 0.25))
        XCTAssertTrue(meter.heardVoice)
    }

    /// The drift the "learn from quiet frames only" rule exists to prevent: a
    /// floor that averages speech in climbs toward the talker, the margin
    /// closes, and a long sentence reads as silence exactly when it matters.
    ///
    /// Driven on simulated time, and with the gaps real speech has between
    /// words — a wall-clock loop would finish in milliseconds and prove nothing
    /// about a sentence that runs for half a minute.
    func testALongSentenceDoesNotTrainTheFloorUpToItself() {
        let opened = Date()
        let meter = VoiceMeter(now: opened)
        var elapsed: TimeInterval = 0
        // 30 s of speech at 50 buffers a second, one quiet frame in every ten
        // for the stops between words.
        for step in 0..<1500 {
            elapsed += 0.02
            let quiet = step % 10 == 0
            meter.feed(toneBuffer(amplitude: quiet ? 0.002 : 0.25),
                       now: opened.addingTimeInterval(elapsed))
        }
        XCTAssertLessThan(meter.quietFor(now: opened.addingTimeInterval(elapsed)), 0.05,
                          "sustained speech must stay voiced to the last buffer")
    }

    /// The other half of the same trade-off. Learning only from quiet frames
    /// means a room that is never quiet is never measured: the first buffer
    /// clears the starting floor, nothing after it is ever judged quiet, and
    /// the silence auto-stop is off for the rest of the capture — a forgotten
    /// chord then runs to the ten-minute ceiling with the microphone open.
    func testARoomThatIsNeverQuietStillGetsMeasured() {
        let opened = Date()
        let meter = VoiceMeter(now: opened)
        // Loud room tone, unbroken: −35 dBFS clears the −50 starting floor from
        // the very first buffer.
        var elapsed: TimeInterval = 0
        for _ in 0..<600 {
            elapsed += 0.02
            meter.feed(toneBuffer(amplitude: 0.025), now: opened.addingTimeInterval(elapsed))
        }
        let recalibrated = opened.addingTimeInterval(elapsed)
        // Past the recalibration window the room has become the floor, so it
        // reads as quiet and the clock starts running again.
        meter.feed(toneBuffer(amplitude: 0.025), now: recalibrated.addingTimeInterval(0.02))
        XCTAssertGreaterThan(meter.quietFor(now: recalibrated.addingTimeInterval(1)), 0.5,
                             "an unbroken room must not read as speech forever")
        // ...and speech over it still clears the new floor.
        meter.feed(toneBuffer(amplitude: 0.3), now: recalibrated.addingTimeInterval(1))
        XCTAssertLessThan(meter.quietFor(now: recalibrated.addingTimeInterval(1)), 0.05)
    }

    /// A device that opens on digital silence — a warming USB microphone, a
    /// hardware-muted headset, the first frames after `startRunning` — used to
    /// drag the floor to −95 in well under a second. Ordinary room tone then
    /// cleared the bar permanently, which is the auto-stop switching itself off
    /// by a second door.
    func testSilenceAtTheMicrophoneOpeningDoesNotDeafenTheMeter() {
        let opened = Date()
        let meter = VoiceMeter(now: opened)
        for step in 0..<100 {
            meter.feed(toneBuffer(amplitude: 0),
                       now: opened.addingTimeInterval(Double(step) * 0.02))
        }
        // Room tone at −57 dBFS, which has to stay under the bar.
        meter.feed(toneBuffer(amplitude: 0.002), now: opened.addingTimeInterval(2))
        XCTAssertFalse(meter.heardVoice,
                       "a floor dragged down by dead air would hear the room as speech")
    }

    /// Silence is measured from the microphone opening until something is
    /// heard — otherwise a capture that heard nothing at all would report zero
    /// quiet seconds forever and never reach its budget.
    func testQuietTimeRunsFromTheMicrophoneOpeningUntilTheFirstWord() {
        let opened = Date()
        let meter = VoiceMeter(now: opened)
        XCTAssertEqual(meter.quietFor(now: opened.addingTimeInterval(4)), 4, accuracy: 0.01)
        meter.noteVoice(now: opened.addingTimeInterval(4))
        XCTAssertEqual(meter.quietFor(now: opened.addingTimeInterval(5)), 1, accuracy: 0.01)
    }

    /// AVCapture flags the mono Float32 it delivers as interleaved even when asked
    /// for non-interleaved; for one channel that's the same samples, not a mismatch.
    func testMonoInterleavingIsNotAFormatMismatch() {
        func format(_ rate: Double, _ channels: AVAudioChannelCount, interleaved: Bool) -> AVAudioFormat {
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: interleaved)!
        }
        let asked = format(16_000, 1, interleaved: false)  // Parakeet's and the API's format
        XCTAssertTrue(AudioCapture.accepts(format(16_000, 1, interleaved: true), for: asked))
        XCTAssertFalse(AudioCapture.accepts(format(48_000, 1, interleaved: true), for: asked))
        XCTAssertFalse(AudioCapture.accepts(format(16_000, 2, interleaved: true), for: asked))
        let stereo = format(16_000, 2, interleaved: false)
        XCTAssertFalse(AudioCapture.accepts(format(16_000, 2, interleaved: true), for: stereo))
    }
}
