import AVFoundation
import CoreMedia

/// Microphone permission, kept apart from the capture itself so the settings
/// surface can ask for it — and report a refusal — before anything opens the
/// input device.
///
/// macOS kills a process that touches the microphone without
/// `NSMicrophoneUsageDescription` in its bundle, and a bare `swift run` binary
/// has no Info.plist at all, so `isAvailable` gates the whole feature on being
/// a real .app (same rule, and same reason, as `LoginItem.isSupported`).
enum MicrophoneAccess {
    static var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static var status: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    /// Prompts only on `.notDetermined`: once answered, `requestAccess`
    /// returns the cached status without a prompt, because macOS never
    /// re-prompts.
    static func request() async -> Bool {
        guard isBundled else { return false }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Deep link to the pane where a refusal is reversed.
    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
}

/// Push-to-talk microphone capture: opens the chosen input while the user
/// holds the dictation key, resamples every buffer into the format the
/// transcriber asked for, and hands it straight over.
///
/// Built on `AVCaptureSession`, NOT `AVAudioEngine`, and with a Bluetooth
/// headset in the room that difference is the whole feature. Merely
/// INSTANTIATING an engine and touching `inputNode` builds an aggregate device
/// around the system-default input and output ("CADefaultDeviceAggregate") —
/// with AirPods on both ends, that alone halved the headset's output volume
/// (hands-free attenuation, 0.250 → 0.125, measured with no tap installed and
/// the engine never started) and handed it back changed on release. An engine
/// built and released per capture therefore made music breathe
/// quieter-then-louder around every single hold, and no device selection could
/// help: the damage was done before a device could be named. (Pointing the
/// shared engine unit somewhere safe afterwards has its own failure — a
/// one-directional device on it reads back as device 0 and `engine.start()`
/// throws `com.apple.coreaudio.avfaudio` — which is how the first repair
/// attempt shipped broken.) A capture session opens exactly one device, the
/// microphone it was given, and has no output side to disturb.
///
/// Deliberately dumb — no voice-activity detection, no ring buffer, no file on
/// disk. Nothing is captured unless the key is down, and the samples exist only
/// for as long as the callback runs: whatever a dictation feature is allowed to
/// be, "an app that can open the microphone whenever it likes" isn't it.
@MainActor
final class AudioCapture {
    enum Failure: LocalizedError {
        case noInputDevice
        case unusableFormat
        case deviceChanged
        case sessionFailed(String)

        var errorDescription: String? {
            switch self {
            case .noInputDevice: return String(localized: "no microphone found")
            case .unusableFormat: return String(localized: "the microphone format can't be converted")
            case .deviceChanged: return String(localized: "the microphone went away")
            case .sessionFailed(let why): return why
            }
        }
    }

    /// Built per capture and RELEASED by `stop()` — never held across
    /// captures, so the microphone (and the orange indicator that follows it)
    /// is handed back the moment the key comes up, with nothing left alive to
    /// keep the device claimed.
    private var session: AVCaptureSession?
    /// The capture's delivery path — see `Sink`. Held so it outlives the
    /// session that calls into it; released in `stop()` after delivery is
    /// unhooked.
    private var sink: Sink?
    /// Tokens for the device-loss observers. Main-thread-only state, like
    /// `session`: set in `start`, cleared in `stop`, and both of those only
    /// ever run on the main thread.
    private var observers: [NSObjectProtocol] = []
    /// Where `startRunning()`/`stopRunning()` actually run. Both are documented
    /// blocking calls — a Bluetooth microphone negotiates its hands-free
    /// profile for 0.5–2 s at open — and the main thread they would otherwise
    /// block is the one the event tap's run loop lives on: blocking it stalls
    /// every keyboard event on the system and can trip
    /// `kCGEventTapDisabledByTimeout`. Serial, so a start and the stop that
    /// follows it can never run out of order.
    private let sessionQueue = DispatchQueue(label: "app.pretype.dictation.session")

    /// Nonisolated so `DictationController.init`'s default argument — which
    /// Swift evaluates outside the actor — can build one; every stored
    /// property has a nonisolated default.
    nonisolated init() {}

