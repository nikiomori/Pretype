import AppKit
import ApplicationServices
import AVFoundation
import os

/// Subsystem for the dictation trail. File-scope, so `note` can stay
/// `nonisolated` — a log handle is not main-actor state.
private let dictationLog = OSLog(subsystem: "app.pretype.Pretype", category: "dictation")

/// Hold-to-talk dictation: hold the modifier, speak, release — the words are
/// typed into the field you were already in.
///
/// The pieces it owns are small (`AudioCapture` for the microphone,
/// `Transcription` for the words); what lives here is the part that has to be
/// right: when it is allowed to open the microphone, what the caret shows while
/// it listens, and everything that must invalidate a capture before its text
/// can land in the wrong place.
///
/// Deliberately never automatic. Nothing records unless a key is held, every
/// capture ends the moment anything else happens (a keystroke, a focus change,
/// Pretype being paused, the input device disappearing), and the transcript is
/// typed only into the field that was focused when the key went down.
@MainActor
final class DictationController {
    weak var owner: (any DictationHost)?

    /// The environment checks `begin()` makes, as closures. Production values
    /// read AppKit, TCC and the Speech framework; a test swaps them so the
    /// state machine can run with no microphone, no bundle and no frontmost
    /// app — the exact conditions a test runner is in.
    struct Gates {
        var appIsActive: @MainActor () -> Bool = { NSApp.isActive }
        var secureInput: () -> Bool = { AXText.isSecureInputActive() }
        var micBundled: () -> Bool = { MicrophoneAccess.isBundled }
        var micGranted: () -> Bool = { MicrophoneAccess.isGranted }
        var micStatus: () -> AVAuthorizationStatus = { MicrophoneAccess.status }
        var transcriptionSupported: () -> Bool = { Transcription.isSupported }
        var startSession: @Sendable (Locale, @escaping @Sendable (String) -> Void)
            async throws -> any TranscriptionSession = {
                try await Transcription.start(locale: $0, onPartial: $1)
            }
    }

    var gates = Gates()

    enum Phase: Equatable {
        case idle
        /// Opening the microphone — or downloading a language pack on first use.
        case preparing
        /// Capturing; the payload is the live transcript so far.
        case listening(String)
        /// Key released: finalizing the tail and (optionally) tidying it up.
        case working
    }

    private(set) var phase: Phase = .idle {
        didSet {
            // The status item mirrors the microphone: only the open/closed
            // flip matters there, not every partial-transcript repaint.
            guard Self.isListening(oldValue) != Self.isListening(phase) else { return }
            owner?.onDictationActivity?()
        }
    }

    /// True while a capture is live or being finalized — the completion
    /// pipeline stands down and the overlay belongs to us.
    var isBusy: Bool { phase != .idle }
    /// True while audio is actually being captured.
    var isCapturing: Bool { Self.isListening(phase) }

    private static func isListening(_ phase: Phase) -> Bool {
        if case .listening = phase { return true }
        return false
    }

    /// Hard ceiling on one capture. The key-up that normally ends it arrives on
    /// an event tap macOS is allowed to disable (and re-enable) under load, so
    /// "the release was never delivered" is a real state — and the failure it
    /// would otherwise cause is a microphone left open with a pill sitting at a
    /// caret nobody is looking at. Two minutes is far past any dictation
    /// anyone actually holds a key for, and it *finishes* rather than
    /// discarding: whatever was said still gets typed. Armed from `begin`, so
    /// it covers `.preparing` too — a hung session start with the release
    /// never delivered is the same wedge, and there it discards, because there
    /// is nothing heard to keep. A var only so tests can shorten it; nothing
    /// in the app writes it.
    static var maxCaptureSeconds: TimeInterval = 120

    /// Internal, not private: tests shorten `hold.threshold` so driving the
    /// arm timer doesn't cost half a second of wall clock per case.
    var hold = ModifierHold()
    private var armTimer: Timer?
    private var limitTimer: Timer?
    /// A hold that passed its threshold while the previous capture was still
    /// being written down. Honored by `resumePendingHold` the moment that
    /// write resolves — the alternative was a generation bump that silently
    /// threw away the finished transcript, which is exactly what happens when
    /// someone dictates two sentences back to back with the tidy-up pass on.
    private var pendingBegin = false
    private let capture: any AudioCapturing
    private var session: (any TranscriptionSession)?
    private var sessionTask: Task<Void, Never>?

    init(capture: any AudioCapturing = AudioCapture()) {
        self.capture = capture
    }

    /// Bumped by every start and every discard: an async step that finishes
    /// after its capture was abandoned checks this and drops its result rather
    /// than typing it into whatever is focused now.
    private var generation = 0

