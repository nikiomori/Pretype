import AppKit

// Dictation's side of the controller: the transcript goes in through the same
// injection path an accept takes, or onto the clipboard when it can't.
extension SuggestionController {
    /// Type a finished dictation into the field it was spoken into.
    ///
    /// Goes through the same bookkeeping an accepted suggestion does — advance
    /// the synchronous cache, arm the settle window, arm ⌘Z — because the
    /// hazards are identical: a streamed partial must not anchor on the
    /// pre-injection context, and a misheard sentence has to be one keypress
    /// away from gone. The field is re-read first: the transcript arrives
    /// hundreds of milliseconds after the words were spoken, and only the live
    /// caret can say whether a space belongs at the seam.
    func insertDictated(_ text: String) {
        guard !text.isEmpty else { return }
        // Synthetic keystrokes land in whatever holds keyboard focus RIGHT NOW,
        // not in the element the capture pinned — so the checks `begin()` made
        // hundreds of milliseconds ago have to be remade at the moment of
        // injection. Our own app frontmost means the transcript would type into
        // Pretype's menu or Settings; secure input means a password field took
        // focus in a way no AX notification reports (a browser engaging kernel
        // secure entry, a SecurityAgent sheet).
        //
        // Each drop gets a notice as well as a log line: the pill said
        // "writing it down…" and was hidden just before this ran, so a silent
        // return here is the sentence vanishing into nothing — the exact
        // failure the refusal ladder in `begin()` was built to prevent. The
        // secure-input case especially can engage with no user action that
        // would explain the disappearance.
        //
        // A hands-free capture can be minutes of speech, so the words are not
        // thrown away with the notice: see `parkDictation`.
        func drop(_ why: String, notice: String) {
            DictationController.note("dropped \(text.count) chars to the clipboard — \(why)")
            parkDictation(text, why: why, notice: notice)
        }
        // Paused while the words were being written down (pausing finishes a
        // hands-free capture rather than throwing it away): the switch means
        // nothing gets typed, so the sentence goes to the clipboard.
        guard Settings.enabled else {
            return drop("Pretype was paused", notice: String(localized: "paused — dictation copied, ⌘V to paste"))
        }
        guard !NSApp.isActive else {
            return drop("our own window took focus", notice: String(localized: "Pretype's window took focus — dictation copied, ⌘V to paste"))
        }
        guard !AXText.isSecureInputActive() else {
            return drop("secure input engaged", notice: String(localized: "a password field took focus — dictation copied, ⌘V to paste"))
        }
        guard dictationElement() != nil else {
            return drop("no text field", notice: String(localized: "no text field in focus — dictation copied, ⌘V to paste"))
        }
        // Remade at injection time like the rest: a composition opened during
        // the capture (the transcript arrives hundreds of milliseconds after
        // the words) would swallow the synthetic keystrokes into its marked
        // text. Precise marked-text only — see `isComposingInFocusedField`.
        guard !isComposingInFocusedField() else {
            return drop("an IME composition is open", notice: String(localized: "a composition is open — dictation copied, ⌘V to paste"))
        }
        // Advisory, exactly as at capture time: a field that publishes no caret
        // (web and Electron inputs before their first keystroke) must still
        // receive what was said. Without the read there is no seam to judge and
        // no snapshot to undo against, so both are skipped rather than guessed.
        // Through the same re-resolving read the anchor uses — the handle this
        // very method invalidated last time is the one that would fail here.
        let context = dictationFieldContext()
        // Dictation took the words in a terminal only inside an agent's input
        // box; one that closed meanwhile leaves a shell under the caret.
        if AppPolicy.isTerminal(typingContext.bundleID), context == nil {
            return drop("the agent prompt closed", notice: String(localized: "the agent prompt closed — dictation copied, ⌘V to paste"))
        }
        let before = context?.textBeforeCaret
        clearActiveCompletion()
        window.hide()
        // Both seams come out of that one read: the caret can sit mid-sentence
        // (dictating into a half-written line), and the text after it decides
        // the trailing space exactly as the text before it decides the leading
        // one. A second AX round-trip would only re-read the same snapshot.
        let chunk = context.map {
            Self.spacedForInsertion(text, after: $0.textBeforeCaret, before: $0.textAfterCaret)
        } ?? text
        // Without a read the cache is unknown, not the old field's text — and a
        // launcher's text is no cache of the tracked field's, nor a ⌘Z of ours.
        let inLauncher = keyboardFocusIsElsewhere
        let snapshot = inject(chunk, over: inLauncher ? nil : before)
        // Sent: the app empties the field (or opens a line), so the text known
        // to be before the caret is gone and there is nothing for ⌘Z to take back.
        let sends = !inLauncher && AppPolicy.sendsAfterDictation(typingContext)
        if sends {
            TextInjector.press(KeyCode.returnKey, times: 1)
            latestTextBeforeCaret = nil
        }
        // ⌘Z removes it exactly like an accepted suggestion — but the undo
        // path books what it removed, and this chunk was spoken.
        undoable = sends ? nil : snapshot.map { Undoable(chunk: chunk, snapshot: $0, dictated: true) }
        // The transcript's own length, not the chunk's: the seam spaces are
        // typing mechanics, and the counter claims to measure what was said.
        Stats.recordDictated(chars: text.count)
        lastEvent = "dictated \(chunk.count) characters"
        // The transcript itself never reaches the log: the debug buffer is
        // exportable for bug reports, and what was said aloud is as sensitive
        // as the OCR'd screen and the clipboard, both of which the prompt log
        // redacts the same way. The count is the whole diagnostic value here.
        DictationController.note("typed \(chunk.count) characters" + (sends ? " and pressed Return" : ""))
        scheduleKeystrokeRefresh(after: 0.09)
    }

