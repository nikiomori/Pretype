import AppKit

/// Orchestrates the pipeline: focused-element text → completion engine →
/// ghost overlay → Tab acceptance → text injection. Also handles
/// fix-selection (⌥Tab) and feeds the menu with diagnostics and context.
@MainActor
final class SuggestionController: NSObject {
    private let focusTracker = FocusTracker()
    private let keyTap = KeyTap()
    let window = SuggestionWindow()
    private let engineCoordinator = EngineCoordinator()
    /// The active completion engine, owned by `engineCoordinator`. Read-only here;
    /// model/style/gate changes flow through the coordinator's methods.
    var engine: CompletionEngine { engineCoordinator.engine }
    private var refreshTask: Task<Void, Never>?
    /// Bumped per scheduled completion query so a finishing task only clears
    /// `refreshTask` when it's still the current one (a newer query owns it
    /// otherwise). Without this the reference lingers after a normal finish and
    /// `isQueryRunning` reads true forever.
    private var refreshSeq = 0

    /// Engine-state indicator at the caret (download progress, thinking dots,
    /// transient notices). Shares the overlay window with the suggestion.
    lazy var indicator = CaretIndicator(
        window: window,
        engineState: { [weak self] in self?.engine.state ?? .ready },
        caretRect: { [weak self] in self?.lastCaretRect },
        hostStyle: { [weak self] in self?.lastHostStyle ?? HostTextStyle() },
        hasActiveSuggestion: { [weak self] in self?.active != nil },
        isQueryRunning: { [weak self] in
            // The ⌥⇥ fix flows run outside refreshTask; without them the timer
            // sees .ready + idle at its first tick and kills the thinking dots.
            self?.refreshTask != nil || self?.correctionController.inFlight == true
        }
    )
    /// The text-fixing flows (⌥⇥ fix-selection / last word, inline spell-fix),
    /// kept separate from the completion pipeline below.
    let correctionController = CorrectionController()

    /// Hold-to-talk dictation. Owns the microphone, the caret pill while it
    /// listens, and nothing else — the transcript comes back through
    /// `insertDictated`, which is the same injection path an accept takes.
    let dictationController = DictationController()

    /// Fired when the microphone opens or closes, so the status item can show
    /// a mic while a capture is live. Set by `StatusMenuController.bind`.
    var onDictationActivity: (() -> Void)?

    private struct Active {
        /// Text before the caret at the moment the suggestion became valid.
        var anchor: String
        /// Remaining (not yet accepted) suggestion text.
        var text: String
        /// Already counted as an accepted suggestion, so accepting word-by-word
        /// counts once (not once per word). Carried across in-place mutations;
        /// reset only when a fresh suggestion is shown. See accept().
        var accepted = false
    }

    private var active: Active?

    /// Journal record for the currently shown suggestion, opened when it first
    /// appears and written out with its outcome when it resolves. Everything is
    /// local-only (see `SuggestionJournal`).
    private struct PendingJournal {
        var ctx: String
        var after: String
        var suggestion: String
        var acceptedChars = 0
        var hadScreen: Bool
        /// The app this was offered in, captured at show time. Resolution can
        /// arrive after focus has already moved (a `.abandoned` on app switch),
        /// and `typingContext` names the NEW app by then — booking the offer, or
        /// journaling it, against that one blames the wrong app.
        var app: String?
        /// "ngram" for the fast-path, else the engine's name — so the journal
        /// can compare their acceptance rates.
        var engine: String
        /// Config regime at show-time (see `Entry.model`…); `model` is the
        /// engine's own resolved/loaded model — nil for the ngram fast-path
        /// and Apple Intelligence.
        var model: String?
        var style: String
        var gate: String
        var personalization: String
        var shownAt = Date()
    }
    private var pendingJournal: PendingJournal?

    /// True while the visible suggestion came from the personal n-gram
    /// fast-path (shown instantly, before the LLM answers). The LLM stream
    /// supersedes it via the normal `apply` path; its *abstain* must not
    /// hide it though — a confident personal phrase beats showing nothing.
    private var activeIsInstant = false

    /// Double-tap-a-modifier state — the easy-to-reach twin of the reply chord.
    private var replyTap = ModifierDoubleTap()

    private var keyRefreshScheduled = false
    private var lastAcceptedChunk: String?
    /// Whether that chunk was SPOKEN rather than suggested. The undo path books
    /// its chunk into the debug log, the Diagnostics line and the journal —
    /// all three fine for a suggestion the model produced, none of them allowed
    /// to hold a dictated sentence (`docs/privacy.md`: the transcript is
    /// redacted from the log and never journaled).
    private var lastAcceptedWasDictated = false
    /// The most recent `textBeforeCaret` seen by `textDidChange`. Lets a streamed
    /// partial tell — without a fresh AX read — whether the user has typed since
    /// the completion stream began, so it knows when its cached context is stale.
    private var latestTextBeforeCaret: String?
    /// While set and in the future, a synthetic injection (accept / ⌘Z undo)
    /// is still landing in the target app: `textDidChange` treats the cache as
    /// the authority over a mismatching (trailing) AX read until then.
    private var injectionSettleDeadline: Date?
    /// The cache exactly as it read right after the last accept's injection.
    /// ⌘Z-undo is offered only while the field still reads like this — a
    /// same-field mouse click can land the caret after identical text, so a
    /// bare "ends with the chunk" check would delete the wrong occurrence.
    private var lastAcceptedSnapshot: String?

    /// Caret rect of the latest context — shared by the completion overlay, the
    /// indicator and the correction previews.
    var lastCaretRect: CGRect?
    /// Host style of the latest context, refreshed with `lastCaretRect` on every
    /// keystroke. The indicator's shows (thinking dots, status, transients) pass
    /// it so they carry measured, current evidence — the dots decide ghost-vs-
    /// pill on `textFollowsCaret`, and the window's own remembered style can be
    /// many keystrokes stale while no suggestion is live.
    private(set) var lastHostStyle = HostTextStyle()

    // Opt-in OCR context of the focused window.
    private var screenSummary: String?
    private var screenCapturedAt = Date.distantPast
    private var screenCaptureInFlight = false

    // Opt-in clipboard context, re-read only when the pasteboard changes.
    private var clipboardChangeCount = -1
    private var clipboardSnippet: String?

    // Retrieval-augmented few-shot from the user's own accepted phrases.
    // Refreshed off the typing path (same discipline as the OCR context) so the
    // prompt prefix only changes on a refresh, not per keystroke — a prefix
    // change costs one full KV-cache re-prefill.
    private var personalExamples: [SuggestionJournal.AcceptedPhrase] = []
    private var examplesRefreshedAt = Date.distantPast
    private var examplesRefreshInFlight = false
    /// Bumped on every real focus change; in-flight captures and corrections
    /// that finish after a change are discarded (a result for the previous app's
    /// context must never attach to the new one).
    var focusGeneration = 0
    private var lastFocusedElement: AXUIElement?
    private var lastLoggedSuggestion: String?

    // Surfaced in the menu.
    private(set) var typingContext = TypingContext()
    private(set) var lastPromptDescription: String?
    private(set) var lastResultDescription: String?
    var lastEvent = "waiting for typing"
    private var onboardingWindow: OnboardingWindow?

    override init() {
        super.init()
        // A model/style/gate rebuild drops the suggestion that belonged to the
        // old engine.
        engineCoordinator.onRebuild = { [weak self] in self?.dismiss() }
        window.presentation = Settings.suggestionPresentation
        correctionController.owner = self
        dictationController.owner = self
        focusTracker.delegate = self
        keyTap.handler = { [weak self] event in
            self?.handleKeyDown(event) ?? false
        }
        keyTap.scrollHandler = { [weak self] isMomentum in
            guard let self else { return }
            // Momentum frames don't reach dictation at all — a flick keeps
            // coasting for seconds after the finger left, and a hold started
            // (or a transcript being finalized) during that tail is
            // deliberate, not a scroll gesture interrupting it.
            let dictating = self.dictationController.isBusy
            if !isMomentum { self.dictationController.scrolled() }
            // While dictation is busy the overlay is its to keep: the live
            // pill riding out a momentum tail, or the protected "dictation
            // dropped" notice `scrolled()` just posted — `dropOverlay` would
            // erase either one, and dictation tears down its own overlay on
            // discard anyway. (`mouseDownHandler` skips it for the same
            // reason.)
            if !dictating { self.dropOverlay(why: "the view scrolled") }
        }
        keyTap.mouseDownHandler = { [weak self] in
            self?.dictationController.mouseDown()
        }
        keyTap.flagsHandler = { [weak self] event in
            // Both gestures read every modifier edge. They cannot collide: a
            // reply only ever fires on a pair of taps, a dictation capture only
            // on a hold past `ModifierHold.threshold`.
            self?.dictationController.modifierChanged(event)
            guard let self, self.replyTap.modifierChanged(
                keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                flags: event.flags, gesture: Settings.replyGesture, now: Date()) else { return }
            // Off the tap callback before any AX read — same rule as the chord.
            DispatchQueue.main.async { [weak self] in self?.composeReply() }
        }
    }