    /// Bumped by every `capture.start` — begin's and a mid-capture restart's.
    /// A device-loss notification already in flight when the tap restarts
    /// carries the OLD epoch and is dropped: one physical unplug can post both
    /// the disconnect and the session's runtime error, and counting the second
    /// against the circuit breaker (plus a redundant stop/start) helped nobody.
    private var captureEpoch = 0

    /// Where the capture started — the field the words belong to. A result is
    /// only ever inserted while the focus generation still matches.
    private var focusGeneration = 0
    private var caretRect: CGRect?
    private var hostStyle = HostTextStyle()
    /// Text before the caret when the key went down, so the tidy-up pass can
    /// see what the sentence is continuing.
    private var contextBefore = ""

    /// Dictation events go to the *unified* log as well as the in-app console.
    ///
    /// This is the one flow in the app whose failures are invisible by design:
    /// a refusal draws nothing, and the in-memory console can only be read from
    /// inside a running app — which is no help when the question is "why did
    /// holding the key do nothing". A handful of lines per capture costs
    /// nothing and makes the whole flow observable from outside:
    ///
    ///     log show --last 5m --predicate 'subsystem == "app.pretype.Pretype"'
    ///
    /// `%{public}@` is load-bearing: the unified log redacts interpolated
    /// arguments by default, and an `NSLog("...%@", message)` here showed up as
    /// a row of `<private>` — a log line that proves something happened and
    /// refuses to say what.
    nonisolated static func note(_ message: String, detail: String? = nil) {
        DebugLog.shared.log("DICTATE", message, detail: detail)
        os_log("%{public}@", log: dictationLog, type: .default, message)
    }

    /// One line for the Diagnostics menu: the same conditions `begin()` checks,
    /// in the same order, read from the APP's own TCC identity. A feature whose
    /// refusals are (deliberately) quiet has to be answerable without a
    /// rebuild — and running the probe binary from a terminal reads the
    /// terminal's microphone grant, not Pretype's, so this is the only place
    /// that can state it truthfully.
    var statusLine: String {
        guard Settings.dictationEnabled else { return "off" }
        guard MicrophoneAccess.isBundled else { return "unavailable — not running as an .app" }
        guard Transcription.isSupported else { return "unavailable — needs macOS 26" }
        switch MicrophoneAccess.status {
        case .authorized: break
        case .notDetermined: return "microphone never asked for — hold the key and it will ask"
        case .denied: return "microphone DENIED — System Settings → Privacy & Security → Microphone"
        case .restricted: return "microphone blocked by policy"
        @unknown default: return "microphone unavailable"
        }
        guard Settings.dictationGesture != .off else { return "no key assigned" }
        let state: String
        switch phase {
        case .idle: state = "ready"
        case .preparing: state = "starting…"
        case .listening: state = "listening"
        case .working: state = "writing it down…"
        }
        return "\(Settings.dictationGesture.label) — \(state)"
    }

    // MARK: - Input

    /// Feed a `.flagsChanged` event from the key tap.
    func modifierChanged(_ event: CGEvent) {
        guard Settings.dictationEnabled else { return }
        let outcome = hold.modifierChanged(
            keyCode: event.getIntegerValueField(.keyboardEventKeycode),
            flags: event.flags,
            gesture: Settings.dictationGesture,
            now: Date())
        // Applied HERE, synchronously, in event order. An `.end` deferred to
        // the next runloop pass loses a race against the keystroke that often
        // follows a release within milliseconds: `keyPressed` would still see
        // a live capture and throw away the sentence the queued `finish` was
        // about to type. Nothing on this path is slow — the tap already runs
        // on the main run loop, and `.begin`, the one outcome that does AX
        // reads, only ever arrives from the arm timer, never from here.
        apply(outcome)
        rearmTimer()
    }

    /// A real keystroke ends a hold — it was a chord, not someone talking. It
    /// also disarms a press that has not reached the threshold yet, which is
    /// the case that bites: ⌥⌫ and ⌥-arrows keep the modifier down across
    /// several presses, and a hold left armed through them has the timer open
    /// the microphone half a second into an ordinary edit.
    func keyPressed(isEscape: Bool = false) {
        if let event = hold.keyPressed() { return apply(event) }
        // A capture already being finalized has no hold left to cancel, but a
        // keystroke still says the user has moved on: dropping the transcript
        // beats typing it in behind whatever they just wrote. WITH a notice,
        // unlike the other silent interrupts — release-then-keep-typing is the
        // most natural gesture there is, and a sentence that vanishes without
        // a word is indistinguishable from the feature being broken. ⎋ gets
        // its own wording: Settings promises "⎋ discards one already running",
        // and answering a deliberate cancel with "you kept typing" reads as
        // the app misreading the gesture.
        let wasWorking = phase == .working
        discard(notice: wasWorking
            ? .hint(isEscape ? "dictation cancelled" : "dictation dropped — you kept typing")
            : nil)
    }

