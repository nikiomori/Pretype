import AppKit

@MainActor
extension SuggestionController {

    /// The hands-free dictation chord, and whether we are in any position to
    /// act on it.
    ///
    /// Every condition here is also a condition on SWALLOWING the key, which is
    /// what makes them load-bearing rather than tidy. ⌃⌥D is a plain letter
    /// chord that other apps bind, and the setting carrying it defaults to a
    /// real value while dictation itself defaults to off — so an unguarded
    /// match would quietly stop that chord working system-wide for every user
    /// who never turned dictation on, with nothing in the UI to explain it (the
    /// picker isn't even drawn until the feature is enabled).
    private func isLatchChord(keyCode: Int64, flags: CGEventFlags) -> Bool {
        let latch = Settings.dictationLatch
        guard latch != .off, Settings.dictationEnabled else { return false }
        // Matched before the fix chord: no latch chord may equal one
        // (HotkeyTests pins that).
        guard latch.matches(keyCode: keyCode, flags: flags) else { return false }
        // An app Pretype has been told to stay out of is one where holding on
        // to its keystrokes is still being in the way; `begin` would refuse a
        // moment later anyway, having already eaten the key. A terminal is
        // let through, as `begin` lets its agent prompt through.
        guard AppPolicy.allowsCompletions(typingContext) else { return false }
        // The same for a panel holding the keys whose app Pretype stays out of
        // (a password manager's quick-access panel): `begin` refuses it
        // silently. A capture already running still stops on the chord.
        if !dictationController.isBusy, let owner = focusedPanelOwner,
           DictationFocus.panel(ownedBy: env.bundleIdentifier(owner), hasTextField: { true }) == .offLimits {
            return false
        }
        // Our own Settings window: `begin` refuses while we are frontmost, so
        // swallowing here would take a keystroke out of our own text fields to
        // do nothing with it. A launcher holding the keys is not excluded:
        // `begin` types into its field (`dictationElement`), as it does for a
        // hold — and a hands-free capture still running under a launcher
        // opened mid-take has no other way to stop that keeps its words.
        return !isOwnUIFrontmost
    }

    func handleKeyDown(_ event: CGEvent) -> Bool {
        guard Settings.enabled else { return false }
        if event.getIntegerValueField(.eventSourceUserData) == TextInjector.magicTag { return false }
        // A real keystroke means a held modifier is part of a chord, not a tap.
        replyTap.keyPressed()

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        if flags.contains(.maskCommand) { promptContext.warmIfClipboardChanges() }

        // Hands-free dictation, started and ended by the same chord.
        //
        // FIRST, ahead of `keyPressed` below, because that call reads any
        // ordinary keystroke as "the modifier you were holding was part of a
        // chord" and throws the capture away — including the one this very
        // chord is being pressed to continue. Hold ⌥, say a sentence, release,
        // reach for ⌃⌥D to carry on hands-free, and the sentence would vanish
        // with a notice blaming you for typing.
        if isLatchChord(keyCode: keyCode, flags: flags) {
            field.undoable = nil
            // Autorepeat is swallowed and otherwise ignored. The WindowServer
            // sends these at ~15 Hz for as long as the chord is held, and a
            // toggle apiece would tear the capture down and re-open the input
            // device on every one — an HFP profile flip per frame on a
            // Bluetooth headset, which is the exact damage the device-change
            // circuit breaker exists to prevent, by a path it can't see.
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                // Off the tap before the AX reads `begin` makes, same rule as
                // the reply chord.
                env.hop { [weak self] in self?.dictationController.toggleLatch() }
            }
            return true
        }

