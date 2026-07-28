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

    static var isGranted: Bool { isBundled && status == .authorized }

    /// Prompts only on `.notDetermined` — a previous refusal is answered from
    /// the cached status, because macOS never re-prompts and a silent `false`
    /// would read as a broken button.
    static func request() async -> Bool {
        guard isBundled else { return false }
        guard status != .authorized else { return true }
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
            case .noInputDevice: return "no microphone found"
            case .unusableFormat: return "the microphone format can't be converted"
            case .deviceChanged: return "the microphone went away"
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
    /// Bumped by every `start` and `stop`, so the delayed "after release"
    /// output-state log fires only when no newer capture has begun — the line
    /// exists to catch "the volume stayed changed", and measured mid-next-
    /// capture it would report exactly the wrong moment.
    private var logToken = 0

    var isRunning: Bool { session?.isRunning ?? false }

    /// Nonisolated so `DictationController.init`'s default argument — which
    /// Swift evaluates outside the actor — can build one; every stored
    /// property has a nonisolated default.
    nonisolated init() {}

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
        logToken += 1
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
        DictationController.note("microphone: \(device.localizedName)"
            + (deviceUID == nil ? " (system default)" : ""))
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
                        cont.resume(throwing: Failure.sessionFailed("the capture session refused to start"))
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
            throw Failure.sessionFailed("the capture was stopped while starting")
        }
        // Both sides of a capture, so "the sound changed and stayed changed"
        // becomes a pair of numbers in the log rather than something the user
        // has to catch in the act.
        DictationController.note("listening through — \(AudioDevices.outputStateLine())")
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
            // Flush the resampler's buffered tail into the stream — queued
            // behind any frame still in flight (same serial queue), and BEFORE
            // the caller finalizes the analyzer, which `stop` returning is the
            // signal for. A few milliseconds, but they are the last thing said.
            if let sink { sink.queue.sync { sink.drain() } }
            // The block-and-wait happens off the main thread; the closure's
            // strong reference keeps the session alive until it has stopped.
            // Same `nonisolated(unsafe)` grounds as in `start`.
            nonisolated(unsafe) let closing = session
            sessionQueue.async {
                if closing.isRunning { closing.stopRunning() }
            }
            // Read a moment later — late enough for a Bluetooth output to have
            // finished renegotiating anything a capture disturbed. Token-
            // guarded: a newer capture running when this fires would make the
            // line report mid-capture state as "after release".
            logToken += 1
            let token = logToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.logToken == token, self.session == nil else { return }
                DictationController.note("after release — \(AudioDevices.outputStateLine())")
            }
        }
        session = nil
        sink = nil
    }

    /// One input buffer resampled into the target format. Returns nil when the
    /// converter has nothing to give (it buffers internally across calls) —
    /// and also on a real conversion error, which `failed` distinguishes so
    /// the sink can say so once instead of dropping audio in silence.
    ///
    /// Static, and handed everything it works on, so that the delivery queue
    /// never reads state another thread could be writing.
    nonisolated static func convert(
        _ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, to target: AVAudioFormat,
        failed: inout Bool
    ) -> AVAudioPCMBuffer? {
        // When the device already speaks the format the transcriber asked for,
        // the converter is never touched and the buffer goes straight through.
        guard target != buffer.format else { return buffer }
        // Capacity from the sample-rate ratio plus slack: the converter emits
        // whole packets, so an exact ratio can come up one packet short and
        // `convert` then fails with `.insufficientDataFromInputBlock`.
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        // `nonisolated(unsafe)`: the input block runs synchronously inside
        // `convert`, on this same thread — the Sendable requirement on the
        // block is broader than this use.
        nonisolated(unsafe) let input = buffer
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            // One shot per call: claiming more data would make the converter
            // block waiting for a buffer that only the next callback brings.
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error {
            failed = true
            return nil
        }
        guard out.frameLength > 0 else { return nil }
        return out
    }
}

/// One capture's delivery path: `CMSampleBuffer` in, resampled
/// `AVAudioPCMBuffer` out to the transcription stream.
///
/// Everything it owns is either immutable or confined to `queue` — the
/// converter is built lazily on first delivery and rebuilt if the device
/// format shifts mid-capture — so `stop()` on the main thread never races a
/// frame in flight: the frame completes against the sink's own strong
/// reference, reading state only its own serial queue ever writes.
private final class Sink: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    /// Serial delivery queue. One per capture, so a late frame from the old
    /// session never runs converter state the new capture's sink owns. (It is
    /// NOT a cross-capture ordering guarantee — at a mid-capture device swap
    /// the old sink's last in-flight buffer can reach the stream a beat after
    /// the new sink's first, about one buffer's worth of audio; inaudible.)
    let queue = DispatchQueue(label: "app.pretype.dictation.capture")
    private let target: AVAudioFormat?
    private let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    /// One line per broken format, not one per buffer: without it, a converter
    /// that cannot be built (or errors on every call) drops all audio forever
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
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        pcm.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames),
            into: pcm.mutableAudioBufferList) == noErr else { return }
        // A nil target means the session accepted whatever the device speaks.
        guard let target, target != format else { return onBuffer(pcm) }
        if converter == nil || converterInput != format {
            converter = AVAudioConverter(from: format, to: target)
            // Resampling is typically downward (48 kHz device → 16 kHz
            // model). `mastering` costs nothing at this scale and avoids the
            // aliasing the default quality leaves on sibilants.
            converter?.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            converterInput = format
            // A fresh format deserves a fresh report either way.
            reportedBadFormat = false
            if converter == nil {
                reportedBadFormat = true
                DictationController.note("can't resample \(Int(format.sampleRate)) Hz "
                    + "\(format.channelCount)ch into the analyzer's format — audio dropped")
            }
        }
        guard let converter else { return }
        var failed = false
        let converted = AudioCapture.convert(pcm, using: converter, to: target, failed: &failed)
        if failed, !reportedBadFormat {
            reportedBadFormat = true
            DictationController.note("resampler error on \(Int(format.sampleRate)) Hz "
                + "\(format.channelCount)ch input — audio dropped")
        }
        guard let converted else { return }
        onBuffer(converted)
    }

    /// Flush the converter's internally buffered tail into the stream — the
    /// last few milliseconds said, which otherwise never leave the resampler.
    /// The owner dispatches this onto `queue`, after the final delivery.
    func drain() {
        guard let converter, let target else { return }
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096) else { return }
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            inputStatus.pointee = .endOfStream
            return nil
        }
        if status != .error, out.frameLength > 0 { onBuffer(out) }
    }
}
