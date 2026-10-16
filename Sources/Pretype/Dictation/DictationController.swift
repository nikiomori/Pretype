import Accelerate
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

    /// What is keeping the microphone open — which is also what will close it.
    ///
    /// The two are not variations on a theme: a held key is a dead-man's switch
    /// (everything else the user does means "that wasn't dictation"), while a
    /// latch is a deliberate mode the user is expected to keep working
    /// alongside. Nearly every interrupt rule below reads this.
    enum Trigger: Equatable {
        /// A modifier held down — `ModifierHold`. Ends on release.
        case hold
        /// `DictationLatch`'s chord. Ends on the next press of it, on ⎋, on
        /// silence, or at the ceiling.
        case latch
    }

    private(set) var trigger: Trigger = .hold

    /// A hands-free capture is running. Every interrupt that exists because a
    /// held modifier is ambiguous — a keystroke, a click, a scroll — reads this
    /// and stands down: hands-free means the user is expected to keep using the
    /// machine, and a capture that died on the first scroll would be a hold
    /// with extra steps.
    private var isLatched: Bool { trigger == .latch && isBusy }

    /// A hands-free capture that has not been stopped yet — which is the window
    /// the relaxed interrupt rules apply to.
    ///
    /// `.preparing` is in it, deliberately and load-bearingly. That phase is
    /// tens of milliseconds on a built-in microphone, seconds on a Bluetooth
    /// headset and *minutes* on a first-use language-pack download — and
    /// "press the chord, then go and find the thing I was going to say" is the
    /// hands-free case exactly. Scoping this to `.listening` alone let a scroll
    /// during the wait tear the capture down with no pill and no notice.
    ///
    /// `.working` is out of it, equally deliberately. Once the chord has been
    /// pressed again and the words are being written down there is no speech
    /// left to protect, and a click in that window has just moved the caret the
    /// transcript is about to be typed at — so it goes to the clipboard
    /// instead (`rescueOnInterrupt`), whatever started the capture.
    private var isLatchedAndLive: Bool {
        trigger == .latch && isBusy && phase != .working
    }

    /// A keystroke or click landed while this take was being written down:
    /// the caret it was headed for has moved, so `finish` hands it to
    /// `rescueDictated` instead of typing it behind whatever was just typed or
    /// clicked. Reset by `begin`.
    private var caretMoved = false

    /// A keystroke or click while the take is being written down. Dropping
    /// it there threw away a finished sentence over one stray key — and on a
    /// hosted API `.working` is the whole upload, so that sentence could be
    /// ten minutes of speech. It can't be typed either, the caret has moved:
    /// it finishes to the clipboard, as a focus change does, and later
    /// interrupts leave it be. A hold queued behind it was a chord, and goes.
    /// false when there is nothing to rescue — not writing yet, or a voice
    /// command, whose selection is what just moved — and the caller drops it
    /// as before.
    private func rescueOnInterrupt() -> Bool {
        guard phase == .working, commandSelection == nil else { return false }
        if hold.interrupt() != nil, pendingBegin == .hold { pendingBegin = nil }
        caretMoved = true
        return true
    }

    private(set) var phase: Phase = .idle {
        didSet {
            if (oldValue == .idle) != (phase == .idle) { owner?.dictationBusyChanged() }
            // The status item mirrors the microphone: only the open/closed
            // flip matters there, not every partial-transcript repaint.
            guard Self.isListening(oldValue) != Self.isListening(phase) else { return }
            onActivity?()
        }
    }

    /// Fires on the open/closed flip of the microphone, so the status item can
    /// show a mic while a capture is live. Set by `StatusMenuController.bind`.
    var onActivity: (() -> Void)?

    /// True while a capture is live or being finalized — the completion
    /// pipeline stands down and the overlay belongs to us.
    var isBusy: Bool { phase != .idle }
    /// True while audio is actually being captured.
    var isCapturing: Bool { Self.isListening(phase) }
    /// A gesture modifier is down and counting toward the hold threshold.
    var isHoldArmed: Bool { hold.isArmed }

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
    var maxCaptureSeconds: TimeInterval = 120

    /// The same ceiling for a latched capture, where it means something else
    /// entirely. Nothing was ever going to arrive to end a hands-free capture —
    /// no release to miss — so this is not a safety net under a lost event but
    /// the only bound on a capture the user walked away from. Ten minutes is
    /// past any dictation anyone sits through and still short enough that a
    /// forgotten latch is not an open microphone for the afternoon. (Silence
    /// normally gets there first; this covers the room that is never quiet.)
    var maxLatchedSeconds: TimeInterval = 600

    /// The ceiling this capture is running under.
    private var ceilingSeconds: TimeInterval {
        trigger == .latch ? maxLatchedSeconds : maxCaptureSeconds
    }

    /// Internal, not private: tests shorten `hold.threshold` so driving the
    /// arm timer doesn't cost half a second of wall clock per case.
    var hold = ModifierHold()
    private var armTimer: Timer?
    private var limitTimer: Timer?
    /// Bumped by every `armCeiling` — see there.
    private var ceilingToken = 0
    private var silenceTimer: Timer?
    /// A start that arrived while the previous capture was still being written
    /// down, and what asked for it. Honored by `resumePendingHold` the moment
    /// that write resolves — the alternative was a generation bump that
    /// silently threw away the finished transcript, which is exactly what
    /// happens when someone dictates two sentences back to back with the
    /// tidy-up pass on.
    private var pendingBegin: Trigger?
    /// Voice activity for the capture in flight, written on the delivery queue
    /// and read by `silenceTimer`. Replaced per capture, so a straggling buffer
    /// from the previous one cannot keep this one alive.
    private var meter: VoiceMeter?
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
    private var startedInLauncher = false
    private var caretRect: CGRect?
    private var hostStyle = HostTextStyle()
    /// Text before the caret when the key went down, so the tidy-up pass can
    /// see what the sentence is continuing.
    private var contextBefore = ""
    /// The selection this capture's words are an instruction for (voice
    /// command mode), or nil for ordinary dictation.
    private var commandSelection: String?

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
    nonisolated static func note(_ message: String) {
        DebugLog.shared.log("DICTATE", message)
        os_log("%{public}@", log: dictationLog, type: .default, message)
    }

    /// One line for the Diagnostics menu: the same conditions `begin()` checks,
    /// in the same order, read from the APP's own TCC identity. A feature whose
    /// refusals are (deliberately) quiet has to be answerable without a
    /// rebuild — and a binary run from a terminal reads the terminal's
    /// microphone grant, not Pretype's, so this is the only place that can
    /// state it truthfully.
    var statusLine: String {
        guard Settings.dictationEnabled else { return "off" }
        guard MicrophoneAccess.isBundled else { return "unavailable — not running as an .app" }
        guard Transcription.isSupported else { return "unavailable — no system speech model on this Mac" }
        switch MicrophoneAccess.status {
        case .authorized: break
        case .notDetermined: return "microphone never asked for — hold the key and it will ask"
        case .denied: return "microphone DENIED — System Settings → Privacy & Security → Microphone"
        case .restricted: return "microphone blocked by policy"
        @unknown default: return "microphone unavailable"
        }
        let gesture = Settings.dictationGesture
        let latch = Settings.dictationLatch
        guard gesture != .off || latch != .off else { return "no key assigned" }
        let state: String
        switch phase {
        case .idle: state = "ready"
        case .preparing: state = "starting…"
        case .listening: state = "listening"
        case .working: state = "writing it down…"
        }
        // Both keys, because either one alone answers "why did nothing happen"
        // wrongly: a user who assigned only the latch and reads "Hold ⌥" goes
        // on holding a key that does nothing.
        let keys = [gesture == .off ? nil : gesture.label,
                    latch == .off ? nil : "\(latch.label) hands-free"]
            .compactMap { $0 }.joined(separator: " / ")
        return "\(keys) — \(state)"
    }

    // MARK: - Input

    /// Feed a `.flagsChanged` event from the key tap.
    func modifierChanged(_ event: CGEvent) {
        guard Settings.dictationEnabled else { return }
        // A hands-free capture owns the microphone until something stops it,
        // and the hold gesture is inert underneath. Guarded HERE rather than at
        // the outcome, so `hold` never books state for a capture it did not
        // start: fed these edges it would come out of the latch believing it
        // holds one, and the next release would fire an `.end` at nothing.
        //
        // Not while it is being written down, though: a hold reaching for the
        // NEXT sentence should queue behind the transcript exactly as one hold
        // queues behind another.
        guard !isLatchedAndLive else { return }
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
        // Nothing about a keystroke says anything about a latched capture: it
        // is not riding on a held key, so there is no chord to have been
        // building. The user is free to keep typing — including into the very
        // field the transcript is bound for, which is why the insert re-reads
        // the caret rather than trusting the one `begin` saw. ⎋ still cancels;
        // Settings promises that it does, for every capture.
        if isLatchedAndLive {
            _ = hold.keyPressed()
            guard isEscape else { return }
            Self.note("hands-free capture cancelled with ⎋")
            discard(notice: .hint(String(localized: "dictation cancelled")))
            return
        }
        // Release-then-keep-typing is the most natural gesture there is: a
        // take being written down goes to the clipboard, not away. ⎋ is still
        // a cancel — Settings promises "⎋ discards one already running".
        if !isEscape, rescueOnInterrupt() { return }
        // Mid-write a `.cancel` would only end a queued hold (see `apply`),
        // and this keystroke ends the take too — below.
        if let event = hold.keyPressed(), phase != .working { return apply(event) }
        // What is left mid-write is ⎋ or a voice command, and both are
        // dropped WITH a notice, unlike the other silent interrupts: a take
        // that vanishes without a word is indistinguishable from the feature
        // being broken. ⎋ gets its own wording — answering a deliberate
        // cancel with "you kept typing" reads as the app misreading it.
        let wasWorking = phase == .working
        discard(notice: wasWorking
            ? .hint(isEscape ? String(localized: "dictation cancelled") : String(localized: "dictation dropped — you kept typing"))
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
    /// Mid-`.working` the sentence is already finished, the finalize-plus-tidy
    /// window is seconds long (a whole upload, on a hosted API), and users
    /// click things while they wait — so it goes to the clipboard, same as
    /// `keyPressed`. A voice command dropped there earns a notice. A click
    /// during `.listening` stays silent: the pill vanishing under the click IS
    /// the explanation there.
    private func pointerInterrupted() {
        // Both of these exist because a held modifier is ambiguous — ⌥-click
        // and ⌃-scroll are ordinary gestures that happen to look like a hold.
        // A latch is not ambiguous about anything, and reading a page or
        // clicking something to check a fact while dictating a paragraph is
        // precisely what hands-free is for.
        guard !isLatchedAndLive else { return }
        guard isBusy || hold.isArmed else { return }
        guard !rescueOnInterrupt() else { return }
        _ = hold.interrupt()
        let wasWorking = phase == .working
        discard(notice: wasWorking ? .hint(String(localized: "dictation dropped — the caret moved")) : nil)
    }

    /// Focus moved, Pretype was paused, the app is quitting: whatever was being
    /// captured can no longer be typed anywhere sensible.
    func invalidate() {
        // Silent for a hold: the key came up, or the user switched apps with
        // one hand on a modifier, and a pill about it would be noise. A latched
        // capture is the opposite case — it can be minutes of speech, the user
        // has no key in their hand to tell them it was live, and losing a
        // paragraph without a word is exactly how this feature reads as broken.
        let spoken = isLatched
        // Already finishing: the transcript is done, and the finish task's own
        // focus check routes it to the clipboard now that it can't be typed
        // here. Discarding instead would drop it — and an app switch fires
        // this twice (focus change, then resign-active, ms apart), so the
        // second call would bump the generation under the finish the FIRST
        // one started for exactly this rescue. The capture QUEUED behind it is
        // another matter: that one would open the microphone in the app just
        // moved to, so it goes.
        if phase == .working {
            _ = hold.interrupt()
            if pendingBegin == .latch { pendingBegin = nil }
            return
        }
        _ = hold.interrupt()
        // …and a latched capture that has heard something is finished, not
        // discarded: `finish` sees the focus moved and hands the transcript
        // to `rescueDictated` instead of typing it into the wrong field.
        if spoken, heardSomething {
            Self.note("focus moved mid hands-free capture — finishing to the clipboard")
            return finish()
        }
        discard(notice: spoken ? .hint(String(localized: "dictation stopped — the focus moved")) : nil)
    }

    /// The live capture has words worth finishing rather than discarding. The
    /// preview is not enough on its own: a hosted API sends none, so its
    /// minutes of speech sit behind an empty `.listening("")` — the level
    /// meter is what knows someone spoke there.
    private var heardSomething: Bool {
        guard case .listening(let partial) = phase else { return false }
        return !partial.isEmpty || meter?.heardVoice == true
    }

    /// The latch chord, pressed. Starts a hands-free capture, or ends the one
    /// it started — and deliberately does nothing to a capture a held key owns,
    /// which has its own way of ending and would be surprising to stop from a
    /// key that never started it.
    func toggleLatch() {
        guard Settings.dictationEnabled else { return }
        switch phase {
        case .idle:
            begin(trigger: .latch)
        case .preparing, .listening:
            guard trigger == .latch else { return }
            finish()
        case .working:
            // Pressed while the last transcript is still being written down.
            // Queued rather than dropped, on the same grounds `begin` queues a
            // hold — except that a chord is its own toggle, so a second press
            // takes the queued capture back off again.
            guard trigger == .latch || pendingBegin == nil else { return }
            if pendingBegin == .latch {
                pendingBegin = nil
                Self.note("queued hands-free capture cancelled")
            } else {
                pendingBegin = .latch
                Self.note("still writing the last one down — hands-free capture queued")
            }
        }
    }

    private func apply(_ event: ModifierHold.Event?) {
        // Defence in depth behind `modifierChanged`'s guard: an arm timer
        // scheduled before the latch started could still be in flight, and a
        // `.begin` from it would open a second microphone under the first.
        //
        // The interrupt is not decoration. `hold.tick` has ALREADY set itself
        // holding by the time its `.begin` reaches here, and swallowing that
        // silently leaves the gesture believing it owns a capture it never
        // started: the modifier's release then reads as `.cancel` and throws
        // away the hands-free paragraph, blaming a cancel the user never made
        // — and the next genuine hold is a no-op, because `tick` starts
        // `guard !holding`. Safe here precisely because this never trips in
        // `.working`, which is where queueing a hold behind the write lives.
        guard !isLatchedAndLive else { _ = hold.interrupt(); return }
        switch event {
        case .begin: begin()
        case .end: finish()
        case .cancel where phase == .working:
            // Mid-write, the hold a `.cancel` ends is the one QUEUED behind the
            // take (`begin`): another modifier joined it, so it was a chord.
            // Only the queue goes — a modifier types nothing, the caret is
            // still where the take is headed, and it lands there. ⎋ drops the
            // take itself, in `keyPressed`.
            if pendingBegin == .hold { pendingBegin = nil }
            Self.note("queued hold turned into a chord — dropped it, still writing the last one down")
        case .cancel: discard(notice: .hint(String(localized: "dictation cancelled")))
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

    private func begin(trigger requested: Trigger = .hold) {
        guard let owner else { return }
        // The previous transcript is still being finalized (or tidied up — a
        // whole model generation, with polish on). Starting over here would
        // bump the generation and silently discard it, so the new hold WAITS
        // instead: the pill keeps saying "writing it down…", and the moment
        // the pending insert lands `resumePendingHold` starts this capture for
        // real. The key is still down by then, or it isn't and nothing happens.
        if phase == .working {
            pendingBegin = requested
            Self.note("still writing the last one down — capture queued")
            return
        }
        // One microphone, one capture. Only reachable now that two gestures can
        // ask for one, and cheap insurance against a third ever being added:
        // the paths that could double up are guarded at their own ends, and
        // this is where the damage would land if one of them ever isn't.
        guard phase == .idle else {
            Self.note("already capturing — ignoring a second start")
            return
        }
        trigger = requested
        // Every refusal below ends in "then <do the thing again>", and the
        // thing differs: telling someone who just pressed a chord to hold a key
        // sends them looking for a gesture that isn't the one they used.
        let latchKey = requested == .latch ? Settings.dictationLatch.label : nil
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
        // keep out of, pills included. A terminal is let through to the agent
        // check below, as for completions.
        guard Settings.enabled else { return refuse("Pretype is paused") }
        guard !gates.appIsActive() else { return refuse("our own window is frontmost") }
        guard AppPolicy.allowsCompletions(owner.typingContext) else {
            return refuse("off in \(owner.typingContext.appName ?? "this app")")
        }
        // Something has to receive the words. This is the only hard requirement:
        // typing into a window with no text focus would fire shortcuts instead
        // of writing a sentence.
        guard owner.hasFocusedTextField() else {
            return refuse("no text field in focus",
                          notice: .hint(latchKey.map { String(localized: "click into a text field, then press \($0) again") }
                              ?? String(localized: "click into a text field, then hold to talk")))
        }
        // Again: finding the field can read the site of one the focus tracker
        // missed, and that site may be switched off.
        guard AppPolicy.allowsCompletions(owner.typingContext) else {
            return refuse("off on \(owner.typingContext.site ?? "this site")")
        }
        // An open IME composition is the one focused-field state synthetic
        // keystrokes must never touch: they land inside the marked text and
        // garble or force-commit it, IME-dependent. Precise-only by design —
        // see `AXText.hasMarkedText` for why the coarse input-source fallback
        // is not consulted here.
        guard !owner.isComposingInFocusedField() else {
            return refuse("an IME composition is open",
                          notice: .hint(latchKey.map { String(localized: "finish composing that word, then press \($0) again") }
                              ?? String(localized: "finish composing that word, then hold to talk")))
        }
        // The privacy floor `AXText.context` normally enforces has to be
        // restated here, because the anchor read is no longer a gate: while
        // macOS reports secure input, a password field is focused somewhere and
        // nothing may be captured or typed.
        guard !gates.secureInput() else {
            return refuse("secure input is active",
                          notice: .hint(String(localized: "dictation stays out of password fields")))
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
        // A terminal's field reads only as an AI agent's input box (see
        // `AgentPrompt`); anywhere else in it is a shell, which would run what
        // it heard. Silent, like the blacklist this used to be.
        if AppPolicy.isTerminal(owner.typingContext.bundleID), anchor == nil {
            return refuse("a terminal outside an agent's prompt")
        }
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
                          notice: .error(String(localized: "dictation needs the built app — run make-app.sh")), at: rect)
        }
        guard gates.transcriptionSupported() else {
            return refuse("no system speech model", notice: .error(String(localized: "this Mac can't dictate")), at: rect)
        }
        // A released capture's language-pack download is still running (see
        // `discard`). A second session start now would race it for the same
        // install and reservation, so wait it out with the same words — but
        // only a download this capture's engine would wait on.
        guard !Transcription.isDownloading(for: Settings.resolvedDictationLocale) else {
            return refuse("the language pack is still downloading",
                          notice: .hint(String(localized: "getting the dictation model ready…")), at: rect)
        }
        guard gates.micStatus() == .authorized else {
            // Never asked. Dictation can be switched on without passing through
            // the Settings toggle that normally does the asking — a stored
            // default, a synced preference, a `defaults write` — and refusing a
            // key the user is *holding down* because of that is the worst
            // possible moment to be pedantic. Ask now; the next hold works.
            if gates.micStatus() == .notDetermined {
                refuse("microphone never asked for — asking now",
                       notice: .hint(latchKey.map { String(localized: "allow the microphone, then press \($0) again") }
                                     ?? String(localized: "allow the microphone, then hold to talk")), at: rect)
                Task { @MainActor in
                    let granted = await MicrophoneAccess.request()
                    Self.note("microphone \(granted ? "granted" : "refused")")
                    Settings.dictationEnabled = granted
                }
                return
            }
            return refuse("no microphone permission",
                          notice: .error(String(localized: "allow the microphone in Settings")), at: rect)
        }

        owner.prepareForDictation()
        restarts = 0
        firstRestartAt = Date()
        focusGeneration = owner.focusGeneration
        caretMoved = false
        startedInLauncher = owner.focusIsInLauncher
        caretRect = rect
        hostStyle = anchor?.host ?? HostTextStyle()
        contextBefore = anchor?.textBeforeCaret ?? ""
        commandSelection = Settings.dictationCommands
            ? anchor.flatMap { $0.selectedText.isEmpty ? nil : $0.selectedText } : nil
        Transcription.contextualWords.set(Transcription.biasWords(in: contextBefore))
        if let rect, let anchor { owner.noteCaret(rect: rect, host: anchor.host) }
        generation += 1
        let gen = generation
        phase = .preparing
        if Settings.dictationPolish || commandSelection != nil { owner.prewarmTidy() }
        render()
        owner.lastEvent = "listening…"
        Self.note("listening (\(requested == .latch ? Settings.dictationLatch.label + ", hands-free" : Settings.dictationGesture.label))")
        // Armed here, not at the `.listening` flip, so the ceiling covers
        // `.preparing` too: a hung session start with the key-up never
        // delivered (the disabled-event-tap case the ceiling exists for) would
        // otherwise say "starting dictation…" forever while suppressing the
        // whole completion pipeline.
        //
        // Always the SHORT bound here, whatever the trigger. `maxLatchedSeconds`
        // is argued as "past any dictation anyone sits through", which says
        // nothing about how long a session that never opened may hang — and ten
        // minutes of "starting dictation…" is ten minutes with the completion
        // pipeline suppressed behind `isBusy`. The capture re-arms itself at the
        // full ceiling once it is actually listening.
        armCeiling(maxCaptureSeconds, generation: gen)

        // Built here, not inside the task below: a closure written inside a
        // `[weak self]` task captures the task's optional `self` *variable*,
        // which is a data race the moment the transcriber calls it off-actor.
        let onPartial: @Sendable (String) -> Void = { [weak self] text in
            Task { @MainActor in self?.updatePartial(text, generation: gen) }
        }
        captureEpoch += 1
        let epoch = captureEpoch
        // Fresh per capture, so a buffer straggling out of the previous one
        // cannot count as this one having heard something. Written on the
        // delivery queue, read by `silenceTimer` — hence the lock inside, and
        // hence no main-actor hop per buffer: at 16 kHz that would be a
        // scheduled task every few milliseconds to answer one question every
        // quarter second.
        let meter = VoiceMeter()
        self.meter = meter
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
                try await self.openMic(for: session, meter: meter, generation: gen, epoch: epoch)
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
                // Re-armed from HERE, so the capture's own ceiling is measured
                // from the microphone actually opening rather than from a
                // key-down that may have spent a Bluetooth negotiation getting
                // here — and so a latch gets its long bound only now that there
                // is speech for it to be long about.
                self.armCeiling(self.ceilingSeconds, generation: gen)
                meter.opened()
                self.armSilenceWatch()
            } catch {
                started?.cancel()
                guard let self, self.generation == gen else { return }
                self.fail(error)
            }
        }
    }

    private func updatePartial(_ text: String, generation: Int) {
        guard self.generation == generation, case .listening(let previous) = phase else { return }
        phase = .listening(text)
        // A transcript that is still growing is the most trustworthy "someone
        // is speaking" signal available, and it is free — the analyzer only
        // repaints when it has heard words. It backs the energy meter up rather
        // than replacing it: the fallback transcriber that Russian and most
        // other locales run on reports far less often than a live level does,
        // so on its own it would end captures mid-sentence.
        if text != previous { meter?.noteVoice() }
        render()
    }

    /// Arm (or re-arm) the hard ceiling on the capture `generation` owns.
    ///
    /// Token-guarded as well as generation-guarded, because one capture arms
    /// this twice — the short bound at `begin`, the real one at the microphone
    /// opening — and both arms share a generation. Invalidating the old timer
    /// does not un-schedule a fire whose main-actor hop is already queued, and
    /// that hop landing after the re-arm would end the capture on the ceiling
    /// it had just been let out of.
    private func armCeiling(_ seconds: TimeInterval, generation gen: Int) {
        limitTimer?.invalidate()
        ceilingToken += 1
        let token = ceilingToken
        limitTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == gen, self.ceilingToken == token else { return }
                // The interrupt lives inside the cases: a fire racing
                // `finish()` into `.working` must be a true no-op, not one
                // that ends a second hold already queued behind the write.
                switch self.phase {
                case .listening:
                    Self.note("capture hit the \(Int(seconds))-second ceiling — finishing")
                    _ = self.hold.interrupt()
                    self.finish()
                case .preparing:
                    Self.note("still preparing when the capture ceiling hit — giving up on this hold")
                    _ = self.hold.interrupt()
                    self.discard(notice: .error(String(localized: "dictation couldn't start — try again")))
                default:
                    break
                }
            }
        }
    }

    /// Start the silence clock.
    ///
    /// Latched captures only. A held key already says when the user is done,
    /// and ending one because they paused to think would take away the single
    /// thing a hold is unambiguous about.
    private func armSilenceWatch() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        guard trigger == .latch, Settings.dictationSilence > 0 else { return }
        let gen = generation
        // One-shot, re-armed by each tick rather than repeating. A repeating
        // Timer is retained by the run loop and keeps firing after a `[weak
        // self]` has gone nil — there is nothing in the block to stop it —
        // whereas re-arming from the tick makes "no owner left to check"
        // terminate the clock for free.
        silenceTimer = Timer.scheduledTimer(
            withTimeInterval: silenceTick, repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                self.checkSilence()
            }
        }
    }

    private func checkSilence() {
        // The budget is re-read, not remembered: switching to "Never" while a
        // capture runs would otherwise make `quiet >= 0` true on the next tick
        // and end it on the spot.
        guard case .listening = phase, trigger == .latch,
              Settings.dictationSilence > 0, let meter else { return }
        let quiet = meter.quietFor(now: Date())
        // Before the first word the budget is a far longer one. Someone who
        // latched and is still gathering their thoughts has said nothing to
        // measure, and holding them to the same few seconds a mid-sentence
        // pause gets would break the feature for exactly the long-form
        // dictation it exists for. (Nothing heard by the end of it finishes
        // anyway, and an empty transcript says "nothing heard".)
        let budget = meter.heardVoice ? Settings.dictationSilence : openingSilenceSeconds
        guard quiet >= budget else { return armSilenceWatch() }
        Self.note("hands-free capture heard nothing for \(Int(quiet))s — finishing")
        finish()
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
        func end() {
            _ = hold.interrupt()
            if heardSomething {
                finish()
            } else {
                fail(AudioCapture.Failure.deviceChanged)
            }
        }
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
            return end()
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
            do {
                // The device is re-resolved, not remembered: the loss that
                // brought us here may be the very headset the automatic rule
                // steps around leaving the room.
                // The same meter across the swap: a capture that keeps going
                // through a device change is still one capture, and handing it
                // a fresh meter would restart its noise floor from scratch
                // mid-sentence — on the new device, in the same room.
                try await openMic(for: session, meter: meter, generation: gen, epoch: epoch)
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
        end()
    }

    /// Open the microphone for `session` under `epoch` (see `captureEpoch`),
    /// feeding it and `meter` — `begin`'s first open and `deviceChanged`'s
    /// restart alike.
    ///
    /// The device-change callback is built here, in a method, rather than
    /// inside a `[weak self]` task: there it would capture the task's optional
    /// `self` *variable*, a data race the moment the capture calls it from
    /// whatever thread the device-loss notification is posted on.
    private func openMic(for session: any TranscriptionSession, meter: VoiceMeter?,
                         generation gen: Int, epoch: Int) async throws {
        let onDeviceChange: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in await self?.deviceChanged(generation: gen, epoch: epoch) }
        }
        try await capture.start(
            deviceUID: AudioDevices.current(preference: .init(stored: Settings.dictationInput))?.uid,
            outputFormat: session.audioFormat, onDeviceChange: onDeviceChange
        ) { buffer in
            session.feed(buffer)
            meter?.feed(buffer)
        }
    }

    private func finish() {
        guard let owner else { return }
        if case .preparing = phase {
            // Released before the microphone opened. During a first-use
            // language-pack download that is expected — the download keeps
            // running (`discard` leaves it alone: it is the slow part, and
            // cancelling would mean starting over), so the next press is the
            // fast one. Otherwise it was only the microphone opening (a
            // Bluetooth input negotiates for 0.5–2 s), and "getting the model
            // ready" would send the user waiting for a download that isn't.
            discard(notice: .hint(Transcription.isDownloading(for: Settings.resolvedDictationLocale)
                ? String(localized: "getting the dictation model ready…")
                : String(localized: "too quick — the microphone was still opening")))
            return
        }
        guard case .listening(let heard) = phase, let session else { return }
        capture.stop()
        limitTimer?.invalidate()
        limitTimer = nil
        silenceTimer?.invalidate()
        silenceTimer = nil
        meter = nil
        phase = .working
        render()
        let gen = generation
        let targetFocus = focusGeneration
        let inLauncher = startedInLauncher
        let focusHeld = { owner.focusGeneration == targetFocus && owner.focusIsInLauncher == inLauncher }
        let deadline = session.finishDeadline ?? finalizeSeconds
        sessionTask = Task { @MainActor [weak self] in
            do {
                // Behind a deadline, because `finish` awaits the analyzer's own
                // finalization: a hung `finalizeAndFinishThroughEndOfInput`
                // would otherwise leave the pill saying "writing it down…"
                // forever, with the completion pipeline suppressed. Ten
                // seconds is far past any real finalization of a two-minute
                // ceiling's audio — this is a watchdog, not a budget. A
                // session that re-transcribes or uploads the whole take asks
                // for longer, growing with the take (`finishDeadline`).
                let raw = try await Self.withDeadline(seconds: deadline) {
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
                    self.discard(notice: .hint(String(localized: "nothing heard")))
                    return
                }
                if let selection = self.commandSelection {
                    // A spoken instruction, not text to type: no tidy-up (its
                    // punctuation doesn't matter), and nothing to rescue if the
                    // focus moved — the selection it was about is gone.
                    self.phase = .idle
                    self.session = nil
                    if focusHeld() {
                        owner.hideOverlay()
                        owner.applyVoiceCommand(transcript, to: selection)
                    } else {
                        // Said out loud like every other drop: a command that
                        // silently does nothing reads as the feature being broken.
                        Self.note("dropped a voice command — focus changed")
                        owner.showTransientOverlay(
                            .hint(String(localized: "voice command dropped — the focus moved")),
                            at: self.noticeRect, host: self.hostStyle)
                    }
                    self.resumePendingHold(noticeIfMissed: true)
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
                if focusHeld(), !self.caretMoved {
                    owner.insertDictated(text)
                } else {
                    Self.note("rescued \(text.count) chars to the clipboard — \(self.caretMoved ? "the caret moved" : "focus changed")")
                    owner.rescueDictated(text, because: focusHeld() ? .caretMoved : .focusMoved)
                }
                self.resumePendingHold(noticeIfMissed: true)
            } catch {
                guard let self, self.generation == gen else { return }
                // A watchdog that fired on a take with a live preview still has
                // that preview — on Parakeet and a local server, nearly the
                // whole take. Minutes of speech go to the clipboard, not away.
                // A voice command's preview is an instruction, not text: it fails.
                let preview = Self.clean(heard)
                if case TranscriptionError.timedOut = error, !preview.isEmpty, self.commandSelection == nil {
                    Self.note("finish timed out — rescued the \(preview.count)-char preview to the clipboard")
                    // A hold queued behind this take resumes inside `discard`;
                    // its pill replaces the notice once its microphone opens.
                    // The words are on the clipboard either way.
                    self.discard(notice: nil)
                    owner.rescueDictated(preview, because: .timedOut)
                    return
                }
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
        guard let queued = pendingBegin else { return }
        pendingBegin = nil
        // Only a hold can have gone away while it waited — a latch asked for a
        // capture with a keypress that is long over, and it still wants one.
        if queued == .hold, !hold.isActive {
            if noticeIfMissed, let owner {
                Self.note("queued hold released before the microphone could open")
                owner.showTransientOverlay(
                    .hint(String(localized: "wasn't listening yet — hold and say that again")),
                    at: noticeRect, host: hostStyle)
            }
            return
        }
        begin(trigger: queued)
    }

    /// Run the transcript through the engine's minimal-edit fix — the same pass
    /// ⌥⇥ uses on a selection. It restores the capitalization and punctuation
    /// speech doesn't carry, and its divergence guard means a model that starts
    /// paraphrasing gets rejected instead of rewriting what you said. nil ⇒ keep
    /// the transcript exactly as heard.
    ///
    /// On a hard time budget, because the whole `.working` window is hostile
    /// territory: any keystroke sends the transcript to the clipboard instead
    /// of the caret, and a queued next hold hasn't opened its microphone yet.
    /// The fix is one short generation when the model is loaded — but on an
    /// idle-unloaded engine it begins with a model RELOAD, tens of seconds the
    /// sentence must not be hostage to. Past the budget the transcript goes in
    /// exactly as heard.
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
            fixed = try await Self.withDeadline(seconds: polishSeconds) { @MainActor in
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
    var polishSeconds: TimeInterval = 3
    /// See `finish` — the watchdog on the analyzer's own finalization. A var
    /// for the same reason.
    var finalizeSeconds: TimeInterval = 10
    /// How often `checkSilence` reads the meter. Fine enough that the capture
    /// ends within a blink of the budget, coarse enough to be nothing next to
    /// the audio it is watching. Vars, again only so tests can shorten them.
    var silenceTick: TimeInterval = 0.25
    /// The silence budget BEFORE anything has been said — see `checkSilence`.
    var openingSilenceSeconds: TimeInterval = 30

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
                resumeOnce(.failure(TranscriptionError.timedOut))
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
    /// A task still *preparing* is left running only while it downloads the
    /// language pack: cancelling that would mean starting the download over
    /// on the next press. The generation bump is what makes that safe — the
    /// session it eventually produces is cancelled on arrival — and `begin`
    /// refuses while the download runs, so it is never one of two session
    /// starts racing each other. A preparing task that is only opening the
    /// microphone is cancelled like any other.
    private func discard(notice: SuggestionDisplayMode?) {
        guard isBusy else { return }
        generation += 1
        capture.stop()
        session?.cancel()
        session = nil
        if phase != .preparing || !Transcription.isDownloading(for: Settings.resolvedDictationLocale) {
            sessionTask?.cancel()
            sessionTask = nil
        }
        phase = .idle
        armTimer?.invalidate()
        armTimer = nil
        limitTimer?.invalidate()
        limitTimer = nil
        silenceTimer?.invalidate()
        silenceTimer = nil
        meter = nil
        // A queued LATCH does not survive a discard. What made the resume below
        // safe was that every interrupt path calls `hold.interrupt()` first, so
        // a queued hold could only still be there if the key was genuinely
        // still down — the user asking, right now. A latch has no such tell:
        // its press is long over, and every discard reaching here is an
        // explicit ⎋, a focus change, or a failure. Re-opening the microphone
        // on the far side of any of those is the opposite of what was asked,
        // and after ⎋ it is visibly so — `begin`'s repaint would wipe the
        // "dictation cancelled" pill with "starting dictation…".
        if pendingBegin == .latch { pendingBegin = nil }
        // Either the notice or the hide, never both: `hide` runs a fade whose
        // completion is only cancelled by a later show, so hiding first would
        // race a transient shown a line later against its own fade-out.
        if let owner {
            if let notice {
                // `noticeRect`, pointer included: fields that publish no
                // caret (web/Electron inputs before their first keystroke) are
                // exactly where dictation still runs, and a notice quietly
                // skipped there is the silent-vanish bug all over again.
                owner.showTransientOverlay(notice, at: noticeRect, host: hostStyle)
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
        // only the menu-bar dot. Hence `noticeRect`, pointer and all.
        let mode: SuggestionDisplayMode
        switch phase {
        case .idle:
            owner.hideOverlay()
            return
        case .preparing:
            mode = .status(String(localized: "starting dictation…"))
        case .listening(let text):
            mode = .listening(Self.tail(text))
        case .working:
            mode = .status(String(localized: "writing it down…"))
        }
        owner.showOverlay(mode, at: noticeRect, host: hostStyle)
    }

    /// Where this capture draws: its own caret, then the last one the field
    /// drew at, then the pointer — the same ladder a refusal notice uses.
    private var noticeRect: CGRect {
        caretRect ?? owner?.fallbackCaretRect ?? Self.pointerAnchor()
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
        raw.split(whereSeparator: { $0.isNewline || $0 == " " }).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Voice activity for one capture: written on the audio delivery queue, read
/// from the main actor, which is the whole reason it is a class with a lock
/// rather than a couple of fields on the controller.
///
/// Deliberately not a neural detector. The only question asked of it is "has
/// anything been said in the last few seconds", and it is asked in order to
/// decide whether to KEEP a capture alive — an asymmetric question. A frame
/// wrongly called speech costs a few more seconds of a capture the user can end
/// with the same chord that started it; a frame wrongly called silence cuts
/// somebody off mid-sentence. So the bar sits where speech clears it
/// comfortably, and the floor is learned rather than configured: a fanless
/// laptop in a quiet flat, a desk fan and a café all sit at different levels,
/// and none of them should be a setting the user has to find.
///
/// The floor only ever learns from frames it judged quiet. Averaging speech
/// into it is the classic way these drift — the floor climbs toward the talker,
/// the margin closes, and a long sentence reads as silence right when it
/// matters most.
final class VoiceMeter: Sendable {
    /// How far over the learned floor a frame must sit to count as speech.
    private static let marginDB: Float = 10
    /// An absolute bar under that, so a near-silent digital input — whose floor
    /// would otherwise learn its way down to the noise of the last bit — can't
    /// promote its own dither to speech.
    private static let absoluteDB: Float = -60
    /// How fast the floor follows the room. One buffer is a few tens of
    /// milliseconds, so this settles within about a second of the microphone
    /// opening and still tracks a fan that starts up mid-capture.
    private static let floorRate: Float = 0.05
    /// The floor is held inside this band whatever it is fed. The bottom stops
    /// a device that opens on digital silence (a warming USB microphone, a
    /// hardware-muted headset, the first frames after `startRunning`) from
    /// dragging the floor to −95 on a handful of all-zero buffers, which would
    /// leave ordinary room tone permanently clearing the bar. The top keeps a
    /// recalibration from a very loud room out of the range where speech itself
    /// would fail to clear it.
    private static let floorRange: ClosedRange<Float> = -65 ... -30
    /// A stretch with no quiet frame in it at all is itself a measurement —
    /// see `feed`.
    private static let recalibrateAfter: TimeInterval = 6

    private struct State {
        /// Starts pessimistically high: until the room has been measured, the
        /// margin above it is what keeps a noisy office from reading as speech
        /// on the very first buffer.
        var floorDB: Float = -50
        var lastVoiceAt: Date?
        var openedAt: Date
        /// The quietest thing heard since the last frame judged quiet, and when
        /// that was. Only used by the recalibration below.
        var quietestSinceQuiet: Float = .greatestFiniteMagnitude
        var lastQuietAt: Date
    }

    private let state: OSAllocatedUnfairLock<State>

    init(now: Date = Date()) {
        state = OSAllocatedUnfairLock(initialState: State(openedAt: now, lastQuietAt: now))
    }

    /// One delivered buffer. Runs on the capture's delivery queue.
    func feed(_ buffer: AVAudioPCMBuffer, now: Date = Date()) {
        let db = Self.decibels(buffer)
        state.withLock { state in
            guard db > state.floorDB + Self.marginDB, db > Self.absoluteDB else {
                // Quiet: this is the room, and the only thing the floor learns
                // from. Averaging speech in is how these estimators go deaf —
                // the floor climbs toward the talker, the margin closes, and a
                // long sentence reads as silence exactly when it matters.
                state.floorDB = min(max(state.floorDB + Self.floorRate * (db - state.floorDB),
                                        Self.floorRange.lowerBound),
                                    Self.floorRange.upperBound)
                state.lastQuietAt = now
                state.quietestSinceQuiet = .greatestFiniteMagnitude
                return
            }
            state.lastVoiceAt = now
            state.quietestSinceQuiet = min(state.quietestSinceQuiet, db)
            // ...but a room that is never quiet never gets measured at all. A
            // café, a desk fan, a microphone with the gain wound up: the very
            // first buffer clears the starting floor, so nothing ever takes the
            // branch above, the floor stays where it began, and every frame for
            // the rest of the capture reads as speech — which quietly turns the
            // silence auto-stop off altogether. So a long stretch without a
            // single quiet frame is itself the measurement: the quietest thing
            // in it is the room. Real speech never gets here — the stops
            // between words are quiet frames, and any one of them resets this.
            guard now.timeIntervalSince(state.lastQuietAt) >= Self.recalibrateAfter else { return }
            state.floorDB = min(max(state.quietestSinceQuiet, Self.floorRange.lowerBound),
                                Self.floorRange.upperBound)
            state.lastQuietAt = now
            state.quietestSinceQuiet = .greatestFiniteMagnitude
        }
    }

    /// The transcript grew — the analyzer heard words, whatever the level said.
    func noteVoice(now: Date = Date()) {
        state.withLock { $0.lastVoiceAt = now }
    }

    /// Restamp the clock to the moment the microphone actually opened.
    ///
    /// The meter has to be built before `capture.start` — the delivery closure
    /// captures it — but `begin` can be a whole language-pack download away
    /// from the first buffer, and the pre-first-word silence budget measured
    /// from there is spent on a wait nobody could have spoken into. Long
    /// enough, and the first check after the microphone opened would end the
    /// capture as "nothing heard" before the user got a word in.
    func opened(at now: Date = Date()) {
        state.withLock { state in
            state.openedAt = now
            state.lastQuietAt = now
        }
    }

    /// Anything at all has been heard since the microphone opened. Splits the
    /// two silence budgets apart — see `DictationController.checkSilence`.
    var heardVoice: Bool { state.withLock { $0.lastVoiceAt != nil } }

    /// How long since the last voiced frame, or since the microphone opened if
    /// there has never been one.
    func quietFor(now: Date = Date()) -> TimeInterval {
        state.withLock { now.timeIntervalSince($0.lastVoiceAt ?? $0.openedAt) }
    }

    /// RMS of one buffer as dBFS.
    ///
    /// An unreadable layout returns 0 dB — full scale, unconditionally voiced.
    /// The failure mode to avoid is a silence clock running blind on a format
    /// it cannot measure and ending captures that were going fine; a capture
    /// that never auto-stops still has its chord and its ceiling.
    nonisolated static func decibels(_ buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return -120 }
        let rms: Float
        if let channel = buffer.floatChannelData?[0] {
            rms = vDSP.rootMeanSquare(UnsafeBufferPointer(start: channel, count: frames))
        } else if let channel = buffer.int16ChannelData?[0] {
            let samples = UnsafeBufferPointer(start: channel, count: frames)
            rms = vDSP.rootMeanSquare(vDSP.integerToFloatingPoint(samples, floatingPointType: Float.self)) / 32768
        } else {
            return 0
        }
        guard rms > 0 else { return -120 }
        return 20 * log10(rms)
    }
}
