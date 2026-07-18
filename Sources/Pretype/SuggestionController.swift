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
        hasActiveSuggestion: { [weak self] in self?.active != nil },
        isQueryRunning: { [weak self] in self?.refreshTask != nil }
    )
    /// The text-fixing flows (⌥⇥ fix-selection / last word, inline spell-fix),
    /// kept separate from the completion pipeline below.
    let correctionController = CorrectionController()

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

    private var keyRefreshScheduled = false
    private var lastAcceptedChunk: String?
    /// The most recent `textBeforeCaret` seen by `textDidChange`. Lets a streamed
    /// partial tell — without a fresh AX read — whether the user has typed since
    /// the completion stream began, so it knows when its cached context is stale.
    private var latestTextBeforeCaret: String?

    /// Caret rect of the latest context — shared by the completion overlay, the
    /// indicator and the correction previews.
    var lastCaretRect: CGRect?

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
        focusTracker.delegate = self
        keyTap.handler = { [weak self] event in
            self?.handleKeyDown(event) ?? false
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
    func setConfidenceGate(_ enabled: Bool) { engineCoordinator.setConfidenceGate(enabled) }
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

    /// Apple Intelligence prompt recipe. The FM engine reads it live per
    /// request, so just persist and clear the current suggestion.
    func setFMPromptVariant(_ variant: FMPromptVariant) {
        Settings.fmPromptVariant = variant
        dismiss()
    }

    /// Close the pending journal record with its outcome. Idempotent — the
    /// first resolution wins; later calls (e.g. the `dismiss()` that follows an
    /// Escape) find nothing pending.
    private func resolveJournal(_ outcome: SuggestionJournal.Outcome, typed: String? = nil) {
        guard let pending = pendingJournal else { return }
        pendingJournal = nil
        guard Settings.suggestionJournalEnabled else { return }
        // ONE snapshot for both consumers: observe's delta cursor must see
        // exactly the ctx window the journal stores, or the next launch's
        // replay re-splits the stream differently and double-learns.
        let ctx = String(pending.ctx.suffix(1000))
        // Live n-gram learning from the same ctx snapshots the startup build
        // replays — so today's typing predicts today, not from the next launch.
        if Settings.personalizationLevel != .off {
            PersonalNgram.shared.observe(ctx: ctx, app: typingContext.bundleID)
        }
        SuggestionJournal.shared.append(SuggestionJournal.Entry(
            ts: SuggestionJournal.timestamp(),
            app: typingContext.bundleID,
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
            shownForMs: Int(Date().timeIntervalSince(pending.shownAt) * 1000),
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
                DebugLog.shared.log(
                    "OCR",
                    summary.map { "captured \($0.count) chars (\(appName))" } ?? "nothing usable captured (\(appName))",
                    detail: summary
                )
            }
        }
    }

    // MARK: - Text changes

    private func textDidChange() {
        guard Settings.enabled else { return }
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
        latestTextBeforeCaret = text
        lastCaretRect = ctx.caretRect
        refreshScreenContextIfNeeded(typed: text)
        refreshPersonalExamplesIfNeeded(typed: text)

        // A reviving last-word fix preview, or an inline spell-fix on the word at
        // the caret, preempts a completion — fixing what's written matters more
        // than predicting ahead.
        if correctionController.handleCaret(ctx) { return }

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
    /// keystroke, and a keystroke cancels this task. `nil` ⇒ read AX now.
    @discardableResult
    private func apply(_ result: String?, requestText: String,
                       cachedContext: TextContext? = nil, countShown: Bool = true,
                       instant: Bool = false) -> Bool {
        indicator.stop()
        guard Settings.enabled else { return false }
        var suggestion = result.map(sanitize) ?? ""
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
        let ctx: TextContext
        // Trust the cached context only while the typed text is unchanged since
        // the stream began (the cheap string compare avoids an AX read). If the
        // user typed mid-stream, `latestTextBeforeCaret` has moved on — fall back
        // to a fresh read so the partial re-anchors and shrinks correctly.
        if let cachedContext, cachedContext.textBeforeCaret == latestTextBeforeCaret {
            ctx = cachedContext
        } else if let element = currentTextElement(),
                  let fresh = AXText.context(for: element, maxChars: Settings.maxContextChars) {
            ctx = fresh
        } else {
            lastEvent = "lost text element"
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
            Stats.recordShown()
            // A fresh suggestion opens a journal record; an unresolved one at
            // this point was replaced before the user reacted to it.
            resolveJournal(.superseded)
            pendingJournal = PendingJournal(
                ctx: current, after: ctx.textAfterCaret, suggestion: suggestion,
                hadScreen: screenSummary != nil
                    && AppPolicy.allowsScreenContext(typingContext.bundleID),
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
        lastEvent = "suggesting \"\(text.prefix(40))\""
        if text != lastLoggedSuggestion {
            lastLoggedSuggestion = text
            DebugLog.shared.log("SHOW", "\"\(text)\"")
        }
        window.show(mode: .suggestion(text), at: rect, fontSize: ctx.fontSize)
        if !Settings.onboardingCompleted {
            onboardingWindow?.updateStatusSuggestionActive(true)
        }
    }

    private func sanitize(_ raw: String) -> String {
        var out = raw.replacingOccurrences(of: "\t", with: " ")
        if let newline = out.firstIndex(where: { $0.isNewline }) {
            out = String(out[..<newline])
        }
        while out.contains("  ") {
            out = out.replacingOccurrences(of: "  ", with: " ")
        }
        if out.count > 120 {
            out = String(out.prefix(120))
        }
        while out.hasSuffix(" ") {
            out.removeLast()
        }
        return out
    }

    // MARK: - Key handling

    private func handleKeyDown(_ event: CGEvent) -> Bool {
        guard Settings.enabled else { return false }
        if event.getIntegerValueField(.eventSourceUserData) == TextInjector.magicTag { return false }
        // Our own Settings/Debug field is focused — pass every key through
        // untouched (never accept a stale background suggestion into it).
        if isOwnUIFrontmost { return false }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // Check for Cmd + Z (Undo accepted chunk)
        if keyCode == KeyCode.z, flags.contains(.maskCommand), let accepted = lastAcceptedChunk {
            lastAcceptedChunk = nil
            let count = accepted.count
            TextInjector.deleteBackward(count)
            lastEvent = "undid acceptance of \"\(accepted)\""
            DebugLog.shared.log("UNDO", "\"\(accepted)\"")
            indicator.flashTransient(.hint("Undone"))
            // The accept was already journaled; an undo is the strongest reject
            // signal there is, so it gets its own event.
            if Settings.suggestionJournalEnabled {
                SuggestionJournal.shared.append(SuggestionJournal.Entry(
                    ts: SuggestionJournal.timestamp(),
                    app: typingContext.bundleID,
                    engine: engine.name,
                    ctx: String((latestTextBeforeCaret ?? "").suffix(1000)),
                    after: "",
                    suggestion: accepted,
                    outcome: .undone,
                    acceptedChars: -count,
                    typed: nil,
                    shownForMs: 0,
                    screen: false))
            }
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

        if let current = active, window.isVisible {
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
        guard var current = active else { return }
        // Command/control chords don't type text; leave them to the AX refresh.
        guard !flags.contains(.maskCommand), !flags.contains(.maskControl) else { return }
        let typed = Self.typedCharacters(event)
        guard !typed.isEmpty else { return }   // dead keys, bare modifiers
        guard let remaining = Self.narrowedSuggestion(current.text, typedCharacters: typed) else {
            // Divergent or control input — the ghost no longer matches the field.
            let isControl = typed.unicodeScalars.contains {
                $0.value < 0x20 || $0.value == 0x7F || (0xF700...0xF8FF).contains($0.value)
            }
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
        // Advance the stale-cache marker too, so a streamed partial arriving
        // before the AX refresh re-reads instead of trusting pre-keystroke text.
        latestTextBeforeCaret? += typed
        window.advance(past: typed, remaining: remaining)
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

    private func accept(chunk: String) {
        guard var current = active, !chunk.isEmpty else { return }
        lastAcceptedChunk = chunk
        TextInjector.insert(chunk)
        // Count the suggestion once even when accepted word-by-word (chars still
        // accrue per chunk), so the menu's "accepted of shown" can't exceed 100%.
        Stats.recordAccepted(chunk: chunk, countSuggestion: !current.accepted)
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
            // word stays smooth; the keystroke refresh then re-anchors it on the
            // real caret.
            window.advance(past: chunk, remaining: current.text)
        }
        if !Settings.onboardingCompleted {
            Settings.onboardingCompleted = true
            onboardingWindow?.dismiss()
        }
        // Re-read context once the synthetic keystrokes have landed.
        scheduleKeystrokeRefresh(after: 0.09)
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
        lastFocusedElement = tracker.focusedTextElement
        lastCaretRect = nil
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
        // Left the app we were typing in — drop any ghost/indicator left at its
        // caret. A returning keystroke re-queries from the live context, so this
        // can't strand a still-wanted suggestion.
        guard active != nil || refreshTask != nil || window.isVisible else { return }
        lastEvent = "dismissed — left the app"
        dismiss()
    }
}