    /// A transcript that can't be typed goes to the clipboard, one ⌘V from
    /// wherever it was meant to land, and the notice says so. Marked
    /// transient, so clipboard managers keep it out of their on-disk history —
    /// no transcript is ever written to disk — and kept off other devices.
    private func parkDictation(_ text: String, why: String, notice: String) {
        let pasteboard = NSPasteboard.general
        // This Mac only: Universal Clipboard ignores the transient marker and
        // would offer the transcript to every device on the iCloud account.
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        lastEvent = "dictation copied to the clipboard — \(why)"
        showTransientOverlay(.hint(notice),
                             at: lastCaretRect ?? DictationController.pointerAnchor(),
                             host: lastHostStyle)
    }
}

// What dictation is allowed to see of this controller — the protocol keeps the
// capture state machine testable without an AX tree or a window server, and
// keeps `DictationController` from growing casual reach into the completion
// pipeline. `insertDictated` (above), `noteCaret`, `typingContext`,
// `focusGeneration` and `lastEvent` already satisfy their requirements.
extension SuggestionController: DictationHost {
    var fallbackCaretRect: CGRect? { lastCaretRect }
    var fallbackHostStyle: HostTextStyle { lastHostStyle }

    func hasFocusedTextField() -> Bool { dictationElement() != nil }

    var focusIsInLauncher: Bool { keyboardFocusIsElsewhere }

    /// The field a dictation types into. Unlike the pipeline's, a launcher's
    /// counts (Spotlight, Raycast): the transcript is typed into whatever holds
    /// keyboard focus, and a search spoken into Spotlight is a fine use — it is
    /// only a ghost from the app underneath that must never land there.
    private func dictationElement() -> AXUIElement? {
        keyboardFocusIsElsewhere ? AXText.systemFocusedTextElement() : currentTextElement()
    }

    /// Precise marked-text only — `AXText.hasMarkedText`, not `isComposing` —
    /// so a CJK input source merely being SELECTED (the coarse fallback's
    /// answer in Electron/Chromium) doesn't ban dictation wholesale where it
    /// demonstrably works today.
    func isComposingInFocusedField() -> Bool {
        dictationElement().map(AXText.hasMarkedText) ?? false
    }

    func prepareForDictation() {
        clearActiveCompletion()
        correctionController.reset()
        indicator.stop()
    }

    func dictationAnchor() -> DictationAnchor? {
        guard let ctx = dictationFieldContext() else { return nil }
        // Only read when it can matter: the selection is a voice command's target.
        let selected = Settings.dictationCommands
            ? dictationElement().flatMap { AXText.selectionInfo(for: $0)?.text } ?? "" : ""
        return DictationAnchor(caretRect: ctx.caretRect, host: ctx.host,
                               textBeforeCaret: ctx.textBeforeCaret, selectedText: selected)
    }

    /// The focused field, read for a dictation — with one re-resolve when the
    /// tracked handle answers nothing.
    ///
    /// Web and Electron apps REPLACE the focused node when their value
    /// changes, and typing a transcript into one is exactly such a change.
    /// They do it without an AX focus notification, so the tracker keeps
    /// handing out a handle every read now fails on: reported from real use as
    /// a second dictation that recorded but drew no pill (the log said "field
    /// publishes no caret yet" for every capture after the first). The same
    /// dead handle costs `insertDictated` its seam space, which would run two
    /// dictated sentences together.
    ///
    /// Read-only on purpose: re-latching the tracker here would fire a focus
    /// change, and a focus change discards the capture being read for.
    private func dictationFieldContext() -> TextContext? {
        func read(_ element: AXUIElement) -> TextContext? {
            AXText.context(for: element, allowEmpty: true)
        }
        // In a launcher the tracked field is the app underneath; the system's
        // focused element is the launcher's own field.
        if !keyboardFocusIsElsewhere, let element = focusTracker.focusedTextElement,
           let ctx = read(element) { return ctx }
        guard let fresh = AXText.systemFocusedTextElement() else { return nil }
        return read(fresh)
    }

