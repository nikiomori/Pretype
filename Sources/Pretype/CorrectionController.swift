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
    /// The text before the caret as last known, typed keys included.
    var knownTextBeforeCaret: String? { get }
    /// …while its end was typed, not only read (`FieldState.typedCache`).
    var typedTextBeforeCaret: String? { get }
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
///      spell-check correction over it (⇥ applies).
///
/// A fix is *previewed* and applied only on an explicit key. The one
/// exception is a sure typo with "Fix sure typos automatically" on
/// (`SpellChecker.isSure`): typed at once, with ⌘Z to bring the word back.
/// It draws into the shared overlay and reaches the pipeline
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
    /// A fix typed without a key. ⌘Z brings `original` back while the text
    /// still reads `after`, alone or with the next word growing behind it.
    private var autoFixed: (original: String, fixed: String, after: String, row: SuggestionJournal.FixEntry)?
    /// A fix without a key is on its way to the field: not started twice.
    private var applyingAuto = false
    /// The token whose fix without a key the field did not confirm: it gets
    /// the pill, not a try at every read.
    private var autoRefused: String?
    /// Read by the caret indicator's `isQueryRunning` — a fix generation must
    /// keep the thinking dots alive just like a completion stream does.
    private(set) var inFlight = false
    private(set) var correctionTask: Task<Void, Never>?
    /// The fix on screen — preview or pill — journaled once when it resolves.
    private var shown: (row: SuggestionJournal.FixEntry, at: Date)?

    // MARK: - Lifecycle

    /// Clear all in-progress fix state (called when the overlay is dismissed).
    func reset() {
        resolveShown(.abandoned)
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
        autoFixed = nil
    }

    // MARK: - Text-change hooks (called from SuggestionController.textDidChange)

    /// Handle a non-empty selection: keep a proposed fix on screen, or offer the
    /// ⌥⇥ affordance. Returns true if it took the overlay over (caller returns).
    /// When there is no selection it clears the selection state and returns false.
    func handleSelection(_ element: AXUIElement) -> Bool {
        if let info = env.selection(element) {
            autoFixed = nil
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
            resolveShown(.abandoned)
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
            resolveShown(.abandoned)
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
            resolveShown(.abandoned)
            // The preview pill must not outlive its word: nobody downstream is
            // guaranteed to redraw the overlay (the completion flow only shows
            // when it has something), so hide it here or it lingers forever.
            window.hide()
        }

        // Escape suppresses a fix until the token under the caret changes.
        // inlineToken, not trailingWord: trailingWord stops at ':', so a dismissed
        // ":shrug:" would read as "" and never un-suppress.
        let tokenAtCaret = Self.inlineToken(of: text)
        if Self.typo(of: tokenAtCaret) != dismissedCorrectionWord { dismissedCorrectionWord = nil }
        if tokenAtCaret != autoRefused { autoRefused = nil }

        // A fix typed without a key shows what it replaced until the next
        // key, and stays ⌘Z's through the next word.
        if let done = autoFixed {
            if text == done.after, let caret = ctx.caretRect {
                host.noteCaret(caret)
                window.show(mode: .fixed(original: Self.typo(of: done.original), fix: Self.typo(of: done.fixed)),
                            at: Self.wordRect(of: done.fixed, caret: caret, style: ctx.host), host: ctx.host)
                return true
            }
            if case .fixed = window.currentMode { window.hide() }
            if !text.hasPrefix(done.after) || text.dropFirst(done.after.count).contains(where: \.isWhitespace) { autoFixed = nil }
        }

        // Inline fix: a closed ":shrug:" previews 🤷, a finished misspelled word
        // its correction, over the token (⇥ applies). Takes priority over a
        // completion — fixing what's written matters more than predicting
        // ahead — but a live ⌥⇥ preview outranks it. A shortcode never reaches
        // the spell-check, or ":asdf:" would put a typo pill on "asdf". Nothing
        // downstream needs an emoji special case: the backspaces delete the
        // ASCII shortcode, so the Character-vs-UTF-16 mismatch that bites
        // elsewhere can't bite here, and the emoji is only ever inserted
        // (TextInjector.insert is surrogate-safe).
        if pendingFix == nil, Settings.fixesEnabled, ctx.textAfterCaret.first?.isLetter != true,
           Self.typo(of: tokenAtCaret) != dismissedCorrectionWord,
           let caret = ctx.caretRect,
           let fix = inlineFix(for: tokenAtCaret, in: text) {
            host.clearActiveCompletion()
            indicator.stop()
            // Redrawn on every read while its typo stands, the next word
            // growing behind it: journaled once.
            let pill = Self.pill(token: tokenAtCaret, fix: fix)
            // A sure fix of the word just ended needs no key.
            // Only a word whose end was typed just now: a click, a paste or
            // a draft that ends in a typo is text nobody asked to change.
            if Settings.autoFixTypos, tokenAtCaret.hasSuffix(" "), tokenAtCaret != autoRefused,
               host.typedTextBeforeCaret?.hasSuffix(tokenAtCaret) == true,
               Self.isSure(token: tokenAtCaret, fix: fix) {
                guard !applyingAuto else { return true }
                var row = row(Self.inlineKind(of: tokenAtCaret), original: pill.original, fix: pill.fix, ctx: text)
                row.auto = true
                open(row)
                activeCorrection = (word: tokenAtCaret, fix: fix)
                applyingAuto = true
                applyCorrection(auto: true)
                return true
            }
            if activeCorrection.map({ Self.pill(token: $0.word, fix: $0.fix) }) ?? ("", "") != pill {
                open(row(Self.inlineKind(of: tokenAtCaret), original: pill.original, fix: pill.fix, ctx: text))
            }
            activeCorrection = (word: tokenAtCaret, fix: fix)
            showCorrection(fix, word: tokenAtCaret, caret: caret, style: ctx.host)
            return true
        }
        if activeCorrection != nil {
            // The typo this pill was correcting is gone (edited, or the user
            // typed past it). Hide NOW — same reason as the pendingFix drop
            // above: no later stage reliably clears the overlay.
            activeCorrection = nil
            resolveShown(.abandoned, typedPast: true)
            window.hide()
        }
        return false
    }

    /// The inline fix for the token at the caret, each kind behind its own
    /// switch: a closed shortcode, a sum ending in "=", or a misspelling. A
    /// misspelling keeps what ended it: "teh, " gives "the, ".
    /// `correct`: the misspelling's fix (`SpellChecker.correction`).
    static func inlineFix(for token: String, context: String,
                          correct: ((String) -> String?)? = nil) -> String? {
        if token.hasPrefix(":") { return Settings.emojiShortcodes ? EmojiShortcodes.emoji(for: token) : nil }
        if token.hasSuffix("=") { return Settings.inlineMath ? InlineCalculator.completion(for: token) : nil }
        guard Settings.fixTypos, !KeptWords.holds(typo(of: token)) else { return nil }
        if let fix = LayoutFix.fix(token: token) { return fix }
        let word = String(token.prefix(while: \.isWordChar))
        // No token is no typo: with nothing to check, the checked-once cache
        // would answer for the word the text happens to end on.
        guard !word.isEmpty else { return nil }
        let fix = correct.map { $0(word) } ?? SpellChecker.correction(for: word, context: context)
        return fix.map { $0 + token.dropFirst(word.count) }
    }

    /// The text up to the word last spell-checked, and its fix.
    private var spellChecked: (upTo: String, fix: String?)?

    /// `inlineFix`, a word spell-checked once: while the next word grows
    /// behind it ("teh, wor"), the text up to it stays, and so does its fix.
    private func inlineFix(for token: String, in text: String) -> String? {
        Self.inlineFix(for: token, context: text) { [self] word in
            let upTo = String(text.dropLast(token.count - word.count))
            if let spellChecked, spellChecked.upTo == upTo { return spellChecked.fix }
            let fix = SpellChecker.correction(for: word, context: text)
            // A spell server that did not answer is asked again at the next key.
            self.spellChecked = fix != nil || SpellChecker.lastCallHeard ? (upTo, fix) : nil
            return fix
        }
    }

    /// Which of `inlineFix`'s three a token gets — the journal's `kind`.
    static func inlineKind(of token: String) -> SuggestionJournal.FixEntry.Kind {
        token.hasPrefix(":") ? .emoji : token.hasSuffix("=") ? .math : LayoutFix.fix(token: token) != nil ? .layout : .typo
    }

    /// `fix` of `token` may be typed without a key: a word read on the right
    /// keyboard layout, or a sure typo (`SpellChecker.isSure`).
    static func isSure(token: String, fix: String) -> Bool {
        switch inlineKind(of: token) {
        case .layout: return token.prefix { $0 != " " }.count >= 5
        case .typo:
            let word = String(token.prefix(while: \.isWordChar))
            return SpellChecker.isSure(word, fix: String(fix.dropLast(token.count - word.count)))
        default: return false
        }
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
        /// ⌘Z after a fix typed without a key: the word comes back.
        case undoAuto
        case none

        /// Whether the app still gets the key.
        var outcome: KeyOutcome {
            switch self {
            case .propose, .reshow, .apply, .applyInline, .undoAuto: return .consumed
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
        /// Exact ⌘Z, and a fix typed without a key it can take back (`autoFixed`).
        var undoesAuto = false
    }

    static func fixKey(_ key: FixKeyState) -> FixKey {
        if key.undoesAuto { return .undoAuto }
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

    /// `isRepeat`: the key is held. It stays ours, but a fix drawn under a
    /// held chord would be applied barely seen.
    func handleKey(keyCode: Int64, flags: CGEventFlags, isRepeat: Bool = false, isCommandZ: Bool = false) -> KeyOutcome {
        let action = Self.fixKey(FixKeyState(
            keyCode: keyCode, flags: flags, style: Settings.hotkeyStyle, proposal: pendingFix != nil,
            inline: activeCorrection != nil, onScreen: window.showsCorrection, selection: selection != nil,
            undoesAuto: isCommandZ && autoFixed != nil))
        if isRepeat, action.outcome == .consumed { return .consumed }
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
        case .undoAuto:
            // The confirming read must not run inside the event tap.
            env.hop { [weak self] in self?.undoAutoFix() }
        case .dismissInline:
            dismissedCorrectionWord = activeCorrection.map { Self.typo(of: $0.word) }
            activeCorrection = nil
            resolveShown(.dismissed)
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
            kind: .selection,
            proposedEvent: "fix proposed — ⏎ to apply, esc to keep",
            perform: { try await $0.correct(selection: sel.text) }
        )
    }

    /// A voice command can run, and `keyAction` will hand ⏎ and ⎋ over its
    /// preview to `handleKey`: not with Fixes off or while paused, nor in a
    /// terminal, where they stay the app's and ⏎ would send the message under
    /// the preview.
    var canRunVoiceCommand: Bool {
        Settings.enabled && Settings.fixesEnabled && host.engine.writesNewText
            && !AppPolicy.isBlacklisted(host.typingContext)
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
        let oneLine = AppPolicy.returnSends(host.typingContext)
        runFix(
            selectionText: text,
            proposedEvent: "voice command — ⏎ to apply, esc to keep",
            unchangedNotice: String(localized: "no change"),
            perform: { engine in
                let rewritten = try await engine.rewrite(selection: text, instruction: instruction)
                guard oneLine else { return rewritten }
                let flat = rewritten?.split(whereSeparator: \.isNewline).joined(separator: " ")
                return flat == text ? nil : flat
            }
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
              let rect = ctx.caretRect,
              let before = fixableText(ctx, of: element) else { return }
        // Not mid-word: the next character must not be a letter.
        guard ctx.textAfterCaret.first?.isLetter != true else { return }
        let word = SpellChecker.trailingWord(of: before)
        guard word.count >= 3, word.count <= 40 else { return }

        host.clearActiveCompletion()
        host.noteCaret(rect)
        runFix(
            selectionText: word,
            deletesOriginal: true,
            kind: .lastWord, ctx: before,
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
    /// `deletesOriginal`: see `PendingFix`. `kind` nil: not journaled — a voice
    /// command's rewrite carries what was said, and dictation never writes that.
    private func runFix(
        selectionText: String,
        deletesOriginal: Bool = false,
        kind: SuggestionJournal.FixEntry.Kind? = nil,
        ctx: String? = nil,
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
                resolveShown(.abandoned)
                if let kind { open(row(kind, engine: engine, original: selectionText, fix: fixed, ctx: ctx)) }
                host.report(proposedEvent)
                DebugLog.shared.log("FIX", "proposed, \(selectionText.count) → \(fixed.count) chars")
                self.showPreview(fix)
            case .success(nil):
                if let kind { book(row(kind, engine: engine, original: selectionText, fix: nil, ctx: ctx), .unchanged) }
                host.report("nothing to fix")
                DebugLog.shared.log("FIX", "no changes for \(selectionText.count) chars")
                indicator.flashTransient(.hint(unchangedNotice), orAtPointer: true)
            case .failure(let error):
                if let kind { book(row(kind, engine: engine, original: selectionText, fix: nil, ctx: ctx), .failed) }
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
        let record = takeShown()
        // The validating AX read must not run inside the event-tap callback (a
        // hung target app would stall the tap); hop off, then validate + inject.
        env.hop { [weak self] in self?.inject(fix, event: event, record: record) }
    }

    /// Shared apply path for every fix flow: re-read the *live* text and inject
    /// only if it still matches what the fix was computed against. The preview
    /// is only re-validated on AX events, which trail typing by tens of ms — a
    /// confirm key landing in that gap (e.g. Enter-to-send right after a burst
    /// of typing) would otherwise delete and replace the wrong characters.
    private func inject(_ fix: PendingFix, event: String, record: (row: SuggestionJournal.FixEntry, at: Date)?,
                        auto: Bool = false) {
        defer { if auto { applyingAuto = false } }
        guard let live = liveRead(confirming: fix) else {
            // Its pill comes next, with a row of its own.
            if auto { autoRefused = fix.original } else if let record { book(record.row, .abandoned, since: record.at) }
            DebugLog.shared.log("FIX", "dropped stale fix — text changed before apply")
            return
        }
        if let record { book(record.row, .applied, since: record.at) }
        // A word read on the right keyboard layout: the next one is typed on it.
        if fix.deletesOriginal, Self.inlineKind(of: fix.original) == .layout { env.selectLayout(fix.original) }
        // Through the shared path, so the settle window covers a fix too: an
        // AX read still showing the typo would re-raise its pill, and a second
        // ⇥ — validated against that same stale read — would apply it twice.
        host.typeFix(fix.replacement, deleting: fix.deletesOriginal ? fix.original : "", over: live.textBeforeCaret)
        if auto, let record, let before = live.textBeforeCaret {
            autoFixed = (fix.original, fix.replacement, String(before.dropLast(fix.original.count)) + fix.replacement, record.row)
        }
        env.book(.correction)
        host.report(event)
        DebugLog.shared.log("FIX", "applied, \(fix.original.count) → \(fix.replacement.count) chars")
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
            guard let ctx = env.context(of: element), ctx.textAfterCaret.first?.isLetter != true,
                  let before = fixableText(ctx, of: element) else { return nil }
            guard Self.lastToken(of: before) == fix.original || Self.inlineToken(of: before) == fix.original
            else { return nil }
            host.recoverCaret(ctx.caretRect)
            return LiveRead(textBeforeCaret: before)
        }
        guard let info = env.selection(element), info.text == fix.original else { return nil }
        host.recoverCaret(info.rect)
        return LiveRead(textBeforeCaret: nil)
    }

    /// The text before the caret in `ctx`, read from `element`, as a fix that
    /// deletes may count its Backspaces on, or nil. A read shorter than what
    /// the keys already typed trails them ("teh, wor" read, "teh, worl"
    /// typed): counted on it, a fix deletes the wrong letters. A terminal's
    /// read hides a space typed at its end, one Backspace short: only a cache
    /// whose end was typed puts it back, and without one the end is unknown.
    private func fixableText(_ ctx: TextContext, of element: AXUIElement) -> String? {
        var before = ctx.textBeforeCaret
        if env.isTerminalField(element) {
            guard let typed = host.typedTextBeforeCaret else { return nil }
            before = FieldState.keepingTypedSpaces(before, cache: typed)
        }
        if let known = host.knownTextBeforeCaret, known.count > before.count, known.hasPrefix(before) { return nil }
        return before
    }

    /// Dismiss the previewed fix and keep the original text untouched.
    private func cancelPendingFix() {
        guard pendingFix != nil else { return }
        pendingFix = nil
        resolveShown(.dismissed)
        host.report("fix dismissed")
        DebugLog.shared.log("FIX", "dismissed by user")
        window.hide()
    }

    // MARK: - Inline spell-fix

    /// Places the inline spell-fix diff in a pill ABOVE the mistyped word. The
    /// word ends at the caret, so it starts one word-width to the left; anchoring
    /// the pill there lands it above the word it's correcting, not the caret.
    private func showCorrection(_ fix: String, word: String, caret: CGRect, style: HostTextStyle) {
        let wordRect = Self.wordRect(of: word, caret: caret, style: style)
        host.noteCaret(caret)
        let (original, fixed) = Self.pill(token: word, fix: fix)
        host.report("typo \"\(original)\" → \"\(fixed)\" (\(Settings.hotkeyStyle.label) to fix)")
        window.show(mode: .correction(original: original, fix: fixed), at: wordRect, host: style)
    }

    /// Where `word`, which ends at `caret`, is drawn.
    private static func wordRect(of word: String, caret: CGRect, style: HostTextStyle) -> CGRect {
        // Measure the word in the HOST's font — a system-font measurement put the
        // pill a word-width off in any field that doesn't use it.
        let font = style.font ?? .systemFont(ofSize: caret.height / 1.30)
        let wordWidth = ceil((word as NSString).size(withAttributes: [.font: font]).width)
        var wordRect = caret
        wordRect.origin.x = caret.maxX - wordWidth
        wordRect.size.width = wordWidth
        return wordRect
    }

    /// ⌘Z after a fix typed without a key: the word comes back, with what
    /// was typed after it, and is the user's from now on (`KeptWords`).
    /// Only while a live read still ends with the fix and that next word.
    private func undoAutoFix() {
        // A read that does not confirm yet may trail the fix itself: the
        // record stays for the next ⌘Z, and `handleCaret` drops it once the
        // text has moved on.
        guard let done = autoFixed, let element = host.currentTextElement(), let ctx = env.context(of: element),
              ctx.textAfterCaret.first?.isLetter != true, let before = fixableText(ctx, of: element),
              before.hasPrefix(done.after),
              !before.dropFirst(done.after.count).contains(where: \.isWhitespace) else { return }
        autoFixed = nil
        window.hide()
        let rest = String(before.dropFirst(done.after.count))
        host.typeFix(done.original + rest, deleting: done.fixed + rest, over: before)
        book(done.row, .undone)
        host.report("fix undone")
    }

    /// ⇥ on an inline spell-fix: replace the mistyped word with the correction.
    /// Routed through the same validate-then-inject path as the ⌥⇥ fixes.
    /// `auto`: no key asked for it (`SpellChecker.isSure`).
    private func applyCorrection(auto: Bool = false) {
        guard let correction = activeCorrection else { return }
        activeCorrection = nil
        window.hide()
        let fix = PendingFix(original: correction.word, replacement: correction.fix,
                             deletesOriginal: true)
        let event = "fixed typo \"\(correction.word)\" → \"\(correction.fix)\""
        let record = takeShown()
        env.hop { [weak self] in self?.inject(fix, event: event, record: record, auto: auto) }
    }

    // MARK: - Fix journal

    /// A row for the app in front; `engine` stamps an ⌥⇥ fix with what wrote it.
    private func row(_ kind: SuggestionJournal.FixEntry.Kind, engine: (any CompletionEngine)? = nil,
                     original: String, fix: String?, ctx: String?) -> SuggestionJournal.FixEntry {
        SuggestionJournal.FixEntry(
            ts: SuggestionJournal.timestamp(), app: host.typingContext.bundleID,
            engine: engine?.name, model: engine?.loadedModelID, kind: kind,
            original: original, fix: fix, ctx: ctx.map { String($0.suffix(200)) },
            outcome: .abandoned, shownForMs: 0)
    }

    /// `row` went on screen; whatever was up before it was never confirmed.
    private func open(_ row: SuggestionJournal.FixEntry) {
        resolveShown(.abandoned)
        shown = (row, env.now())
    }

    private func takeShown() -> (row: SuggestionJournal.FixEntry, at: Date)? {
        defer { shown = nil }
        return shown
    }

    /// `typedPast`: the user went on typing with the pill up, which is the
    /// one way to leave it that says "my word" (`KeptWords`).
    private func resolveShown(_ outcome: SuggestionJournal.FixEntry.Outcome, typedPast: Bool = false) {
        if let record = takeShown() { book(record.row, outcome, since: record.at, typedPast: typedPast) }
    }

    private func book(_ row: SuggestionJournal.FixEntry, _ outcome: SuggestionJournal.FixEntry.Outcome,
                      since: Date? = nil, typedPast: Bool = false) {
        var row = row
        row.outcome = outcome
        if let since { row.shownForMs = Int(env.now().timeIntervalSince(since) * 1000) }
        if row.kind == .typo || row.kind == .layout, row.outcome != .abandoned || typedPast {
            KeptWords.note(row.original, row.outcome, shownForMs: row.shownForMs)
        }
        env.book(.fix(row))
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

    /// What an inline fix reads: a shortcode or a sum as soon as it closes, a
    /// word only once a space ends it, with what ended it ("teh, "). A word
    /// still being typed is no typo: such pills lived 225 ms at the median,
    /// and 1 of 694 was taken. The finished word stays the token while the
    /// next one is typed ("teh, wor"): ended by the space alone, its pill
    /// lived 350 ms, gone at the next letter.
    static func inlineToken(of text: String) -> String {
        let token = lastToken(of: text)
        guard token == SpellChecker.trailingWord(of: text) else { return token }
        guard text.hasSuffix(" ") else {
            // Three letters of the next word: past that the pill only keeps
            // that word's own suggestion away.
            guard !token.isEmpty, token.count <= 3 else { return "" }
            let finished = inlineToken(of: String(text.dropLast(token.count)))
            return finished.isEmpty ? "" : finished + token
        }
        // A chunk typed on the wrong keyboard layout is a token whole: its
        // marks may be letters there ("k.,k." is "люблю").
        let chunk = String(text.dropLast().reversed().prefix { $0 != " " && $0 != "\n" }.reversed())
        if LayoutFix.fix(token: chunk + " ") != nil { return chunk + " " }
        let marks = text.dropLast().reversed().prefix { ".,;:!?)»\"".contains($0) }
        let word = SpellChecker.trailingWord(of: String(text.dropLast(marks.count + 1)))
        return word.isEmpty ? "" : word + String(marks.reversed()) + " "
    }

    /// The finished word an inline token fixes, with what ended it: "teh," of
    /// "teh, wor". What the pill shows, the journal books and ⎋ suppresses.
    /// A shortcode or a sum is its whole token ("2 + 3 =").
    static func typo(of token: String) -> String {
        pill(token: token, fix: token).original
    }

    /// The pill's two sides: `token` and its `fix` without the next word they
    /// share ("teh, wor" → "the, wor" shows "teh," → "the,").
    static func pill(token: String, fix: String) -> (original: String, fix: String) {
        let next = token.hasPrefix(":") || token.hasSuffix("=") ? 0 : token.drop { $0 != " " }.count
        return (token.dropLast(next).trimmingCharacters(in: .whitespaces),
                fix.dropLast(next).trimmingCharacters(in: .whitespaces))
    }
}

extension SuggestionController: CorrectionHost {
    var canRunVoiceCommand: Bool { correctionController.canRunVoiceCommand }

    func typeFix(_ text: String, deleting deleted: String, over before: String?) {
        inject(text, deleting: deleted, over: before)
        scheduleKeystrokeRefresh(after: 0.12)
    }
}

/// Words whose fix the user left on screen or took back: after two such
/// times the word is theirs ("канвасе" is no typo of "канаве"), and the pill
/// stays away. Left means typed past with the pill up; ⎋ and ⌘Z count as
/// two, a fix taken forgets the word.
/// ponytail: one dictionary in the defaults, at most 500 words, then no new
/// ones; a list in Settings if users ask to edit it.
enum KeptWords {
    static func holds(_ word: String) -> Bool { (Settings.keptWords[key(word)] ?? 0) >= 2 }

    /// A pill on screen for under 0.7 s was not read (the quickest one taken
    /// stood 0.66 s): it counts for nothing.
    static func note(_ word: String, _ outcome: SuggestionJournal.FixEntry.Outcome, shownForMs: Int) {
        var words = Settings.keptWords
        let key = key(word)
        guard !key.isEmpty else { return }
        switch outcome {
        case .applied: guard words.removeValue(forKey: key) != nil else { return }
        case .dismissed, .undone: words[key] = 2
        case .abandoned where shownForMs >= 700 && (words[key] != nil || words.count < 500): words[key, default: 0] += 1
        default: return
        }
        Settings.keptWords = words
    }

    private static func key(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    }
}