    func start() {
        focusTracker.start()
        ensureKeyTap()
        // Legacy favored-word store (measured null, removed 2026-07-16): the
        // learned-word list must not outlive the feature on disk.
        if let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(
                at: dir.appendingPathComponent("Pretype/personalization.json"))
        }
        if Settings.personalizationLevel != .off {
            PersonalNgram.shared.prepareIfNeeded()
        }
        if !Settings.onboardingCompleted {
            onboardingWindow = OnboardingWindow(controller: self)
            onboardingWindow?.show()
        }
    }

    func clearOnboarding() {
        onboardingWindow = nil
    }

    func shutdown() {
        dictationController.invalidate()
        engineCoordinator.shutdown()
    }

    // Engine lifecycle + the settings that reshape it live in `engineCoordinator`;
    // these forward the menu/window actions to it. A rebuild calls back into
    // `dismiss()` (wired in `init`) to drop the stale suggestion.
    func setModel(_ id: String) { engineCoordinator.setModel(id) }
    func applyConfig(_ target: ProjectionConfig) { engineCoordinator.apply(target) }
    func applyRecommendedSettings() { engineCoordinator.applyRecommendedSettings() }
    func releaseEngineModel() { engineCoordinator.releaseModelNow() }
    func setCompletionStyle(_ style: CompletionStyle) { engineCoordinator.setCompletionStyle(style) }
    func setLogprobGate(_ enabled: Bool) { engineCoordinator.setLogprobGate(enabled) }
    func setCompletionLength(_ length: CompletionLength) { engineCoordinator.setCompletionLength(length) }
    func setCustomInstructions(_ instructions: String) { engineCoordinator.setCustomInstructions(instructions) }
    func setPersonalization(_ level: PersonalizationLevel) { engineCoordinator.setPersonalization(level) }

    /// Inline ghost text vs the classic floating panel. Dismisses any live
    /// suggestion so the next one renders in the chosen mode.
    func setSuggestionPresentation(_ presentation: SuggestionPresentation) {
        Settings.suggestionPresentation = presentation
        window.presentation = presentation
        dismiss()
    }

    /// Close the pending journal record with its outcome. Idempotent — the
    /// first resolution wins; later calls (e.g. the `dismiss()` that follows an
    /// Escape) find nothing pending.
    private func resolveJournal(_ outcome: SuggestionJournal.Outcome, typed: String? = nil) {
        guard let pending = pendingJournal else { return }
        pendingJournal = nil
        // The counters are booked HERE, not where the ghost was drawn: what makes
        // a ghost an offer the user could take is how long it survived and what
        // ended it, and neither is known until now. See `Stats.isChance`.
        let shownForMs = Int(Date().timeIntervalSince(pending.shownAt) * 1000)
        Stats.recordOffer(outcome: outcome, shownForMs: shownForMs,
                          tookAny: pending.acceptedChars > 0, app: pending.app)
        guard Settings.suggestionJournalEnabled else { return }
        // ONE snapshot for both consumers: observe's delta cursor must see
        // exactly the ctx window the journal stores, or the next launch's
        // replay re-splits the stream differently and double-learns.
        let ctx = String(pending.ctx.suffix(1000))
        // Live n-gram learning from the same ctx snapshots the startup build
        // replays — so today's typing predicts today, not from the next launch.
        if Settings.personalizationLevel != .off {
            PersonalNgram.shared.observe(ctx: ctx, app: pending.app)
        }
        SuggestionJournal.shared.append(SuggestionJournal.Entry(
            ts: SuggestionJournal.timestamp(),
            app: pending.app,
            engine: pending.engine,
            model: pending.model,
            style: pending.style,
            gate: pending.gate,
            personalization: pending.personalization,
            // Read at resolve, not show: the engine publishes the value only
            // after the generation completes, which is after the first streamed
            // partial is shown. By resolve time it belongs to the shown
            // suggestion — except `superseded`, where a newer generation has
            // already overwritten it (see Entry doc: calibration filters those).
            firstWordLogProb: pending.engine == "ngram" ? nil : engine.lastFirstWordLogProb,
            ctx: ctx,
            after: pending.after,
            suggestion: pending.suggestion,
            outcome: outcome,
            acceptedChars: pending.acceptedChars,
            typed: typed.map { String($0.prefix(20)) },
            shownForMs: shownForMs,
            screen: pending.hadScreen))
    }

    func dismiss() {
        resolveJournal(.abandoned)
        refreshTask?.cancel()
        refreshTask = nil
        active = nil
        activeIsInstant = false
        lastAcceptedChunk = nil
        correctionController.reset()
        indicator.stop()
        window.hide()
        if !Settings.onboardingCompleted {
            onboardingWindow?.updateStatusSuggestionActive(false)
        }
    }

    /// The overlay is placed in screen coordinates, and nothing re-places it
    /// when the host view moves under it: AX posts no scroll notification, and
    /// the caret rect it would report after one can sit outside the visible clip
    /// (a scrolled-away caret in an NSTextView is still inside the text view's
    /// own frame). So a viewport change drops the overlay instead of chasing it
    /// — the next keystroke re-queries from the live caret. Cheap enough to sit
    /// on the scroll-event path: three flags before anything else runs.
    private func dropOverlay(why: String) {
        guard active != nil || refreshTask != nil || window.isVisible else { return }
        lastEvent = "dismissed — \(why)"
        // Every caller of this means the caret moved out from under the
        // overlay (scroll, window move, app switch) — a protected notice is as
        // stranded as a ghost would be.
        window.clearNoticeProtection()
        dismiss()
    }

    /// Drop any live completion without touching the overlay — used when a
    /// correction preempts a suggestion.
    func clearActiveCompletion() {
        resolveJournal(.abandoned)
        active = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    var diagnostics: [String] {
        let hasField = currentTextElement() != nil
        return [
            "Accessibility: \(Permissions.isTrusted ? "granted ✓" : "NOT granted ✗")",
            "Key tap: \(keyTap.isActive ? "active ✓" : "NOT active ✗")",
            "Text element: \(hasField ? "detected ✓" : "none")",
            "Engine: \(engine.name)\(engine.statusLine.map { " — \($0)" } ?? "")",
            "Dictation: \(dictationController.statusLine)",
            "Prompt: \(lastPromptDescription?.count ?? 0) chars"
                + (screenSummary.map { " (incl. \($0.count) screen)" } ?? ""),
            "Last: \(lastEvent)",
        ]
    }

    /// The event tap fails when Accessibility was granted after launch (or to
    /// the wrong target); keep retrying until it comes up.
    private func ensureKeyTap() {
        keyTap.start()
        if !keyTap.isActive {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.ensureKeyTap()
            }
        }
    }

    func currentTextElement() -> AXUIElement? {
        focusTracker.focusedTextElement ?? AXText.systemFocusedTextElement()
    }

    /// True while one of Pretype's own windows (Settings, Debug console) is
    /// frontmost. The session-wide key tap still fires for keystrokes into our
    /// own fields, but `FocusTracker.attach` skips our own pid *without*
    /// detaching, so `focusedTextElement` stays pinned to the last external
    /// field. Left ungated, typing in Settings would generate a ghost for that
    /// stale background field — and Tab would inject its text into our own
    /// field. Both pipeline entry points go inert while this is true.
    private var isOwnUIFrontmost: Bool { NSApp.isActive }

    func makeRequest(text: String, after: String = "") -> CompletionRequest {
        var request = CompletionRequest(textBeforeCaret: text, textAfterCaret: after, context: typingContext)
        if AppPolicy.allowsScreenContext(typingContext.bundleID) {
            request.screenSummary = screenSummary
            // Same app gate as the OCR: clipboard in a terminal/code editor is
            // usually code, which poisons a prose model. Skip once pasted —
            // the field already contains it.
            if Settings.clipboardContextEnabled, let clip = currentClipboardContext(),
               !text.contains(clip) {
                request.clipboardContext = clip
            }
        }
        // Decided here, on the main thread, where NSSpellChecker is safe: lets the
        // engine offer a space + next word right after a finished word.
        request.endsOnCompleteWord = SpellChecker.endsOnCompleteWord(before: text, after: after)
        if Settings.personalExamplesEnabled {
            request.personalExamples = personalExamples
        }
        return request
    }

    /// Retrieve the accepted phrases most similar to what's being typed, at
    /// most every 25 s and never on the keystroke path. The result set stays
    /// frozen between refreshes so the instruct prompt prefix — and with it the
    /// KV cache — survives incremental typing.
    private func refreshPersonalExamplesIfNeeded(typed: String) {
        guard Settings.personalExamplesEnabled, !examplesRefreshInFlight,
              typed.count >= 12,
              Date().timeIntervalSince(examplesRefreshedAt) > 25 else { return }
        examplesRefreshInFlight = true
        let generation = focusGeneration
        let query = String(typed.suffix(300))
        Task.detached { [weak self] in
            let found = SuggestionJournal.shared.similarAcceptedPhrases(to: query)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.examplesRefreshInFlight = false
                guard self.focusGeneration == generation else { return }
                self.examplesRefreshedAt = Date()
                guard found != self.personalExamples else { return }
                self.personalExamples = found
                DebugLog.shared.log(
                    "PROMPT", "personal examples: \(found.count)",
                    detail: found.map { "…\($0.ctx) ⟶\($0.next)" }.joined(separator: "\n"))
            }
        }
    }

    /// Clipboard text for the prompt, re-read only when the pasteboard
    /// changes (reading a multi-MB copy per keystroke would hurt). Concealed
    /// and transient contents — password managers mark both — are never read.
    private func currentClipboardContext() -> String? {
        let pasteboard = NSPasteboard.general
        if pasteboard.changeCount != clipboardChangeCount {
            clipboardChangeCount = pasteboard.changeCount
            let concealed = pasteboard.types?.contains {
                $0.rawValue == "org.nspasteboard.ConcealedType"
                    || $0.rawValue == "org.nspasteboard.TransientType"
            } ?? false
            let text = concealed
                ? nil
                : pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
            clipboardSnippet = text.flatMap { $0.isEmpty ? nil : String($0.prefix(600)) }
        }
        return clipboardSnippet
    }

    /// Surfaced in the Context submenu.
    var screenContextStatus: String {
        guard Settings.screenContextEnabled else { return "off" }
        guard ScreenContext.hasPermission else {
            return "no Screen Recording permission (grant + relaunch)"
        }
        guard AppPolicy.allowsScreenContext(typingContext.bundleID) else {
            return "blocked in this app (terminal/code editor)"
        }
        if let screenSummary { return "captured \(screenSummary.count) chars" }
        return screenCaptureInFlight ? "capturing…" : "nothing captured yet"
    }

    /// Refreshes the window OCR at most every 25 s, off the typing path.
    private func refreshScreenContextIfNeeded(typed: String) {
        guard Settings.screenContextEnabled, ScreenContext.hasPermission,
              AppPolicy.allowsScreenContext(typingContext.bundleID) else { return }
        guard !screenCaptureInFlight,
              Date().timeIntervalSince(screenCapturedAt) > 25,
              focusTracker.observedPID > 0 else { return }
        screenCaptureInFlight = true
        let pid = focusTracker.observedPID
        let generation = focusGeneration
        let appName = typingContext.appName ?? "?"
        let caret = self.lastCaretRect
        Task { [weak self] in
            let summary = await ScreenContext.capture(pid: pid, excluding: typed, caretRect: caret)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.screenCaptureInFlight = false
                guard self.focusGeneration == generation else {
                    DebugLog.shared.log("OCR", "discarded stale capture of \(appName) (focus changed)")
                    return
                }
                self.screenCapturedAt = Date()
                self.screenSummary = summary
                // Count only, never the text: the log is exportable and this is
                // OTHER people's on-screen text. Passing it as `detail` here
                // leaked it straight past the redaction the prompt log does
                // below, and past the export warning's "text you typed" framing.
                DebugLog.shared.log(
                    "OCR",
                    summary.map { "captured \($0.count) chars (\(appName))" } ?? "nothing usable captured (\(appName))"
                )
            }
        }
    }

    // MARK: - Text changes

    private func textDidChange() {
        guard Settings.enabled else { return }
        // The overlay belongs to the dictation pill while it listens, and an AX
        // notification arriving mid-capture (a selection event, the injection
        // itself) would both hide it and start generating for text the user is
        // still speaking. The post-injection refresh re-enters here normally.
        if dictationController.isBusy { return }
        if isOwnUIFrontmost { dismiss(); return }
        if AppPolicy.isBlacklisted(typingContext.bundleID) {
            lastEvent = "suggestions are off in blacklisted apps"
            dismiss()
            return
        }
        guard let element = currentTextElement() else {
            if active != nil { lastEvent = "lost text element" }
            dismiss()
            return
        }

        // A selection switches into fix-selection mode (⌥⇥); the correction
        // controller owns the overlay while it's up.
        if correctionController.handleSelection(element) { return }

        guard let ctx = AXText.context(for: element, maxChars: Settings.maxContextChars) else {
            if active != nil { lastEvent = "lost text element" }
            dismiss()
            return
        }
        let text = ctx.textBeforeCaret
        // While an injection settles, the synchronously-maintained cache is the
        // authority: AX reads trail synthetic keystrokes (worst in Electron),
        // and acting on one would regress the cache, re-query a stale prompt
        // and re-offer — or resurrect — the just-accepted/undone text. Retry
        // shortly; the deadline bounds the wait.
        if let deadline = injectionSettleDeadline {
            if Date() < deadline, let cached = latestTextBeforeCaret, cached != text {
                scheduleKeystrokeRefresh(after: 0.09)
                return
            }
            injectionSettleDeadline = nil
        }
        latestTextBeforeCaret = text
        lastCaretRect = ctx.caretRect
        lastHostStyle = ctx.host
        refreshScreenContextIfNeeded(typed: text)
        refreshPersonalExamplesIfNeeded(typed: text)

        // A reviving last-word fix preview, or an inline spell-fix on the word at
        // the caret, preempts a completion — fixing what's written matters more
        // than predicting ahead.
        if correctionController.handleCaret(ctx) { return }

        // A letter or digit right after the caret: the caret splits a word, and
        // any completion accepted there fuses into its remainder ("hel|lo" +
        // "p there" → "help therelo"). The gates' after-caret duplication check
        // only catches the model re-typing that exact remainder — the general
        // case is unsalvageable, so offer nothing at all while the user edits
        // inside a word. (The correction flows carry this same guard.)
        if let next = ctx.textAfterCaret.first, next.isLetter || next.isNumber {
            if active != nil { lastEvent = "caret splits a word — no suggestion" }
            // Not dismiss(): that resets the correction controller, and a
            // last-word ⌥⇥ fix may legitimately be computing at a caret that
            // sits before a DIGIT (its own guard only excludes letters).
            clearActiveCompletion()
            indicator.stop()
            window.hide()
            return
        }

        if var current = active {
            if text.hasPrefix(current.anchor) {
                let delta = String(text.dropFirst(current.anchor.count))
                if delta.isEmpty {
                    // Caret/selection event with no text change: just reposition.
                    showSuggestion(current.text, ctx)
                    return
                }
                // The user typed (or we injected) characters that match the
                // suggestion: shrink it instead of re-querying the engine.
                if current.text.hasPrefix(delta), delta.count < current.text.count {
                    current.anchor = text
                    current.text = String(current.text.dropFirst(delta.count))
                    active = current
                    showSuggestion(current.text, ctx)
                    return
                }
                // The typed delta doesn't extend the ghost: either the user typed
                // it out in full themselves, or they went another way.
                resolveJournal(delta.hasPrefix(current.text) ? .typedThrough : .diverged,
                               typed: delta)
            } else {
                // Context jumped (backspace, caret move, programmatic edit).
                resolveJournal(.abandoned)
            }
            active = nil
            window.hide()
        }

        // Suggestions have been offered here dozens of times and essentially
        // never taken: go quiet rather than keep interrupting (and stop spending
        // the battery generating them). Deliberately after the correction pass
        // above — the record counts completions, so a typo fix or an emoji
        // shortcode still works in an app that is bad for completions. A ghost
        // that is already up keeps shrinking as the user types: it was offered
        // before the verdict landed, and yanking it mid-word helps nobody.
        // Reversible from the status menu, which is where the numbers are shown.
        if Stats.isUnproductive(typingContext.bundleID) {
            lastEvent = "quiet in this app — suggestions here are almost never taken"
            return
        }

        // Personal n-gram fast-path: a confident hit from the user's own
        // recurring phrases shows at ~0 ms, before the debounce even starts;
        // the LLM stream below then supersedes it through the same apply path.
        if let instant = instantSuggestion(text: text, after: ctx.textAfterCaret) {
            apply(instant, requestText: text, cachedContext: ctx, instant: true)
        }

        scheduleRefresh(for: text, after: ctx.textAfterCaret, context: ctx)
    }

    /// A conservative next-word / word-completion prediction from the personal
    /// n-gram model. Runs synchronously on the keystroke path — pure in-memory
    /// counts, microseconds. nil unless the user's history is emphatic.
    private func instantSuggestion(text: String, after: String) -> String? {
        guard Settings.personalizationLevel != .off else { return nil }
        PersonalNgram.shared.prepareIfNeeded()
        guard text.count >= 12 else { return nil }

        let prediction: String?
        if text.hasSuffix(" ") {
            prediction = PersonalNgram.shared.nextWord(after: text)
        } else if text.last?.isLetter == true {
            let partial = SpellChecker.trailingWord(of: text)
            if let remainder = PersonalNgram.shared.completeWord(partial: partial) {
                prediction = remainder
            } else if SpellChecker.endsOnCompleteWord(before: text, after: after) == true,
                      let word = PersonalNgram.shared.nextWord(after: text) {
                prediction = " " + word
            } else {
                prediction = nil
            }
        } else {
            prediction = nil
        }
        guard let prediction, !prediction.isEmpty else { return nil }
        // Never re-suggest what already follows the caret.
        let nextWord = prediction.trimmingCharacters(in: .whitespaces)
        guard !after.trimmingCharacters(in: .whitespaces).hasPrefix(nextWord) else { return nil }
        return prediction
    }

    private func scheduleRefresh(for text: String, after: String, context: TextContext) {
        refreshTask?.cancel()
        indicator.stop()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Nothing left to complete (e.g. the user cleared the field):
            // `indicator.stop()` only kills the timer, so any ghost or thinking
            // indicator already drawn would otherwise stay floating at the old
            // caret. Order it out explicitly.
            window.hide()
            return
        }

        if case .failed(let why) = engine.state {
            lastEvent = "engine failed: \(why)"
            indicator.flashTransient(.error("engine not working"))
            return
        }

        let request = makeRequest(text: text, after: after)
        let engine = engine
        indicator.start()

        refreshSeq += 1
        let refreshID = refreshSeq
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Settings.debounceMs))
            if Task.isCancelled { return }
            // Log the prompt with the OCR'd screen text and clipboard redacted:
            // the debug log is exportable (bug reports), and both can contain
            // OTHER people's text — it must never leave the process under the
            // export warning's "text you typed" framing.
            var redacted = request
            redacted.screenSummary = request.screenSummary.map {
                "[\($0.count) chars of on-screen text — redacted from log]"
            }
            redacted.clipboardContext = request.clipboardContext.map {
                "[\($0.count) chars of clipboard text — redacted from log]"
            }
            let fullPrompt = redacted.completionPrompt(maxChars: 1000)
            DebugLog.shared.log(
                "PROMPT",
                "\(fullPrompt.count) chars"
                    + (request.screenSummary.map { " (incl. \($0.count) screen)" } ?? "")
                    + (request.clipboardContext.map { " (incl. \($0.count) clip)" } ?? "")
                    + " — \(request.appName ?? "?")",
                detail: fullPrompt
            )
            let started = Date()
            var shown = false
            var measured = false
            do {
                // Stream the completion: render each gated partial as it decodes,
                // so the first word appears after ~one token instead of after the
                // whole generation — the dominant wait on slow machines. Latency
                // is recorded at the first token (what the user actually feels).
                for try await partial in engine.completions(for: request) {
                    if Task.isCancelled { return }
                    if !measured {
                        let latency = Date().timeIntervalSince(started)
                        await MainActor.run {
                            Stats.recordLatency(latency)
                        }
                        measured = true
                    }
                    let countShown = !shown
                    let didShow = await MainActor.run { [weak self] () -> Bool in
                        guard let self, !Task.isCancelled else { return false }
                        return self.apply(partial, requestText: request.textBeforeCaret,
                                          cachedContext: context, countShown: countShown)
                    }
                    if didShow { shown = true }
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    if self.refreshSeq == refreshID { self.refreshTask = nil }
                    self.lastEvent = "engine error: \(error.localizedDescription)"
                    DebugLog.shared.log("ERROR", error.localizedDescription)
                    self.indicator.stop()
                    self.indicator.flashTransient(.error("engine error"))
                }
                return
            }
            if Task.isCancelled { return }
            let finalShown = shown
            await MainActor.run { [weak self] in
                // Re-check cancellation on the main actor (like the sibling hops):
                // a newer keystroke can supersede this task between the check above
                // and this closure running, and the terminal apply(nil) below would
                // otherwise stomp the newer query's overlay/indicator/journal.
                guard let self, !Task.isCancelled else { return }
                if self.refreshSeq == refreshID { self.refreshTask = nil }
                self.lastPromptDescription = request.completionPrompt(maxChars: 1000)
                if finalShown {
                    self.lastResultDescription = self.active?.text
                } else if self.activeIsInstant, self.active != nil {
                    // The LLM abstained but the personal n-gram suggestion is
                    // up — a confident personal phrase beats showing nothing.
                    self.lastResultDescription = self.active?.text
                } else {
                    // Nothing passed the gates — hide and record the abstain.
                    self.lastResultDescription = nil
                    self.apply(nil, requestText: request.textBeforeCaret)
                }
            }
        }
    }

    /// Render an engine result — or a streamed partial — at the caret. Returns
    /// true when a suggestion was actually shown. `countShown` is false for the
    /// follow-up partials of a stream so one completion counts once in Stats.
    ///
    /// `cachedContext` is the `TextContext` captured when the stream began. Streamed
    /// partials pass it so each one doesn't trigger a fresh synchronous AX read on
    /// the main thread (N reads per completion): the caret can't move without a
    /// keystroke, and every keystroke advances or invalidates
    /// `latestTextBeforeCaret` synchronously, so the equality gate below
    /// catches typing mid-stream. `nil` ⇒ read AX now.
    @discardableResult
    private func apply(_ result: String?, requestText: String,
                       cachedContext: TextContext? = nil, countShown: Bool = true,
                       instant: Bool = false, maxChars: Int = 120,
                       allowEmpty: Bool = false) -> Bool {
        indicator.stop()
        guard Settings.enabled else { return false }
        var suggestion = result.map { sanitize($0, maxChars: maxChars) } ?? ""
        guard !suggestion.isEmpty else {
            // nil/empty is an abstain — or a mid-stream RETRACT ("" from the
            // engine when its final gate rejected what the partials already
            // showed). Close the journal record and clear the stale suggestion
            // so a hidden one can't still be accepted.
            lastEvent = "engine returned no suggestion"
            resolveJournal(.abandoned)
            active = nil
            window.hide()
            return false
        }
        // While an injection settles, every anchor in reach (cache or AX read)
        // either predates or trails the synthetic keystrokes: narrowing a
        // streamed partial against one resurrects the just-accepted word (and
        // in a ≥maxContextChars document the window offsets diverge outright).
        // Drop it — the post-settle refresh re-streams from the true context,
        // and the ghost the accept advanced stays up meanwhile.
        if let deadline = injectionSettleDeadline, Date() < deadline {
            lastEvent = "result during injection settle; dropped"
            return false
        }
        let ctx: TextContext
        // Trust the cached context only while the typed text is unchanged since
        // the stream began (the cheap string compare avoids an AX read). If the
        // user typed mid-stream, `latestTextBeforeCaret` has moved on — fall back
        // to a fresh read so the partial re-anchors and shrinks correctly.
        if let cachedContext, cachedContext.textBeforeCaret == latestTextBeforeCaret {
            ctx = cachedContext
        } else if let element = currentTextElement(),
                  let fresh = AXText.context(for: element, maxChars: Settings.maxContextChars,
                                             allowEmpty: allowEmpty) {
            ctx = fresh
        } else {
            // The reply path lands here whenever the field is empty and this read
            // refuses it — which was every composed reply in a web/Electron chat
            // box: generated, then dropped one line before the ghost.
            lastEvent = "lost text element"
            DebugLog.shared.log("SHOW", "dropped a result — field unreadable at apply time")
            window.hide()
            return false
        }

        let current = ctx.textBeforeCaret
        if current != requestText {
            // The user kept typing while the engine was thinking: the result is
            // still usable if the newly typed characters match its beginning.
            guard current.hasPrefix(requestText) else {
                lastEvent = "context changed; dropped result"
                window.hide()
                return false
            }
            let delta = String(current.dropFirst(requestText.count))
            guard suggestion.hasPrefix(delta), delta.count < suggestion.count else {
                lastEvent = "typed past the suggestion"
                window.hide()
                return false
            }
            suggestion = String(suggestion.dropFirst(delta.count))
        }

        // Normalize on the main thread (NSSpellChecker is unsafe off it): drop a
        // stray separator the engine prepended to a word-continuation ("при " +
        // "вет" → "привет"), then lower a wrongly capitalized mid-sentence
        // continuation ("я хочу " + "Поехать" → "поехать").
        suggestion = SpellChecker.strippingStraySeparator(suggestion: suggestion, before: current)
        suggestion = Self.deduplicatingSeamSpace(suggestion, after: current)
        suggestion = SpellChecker.decapitalizeContinuation(suggestion, before: current)

        if Self.wouldGlueMidWord(current: current, suggestion: suggestion) {
            // A mid-word suggestion that fuses a whole new word onto the partial
            // word ("быст" + "ответ" → "быстответ"): instruct/FM models answer
            // flush, so the gate can't catch this upstream. Drop it — showing
            // nothing beats showing garbage.
            lastEvent = "dropped mid-word glue suggestion"
            resolveJournal(.abandoned)
            active = nil
            window.hide()
            return false
        }

        // Preserve the "already counted as accepted" flag across streamed growth
        // of the same suggestion (countShown == false, no recordShown); reset it
        // only for a genuinely fresh suggestion. Keeps accepted ≤ shown even when
        // the user accepts word-by-word while the model is still streaming.
        active = Active(anchor: current, text: suggestion,
                        accepted: countShown ? false : (active?.accepted ?? false))
        activeIsInstant = instant
        if countShown {
            // A fresh suggestion opens a journal record; an unresolved one at
            // this point was replaced before the user reacted to it. The offer
            // itself is booked when this record resolves — resolveJournal.
            resolveJournal(.superseded)
            pendingJournal = PendingJournal(
                ctx: current, after: ctx.textAfterCaret, suggestion: suggestion,
                hadScreen: screenSummary != nil
                    && AppPolicy.allowsScreenContext(typingContext.bundleID),
                app: typingContext.bundleID,
                engine: instant ? "ngram" : engine.name,
                // The engine's OWN resolved model — not Settings.mlxModelID,
                // which diverges from what actually generated (instruct loads
                // the it-sibling; Apple Intelligence has no MLX model at all).
                model: instant ? nil : engine.loadedModelID,
                style: Settings.completionStyle.rawValue,
                gate: Settings.confidenceGate
                    ? "\(Settings.confidenceGateSamples)@\(Settings.confidenceGateThreshold)" : "off",
                personalization: Settings.personalizationLevel.rawValue
                    + (Settings.personalExamplesEnabled ? "+rag" : ""))
        } else {
            // Streamed growth of the same suggestion — keep the record current.
            pendingJournal?.suggestion = suggestion
        }
        showSuggestion(suggestion, ctx)
        return true
    }

    /// True when showing `suggestion` after `current` would glue a standalone new
    /// word onto the half-typed word at the caret. Only fires when the caret is
    /// mid-word (a letter, no trailing space), the suggestion claims to continue
    /// it (no leading space), its first word is itself a real word, and the
    /// merged form is NOT — i.e. it's a fresh word fused on, not a completion
    /// ("appreci" + "ate" = "appreciate" is a real word, so it passes). Runs on
    /// the main thread, where NSSpellChecker is safe.
    private static func wouldGlueMidWord(current: String, suggestion: String) -> Bool {
        guard current.last?.isLetter == true, !suggestion.hasPrefix(" ") else { return false }
        let partial = SpellChecker.trailingWord(of: current)
        let firstWord = String(suggestion.prefix {
            $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-"
        })
        guard !partial.isEmpty, !firstWord.isEmpty else { return false }
        return SpellChecker.isCompleteWord(firstWord, context: current)
            && !SpellChecker.isCompleteWord(partial + firstWord, context: current)
    }

    private func showSuggestion(_ text: String, _ ctx: TextContext) {
        guard let rect = ctx.caretRect else {
            lastEvent = "no caret geometry — cannot place overlay"
            dismiss()
            return
        }
        lastCaretRect = rect
        // The inline ghost trims the suggestion to what fits on the line, and
        // what ⇧⇥ accepts has to be exactly what the user was shown — offering
        // an ellipsized tail is offering text sight unseen. Only ever a prefix,
        // so narrowing, accepting and the journal all still line up.
        let shown = window.show(mode: .suggestion(text), at: rect, host: ctx.host) ?? text
        if shown != text {
            active?.text = shown
            pendingJournal?.suggestion = shown
        }
        lastEvent = "suggesting \"\(shown.prefix(40))\""
        if shown != lastLoggedSuggestion {
            lastLoggedSuggestion = shown
            DebugLog.shared.log("SHOW", "\"\(shown)\""
                + (shown != text ? " (trimmed to the line from \(text.count) chars)" : ""))
        }
        if !Settings.onboardingCompleted {
            onboardingWindow?.updateStatusSuggestionActive(true)
        }
    }

    /// `maxChars` is the hard backstop on what can reach the field: a keystroke
    /// completion is a few words, a composed reply a few sentences.
    private func sanitize(_ raw: String, maxChars: Int = 120) -> String {
        var out = raw.replacingOccurrences(of: "\t", with: " ")
        if let newline = out.firstIndex(where: { $0.isNewline }) {
            out = String(out[..<newline])
        }
        while out.contains("  ") {
            out = out.replacingOccurrences(of: "  ", with: " ")
        }
        if out.count > maxChars {
            out = String(out.prefix(maxChars))
        }
        while out.hasSuffix(" ") {
            out.removeLast()
        }
        return out
    }

    // MARK: - Reply

    /// Write the user's next message for them: OCR the conversation in front of
    /// them, ask the engine to answer it, and offer the whole thing as one ghost
    /// the normal accept keys take (⇥ word by word, ⇧⇥ all of it, ⎋ to drop it).
    /// Explicit chord only — nothing is generated, and nothing typed, unasked.
    ///
    /// It borrows `refreshTask` for the duration, so the thinking dots run, a
    /// keystroke or a focus change cancels it, and it can't race a completion.
    /// Never call inside the event-tap callback: it does synchronous AX reads.
    private func composeReply() {
        // Every stop below says why, in the console and in the menu's "Last:"
        // line: an explicitly-pressed chord that does nothing, silently, is
        // indistinguishable from a broken build.
        DebugLog.shared.log(
            "REPLY", "requested (\(Settings.replyGesture.label) / \(Settings.hotkeyStyle.replyLabel))")
        func stop(_ why: String) {
            lastEvent = "reply: \(why)"
            DebugLog.shared.log("REPLY", "not composing — \(why)")
        }
        guard Settings.enabled else { return stop("Pretype is paused") }
        guard !isOwnUIFrontmost else { return stop("our own window is frontmost") }
        guard !AppPolicy.isBlacklisted(typingContext.bundleID) else {
            return stop("off in \(typingContext.appName ?? "this app")")
        }
        guard let element = currentTextElement() else {
            return stop("no text field in focus")
        }
        // allowEmpty: an empty chat box is the case this feature exists for —
        // the completion pipeline's "nothing to continue" is not a refusal here.
        guard let ctx = AXText.context(for: element, maxChars: Settings.maxContextChars,
                                       allowEmpty: true),
              let rect = ctx.caretRect else {
            return stop("cannot read the field or place the ghost")
        }
        lastCaretRect = rect
        lastHostStyle = ctx.host
        // We just read the field — make that the cache marker, so the result
        // lands on the cached context instead of paying for another AX read
        // (and so an accept advances from the right place).
        latestTextBeforeCaret = ctx.textBeforeCaret
        // Without the screen there is nothing to reply *to*: say so at the caret
        // instead of answering from the empty field.
        guard Settings.screenContextEnabled, ScreenContext.hasPermission,
              AppPolicy.allowsScreenContext(typingContext.bundleID) else {
            stop("needs screen context — \(screenContextStatus)")
            indicator.flashTransient(.error("reply needs screen context"))
            return
        }
        clearActiveCompletion()
        window.hide()
        indicator.start()
        lastEvent = "composing a reply…"

        let request = makeRequest(text: ctx.textBeforeCaret, after: ctx.textAfterCaret)
        let engine = engine
        let pid = focusTracker.observedPID
        let generation = focusGeneration
        refreshSeq += 1
        let refreshID = refreshSeq
        refreshTask = Task { [weak self] in
            // A fresh, wider capture — not the 25 s-cached completion context:
            // the message being answered may have landed a second ago. No caret
            // ROI either: that band is ±250 pt of the input box, while a reply
            // needs the exchange above it — the whole window, capped from the
            // bottom, which is where the recent messages are.
            let conversation = await ScreenContext.capture(
                pid: pid, excluding: ctx.textBeforeCaret, caretRect: nil, maxChars: 1200)
            if Task.isCancelled { return }
            let outcome: Result<String?, Error>
            if let conversation {
                do {
                    outcome = .success(try await engine.reply(to: conversation, request: request))
                } catch is CancellationError {
                    return
                } catch {
                    outcome = .failure(error)
                }
            } else {
                outcome = .success(nil)
            }
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                if self.refreshSeq == refreshID { self.refreshTask = nil }
                self.indicator.stop()
                guard self.focusGeneration == generation else {
                    DebugLog.shared.log("REPLY", "dropped — focus changed")
                    return
                }
                // Count only, never the text: this is OTHER people's on-screen
                // text and the log is exportable (same rule as the OCR log).
                DebugLog.shared.log(
                    "REPLY", "\(conversation?.count ?? 0) chars of screen context")
                switch outcome {
                case .success(let reply?):
                    // Through the normal apply path: same anchoring, settle and
                    // journal rules as a completion — only longer, and reading an
                    // empty field as a real (empty) context.
                    let shown = self.apply(reply, requestText: ctx.textBeforeCaret,
                                           cachedContext: ctx, maxChars: 400, allowEmpty: true)
                    DebugLog.shared.log("REPLY", shown ? "shown" : "dropped — \(self.lastEvent)")
                case .success(nil):
                    // Two different silences: nothing readable on screen, or the
                    // model had nothing to say about it.
                    let why = conversation == nil ? "nothing to reply to" : "no answer from the model"
                    self.lastEvent = "reply: \(why)"
                    self.indicator.flashTransient(.hint(why))
                case .failure(let error):
                    self.lastEvent = "reply failed: \(error.localizedDescription)"
                    DebugLog.shared.log("ERROR", "reply failed: \(error.localizedDescription)")
                    self.indicator.flashTransient(.error("reply failed"))
                }
            }
        }
    }

    // MARK: - Key handling

    private func handleKeyDown(_ event: CGEvent) -> Bool {
        guard Settings.enabled else { return false }
        if event.getIntegerValueField(.eventSourceUserData) == TextInjector.magicTag { return false }
        // A real keystroke means a held modifier is part of a chord, not a tap.
        replyTap.keyPressed()
        // ...and not someone talking either. Unconditional, because the window
        // that matters most is the one where there is no capture yet: ⌥⌫ and
        // ⌥-arrows hold the modifier across several presses, and a hold left
        // armed through them opens the microphone in the middle of a chord.
        // Idle this costs a cleared date. Escape is the explicit "forget that"
        // while listening, so it is ours to swallow — but only when a capture
        // was live as it arrived, which the call below is what ends.
        let wasDictating = dictationController.isBusy
        let isEscape = event.getIntegerValueField(.keyboardEventKeycode) == KeyCode.escape
        dictationController.keyPressed(isEscape: isEscape)
        if wasDictating, isEscape { return true }
        // Our own Settings/Debug field is focused — pass every key through
        // untouched (never accept a stale background suggestion into it).
        if isOwnUIFrontmost { return false }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // Exact ⌘Z undoes the last accepted chunk. The cached-text check decides
        // consume vs pass-through synchronously (no AX read inside the tap): a
        // caret moved since the accept (mouse click) means the app's own undo is
        // the right handler, not our backspaces. On a miss the key falls through
        // and the bottom of this function clears `lastAcceptedChunk`.
        if let accepted = lastAcceptedChunk, let expected = lastAcceptedSnapshot,
           Self.isPlainCommandZ(keyCode: keyCode,
                                key: NSEvent(cgEvent: event)?.charactersIgnoringModifiers?.lowercased(),
                                flags: flags),
           latestTextBeforeCaret == expected {
            lastAcceptedChunk = nil
            // Delete off the tap, after a live re-read: the cache trails typing
            // in Electron, and blind backspaces at a moved caret eat text.
            DispatchQueue.main.async { [weak self] in self?.undoAccept(accepted, expected: expected) }
            return true
        }

        // Compose a reply from what's on screen (⌥⇧⇥). Checked before the fix
        // flows only for symmetry — the two chords differ by ⇧ and the fix
        // matcher demands exact flags, so neither can swallow the other. Hops
        // off the tap: the flow does synchronous AX reads.
        if Settings.hotkeyStyle.matchesReply(keyCode: keyCode, flags: flags) {
            lastAcceptedChunk = nil
            DispatchQueue.main.async { [weak self] in self?.composeReply() }
            return true
        }

        // Fix flows (⌥⇥, plus the keys that apply/dismiss a fix preview) get
        // first refusal — a fix preview is only ever up when no completion is.
        switch correctionController.handleKey(keyCode: keyCode, flags: flags) {
        case .consumed:
            lastAcceptedChunk = nil
            return true
        case .passThrough:
            lastAcceptedChunk = nil
            return false
        case .ignored:
            break
        }

        // ponytail: no IME/marked-text check on the tap. The tap only swallows
        // while a ghost is up, and a composition kills the ghost first: the
        // keystroke that starts it doesn't match the ghost, so `narrowActive()`
        // drops it, and the ≤60 ms AX refresh then reads a nil context
        // (`AXText.isComposing`) and dismisses. Ceiling: a ghost whose first
        // character equals the keystroke that starts a composition — narrowActive
        // keeps it — with Tab landing inside that same ≤60 ms window, where Tab
        // accepts instead of picking a candidate.
        // Upgrade path if that's ever seen in the wild: query
        // `AXText.isComposing` on the focused element here too.
        // `showsSuggestion`, not `isVisible`: the ghost is only acceptable while
        // it is the thing on screen. Anything else holding the window — a
        // dictation notice, a correction pill, an engine status — means ⇥ would
        // be inserting text the user can no longer see.
        if let current = active, window.showsSuggestion {
            let style = Settings.hotkeyStyle
            if style.matchesAcceptAll(keyCode: keyCode, flags: flags) {
                accept(chunk: current.text)
                return true
            } else if style.matchesAcceptWord(keyCode: keyCode, flags: flags) {
                accept(chunk: Self.firstWordChunk(of: current.text))
                return true
            }
            if keyCode == KeyCode.escape {
                // Drop the ghost, but let Escape still reach the app (close a
                // dialog, clear a field) — it isn't ours to swallow.
                resolveJournal(.dismissed)
                dismiss()
                lastAcceptedChunk = nil
                return false
            }
        }

        // Keep `active` truthful before this keystroke reaches the app: the
        // re-read below is a 60 ms *throttle*, and an accept landing inside
        // that window would re-inject characters the OS already typed
        // (duplicating them). Worst in Electron apps, where AX notifications
        // are unreliable and the timer is the only update path.
        narrowActive(with: event, flags: flags)

        // AX change notifications are unreliable in some apps (notably
        // Electron), so every keystroke also schedules a context re-read.
        scheduleKeystrokeRefresh()
        lastAcceptedChunk = nil
        return false
    }

    /// Synchronously shrinks (or drops) the live suggestion to match a
    /// pass-through keystroke, using the characters carried by the event
    /// itself — no AX round-trip, so it can't block on a hung target app.
    private func narrowActive(with event: CGEvent, flags: CGEventFlags) {
        // Command/control chords carry no typed text but can mutate the field
        // arbitrarily (⌘V, ⌘X, the app's own ⌘Z): both the synchronous cache
        // and the ghost stop being trustworthy — invalidate them and let the
        // scheduled AX refresh re-read the truth, exactly like control input.
        guard !flags.contains(.maskCommand), !flags.contains(.maskControl) else {
            latestTextBeforeCaret = nil
            if active != nil {
                resolveJournal(.abandoned)
                active = nil
                window.hide()
            }
            return
        }
        let typed = Self.typedCharacters(event)
        guard !typed.isEmpty else { return }   // dead keys, bare modifiers
        let isControl = typed.unicodeScalars.contains {
            $0.value < 0x20 || $0.value == 0x7F || (0xF700...0xF8FF).contains($0.value)
        }
        // Keep the cache marker truthful for EVERY pass-through keystroke,
        // ghost or not: a streamed partial landing inside the ≤60 ms refresh
        // window anchors on this cache, and pre-keystroke text would make Tab
        // duplicate the typed character. Control input (backspace, arrows)
        // can't be replayed onto the cache — nil it so apply() falls back to a
        // fresh AX read.
        if isControl {
            latestTextBeforeCaret = nil
        } else {
            advanceCache(typed)
        }
        guard var current = active else { return }
        guard let remaining = Self.narrowedSuggestion(current.text, typedCharacters: typed) else {
            // Divergent or control input — the ghost no longer matches the field.
            if isControl {
                resolveJournal(.abandoned)
            } else if typed.hasPrefix(current.text) {
                // The keystroke completed the remaining suggestion unaided.
                resolveJournal(.typedThrough)
            } else {
                resolveJournal(.diverged, typed: typed)
            }
            active = nil
            window.hide()
            return
        }
        current.anchor += typed
        current.text = remaining
        active = current
        // The pill re-render inside advance can flip back into a trimmed ghost
        // — same contract as show: never accept more than is on screen.
        if let shown = window.advance(past: typed, remaining: remaining), shown != remaining {
            active?.text = shown
        }
    }

    /// Append injected/typed text to the cache marker, re-capping it to the AX
    /// read window: fresh reads return at most `maxContextChars` before the
    /// caret, and an uncapped cache in a longer document would sit at a
    /// different offset than every fresh read — structurally failing the
    /// settle/undo equality gates.
    private func advanceCache(_ s: String) {
        guard var cached = latestTextBeforeCaret else { return }
        cached += s
        let cap = Settings.maxContextChars
        if cached.count > cap { cached.removeFirst(cached.count - cap) }
        latestTextBeforeCaret = cached
    }

    /// Pure narrowing decision (testable): the suggestion remainder after the
    /// user typed `typed`, or nil when the keystroke invalidates it — control
    /// input (backspace, arrows, function keys), a diverging character, or
    /// typing through the suggestion's end.
    nonisolated static func narrowedSuggestion(_ text: String, typedCharacters typed: String) -> String? {
        guard !typed.unicodeScalars.contains(where: {
            $0.value < 0x20 || $0.value == 0x7F || (0xF700...0xF8FF).contains($0.value)
        }), typed.count < text.count, text.hasPrefix(typed) else { return nil }
        return String(text.dropFirst(typed.count))
    }

    /// The characters this key event will insert, as reported by the event.
    private static func typedCharacters(_ event: CGEvent) -> String {
        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &chars)
        return String(utf16CodeUnits: chars, count: min(length, 8))
    }

    func scheduleKeystrokeRefresh(after delay: TimeInterval = 0.06) {
        guard !keyRefreshScheduled else { return }
        keyRefreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.keyRefreshScheduled = false
            self.textDidChange()
        }
    }

    /// Exact ⌘Z on the current layout: any extra chord modifier (⇧⌘Z redo,
    /// ⌥⌘Z, …) is the app's key. Layouts that move Z (QWERTZ, AZERTY) are
    /// decided by the produced character; layouts with no Latin letters at all
    /// (ЙЦУКЕН, Greek) fall back to the physical ANSI key — the same
    /// resolution macOS uses for its own ⌘-shortcuts.
    nonisolated static func isPlainCommandZ(keyCode: Int64, key: String?, flags: CGEventFlags) -> Bool {
        guard flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]) == [.maskCommand] else {
            return false
        }
        if let key, key.count == 1, ("a"..."z").contains(key) {
            return key == "z"
        }
        return keyCode == KeyCode.z
    }

    /// ⌘Z after an accept: remove the injected chunk. Runs off the event-tap
    /// callback (synchronous AX read) and skips the deletion unless the live
    /// text still reads exactly like the post-accept snapshot — same
    /// validate-before-delete rule as `CorrectionController.inject`.
    private func undoAccept(_ accepted: String, expected: String) {
        // Fail closed: an unreadable context (active selection, hung app,
        // secure input) skips the undo rather than deleting blindly — the
        // first backspace would eat a whole selection. The chunk stays cleared,
        // so the next ⌘Z reaches the app.
        guard let element = currentTextElement(),
              let ctx = AXText.context(for: element, maxChars: Settings.maxContextChars) else {
            DebugLog.shared.log("UNDO", "skipped — context unreadable")
            return
        }
        guard ctx.textBeforeCaret == expected else {
            // A readable context that doesn't confirm yet usually means AX is
            // trailing the injected text (Electron): restore the state so the
            // next ⌘Z retries once AX catches up — any other keystroke still
            // clears it in handleKeyDown.
            lastAcceptedChunk = accepted
            lastAcceptedSnapshot = expected
            DebugLog.shared.log("UNDO", "skipped — field no longer matches the post-accept snapshot")
            return
        }
        TextInjector.deleteBackward(accepted.count)
        // Roll the pipeline back with the text: the shrunk ghost, the live
        // stream and the advanced cache all still assume the chunk is in the
        // field — a Tab or a streamed partial landing before the 0.09 s AX
        // refresh would re-accept or resurrect the just-undone word.
        if latestTextBeforeCaret?.hasSuffix(accepted) == true {
            latestTextBeforeCaret?.removeLast(accepted.count)
        }
        injectionSettleDeadline = Date().addingTimeInterval(0.3)
        let wasDictated = lastAcceptedWasDictated
        dismiss()
        // A dictated chunk is a spoken sentence: it may be named by length
        // here, never quoted — the debug buffer is exported into bug reports
        // and this message field is not even length-capped on the way out.
        lastEvent = wasDictated
            ? "undid a dictation of \(accepted.count) characters"
            : "undid acceptance of \"\(accepted)\""
        DebugLog.shared.log(
            "UNDO", wasDictated ? "\(accepted.count) chars — redacted from log" : "\"\(accepted)\"")
        indicator.flashTransient(.hint("Undone"))
        // The accept was already journaled; an undo is the strongest reject
        // signal there is, so it gets its own event. Never for dictation: the
        // journal is on disk, the flow promises it never records a transcript,
        // and an `.undone` row only ever acts as a negative filter against a
        // phrase this pipeline suggested — which a spoken sentence never was.
        if Settings.suggestionJournalEnabled, !wasDictated {
            SuggestionJournal.shared.append(SuggestionJournal.Entry(
                ts: SuggestionJournal.timestamp(),
                app: typingContext.bundleID,
                engine: engine.name,
                ctx: String((latestTextBeforeCaret ?? "").suffix(1000)),
                after: "",
                suggestion: accepted,
                outcome: .undone,
                acceptedChars: -accepted.count,
                typed: nil,
                shownForMs: 0,
                screen: false))
        }
        scheduleKeystrokeRefresh(after: 0.09)
    }

    private func accept(chunk: String) {
        guard var current = active, !chunk.isEmpty else { return }
        lastAcceptedChunk = chunk
        // Paired with every assignment of the chunk, so the flag can never
        // describe a different chunk than the one undo would remove. The nil
        // assignments leave it alone on purpose: it is only ever read
        // alongside a non-nil chunk.
        lastAcceptedWasDictated = false
        TextInjector.insert(chunk)
        // Advance the cached marker in step with the injection (mirrors
        // narrowActive for user-typed keys). Until the 0.09 s AX refresh lands,
        // a streamed partial and the ⌘Z gate both read this cache — a stale
        // marker re-arms the just-accepted word (double insert on a second Tab)
        // and makes an immediate ⌘Z fall through to the app.
        advanceCache(chunk)
        lastAcceptedSnapshot = latestTextBeforeCaret
        injectionSettleDeadline = Date().addingTimeInterval(0.3)
        // Count the suggestion once even when accepted word-by-word (chars still
        // accrue per chunk), so the menu's "accepted of shown" can't exceed 100%.
        Stats.recordAccepted(chunk: chunk, countSuggestion: !current.accepted,
                             app: typingContext.bundleID)
        current.accepted = true
        lastEvent = "accepted \"\(chunk)\""
        DebugLog.shared.log("ACCEPT", "\"\(chunk)\"")
        pendingJournal?.acceptedChars += chunk.count
        if chunk.count >= current.text.count {
            resolveJournal(.accepted)
            active = nil
            // A fully-accepted suggestion ends its stream. Otherwise a later
            // partial re-mints `active` (with no recordShown), re-showing and
            // re-counting a continuation at the stale caret. The 0.09s refresh
            // below re-queries the extended context and re-streams cleanly.
            refreshTask?.cancel()
            refreshTask = nil
            window.hide()
        } else {
            current.anchor += chunk
            current.text = String(current.text.dropFirst(chunk.count))
            active = current
            // Slide the remaining ghost forward in place so accepting word by
            // word stays smooth; the keystroke refresh then re-anchors it on
            // the real caret. Its pill path can flip back into a trimmed ghost
            // — narrow what ⇧⇥ accepts to what it actually rendered.
            if let shown = window.advance(past: chunk, remaining: current.text),
               shown != current.text {
                active?.text = shown
            }
        }
        if !Settings.onboardingCompleted {
            Settings.onboardingCompleted = true
            onboardingWindow?.dismiss()
        }
        // Re-read context once the synthetic keystrokes have landed.
        scheduleKeystrokeRefresh(after: 0.09)
    }

    // MARK: - Dictation

    /// Adopt a caret reading taken by a side flow, so the indicator and any
    /// later overlay place against the same field that flow measured.
    func noteCaret(rect: CGRect, host: HostTextStyle) {
        lastCaretRect = rect
        lastHostStyle = host
    }

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
        func drop(_ why: String, hint: String) {
            lastEvent = "dictation dropped — \(why)"
            DictationController.note("dropped \(text.count) chars — \(why)")
            showTransientOverlay(.hint(hint),
                                 at: lastCaretRect ?? DictationController.pointerAnchor(),
                                 host: lastHostStyle)
        }
        guard !NSApp.isActive else {
            return drop("our own window took focus",
                        hint: "dictation dropped — click back into your text field")
        }
        guard !AXText.isSecureInputActive() else {
            return drop("secure input engaged",
                        hint: "dictation dropped — a password field took focus")
        }
        guard currentTextElement() != nil else {
            return drop("no text field", hint: "dictation dropped — no text field in focus")
        }
        // Remade at injection time like the rest: a composition opened during
        // the capture (the transcript arrives hundreds of milliseconds after
        // the words) would swallow the synthetic keystrokes into its marked
        // text. Precise marked-text only — see `isComposingInFocusedField`.
        guard !isComposingInFocusedField() else {
            return drop("an IME composition is open",
                        hint: "dictation dropped — finish composing that word first")
        }
        // Advisory, exactly as at capture time: a field that publishes no caret
        // (web and Electron inputs before their first keystroke) must still
        // receive what was said. Without the read there is no seam to judge and
        // no snapshot to undo against, so both are skipped rather than guessed.
        // Through the same re-resolving read the anchor uses — the handle this
        // very method invalidated last time is the one that would fail here.
        let context = dictationFieldContext()
        let before = context?.textBeforeCaret
        clearActiveCompletion()
        window.hide()
        latestTextBeforeCaret = before
        // Both seams come out of that one read: the caret can sit mid-sentence
        // (dictating into a half-written line), and the text after it decides
        // the trailing space exactly as the text before it decides the leading
        // one. A second AX round-trip would only re-read the same snapshot.
        let chunk = context.map {
            Self.spacedForInsertion(text, after: $0.textBeforeCaret, before: $0.textAfterCaret)
        } ?? text
        TextInjector.insert(chunk)
        if before != nil {
            lastAcceptedChunk = chunk
            // ⌘Z removes it exactly like an accepted suggestion — but the undo
            // path books what it removed, and this chunk was spoken.
            lastAcceptedWasDictated = true
            advanceCache(chunk)
            lastAcceptedSnapshot = latestTextBeforeCaret
        }
        injectionSettleDeadline = Date().addingTimeInterval(0.3)
        // The transcript's own length, not the chunk's: the seam spaces are
        // typing mechanics, and the counter claims to measure what was said.
        Stats.recordDictated(chars: text.count)
        lastEvent = "dictated \(chunk.count) characters"
        // The transcript itself never reaches the log: the debug buffer is
        // exportable for bug reports, and what was said aloud is as sensitive
        // as the OCR'd screen and the clipboard, both of which the prompt log
        // redacts the same way. The count is the whole diagnostic value here.
        DictationController.note("typed \(chunk.count) characters")
        scheduleKeystrokeRefresh(after: 0.09)
    }

    /// The spaces between what is already in the field and what was just
    /// dictated. Speech has no spacebar: the transcript always starts at a
    /// word, and the caret may be sitting right after one — "привет" spoken
    /// after "я сказал" must not land as "я сказалпривет" — or right *before*
    /// one, where "hello|world" would fuse the spoken tail into the word that
    /// follows. Nothing is added after whitespace or an opening bracket, and
    /// nothing before punctuation that belongs to the word it hugs; the right
    /// seam is the same rules mirrored. Both are decided here so the caller
    /// injects, caches and books ONE chunk — a trailing space added by a second
    /// insert would be missing from `advanceCache` and the undo snapshot.
    ///
    /// `following` defaults to empty because a caret at the end of the field
    /// has no right seam to judge, which is where dictation usually lands.
    nonisolated static func spacedForInsertion(_ text: String, after context: String,
                                               before following: String = "") -> String {
        var chunk = text
        if let last = context.last, let first = text.first,
           !last.isWhitespace, !last.isNewline, !first.isWhitespace,
           !"([{«“„<".contains(last), !".,!?;:)]}»”…".contains(first),
           !isScriptioContinua(last), !isScriptioContinua(first) {
            chunk = " " + chunk
        }
        if let last = text.last, let first = following.first,
           !last.isWhitespace, !last.isNewline, !first.isWhitespace, !first.isNewline,
           !"([{«“„<".contains(last), !".,!?;:)]}»”…".contains(first),
           !isScriptioContinua(last), !isScriptioContinua(first) {
            chunk += " "
        }
        return chunk
    }

    /// Han, kana, and the CJK/fullwidth punctuation that travels with them —
    /// scripts written without spaces between words, where a seam space is not
    /// a nicety but a typo the user then has to delete. Fullwidth punctuation
    /// carries its own side-bearing for the same reason, so "。" needs no space
    /// before it and "「" none after it. Hangul is deliberately absent: Korean
    /// orthography spaces its words like ours, so it takes the ordinary rules.
    nonisolated private static func isScriptioContinua(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3000...0x303F,      // CJK symbols and punctuation (、。「」)
             0x3040...0x309F,      // hiragana
             0x30A0...0x30FF,      // katakana
             0x3400...0x4DBF,      // CJK ideographs ext. A
             0x4E00...0x9FFF,      // CJK unified ideographs
             0xF900...0xFAFF,      // CJK compatibility ideographs
             0xFF00...0xFFEF,      // fullwidth and halfwidth forms (！？，)
             0x20000...0x2FA1F:    // CJK ext. B–F (e.g. 𨐈)
            return true
        default:
            return false
        }
    }

    /// Drop a leading space the context already supplies. You type "спасибо за "
    /// and the model predicts a fresh word as " ответ" — the space is right
    /// after a word, wrong after a space. Shown, it is a stray gap between the
    /// caret and the ghost that looks like the suggestion is mispositioned;
    /// typed, it is a real double space in the sentence.
    ///
    /// `strippingStraySeparator` is the mirror case (a separator prepended to a
    /// *word continuation*) and deliberately only fires after a letter, so it
    /// never saw this one.
    nonisolated static func deduplicatingSeamSpace(_ suggestion: String, after context: String) -> String {
        guard context.hasSuffix(" "), suggestion.hasPrefix(" ") else { return suggestion }
        return String(suggestion.drop { $0 == " " })
    }

    /// Leading spaces plus the first run of non-space characters.
    nonisolated static func firstWordChunk(of text: String) -> String {
        var chunk = ""
        var seenNonSpace = false
        for ch in text {
            if ch == " " {
                if seenNonSpace { break }
            } else {
                seenNonSpace = true
            }
            chunk.append(ch)
        }
        return chunk
    }

}

