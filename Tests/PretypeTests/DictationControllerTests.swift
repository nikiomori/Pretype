import AVFoundation
import CoreAudio
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

    func start(
        deviceUID: String?,
        outputFormat: AVAudioFormat?,
        onDeviceChange: @escaping @Sendable () -> Void,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) async throws {
        if failStart { throw AudioCapture.Failure.noInputDevice }
        startCount += 1
        self.onDeviceChange = onDeviceChange
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
    var fallbackCaretRect: CGRect?
    var fallbackHostStyle = HostTextStyle()
    var onDictationActivity: (() -> Void)?

    var hasField = true
    var composing = false
    var anchor: DictationAnchor? = DictationAnchor(
        caretRect: CGRect(x: 10, y: 10, width: 1, height: 18),
        host: HostTextStyle(), textBeforeCaret: "")
    private(set) var inserted: [String] = []
    private(set) var transientNotices: [SuggestionDisplayMode] = []
    private(set) var shownModes: [SuggestionDisplayMode] = []
    private(set) var hideCount = 0
    private(set) var cancelledFixes = 0
    var tidy: ((String) -> String?)?
    var tidyDelay: TimeInterval = 0

    func hasFocusedTextField() -> Bool { hasField }
    func isComposingInFocusedField() -> Bool { composing }
    func cancelPendingFix() { cancelledFixes += 1 }
    func dictationAnchor() -> DictationAnchor? { anchor }
    func clearActiveCompletion() {}
    func stopProgressIndicator() {}
    func noteCaret(rect: CGRect, host: HostTextStyle) {}
    func showOverlay(_ mode: SuggestionDisplayMode, at rect: CGRect, host: HostTextStyle) {
        shownModes.append(mode)
    }
    func showTransientOverlay(_ mode: SuggestionDisplayMode, at rect: CGRect, host: HostTextStyle) {
        transientNotices.append(mode)
    }
    func hideOverlay() { hideCount += 1 }
    func insertDictated(_ text: String) { inserted.append(text) }
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

    override func setUp() {
        super.setUp()
        savedEnabled = Settings.enabled
        savedDictation = Settings.dictationEnabled
        savedGesture = Settings.dictationGesture
        savedPolish = Settings.dictationPolish
        Settings.enabled = true
        Settings.dictationEnabled = true
        Settings.dictationGesture = .option
        Settings.dictationPolish = false
    }

    override func tearDown() {
        Settings.enabled = savedEnabled
        Settings.dictationEnabled = savedDictation
        Settings.dictationGesture = savedGesture
        Settings.dictationPolish = savedPolish
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
        controller.gates.micGranted = { true }
        controller.gates.micStatus = { .authorized }
        controller.gates.transcriptionSupported = { true }
        controller.gates.startSession = { _, onPartial in
            session.onPartial = onPartial
            return session
        }
        return Rig(controller: controller, host: host, capture: capture, session: session)
    }

    /// A `.flagsChanged`-shaped event: `modifierChanged` only reads the keycode
    /// field and the flags, so a keyboard event carrying them is enough.
    private func optionEvent(down: Bool) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(KeyCode.leftOption),
                            keyDown: down)!
        event.flags = down ? .maskAlternate : []
        return event
    }

    /// Spin the main run loop so `Timer`s fire and queued MainActor tasks run.
    private func pump(_ seconds: TimeInterval) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
            await Task.yield()
        }
    }

    /// Pump until `condition` holds. A fixed margin that holds locally loses
    /// by an order of magnitude on a loaded CI runner — each `Task { @MainActor }`
    /// hop can take longer there than a whole 0.1 s pump window — so waits on
    /// the controller's async paths are stated as the condition they wait FOR.
    /// The deadline only bounds a genuine wedge: the assertions right after
    /// still run, and name the wedged state.
    private func pump(until condition: () -> Bool, timeout: TimeInterval = 2) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
            await Task.yield()
        }
    }

    /// Press the dictation key and wait out the (shortened) hold threshold.
    private func holdDown(_ controller: DictationController) async {
        controller.modifierChanged(optionEvent(down: true))
        await pump(0.12)
    }

    private func release(_ controller: DictationController) async {
        controller.modifierChanged(optionEvent(down: false))
        await pump(0.05)
    }

    // MARK: - Tests

    func testCaptureToInsertion() async {
        let rig = makeRig()
        await holdDown(rig.controller)
        XCTAssertEqual(rig.controller.phase, .listening(""))
        XCTAssertEqual(rig.capture.startCount, 1)
        rig.session.onPartial?("say someth")
        await pump(0.03)
        XCTAssertEqual(rig.controller.phase, .listening("say someth"))
        await release(rig.controller)
        await pump(0.1)
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
        await holdDown(rig.controller)
        XCTAssertEqual(rig.controller.phase, .listening(""))
        XCTAssertTrue(rig.host.shownModes.contains { if case .listening = $0 { return true }
                                                     return false },
                      "a capture with no readable caret still has to look like one")
        rig.session.onPartial?("слышу")
        await pump(0.03)
        guard case .listening(let text)? = rig.host.shownModes.last else {
            return XCTFail("partials must keep repainting the pill")
        }
        XCTAssertEqual(text, "слышу")
    }

    func testFocusChangeDropsTranscript() async {
        let rig = makeRig()
        await holdDown(rig.controller)
        rig.session.onPartial?("meant for the other field")
        await pump(0.03)
        // Only the generation guard is under test here — the live app also
        // calls `invalidate()` on a real focus change.
        rig.host.focusGeneration += 1
        await release(rig.controller)
        await pump(0.1)
        XCTAssertTrue(rig.host.inserted.isEmpty)
        XCTAssertEqual(rig.controller.phase, .idle)
    }

    func testKeystrokeDuringFinalizeDiscardsWithNotice() async {
        let rig = makeRig { $0.finishDelay = 0.3 }
        await holdDown(rig.controller)
        rig.session.onPartial?("about to vanish")
        await pump(0.03)
        await release(rig.controller)
        XCTAssertEqual(rig.controller.phase, .working)
        rig.controller.keyPressed()
        XCTAssertEqual(rig.controller.phase, .idle)
        guard case .hint(let notice)? = rig.host.transientNotices.last else {
            return XCTFail("a silently vanished sentence reads as a broken feature")
        }
        XCTAssertTrue(notice.contains("kept typing"), notice)
        await pump(0.4)
        XCTAssertTrue(rig.host.inserted.isEmpty)
    }

    func testSecondHoldQueuesBehindFinalize() async {
        let rig = makeRig { $0.finishDelay = 0.25 }
        await holdDown(rig.controller)
        rig.session.onPartial?("first sentence")
        await pump(0.03)
        await release(rig.controller)
        XCTAssertEqual(rig.controller.phase, .working)
        // Second hold while the first transcript is still being written down:
        // queued, not started — and NOT silently dropped either way.
        await holdDown(rig.controller)
        XCTAssertEqual(rig.controller.phase, .working)
        XCTAssertEqual(rig.capture.startCount, 1)
        await pump(0.4)
        XCTAssertEqual(rig.host.inserted, ["hello world"])
        XCTAssertTrue(rig.controller.isCapturing, "the queued hold must start once the insert lands")
        XCTAssertEqual(rig.capture.startCount, 2)
    }

    func testDeviceChangeWithoutPinnedFormatFinishes() async {
        let rig = makeRig()  // audioFormat nil: restart-in-place is unsound
        await holdDown(rig.controller)
        await pump(until: { rig.controller.phase == .listening("") })
        rig.session.onPartial?("already heard")
        await pump(until: { rig.controller.phase == .listening("already heard") })
        rig.capture.onDeviceChange?()
        await pump(until: { !rig.host.inserted.isEmpty })
        XCTAssertEqual(rig.host.inserted, ["hello world"],
                       "words already heard must be typed, not thrown away")
        XCTAssertEqual(rig.controller.phase, .idle)
    }

    func testDeviceLossHeardNothingFails() async {
        let rig = makeRig()
        await holdDown(rig.controller)
        await pump(until: { rig.controller.phase == .listening("") })
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
        await holdDown(rig.controller)
        await pump(until: { rig.controller.phase == .listening("") })
        rig.session.onPartial?("keep going")
        await pump(until: { rig.controller.phase == .listening("keep going") })
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
        await holdDown(rig.controller)
        await pump(until: { rig.controller.phase == .listening("") })
        rig.session.onPartial?("что-то услышал")
        await pump(until: { rig.controller.phase == .listening("что-то услышал") })
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

    func testReleaseDuringPreparingCancelsSessionOnArrival() async {
        let rig = makeRig()
        let session = rig.session
        rig.controller.gates.startSession = { _, onPartial in
            try await Task.sleep(nanoseconds: 200_000_000)
            session.onPartial = onPartial
            return session
        }
        rig.controller.modifierChanged(optionEvent(down: true))
        await pump(0.08)
        XCTAssertEqual(rig.controller.phase, .preparing)
        await release(rig.controller)
        XCTAssertEqual(rig.controller.phase, .idle)
        XCTAssertEqual(rig.capture.startCount, 0)
        await pump(0.3)
        // The download task was left running on purpose; the session it
        // produced belongs to a discarded capture and dies on arrival.
        XCTAssertEqual(session.cancelCount, 1)
        XCTAssertEqual(rig.capture.startCount, 0)
    }

    func testSecureInputRefusesBeforeOpeningMic() async {
        let rig = makeRig()
        rig.controller.gates.secureInput = { true }
        await holdDown(rig.controller)
        XCTAssertEqual(rig.controller.phase, .idle)
        XCTAssertEqual(rig.capture.startCount, 0)
        guard case .hint? = rig.host.transientNotices.last else {
            return XCTFail("secure input should refuse with a visible hint")
        }
    }

    func testPolishPastBudgetFallsBackToRawTranscript() async {
        let saved = DictationController.polishSeconds
        DictationController.polishSeconds = 0.05
        defer { DictationController.polishSeconds = saved }
        Settings.dictationPolish = true
        let rig = makeRig()
        rig.host.tidy = { _ in "Polished." }
        rig.host.tidyDelay = 0.5
        await holdDown(rig.controller)
        rig.session.onPartial?("x")
        await pump(0.03)
        await release(rig.controller)
        await pump(0.3)
        XCTAssertEqual(rig.host.inserted, ["hello world"],
                       "a slow tidy-up must not hold the sentence hostage")
    }

    func testPolishAppliesWithinBudget() async {
        Settings.dictationPolish = true
        let rig = makeRig()
        rig.host.tidy = { _ in "Hello, world." }
        await holdDown(rig.controller)
        rig.session.onPartial?("x")
        await pump(0.03)
        await release(rig.controller)
        await pump(0.15)
        XCTAssertEqual(rig.host.inserted, ["Hello, world."])
    }

    func testEscapeDuringFinalizeSaysCancelled() async {
        let rig = makeRig { $0.finishDelay = 0.3 }
        await holdDown(rig.controller)
        rig.session.onPartial?("never mind")
        await pump(0.03)
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
        let saved = DictationController.finalizeSeconds
        DictationController.finalizeSeconds = 0.1
        defer { DictationController.finalizeSeconds = saved }
        let rig = makeRig { $0.finishDelay = 5 }
        await holdDown(rig.controller)
        rig.session.onPartial?("x")
        await pump(0.03)
        await release(rig.controller)
        await pump(0.4)
        XCTAssertEqual(rig.controller.phase, .idle, "a hung finalize must not wedge the pill")
        XCTAssertTrue(rig.host.inserted.isEmpty)
        guard case .error(let why)? = rig.host.transientNotices.last else {
            return XCTFail("the watchdog should surface an error")
        }
        XCTAssertTrue(why.contains("timed out"), why)
    }

    /// Which microphone a capture opens. The rule exists because a Bluetooth
    /// headset carries good playback OR a two-way call, never both: opening the
    /// AirPods microphone drops whatever is playing into hands-free quality for
    /// the length of the hold. Reported from real use as "the music goes dull
    /// while I dictate".
    func testAutomaticInputAvoidsTheHeadsetItIsPlayingThrough() {
        // Exactly the shape of the reporting machine: macOS publishes AirPods
        // as two objects whose UIDs share everything before the colon.
        let builtIn = AudioDevices.Device(id: 98, uid: "BuiltInMicrophoneDevice",
                                          name: "MacBook Pro Microphone",
                                          transport: kAudioDeviceTransportTypeBuiltIn)
        let podsIn = AudioDevices.Device(id: 111, uid: "F8-D3-F0-79-64-02:input",
                                         name: "AirPods Pro",
                                         transport: kAudioDeviceTransportTypeBluetooth)
        let podsOut = AudioDevices.Device(id: 105, uid: "F8-D3-F0-79-64-02:output",
                                          name: "AirPods Pro",
                                          transport: kAudioDeviceTransportTypeBluetooth)
        let usbMic = AudioDevices.Device(id: 120, uid: "USB-Yeti", name: "Yeti",
                                         transport: kAudioDeviceTransportTypeUSB)
        let speakers = AudioDevices.Device(id: 91, uid: "BuiltInSpeakerDevice",
                                           name: "MacBook Pro Speakers",
                                           transport: kAudioDeviceTransportTypeBuiltIn)
        let inputs = [builtIn, podsIn, usbMic]

        func auto(_ input: AudioDevices.Device?, _ output: AudioDevices.Device?) -> AudioDevices.Device? {
            AudioDevices.resolve(preference: .automatic, inputs: inputs,
                                 defaultInput: input, defaultOutput: output)
        }
        // Listening through the same headset you'd record from: step aside.
        XCTAssertEqual(auto(podsIn, podsOut), builtIn)
        // Same headset for the microphone but sound coming out of the speakers:
        // nothing to protect, record where the user pointed us.
        XCTAssertEqual(auto(podsIn, speakers), podsIn)
        // A wired microphone never had this problem.
        XCTAssertEqual(auto(usbMic, podsOut), usbMic)
        XCTAssertEqual(auto(builtIn, podsOut), builtIn)

        // An explicit pick always wins — including picking the headset back.
        XCTAssertEqual(
            AudioDevices.resolve(preference: .device(uid: podsIn.uid), inputs: inputs,
                                 defaultInput: podsIn, defaultOutput: podsOut),
            podsIn)
        XCTAssertEqual(
            AudioDevices.resolve(preference: .systemDefault, inputs: inputs,
                                 defaultInput: podsIn, defaultOutput: podsOut),
            podsIn)
        // A pinned device that is unplugged right now falls back rather than
        // refusing to record.
        XCTAssertEqual(
            AudioDevices.resolve(preference: .device(uid: "gone"), inputs: inputs,
                                 defaultInput: podsIn, defaultOutput: podsOut),
            podsIn)
        // The stored form round-trips, and an empty default reads as automatic.
        XCTAssertEqual(AudioDevices.Preference(stored: ""), .automatic)
        XCTAssertEqual(AudioDevices.Preference(stored: "auto").stored, "auto")
        XCTAssertEqual(AudioDevices.Preference(stored: podsIn.uid), .device(uid: podsIn.uid))
    }

    /// The gate the dictation tidy-up asks before spending its budget: it must
    /// answer "would this go to the network", not "is the model resident".
    /// Anything with no Hugging Face cache directory of its own — the Apple
    /// Intelligence pseudo-id, a local fine-tune folder — is already on the
    /// machine and must never be treated as an unfetched download.
    func testCorrectionFetchGateAnswersForLocalIDs() {
        XCTAssertTrue(ModelStorage.isFetched(ModelCatalog.appleIntelligenceID))
        XCTAssertTrue(ModelStorage.isFetched("/Users/someone/models/my-finetune"))
        XCTAssertFalse(ModelStorage.isFetched("pretype-test/definitely-not-downloaded"))
    }

    /// The gate has to fail closed on a download IN FLIGHT, which is the whole
    /// point: the hub populates `snapshots/<rev>/` file by file, so the
    /// directory shows up as soon as a few-kilobyte config.json lands, with
    /// gigabytes of weights still on the wire — and an abandoned fetch leaves
    /// exactly that state behind, with no partial-file residue to spot it by.
    func testFetchGateReadsTheWeightsNotTheDirectory() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pretype-fetch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        @discardableResult
        func repo(_ name: String, revision revisionName: String = "rev1",
                  files: [String: String] = [:], danglingLinks: [String] = [],
                  head: String? = nil) throws -> URL {
            let directory = root.appendingPathComponent(name)
            let revision = directory.appendingPathComponent("snapshots/\(revisionName)")
            try FileManager.default.createDirectory(at: revision, withIntermediateDirectories: true)
            for (file, contents) in files {
                try contents.write(to: revision.appendingPathComponent(file),
                                   atomically: true, encoding: .utf8)
            }
            for link in danglingLinks {
                // What a snapshot entry looks like before its blob is copied in.
                try FileManager.default.createSymbolicLink(
                    at: revision.appendingPathComponent(link),
                    withDestinationURL: directory.appendingPathComponent("blobs/not-here-yet"))
            }
            if let head {
                let refs = directory.appendingPathComponent("refs")
                try FileManager.default.createDirectory(at: refs, withIntermediateDirectories: true)
                try head.write(to: refs.appendingPathComponent("main"),
                               atomically: true, encoding: .utf8)
            }
            return directory
        }

        let index = #"{"weight_map":{"a":"model-00001-of-00002.safetensors","b":"model-00002-of-00002.safetensors"}}"#
        // Only the config has landed — a download in flight, or one abandoned.
        XCTAssertFalse(ModelStorage.isFetched(
            at: try repo("config-only", files: ["config.json": "{}"])))
        // Sharded, one shard still coming.
        XCTAssertFalse(ModelStorage.isFetched(at: try repo("half", files: [
            "config.json": "{}", "model.safetensors.index.json": index,
            "model-00001-of-00002.safetensors": "w",
        ])))
        // Both shards present: ready.
        XCTAssertTrue(ModelStorage.isFetched(at: try repo("whole", files: [
            "config.json": "{}", "model.safetensors.index.json": index,
            "model-00001-of-00002.safetensors": "w", "model-00002-of-00002.safetensors": "w",
        ])))
        // A snapshot link whose blob has not been copied in yet resolves to
        // nothing — `fileExists` follows it, which is why that is the test.
        XCTAssertFalse(ModelStorage.isFetched(at: try repo(
            "dangling",
            files: ["config.json": "{}", "model.safetensors.index.json": #"{"weight_map":{"a":"model.safetensors"}}"#],
            danglingLinks: ["model.safetensors"])))
        // No shard index at all — a single-file repo is ready on its weights.
        XCTAssertTrue(ModelStorage.isFetched(
            at: try repo("single", files: ["config.json": "{}", "model.safetensors": "w"])))
        // Nothing there at all.
        XCTAssertFalse(ModelStorage.isFetched(at: root.appendingPathComponent("absent")))

        // A second revision holding only metadata — what another tool sharing
        // this cache leaves behind with one `hf_hub_download(repo, "config.json")`
        // at a different sha. The complete revision must still answer, whichever
        // order the filesystem lists them in: reading the stray one would report
        // a fully downloaded model as missing, and the answer is latched.
        let shared = try repo("shared-cache", revision: "aaa-metadata-only",
                              files: ["config.json": "{}"])
        try repo("shared-cache", revision: "bbb-complete",
                 files: ["config.json": "{}", "model.safetensors": "w"])
        XCTAssertTrue(ModelStorage.isFetched(at: shared))

        // With `refs/main` present it decides, so a re-converted head still
        // downloading is not masked by the complete revision it replaces.
        let rolling = try repo("rolling", revision: "old-complete",
                               files: ["config.json": "{}", "model.safetensors": "w"])
        try repo("rolling", revision: "new-head", files: ["config.json": "{}"],
                 head: "new-head")
        XCTAssertFalse(ModelStorage.isFetched(at: rolling))
    }

    /// The keyboard gates ask what the window is SHOWING, not whether it is
    /// visible — the difference is whether ⇥ can insert text that something
    /// else (a dictation notice, an engine status) has covered up.
    func testOverlayOwnershipGates() {
        XCTAssertTrue(SuggestionWindow.offersSuggestion(.suggestion("inute")))
        XCTAssertTrue(SuggestionWindow.offersCorrection(.fixPreview("receive")))
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
        XCTAssertFalse(SuggestionWindow.offersSuggestion(.fixPreview("receive")))
    }

    func testWatchdogAbandonsUncancellableFinalize() async {
        let saved = DictationController.finalizeSeconds
        DictationController.finalizeSeconds = 0.1
        defer { DictationController.finalizeSeconds = saved }
        let rig = makeRig { $0.uncancellableFinishDelay = 1.0 }
        await holdDown(rig.controller)
        rig.session.onPartial?("x")
        await pump(0.03)
        await release(rig.controller)
        // Well before the 1 s hang resolves: the deadline must not wait for a
        // finalize that ignores cancellation.
        await pump(0.4)
        XCTAssertEqual(rig.controller.phase, .idle,
                       "an uncancellable hang must still trip the watchdog")
        XCTAssertTrue(rig.host.inserted.isEmpty)
        guard case .error(let why)? = rig.host.transientNotices.last else {
            return XCTFail("the watchdog should surface an error")
        }
        XCTAssertTrue(why.contains("timed out"), why)
    }

    /// Invariant 1, enforced by a test instead of convention: the transcript
    /// must never reach the log or the diagnostics line — the debug buffer is
    /// exportable for bug reports, and what was said aloud is as sensitive as
    /// the clipboard. Counts are fine; words are not.
    func testTranscriptNeverReachesLogsOrLastEvent() async {
        let spoken = "zanzibar-confidential-sentence"
        let rig = makeRig { $0.transcript = spoken }
        let before = DebugLog.shared.snapshot().count
        await holdDown(rig.controller)
        rig.session.onPartial?(spoken)
        await pump(0.03)
        await release(rig.controller)
        await pump(0.1)
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
        let saved = DictationController.maxCaptureSeconds
        DictationController.maxCaptureSeconds = 0.15
        defer { DictationController.maxCaptureSeconds = saved }
        let rig = makeRig()
        await holdDown(rig.controller)
        XCTAssertEqual(rig.controller.phase, .listening(""))
        rig.session.onPartial?("still talking")
        // Never released — the ceiling has to end it alone.
        await pump(0.4)
        XCTAssertEqual(rig.controller.phase, .idle)
        XCTAssertEqual(rig.host.inserted, ["hello world"],
                       "the ceiling must finish, not discard")
    }

    /// The same ceiling covers `.preparing`: a hung session start with the
    /// release never delivered must not say "starting dictation…" forever
    /// while suppressing the completion pipeline. Nothing was heard, so this
    /// one discards — with a notice.
    func testPreparingCeilingDiscardsAHungStart() async {
        let saved = DictationController.maxCaptureSeconds
        DictationController.maxCaptureSeconds = 0.15
        defer { DictationController.maxCaptureSeconds = saved }
        let rig = makeRig()
        rig.controller.gates.startSession = { _, _ in
            try await Task.sleep(nanoseconds: 2_000_000_000)
            throw AudioCapture.Failure.sessionFailed("never reached")
        }
        await holdDown(rig.controller)
        XCTAssertEqual(rig.controller.phase, .preparing)
        await pump(0.4)
        XCTAssertEqual(rig.controller.phase, .idle,
                       "a hung start must not wedge `.preparing`")
        guard case .error? = rig.host.transientNotices.last else {
            return XCTFail("giving up on a hold deserves a visible notice")
        }
    }

    /// A click mid-`.working` discards a *finished* sentence — that earns the
    /// same notice a keystroke gets. Mid-`.listening` it stays silent: the
    /// pill vanishing under the click is its own explanation.
    func testPointerDuringWorkingShowsNoticeListeningStaysSilent() async {
        let rig = makeRig { $0.finishDelay = 0.3 }
        await holdDown(rig.controller)
        rig.session.onPartial?("about to vanish")
        await pump(0.03)
        await release(rig.controller)
        XCTAssertEqual(rig.controller.phase, .working)
        rig.controller.mouseDown()
        XCTAssertEqual(rig.controller.phase, .idle)
        guard case .hint(let notice)? = rig.host.transientNotices.last else {
            return XCTFail("a clicked-away finished sentence must say where it went")
        }
        XCTAssertTrue(notice.contains("caret moved"), notice)
        await pump(0.4)
        XCTAssertTrue(rig.host.inserted.isEmpty)

        let quiet = makeRig()
        await holdDown(quiet.controller)
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
        XCTAssertEqual(rig.controller.phase, .idle)
        XCTAssertEqual(rig.capture.startCount, 0, "the microphone must never open")
        guard case .hint(let notice)? = rig.host.transientNotices.last else {
            return XCTFail("an IME refusal must be visible")
        }
        XCTAssertTrue(notice.contains("composing"), notice)
    }

    /// Starting a capture cancels an in-flight ⌥⇥ fix: its preview would land
    /// mid-capture and fight the listening pill for the window.
    func testBeginCancelsPendingFix() async {
        let rig = makeRig()
        await holdDown(rig.controller)
        XCTAssertEqual(rig.host.cancelledFixes, 1)
    }

    /// A hold that queued behind a finalize and was released before it
    /// resolved never opened the microphone — the spoken sentence is gone, and
    /// silence there reads as the feature eating it. Sentence one must still
    /// land; sentence two's loss must be said out loud.
    func testQueuedHoldReleasedBeforeInsertGetsNotice() async {
        let rig = makeRig { $0.finishDelay = 0.3 }
        await holdDown(rig.controller)
        rig.session.onPartial?("first sentence")
        await pump(0.03)
        await release(rig.controller)
        XCTAssertEqual(rig.controller.phase, .working)
        // Second hold queues behind the write…
        await holdDown(rig.controller)
        // …and is released before the write resolves.
        await release(rig.controller)
        await pump(0.5)
        XCTAssertEqual(rig.host.inserted, ["hello world"])
        guard case .hint(let notice)? = rig.host.transientNotices.last else {
            return XCTFail("a swallowed queued hold must be said out loud")
        }
        XCTAssertTrue(notice.contains("wasn't listening"), notice)
    }

    /// The no-index branch of the fetch gate has the same dangling-symlink
    /// hole the indexed branch was already tested for: a single-file repo
    /// mid-download IS a dangling `model.safetensors` link, and answering
    /// "fetched" there sends the tidy-up into the very stall the gate exists
    /// to prevent.
    func testFetchGateNoIndexBranchChecksTheLinkResolves() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pretype-fetch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let revision = root.appendingPathComponent("snapshots/rev1")
        try FileManager.default.createDirectory(at: revision, withIntermediateDirectories: true)
        try "{}".write(to: revision.appendingPathComponent("config.json"),
                       atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: revision.appendingPathComponent("model.safetensors"),
            withDestinationURL: root.appendingPathComponent("blobs/not-here-yet"))
        XCTAssertFalse(ModelStorage.isFetched(at: root),
                       "a dangling single-file weight link is a download in flight")
    }
}
