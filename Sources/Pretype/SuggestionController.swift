import AppKit

/// Orchestrates the pipeline: focused-element text → completion engine →
/// ghost overlay → Tab acceptance → text injection. Also handles
/// fix-selection (⌥Tab) and feeds the menu with diagnostics and context.
@MainActor
final class SuggestionController {
    let focusTracker: FocusTracker
    let keyTap = KeyTap()
    /// The pipeline's reach outside the process: AX, keys, overlay, engine, clock.
    let env: Environment
    var window: any SuggestionOverlay { env.window }
    /// Engine lifecycle + the settings that reshape it; the menu and settings
    /// window drive it directly. A rebuild calls back into `dismiss()` to drop
    /// the stale suggestion. Built by `start()`, not `init`, so a controller a
    /// test drives with a fake engine never builds — or loads — a real one.
    lazy var engineCoordinator: EngineCoordinator = {
        let coordinator = EngineCoordinator()
        // A model/style/gate rebuild drops the suggestion that belonged to the
        // old engine.
        coordinator.onRebuild = { [weak self] in self?.dismiss() }
        return coordinator
    }()
    /// The active completion engine, owned by `engineCoordinator`. Read-only here;
    /// model/style/gate changes flow through the coordinator's methods.
    var engine: CompletionEngine { env.engine ?? engineCoordinator.engine }
    /// The completion query or composed reply in flight (`QuerySlot`).
    var queries = QuerySlot() { didSet { updateScrollMonitoring(canStop: false) } }

    /// A completion query is scheduled or streaming (the indicator's dots).
    var isCompleting: Bool { queries.current != nil }

    /// Engine-state indicator at the caret (download progress, thinking dots,
    /// transient notices). Shares the overlay window with the suggestion.
    lazy var indicator = CaretIndicator(host: self, window: window)
    /// The text-fixing flows (⌥⇥ fix-selection / last word, inline spell-fix),
    /// kept separate from the completion pipeline below.
    lazy var correctionController = CorrectionController(host: self, env: env, indicator: indicator)
    /// The window OCR, the clipboard and the personal examples a prompt carries.
    lazy var promptContext = PromptContext(host: self, env: env)
    /// The reply chord's flow: the conversation on screen in, a reply ghost out.
    lazy var replyComposer = ReplyComposer(host: self, env: env, indicator: indicator, prompts: promptContext)

    /// Hold-to-talk dictation. Owns the microphone, the caret pill while it
    /// listens, and nothing else — the transcript comes back through
    /// `insertDictated`, which is the same injection path an accept takes.
    let dictationController: DictationController

    /// The ghost, the text-before-caret cache, the settle window, the decline
    /// and the ⌘Z record, with the rules that move them.
    var field = FieldState() {
        // A ghost is one of the times the scroll monitor runs.
        didSet { if field.ghost != nil || oldValue.ghost != nil { updateScrollMonitoring(canStop: false) } }
    }
    var hasActiveSuggestion: Bool { field.ghost != nil }

    /// The record of the suggestion on screen, booked when it resolves.
    var offer = OfferRecord()

    /// Double-tap-a-modifier state — the easy-to-reach twin of the reply chord.
    var replyTap = ModifierDoubleTap()

    /// When the field is re-read after an edit (`RereadSchedule`).
    var reread = RereadSchedule()

    /// The caret of the latest context, and the field's style there
    /// (`FieldState.caret`, `.style`).
    var lastCaretRect: CGRect? { field.caret }
    var lastHostStyle: HostTextStyle { field.style }

    /// Bumped on every real focus change; in-flight captures and corrections
    /// that finish after a change are discarded (a result for the previous app's
    /// context must never attach to the new one).
    var focusGeneration = 0
    var lastLoggedSuggestion: String?
    /// The text before the caret right after Words typed a word and its
    /// space — the next key may take that space back (`takeProvisionalSpace`).
    var provisionalSpace: String?
    /// An agent session's names (`AgentPrompt.names`), read for `element`
    /// `at` its message's first word (`sessionNames(in:typed:)`).
    var sessionNamesRead: (element: AXUIElement, at: Date, names: [String])?

