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
        var micBundled: () -> Bool = { MicrophoneAccess.isBundled }
        var micStatus: () -> AVAuthorizationStatus = { MicrophoneAccess.status }
        var transcriptionSupported: () -> Bool = { Transcription.isSupported }
        var startSession: @Sendable (Locale, @escaping @Sendable (String) -> Void)
            async throws -> any TranscriptionSession = {
                try await Transcription.start(locale: $0, onPartial: $1)
            }
        /// A speech API's failed take, written down on this Mac (`finish`).
        var transcribeOnDevice: @Sendable ([Float], Locale) async throws -> String = {
            try await Transcription.transcribeOnDevice($0, locale: $1)
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

    var trigger: Trigger = .hold

    /// A hands-free capture that has not been stopped yet. The hold gesture is
    /// inert under it (`modifierChanged`, `apply`); `.preparing` counts, for
    /// the reason `action(for:)` gives.
    private var isLatchedAndLive: Bool {
        trigger == .latch && isBusy && phase != .working
    }

    /// A keystroke or click landed while this take was being written down:
    /// the caret it was headed for has moved, so `finish` hands it to
    /// `rescueDictated` instead of typing it behind whatever was just typed or
    /// clicked. Reset by `begin`.
    var caretMoved = false

    /// Keyboard focus is still in the field this capture started in — the
    /// only place its words may be typed. Opening or closing a launcher fires
    /// no focus change, hence the second half.
    var focusHeld: Bool {
        guard let owner else { return false }
        return owner.focusGeneration == focusGeneration && owner.focusIsInLauncher == startedInLauncher
    }

    /// Something from outside the capture that may end it.
    enum Interrupt: Equatable {
        case key, escape, click, scroll
        /// Another modifier joined a held one (`ModifierHold`'s `.cancel`).
        case chord
        /// Focus moved, Pretype was paused, the app is quitting.
        case focusLost
    }

    enum InterruptAction: Equatable {
        /// The capture carries on, or the take being written lands as planned.
        case ignore
        /// The take being written goes to the clipboard: its caret moved.
        case rescue
        /// A hands-free take that lost its field: finished, to the clipboard.
        case finish
        /// Thrown away, saying `notice` (nil: silently).
        case discard(SuggestionDisplayMode?)
    }

    /// What `interrupt` does to a capture in `phase` — every interrupt rule in
    /// one table, applied by `interrupted(by:)`. `atOrigin` (⎋ only): focus is
    /// still where the capture started and its caret hasn't moved. `heard`
    /// (focus loss only): the capture has words worth finishing.
    ///
    /// A HOLD is a dead-man's switch: anything else the user does means "that
    /// wasn't dictation". A keystroke or chord says so out loud ("cancelled");
    /// a click, scroll or focus change ends it silently — the pill vanishing
    /// under the click is the explanation, and a user who switched apps with a
    /// hand on a modifier needs no pill about it.
    ///
    /// A LATCH stands down from all of that: hands-free means the user keeps
    /// using the machine — typing into the very field the transcript is bound
    /// for included, which is why the insert re-reads the caret — and a
    /// capture that died on the first scroll would be a hold with extra
    /// steps. `.preparing` included, load-bearingly — it
    /// is minutes on a first-use language-pack download, and "press the chord,
    /// then go and find what I was going to say" is the hands-free case
    /// exactly. ⎋ still cancels, as Settings promises — but only at its
    /// origin: ⌘Space opens Spotlight with no focus change and the capture
    /// stays live, so the ⎋ that closes Spotlight must not throw away minutes
    /// of speech. A focus change finishes a take that heard something (to the
    /// clipboard, `finish` sees the field is gone) and says so when it didn't:
    /// the user has no key in hand to tell them it was live.
    ///
    /// `.working`: the sentence is finished, and on a hosted API this is the
    /// whole upload — so nothing short of ⎋ at its origin throws it away. A
    /// keystroke or click moved the caret it was headed for, so it goes to the
    /// clipboard instead; a voice command can't be rescued (its selection is
    /// what moved) and is dropped with a notice — a take that vanishes
    /// without a word reads as the feature being broken. A scroll or a chord
    /// moves no caret (`TextInjector` types at keyboard focus): it lands. A
    /// focus loss leaves it to `finish`'s own focus check, which rescues it —
    /// an app switch fires two of these ms apart, and a discard from the
    /// second would drop the take the first one was rescuing. A ⎋ pressed
    /// away from its origin was meant for the app that has focus now.
    static func action(for interrupt: Interrupt, phase: Phase, trigger: Trigger,
                       isCommand: Bool, atOrigin: Bool, heard: Bool) -> InterruptAction {
        let cancelled = InterruptAction.discard(.hint(String(localized: "dictation cancelled")))
        switch (phase, trigger) {
        case (.idle, _):
            return .ignore
        case (.preparing, .latch), (.listening, .latch):
            switch interrupt {
            case .escape where atOrigin: return cancelled
            case .focusLost: return heard ? .finish : .discard(.hint(String(localized: "dictation stopped — the focus moved")))
            default: return .ignore
            }
        case (.preparing, .hold), (.listening, .hold):
            switch interrupt {
            case .key, .escape, .chord: return cancelled
            case .click, .scroll, .focusLost: return .discard(nil)
            }
        case (.working, _):
            switch interrupt {
            case .escape: return atOrigin ? cancelled : .ignore
            case .key: return isCommand ? .discard(.hint(String(localized: "dictation dropped — you kept typing"))) : .rescue
            case .click: return isCommand ? .discard(.hint(String(localized: "dictation dropped — the caret moved"))) : .rescue
            case .scroll, .chord, .focusLost: return .ignore
            }
        }
    }

    /// Apply `interrupt` to whatever is running — the one place its side
    /// effects happen. See `action(for:)` for what it decides.
    @discardableResult
    private func interrupted(by interrupt: Interrupt) -> InterruptAction {
        let action = Self.action(
            for: interrupt, phase: phase, trigger: trigger, isCommand: commandSelection != nil,
            // An AX read (`focusIsInLauncher`), so only for the ⎋ that asks.
            atOrigin: interrupt == .escape && isBusy && focusHeld && !caretMoved,
            heard: heardSomething)
        // Every interrupt ends a hold — armed, live, or queued behind the take
        // being written. A queued one it ended was a chord, a click or a zoom,
        // not someone asking to talk, so the queue forgets it. A focus loss
        // empties the queue outright: what is queued would open the microphone
        // in the app just moved to.
        let endedHold = hold.interrupt() != nil || interrupt == .chord
        if interrupt == .focusLost || (endedHold && pendingBegin == .hold) { pendingBegin = nil }
        switch action {
        case .ignore: break
        case .rescue: caretMoved = true
        case .finish:
            Self.note("focus moved mid hands-free capture — finishing to the clipboard")
            finish()
        case .discard(let notice):
            Self.note("capture ended by \(interrupt)")
            discard(notice: notice)
        }
        return action
    }

    var phase: Phase = .idle {
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
    /// is nothing heard to keep (`discardPreparing`: no error while a model
    /// download is what it waits on).
    let maxCaptureSeconds: TimeInterval = 120

    /// The same ceiling for a latched capture, where it means something else
    /// entirely. Nothing was ever going to arrive to end a hands-free capture —
    /// no release to miss — so this is not a safety net under a lost event but
    /// the only bound on a capture the user walked away from. Ten minutes is
    /// past any dictation anyone sits through and still short enough that a
    /// forgotten latch is not an open microphone for the afternoon. (Silence
    /// normally gets there first; this covers the room that is never quiet.)
    let maxLatchedSeconds: TimeInterval = 600

    /// The ceiling this capture is running under.
    var ceilingSeconds: TimeInterval {
        trigger == .latch ? maxLatchedSeconds : maxCaptureSeconds
    }

    /// Internal, not private: tests zero `hold.threshold` and fire the arm
    /// timer by hand.
    var hold = ModifierHold()
    /// Readable so a test can `fire()` one instead of waiting out its
    /// interval. Every handler runs on the main run loop with no actor hop, so
    /// the fire is the effect — and an `invalidate()` is a true cancel.
    var armTimer: Timer?
    var limitTimer: Timer?
    var silenceTimer: Timer?
    /// A start that arrived while the previous capture was still being written
    /// down, and what asked for it. Honored by `resumePendingHold` the moment
    /// that write resolves — the alternative was a generation bump that
    /// silently threw away the finished transcript, which is exactly what
    /// happens when someone dictates two sentences back to back with the
    /// tidy-up pass on.
    var pendingBegin: Trigger?
    /// Voice activity for the capture in flight, written on the delivery queue
    /// and read by `silenceTimer`. Replaced per capture, so a straggling buffer
    /// from the previous one cannot keep this one alive.
    var meter: VoiceMeter?
    let capture: any AudioCapturing
    var session: (any TranscriptionSession)?
    /// The language `session` was started in — and the one a failed upload
    /// is written down in on this Mac.
    var sessionLocale = Locale.current
    /// Readable so a test can await the step in flight — the session start,
    /// or the write-down — instead of guessing how long it takes.
    var sessionTask: Task<Void, Never>?

    init(capture: any AudioCapturing = AudioCapture()) {
        self.capture = capture
    }

    /// Bumped by every start and every discard: an async step that finishes
    /// after its capture was abandoned checks this and drops its result rather
    /// than typing it into whatever is focused now.
    var generation = 0

    /// Bumped by every `capture.start` — begin's and a mid-capture restart's.
    /// A device-loss notification already in flight when the tap restarts
    /// carries the OLD epoch and is dropped: one physical unplug can post both
    /// the disconnect and the session's runtime error, and counting the second
    /// against the circuit breaker (plus a redundant stop/start) helped nobody.
    var captureEpoch = 0

    /// Where the capture started — the field the words belong to. A result is
    /// only ever inserted while the focus generation still matches.
    var focusGeneration = 0
    var startedInLauncher = false
    var caretRect: CGRect?
    var hostStyle = HostTextStyle()
    /// The selection this capture's words are an instruction for (voice
    /// command mode), or nil for ordinary dictation.
    var commandSelection: String?

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
    /// the microphone half a second into an ordinary edit. What it does to a
    /// capture is `action(for:)`'s call.
    ///
    /// True when ⎋ cancelled a capture, and the caller swallows it. A ⎋ that
    /// cancelled nothing here was meant for the app, and goes through.
    @discardableResult
    func keyPressed(isEscape: Bool = false) -> Bool {
        let action = interrupted(by: isEscape ? .escape : .key)
        return isEscape && action != .ignore
    }

    /// A mouse press or a scroll ends a hold too. ⌥-click and ⌥-drag are
    /// ordinary gestures, and the click has just moved the caret away from
    /// where the words were going. Under "Hold ⌃" the gesture key is also the
    /// pinch-zoom modifier, so a ⌃-scroll held past the threshold would open
    /// the microphone mid-zoom; and during a live capture the view has just
    /// carried the caret out from under the pill. Armed counts as well as
    /// busy: that damage happens in the first `threshold` seconds, before a
    /// capture exists. The rest is `action(for:)`'s call.
    func pointerInterrupted(isScroll: Bool = false) {
        interrupted(by: isScroll ? .scroll : .click)
    }

    /// Focus moved, Pretype was paused, the app is quitting: whatever was being
    /// captured can no longer be typed anywhere sensible.
    func invalidate() {
        interrupted(by: .focusLost)
    }

    /// The live capture has words worth finishing rather than discarding. The
    /// preview is not enough on its own: a hosted API sends none, so its
    /// minutes of speech sit behind an empty `.listening("")` — the level
    /// meter is what knows someone spoke there.
    var heardSomething: Bool {
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
        case .cancel: interrupted(by: .chord)
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
            MainActor.assumeIsolated {
                guard let self else { return }
                self.armTimer = nil
                self.apply(self.hold.tick(now: Date()))
            }
        }
    }

    /// See the circuit breaker in `deviceChanged`.
    var restarts = 0
    var firstRestartAt = Date.distantPast
    static let maxRestarts = 3
    static let restartWindow: TimeInterval = 3

    /// See `polish` — how long the tidy-up may hold the transcript. A var only
    /// so tests can shorten it; nothing in the app writes it.
    var polishSeconds: TimeInterval = 3
    /// See `finish` — the watchdog on the analyzer's own finalization. A var
    /// for the same reason.
    var finalizeSeconds: TimeInterval = 10
    /// See `finish` — how long writing a failed upload down on this Mac may
    /// take, before its share per audio second. A var for the same reason.
    var fallbackSeconds: TimeInterval = 30
    /// How often `checkSilence` reads the meter. Fine enough that the capture
    /// ends within a blink of the budget, coarse enough to be nothing next to
    /// the audio it is watching.
    let silenceTick: TimeInterval = 0.25
    /// The silence budget BEFORE anything has been said — see `checkSilence`.
    let openingSilenceSeconds: TimeInterval = 30
    /// What the level meter and `checkSilence` read the time from. A var only
    /// so tests can step it past a budget instead of sleeping through one.
    var clock: @Sendable () -> Date = { Date() }
}