extension SuggestionController: FocusTrackerDelegate {
    func focusTrackerDidChangeFocus(_ tracker: FocusTracker) {
        // Apps fire the focus notification in duplicate bursts; identical
        // context + identical element means nothing actually changed.
        let newContext = tracker.typingContext
        let sameElement: Bool
        switch (tracker.focusedTextElement, lastFocusedElement) {
        case let (new?, old?): sameElement = CFEqual(new, old)
        case (nil, nil): sameElement = true
        default: sameElement = false
        }
        if newContext == typingContext, sameElement { return }

        focusGeneration += 1
        // A capture belongs to the field it started in: carried across a focus
        // change it would type a sentence meant for one app into another.
        dictationController.invalidate()
        lastFocusedElement = tracker.focusedTextElement
        lastCaretRect = nil
        lastHostStyle = HostTextStyle()
        // The overlay's remembered field style and the probe's pixel verdict
        // describe the field we just left; carried across they outrank what the
        // new field reports about itself (dark verdict from the previous app on
        // a white page — the same unreadable pill the tone resolver exists to
        // prevent).
        window.fieldChanged()
        correctionController.focusChanged()
        typingContext = newContext
        let policy = AppPolicy.isBlacklisted(typingContext.bundleID)
            ? " — suggestions off (blacklisted)"
            : (AppPolicy.isCodeEditor(typingContext.bundleID) ? " — code editor, no screen context" : "")
        DebugLog.shared.log(
            "FOCUS",
            "\(typingContext.appName ?? "?")\(policy)",
            detail: "window: \(typingContext.windowTitle ?? "—")\nfield: \(typingContext.fieldLabel ?? "—")"
        )
        // Stale window text must not leak into the new context.
        screenSummary = nil
        screenCapturedAt = .distantPast
        // The cache and any live settle window are field-scoped: carried into
        // the new app they would hold textDidChange hostage to the OLD field's
        // text (retry loop until the deadline) and advanceCache would glue new
        // keystrokes onto it.
        latestTextBeforeCaret = nil
        injectionSettleDeadline = nil
        // Examples anchored to the previous app's text go stale too; the next
        // keystroke in the new field re-retrieves immediately.
        personalExamples = []
        examplesRefreshedAt = .distantPast
        dismiss()
        // Capture shortly after focus settles: passing through apps with
        // cmd-tab must not trigger screenshots, but a chat's first message
        // should still have context before the first keystroke lands.
        if let element = tracker.focusedTextElement {
            // Entered a text field — start reloading the model now (no-op unless
            // it was idle-unloaded) so the first keystroke doesn't wait for it.
            engine.prewarmIfNeeded()
            if case .preparing = engine.state {
                if let ctx = AXText.context(for: element, maxChars: Settings.maxContextChars) {
                    lastCaretRect = ctx.caretRect
                    lastHostStyle = ctx.host
                    indicator.start()
                }
            }
            let generation = focusGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, self.focusGeneration == generation else { return }
                self.refreshScreenContextIfNeeded(typed: "")
            }
        }
    }

    func focusTrackerTextDidChange(_ tracker: FocusTracker) {
        textDidChange()
    }

    func focusTrackerDidResignActiveApp(_ tracker: FocusTracker) {
        // A capture dies with the app it started in. This is the only signal
        // that fires when the app switched *to* is Pretype itself — the tracker
        // never attaches to our own pid, so no focus change bumps
        // `focusGeneration`, and a capture left alive here would pass its
        // stale-focus check and type the transcript into our own menu or
        // Settings field.
        dictationController.invalidate()
        // Left the app we were typing in — drop any ghost/indicator left at its
        // caret. A returning keystroke re-queries from the live context, so this
        // can't strand a still-wanted suggestion.
        dropOverlay(why: "left the app")
    }

    func focusTrackerViewportDidChange(_ tracker: FocusTracker) {
        dropOverlay(why: "the window moved or resized")
    }
}

