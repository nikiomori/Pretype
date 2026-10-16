import AppKit
import ApplicationServices

/// Owns the three text-fixing flows, kept separate from the completion pipeline:
///   1. fix-selection — ⌥⇥ on a selection asks the engine to correct it,
///   2. last-word fix — ⌥⇥ with no selection corrects the just-typed word,
///   3. inline spell-fix — a misspelled word at the caret shows a system
///      spell-check correction over it (⇥ applies), Cotypist-style.
///
/// A fix is always *previewed* and applied only on an explicit key — never
/// automatically. The controller reaches shared infrastructure (the overlay
/// window, the engine, the caret rect, the focus generation) through its
/// `owner`; it never drives the completion state directly beyond clearing it
/// when a fix preempts a suggestion.
@MainActor
final class CorrectionController {
    private unowned let owner: SuggestionController

    init(owner: SuggestionController) {
        self.owner = owner
    }

    /// A correction the engine proposed, shown as a preview and applied only
    /// when the user confirms (⏎/⇥/⌥⇥).
    private struct PendingFix {
        var original: String
        var replacement: String
        /// false → replace the user's active selection (typing over it). true →
        /// delete `original` (the just-typed word) first, then insert — the
        /// last-word fix, where nothing is selected in the app.
        var deletesOriginal = false
    }

    /// How a key event was handled, so the caller knows whether to swallow it.
    enum KeyOutcome {
        /// Consumed — do not forward to the app.
        case consumed
        /// Acted on, but the app should still see the key (e.g. Escape).
        case passThrough
        /// Not a correction key — let the completion handler try it.
        case ignored
    }

    private var selection: SelectionInfo?
    private var pendingFix: PendingFix?
    /// Inline spell-fix shown over the word at the caret (⇥ applies). Detected by
    /// the system spell-checker, separate from the LLM ⌥⇥ fix.
    private var activeCorrection: (word: String, fix: String)?
    /// A word whose correction the user dismissed with Escape — suppressed until
    /// the word changes, so it doesn't nag.
    private var dismissedCorrectionWord: String?
    /// Read by the caret indicator's `isQueryRunning` — a fix generation must
    /// keep the thinking dots alive just like a completion stream does.
    private(set) var inFlight = false
    private var correctionTask: Task<Void, Never>?

    // MARK: - Lifecycle

    /// Clear all in-progress fix state (called when the overlay is dismissed).
    func reset() {
        correctionTask?.cancel()
        correctionTask = nil
        selection = nil
        pendingFix = nil
        activeCorrection = nil
        inFlight = false
    }

    /// On a focus change, stop suppressing the previously-dismissed word.
    func focusChanged() {
        dismissedCorrectionWord = nil
    }

    // MARK: - Text-change hooks (called from SuggestionController.textDidChange)

    /// Handle a non-empty selection: keep a proposed fix on screen, or offer the
    /// ⌥⇥ affordance. Returns true if it took the overlay over (caller returns).
    /// When there is no selection it clears the selection state and returns false.
    func handleSelection(_ element: AXUIElement) -> Bool {
        if let info = AXText.selectionInfo(for: element) {
            // A selection switches the panel into fix-selection mode: drop any
            // live completion first.
            owner.clearActiveCompletion()
            owner.indicator.stop()
            let rect = info.rect ?? owner.lastCaretRect
            // A proposed fix for this exact selection stays up until accept/cancel.
            if let fix = pendingFix, fix.original == info.text {
                if let rect { owner.window.show(mode: .fixPreview(original: fix.original, fix: fix.replacement), at: rect) }
                return true
            }
            pendingFix = nil
            let fixable = info.text.count >= 3 && info.text.count <= 500
                && !info.text.contains("\n")
            if fixable, !inFlight {
                selection = info
                if let rect {
                    owner.window.show(mode: .shortcut(key: Settings.hotkeyStyle.correctionLabel, action: String(localized: "fix")), at: rect)
                }
            } else if !inFlight {
                selection = nil
                owner.window.hide()
            }
            return true
        }
        // The "fix" pill goes with its selection: in an app the completion
        // pipeline has gone quiet in, nothing else would ever repaint it.
        if case .shortcut = owner.window.currentMode { owner.window.hide() }
        selection = nil
        // A selection-fix preview ends when the selection is gone; a last-word
        // fix preview is re-validated against the caret context in handleCaret.
        if pendingFix?.deletesOriginal == false {
            pendingFix = nil
            owner.window.hide()
        }
        return false
    }

