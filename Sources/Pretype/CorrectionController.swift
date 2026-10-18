import AppKit
import ApplicationServices

/// What the fix flows may ask of the completion pipeline — `SuggestionController`
/// in the app, a fake in CorrectionControllerTests.
@MainActor
protocol CorrectionHost: AnyObject {
    var typingContext: TypingContext { get }
    var engine: CompletionEngine { get }
    /// Bumped on every focus change: a fix for the field just left is stale.
    var focusGeneration: Int { get }
    var lastCaretRect: CGRect? { get }
    /// A fix measured where its text is (a selection, the word at the caret).
    func noteCaret(_ rect: CGRect)
    /// …or found the caret a scroll forgot.
    func recoverCaret(_ rect: CGRect?)
    func report(_ event: String)
    /// The field the pipeline reads and types into.
    func currentTextElement() -> AXUIElement?
    /// A fix takes the overlay: the completion's ghost and query go.
    func clearActiveCompletion()
    /// Type the fix over `deleted` the one way the pipeline types — cache,
    /// settle window and all — and re-read the field once the keys landed.
    func typeFix(_ text: String, deleting deleted: String, over before: String?)
}

/// Owns the three text-fixing flows, kept separate from the completion pipeline:
///   1. fix-selection — ⌥⇥ on a selection asks the engine to correct it,
///   2. last-word fix — ⌥⇥ with no selection corrects the just-typed word,
///   3. inline spell-fix — a misspelled word at the caret shows a system
///      spell-check correction over it (⇥ applies), Cotypist-style.
///
/// A fix is always *previewed* and applied only on an explicit key — never
/// automatically. It draws into the shared overlay and reaches the pipeline
/// only through its `CorrectionHost`, never driving the completion state
/// beyond clearing it when a fix preempts a suggestion.
@MainActor
final class CorrectionController {
    private unowned let host: any CorrectionHost
    private let env: SuggestionController.Environment
    private let indicator: CaretIndicator
    private var window: any SuggestionOverlay { env.window }