    /// Whether `delivered` is the `target` format the output was asked for.
    /// Compared field by field rather than with `==`, which also compares
    /// channel layouts — a layout tag on the same mono samples is no reason to
    /// drop them. Interleaving counts only with more than one channel: asked
    /// for non-interleaved mono Float32 (Parakeet, the API), AVCapture delivers
    /// the very same samples flagged interleaved, and refusing that dropped
    /// every buffer — "nothing heard" on every hold.
    nonisolated static func accepts(_ delivered: AVAudioFormat, for target: AVAudioFormat) -> Bool {
        delivered.sampleRate == target.sampleRate
            && delivered.channelCount == target.channelCount
            && delivered.commonFormat == target.commonFormat
            && (target.channelCount == 1 || delivered.isInterleaved == target.isInterleaved)
    }

    /// Start capturing from the microphone with CoreAudio UID `deviceUID`
    /// (nil = system default input), delivering buffers in `outputFormat`
    /// (nil = whatever the device gives). `onBuffer` runs on the capture's
    /// delivery queue — it must not block, so the only thing the caller does
    /// with it is hand the buffer to the transcription stream.
    ///
    /// `onDeviceChange` fires when the device this capture opened disappears
    /// or the session dies, on whatever thread posted the notification. It is
    /// a signal, not an instruction: this class does nothing about it, because
    /// deciding whether a capture survives belongs to the caller.
    func start(
        deviceUID: String?,
        outputFormat: AVAudioFormat?,
        onDeviceChange: @escaping @Sendable () -> Void,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) async throws {
        stop()
        // `AVCaptureDevice.uniqueID` IS the CoreAudio device UID for audio
        // devices (verified against the HAL device list), so the resolver's
        // pick names a capture device directly. A pinned UID that no longer
        // resolves falls back rather than refusing to record.
        var chosen: AVCaptureDevice?
        if let deviceUID {
            chosen = AVCaptureDevice(uniqueID: deviceUID)
            if chosen == nil {
                DictationController.note("chosen microphone is gone — using the default input")
            }
        }
        guard let device = chosen ?? AVCaptureDevice.default(for: .audio) else {
            throw Failure.noInputDevice
        }
        let session = AVCaptureSession()
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw Failure.sessionFailed(error.localizedDescription)
        }
        guard session.canAddInput(input) else { throw Failure.noInputDevice }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        // The output resamples into the transcriber's format itself, so every
        // buffer arrives ready to feed. Resampling is typically downward
        // (48 kHz device → 16 kHz model); max quality costs nothing at this
        // scale and avoids the aliasing the default leaves on sibilants.
        if let outputFormat {
            output.audioSettings = outputFormat.settings.merging(
                [AVSampleRateConverterAudioQualityKey: AVAudioQuality.max.rawValue]) { current, _ in current }
        }
        guard session.canAddOutput(output) else { throw Failure.unusableFormat }
        session.addOutput(output)
        let sink = Sink(target: outputFormat, onBuffer: onBuffer)
        output.setSampleBufferDelegate(sink, queue: sink.queue)
        self.sink = sink
        self.session = session
        // The input device can disappear mid-capture — a Bluetooth headset
        // running out of battery, a USB microphone unplugged — and nobody
        // hears about it otherwise: the delegate simply stops being called,
        // and the hold ends in "nothing heard", which reads as the feature
        // being broken rather than the microphone being gone.
        //
        // Scoped to THIS capture's device and session objects and dropped by
        // `stop()`; the caller still generation-checks, because a notification
        // already in flight can outrun that. The nil queue means the block
        // runs on whichever thread posted the notification — which is why it
        // touches no capture state. (Unlike the engine, a session posts
        // nothing about its own setup, so there is no settle window here.)
        observers = [
            NotificationCenter.default.addObserver(
                forName: AVCaptureDevice.wasDisconnectedNotification,
                object: device, queue: nil
            ) { _ in onDeviceChange() },
            NotificationCenter.default.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification,
                object: session, queue: nil
            ) { note in
                let why = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?
                    .localizedDescription ?? "unknown"
                DictationController.note("capture runtime error — \(why)")
                onDeviceChange()
            },
        ]
        // Names only — no audio, nothing private.
        DictationController.note("microphone: \(device.localizedName)")
        // The device-open block happens on the session queue; the main actor
        // only suspends. The session reference rides into the closure so a
        // `stop()` landing mid-open can release ours without pulling the rug.
        do {
            // `nonisolated(unsafe)`: AVCaptureSession isn't Sendable, but its
            // start/stop ARE thread-safe (Apple's own recommendation is a
            // dedicated session queue), and every touch of ours goes through
            // the same serial `sessionQueue`.
            nonisolated(unsafe) let opening = session
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                sessionQueue.async {
                    opening.startRunning()
                    if opening.isRunning {
                        cont.resume()
                    } else {
                        cont.resume(throwing: Failure.sessionFailed(String(localized: "the capture session refused to start")))
                    }
                }
            }
        } catch {
            // Guarded like the success path below: if a discard or a newer
            // start displaced this session while it was opening, whichever
            // `stop()` displaced it already owns the cleanup — an unguarded
            // stop here would unhook the NEWER capture's delivery.
            if self.session === session { stop() }
            throw error
        }
        // A `stop()` (or a newer `start`) landed while the device was opening:
        // its queued `stopRunning` will close this session in order, and the
        // caller's own generation check is about to drop the capture anyway.
        guard self.session === session else {
            throw Failure.sessionFailed(String(localized: "the capture was stopped while starting"))
        }
    }

    /// Stops the session, unhooks delivery, and releases everything — which is
    /// what actually hands the microphone back. Always called by the owner
    /// (every capture ends through `discard` or `finish`); there is no deinit
    /// net, because `stop` is main-actor and a deinit is not.
    func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        if let session {
            // Unhook delivery first: a frame already on the sink's queue
            // completes against the sink's own strong reference, but nothing
            // new is enqueued after this line.
            for output in session.outputs {
                (output as? AVCaptureAudioDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
            }
            // Wait out any frame still in flight on the sink's serial queue, so
            // it reaches the stream BEFORE the caller finalizes the analyzer,
            // which `stop` returning is the signal for — it is the last thing
            // said.
            sink?.queue.sync {}
            // The block-and-wait happens off the main thread; the closure's
            // strong reference keeps the session alive until it has stopped.
            // Same `nonisolated(unsafe)` grounds as in `start`.
            nonisolated(unsafe) let closing = session
            sessionQueue.async {
                if closing.isRunning { closing.stopRunning() }
            }
        }
        session = nil
        sink = nil
    }
}

