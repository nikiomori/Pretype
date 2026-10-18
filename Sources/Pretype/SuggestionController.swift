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
    private(set) lazy var engineCoordinator: EngineCoordinator = {
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
    private(set) var queries = QuerySlot() { didSet { updateScrollMonitoring(canStop: false) } }

    /// A completion query is scheduled or streaming (the indicator's dots).
    var isCompleting: Bool { queries.current != nil }

    /// Engine-state indicator at the caret (download progress, thinking dots,
    /// transient notices). Shares the overlay window with the suggestion.
    private(set) lazy var indicator = CaretIndicator(host: self, window: window)
    /// The text-fixing flows (⌥⇥ fix-selection / last word, inline spell-fix),
    /// kept separate from the completion pipeline below.
    private(set) lazy var correctionController = CorrectionController(host: self, env: env, indicator: indicator)
    /// The window OCR, the clipboard and the personal examples a prompt carries.
    private(set) lazy var promptContext = PromptContext(host: self, env: env)
    /// The reply chord's flow: the conversation on screen in, a reply ghost out.
    private(set) lazy var replyComposer = ReplyComposer(host: self, env: env, indicator: indicator, prompts: promptContext)

    /// Hold-to-talk dictation. Owns the microphone, the caret pill while it
    /// listens, and nothing else — the transcript comes back through
    /// `insertDictated`, which is the same injection path an accept takes.
    let dictationController: DictationController

    /// The ghost, the text-before-caret cache, the settle window, the decline
    /// and the ⌘Z record, with the rules that move them.
    private(set) var field = FieldState() {
        // A ghost is one of the times the scroll monitor runs.
        didSet { if field.ghost != nil || oldValue.ghost != nil { updateScrollMonitoring(canStop: false) } }
    }
    var hasActiveSuggestion: Bool { field.ghost != nil }

    /// The record of the suggestion on screen, booked when it resolves.
    private var offer = OfferRecord()

    /// Double-tap-a-modifier state — the easy-to-reach twin of the reply chord.
    private var replyTap = ModifierDoubleTap()

    /// When the field is re-read after an edit (`RereadSchedule`).
    private var reread = RereadSchedule()

    /// The caret of the latest context, and the field's style there
    /// (`FieldState.caret`, `.style`).
    var lastCaretRect: CGRect? { field.caret }
    var lastHostStyle: HostTextStyle { field.style }

    /// Bumped on every real focus change; in-flight captures and corrections
    /// that finish after a change are discarded (a result for the previous app's
    /// context must never attach to the new one).
    private(set) var focusGeneration = 0
    private var lastLoggedSuggestion: String?

    // Surfaced in the menu.
    /// What the focus tracker reported, plus the site of a field only the
    /// system-wide fallback found (`currentTextElement`).
    var typingContext: TypingContext {
        var context = focusTracker.reportedContext
        if context.site == nil { context.site = field.untracked?.site }
        return context
    }
    /// The last request sent — formatted only when Diagnostics asks, not per query.
    private var lastPromptRequest: CompletionRequest?
    var lastPromptDescription: String? { lastPromptRequest?.completionPrompt(maxChars: 1000) }
    private(set) var lastResultDescription: String?
    /// One line of what just happened — the Diagnostics menu's "Last:".
    private(set) var lastEvent = "waiting for typing"
    private var onboardingWindow: OnboardingWindow?

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
            guard let self, self.replyTap.modifierChanged(
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
    private func resolveJournal(_ outcome: SuggestionJournal.Outcome) {
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
        entry.firstWordLogProb = entry.engine == "ngram" ? nil : engine.lastFirstWordLogProb
        env.book(.offer(entry))
    }

    /// Resolve the shown suggestion with `outcome` and take it off screen.
    private func retire(_ outcome: SuggestionJournal.Outcome) {
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
    private func dropOverlay(why: String) {
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
    private func viewScrolled() {
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
    private func dropCompletion(afterUnseenCaretMove why: String, overlay: Bool) {
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
            enabled: Settings.enabled, dictating: dictationController.isBusy,
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
        if !AppPolicy.isTerminal(typingContext.bundleID), correctionController.handleSelection(element) { return }

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
        // completions don't. Reversible from the status menu.
        if let why = RequestGate.quietReason(unproductive: env.isUnproductive(typingContext.bundleID),
                                             onBattery: env.pausedForBattery(), declined: field.isDeclined) {
            lastEvent = why
            return
        }
        if queries.isRunning(before: text, after: ctx.textAfterCaret) { return }

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

    private func scheduleRefresh(for text: String, after: String, context: TextContext) {
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
    @discardableResult
    func apply(_ result: String?, requestText: String,
               cachedContext: TextContext? = nil, countShown: Bool = true,
               instant: Bool = false, reply: Bool = false) -> Bool {
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
        switch RequestGate.landing(sanitized, askedOn: requestText, current: current) {
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
                    fresh: opensRecord, trimToLine: !reply, instant: instant)
        if opensRecord {
            // A fresh suggestion opens a journal record; an unresolved one at
            // this point was replaced before the user reacted to it. The offer
            // itself is booked when this record resolves — resolveJournal.
            resolveJournal(.superseded)
            offer.open(SuggestionJournal.Entry(
                ts: "",
                app: typingContext.bundleID,
                // "ngram" for the fast-path, else the engine's name — so the
                // journal can compare their acceptance rates.
                engine: instant ? "ngram" : engine.name,
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
    private func showSuggestion(_ text: String, _ ctx: TextContext) -> Bool {
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

    // MARK: - Key handling

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
        // Everything else is the pipeline's: one table decides
        // (`SuggestionController+Keys`), and this executes it.
        let keyEvent = NSEvent(cgEvent: event)
        let undo = field.pendingUndo
        let key = KeyState(
            keyCode: keyCode, flags: flags,
            isCommandZ: Self.isPlainCommandZ(keyCode: keyCode,
                                             key: keyEvent?.charactersIgnoringModifiers?.lowercased(),
                                             flags: flags),
            canUndo: undo != nil,
            offHere: AppPolicy.isBlacklisted(typingContext) || dictationController.isBusy,
            ghost: field.ghost, ghostOnScreen: window.showsSuggestion,
            style: Settings.hotkeyStyle)
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
        typeChunk(chunk, over: field.cache, dictated: false)
        env.book(.accepted(chunk: chunk, countSuggestion: !current.accepted, app: typingContext.bundleID))
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
        }
        // Re-read context once the synthetic keystrokes have landed.
        scheduleKeystrokeRefresh(after: 0.09)
    }

}

// MARK: - Focus tracking (wired to `FocusTracker`'s handlers in `init`)

extension SuggestionController {
    /// A real focus change — `FocusTracker` drops the duplicates.
    private func focusDidChange() {
        focusGeneration += 1
        field.focusMoved()
        // The overlay's remembered field style and the probe's pixel verdict
        // describe the field we just left; carried across they outrank what the
        // new field reports about itself (dark verdict from the previous app on
        // a white page — the same unreadable pill the tone resolver exists to
        // prevent).
        window.fieldChanged()
        correctionController.focusChanged()
        let policy = !AppPolicy.allowsCompletions(typingContext) ? " — suggestions off (blacklisted)"
            : AppPolicy.isTerminal(typingContext.bundleID) ? " — terminal, AI agent prompts only"
            : (AppPolicy.isCodeEditor(typingContext.bundleID) ? " — code editor, no screen context" : "")
        DebugLog.shared.log(
            "FOCUS",
            "\(typingContext.appName ?? "?")\(policy)",
            detail: "window: \(typingContext.windowTitle ?? "—")\nfield: \(typingContext.fieldLabel ?? "—")"
        )
        // Stale window text must not leak into the new context.
        promptContext.focusChanged()
        dismiss()
        // A capture belongs to the field it started in: carried across a focus
        // change it would type a sentence meant for one app into another.
        // After the teardown above, so its notice is the last thing painted
        // (and `fieldChanged()` no longer strips its protection either way).
        dictationController.invalidate()
        // Capture shortly after focus settles: passing through apps with
        // cmd-tab must not trigger screenshots, but a chat's first message
        // should still have context before the first keystroke lands.
        // Paused (or on battery), blacklisted or quiet: no reload, no
        // indicator, no screenshot.
        if let element = env.trackedElement(), Settings.enabled, completionsWelcome {
            // Entered a text field — start reloading the model now (no-op unless
            // it was idle-unloaded) so the first keystroke doesn't wait for it.
            engine.prewarmIfNeeded()
            if case .preparing = engine.state {
                if let ctx = env.context(of: element) {
                    field.noteCaret(ctx.caretRect, style: ctx.host)
                    indicator.start()
                }
            }
            let generation = focusGeneration
            env.after(0.8) { [weak self] in
                guard let self, self.focusGeneration == generation else { return }
                // An empty message box in a chat: the reply's own, wider
                // capture replaces the completion's.
                if Settings.autoReply, AppPolicy.isChat(self.typingContext), self.replyComposer.compose(auto: true) {
                    return
                }
                self.promptContext.refreshScreenIfNeeded(typed: "")
                // No capture coming (context off, no permission, blocked app):
                // warm the new field's prompt now — its first keystroke would
                // otherwise prefill the whole text. A capture warms on landing.
                if !self.promptContext.screenCaptureInFlight {
                    self.promptContext.warm(self.currentTextElement().flatMap {
                        self.env.context(of: $0)?.textBeforeCaret
                    })
                }
            }
        }
    }

    /// One edit posts two notifications ~0.1 ms apart (selection, then
    /// value) and the main queue drains between them: one short wait answers
    /// both with a single read instead of two identical ones.
    private func focusedTextDidChange(valueChanged: Bool) {
        guard reread.notified(valueChanged: valueChanged) else { return }
        env.after(0.004) { [weak self] in
            guard let self else { return }
            reread.notifiedReadStarts()
            textDidChange()
            reread.notifiedReadEnded()
        }
    }

    private func focusedAppDidResign() {
        // Left the app we were typing in — drop any ghost/indicator left at its
        // caret. A returning keystroke re-queries from the live context, so this
        // can't strand a still-wanted suggestion.
        dropOverlay(why: "left the app")
        // A capture dies with the app it started in. This is the only signal
        // that fires when the app switched *to* is Pretype itself — the tracker
        // never attaches to our own pid, so no focus change bumps
        // `focusGeneration`, and a capture left alive here would pass its
        // stale-focus check and type the transcript into our own menu or
        // Settings field. After `dropOverlay`, which would strip its notice's
        // protection and fade it at once.
        dictationController.invalidate()
    }
}