    /// Handle the caret context: revive a last-word fix preview if its word still
    /// sits before the caret, else show an inline spell-fix if the word is a
    /// typo. Returns true if it took the overlay over (caller returns).
    func handleCaret(_ ctx: TextContext) -> Bool {
        let text = ctx.textBeforeCaret

        // Keep a last-word fix preview up while that exact word still sits just
        // before the caret; once the user types or moves on, drop it.
        if let fix = pendingFix, fix.deletesOriginal {
            if let rect = ctx.caretRect,
               ctx.textAfterCaret.first?.isLetter != true,
               SpellChecker.trailingWord(of: text) == fix.original {
                owner.window.show(mode: .fixPreview(original: fix.original, fix: fix.replacement), at: rect)
                return true
            }
            pendingFix = nil
            // The preview pill must not outlive its word: nobody downstream is
            // guaranteed to redraw the overlay (the completion flow only shows
            // when it has something), so hide it here or it lingers forever.
            owner.window.hide()
        }

        // Escape suppresses a fix until the token under the caret changes.
        // lastToken, not trailingWord: trailingWord stops at ':', so a dismissed
        // ":shrug:" would read as "" and never un-suppress.
        let tokenAtCaret = Self.lastToken(of: text)
        if tokenAtCaret != dismissedCorrectionWord { dismissedCorrectionWord = nil }

        // Inline fix: a closed ":shrug:" previews 🤷, a misspelled word its
        // correction, over the token (⇥ applies). Takes priority over a
        // completion — fixing what's written matters more than predicting
        // ahead — but a live ⌥⇥ preview outranks it. A shortcode never reaches
        // the spell-check, or ":asdf:" would put a typo pill on "asdf". Nothing
        // downstream needs an emoji special case: the backspaces delete the
        // ASCII shortcode, so the Character-vs-UTF-16 mismatch that bites
        // elsewhere can't bite here, and the emoji is only ever inserted
        // (TextInjector.insert is surrogate-safe).
        if pendingFix == nil, ctx.textAfterCaret.first?.isLetter != true,
           tokenAtCaret != dismissedCorrectionWord,
           let caret = ctx.caretRect,
           let fix = tokenAtCaret.hasPrefix(":")
               ? EmojiShortcodes.emoji(for: tokenAtCaret)
               : tokenAtCaret.hasSuffix("=")
                   ? InlineCalculator.completion(for: tokenAtCaret)
                   : SpellChecker.correction(for: tokenAtCaret, context: text) {
            owner.clearActiveCompletion()
            owner.indicator.stop()
            activeCorrection = (word: tokenAtCaret, fix: fix)
            showCorrection(fix, word: tokenAtCaret, caret: caret, host: ctx.host)
            return true
        }
        if activeCorrection != nil {
            // The typo this pill was correcting is gone (edited, or the user
            // typed past it). Hide NOW — same reason as the pendingFix drop
            // above: no later stage reliably clears the overlay.
            activeCorrection = nil
            owner.window.hide()
        }
        return false
    }

    // MARK: - Key handling (called from SuggestionController.handleKeyDown)