/// One capture's delivery path: `CMSampleBuffer` in, `AVAudioPCMBuffer` out to
/// the transcription stream.
///
/// Everything it owns is either immutable or confined to `queue`, so `stop()`
/// on the main thread never races a frame in flight: the frame completes
/// against the sink's own strong reference, reading state only its own serial
/// queue ever writes.
private final class Sink: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    /// Serial delivery queue. One per capture, so a late frame from the old
    /// session never runs state the new capture's sink owns. (It is NOT a
    /// cross-capture ordering guarantee — at a mid-capture device swap the old
    /// sink's last in-flight buffer can reach the stream a beat after the new
    /// sink's first, about one buffer's worth of audio; inaudible.)
    let queue = DispatchQueue(label: "app.pretype.dictation.capture")
    private let target: AVAudioFormat?
    private let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void
    /// One line per capture, not one per buffer: without it, an output that
    /// delivers something other than the analyzer's format drops all audio
    /// while the pill says "listening" — the exact "held the key, heard
    /// nothing" report, with an empty log.
    private var reportedBadFormat = false

    init(target: AVAudioFormat?, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        self.target = target
        self.onBuffer = onBuffer
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // The HAL delivers linear PCM; anything else would crash the
        // AVAudioFormat wrapper, so it is checked rather than assumed.
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              CMFormatDescriptionGetMediaSubType(description) == kAudioFormatLinearPCM else {
            return
        }
        let delivered = AVAudioFormat(cmAudioFormatDescription: description)
        // `start` asked the output to convert into `target`; this checks that it did.
        if let target, !AudioCapture.accepts(delivered, for: target) {
            if !reportedBadFormat {
                reportedBadFormat = true
                DictationController.note("microphone delivered \(Int(delivered.sampleRate)) Hz "
                    + "\(delivered.channelCount)ch, not the analyzer's format — audio dropped")
            }
            return
        }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: target ?? delivered, frameCapacity: frames) else { return }
        pcm.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames),
            into: pcm.mutableAudioBufferList) == noErr else { return }
        onBuffer(pcm)
    }
}