    /// A mouse press ends a hold too: ⌥-click and ⌥-drag are ordinary gestures,
    /// and the click has just moved the caret away from where the words were
    /// going.
    func mouseDown() { pointerInterrupted() }

    /// So does a scroll. Under "Hold ⌃" the gesture key is also the pinch-zoom
    /// modifier, so a ⌃-scroll held past the threshold would open the
    /// microphone mid-zoom; and during a live capture the view has just carried
    /// the caret out from under the pill.
    func scrolled() { pointerInterrupted() }

    /// Armed counts as well as busy: the damage these two prevent happens in
    /// the first `threshold` seconds, before a capture exists to be `isBusy`
    /// about. Fully idle stays a cheap early return, because both ride global
    /// monitors that see every click and every scroll on the system.
    ///
    /// Mid-`.working` the interrupt earns a notice, same reasoning as
    /// `keyPressed`: the sentence is already finished, the finalize-plus-tidy
    /// window is seconds long, and users click things while they wait — a
    /// sentence that evaporates without a word is indistinguishable from the
    /// feature being broken. A click during `.listening` stays silent: the
    /// pill vanishing under the click IS the explanation there.
    private func pointerInterrupted() {
        guard isBusy || hold.isArmed else { return }
        _ = hold.interrupt()
        let wasWorking = phase == .working
        discard(notice: wasWorking ? .hint("dictation dropped — the caret moved") : nil)
    }

    /// Focus moved, Pretype was paused, the app is quitting: whatever was being
    /// captured can no longer be typed anywhere sensible.
    func invalidate() {
        _ = hold.interrupt()
        discard(notice: nil)
    }

    private func apply(_ event: ModifierHold.Event?) {
        switch event {
        case .begin: begin()
        case .end: finish()
        case .cancel: discard(notice: .hint("dictation cancelled"))
        case nil: break
        }
    }