    func handleKey(keyCode: Int64, flags: CGEventFlags) -> KeyOutcome {
        let style = Settings.hotkeyStyle

        // Check correction trigger based on active hotkey style
        if style.matchesCorrection(keyCode: keyCode, flags: flags) {
            // Same gate as ⏎ below: only a preview on screen is applied. One
            // that was never drawn, or that a notice has since covered, is
            // shown again instead — the press that looked like it did nothing
            // must not type an unseen rewrite over the selection.
            if let fix = pendingFix {
                if owner.window.showsCorrection { applyPendingFix() } else { showPreview(fix) }
                return .consumed
            }
            // Neither fix may run here, inside the event-tap callback: the
            // last-word fix does a synchronous AX read, and both build a request,
            // which reads the clipboard — a hung target app, or a huge or lazily
            // provided copy, would block the main thread and get the tap
            // disabled. Hop off the callback and consume the key now — the
            // correction hotkey isn't a system shortcut, so swallowing it even
            // when there's nothing to fix is harmless.
            let fixSelection = selection != nil
            DispatchQueue.main.async { [weak self] in
                if fixSelection { self?.correctSelection() } else { self?.correctLastWord() }
            }
            return .consumed
        }

        // While a proposed fix is on screen: ⏎ or style's accept key applies it, esc keeps the
        // original (but still reaches the app).
        //
        // `showsCorrection`, not `isVisible`: a dictation notice, an engine
        // status or a completion ghost also makes the window visible, and a
        // preview that was never painted (no caret rect to hang it on, which
        // web and Electron fields routinely report) would then let ⏎ apply a
        // rewrite nobody saw — and swallow the Enter that was meant to send
        // the message.
        if pendingFix != nil, owner.window.showsCorrection {
            if keyCode == KeyCode.returnKey || keyCode == KeyCode.keypadEnter || style.matchesAcceptWord(keyCode: keyCode, flags: flags) {
                applyPendingFix()
                return .consumed
            }
            if keyCode == KeyCode.escape {
                cancelPendingFix()
                return .passThrough
            }
        }

        // Inline spell-fix: style's accept key replaces the word, esc dismisses
        if let correction = activeCorrection, owner.window.showsCorrection {
            if style.matchesAcceptWord(keyCode: keyCode, flags: flags) {
                applyCorrection()
                return .consumed
            }
            if keyCode == KeyCode.escape {
                dismissedCorrectionWord = correction.word
                activeCorrection = nil
                owner.window.hide()
                return .passThrough
            }
        }
        return .ignored
    }

    // MARK: - Fix selection (⌥Tab)

    /// First ⌥⇥ on a selection: ask the engine for a fix and preview it. Runs
    /// off the event-tap callback (`makeRequest` reads the clipboard).
    private func correctSelection() {
        guard let sel = selection, !inFlight else { return }
        owner.lastCaretRect = sel.rect ?? owner.lastCaretRect
        runFix(
            selectionText: sel.text,
            request: owner.makeRequest(text: ""),
            makePending: { PendingFix(original: sel.text, replacement: $0) },
            proposedEvent: "fix proposed — ⏎ to apply, esc to keep"
        )
    }

    /// Voice command mode: the spoken `instruction` applied to `selection`,
    /// previewed and confirmed exactly like a ⌥⇥ fix — so ⏎/⇥ applies it over
    /// the selection (re-validated live), ⎋ keeps the original.
    func runVoiceCommand(_ instruction: String, selection text: String) {
        guard !inFlight else { return }
        if let element = owner.currentTextElement(), let rect = AXText.selectionInfo(for: element)?.rect {
            owner.lastCaretRect = rect
        }
        owner.clearActiveCompletion()
        runFix(
            selectionText: text,
            request: owner.makeRequest(text: ""),
            makePending: { PendingFix(original: text, replacement: $0) },
            proposedEvent: "voice command — ⏎ to apply, esc to keep",
            unchangedNotice: String(localized: "no change"),
            perform: { engine, request in
                try await engine.rewrite(selection: text, instruction: instruction, request: request)
            }
        )
    }

    /// ⌥⇥ with no selection: propose a fix for the just-typed last word. The
    /// caret must sit at the end of a word (mid-word is the completion's job).
    /// Runs off the event-tap callback (it does a synchronous AX read); a no-op
    /// when there's nothing fixable at the caret.
    private func correctLastWord() {
        guard !inFlight,
              let element = owner.currentTextElement(),
              // Re-checked here: resolving the element can read a site the
              // tap-side check didn't know yet.
              !AppPolicy.isBlacklisted(owner.typingContext),
              let ctx = AXText.context(for: element),
              let rect = ctx.caretRect else { return }
        // Not mid-word: the next character must not be a letter.
        guard ctx.textAfterCaret.first?.isLetter != true else { return }
        let word = SpellChecker.trailingWord(of: ctx.textBeforeCaret)
        guard word.count >= 3, word.count <= 40 else { return }

        owner.clearActiveCompletion()
        owner.lastCaretRect = rect
        let before = ctx.textBeforeCaret
        runFix(
            selectionText: word,
            request: owner.makeRequest(text: before),
            makePending: { PendingFix(original: word, replacement: $0, deletesOriginal: true) },
            proposedEvent: "last-word fix proposed — ⏎ to apply, esc to keep",
            perform: { engine, request in
                try await CorrectionGates.fixLastWord(word, before: before) {
                    try await engine.correct(selection: $0, request: request)
                }
            }
        )
    }