// What dictation is allowed to see of this controller — the protocol keeps the
// capture state machine testable without an AX tree or a window server, and
// keeps `DictationController` from growing casual reach into the completion
// pipeline. `insertDictated`, `clearActiveCompletion`, `noteCaret`,
// `typingContext`, `focusGeneration`, `lastEvent` and `onDictationActivity`
// already satisfy their requirements above.
extension SuggestionController: DictationHost {
    var fallbackCaretRect: CGRect? { lastCaretRect }
    var fallbackHostStyle: HostTextStyle { lastHostStyle }

    func hasFocusedTextField() -> Bool { currentTextElement() != nil }

    /// Precise marked-text only — `AXText.hasMarkedText`, not `isComposing` —
    /// so a CJK input source merely being SELECTED (the coarse fallback's
    /// answer in Electron/Chromium) doesn't ban dictation wholesale where it
    /// demonstrably works today.
    func isComposingInFocusedField() -> Bool {
        guard let element = focusTracker.focusedTextElement
            ?? AXText.systemFocusedTextElement() else { return false }
        return AXText.hasMarkedText(element)
    }

    func cancelPendingFix() { correctionController.reset() }

    func dictationAnchor() -> DictationAnchor? {
        guard let ctx = dictationFieldContext() else { return nil }
        return DictationAnchor(caretRect: ctx.caretRect, host: ctx.host,
                               textBeforeCaret: ctx.textBeforeCaret)
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
            AXText.context(for: element, maxChars: Settings.maxContextChars, allowEmpty: true)
        }
        if let element = focusTracker.focusedTextElement, let ctx = read(element) { return ctx }
        guard let fresh = AXText.systemFocusedTextElement() else { return nil }
        return read(fresh)
    }

    func stopProgressIndicator() { indicator.stop() }

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

    func tidyDictation(_ text: String, before context: String) async -> String? {
        guard engine.supportsCorrection else { return nil }
        // A fix model that still has to be fetched cannot help THIS sentence:
        // the tidy-up budget is three seconds and the download is gigabytes.
        // Waiting would only stall every dictation behind a progress bar it
        // can't outlast, so the words go in as heard and the fetch starts in
        // the background for the next one.
        guard engine.isCorrectionReady else {
            engine.prewarmCorrection()
            DictationController.note("tidy-up skipped — fetching the fix model for next time")
            return nil
        }
        let request = makeRequest(text: context)
        // `redactLog` is the whole point of the parameter: what is being fixed
        // here was SPOKEN, and the divergence guard's rejection path logs the
        // pair verbatim otherwise — into a buffer whose export dialog only
        // warns about text the user typed.
        let fixed = try? await engine.correct(selection: text, request: request, redactLog: true)
        guard let fixed, !fixed.isEmpty, fixed != text else { return nil }
        return fixed
    }
}