        // ...and not someone talking either. Unconditional, because the window
        // that matters most is the one where there is no capture yet: ⌥⌫ and
        // ⌥-arrows hold the modifier across several presses, and a hold left
        // armed through them opens the microphone in the middle of a chord.
        // Idle this costs a cleared date. Escape is the explicit "forget that"
        // while listening, so it is ours to swallow — but only when it
        // cancelled a capture, which the call below decides: a ⎋ pressed in a
        // launcher opened over the field, or after the take went to the
        // clipboard, was meant for that app. Not in a launcher even then: its
        // ⎋ is also "close", and swallowed it left Spotlight open over the
        // field the capture was for.
        if dictationController.keyPressed(isEscape: keyCode == KeyCode.escape),
           !keyboardFocusIsElsewhere { return true }
        // Our own Settings/Debug field is focused — pass every key through
        // untouched (never accept a stale background suggestion into it).
        if isOwnUIFrontmost { return false }
        let keyEvent = NSEvent(cgEvent: event)
        if takeProvisionalSpace(typed: keyEvent?.characters, flags: flags) { return true }
        // Everything else is the pipeline's: one table decides
        // (`SuggestionController+Keys`), and this executes it.
        let undo = field.pendingUndo
        let key = KeyState(
            keyCode: keyCode, flags: flags,
            isCommandZ: Self.isPlainCommandZ(keyCode: keyCode,
                                             key: keyEvent?.charactersIgnoringModifiers?.lowercased(),
                                             flags: flags),
            canUndo: undo != nil,
            offHere: AppPolicy.isBlacklisted(typingContext) || dictationController.isBusy,
            // The last read found an agent's box: a terminal reads as nothing
            // anywhere else (`AXText.context`).
            agentBox: AppPolicy.isTerminal(typingContext.bundleID) && AppPolicy.allowsCompletions(typingContext)
                && field.cache != nil && !dictationController.isBusy,
            ghost: field.ghost, ghostOnScreen: window.showsSuggestion,
            style: Settings.hotkeyStyle, fixes: Settings.fixesEnabled, replies: Settings.repliesEnabled)
        let action = Self.keyAction(for: key,
                                    fix: { correctionController.handleKey(keyCode: keyCode, flags: flags) },
                                    focusElsewhere: { keyboardFocusIsElsewhere })
        switch action {
        case .undo:
            field.undoable = nil
            // Delete off the tap, after a live re-read: the cache trails typing
            // in Electron, and blind backspaces at a moved caret eat text.
            if let undo { env.hop { [weak self] in self?.undoAccept(undo) } }
            return true
        case .reply:
            field.undoable = nil
            env.hop { [weak self] in self?.replyComposer.compose() }
            return true
        case .fix(let swallowed):
            field.undoable = nil
            return swallowed
        case .accept(let chunk):
            // ponytail: no IME/marked-text check on the tap. The tap only
            // swallows while a ghost is up, and a composition kills the ghost
            // first: the keystroke that starts it doesn't match the ghost, so
            // `narrowActive()` drops it, and the ≤60 ms AX refresh then reads a
            // nil context (`AXText.isComposing`) and dismisses. Ceiling: a ghost
            // whose first character equals the keystroke that starts a
            // composition — narrowActive keeps it — with Tab landing inside that
            // same ≤60 ms window, where Tab accepts instead of picking a
            // candidate. Upgrade path if that's ever seen in the wild: query
            // `AXText.isComposing` on the focused element here too.
            accept(chunk: chunk)
            return true
        case .decline(let before, let after):
            // Escape still reaches the app (close a dialog, clear a field).
            resolveJournal(.dismissed)
            dismiss()
            field.decline(before: before, after: after)
            return false
        case .type:
            // Keep the ghost truthful before this keystroke reaches the app:
            // the re-read below is a 60 ms *throttle*, and an accept landing
            // inside that window would re-inject characters the OS already
            // typed (duplicating them). Worst in Electron apps, where AX
            // notifications are unreliable and the timer is the only update path.
            narrowActive(typed: keyEvent?.characters ?? "", flags: flags)
            // AX change notifications are unreliable in some apps (notably
            // Electron), so every keystroke also schedules a context re-read.
            reread.keyPressed()
            scheduleKeystrokeRefresh(keystrokeFallback: true)
            field.undoable = nil
            return false
        }
    }

    /// The space Words typed after a word, settled by the next key (a
    /// provisional space): a space is already there and is swallowed, punctuation takes its
    /// place ("tomorrow ." → "tomorrow."), anything else keeps it. Only while
    /// the field is exactly as the accept left it. Whether the key was taken.
    private func takeProvisionalSpace(typed: String?, flags: CGEventFlags) -> Bool {
        guard let snapshot = provisionalSpace else { return false }
        provisionalSpace = nil
        guard field.cache == snapshot, flags.isDisjoint(with: [.maskCommand, .maskControl, .maskAlternate]),
              let typed, let mark = Self.spaceSettlement(typed) else { return false }
        field.undoable = nil
        if mark == " " { return true }
        inject(mark, deleting: " ", over: snapshot)
        scheduleKeystrokeRefresh(after: 0.09)
        return true
    }

    /// What a key does to a provisional space: " " keeps the one there,
    /// closing punctuation replaces it; nil leaves it alone.
    nonisolated static func spaceSettlement(_ typed: String) -> String? {
        typed == " " || (typed.count == 1 && ".,;:!?)]}…".contains(typed)) ? typed : nil
    }

    /// Synchronously shrinks (or drops) the live suggestion to match a
    /// pass-through keystroke, using the characters `typed` carried by the
    /// event itself (`FieldState.keystroke`).
    private func narrowActive(typed: String, flags: CGEventFlags) {
        let chord = flags.contains(.maskCommand) || flags.contains(.maskControl)
        switch field.keystroke(typed, chord: chord) {
        case .narrowed(let remaining)?:
            // The pill re-render inside advance can flip back into a trimmed
            // ghost — same contract as show: never accept more than is on screen.
            if let shown = window.advance(past: typed, remaining: remaining), shown != remaining {
                field.ghost?.text = shown
            }
        case .retired(let outcome)?:
            retire(outcome)
        case .unchanged?, nil:
            break
        }
    }

    /// The one way text is typed into the host — accept, dictation, ⌘Z undo
    /// and every fix. Backspaces over `deleted`, types `text`, moves
    /// the synchronous cache in step and opens the settle window, so an AX
    /// read that still trails the synthetic keys can't re-offer, resurrect or
    /// re-fix what was just typed (a lagging read of the old typo re-showed its
    /// pill, and a second ⇥ applied the fix twice). `before` is the text
    /// before the caret as the edit starts — nil when unknown (a selection
    /// being typed over), which leaves the cache unknown too. Returns the
    /// cache after the edit.
    @discardableResult
    func inject(_ text: String, deleting deleted: String = "",
                over before: String?) -> String? {
        let keys = FieldState.keystrokes(replacing: deleted, with: text)
        if !keys.delete.isEmpty {
            // The field decides, not the app: xterm.js in VS Code or Cursor
            // deletes a cluster per press like a terminal app does.
            let element = env.trackedElement() ?? field.untracked?.element
            env.deleteBackward(keys.delete, element.map(env.isTerminalField)
                                  ?? AppPolicy.isTerminal(typingContext.bundleID))
        }
        if !keys.type.isEmpty { env.insert(keys.type) }
        return field.injected(text, deleting: deleted, over: before, at: env.now())
    }

    /// `keystrokeFallback`: only the keystroke's own re-read, which stands
    /// down when the edit's notifications brought one (`RereadSchedule`).
    func scheduleKeystrokeRefresh(after delay: TimeInterval = 0.06, keystrokeFallback: Bool = false) {
        guard reread.requestKeyReread(fallback: keystrokeFallback) else { return }
        env.after(delay) { [weak self] in
            guard let self, self.reread.keyRereadFired() else { return }
            self.textDidChange()
        }
    }

    /// ⌘Z after an accept: remove the injected chunk. Runs off the event-tap
    /// callback (synchronous AX read) and skips the deletion unless the live
    /// text still reads exactly like the post-accept snapshot — same
    /// validate-before-delete rule as `CorrectionController.inject`.
    func undoAccept(_ undo: FieldState.Undoable) {
        // Fail closed: an unreadable context (active selection, hung app,
        // secure input) skips the undo rather than deleting blindly — the
        // first backspace would eat a whole selection. The chunk stays cleared,
        // so the next ⌘Z reaches the app.
        guard let element = currentTextElement(),
              let ctx = env.context(of: element) else {
            DebugLog.shared.log("UNDO", "skipped — context unreadable")
            return
        }
        guard ctx.textBeforeCaret == undo.snapshot else {
            // A readable context that doesn't confirm yet usually means AX is
            // trailing the injected text (Electron): restore the state so the
            // next ⌘Z retries once AX catches up — any other keystroke still
            // clears it in handleKeyDown.
            field.undoable = undo
            DebugLog.shared.log("UNDO", "skipped — field no longer matches the post-accept snapshot")
            return
        }
        // Roll the pipeline back with the text: the shrunk ghost, the live
        // stream and the advanced cache all still assume the chunk is in the
        // field — a Tab or a streamed partial landing before the 0.09 s AX
        // refresh would re-accept or resurrect the just-undone word.
        let accepted = undo.chunk, wasDictated = undo.dictated
        inject("", deleting: accepted, over: ctx.textBeforeCaret)
        dismiss()
        // The strongest "no" there is: the field is back to exactly the text
        // the ghost was offered on, and the next refresh would query the same
        // context and draw the same ghost for ⇥ to type again. Declined like
        // a ⎋ until the field changes. A spoken chunk was no ghost.
        if !wasDictated, let before = field.cache {
            field.decline(before: before, after: ctx.textAfterCaret)
        }
        // A dictated chunk is a spoken sentence: it may be named by length
        // here, never quoted — the debug buffer is exported into bug reports
        // and this message field is not even length-capped on the way out.
        lastEvent = wasDictated
            ? "undid a dictation of \(accepted.count) characters"
            : "undid acceptance of \"\(accepted)\""
        DebugLog.shared.log(
            "UNDO", wasDictated ? "\(accepted.count) chars — redacted from log" : "\"\(accepted)\"")
        indicator.flashTransient(.hint(String(localized: "Undone")))
        // The accept was already journaled; an undo is the strongest reject
        // signal there is, so it gets its own event. Never for dictation: the
        // journal is on disk, the flow promises it never records a transcript,
        // and an `.undone` row only ever acts as a negative filter against a
        // phrase this pipeline suggested — which a spoken sentence never was.
        if !wasDictated {
            env.book(.undo(SuggestionJournal.Entry(
                ts: SuggestionJournal.timestamp(),
                app: typingContext.bundleID,
                engine: engine.name,
                ctx: String((field.cache ?? "").suffix(1000)),
                after: "",
                suggestion: accepted,
                outcome: .undone,
                acceptedChars: -accepted.count,
                shownForMs: 0,
                screen: false)))
        }
        scheduleKeystrokeRefresh(after: 0.09)
    }

    /// Type `chunk` — an accepted suggestion, or a dictation (`dictated`) —
    /// over `before`, and arm ⌘Z to take it back. `thenReturn`: a dictation
    /// into a chat that sends on Return; the app sends the text or opens a
    /// line, so the text before the caret is unknown and nothing is left for ⌘Z.
    func typeChunk(_ chunk: String, over before: String?, dictated: Bool, thenReturn: Bool = false) {
        let snapshot = inject(chunk, over: before)
        guard thenReturn else { return field.typed(chunk, snapshot: snapshot, dictated: dictated) }
        env.pressReturn()
        field.sent()
    }

    private func accept(chunk: String) {
        guard let current = field.ghost, !chunk.isEmpty else { return }
        // The cache advances in step with the injection (mirrors narrowActive
        // for user-typed keys). Until the 0.09 s AX refresh lands, a streamed
        // partial and the ⌘Z gate both read it — a stale marker re-arms the
        // just-accepted word (double insert on a second Tab) and makes an
        // immediate ⌘Z fall through to the app.
        // A whole word from Words comes with its space, which the next key
        // may take back (`takeProvisionalSpace`) — not before a line's text.
        let word = current.isInstant && Settings.activeSuggestionMode == .words
        let space = word && chunk == current.text && (current.after.first?.isNewline ?? true) ? " " : ""
        typeChunk(chunk + space, over: field.cache, dictated: false)
        provisionalSpace = space.isEmpty ? nil : field.cache
        env.book(.accepted(chunk: chunk, countSuggestion: !current.accepted, app: word ? nil : typingContext.bundleID))
        lastEvent = "accepted \"\(chunk)\""
        DebugLog.shared.log("ACCEPT", "\"\(chunk)\"")
        offer.accepted(chunk)
        if let remaining = field.advanceGhost(past: chunk) {
            // Slide the remaining ghost forward in place so accepting word by
            // word stays smooth; the keystroke refresh then re-anchors it on
            // the real caret. Its pill path can flip back into a trimmed ghost
            // — narrow what ⇧⇥ accepts to what it actually rendered.
            if let shown = window.advance(past: chunk, remaining: remaining), shown != remaining {
                field.ghost?.text = shown
            }
        } else {
            retire(.accepted)
            // A fully-accepted suggestion ends its stream. Otherwise a later
            // partial re-mints the ghost (with no recordShown), re-showing and
            // re-counting a continuation at the stale caret. The 0.09s refresh
            // below re-queries the extended context and re-streams cleanly.
            queries.cancel()
        }
        if !Settings.onboardingCompleted {
            Settings.onboardingCompleted = true
            onboardingWindow?.celebrate()
        } else if !current.accepted {
            onboardingWindow?.nextSuggestionAccepted()
        }
        // Re-read context once the synthetic keystrokes have landed.
        scheduleKeystrokeRefresh(after: 0.09)
    }

}