    /// Shared body for both ⌥⇥ flows: run the engine off the main actor, then on
    /// the main actor surface the proposal, a "looks fine" notice, or a failure —
    /// guarding on the focus generation so a result for stale context is dropped.
    private func runFix(
        selectionText: String,
        request: CompletionRequest,
        makePending: @escaping (String) -> PendingFix,
        proposedEvent: String,
        unchangedNotice: String = String(localized: "✓ looks fine"),
        perform: (@Sendable (any CompletionEngine, CompletionRequest) async throws -> String?)? = nil
    ) {
        inFlight = true
        owner.indicator.start()
        let engine = owner.engine
        let generation = owner.focusGeneration
        correctionTask = Task { [weak self] in
            let started = Date()
            let outcome: Result<String?, Error>
            do {
                if let perform {
                    outcome = .success(try await perform(engine, request))
                } else {
                    outcome = .success(try await engine.correct(selection: selectionText, request: request))
                }
            } catch is CancellationError {
                return
            } catch {
                outcome = .failure(error)
            }
            let elapsed = Date().timeIntervalSince(started)
            // The task inherits the main actor: nothing runs between this
            // check and the code below it.
            guard let self else { return }
            // reset() cancelled this task: its late result must not
            // resurrect the state reset() just cleared, nor stomp a newer
            // request's single-flight flag.
            guard !Task.isCancelled else { return }
            self.inFlight = false
            owner.indicator.stop()
            Stats.recordLatency(elapsed)
            // The user moved on while the engine ran: don't show a fix for
            // context that's no longer in front.
            guard owner.focusGeneration == generation else {
                DebugLog.shared.log("FIX", "dropped stale fix (focus changed)")
                return
            }
            switch outcome {
            case .success(let fixed?):
                let fix = makePending(fixed)
                // Nothing cancels the task while the user types on in the
                // same field, so a slow result can arrive for text that's
                // gone — showing it would swallow the next ⏎ (Enter-to-send)
                // for a fix that can never apply. Same check as inject().
                guard self.liveRead(confirming: fix) != nil else {
                    DebugLog.shared.log("FIX", "dropped stale fix — text changed while engine ran")
                    return
                }
                self.pendingFix = fix
                owner.lastEvent = proposedEvent
                DebugLog.shared.log("FIX", "proposed", detail: "\"\(selectionText)\" → \"\(fixed)\"")
                self.showPreview(fix)
            case .success(nil):
                owner.lastEvent = "nothing to fix"
                DebugLog.shared.log("FIX", "no changes for \"\(selectionText.prefix(60))\"")
                owner.indicator.flashTransient(.hint(unchangedNotice), orAtPointer: true)
            case .failure(let error):
                owner.lastEvent = "fix failed: \(error.localizedDescription)"
                DebugLog.shared.log("ERROR", "correction failed: \(error.localizedDescription)")
                owner.indicator.flashTransient(SuggestionController.failureNotice(error, fallback: String(localized: "fix failed")),
                                               orAtPointer: true)
            }
        }
    }

    /// Draw `fix`'s preview where its text is — or, when neither selection box
    /// nor caret could be read (web and Electron selections), under the
    /// pointer: a preview pending off screen is one ⏎ or ⌥⇥ would apply blind.
    private func showPreview(_ fix: PendingFix) {
        owner.window.show(mode: .fixPreview(original: fix.original, fix: fix.replacement),
                          at: owner.lastCaretRect ?? DictationController.pointerAnchor())
    }

    /// Confirm the previewed fix. A selection fix types over the selection; a
    /// last-word fix deletes the typed word first, then types the correction.
    private func applyPendingFix() {
        guard let fix = pendingFix else { return }
        pendingFix = nil
        selection = nil
        owner.window.hide()
        let event = "fixed \(fix.deletesOriginal ? "last word" : "selection") (\(fix.original.count) chars)"
        // The validating AX read must not run inside the event-tap callback (a
        // hung target app would stall the tap); hop off, then validate + inject.
        DispatchQueue.main.async { [weak self] in self?.inject(fix, event: event) }
    }