    // Surfaced in the menu.
    /// What the focus tracker reported, plus the site of a field only the
    /// system-wide fallback found (`currentTextElement`).
    var typingContext: TypingContext {
        var context = focusTracker.reportedContext
        if context.site == nil { context.site = field.untracked?.site }
        return context
    }
    /// The last request sent — formatted only when Diagnostics asks, not per query.
    var lastPromptRequest: CompletionRequest?
    var lastPromptDescription: String? { lastPromptRequest?.completionPrompt(maxChars: 1000) }
    var lastResultDescription: String?
    /// One line of what just happened — the Diagnostics menu's "Last:".
    var lastEvent = "waiting for typing"
    var onboardingWindow: OnboardingWindow?

    init(env: Environment? = nil, focusTracker tracker: FocusTracker = FocusTracker(),
         dictation: DictationController? = nil) {
        focusTracker = tracker
        dictationController = dictation ?? DictationController()
        self.env = env ?? .live(tracker)
        window.presentation = Settings.suggestionPresentation
        window.onVisibilityChange = { [weak self] in self?.updateScrollMonitoring() }
        dictationController.owner = self
        focusTracker.onFocusChange = { [weak self] in self?.focusDidChange() }
        focusTracker.onTextChange = { [weak self] valueChanged in self?.focusedTextDidChange(valueChanged: valueChanged) }
        focusTracker.onResignActiveApp = { [weak self] in self?.focusedAppDidResign() }
        focusTracker.onViewportChange = { [weak self] in self?.dropOverlay(why: "the window moved or resized") }
        keyTap.handler = { [weak self] event in
            self?.handleKeyDown(event) ?? false
        }
        keyTap.scrollHandler = { [weak self] isMomentum in self?.scrolled(momentum: isMomentum) }
        keyTap.mouseDownHandler = { [weak self] in self?.pointerPressed() }
        keyTap.reenabledHandler = { [weak self] in
            // macOS turned the tap off (a callback ran past its timeout, or
            // input was held off) and keystrokes went by unseen.
            guard let self else { return }
            self.field.undoable = nil
            self.dropCompletion(afterUnseenCaretMove: "the key tap was paused",
                                overlay: !self.dictationController.isBusy)
            DebugLog.shared.log("TAP", "re-enabled after macOS disabled it")
        }
        keyTap.flagsHandler = { [weak self] event in
            // Both gestures read every modifier edge. They cannot collide: a
            // reply only ever fires on a pair of taps, a dictation capture only
            // on a hold past `ModifierHold.threshold`.
            self?.dictationController.modifierChanged(event)
            self?.updateScrollMonitoring()
            guard let self, Settings.repliesEnabled, self.replyTap.modifierChanged(
                keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                flags: event.flags, gesture: Settings.replyGesture, now: self.env.now()) else { return }
            // Off the tap callback before any AX read — same rule as the chord.
            self.env.hop { [weak self] in self?.replyComposer.compose() }
        }
    }

    func start() {
        // The model starts loading with the app, as it did from `init`.
        _ = engineCoordinator
        focusTracker.start()
        keyTap.keepUp()
        if Settings.personalizationLevel != .off {
            env.personalNgram.prepareIfNeeded()
        }
        if !Settings.onboardingCompleted {
            onboardingWindow = OnboardingWindow(controller: self)
            onboardingWindow?.show()
        }
    }

    /// The master switch — the menu's Pause and the Settings toggle both land
    /// here. Pause means the microphone too: a capture that survived the
    /// toggle would keep listening — and then type — under an app the user
    /// just switched off.
    func setEnabled(_ on: Bool) {
        Settings.enabled = on
        guard !on else { return focusTracker.wakeAccessibility() }
        dictationController.invalidate()
        dismiss()
    }

    /// A feature switch moved (Settings → General). What is on screen goes —
    /// a ghost or a pill of a feature just turned off must not stay one key
    /// from typing. When suggestions stopped or started asking the completion
    /// model, it is let go — fixes and replies reload theirs on use — or
    /// loading starts.
    func featuresChanged(wasUsingModel: Bool) {
        dismiss()
        guard wasUsingModel != Settings.completionsUseModel else { return }
        if Settings.completionsUseModel { engine.prewarmIfNeeded() } else { engine.releaseModelNow() }
    }

    func clearOnboarding() {
        onboardingWindow = nil
    }

    func shutdown() {
        dictationController.invalidate()
        engine.shutdown()
    }

