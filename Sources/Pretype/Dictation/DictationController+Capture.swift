import AppKit
import AVFoundation

@MainActor
extension DictationController {
    // MARK: - Capture

    func begin(trigger requested: Trigger = .hold) {
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
            owner.report("dictation: \(why)")
            Self.note("not listening — \(why)")
            guard let notice else { return }
            // Falls all the way back to the POINTER when there is no caret to
            // hang a pill on. Every silent refusal in this flow has read as
            // "the feature is broken" — including to the person who wrote it —
            // so a notice with nowhere to go goes to where the user is looking.
            let anchor = rect ?? owner.fallbackCaretRect ?? Self.pointerAnchor()
            owner.showTransientOverlay(notice, at: anchor, host: owner.fallbackHostStyle)
        }
        // The "we should not be here at all" cases draw nothing on purpose — a
        // paused or blacklisted app is one Pretype has been told to keep out
        // of, pills included. A terminal is let through to the agent
        // check below, as for completions.
        guard Settings.enabled else { return refuse("Pretype is paused") }
        guard !owner.isOwnUIFrontmost else { return refuse("our own window is frontmost") }
        guard AppPolicy.allowsCompletions(owner.typingContext) else {
            return refuse("off in \(owner.typingContext.appName ?? "this app")")
        }
        // Something has to receive the words. This is the only hard requirement:
        // typing into a window with no text focus would fire shortcuts instead
        // of writing a sentence.
        switch owner.dictationFocus() {
        case .field:
            break
        case .offLimits:
            // A password manager's quick-access panel over an app that is on:
            // as off limits as the app itself, so the same silence — and
            // "click into a text field" would be wrong twice over, drawn over
            // the password manager at someone already in a field.
            return refuse("off in the panel that has the keys")
        case .noField:
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
        guard !owner.isSecureInputActive else {
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
        commandSelection = Settings.dictationCommands
            ? anchor.flatMap { $0.selectedText.isEmpty ? nil : $0.selectedText } : nil
        Transcription.contextualWords.set(Transcription.biasWords(in: anchor?.textBeforeCaret ?? ""))
        if let rect, let anchor { owner.noteCaret(rect: rect, host: anchor.host) }
        generation += 1
        let gen = generation
        phase = .preparing
        if Settings.dictationPolish || commandSelection != nil { owner.prewarmTidy() }
        render()
        owner.report("listening…")
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
        armCeiling(maxCaptureSeconds)

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
        let meter = VoiceMeter(now: clock())
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
                self.armCeiling(self.ceilingSeconds)
                meter.opened(now: self.clock())
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
        if text != previous { meter?.noteVoice(now: clock()) }
        render()
    }

    /// Arm (or re-arm) the hard ceiling on the capture in flight.
    ///
    /// One capture arms this twice — the short bound at `begin`, the real one
    /// at the microphone opening. The handler runs in the timer's own callout,
    /// not behind a main-actor hop, so the `invalidate()` here (and in
    /// `stopTimers`) leaves no queued fire of the old bound to land after the
    /// re-arm and end the capture on the ceiling it had just been let out of.
    private func armCeiling(_ seconds: TimeInterval) {
        limitTimer?.invalidate()
        limitTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The interrupt lives inside the cases: a fire in any other
                // phase must be a true no-op, not one that ends a second hold
                // already queued behind the write.
                switch self.phase {
                case .listening:
                    Self.note("capture hit the \(Int(seconds))-second ceiling — finishing")
                    _ = self.hold.interrupt()
                    self.finish()
                case .preparing:
                    Self.note("still preparing when the capture ceiling hit — giving up on this hold")
                    _ = self.hold.interrupt()
                    self.discardPreparing(otherwise: .error(String(localized: "dictation couldn't start — try again")))
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
        // One-shot, re-armed by each tick rather than repeating. A repeating
        // Timer is retained by the run loop and keeps firing after a `[weak
        // self]` has gone nil — there is nothing in the block to stop it —
        // whereas re-arming from the tick makes "no owner left to check"
        // terminate the clock for free.
        silenceTimer = Timer.scheduledTimer(
            withTimeInterval: silenceTick, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSilence() }
        }
    }

    private func checkSilence() {
        // The budget is re-read, not remembered: switching to "Never" while a
        // capture runs would otherwise make `quiet >= 0` true on the next tick
        // and end it on the spot.
        guard case .listening = phase, trigger == .latch,
              Settings.dictationSilence > 0, let meter else { return }
        let quiet = meter.quietFor(now: clock())
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
        let clock = clock
        try await capture.start(
            deviceUID: AudioDevices.current(preference: .init(stored: Settings.dictationInput))?.uid,
            outputFormat: session.audioFormat, onDeviceChange: onDeviceChange
        ) { buffer in
            session.feed(buffer)
            meter?.feed(buffer, now: clock())
        }
    }
}