    init(host: any CorrectionHost, env: SuggestionController.Environment, indicator: CaretIndicator) {
        self.host = host
        self.env = env
        self.indicator = indicator
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
    private(set) var correctionTask: Task<Void, Never>?

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
        if let info = env.selection(element) {
            // A selection switches the panel into fix-selection mode: drop any
            // live completion first.
            host.clearActiveCompletion()
            indicator.stop()
            let rect = info.rect ?? host.lastCaretRect
            // A proposed fix for this exact selection stays up until accept/cancel.
            if let fix = pendingFix, fix.original == info.text {
                if let rect { window.show(mode: .fixPreview(original: fix.original, fix: fix.replacement), at: rect) }
                return true
            }
            pendingFix = nil
            let fixable = info.text.count >= 3 && info.text.count <= 500
                && !info.text.contains("\n")
            if fixable, !inFlight {
                selection = info
                if let rect {
                    window.show(mode: .shortcut(key: Settings.hotkeyStyle.correctionLabel, action: String(localized: "fix")), at: rect)
                }
            } else if !inFlight {
                selection = nil
                window.hide()
            }
            return true
        }
        // The "fix" pill goes with its selection: in an app the completion
        // pipeline has gone quiet in, nothing else would ever repaint it.
        if case .shortcut = window.currentMode { window.hide() }
        selection = nil
        // A selection-fix preview ends when the selection is gone; a last-word
        // fix preview is re-validated against the caret context in handleCaret.
        if pendingFix?.deletesOriginal == false {
            pendingFix = nil
            window.hide()
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
                window.show(mode: .fixPreview(original: fix.original, fix: fix.replacement), at: rect)
                return true
            }
            pendingFix = nil
            // The preview pill must not outlive its word: nobody downstream is
            // guaranteed to redraw the overlay (the completion flow only shows
            // when it has something), so hide it here or it lingers forever.
            window.hide()
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
            host.clearActiveCompletion()
            indicator.stop()
            activeCorrection = (word: tokenAtCaret, fix: fix)
            showCorrection(fix, word: tokenAtCaret, caret: caret, style: ctx.host)
            return true
        }
        if activeCorrection != nil {
            // The typo this pill was correcting is gone (edited, or the user
            // typed past it). Hide NOW — same reason as the pendingFix drop
            // above: no later stage reliably clears the overlay.
            activeCorrection = nil
            window.hide()
        }
        return false
    }

    // MARK: - Key handling (called from SuggestionController.handleKeyDown)

    /// What a key does to the fix flows — every rule in one table, executed
    /// by `handleKey`. FixKeyTests pin it.
    enum FixKey: Equatable {
        /// ⌥⇥ with nothing proposed: ask the engine — for the selection, or
        /// for the word before the caret.
        case propose(selection: Bool)
        /// ⌥⇥ over a proposal nobody can see (never drawn, or a notice took
        /// the window): draw it again rather than type a rewrite unseen.
        case reshow
        /// ⌥⇥, ⏎ or the accept key over the preview on screen.
        case apply
        /// ⎋ over the preview: the original stays — and ⎋ still reaches the app.
        case cancel
        /// The accept key over the inline fix pill.
        case applyInline
        /// ⎋ over the inline fix pill: that token isn't offered again until it changes.
        case dismissInline
        case none

        /// Whether the app still gets the key.
        var outcome: KeyOutcome {
            switch self {
            case .propose, .reshow, .apply, .applyInline: return .consumed
            case .cancel, .dismissInline: return .passThrough
            case .none: return .ignored
            }
        }
    }

    /// What `fixKey` reads, all known before the key is routed.
    struct FixKeyState {
        var keyCode: Int64
        var flags: CGEventFlags = []
        var style = HotkeyStyle.tab
        /// An engine fix is proposed (`pendingFix`).
        var proposal = false
        /// An inline fix pill is up (`activeCorrection`).
        var inline = false
        /// The window shows a correction — `showsCorrection`, not
        /// `isVisible`: a dictation notice, an engine status or a ghost also
        /// make the window visible, and a preview never painted (no caret
        /// rect, routine in web and Electron fields) would let ⏎ apply a
        /// rewrite nobody saw and swallow the Enter meant to send the message.
        var onScreen = false
        /// A selection is waiting for ⌥⇥ (`selection`).
        var selection = false
    }

    static func fixKey(_ key: FixKeyState) -> FixKey {
        if key.style.matchesCorrection(keyCode: key.keyCode, flags: key.flags) {
            guard key.proposal else { return .propose(selection: key.selection) }
            return key.onScreen ? .apply : .reshow
        }
        guard key.onScreen else { return .none }
        if key.proposal {
            if key.keyCode == KeyCode.returnKey || key.keyCode == KeyCode.keypadEnter
                || key.style.matchesAcceptWord(keyCode: key.keyCode, flags: key.flags) { return .apply }
            if key.keyCode == KeyCode.escape { return .cancel }
        }
        if key.inline {
            if key.style.matchesAcceptWord(keyCode: key.keyCode, flags: key.flags) { return .applyInline }
            if key.keyCode == KeyCode.escape { return .dismissInline }
        }
        return .none
    }

    func handleKey(keyCode: Int64, flags: CGEventFlags) -> KeyOutcome {
        let action = Self.fixKey(FixKeyState(
            keyCode: keyCode, flags: flags, style: Settings.hotkeyStyle, proposal: pendingFix != nil,
            inline: activeCorrection != nil, onScreen: window.showsCorrection, selection: selection != nil))
        switch action {
        case .propose(let fixSelection):
            // Neither fix runs here, inside the event-tap callback: the
            // last-word fix does a synchronous AX read — a hung target app
            // would block the main thread and get the tap disabled. Hop off
            // the callback and consume the key now — the correction hotkey
            // isn't a system shortcut, so swallowing it even when there's
            // nothing to fix is harmless.
            env.hop { [weak self] in
                if fixSelection { self?.correctSelection() } else { self?.correctLastWord() }
            }
        case .reshow:
            if let pendingFix { showPreview(pendingFix) }
        case .apply:
            applyPendingFix()
        case .cancel:
            cancelPendingFix()
        case .applyInline:
            applyCorrection()
        case .dismissInline:
            dismissedCorrectionWord = activeCorrection?.word
            activeCorrection = nil
            window.hide()
        case .none:
            break
        }
        return action.outcome
    }

    // MARK: - Fix selection (⌥Tab)

    /// First ⌥⇥ on a selection: ask the engine for a fix and preview it. Runs
    /// off the event-tap callback.
    private func correctSelection() {
        guard let sel = selection, !inFlight else { return }
        if let rect = sel.rect { host.noteCaret(rect) }
        runFix(
            selectionText: sel.text,
            proposedEvent: "fix proposed — ⏎ to apply, esc to keep",
            perform: { try await $0.correct(selection: sel.text) }
        )
    }

    /// Voice command mode: the spoken `instruction` applied to `selection`,
    /// previewed and confirmed exactly like a ⌥⇥ fix — so ⏎/⇥ applies it over
    /// the selection (re-validated live), ⎋ keeps the original.
    func runVoiceCommand(_ instruction: String, selection text: String) {
        guard !inFlight else { return }
        if let element = host.currentTextElement(), let rect = env.selection(element)?.rect {
            host.noteCaret(rect)
        }
        host.clearActiveCompletion()
        runFix(
            selectionText: text,
            proposedEvent: "voice command — ⏎ to apply, esc to keep",
            unchangedNotice: String(localized: "no change"),
            perform: { try await $0.rewrite(selection: text, instruction: instruction) }
        )
    }

    /// ⌥⇥ with no selection: propose a fix for the just-typed last word. The
    /// caret must sit at the end of a word (mid-word is the completion's job).
    /// Runs off the event-tap callback (it does a synchronous AX read); a no-op
    /// when there's nothing fixable at the caret.
    private func correctLastWord() {
        guard !inFlight,
              let element = host.currentTextElement(),
              // Re-checked here: resolving the element can read a site the
              // tap-side check didn't know yet.
              !AppPolicy.isBlacklisted(host.typingContext),
              let ctx = env.context(of: element),
              let rect = ctx.caretRect else { return }
        // Not mid-word: the next character must not be a letter.
        guard ctx.textAfterCaret.first?.isLetter != true else { return }
        let word = SpellChecker.trailingWord(of: ctx.textBeforeCaret)
        guard word.count >= 3, word.count <= 40 else { return }

        host.clearActiveCompletion()
        host.noteCaret(rect)
        let before = ctx.textBeforeCaret
        runFix(
            selectionText: word,
            deletesOriginal: true,
            proposedEvent: "last-word fix proposed — ⏎ to apply, esc to keep",
            perform: { engine in
                try await CorrectionGates.fixLastWord(word, before: before) {
                    try await engine.correct(selection: $0)
                }
            }
        )
    }

    /// Shared body for both ⌥⇥ flows: run the engine off the main actor, then on
    /// the main actor surface the proposal, a "looks fine" notice, or a failure —
    /// guarding on the focus generation so a result for stale context is dropped.
    /// `deletesOriginal`: see `PendingFix`.
    private func runFix(
        selectionText: String,
        deletesOriginal: Bool = false,
        proposedEvent: String,
        unchangedNotice: String = String(localized: "✓ looks fine"),
        perform: @escaping @Sendable (any CompletionEngine) async throws -> String?
    ) {
        inFlight = true
        indicator.start()
        let engine = host.engine
        let generation = host.focusGeneration
        let started = env.now()
        correctionTask = Task { [weak self] in
            let outcome: Result<String?, Error>
            do {
                outcome = .success(try await perform(engine))
            } catch is CancellationError {
                return
            } catch {
                outcome = .failure(error)
            }
            // The task inherits the main actor: nothing runs between this
            // check and the code below it.
            guard let self else { return }
            // reset() cancelled this task: its late result must not
            // resurrect the state reset() just cleared, nor stomp a newer
            // request's single-flight flag.
            guard !Task.isCancelled else { return }
            self.inFlight = false
            indicator.stop()
            env.book(.latency(env.now().timeIntervalSince(started)))
            // The user moved on while the engine ran: don't show a fix for
            // context that's no longer in front.
            guard host.focusGeneration == generation else {
                DebugLog.shared.log("FIX", "dropped stale fix (focus changed)")
                return
            }
            switch outcome {
            case .success(let fixed?):
                let fix = PendingFix(original: selectionText, replacement: fixed,
                                     deletesOriginal: deletesOriginal)
                // Nothing cancels the task while the user types on in the
                // same field, so a slow result can arrive for text that's
                // gone — showing it would swallow the next ⏎ (Enter-to-send)
                // for a fix that can never apply. Same check as inject().
                guard self.liveRead(confirming: fix) != nil else {
                    DebugLog.shared.log("FIX", "dropped stale fix — text changed while engine ran")
                    return
                }
                self.pendingFix = fix
                host.report(proposedEvent)
                DebugLog.shared.log("FIX", "proposed", detail: "\"\(selectionText)\" → \"\(fixed)\"")
                self.showPreview(fix)
            case .success(nil):
                host.report("nothing to fix")
                DebugLog.shared.log("FIX", "no changes for \"\(selectionText.prefix(60))\"")
                indicator.flashTransient(.hint(unchangedNotice), orAtPointer: true)
            case .failure(let error):
                host.report("fix failed: \(error.localizedDescription)")
                DebugLog.shared.log("ERROR", "correction failed: \(error.localizedDescription)")
                indicator.flashTransient(SuggestionController.failureNotice(error, fallback: String(localized: "fix failed")),
                                               orAtPointer: true)
            }
        }
    }

    /// Draw `fix`'s preview where its text is — or, when neither selection box
    /// nor caret could be read (web and Electron selections), under the
    /// pointer: a preview pending off screen is one ⏎ or ⌥⇥ would apply blind.
    private func showPreview(_ fix: PendingFix) {
        window.show(mode: .fixPreview(original: fix.original, fix: fix.replacement),
                          at: host.lastCaretRect ?? DictationController.pointerAnchor())
    }

    /// Confirm the previewed fix. A selection fix types over the selection; a
    /// last-word fix deletes the typed word first, then types the correction.
    private func applyPendingFix() {
        guard let fix = pendingFix else { return }
        pendingFix = nil
        selection = nil
        window.hide()
        let event = "fixed \(fix.deletesOriginal ? "last word" : "selection") (\(fix.original.count) chars)"
        // The validating AX read must not run inside the event-tap callback (a
        // hung target app would stall the tap); hop off, then validate + inject.
        env.hop { [weak self] in self?.inject(fix, event: event) }
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
        host.typeFix(fix.replacement, deleting: fix.deletesOriginal ? fix.original : "", over: live.textBeforeCaret)
        env.book(.correction)
        host.report(event)
        DebugLog.shared.log("FIX", "applied \"\(fix.original)\" → \"\(fix.replacement)\"")
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
        guard let element = host.currentTextElement() else { return nil }
        if fix.deletesOriginal {
            guard let ctx = env.context(of: element),
                  ctx.textAfterCaret.first?.isLetter != true,
                  Self.lastToken(of: ctx.textBeforeCaret) == fix.original else { return nil }
            host.recoverCaret(ctx.caretRect)
            return LiveRead(textBeforeCaret: ctx.textBeforeCaret)
        }
        guard let info = env.selection(element), info.text == fix.original else { return nil }
        host.recoverCaret(info.rect)
        return LiveRead(textBeforeCaret: nil)
    }

    /// Dismiss the previewed fix and keep the original text untouched.
    private func cancelPendingFix() {
        guard pendingFix != nil else { return }
        pendingFix = nil
        host.report("fix dismissed")
        DebugLog.shared.log("FIX", "dismissed by user")
        window.hide()
    }

    // MARK: - Inline spell-fix

    /// Places the inline spell-fix diff in a pill ABOVE the mistyped word. The
    /// word ends at the caret, so it starts one word-width to the left; anchoring
    /// the pill there lands it above the word it's correcting, not the caret.
    private func showCorrection(_ fix: String, word: String, caret: CGRect, style: HostTextStyle) {
        // Measure the word in the HOST's font — a system-font measurement put the
        // pill a word-width off in any field that doesn't use it.
        let font = style.font ?? .systemFont(ofSize: caret.height / 1.30)
        let wordWidth = ceil((word as NSString).size(withAttributes: [.font: font]).width)
        var wordRect = caret
        wordRect.origin.x = caret.maxX - wordWidth
        wordRect.size.width = wordWidth
        host.noteCaret(caret)
        host.report("typo \"\(word)\" → \"\(fix)\" (\(Settings.hotkeyStyle.label) to fix)")
        window.show(mode: .correction(original: word, fix: fix), at: wordRect, host: style)
    }

    /// ⇥ on an inline spell-fix: replace the mistyped word with the correction.
    /// Routed through the same validate-then-inject path as the ⌥⇥ fixes.
    private func applyCorrection() {
        guard let correction = activeCorrection else { return }
        activeCorrection = nil
        window.hide()
        let fix = PendingFix(original: correction.word, replacement: correction.fix,
                             deletesOriginal: true)
        let event = "fixed typo \"\(correction.word)\" → \"\(correction.fix)\""
        env.hop { [weak self] in self?.inject(fix, event: event) }
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

extension SuggestionController: CorrectionHost {
    func typeFix(_ text: String, deleting deleted: String, over before: String?) {
        inject(text, deleting: deleted, over: before)
        scheduleKeystrokeRefresh(after: 0.12)
    }
}
