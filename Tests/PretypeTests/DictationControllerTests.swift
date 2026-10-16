import AVFoundation
import CoreGraphics
import XCTest
@testable import Pretype

/// A transcription session driven by the test instead of a microphone: partials
/// are pushed by hand, `finish` returns a scripted transcript after an optional
/// delay, and every `cancel` is counted.
private final class ScriptedSession: TranscriptionSession, @unchecked Sendable {
    var audioFormat: AVAudioFormat?
    var transcript = "hello world"
    var finishDelay: TimeInterval = 0
    /// Like `finishDelay`, but the wait shrugs off task cancellation — the
    /// shape of a genuinely deadlocked finalize, which the watchdog must
    /// abandon rather than await.
    var uncancellableFinishDelay: TimeInterval = 0
    var onPartial: (@Sendable (String) -> Void)?
    private(set) var cancelCount = 0

    func feed(_ buffer: AVAudioPCMBuffer) {}

    func finish() async throws -> String {
        if uncancellableFinishDelay > 0 {
            let end = Date().addingTimeInterval(uncancellableFinishDelay)
            while Date() < end {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        } else if finishDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(finishDelay * 1_000_000_000))
        }
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
    var lastEvent = ""
    var typingContext = TypingContext()
    var focusGeneration = 0
    var focusIsInLauncher = false
    var fallbackCaretRect: CGRect?
    var fallbackHostStyle = HostTextStyle()

    var hasField = true
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
    var tidyDelay: TimeInterval = 0