    func showOverlay(_ mode: SuggestionDisplayMode, at rect: CGRect, host: HostTextStyle) {
        // A live capture's own pill outranks a protected notice: the
        // protection guards notices from the completion pipeline's chatter,
        // not from the next capture the user has already started — held
        // within the protection window, the "starting dictation…" status
        // would otherwise be refused and the stale notice would sit at the
        // caret while the microphone is genuinely opening.
        window.clearNoticeProtection()
        window.show(mode: mode, at: rect, host: host)
    }

    func showTransientOverlay(_ mode: SuggestionDisplayMode, at rect: CGRect, host: HostTextStyle) {
        // A notice takes the window from whatever was in it — and a ghost left
        // `active` under an opaque pill stays Tab-acceptable while invisible,
        // which is how ⇥ inserts text nobody saw. `CaretIndicator.flashTransient`
        // answers this by refusing to draw; dictation cannot, because a refusal
        // the user can't see is the failure this whole flow was built around.
        // So the ghost is retired instead of hidden.
        //
        // The refusals in `begin()` are exactly the ones that need it: a bare
        // modifier posts no key-down, so holding the dictation key never
        // narrows or drops a suggestion that is already on screen.
        clearActiveCompletion()
        // Nothing is torn down on CorrectionController's behalf: its previews
        // now gate on `window.showsCorrection`, so a notice taking the window
        // already makes them un-appliable, and clearing them here is what broke
        // the ⌥⇥ chord — this runs from `dictationController.keyPressed()`,
        // i.e. BEFORE `correctionController.handleKey`, on the very ⇥ that
        // completes it.
        // Every dictation notice is raised by something that also wakes the
        // completion pipeline — a keystroke, a release, a focus-adjacent
        // event — so each needs a moment of immunity or it never gets read.
        window.showTransient(mode, at: rect, host: host, protectFor: 1.2)
    }

    func hideOverlay() { window.hide() }

    func rescueDictated(_ text: String, because reason: DictationRescue) {
        switch reason {
        case .focusMoved:
            parkDictation(text, why: "the focus moved",
                          notice: String(localized: "focus moved — dictation copied, ⌘V to paste"))
        case .caretMoved:
            parkDictation(text, why: "the caret moved",
                          notice: String(localized: "the caret moved — dictation copied, ⌘V to paste"))
        case .timedOut:
            parkDictation(text, why: "transcription timed out",
                          notice: String(localized: "transcription timed out — the preview is copied, ⌘V to paste"))
        }
    }

    func applyVoiceCommand(_ instruction: String, to selection: String) {
        correctionController.runVoiceCommand(instruction, selection: selection)
    }

    func dictationBusyChanged() { updateScrollMonitoring() }

    func prewarmTidy() {
        // Fetched only: a download is the tidy-up's own call (see below).
        if engine.isCorrectionReady { engine.prewarmCorrection() }
    }

    func tidyDictation(_ text: String) async -> String? {
        // A fix model that still has to be fetched cannot help THIS sentence:
        // the tidy-up budget is three seconds and the download is gigabytes.
        // Waiting would only stall every dictation behind a progress bar it
        // can't outlast, so the words go in as heard and the fetch starts in
        // the background for the next one — on an unmetered network only:
        // nobody asked for gigabytes over a hotspot to tidy a sentence. On
        // one, the first ⌥⇥ (which the user does ask for) fetches it.
        guard engine.isCorrectionReady else {
            if await ModelStorage.isNetworkUnmetered() {
                engine.prewarmCorrection()
                DictationController.note("tidy-up skipped — fetching the fix model for next time")
            } else {
                DictationController.note("tidy-up skipped — fix model not downloaded, network metered or offline")
            }
            return nil
        }
        // `redactLog` is the whole point of the parameter: what is being fixed
        // here was SPOKEN, and the divergence guard's rejection path logs the
        // pair verbatim otherwise — into a buffer whose export dialog only
        // warns about text the user typed.
        let fixed = try? await engine.correct(selection: text, redactLog: true)
        guard let fixed, !fixed.isEmpty, fixed != text else { return nil }
        return fixed
    }
}