    /// Inline ghost text vs the classic floating panel. Dismisses any live
    /// suggestion so the next one renders in the chosen mode.
    func setSuggestionPresentation(_ presentation: SuggestionPresentation) {
        Settings.suggestionPresentation = presentation
        window.presentation = presentation
        dismiss()
    }

    /// Close the offer record with its outcome and book it (`OfferRecord.resolve`).
    /// The counters are booked HERE, not where the ghost was drawn: what makes
    /// a ghost an offer the user could take is how long it survived and what
    /// ended it, and neither is known until now. See `Stats.isChance`.
    func resolveJournal(_ outcome: SuggestionJournal.Outcome) {
        guard var entry = offer.resolve(outcome, ghost: field.ghost?.text, at: env.now()) else { return }
        // ONE snapshot for both of the journal's consumers: the n-gram's delta
        // cursor must see exactly the ctx window the journal stores, or the
        // next launch's replay re-splits the stream differently and double-learns.
        entry.ctx = String(entry.ctx.suffix(1000))
        entry.ts = SuggestionJournal.timestamp()
        // Read at resolve, not show: the engine publishes the value only
        // after the generation completes, which is after the first streamed
        // partial is shown. By resolve time it belongs to the shown
        // suggestion — except `superseded`, where a newer generation has
        // already overwritten it (see Entry doc: calibration filters those).
        entry.firstWordLogProb = entry.model == nil ? nil : engine.lastFirstWordLogProb
        env.book(.offer(entry))
    }

    /// Resolve the shown suggestion with `outcome` and take it off screen.
    func retire(_ outcome: SuggestionJournal.Outcome) {
        resolveJournal(outcome)
        field.ghost = nil
        queries.ghostRetired()
        window.hide()
    }

    func dismiss() {
        clearActiveCompletion()
        field.undoable = nil
        correctionController.reset()
        indicator.stop()
        window.hide()
        if !Settings.onboardingCompleted {
            onboardingWindow?.updateStatusSuggestionActive(false)
        }
    }

    /// Scrolls matter while a suggestion is up or on its way (the line slides
    /// out from under it — and a query still running would land its ghost at
    /// the pre-scroll caret), and to dictation while it captures or a hold is
    /// arming (⌃-scroll zoom must not open the microphone): the only times the
    /// system-wide scroll monitor runs. `canStop: false` from the per-keystroke
    /// query/ghost bookkeeping: those start it, and the next modifier, overlay
    /// or capture change — or the first scroll nobody needed — stops it, so
    /// typing doesn't add and remove a global monitor every key.
    func updateScrollMonitoring(canStop: Bool = true) {
        let needed = window.isVisible || field.ghost != nil || queries.current != nil
            || dictationController.isBusy || dictationController.isHoldArmed
        if needed || canStop { keyTap.wantsScroll = needed }
    }

    /// A scroll anywhere (`KeyTap.scrollHandler`). Momentum frames don't
    /// reach dictation at all — a flick keeps coasting for seconds after the
    /// finger left, and a hold started (or a transcript being finalized)
    /// during that tail is deliberate, not a scroll gesture interrupting it.
    func scrolled(momentum isMomentum: Bool) {
        let dictating = dictationController.isBusy
        if !isMomentum { dictationController.pointerInterrupted(isScroll: true) }
        // While dictation is busy the overlay is its to keep: the live pill
        // riding out a momentum tail, or "writing it down…" over a take the
        // scroll left alone — `dropOverlay` would erase either one, and
        // dictation tears down its own overlay on discard anyway.
        // (`pointerPressed` skips it for the same reason.)
        if !dictating { viewScrolled() }
        // Not from inside the monitor's own handler.
        env.hop { [weak self] in self?.updateScrollMonitoring() }
    }

    /// A mouse press anywhere (`KeyTap.mouseDownHandler`). Dictation keeps the
    /// overlay while busy, as for a scroll — read before `pointerInterrupted()`,
    /// which may end the capture.
    func pointerPressed() {
        let dictating = dictationController.isBusy
        dictationController.pointerInterrupted()
        dropCompletion(afterUnseenCaretMove: "mouse click", overlay: !dictating)
    }

