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
    weak var owner: SuggestionController?

    /// A correction the engine proposed, shown as a preview and applied only
    /// when the user confirms (⏎/⇥/⌥⇥).
    private struct PendingFix {
        var original: String
        var replacement: String
        /// 0 → replace the user's active selection (typing over it). N → delete
        /// the last N characters (the just-typed word) first, then insert — the
        /// last-word fix, where nothing is selected in the app.
        var deleteCount: Int = 0
    }

    private struct SelectionState {
        var text: String
        var rect: CGRect?
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

    private var selection: SelectionState?
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
        guard let owner else { return false }
        if let info = AXText.selectionInfo(for: element) {
            // A selection switches the panel into fix-selection mode: drop any
            // live completion first.
            owner.clearActiveCompletion()
            owner.indicator.stop()
            let rect = info.rect ?? owner.lastCaretRect
            // A proposed fix for this exact selection stays up until accept/cancel.
            if let fix = pendingFix, fix.original == info.text {
                if let rect { owner.window.show(mode: .fixPreview(fix.replacement), at: rect) }
                return true
            }
            pendingFix = nil
            let fixable = owner.engine.supportsCorrection
                && info.text.count >= 3 && info.text.count <= 500
                && !info.text.contains("\n")
            if fixable, !inFlight {
                selection = SelectionState(text: info.text, rect: info.rect)
                let hintText = "\(Settings.hotkeyStyle.correctionLabel) fix"
                if let rect { owner.window.show(mode: .hint(hintText), at: rect) }
            } else if !inFlight {
                selection = nil
                owner.window.hide()
            }
            return true
        }
        selection = nil
        // A selection-fix preview ends when the selection is gone; a last-word
        // fix preview is re-validated against the caret context in handleCaret.
        if pendingFix?.deleteCount == 0 {
            pendingFix = nil
            owner.window.hide()
        }
        return false
    }

    /// Handle the caret context: revive a last-word fix preview if its word still
    /// sits before the caret, else show an inline spell-fix if the word is a
    /// typo. Returns true if it took the overlay over (caller returns).
    func handleCaret(_ ctx: TextContext) -> Bool {
        guard let owner else { return false }
        let text = ctx.textBeforeCaret

        // Keep a last-word fix preview up while that exact word still sits just
        // before the caret; once the user types or moves on, drop it.
        if let fix = pendingFix, fix.deleteCount > 0 {
            if let rect = ctx.caretRect,
               ctx.textAfterCaret.first?.isLetter != true,
               Self.lastWord(of: text) == fix.original {
                owner.window.show(mode: .fixPreview(fix.replacement), at: rect)
                return true
            }
            pendingFix = nil
            // The preview pill must not outlive its word: nobody downstream is
            // guaranteed to redraw the overlay (the completion flow only shows
            // when it has something), so hide it here or it lingers forever.
            owner.window.hide()
        }

        // Inline spell-fix: a misspelled word at the caret shows its correction
        // over the word (⇥ applies). Takes priority over a completion — fixing
        // what's written matters more than predicting ahead.
        let wordAtCaret = Self.lastWord(of: text)
        if wordAtCaret != dismissedCorrectionWord { dismissedCorrectionWord = nil }
        if pendingFix == nil, ctx.textAfterCaret.first?.isLetter != true,
           wordAtCaret.count >= 3, wordAtCaret != dismissedCorrectionWord,
           let caret = ctx.caretRect,
           let fix = SpellChecker.correction(for: wordAtCaret, context: text) {
            owner.clearActiveCompletion()
            owner.indicator.stop()
            activeCorrection = (word: wordAtCaret, fix: fix)
            showCorrection(fix, word: wordAtCaret, caret: caret, fontSize: ctx.fontSize)
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
        guard let owner else { return .ignored }
        let style = Settings.hotkeyStyle

        // Check correction trigger based on active hotkey style
        if style.matchesCorrection(keyCode: keyCode, flags: flags) {
            if pendingFix != nil { applyPendingFix(); return .consumed }
            if selection != nil { correctSelection(); return .consumed }
            // The last-word fix needs a synchronous AX read; it must NOT run here
            // inside the event-tap callback (a hung target app would block the main
            // thread and get the tap disabled). Hop off the callback and consume
            // the key now — the correction hotkey isn't a system shortcut, so
            // swallowing it even when there's nothing to fix is harmless.
            DispatchQueue.main.async { [weak self] in self?.correctLastWord() }
            return .consumed
        }

        // While a proposed fix is on screen: ⏎ or style's accept key applies it, esc keeps the
        // original (but still reaches the app).
        if pendingFix != nil, owner.window.isVisible {
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
        if let correction = activeCorrection, owner.window.isVisible {
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

    /// First ⌥⇥ on a selection: ask the engine for a fix and preview it.
    private func correctSelection() {
        guard let owner, let sel = selection, !inFlight else { return }
        owner.lastCaretRect = sel.rect ?? owner.lastCaretRect
        runFix(
            selectionText: sel.text,
            request: owner.makeRequest(text: ""),
            makePending: { PendingFix(original: sel.text, replacement: $0) },
            proposedEvent: "fix proposed — ⏎ to apply, esc to keep"
        )
    }

    /// ⌥⇥ with no selection: propose a fix for the just-typed last word. The
    /// caret must sit at the end of a word (mid-word is the completion's job).
    /// Runs off the event-tap callback (it does a synchronous AX read); a no-op
    /// when there's nothing fixable at the caret.
    private func correctLastWord() {
        guard let owner, !inFlight, owner.engine.supportsCorrection,
              let element = owner.currentTextElement(),
              let ctx = AXText.context(for: element, maxChars: Settings.maxContextChars),
              let rect = ctx.caretRect else { return }
        // Not mid-word: the next character must not be a letter.
        guard ctx.textAfterCaret.first?.isLetter != true else { return }
        let word = Self.lastWord(of: ctx.textBeforeCaret)
        guard word.count >= 3, word.count <= 40 else { return }

        owner.clearActiveCompletion()
        owner.lastCaretRect = rect
        runFix(
            selectionText: word,
            request: owner.makeRequest(text: ctx.textBeforeCaret),
            makePending: { PendingFix(original: word, replacement: $0, deleteCount: word.count) },
            proposedEvent: "last-word fix proposed — ⏎ to apply, esc to keep"
        )
    }

    /// Shared body for both ⌥⇥ flows: run the engine off the main actor, then on
    /// the main actor surface the proposal, a "looks fine" notice, or a failure —
    /// guarding on the focus generation so a result for stale context is dropped.
    private func runFix(
        selectionText: String,
        request: CompletionRequest,
        makePending: @escaping (String) -> PendingFix,
        proposedEvent: String
    ) {
        guard let owner else { return }
        inFlight = true
        owner.indicator.start()
        let engine = owner.engine
        let generation = owner.focusGeneration
        correctionTask = Task { [weak self] in
            let started = Date()
            let outcome: Result<String?, Error>
            do {
                outcome = .success(try await engine.correct(selection: selectionText, request: request))
            } catch is CancellationError {
                return
            } catch {
                outcome = .failure(error)
            }
            let elapsed = Date().timeIntervalSince(started)
            await MainActor.run { [weak self] in
                guard let self, let owner = self.owner else { return }
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
                    guard self.stillValid(fix) else {
                        DebugLog.shared.log("FIX", "dropped stale fix — text changed while engine ran")
                        return
                    }
                    self.pendingFix = fix
                    owner.lastEvent = proposedEvent
                    DebugLog.shared.log("FIX", "proposed", detail: "\"\(selectionText)\" → \"\(fixed)\"")
                    if let rect = owner.lastCaretRect {
                        owner.window.show(mode: .fixPreview(fixed), at: rect)
                    }
                case .success(nil):
                    owner.lastEvent = "nothing to fix"
                    DebugLog.shared.log("FIX", "no changes for \"\(selectionText.prefix(60))\"")
                    owner.indicator.flashTransient(.hint("✓ looks fine"))
                case .failure(let error):
                    owner.lastEvent = "fix failed: \(error.localizedDescription)"
                    DebugLog.shared.log("ERROR", "correction failed: \(error.localizedDescription)")
                    owner.indicator.flashTransient(.error("fix failed"))
                }
            }
        }
    }

    /// Confirm the previewed fix. A selection fix types over the selection; a
    /// last-word fix deletes the typed word first, then types the correction.
    private func applyPendingFix() {
        guard let owner, let fix = pendingFix else { return }
        pendingFix = nil
        selection = nil
        owner.window.hide()
        let event = "fixed \(fix.deleteCount > 0 ? "last word" : "selection") (\(fix.original.count) chars)"
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
        guard let owner else { return }
        guard stillValid(fix) else {
            DebugLog.shared.log("FIX", "dropped stale fix — text changed before apply")
            return
        }
        if fix.deleteCount > 0 { TextInjector.deleteBackward(fix.deleteCount) }
        TextInjector.insert(fix.replacement)
        Stats.recordCorrection()
        owner.lastEvent = event
        DebugLog.shared.log("FIX", "applied \"\(fix.original)\" → \"\(fix.replacement)\"")
        owner.scheduleKeystrokeRefresh(after: 0.12)
    }

    /// True while the live text still matches what `fix` was computed against —
    /// a last-word fix needs its word still just before the caret, a selection
    /// fix the same selection. Synchronous AX read: never call inside the
    /// event-tap callback.
    private func stillValid(_ fix: PendingFix) -> Bool {
        guard let owner, let element = owner.currentTextElement() else { return false }
        if fix.deleteCount > 0 {
            guard let ctx = AXText.context(for: element, maxChars: Settings.maxContextChars) else { return false }
            return ctx.textAfterCaret.first?.isLetter != true
                && Self.lastWord(of: ctx.textBeforeCaret) == fix.original
        }
        return AXText.selectionInfo(for: element)?.text == fix.original
    }

    /// Dismiss the previewed fix and keep the original text untouched.
    private func cancelPendingFix() {
        guard let owner, pendingFix != nil else { return }
        pendingFix = nil
        owner.lastEvent = "fix dismissed"
        DebugLog.shared.log("FIX", "dismissed by user")
        owner.window.hide()
    }

    // MARK: - Inline spell-fix

    /// Places the inline spell-fix diff in a pill ABOVE the mistyped word. The
    /// word ends at the caret, so it starts one word-width to the left; anchoring
    /// the pill there lands it above the word it's correcting, not the caret.
    private func showCorrection(_ fix: String, word: String, caret: CGRect, fontSize: CGFloat?) {
        guard let owner else { return }
        let size = fontSize ?? caret.height / 1.30
        let font = NSFont.systemFont(ofSize: size)
        let wordWidth = ceil((word as NSString).size(withAttributes: [.font: font]).width)
        var wordRect = caret
        wordRect.origin.x = caret.maxX - wordWidth
        wordRect.size.width = wordWidth
        owner.lastCaretRect = caret
        owner.lastEvent = "typo \"\(word)\" → \"\(fix)\" (\(Settings.hotkeyStyle.label) to fix)"
        owner.window.show(mode: .correction(original: word, fix: fix), at: wordRect, fontSize: fontSize)
    }

    /// ⇥ on an inline spell-fix: replace the mistyped word with the correction.
    /// Routed through the same validate-then-inject path as the ⌥⇥ fixes.
    private func applyCorrection() {
        guard let owner, let correction = activeCorrection else { return }
        activeCorrection = nil
        owner.window.hide()
        let fix = PendingFix(original: correction.word, replacement: correction.fix,
                             deleteCount: correction.word.count)
        let event = "fixed typo \"\(correction.word)\" → \"\(correction.fix)\""
        DispatchQueue.main.async { [weak self] in self?.inject(fix, event: event) }
    }

    /// The word just before the caret: the trailing run of letters (apostrophes
    /// and hyphens kept, so "don't" / "well-known" stay whole).
    static func lastWord(of text: String) -> String {
        var chars: [Character] = []
        for ch in text.reversed() {
            if ch.isLetter || ch == "'" || ch == "’" || ch == "-" {
                chars.append(ch)
            } else {
                break
            }
        }
        return String(chars.reversed())
    }
}