    func hasFocusedTextField() -> Bool { hasField }
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
    func rescueDictated(_ text: String, because reason: DictationRescue) { rescued.append(text) }
    private(set) var commands: [(instruction: String, selection: String)] = []
    func applyVoiceCommand(_ instruction: String, to selection: String) {
        commands.append((instruction, selection))
    }
    func tidyDictation(_ text: String, before context: String) async -> String? {
        if tidyDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(tidyDelay * 1_000_000_000))
        }
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
        // Off unless a test asks for it: the silence clock is real wall time,
        // and a default budget ticking under every latch test would end
        // captures the test believes it still owns.
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
        controller.hold.threshold = 0.02
        controller.gates.appIsActive = { false }
        controller.gates.secureInput = { false }
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

    /// Spin the main run loop so `Timer`s fire and queued MainActor tasks run.
    private func pump(_ seconds: TimeInterval) async { await pump(until: { false }, timeout: seconds) }

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

    /// Press the dictation key and wait until the arm timer has acted: the
    /// hold went live (`tick` fired `.begin`), or something disarmed it. A
    /// press the controller never armed (under a latch) has nothing to wait for.
    private func holdDown(_ controller: DictationController) async {
        controller.modifierChanged(modifierEvent(down: true))
        await pump(until: { controller.hold.isActive || !controller.isHoldArmed })
    }

    /// The key-up is applied synchronously (`modifierChanged`), so there is
    /// nothing to wait for — a fixed spin here only let a short `finishDelay`
    /// run out on a loaded runner before the caller could look at `.working`.
    private func release(_ controller: DictationController) async {
        controller.modifierChanged(modifierEvent(down: false))
    }

    /// Hold the key and wait until the capture is actually LIVE. The press
    /// arms a real timer and `begin` crosses two awaits before `.listening`,
    /// so "held long enough" says nothing about how far the machine got — a
    /// loaded runner schedules those hops late, and a partial poked (or a
    /// release applied) before they land exercises a different path than the
    /// one the test is about.
    private func startCapture(_ rig: Rig) async {
        await holdDown(rig.controller)
        await pump(until: { rig.controller.phase == .listening("") })
    }

    /// Hold the capture open in `.preparing` — a Bluetooth microphone spends
    /// seconds there and a first-use language pack minutes.
    private func slowStart(_ rig: Rig, seconds: TimeInterval) {
        let session = rig.session
        rig.controller.gates.startSession = { _, onPartial in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            session.onPartial = onPartial
            return session
        }
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
        await release(rig.controller)
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
        await release(rig.controller)
        await pump(until: { rig.controller.phase == .idle })
        XCTAssertTrue(rig.host.inserted.isEmpty)
        XCTAssertEqual(rig.controller.phase, .idle)
    }

    /// Release-then-keep-typing: the finished sentence can't be typed at a
    /// caret that has moved, and must not be thrown away over one keystroke
    /// either — on a hosted API `.working` is the whole upload.
    func testKeystrokeDuringFinalizeRescuesToTheClipboard() async {
        let rig = makeRig { $0.finishDelay = 0.3 }
        await startCapture(rig)
        await hear("about to move", in: rig)
        await release(rig.controller)
        XCTAssertEqual(rig.controller.phase, .working)
        rig.controller.keyPressed()
        XCTAssertEqual(rig.controller.phase, .working, "a keystroke no longer drops the take")
        await pump(until: { !rig.host.rescued.isEmpty })
        XCTAssertEqual(rig.host.rescued, ["hello world"])
        XCTAssertTrue(rig.host.inserted.isEmpty, "the caret moved — the transcript must not follow it")
    }

    /// A voice command has nothing to rescue — its selection is what moved —
    /// so a keystroke mid-write still drops it, with the notice.
    func testKeystrokeDuringAVoiceCommandStillDropsIt() async {
        Settings.dictationCommands = true
        defer { Settings.dictationCommands = false }
        let rig = makeRig { $0.finishDelay = 0.3 }
        rig.host.anchor?.selectedText = "the draft paragraph"
        await startCapture(rig)
        await hear("make it shorter", in: rig)
        await release(rig.controller)
        rig.controller.keyPressed()
        XCTAssertEqual(rig.controller.phase, .idle)
        guard case .hint(let notice)? = rig.host.transientNotices.last else {
            return XCTFail("a silently vanished command reads as a broken feature")
        }
        XCTAssertTrue(notice.contains("kept typing"), notice)
        await pump(0.4)
        XCTAssertTrue(rig.host.commands.isEmpty)
        XCTAssertTrue(rig.host.rescued.isEmpty)
    }

    func testSecondHoldQueuesBehindFinalize() async {
        let rig = makeRig { $0.finishDelay = 0.25 }
        await startCapture(rig)
        await hear("first sentence", in: rig)
        await release(rig.controller)
        XCTAssertEqual(rig.controller.phase, .working)
        // Second hold while the first transcript is still being written down:
        // queued, not started — and NOT silently dropped either way.
        await holdDown(rig.controller)
        XCTAssertEqual(rig.controller.phase, .working)
        XCTAssertEqual(rig.capture.startCount, 1)
        await pump(until: { rig.capture.startCount == 2 })
        XCTAssertEqual(rig.host.inserted, ["hello world"])
        XCTAssertTrue(rig.controller.isCapturing, "the queued hold must start once the insert lands")
        XCTAssertEqual(rig.capture.startCount, 2)
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
        XCTAssertLessThanOrEqual(rig.capture.startCount, 4,
                                 "the tap must not be restarted on every notification")
        XCTAssertEqual(rig.controller.phase, .idle)
        XCTAssertEqual(rig.host.inserted, ["hello world"],
                       "what was already heard is still typed")
    }

    /// Released while the start is only opening the microphone (no language
    /// pack downloading): the start is cancelled outright — so a second press
    /// can't race it — and the notice says what actually happened.
    func testReleaseDuringMicOpenCancelsTheStart() async {
        let rig = makeRig()
        let session = rig.session
        slowStart(rig, seconds: 0.2)
        rig.controller.modifierChanged(modifierEvent(down: true))
        await pump(until: { rig.controller.phase == .preparing })
        XCTAssertEqual(rig.controller.phase, .preparing)
        await release(rig.controller)
        XCTAssertEqual(rig.controller.phase, .idle)
        guard case .hint(let notice)? = rig.host.transientNotices.last else {
            return XCTFail("a release during the mic open should say so")
        }
        XCTAssertTrue(notice.contains("microphone"),
                      "no download is running — 'getting the model ready' would be a lie: \(notice)")
        // Past the 200 ms the start would have taken, had it not been cancelled.
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(session.cancelCount, 0, "a cancelled start produces no session")
        XCTAssertEqual(rig.capture.startCount, 0)
    }

    /// Released mid language-pack download: the start is left running (the
    /// next press would otherwise download again), and the session it
    /// produces belongs to a discarded capture, so it dies on arrival.
    func testReleaseDuringDownloadKeepsTheStartAndCancelsSessionOnArrival() async {
        let rig = makeRig()
        let session = rig.session
        slowStart(rig, seconds: 0.2)
        rig.controller.modifierChanged(modifierEvent(down: true))
        await pump(until: { rig.controller.phase == .preparing })
        Transcription.downloading.set(.languagePack)
        defer { Transcription.downloading.set(nil) }
        await release(rig.controller)
        XCTAssertEqual(rig.controller.phase, .idle)
        guard case .hint(let notice)? = rig.host.transientNotices.last else {
            return XCTFail("a release mid-download should say so")
        }
        XCTAssertTrue(notice.contains("getting the dictation model ready"), notice)
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
        await holdDown(waits.controller)
        await pump(until: { !waits.host.transientNotices.isEmpty })
        XCTAssertEqual(waits.capture.startCount, 0)
        guard case .hint(let notice)? = waits.host.transientNotices.last else {
            return XCTFail("a capture waiting on its own model's download should say so")
        }
        XCTAssertTrue(notice.contains("getting the dictation model ready"), notice)
    }

    func testSecureInputRefusesBeforeOpeningMic() async {
        let rig = makeRig()
        rig.controller.gates.secureInput = { true }
        await holdDown(rig.controller)
        // The refusal is the arm timer's doing — wait for its evidence, not
        // for a fixed slice of runner time.
        await pump(until: { !rig.host.transientNotices.isEmpty })
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
        rig.host.tidyDelay = 0.5
        await startCapture(rig)
        await hear("x", in: rig)
        await release(rig.controller)
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
        await release(rig.controller)
        await pump(until: { !rig.host.inserted.isEmpty })
        XCTAssertEqual(rig.host.inserted, ["Hello, world."])
    }

    func testEscapeDuringFinalizeSaysCancelled() async {
        let rig = makeRig { $0.finishDelay = 0.3 }
        await startCapture(rig)
        await hear("never mind", in: rig)
        await release(rig.controller)
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
        await holdDown(rig.controller)
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
        let rig = makeRig { $0.finishDelay = 5 }
        rig.controller.finalizeSeconds = 0.1
        await startCapture(rig)
        await hear("x", in: rig)
        await release(rig.controller)
        await pump(until: { rig.controller.phase == .idle })
        XCTAssertEqual(rig.controller.phase, .idle, "a hung finalize must not wedge the pill")
        XCTAssertTrue(rig.host.inserted.isEmpty)
        // What the pill last showed is all that's left of the take: kept.
        XCTAssertEqual(rig.host.rescued, ["x"], "a timed-out take must leave its preview on the clipboard")
    }

    func testHungFinalizeWithNothingHeardSurfacesTheTimeout() async {
        let rig = makeRig { $0.finishDelay = 5 }
        rig.controller.finalizeSeconds = 0.1
        await startCapture(rig)
        await release(rig.controller)
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
        let rig = makeRig { $0.uncancellableFinishDelay = 1.0 }
        rig.controller.finalizeSeconds = 0.1
        await startCapture(rig)
        await hear("x", in: rig)
        await release(rig.controller)
        // Well before the 1 s hang resolves: the deadline must not wait for a
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
        await release(rig.controller)
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
    func testCaptureCeilingFinishesInsteadOfDiscarding() async {
        // The ceiling clock starts inside `begin`, racing the same hops
        // `startCapture` waits out. 0.6 s lost that race on a loaded Mac (the
        // ceiling hit `.preparing` and discarded); 3 s costs 3 s, never a flake.
        let rig = makeRig()
        rig.controller.maxCaptureSeconds = 3
        await startCapture(rig)
        XCTAssertEqual(rig.controller.phase, .listening(""))
        rig.session.onPartial?("still talking")
        // Never released — the ceiling has to end it alone.
        await pump(until: { rig.controller.phase == .idle })
        XCTAssertEqual(rig.controller.phase, .idle)
        XCTAssertEqual(rig.host.inserted, ["hello world"],
                       "the ceiling must finish, not discard")
    }

    /// The same ceiling covers `.preparing`: a hung session start with the
    /// release never delivered must not say "starting dictation…" forever
    /// while suppressing the completion pipeline. Nothing was heard, so this
    /// one discards — with a notice.
    func testPreparingCeilingDiscardsAHungStart() async {
        let rig = makeRig()
        rig.controller.maxCaptureSeconds = 0.15
        rig.controller.gates.startSession = { _, _ in
            // Far past the wait below, so only the ceiling can end it (the
            // discard cancels this sleep).
            try await Task.sleep(nanoseconds: 60_000_000_000)
            throw AudioCapture.Failure.sessionFailed("never reached")
        }
        await holdDown(rig.controller)
        await pump(until: { rig.controller.phase == .preparing })
        XCTAssertEqual(rig.controller.phase, .preparing)
        await pump(until: { rig.controller.phase == .idle })
        XCTAssertEqual(rig.controller.phase, .idle,
                       "a hung start must not wedge `.preparing`")
        guard case .error? = rig.host.transientNotices.last else {
            return XCTFail("giving up on a hold deserves a visible notice")
        }
    }

    /// A click mid-`.working` moves the caret a *finished* sentence was headed
    /// for — it goes to the clipboard, the same as after a keystroke.
    /// Mid-`.listening` it stays silent: the pill vanishing under the click is
    /// its own explanation.
    func testPointerDuringWorkingRescuesListeningStaysSilent() async {
        let rig = makeRig { $0.finishDelay = 0.3 }
        await startCapture(rig)
        await hear("about to move", in: rig)
        await release(rig.controller)
        XCTAssertEqual(rig.controller.phase, .working)
        rig.controller.mouseDown()
        await pump(until: { !rig.host.rescued.isEmpty })
        XCTAssertEqual(rig.host.rescued, ["hello world"], "a clicked-away finished sentence is kept")
        XCTAssertTrue(rig.host.inserted.isEmpty)

        let quiet = makeRig()
        await startCapture(quiet)
        XCTAssertEqual(quiet.controller.phase, .listening(""))
        quiet.controller.scrolled()
        XCTAssertEqual(quiet.controller.phase, .idle)
        XCTAssertTrue(quiet.host.transientNotices.isEmpty,
                      "a listening capture interrupted by the pointer stays silent")
    }

    /// An open IME composition refuses the capture outright: synthetic
    /// keystrokes land inside the marked text and garble or force-commit it.
    func testComposingFieldRefusesCapture() async {
        let rig = makeRig()
        rig.host.composing = true
        await holdDown(rig.controller)
        await pump(until: { !rig.host.transientNotices.isEmpty })
        XCTAssertEqual(rig.controller.phase, .idle)
        XCTAssertEqual(rig.capture.startCount, 0, "the microphone must never open")
        guard case .hint(let notice)? = rig.host.transientNotices.last else {
            return XCTFail("an IME refusal must be visible")
        }
        XCTAssertTrue(notice.contains("composing"), notice)
    }

    /// Starting a capture prepares the host, which cancels an in-flight ⌥⇥
    /// fix: its preview would land mid-capture and fight the listening pill.
    func testBeginPreparesTheHost() async {
        let rig = makeRig()
        await holdDown(rig.controller)
        await pump(until: { rig.host.prepares == 1 })
        XCTAssertEqual(rig.host.prepares, 1)
    }

    /// A hold that queued behind a finalize and was released before it
    /// resolved never opened the microphone — the spoken sentence is gone, and
    /// silence there reads as the feature eating it. Sentence one must still
    /// land; sentence two's loss must be said out loud.
    func testQueuedHoldReleasedBeforeInsertGetsNotice() async {
        let rig = makeRig { $0.finishDelay = 0.3 }
        await startCapture(rig)
        await hear("first sentence", in: rig)
        await release(rig.controller)
        XCTAssertEqual(rig.controller.phase, .working)
        // Second hold queues behind the write…
        await holdDown(rig.controller)
        // …and is released before the write resolves.
        await release(rig.controller)
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
        await release(rig.controller)
        await pump(until: { !rig.host.rescued.isEmpty })
        XCTAssertEqual(rig.host.rescued, ["hello world"])
        XCTAssertTrue(rig.host.inserted.isEmpty)

        let stays = makeRig()
        stays.host.focusIsInLauncher = true
        await startCapture(stays)
        await hear("weather tomorrow", in: stays)
        await release(stays.controller)
        await pump(until: { !stays.host.inserted.isEmpty })
        XCTAssertEqual(stays.host.inserted, ["hello world"])
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
        await release(rig.controller)
        await pump(until: { !rig.host.commands.isEmpty })
        XCTAssertEqual(rig.host.commands.map(\.instruction), ["hello world"])
        XCTAssertEqual(rig.host.commands.map(\.selection), ["the draft paragraph"])
        XCTAssertTrue(rig.host.inserted.isEmpty, "an instruction is never typed")
    }

    /// Off (the default), dictating over a selection types — replacing it.
    func testWithoutVoiceCommandsASelectionIsDictatedOver() async {
        let rig = makeRig()
        rig.host.anchor?.selectedText = "the draft paragraph"
        await startCapture(rig)
        await hear("hello world", in: rig)
        await release(rig.controller)
        await pump(until: { !rig.host.inserted.isEmpty })
        XCTAssertEqual(rig.host.inserted, ["hello world"])
        XCTAssertTrue(rig.host.commands.isEmpty)
    }

    /// An app switch fires two invalidations milliseconds apart (focus change,
    /// then resign-active). The second must not discard the finish the first
    /// one started — it would bump the generation and drop the transcript.
    func testAppSwitchDoubleInvalidateStillRescues() async {
        let rig = makeRig { $0.finishDelay = 0.2 }
        await startLatched(rig)
        await hear("a whole paragraph", in: rig)
        rig.host.focusGeneration += 1
        rig.controller.invalidate()
        rig.controller.invalidate()
        await pump(until: { !rig.host.rescued.isEmpty })
        XCTAssertEqual(rig.host.rescued, ["hello world"])
        XCTAssertTrue(rig.host.inserted.isEmpty)
    }

    /// Once the transcript is headed for the clipboard, a click or keystroke
    /// can't land it behind anything — it is kept. ⎋ still cancels.
    func testClickOrKeyDuringRescueKeepsTheTranscriptEscapeCancels() async {
        let rig = makeRig { $0.finishDelay = 0.2 }
        await startLatched(rig)
        await hear("a whole paragraph", in: rig)
        rig.host.focusGeneration += 1
        rig.controller.invalidate()
        XCTAssertEqual(rig.controller.phase, .working)
        rig.controller.mouseDown()
        rig.controller.keyPressed()
        await pump(until: { !rig.host.rescued.isEmpty })
        XCTAssertEqual(rig.host.rescued, ["hello world"])

        let cancelled = makeRig { $0.finishDelay = 0.2 }
        await startLatched(cancelled)
        await hear("never mind", in: cancelled)
        cancelled.host.focusGeneration += 1
        cancelled.controller.invalidate()
        cancelled.controller.keyPressed(isEscape: true)
        await pump(0.4)
        XCTAssertTrue(cancelled.host.rescued.isEmpty, "⎋ is a cancel, not a rescue")
        XCTAssertEqual(cancelled.controller.phase, .idle)
    }

    /// The rule that makes hands-free worth having. Under a hold, every one of
    /// these means "that was a chord, not talking" and kills the capture — and
    /// applied to a latch they would make it a hold with extra steps.
    func testTypingClickingAndScrollingLeaveAHandsFreeCaptureAlone() async {
        let rig = makeRig()
        await startLatched(rig)
        await hear("still going", in: rig)
        rig.controller.keyPressed()
        rig.controller.mouseDown()
        rig.controller.scrolled()
        await pump(0.05)
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
        rig.controller.keyPressed(isEscape: true)
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
        await holdDown(rig.controller)
        await pump(0.1)
        XCTAssertEqual(rig.capture.startCount, 1, "one capture, one microphone")
        XCTAssertEqual(rig.controller.phase, .listening(""))
        // And the release of that modifier must not end the latched capture.
        await release(rig.controller)
        XCTAssertEqual(rig.controller.phase, .listening(""))
        XCTAssertTrue(rig.host.inserted.isEmpty)
    }

    /// Silence is what stops a capture nobody is holding. It FINISHES rather
    /// than discards: the words were said, and making the user say them again
    /// because they paused too long is the worst possible answer.
    func testSilenceEndsAHandsFreeCaptureAndTypesWhatItHeard() async {
        Settings.dictationSilence = 0.15
        let rig = makeRig()
        rig.controller.silenceTick = 0.02
        await startLatched(rig)
        // A partial is what tells the meter someone spoke — without it the
        // capture is still inside the far longer opening budget.
        await hear("said something", in: rig)
        await pump(until: { !rig.host.inserted.isEmpty })
        XCTAssertEqual(rig.host.inserted, ["hello world"])
        XCTAssertEqual(rig.controller.phase, .idle)
    }

    /// Before the first word the budget is the long one. Someone who pressed
    /// the chord and is still gathering their thoughts has said nothing to
    /// measure, and holding them to a mid-sentence pause budget would break the
    /// feature for the long-form dictation it exists for.
    func testSilenceBeforeTheFirstWordGetsTheLongerBudget() async {
        Settings.dictationSilence = 0.05
        let rig = makeRig()
        rig.controller.silenceTick = 0.02
        rig.controller.openingSilenceSeconds = 5
        await startLatched(rig)
        await pump(0.3)
        XCTAssertEqual(rig.controller.phase, .listening(""),
                       "nothing said yet is not the same as having stopped talking")
    }

    /// A held key already says when the user is done. Cutting one short on a
    /// thinking pause would take away the single thing a hold is unambiguous
    /// about.
    func testAHeldCaptureIsNeverCutShortBySilence() async {
        Settings.dictationSilence = 0.05
        let rig = makeRig()
        rig.controller.silenceTick = 0.02
        await startCapture(rig)
        await hear("mid sentence", in: rig)
        await pump(0.3)
        XCTAssertEqual(rig.controller.phase, .listening("mid sentence"))
        XCTAssertTrue(rig.host.inserted.isEmpty)
    }

    /// The two ceilings mean different things: 120 s is a safety net under a
    /// key-up the event tap may have swallowed, which a latch has no need of.
    /// A latch bound by the hold's ceiling would cut a long dictation off at
    /// two minutes for a reason that does not apply to it.
    func testAHandsFreeCaptureRunsPastTheHoldCeiling() async {
        // 0.6 for the same reason `testCaptureCeilingFinishesInsteadOfDiscarding`
        // picks it: the short bound still covers `.preparing`, so anything
        // tighter races the two awaits before `.listening` on a loaded runner.
        let rig = makeRig()
        rig.controller.maxCaptureSeconds = 0.6
        rig.controller.maxLatchedSeconds = 5
        await startLatched(rig)
        await hear("a long one", in: rig)
        await pump(1.0)
        XCTAssertEqual(rig.controller.phase, .listening("a long one"))
        XCTAssertTrue(rig.host.inserted.isEmpty)
    }

    /// ...and it does have a ceiling of its own. Nothing was ever going to
    /// arrive to end a forgotten latch, so this is the only bound on it — and
    /// like the hold's, it finishes rather than discarding.
    func testAForgottenLatchStillHitsItsOwnCeiling() async {
        let rig = makeRig()
        rig.controller.maxLatchedSeconds = 0.15
        await startLatched(rig)
        await hear("left running", in: rig)
        await pump(until: { !rig.host.inserted.isEmpty })
        XCTAssertEqual(rig.host.inserted, ["hello world"])
        XCTAssertEqual(rig.controller.phase, .idle)
    }

    /// Pressed again while the last transcript is still being written down. A
    /// chord is its own toggle, so the second press takes the queued capture
    /// back off rather than stacking a third.
    func testAQueuedHandsFreeCaptureCanBeTakenBack() async {
        let rig = makeRig { $0.finishDelay = 0.3 }
        await startLatched(rig)
        await hear("first", in: rig)
        rig.controller.toggleLatch()
        XCTAssertEqual(rig.controller.phase, .working)
        rig.controller.toggleLatch()
        rig.controller.toggleLatch()
        await pump(until: { rig.controller.phase == .idle })
        XCTAssertEqual(rig.host.inserted, ["hello world"])
        XCTAssertEqual(rig.capture.startCount, 1, "the queued capture was taken back")
    }

    /// `.preparing` is inside the hands-free window, not outside it. Scoping
    /// the relaxed rules to `.listening` alone meant a scroll while the model
    /// was still coming down tore the capture apart with no pill and no notice
    /// — and "press the chord, then go and find what I was going to say" is
    /// the hands-free case exactly.
    func testInterruptsDuringAHandsFreeStartLeaveItAlone() async {
        let rig = makeRig()
        slowStart(rig, seconds: 0.3)
        rig.controller.toggleLatch()
        await pump(until: { rig.controller.phase == .preparing })
        rig.controller.scrolled()
        rig.controller.mouseDown()
        rig.controller.keyPressed()
        XCTAssertEqual(rig.controller.phase, .preparing,
                       "the wait for the microphone is still part of the capture")
        await pump(until: { rig.controller.phase == .listening("") })
        XCTAssertEqual(rig.controller.phase, .listening(""))
        XCTAssertEqual(rig.capture.startCount, 1)
    }

    /// ...and ⎋ during that same wait is still an explicit cancel, with the
    /// wording Settings promises rather than a silent teardown.
    func testEscapeDuringAHandsFreeStartSaysCancelled() async {
        let rig = makeRig()
        slowStart(rig, seconds: 0.3)
        rig.controller.toggleLatch()
        await pump(until: { rig.controller.phase == .preparing })
        rig.controller.keyPressed(isEscape: true)
        await pump(until: { rig.controller.phase == .idle })
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
        let rig = makeRig { $0.finishDelay = 0.2 }
        rig.controller.modifierChanged(modifierEvent(down: true))
        rig.controller.toggleLatch()
        await pump(until: { rig.controller.phase == .listening("") })
        // Until the arm timer has fired: its `.begin`, swallowed under the
        // latch, disarms the hold.
        await pump(until: { !rig.controller.isHoldArmed })
        XCTAssertEqual(rig.controller.phase, .listening(""))
        XCTAssertEqual(rig.capture.startCount, 1, "one capture, not two")
        await hear("the whole paragraph", in: rig)
        rig.controller.toggleLatch()
        XCTAssertEqual(rig.controller.phase, .working)
        // ⌃ lifts before ⌥ — the coin flip that used to end in a cancel.
        rig.controller.modifierChanged(modifierEvent(key: KeyCode.leftControl, flag: .maskControl, down: false))
        rig.controller.modifierChanged(modifierEvent(down: false))
        await pump(until: { !rig.host.inserted.isEmpty })
        XCTAssertEqual(rig.host.inserted, ["hello world"],
                       "letting go of a modifier must not cancel what was already said")
    }

    /// The pre-first-word budget belongs to the microphone being open, not to
    /// the keypress. The meter has to be built before the capture starts, but
    /// measured from there a first-use language-pack download spends the whole
    /// budget before a word can be said — and the first check after the wait
    /// ends the capture as "nothing heard".
    func testTheOpeningSilenceBudgetStartsWhenTheMicrophoneDoes() async {
        Settings.dictationSilence = 5
        let rig = makeRig()
        rig.controller.silenceTick = 0.02
        // The wait outlasts the budget, and the check after it sits 0.8 s
        // inside the budget, so a slow runner can't spend it for the speaker.
        rig.controller.openingSilenceSeconds = 1.0
        slowStart(rig, seconds: 1.2)
        rig.controller.toggleLatch()
        await pump(until: { rig.controller.phase == .listening("") })
        await pump(0.2)
        XCTAssertEqual(rig.controller.phase, .listening(""),
                       "the wait for the model must not be charged to the speaker")
    }

    /// ⎋ has to mean cancelled, not paused. A second press of the chord during
    /// the write-down queues another capture, and the resume that honours it
    /// runs from `discard` too — so without an explicit rule the microphone
    /// re-opens on the far side of the cancel, and `begin`'s repaint wipes the
    /// "dictation cancelled" pill on its way past.
    func testCancellingAQueuedHandsFreeCaptureDoesNotReopenTheMicrophone() async {
        let rig = makeRig { $0.finishDelay = 0.4 }
        await startLatched(rig)
        await hear("first", in: rig)
        rig.controller.toggleLatch()
        XCTAssertEqual(rig.controller.phase, .working)
        rig.controller.toggleLatch()
        rig.controller.keyPressed(isEscape: true)
        await pump(until: { rig.controller.phase == .idle })
        await pump(0.2)
        XCTAssertEqual(rig.controller.phase, .idle, "⎋ means cancelled, not paused")
        XCTAssertEqual(rig.capture.startCount, 1, "the microphone must not re-open after a cancel")
        XCTAssertTrue(rig.host.inserted.isEmpty)
    }

    /// The same rule for a focus change: it ends the capture *and* the queue
    /// behind it, rather than opening the microphone in the app just moved to.
    func testAFocusChangeDoesNotHandTheQueuedCaptureToTheNextApp() async {
        let rig = makeRig { $0.finishDelay = 0.4 }
        await startLatched(rig)
        await hear("first", in: rig)
        rig.controller.toggleLatch()
        rig.controller.toggleLatch()
        rig.controller.invalidate()
        await pump(until: { rig.controller.phase == .idle })
        await pump(0.2)
        XCTAssertEqual(rig.capture.startCount, 1)
        XCTAssertEqual(rig.controller.phase, .idle)
    }

    /// Standing down from the interrupts is about the LISTENING window. Once
    /// the chord has been pressed again and the words are being written down,
    /// a click has moved the caret they are about to be typed at — so they go
    /// to the clipboard instead, whatever started the capture.
    func testAClickWhileWritingAHandsFreeTranscriptDownRescuesIt() async {
        let rig = makeRig { $0.finishDelay = 0.4 }
        await startLatched(rig)
        await hear("about to land", in: rig)
        rig.controller.toggleLatch()
        XCTAssertEqual(rig.controller.phase, .working)
        rig.controller.mouseDown()
        await pump(until: { rig.controller.phase == .idle })
        XCTAssertTrue(rig.host.inserted.isEmpty,
                      "the caret moved — the transcript must not follow it")
        XCTAssertEqual(rig.host.rescued, ["hello world"], "minutes of speech are kept, not dropped")
    }

    /// A latched capture's long ceiling is about how long someone may SPEAK.
    /// Applied to a session that never opened it would leave "starting
    /// dictation…" on screen for ten minutes with the completion pipeline
    /// suppressed behind `isBusy` the whole time.
    func testAHungHandsFreeStartGivesUpOnTheShortCeiling() async {
        let rig = makeRig()
        rig.controller.maxCaptureSeconds = 0.15
        rig.controller.maxLatchedSeconds = 30
        rig.controller.gates.startSession = { _, _ in
            // Far past the wait below, so only the short ceiling can end it.
            try await Task.sleep(nanoseconds: 60_000_000_000)
            throw AudioCapture.Failure.sessionFailed("never reached")
        }
        rig.controller.toggleLatch()
        await pump(until: { rig.controller.phase == .preparing })
        await pump(until: { rig.controller.phase == .idle })
        XCTAssertEqual(rig.controller.phase, .idle,
                       "a hung start wedges the whole pipeline — the long ceiling is not for it")
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