    /// The overlay is placed in screen coordinates, and nothing re-places it
    /// when the host view moves under it: AX posts no scroll notification, and
    /// the caret rect it would report after one can sit outside the visible clip
    /// (a scrolled-away caret in an NSTextView is still inside the text view's
    /// own frame). So a viewport change drops the overlay instead of chasing it
    /// — the next keystroke re-queries from the live caret. Cheap enough to sit
    /// on the scroll-event path: three flags before anything else runs.
    func dropOverlay(why: String) {
        guard field.ghost != nil || queries.current != nil || window.isVisible else { return }
        lastEvent = "dismissed — \(why)"
        // Every caller of this means the caret moved out from under the
        // overlay (scroll, window move, app switch) — a protected notice is as
        // stranded as a ghost would be.
        window.clearNoticeProtection()
        dismiss()
    }

    /// A scroll strands what is drawn, not what is being written: a reply or
    /// fix in flight (seconds of OCR and generation — scrolling the chat to
    /// read it meanwhile is natural) keeps running and lands on a fresh read of
    /// the caret. Forgetting the cache and the caret is what forces that read,
    /// and keeps the thinking dots from painting at the pre-scroll spot.
    func viewScrolled() {
        guard queries.isReply || correctionController.inFlight else {
            return dropOverlay(why: "the view scrolled")
        }
        field.forgetCaret()
        window.clearNoticeProtection()
        window.hide()
    }

    /// A click, or keystrokes the tap never saw, can move the caret where no
    /// AX notification says so (Electron): a ghost would sit at the old caret
    /// with ⇥ armed to type it there, and a completion query anchored on the
    /// old text is moot. Drop both, and the cache; the next keystroke re-reads.
    /// A reply or fix in flight is left alone — both re-check the live field
    /// before they show or apply anything, and a click while waiting for one
    /// (into the very chat box being answered) must not silently lose it.
    func dropCompletion(afterUnseenCaretMove why: String, overlay: Bool) {
        field.cache = nil
        guard overlay, field.ghost != nil || (queries.current != nil && !queries.isReply) else { return }
        lastEvent = "dismissed — \(why)"
        clearActiveCompletion()
        if window.showsSuggestion { window.hide() }
    }