    /// The OS sends no event while a key is simply held down, so a one-shot
    /// timer is the only thing that can start a capture.
    private func rearmTimer() {
        armTimer?.invalidate()
        armTimer = nil
        guard hold.isArmed else { return }
        // A hair past the threshold: the press was timestamped a moment before
        // this timer was scheduled, and firing exactly on it would race.
        armTimer = Timer.scheduledTimer(withTimeInterval: hold.threshold + 0.02, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.armTimer = nil
                self.apply(self.hold.tick(now: Date()))
            }
        }
    }

    // MARK: - Capture

    private func begin() {
        guard let owner else { return }
        // The previous transcript is still being finalized (or tidied up — a
        // whole model generation, with polish on). Starting over here would
        // bump the generation and silently discard it, so the new hold WAITS
        // instead: the pill keeps saying "writing it down…", and the moment
        // the pending insert lands `resumePendingHold` starts this capture for
        // real. The key is still down by then, or it isn't and nothing happens.
        if phase == .working {
            pendingBegin = true
            Self.note("still writing the last one down — capture queued")
            return
        }
        // `at` is threaded through so a refusal can still be *shown*: the caret
        // rect from this hold's own AX read, not the host's fallback rect, which
        // is nil until the user has typed something in this field — which is
        // exactly the case where someone reaches for dictation. Refusing
        // silently there is indistinguishable from a broken build.
        func refuse(_ why: String, notice: SuggestionDisplayMode? = nil,
                    at rect: CGRect? = nil) {
            owner.lastEvent = "dictation: \(why)"
            Self.note("not listening — \(why)")
            guard let notice else { return }
            // Falls all the way back to the POINTER when there is no caret to
            // hang a pill on. Every silent refusal in this flow has read as
            // "the feature is broken" — including to the person who wrote it —
            // so a notice with nowhere to go goes to where the user is looking.
            let anchor = rect ?? owner.fallbackCaretRect ?? Self.pointerAnchor()
            owner.showTransientOverlay(notice, at: anchor, host: owner.fallbackHostStyle)
        }
        // The three "we should not be here at all" cases draw nothing on
        // purpose — a paused or blacklisted app is one Pretype has been told to
        // keep out of, pills included.
        guard Settings.enabled else { return refuse("Pretype is paused") }
        guard !gates.appIsActive() else { return refuse("our own window is frontmost") }
        guard !AppPolicy.isBlacklisted(owner.typingContext.bundleID) else {
            return refuse("off in \(owner.typingContext.appName ?? "this app")")
        }
        // Something has to receive the words. This is the only hard requirement:
        // typing into a window with no text focus would fire shortcuts instead
        // of writing a sentence.
        guard owner.hasFocusedTextField() else {
            return refuse("no text field in focus",
                          notice: .hint("click into a text field, then hold to talk"))
        }
        // An open IME composition is the one focused-field state synthetic
        // keystrokes must never touch: they land inside the marked text and
        // garble or force-commit it, IME-dependent. Precise-only by design —
        // see `AXText.hasMarkedText` for why the coarse input-source fallback
        // is not consulted here.
        guard !owner.isComposingInFocusedField() else {
            return refuse("an IME composition is open",
                          notice: .hint("finish composing that word, then hold to talk"))
        }
        // The privacy floor `AXText.context` normally enforces has to be
        // restated here, because the anchor read is no longer a gate: while
        // macOS reports secure input, a password field is focused somewhere and
        // nothing may be captured or typed.
        guard !gates.secureInput() else {
            return refuse("secure input is active",
                          notice: .hint("dictation stays out of password fields"))
        }
        // Everything the anchor gives is ADVISORY. Web and Electron fields
        // routinely publish no `AXSelectedTextRange` until their first
        // keystroke: the field is focused, the caret is blinking in it, and AX
        // still reports nothing. Gating on that produced this feature's most
        // confusing failure — "click into a text field" while the cursor is
        // already in it, curable by typing one letter — for no benefit, since
        // dictation needs no coordinates at all. `TextInjector` types into
        // whatever holds keyboard focus; the read only buys the pill's position
        // and the sentence the tidy-up pass is continuing.
        let anchor = owner.dictationAnchor()
        if anchor == nil {
            Self.note("field publishes no caret yet — listening anyway, without the pill")
        }
        // Caret geometry is optional for the same reason: terminal panes,
        // Electron canvases and web views that expose a field but no caret box
        // are exactly where someone would rather talk than type. No rect simply
        // means no pill; the words still land.
        let rect = anchor?.caretRect
        // Before the microphone checks, because it decides what they mean: an
        // unbundled binary (`swift run`) has no TCC identity, so `request()`
        // below would return false without ever prompting — and booking that
        // as "the user refused" wiped `dictationEnabled` for the built app too.
        guard gates.micBundled() else {
            return refuse("not running as an .app — microphone access is granted by bundle",
                          notice: .error("dictation needs the built app — run make-app.sh"), at: rect)
        }
        guard gates.transcriptionSupported() else {
            return refuse("needs macOS 26", notice: .error("dictation needs macOS 26"), at: rect)
        }
        guard gates.micGranted() else {
            // Never asked. Dictation can be switched on without passing through
            // the Settings toggle that normally does the asking — a stored
            // default, a synced preference, a `defaults write` — and refusing a
            // key the user is *holding down* because of that is the worst
            // possible moment to be pedantic. Ask now; the next hold works.
            if gates.micStatus() == .notDetermined {
                refuse("microphone never asked for — asking now",
                       notice: .hint("allow the microphone, then hold the key again"), at: rect)
                Task { @MainActor in
                    let granted = await MicrophoneAccess.request()
                    Self.note("microphone \(granted ? "granted" : "refused")")
                    Settings.dictationEnabled = granted
                }
                return
            }
            return refuse("no microphone permission",
                          notice: .error("allow the microphone in Settings"), at: rect)
        }

        owner.clearActiveCompletion()
        // An ⌥⇥ fix still in flight would land its preview mid-capture — both
        // guarded only by focus generation, which starting to dictate in the
        // same field does not bump — and the window would ping-pong between
        // the preview and the listening pill on every partial.
        owner.cancelPendingFix()
        owner.stopProgressIndicator()
        restarts = 0
        firstRestartAt = Date()
        focusGeneration = owner.focusGeneration
        caretRect = rect
        hostStyle = anchor?.host ?? HostTextStyle()
        contextBefore = anchor?.textBeforeCaret ?? ""
        if let rect, let anchor { owner.noteCaret(rect: rect, host: anchor.host) }
        generation += 1
        let gen = generation
        phase = .preparing
        render()
        owner.lastEvent = "listening…"
        Self.note("listening (\(Settings.dictationGesture.label))")
        // Armed here, not at the `.listening` flip, so the ceiling covers
        // `.preparing` too: a hung session start with the key-up never
        // delivered (the disabled-event-tap case the ceiling exists for) would
        // otherwise say "starting dictation…" forever while suppressing the
        // whole completion pipeline.
        limitTimer?.invalidate()
        limitTimer = Timer.scheduledTimer(
            withTimeInterval: Self.maxCaptureSeconds, repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                // The interrupt lives inside the cases: a fire racing
                // `finish()` into `.working` must be a true no-op, not one
                // that ends a second hold already queued behind the write.
                switch self.phase {
                case .listening:
                    Self.note("capture hit the \(Int(Self.maxCaptureSeconds))-second ceiling — finishing")
                    _ = self.hold.interrupt()
                    self.finish()
                case .preparing:
                    Self.note("still preparing when the capture ceiling hit — giving up on this hold")
                    _ = self.hold.interrupt()
                    self.discard(notice: .error("dictation couldn't start — try again"))
                default:
                    break
                }
            }
        }

        // Built here, not inside the task below: a closure written inside a
        // `[weak self]` task captures the task's optional `self` *variable*,
        // which is a data race the moment the transcriber calls it off-actor.
        let onPartial: @Sendable (String) -> Void = { [weak self] text in
            Task { @MainActor in self?.updatePartial(text, generation: gen) }
        }
        // Same rule, and the sharper case for it: this one is called from
        // whatever thread the capture's device-loss notification is posted on.
        captureEpoch += 1
        let epoch = captureEpoch
        let onDeviceChange: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in await self?.deviceChanged(generation: gen, epoch: epoch) }
        }
        let startSession = gates.startSession
        sessionTask = Task { @MainActor [weak self] in
            let locale = Settings.resolvedDictationLocale
            // Held OUTSIDE the do-block so the catch can see it: a session that
            // started before the microphone failed (`capture.start` throwing)
            // is invisible to `discard` — `self.session` is only assigned
            // further down — and un-cancelled it leaks a live analyzer and its
            // collector task per attempt.
            var started: (any TranscriptionSession)?
            do {
                // Can be slow exactly once per language — macOS downloads the
                // dictation model on first use. The key is usually long
                // released by then; `finish` says so instead of hanging.
                let session = try await startSession(locale, onPartial)
                started = session
                guard let self, self.generation == gen else { return session.cancel() }
                try await self.capture.start(
                    deviceUID: Self.inputDevice()?.uid,
                    outputFormat: session.audioFormat, onDeviceChange: onDeviceChange
                ) { buffer in
                    session.feed(buffer)
                }
                // Re-checked across the device-open suspension: a discard that
                // landed mid-open already called `capture.stop()`, but ours
                // may have re-opened the microphone after it. Epoch-guarded,
                // because a NEWER begin may also have started its own capture
                // by now — a stale wake must not close that one's microphone
                // (the newer start's own `stop()`-first already closed ours).
                guard self.generation == gen else {
                    if self.captureEpoch == epoch { self.capture.stop() }
                    return session.cancel()
                }
                self.session = session
                self.phase = .listening("")
                self.render()
            } catch {
                started?.cancel()
                guard let self, self.generation == gen else { return }
                self.fail(error)
            }
        }
    }

    private func updatePartial(_ text: String, generation: Int) {
        guard self.generation == generation, case .listening = phase else { return }
        phase = .listening(text)
        render()
    }

    /// The device this capture opened disappeared, or the capture session
    /// died — a Bluetooth headset running out of battery, a USB microphone
    /// pulled out. (A capture session pins the one concrete device it opened:
    /// a NEW default input arriving posts nothing here, and the capture
    /// deliberately keeps the microphone it started with — no mid-sentence
    /// hop, no Bluetooth profile flip.)
    ///
    /// First choice is to carry on: reopen whatever the input resolver picks
    /// now, feeding the same session. The reopen re-reads the device format
    /// and resamples into the session's pinned one, so a different microphone
    /// is a hiccup instead of an ending. Only when no usable input is left
    /// does the capture end — and even then it *finishes* if anything was
    /// already heard: the words exist, and typing them beats making the user
    /// say them again. The device-loss error is reserved for a capture that
    /// had heard nothing.
    ///
    /// Guarded on generation, epoch *and* on still capturing, because the
    /// notification arrives from another thread: one posted for a capture that
    /// has since been discarded must not kill the capture that replaced it,
    /// one from the pre-restart session must not burn another restart, and one
    /// that overtakes `capture.stop()` must not throw away a transcript
    /// already being finalized.
    private func deviceChanged(generation: Int, epoch: Int) async {
        guard self.generation == generation, epoch == captureEpoch,
              isCapturing, let session else { return }
        // Circuit breaker. A reopened device can disappear again immediately —
        // a dying Bluetooth headset does exactly this — and one wrong move
        // upstream turns that into a loop that restarts the tap dozens of
        // times a second, with the measured cost being more than a lost
        // transcript: a Bluetooth headset flips profile on every cycle and its
        // volume comes back wrong. Nothing legitimate changes the input device
        // three times in three seconds, so past that the capture ENDS — with
        // whatever was heard, on the same terms as losing the device outright.
        let now = Date()
        if now.timeIntervalSince(firstRestartAt) > Self.restartWindow {
            firstRestartAt = now
            restarts = 0
        }
        restarts += 1
        guard restarts <= Self.maxRestarts else {
            Self.note("input kept changing — ending the capture instead of restarting again")
            _ = hold.interrupt()
            if case .listening(let partial) = phase, !partial.isEmpty {
                finish()
            } else {
                fail(AudioCapture.Failure.deviceChanged)
            }
            return
        }
        // Carrying on is only sound when the session PINNED a format: the
        // restart resamples the new device into it, and the analyzer never
        // notices. A session that accepted the device's raw format
        // (`audioFormat == nil`) has a live analyzer mid-stream on the OLD
        // device's sample rate — feeding it the new device's would trade a
        // graceful ending for `unexpectedAudioFormat` a moment later.
        // Claimed before the branch, for the tail below: a SECOND loss can
        // arrive while this restart is still opening the device (the
        // replacement session installs its observers before its continuation
        // suspends), and that newer restart's entry `stop()` is exactly what
        // fails this one. The no-format branch never suspends, so its
        // unchanged claim passes the tail by construction.
        var restartEpoch = captureEpoch
        if session.audioFormat != nil {
            let gen = generation
            captureEpoch += 1
            let epoch = captureEpoch
            restartEpoch = epoch
            let onDeviceChange: @Sendable () -> Void = { [weak self] in
                Task { @MainActor in await self?.deviceChanged(generation: gen, epoch: epoch) }
            }
            do {
                // Re-resolved, not remembered: the loss that brought us here
                // may be the very headset the automatic rule steps around
                // leaving the room.
                try await capture.start(
                    deviceUID: Self.inputDevice()?.uid,
                    outputFormat: session.audioFormat, onDeviceChange: onDeviceChange
                ) { buffer in
                    session.feed(buffer)
                }
                // Re-checked across the device-open suspension: a keystroke's
                // discard landing mid-open already stopped the capture, and
                // ours may have re-opened the microphone after it. Same epoch
                // guard as `begin`'s — a newer capture's session must not be
                // stopped from a stale wake.
                guard self.generation == gen, isCapturing else {
                    if captureEpoch == epoch { capture.stop() }
                    return
                }
                Self.note("input device lost mid-capture — reopened on the current default")
                return
            } catch {
                Self.note("input device lost mid-capture — no usable input left")
            }
        } else {
            Self.note("input changed mid-capture — session has no fixed format, ending the capture")
        }
        // The failed-restart path above crossed a suspension: whatever ends
        // here must still be THIS capture, not whatever replaced it meanwhile
        // — and no NEWER restart may have claimed the session since, because
        // then the failure was being displaced by it, and ending here would
        // kill the very capture that restart just saved.
        guard self.generation == generation, isCapturing,
              captureEpoch == restartEpoch else { return }
        _ = hold.interrupt()
        if case .listening(let partial) = phase, !partial.isEmpty {
            finish()
        } else {
            fail(AudioCapture.Failure.deviceChanged)
        }
    }

    private func finish() {
        guard let owner else { return }
        if case .preparing = phase {
            // Released while the language pack was still coming down. The
            // download keeps running (`discard` leaves a preparing task alone
            // — it is the slow part, and cancelling it would mean starting
            // over), so the next press is the fast one.
            discard(notice: .hint("getting the dictation model ready…"))
            return
        }
        guard case .listening = phase, let session else { return }
        capture.stop()
        limitTimer?.invalidate()
        limitTimer = nil
        phase = .working
        render()
        let gen = generation
        let targetFocus = focusGeneration
        sessionTask = Task { @MainActor [weak self] in
            do {
                // Behind a deadline, because `finish` awaits the analyzer's own
                // finalization: a hung `finalizeAndFinishThroughEndOfInput`
                // would otherwise leave the pill saying "writing it down…"
                // forever, with every keystroke silently discarding. Ten
                // seconds is far past any real finalization of a two-minute
                // ceiling's audio — this is a watchdog, not a budget.
                let raw = try await Self.withDeadline(seconds: Self.finalizeSeconds) {
                    try await session.finish()
                }
                guard let self else { return }
                guard self.generation == gen else {
                    // A drop is always someone's sentence — it gets a line even
                    // when it is the right call, so a bug report can tell "the
                    // user moved on" from "the transcript vanished".
                    Self.note("dropped a finished transcript — the capture was discarded meanwhile")
                    return
                }
                let transcript = Self.clean(raw)
                guard !transcript.isEmpty else {
                    self.discard(notice: .hint("nothing heard"))
                    return
                }
                var text = transcript
                if Settings.dictationPolish, let polished = await self.polish(transcript) {
                    text = polished
                }
                guard self.generation == gen else {
                    Self.note("dropped \(text.count) chars — discarded during tidy-up")
                    return
                }
                self.phase = .idle
                self.session = nil
                owner.hideOverlay()
                if owner.focusGeneration == targetFocus {
                    owner.insertDictated(text)
                } else {
                    Self.note("dropped \(text.count) chars — focus changed")
                }
                self.resumePendingHold(noticeIfMissed: true)
            } catch {
                guard let self, self.generation == gen else { return }
                self.fail(error)
            }
        }
    }

    /// Start the capture a hold asked for while the previous one was still
    /// being written down. Clears the flag either way: if the key has since
    /// come up (or the hold was interrupted), there is nothing to resume.
    ///
    /// `noticeIfMissed` is passed only by the finish-and-insert path: a hold
    /// that queued behind the write and was RELEASED before it resolved never
    /// opened the microphone, so whatever was said into it is gone — and the
    /// only warning was the pill still reading "writing it down…". That earns
    /// a notice. The discard paths pass nothing: they either just showed a
    /// more accurate notice of their own ("you kept typing") or are silent by
    /// design (focus change, app quitting), where this one would be noise.
    private func resumePendingHold(noticeIfMissed: Bool = false) {
        guard pendingBegin else { return }
        pendingBegin = false
        guard hold.isActive else {
            if noticeIfMissed, let owner {
                Self.note("queued hold released before the microphone could open")
                let rect = caretRect ?? owner.fallbackCaretRect ?? Self.pointerAnchor()
                owner.showTransientOverlay(
                    .hint("wasn't listening yet — hold and say that again"),
                    at: rect, host: hostStyle)
            }
            return
        }
        begin()
    }

    /// Run the transcript through the engine's minimal-edit fix — the same pass
    /// ⌥⇥ uses on a selection. It restores the capitalization and punctuation
    /// speech doesn't carry, and its divergence guard means a model that starts
    /// paraphrasing gets rejected instead of rewriting what you said. nil ⇒ keep
    /// the transcript exactly as heard.
    ///
    /// On a hard time budget, because the whole `.working` window is hostile
    /// territory: any keystroke discards the transcript, and a queued next
    /// hold hasn't opened its microphone yet. The fix is one short generation
    /// when the model is loaded — but on an idle-unloaded engine it begins
    /// with a model RELOAD, tens of seconds the sentence must not be hostage
    /// to. Past the budget the transcript goes in exactly as heard.
    private func polish(_ text: String) async -> String? {
        guard let owner else { return nil }
        // The shared fix path is defined for a single line of at most 500
        // characters (see `MLXEngine.correct`); a longer dictation goes in as
        // heard rather than half-corrected.
        guard text.count <= 500 else { return nil }
        let context = contextBefore
        let fixed: String?
        do {
            // The same abandon-not-await race as the finalize watchdog: an
            // `engine.correct` mid-model-reload does not observe cancellation,
            // and a task group would wait for it anyway.
            fixed = try await Self.withDeadline(seconds: Self.polishSeconds) { @MainActor in
                await owner.tidyDictation(text, before: context)
            }
        } catch {
            Self.note("tidy-up passed its budget — typing the transcript as heard")
            fixed = nil
        }
        guard let fixed else { return nil }
        // Lengths, not words: this line used to carry both versions of the
        // sentence, and the debug log is exported into bug reports. The counts
        // ride in the MESSAGE rather than the detail so they reach the unified
        // log too — a tidy-up that grew the sentence is what "strange
        // characters at the end" looks like from outside, and the in-app
        // console can only be read from inside a running app.
        Self.note("tidied \(text.count) → \(fixed.count) chars (text redacted)")
        return fixed
    }

    /// See the circuit breaker in `deviceChanged`.
    private var restarts = 0
    private var firstRestartAt = Date.distantPast
    private static let maxRestarts = 3
    private static let restartWindow: TimeInterval = 3

    /// See `polish` — how long the tidy-up may hold the transcript. A var only
    /// so tests can shorten it; nothing in the app writes it.
    static var polishSeconds: TimeInterval = 3
    /// See `finish` — the watchdog on the analyzer's own finalization. A var
    /// for the same reason.
    static var finalizeSeconds: TimeInterval = 10

    enum Failure: LocalizedError {
        case timedOut
        var errorDescription: String? {
            switch self {
            case .timedOut: return "transcription timed out"
            }
        }
    }

    /// `body` raced against a deadline. NOT a task group, deliberately: a
    /// group's scope awaits its children even after `cancelAll()`, so a body
    /// that ignores cancellation — a genuinely deadlocked finalize, the very
    /// case the watchdog exists for — would keep the "timeout" suspended right
    /// alongside it. The losing body task is cancelled and *abandoned*
    /// instead; what actually unblocks the analyzer afterwards is the
    /// `session.cancel()` on the failure path. The timer task is allowed to
    /// sleep out its few seconds when the body wins — a dormant task beats the
    /// reference cycle cancelling it would take.
    nonisolated private static func withDeadline<T: Sendable>(
        seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            @Sendable func resumeOnce(_ result: Result<T, Error>) {
                let first = resumed.withLock { done in
                    if done { return false }
                    done = true
                    return true
                }
                if first { continuation.resume(with: result) }
            }
            let work = Task {
                do { resumeOnce(.success(try await body())) } catch { resumeOnce(.failure(error)) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                work.cancel()
                resumeOnce(.failure(Failure.timedOut))
            }
        }
    }

    private func fail(_ error: Error) {
        let why = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        owner?.lastEvent = "dictation failed: \(why)"
        DebugLog.shared.log("ERROR", "dictation: \(why)")
        // Whatever failed, the session is gone — take the task with it.
        sessionTask?.cancel()
        sessionTask = nil
        discard(notice: .error(why))
    }

    /// Stop everything and forget it.
    ///
    /// A task still *preparing* is left running on purpose: that phase is a
    /// one-time language-pack download, and cancelling it would mean starting
    /// the download over on the next press. The generation bump is what makes
    /// that safe — the session it eventually produces is cancelled on arrival.
    private func discard(notice: SuggestionDisplayMode?) {
        guard isBusy else { return }
        generation += 1
        capture.stop()
        session?.cancel()
        session = nil
        if phase != .preparing {
            sessionTask?.cancel()
            sessionTask = nil
        }
        phase = .idle
        armTimer?.invalidate()
        armTimer = nil
        limitTimer?.invalidate()
        limitTimer = nil
        // Either the notice or the hide, never both: `hide` runs a fade whose
        // completion is only cancelled by a later show, so hiding first would
        // race a transient shown a line later against its own fade-out.
        if let owner {
            if let notice {
                // The same fallback chain `refuse()` uses, pointer included:
                // fields that publish no caret (web/Electron inputs before
                // their first keystroke) are exactly where dictation still
                // runs, and a notice quietly skipped there is the
                // silent-vanish bug all over again.
                let rect = caretRect ?? owner.fallbackCaretRect ?? Self.pointerAnchor()
                owner.showTransientOverlay(notice, at: rect, host: hostStyle)
            } else {
                owner.hideOverlay()
            }
        }
        // A hold that queued behind the discarded capture: interrupts have
        // already ended the hold itself by this point, so this only ever fires
        // for a key that is genuinely still down (say, after a failed capture).
        resumePendingHold()
    }

    // MARK: - Caret display

    private func render() {
        guard let owner else { return }
        // A capture with no readable caret still has to LOOK like one. The pill
        // is the only sign at the caret that the microphone is open, and the
        // fields that publish no caret — web and Electron inputs, before their
        // first keystroke and again whenever the app replaces the focused node
        // — are exactly where someone reaches for dictation. Reported from real
        // use: the second sentence recorded fine but showed nothing at all,
        // only the menu-bar dot. Same ladder a refusal notice uses: this
        // capture's own caret, then the last one this field drew at, then the
        // pointer.
        let rect = caretRect ?? owner.fallbackCaretRect ?? Self.pointerAnchor()
        let mode: SuggestionDisplayMode
        switch phase {
        case .idle:
            owner.hideOverlay()
            return
        case .preparing:
            mode = .status("starting dictation…")
        case .listening(let text):
            mode = .listening(Self.tail(text))
        case .working:
            mode = .status("writing it down…")
        }
        owner.showOverlay(mode, at: rect, host: hostStyle)
    }

    /// The microphone this capture should open, or nil for the system default
    /// input.
    ///
    /// nil when the answer IS the default input — which is every Mac without a
    /// headset doubling as both ends: the capture then follows whatever macOS
    /// calls the microphone without this code naming one.
    static func inputDevice() -> AudioDevices.Device? {
        let chosen = AudioDevices.current(
            preference: AudioDevices.Preference(stored: Settings.dictationInput))
        guard let chosen, chosen.uid != AudioDevices.defaultInput()?.uid else { return nil }
        return chosen
    }

    /// Where to draw a notice that has no caret to belong to: a one-point box
    /// just under the pointer, in the same Cocoa screen coordinates the caret
    /// rects use. Internal, not private: `insertDictated`'s own drop notices
    /// fall back to it too.
    static func pointerAnchor() -> CGRect {
        let point = NSEvent.mouseLocation
        return CGRect(x: point.x, y: point.y - 22, width: 1, height: 18)
    }

    /// The END of a long dictation, not its beginning: what the pill is for is
    /// showing that the words being said right now are being heard.
    nonisolated static func tail(_ text: String, limit: Int = 64) -> String {
        guard text.count > limit else { return text }
        return "…" + String(text.suffix(limit))
    }

    /// One clean line: a transcript with a newline in it would *send* the
    /// message in half the apps this types into, and trailing whitespace is
    /// never wanted at a caret.
    nonisolated static func clean(_ raw: String) -> String {
        var text = raw
        for newline in ["\r\n", "\n", "\r", "\u{2028}", "\u{2029}"] {
            text = text.replacingOccurrences(of: newline, with: " ")
        }
        while text.contains("  ") {
            text = text.replacingOccurrences(of: "  ", with: " ")
        }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