    /// Shared apply path for every fix flow: re-read the *live* text and inject
    /// only if it still matches what the fix was computed against. The preview
    /// is only re-validated on AX events, which trail typing by tens of ms — a
    /// confirm key landing in that gap (e.g. Enter-to-send right after a burst
    /// of typing) would otherwise delete and replace the wrong characters.
    private func inject(_ fix: PendingFix, event: String) {
        guard let live = liveRead(confirming: fix) else {
            DebugLog.shared.log("FIX", "dropped stale fix — text changed before apply")
            return
        }
        // Through the shared path, so the settle window covers a fix too: an
        // AX read still showing the typo would re-raise its pill, and a second
        // ⇥ — validated against that same stale read — would apply it twice.
        owner.inject(fix.replacement, deleting: fix.deletesOriginal ? fix.original : "", over: live.textBeforeCaret)
        Stats.recordCorrection()
        owner.lastEvent = event
        DebugLog.shared.log("FIX", "applied \"\(fix.original)\" → \"\(fix.replacement)\"")
        owner.scheduleKeystrokeRefresh(after: 0.12)
    }

    /// What a confirming live read saw: the text before the caret for a
    /// last-word fix, nil for a selection (typed over, so unknown).
    private struct LiveRead { var textBeforeCaret: String? }

    /// A live read, non-nil only while the text still matches what `fix` was
    /// computed against — a last-word fix needs its word still just before the
    /// caret, a selection fix the same selection. Synchronous AX read: never
    /// call inside the event-tap callback.
    /// Also re-anchors a caret a scroll forgot (`viewScrolled`), so a fix that
    /// lands after one is drawn at its text, not under the pointer.
    private func liveRead(confirming fix: PendingFix) -> LiveRead? {
        guard let element = owner.currentTextElement() else { return nil }
        if fix.deletesOriginal {
            guard let ctx = AXText.context(for: element),
                  ctx.textAfterCaret.first?.isLetter != true,
                  Self.lastToken(of: ctx.textBeforeCaret) == fix.original else { return nil }
            if owner.lastCaretRect == nil { owner.lastCaretRect = ctx.caretRect }
            return LiveRead(textBeforeCaret: ctx.textBeforeCaret)
        }
        guard let info = AXText.selectionInfo(for: element), info.text == fix.original else { return nil }
        if owner.lastCaretRect == nil { owner.lastCaretRect = info.rect }
        return LiveRead(textBeforeCaret: nil)
    }

    /// Dismiss the previewed fix and keep the original text untouched.
    private func cancelPendingFix() {
        guard pendingFix != nil else { return }
        pendingFix = nil
        owner.lastEvent = "fix dismissed"
        DebugLog.shared.log("FIX", "dismissed by user")
        owner.window.hide()
    }

    // MARK: - Inline spell-fix

    /// Places the inline spell-fix diff in a pill ABOVE the mistyped word. The
    /// word ends at the caret, so it starts one word-width to the left; anchoring
    /// the pill there lands it above the word it's correcting, not the caret.
    private func showCorrection(_ fix: String, word: String, caret: CGRect, host: HostTextStyle) {
        // Measure the word in the HOST's font — a system-font measurement put the
        // pill a word-width off in any field that doesn't use it.
        let font = host.font ?? .systemFont(ofSize: caret.height / 1.30)
        let wordWidth = ceil((word as NSString).size(withAttributes: [.font: font]).width)
        var wordRect = caret
        wordRect.origin.x = caret.maxX - wordWidth
        wordRect.size.width = wordWidth
        owner.lastCaretRect = caret
        owner.lastEvent = "typo \"\(word)\" → \"\(fix)\" (\(Settings.hotkeyStyle.label) to fix)"
        owner.window.show(mode: .correction(original: word, fix: fix), at: wordRect, host: host)
    }

    /// ⇥ on an inline spell-fix: replace the mistyped word with the correction.
    /// Routed through the same validate-then-inject path as the ⌥⇥ fixes.
    private func applyCorrection() {
        guard let correction = activeCorrection else { return }
        activeCorrection = nil
        owner.window.hide()
        let fix = PendingFix(original: correction.word, replacement: correction.fix,
                             deletesOriginal: true)
        let event = "fixed typo \"\(correction.word)\" → \"\(correction.fix)\""
        DispatchQueue.main.async { [weak self] in self?.inject(fix, event: event) }
    }

    /// The fixable token just before the caret: an emoji shortcode if one is
    /// closed there, else the plain word. Every revalidation path must go
    /// through this — `trailingWord` stops at ':', so a shortcode fix would read
    /// its original back as "" and fail to apply, silently.
    static func lastToken(of text: String) -> String {
        EmojiShortcodes.trailingShortcode(in: text)
            ?? InlineCalculator.trailingExpression(in: text)
            ?? SpellChecker.trailingWord(of: text)
    }
}