    /// Drop any live completion without touching the overlay — used when a
    /// correction preempts a suggestion.
    func clearActiveCompletion() {
        resolveJournal(.abandoned)
        field.ghost = nil
        queries.cancel()
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
                + (promptContext.screenSummary.map { " (incl. \($0.count) screen)" } ?? ""),
            "Last: \(lastEvent)",
        ]
    }

    /// The field the pipeline reads and types into — nil while keyboard focus
    /// sits in another process. Launchers (Spotlight, Raycast, Alfred) take
    /// keys through a non-activating panel: the menu bar keeps the app we
    /// track and no activation or focus change fires, so without this check
    /// the old field's ghost would be re-offered on every launcher keystroke,
    /// and ⇥ would type it into the launcher.
    func currentTextElement() -> AXUIElement? {
        guard !keyboardFocusIsElsewhere else { return nil }
        if let element = env.trackedElement() { return element }
        return env.systemFocusedElement(field.untracked?.element).map {
            field.foundUntracked($0, trackerSite: focusTracker.reportedContext.site, pageHost: env.pageHost)
        }
    }

    /// One system-wide AX read: the process that holds keyboard focus is
    /// neither the tracked app nor Pretype itself (our panels never take focus;
    /// our own windows are `isOwnUIFrontmost`'s business).
    var keyboardFocusIsElsewhere: Bool { focusedPanelOwner != nil }

    /// That process — the owner of a launcher-style panel — else nil. Kept, so
    /// dictation judges the panel by its app without a second round trip.
    var focusedPanelOwner: pid_t? { env.focusedPanelOwner() }

    /// True while one of Pretype's own windows (Settings, Debug console) is
    /// frontmost. The session-wide key tap still fires for keystrokes into our
    /// own fields, but `FocusTracker.attach` skips our own pid *without*
    /// detaching, so `focusedTextElement` stays pinned to the last external
    /// field. Left ungated, typing in Settings would generate a ghost for that
    /// stale background field — and Tab would inject its text into our own
    /// field. Both pipeline entry points go inert while this is true.
    var isOwnUIFrontmost: Bool { env.ownUIFrontmost() }

    /// Why the pipeline can start nothing now — paused, our own window
    /// frontmost, a hands-free capture listening (it owns the overlay) — or nil.
    var busyReason: String? {
        if !Settings.enabled { return "Pretype is paused" }
        if isOwnUIFrontmost { return "our own window is frontmost" }
        if dictationController.isBusy { return "dictation is listening" }
        return nil
    }

    /// Whether completions are wanted in the app in front at all — worth a
    /// model reload, a capture or a prefill: not on battery with "pause on
    /// battery" on, not where Pretype stays out, not where its suggestions
    /// go unused (`Stats.isUnproductive`).
    var completionsWelcome: Bool {
        !env.pausedForBattery() && AppPolicy.allowsCompletions(typingContext)
            && !env.isUnproductive(typingContext.bundleID)
    }

    /// The app being typed in, whose window the screen context reads.
    var observedPID: pid_t { focusTracker.observedPID }

    /// The text before the caret as last known (`FieldState.cache`).
    var knownTextBeforeCaret: String? { field.cache }

    /// Surfaced in the Context submenu.
    var screenContextStatus: String { promptContext.screenStatus }

    /// Adopt a caret reading taken by a side flow, so the indicator and any
    /// later overlay place against the same field that flow measured.
    func noteCaret(rect: CGRect, host: HostTextStyle) { field.noteCaret(rect, style: host) }

    /// A side flow measured where its text is (a selection, the word at the caret).
    func noteCaret(_ rect: CGRect) { field.noteCaret(rect) }

    /// Adopt `rect` only when the caret was forgotten (`viewScrolled`).
    func recoverCaret(_ rect: CGRect?) { field.recoverCaret(rect) }

    func report(_ event: String) { lastEvent = event }

    // MARK: - Text changes

    func textDidChange() {
        let pass = RequestGate.Pass(
            enabled: Settings.enabled, watchesTyping: Settings.watchesTyping, dictating: dictationController.isBusy,
            ownWindowFrontmost: isOwnUIFrontmost, appAllowed: AppPolicy.allowsCompletions(typingContext),
            hasGhost: field.ghost != nil)
        let element: AXUIElement
        switch RequestGate.entry(pass, findField: currentTextElement,
                                 siteBlocked: { field.untracked?.site != nil && AppPolicy.isBlacklisted(typingContext) }) {
        case .idle:
            return
        case .dismiss(let why):
            if let why { lastEvent = why }
            return dismiss()
        case .read(let found):
            element = found
        }

        // A selection just typed over (a selection fix) may still read as
        // selected inside the settle window — and would put its "fix" pill
        // back. Look again once the host has caught up.
        if field.isSettling(at: env.now()), env.selection(element) != nil {
            scheduleKeystrokeRefresh(after: 0.09)
            return
        }
        // A selection switches into fix-selection mode (⌥⇥); the correction
        // controller owns the overlay while it's up. Not in a terminal, where
        // a selection is screen output and the chord is off.
        if Settings.fixesEnabled, !AppPolicy.isTerminal(typingContext.bundleID),
           correctionController.handleSelection(element) { return }

        // Web and Electron apps can REPLACE the focused node with no focus
        // notification (see `dictationFieldContext`) — typing an accept into
        // one does it. Every read of the old handle then fails, and
        // completions, ⌥⇥ and ⌘Z stayed off until the user left the field.
        // The liveness probe is one more AX round trip, so not in a terminal,
        // where a shell prompt reads nil on every key.
        let probe = element == env.trackedElement() && !AppPolicy.isTerminal(typingContext.bundleID)
            ? { [env] in env.relatchIfDead(element) } : nil
        let ctx: TextContext
        switch field.admit(env.context(of: element), of: element, probe: probe, clock: env.now) {
        case .taken(let read):
            ctx = read
        case .retry:
            return scheduleKeystrokeRefresh(after: 0.09)
        case .lost:
            if field.ghost != nil { lastEvent = "lost text element" }
            dismiss()
            return
        }
        let text = ctx.textBeforeCaret
        reread.fieldRead()
        field.noteCaret(ctx.caretRect, style: ctx.host)
        promptContext.refreshScreenIfNeeded(typed: text)
        promptContext.refreshExamplesIfNeeded(typed: text)

        // A reviving last-word fix preview, or an inline spell-fix on the word at
        // the caret, preempts a completion — fixing what's written matters more
        // than predicting ahead. Not in a terminal: the key handler leaves ⇥/⎋
        // to the terminal there, so a pill could be neither applied nor dismissed.
        if !AppPolicy.isTerminal(typingContext.bundleID), correctionController.handleCaret(ctx) { return }

        // Fixes only, or an agent's prompt with suggestions kept out of it:
        // everything below is the suggestion's.
        guard Settings.suggestionsEnabled,
              Settings.agentPromptSuggestions || !env.isTerminalField(element) else { return }

        // The correction flows carry this same guard.
        if RequestGate.caretSplitsWord(before: ctx.textAfterCaret) {
            if field.ghost != nil { lastEvent = "caret splits a word — no suggestion" }
            // Not dismiss(): that resets the correction controller, and a
            // last-word ⌥⇥ fix may legitimately be computing at a caret that
            // sits before a DIGIT (its own guard only excludes letters).
            clearActiveCompletion()
            indicator.stop()
            window.hide()
            return
        }

        switch field.reconcileGhost(with: text) {
        case .unchanged?, .narrowed?:
            // A caret/selection event with no text change repositions it; the
            // user typing (or us injecting) its head shrinks it instead of
            // re-querying the engine.
            if let ghost = field.ghost {
                showSuggestion(ghost.text, ctx)
                return
            }
        case .retired(let outcome)?:
            retire(outcome)
        case nil:
            break
        }

        // After the correction pass above: the app's record counts
        // completions, so a typo fix or a shortcode still works where
        // completions don't. Reversible from the status menu. Not Words: a
        // word ghost costs a glance, not the model's interruption, and its
        // offers stay out of that record.
        let unproductive = Settings.activeSuggestionMode == .sentences && env.isUnproductive(typingContext.bundleID)
        if let why = RequestGate.quietReason(unproductive: unproductive,
                                             onBattery: env.pausedForBattery(), declined: field.isDeclined) {
            lastEvent = why
            return
        }
        if queries.isRunning(before: text, after: ctx.textAfterCaret) { return }

        // An agent's session names what is typed to it next — a file, a
        // symbol it just printed: the rest of it, no model asked.
        if env.isTerminalField(element),
           let rest = AgentPrompt.completion(of: text, names: sessionNames(in: element, typed: text)) {
            apply(rest, requestText: text, cachedContext: ctx, instant: true, wordFrom: "names")
            return
        }

        // Words: the rest of the word or nothing — no model, nothing to wait for.
        if Settings.activeSuggestionMode == .words {
            if let word = WordCompletion.suggestion(text: text, after: ctx.textAfterCaret, ngram: env.personalNgram) {
                apply(word, requestText: text, cachedContext: ctx, instant: true, wordFrom: "words")
            }
            return
        }

        // Personal n-gram fast-path: a confident hit from the user's own
        // recurring phrases shows at ~0 ms, before the debounce even starts;
        // the LLM stream below then supersedes it through the same apply path.
        if Settings.personalizationLevel != .off {
            env.personalNgram.prepareIfNeeded()   // switched on since launch: builds it now
            if let instant = RequestGate.instantSuggestion(text: text, after: ctx.textAfterCaret,
                                                           ngram: env.personalNgram) {
                apply(instant, requestText: text, cachedContext: ctx, instant: true)
            }
        }

        scheduleRefresh(for: text, after: ctx.textAfterCaret, context: ctx)
    }

    func scheduleRefresh(for text: String, after: String, context: TextContext) {
        // Freed, not just cancelled: the early returns below would otherwise
        // leave `isCompleting` reading true over a task that will never finish.
        queries.cancel()
        indicator.stop()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Nothing left to complete (e.g. the user cleared the field):
            // `indicator.stop()` only kills the timer, so any ghost or thinking
            // indicator already drawn would otherwise stay floating at the old
            // caret. Order it out explicitly.
            window.hide()
            return
        }

        // The engine's own load retry lives in `completions`, which the return
        // below never reaches — so typing alone would never retry a failed
        // load. The prewarm keeps the same cooldown (and is a no-op with no
        // load to retry, e.g. Apple Intelligence); once it restarts the load
        // this keystroke proceeds like any other while the model comes up.
        if case .failed = engine.state { engine.prewarmIfNeeded() }
        if case .failed(let why) = engine.state {
            lastEvent = "engine failed: \(why)"
            indicator.flashTransient(.error(String(localized: "engine not working")))
            return
        }

        let request = promptContext.makeRequest(text: text, after: after)
        let engine = engine
        let debounce = env.debounce, clock = env.now
        indicator.start()

        queries.start(.completion(before: text, after: after)) { queryID in Task { [weak self] in
            await debounce()
            if Task.isCancelled { return }
            let fullPrompt = Self.loggablePrompt(request)
            DebugLog.shared.log(
                "PROMPT",
                "\(fullPrompt.count) chars"
                    + (request.screenSummary.map { " (incl. \($0.count) screen)" } ?? "")
                    + (request.clipboardContext.map { " (incl. \($0.count) clip)" } ?? "")
                    + " — \(request.appName ?? "?")",
                detail: fullPrompt
            )
            let started = clock()
            var shown = false
            var measured = false
            do {
                // Stream the completion: render each gated partial as it decodes,
                // so the first word appears after ~one token instead of after the
                // whole generation — the dominant wait on slow machines. Latency
                // is recorded at the first token (what the user actually feels).
                // The task inherits the main actor, so everything between two
                // awaits runs uninterrupted: a cancellation check right after
                // the await is current for the code that follows it.
                for try await partial in engine.completions(for: request) {
                    guard let self, !Task.isCancelled else { return }
                    if !measured {
                        self.env.book(.latency(clock().timeIntervalSince(started)))
                        measured = true
                    }
                    if self.apply(partial, requestText: request.textBeforeCaret,
                                  cachedContext: context, countShown: !shown) {
                        shown = true
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.queries.finish(queryID)
                self.lastEvent = "engine error: \(error.localizedDescription)"
                DebugLog.shared.log("ERROR", error.localizedDescription)
                self.indicator.stop()
                self.indicator.flashTransient(.error(String(localized: "engine error")))
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.queries.finish(queryID)
            self.lastPromptRequest = request
            if shown {
                self.lastResultDescription = self.field.ghost?.text
            } else if self.field.ghost?.isInstant == true {
                // The LLM abstained but the personal n-gram suggestion is
                // up — a confident personal phrase beats showing nothing.
                self.lastResultDescription = self.field.ghost?.text
            } else {
                // Nothing passed the gates — hide and record the abstain.
                self.lastResultDescription = nil
                self.apply(nil, requestText: request.textBeforeCaret)
            }
        } }
    }

    /// Render an engine result — or a streamed partial — at the caret. Returns
    /// true when a suggestion was actually shown. `countShown` is false for the
    /// follow-up partials of a stream so one completion counts once in Stats.
    ///
    /// `cachedContext` is the `TextContext` captured when the stream began. Streamed
    /// partials pass it so each one doesn't trigger a fresh synchronous AX read on
    /// the main thread (N reads per completion): the caret can't move without a
    /// keystroke, and every keystroke advances or invalidates the cache
    /// synchronously, so the equality gate below catches typing mid-stream.
    /// `nil` ⇒ read AX now.
    ///
    /// `reply`: a composed reply — capped at 400 characters, not 120, reads an
    /// empty field as a real (empty) context, and is never trimmed to the line.
    /// Its leading space is the model's own (`cleanReply`), so landing never
    /// takes it back: "I may" + " be late" is not "maybe".
    @discardableResult
    func apply(_ result: String?, requestText: String,
               cachedContext: TextContext? = nil, countShown: Bool = true,
               instant: Bool = false, reply: Bool = false, wordFrom: String? = nil) -> Bool {
        indicator.stop()
        guard Settings.enabled else { return false }
        let sanitized = result.map { Self.sanitized($0, maxChars: reply ? 400 : 120) } ?? ""
        guard !sanitized.isEmpty else {
            // nil/empty is an abstain — or a mid-stream RETRACT ("" from the
            // engine when its final gate rejected what the partials already
            // showed). Close the journal record and clear the stale suggestion
            // so a hidden one can't still be accepted.
            lastEvent = "engine returned no suggestion"
            retire(.abandoned)
            return false
        }
        // A partial dropped while an edit settles leaves the ghost the accept
        // advanced up meanwhile (`FieldState.anchor`).
        let ctx: TextContext, suggestion: String
        let read = { [self] in currentTextElement().flatMap { env.context(of: $0, allowEmpty: reply) } }
        switch field.anchor(cached: cachedContext, read: read, at: env.now()) {
        case .context(let anchored):
            ctx = anchored
        case .settling:
            lastEvent = "result during injection settle; dropped"
            return false
        case .trailing:
            lastEvent = "field read trails the last keystroke; result dropped"
            return false
        case .unreadable:
            // The reply path lands here whenever the field is empty and this read
            // refuses it — which was every composed reply in a web/Electron chat
            // box: generated, then dropped one line before the ghost.
            lastEvent = "lost text element"
            DebugLog.shared.log("SHOW", "dropped a result — field unreadable at apply time")
            window.hide()
            return false
        }

        let current = ctx.textBeforeCaret
        switch RequestGate.landing(sanitized, askedOn: requestText, current: current,
                                   flush: !instant && !reply && engine.answersFlush,
                                   completesWord: wordFrom != nil) {
        case .show(let landed):
            suggestion = landed
        case .stale(let why):
            lastEvent = why
            window.hide()
            return false
        case .glued:
            lastEvent = "dropped mid-word glue suggestion"
            retire(.abandoned)
            return false
        }

        // Streamed growth of the same suggestion (countShown == false) keeps
        // its record and its "already counted" flag. A stream whose ghost was
        // retired under it (a backspace, a ⌘-chord) re-showing it is a fresh
        // offer too: with no record open it would be shown — and acceptable —
        // with nothing booked against it.
        let opensRecord = countShown || !offer.isOpen
        field.offer(suggestion, before: current, after: ctx.textAfterCaret,
                    fresh: opensRecord, trimToLine: !reply, instant: instant, completesWord: wordFrom != nil)
        if opensRecord {
            // A fresh suggestion opens a journal record; an unresolved one at
            // this point was replaced before the user reacted to it. The offer
            // itself is booked when this record resolves — resolveJournal.
            resolveJournal(.superseded)
            offer.open(SuggestionJournal.Entry(
                ts: "",
                app: typingContext.bundleID,
                // "ngram" for the fast-path, "words" for Words mode, "names"
                // for an agent session's names, else the engine's name — so
                // the journal can compare their acceptance rates, and keeps
                // the model's rows apart from all three.
                engine: !instant ? engine.name : wordFrom ?? "ngram",
                // The engine's OWN resolved model — not Settings.mlxModelID,
                // which diverges from what actually generated (instruct loads
                // the it-sibling; Apple Intelligence has no MLX model at all).
                model: instant ? nil : engine.loadedModelID,
                style: Settings.completionStyle.rawValue,
                personalization: Settings.personalizationLevel.rawValue,
                ctx: current, after: ctx.textAfterCaret, suggestion: suggestion,
                outcome: .abandoned, acceptedChars: 0, shownForMs: 0,
                screen: promptContext.screenSummary != nil
                    && AppPolicy.allowsScreenContext(typingContext)),
                at: env.now())
        } else {
            // Streamed growth of the same suggestion — keep the record current.
            offer.showing(suggestion, at: current)
        }
        return showSuggestion(suggestion, ctx)
    }

    /// Draw `text` at the caret `ctx` read. Whether it could be.
    @discardableResult
    func showSuggestion(_ text: String, _ ctx: TextContext) -> Bool {
        guard let rect = ctx.caretRect else {
            lastEvent = "no caret geometry — cannot place overlay"
            dismiss()
            return false
        }
        field.noteCaret(rect)
        // The inline ghost trims the suggestion to what fits on the line, and
        // what ⇧⇥ accepts has to be exactly what the user was shown — offering
        // an ellipsized tail is offering text sight unseen. Only ever a prefix,
        // so narrowing, accepting and the journal all still line up.
        let shown = window.show(mode: .suggestion(text), at: rect, host: ctx.host,
                                trimToLine: field.ghost?.trimToLine ?? true) ?? text
        if shown != text {
            field.ghost?.text = shown
            offer.showing(shown, at: ctx.textBeforeCaret)
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
        return true
    }

    // MARK: - Reply (`ReplyHost`'s side that moves pipeline state)

    func adoptReplyField(_ context: TextContext, caret: CGRect) {
        noteCaret(rect: caret, host: context.host)
        field.adoptRead(context.textBeforeCaret)
    }

    func startReply(run: (_ id: Int) -> Task<Void, Never>) {
        clearActiveCompletion()
        window.hide()
        indicator.start()
        queries.start(.reply, run: run)
    }

    func endReply(_ id: Int) {
        queries.finish(id)
        indicator.stop()
    }

}
