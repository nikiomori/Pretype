import AppKit
import AVFoundation

@MainActor
extension DictationController {
    func finish() {
        guard let owner else { return }
        if case .preparing = phase {
            // Released before the microphone opened. Unless a model download
            // is what it waits on, that was only the microphone opening (a
            // Bluetooth input negotiates for 0.5–2 s), and "getting the model
            // ready" would send the user waiting for a download that isn't.
            discardPreparing(otherwise: .hint(String(localized: "too quick — the microphone was still opening")))
            return
        }
        guard case .listening(let heard) = phase, let session else { return }
        capture.stop()
        stopTimers()
        phase = .working
        render()
        let gen = generation
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
                    if self.focusHeld {
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
                if self.focusHeld, !self.caretMoved {
                    owner.insertDictated(text)
                } else {
                    Self.note("rescued \(text.count) chars to the clipboard — \(self.caretMoved ? "the caret moved" : "focus changed")")
                    // Nothing resumes behind a rescue: its notice is how the
                    // user learns where the words went, and a queued capture's
                    // pill would paint over it at once. The next press starts it.
                    self.pendingBegin = nil
                    owner.rescueDictated(text, because: self.focusHeld ? .caretMoved : .focusMoved)
                }
                self.resumePendingHold(noticeIfMissed: true)
            } catch {
                guard let self, self.generation == gen else { return }
                // A final pass that timed out or failed outright — a model
                // error, a local server that went away — on a take with a live
                // preview still has that preview: on Parakeet and a local
                // server, nearly the whole take. Minutes of speech go to the
                // clipboard, not away. A voice command's preview is an
                // instruction, not text: it fails.
                let preview = Self.clean(heard)
                guard !preview.isEmpty, self.commandSelection == nil else { return self.fail(error) }
                var timedOut = false
                if case TranscriptionError.timedOut = error { timedOut = true }
                // The error itself goes where `fail` puts it, not into the
                // unified log: a server's message can quote anything.
                if !timedOut {
                    let why = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    DebugLog.shared.log("ERROR", "dictation: \(why)")
                }
                Self.note("finish \(timedOut ? "timed out" : "failed") — rescued the \(preview.count)-char preview to the clipboard")
                self.pendingBegin = nil  // as for a rescue above
                self.discard(notice: nil)
                owner.rescueDictated(preview, because: timedOut ? .timedOut : .failed)
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
        let fixed: String?
        do {
            // The same abandon-not-await race as the finalize watchdog: an
            // `engine.correct` mid-model-reload does not observe cancellation,
            // and a task group would wait for it anyway.
            fixed = try await Self.withDeadline(seconds: polishSeconds) { @MainActor in
                await owner.tidyDictation(text)
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
            let resumed = LockedValue(false)
            @Sendable func resumeOnce(_ result: Result<T, Error>) {
                if !resumed.exchange(true) { continuation.resume(with: result) }
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

    func fail(_ error: Error) {
        let why = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        owner?.report("dictation failed: \(why)")
        DebugLog.shared.log("ERROR", "dictation: \(why)")
        // Whatever failed, the session is gone — take the task with it.
        sessionTask?.cancel()
        sessionTask = nil
        discard(notice: .error(why))
    }

    /// The capture's ceiling and silence timers and its level meter, gone with
    /// it — on the way to `.working` or to `.idle`.
    private func stopTimers() {
        limitTimer?.invalidate()
        limitTimer = nil
        silenceTimer?.invalidate()
        silenceTimer = nil
        meter = nil
    }

    /// Give up on a capture still in `.preparing`. While the model download it
    /// waits on runs (a first-use language pack, Parakeet's 610 MB), that is
    /// the news rather than `notice`: the download carries on (see `discard`)
    /// and `begin` answers with the same words until it lands.
    func discardPreparing(otherwise notice: SuggestionDisplayMode) {
        discard(notice: Transcription.isDownloading(for: Settings.resolvedDictationLocale)
            ? .hint(String(localized: "getting the dictation model ready…")) : notice)
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
    func discard(notice: SuggestionDisplayMode?) {
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
        stopTimers()
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
}
