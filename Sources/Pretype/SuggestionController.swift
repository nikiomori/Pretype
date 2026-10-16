import AppKit

/// Orchestrates the pipeline: focused-element text → completion engine →
/// ghost overlay → Tab acceptance → text injection. Also handles
/// fix-selection (⌥Tab) and feeds the menu with diagnostics and context.
@MainActor
final class SuggestionController {
    private let focusTracker = FocusTracker()
    private let keyTap = KeyTap()
    let window = SuggestionWindow()
    /// Engine lifecycle + the settings that reshape it; the menu and settings
    /// window drive it directly. A rebuild calls back into `dismiss()` (wired
    /// in `init`) to drop the stale suggestion.
    let engineCoordinator = EngineCoordinator()
    /// The active completion engine, owned by `engineCoordinator`. Read-only here;
    /// model/style/gate changes flow through the coordinator's methods.
    var engine: CompletionEngine { engineCoordinator.engine }
    private var refreshTask: Task<Void, Never>? { didSet { updateScrollMonitoring(canStop: false) } }
    /// Bumped per scheduled completion query so a finishing task only clears
    /// `refreshTask` when it's still the current one (a newer query owns it
    /// otherwise). Without this the reference lingers after a normal finish and
    /// `isQueryRunning` reads true forever.
    private var refreshSeq = 0
    /// The text a scheduled completion query was made for — nil for a reply.
    /// One edit reaches `textDidChange` twice (the AX notification, then the
    /// keystroke timer); the second must not restart the debounce, or cancel
    /// the stream, of a query already running for exactly this text.
    private var refreshKey: (before: String, after: String)?
    /// A completion query is scheduled or streaming (the indicator's dots).
    var isCompleting: Bool { refreshTask != nil }

    /// Engine-state indicator at the caret (download progress, thinking dots,
    /// transient notices). Shares the overlay window with the suggestion.
    lazy var indicator = CaretIndicator(owner: self)
    /// The text-fixing flows (⌥⇥ fix-selection / last word, inline spell-fix),
    /// kept separate from the completion pipeline below.
    lazy var correctionController = CorrectionController(owner: self)

    /// Hold-to-talk dictation. Owns the microphone, the caret pill while it
    /// listens, and nothing else — the transcript comes back through
    /// `insertDictated`, which is the same injection path an accept takes.
    let dictationController = DictationController()

    private struct Active {
        /// Text before the caret at the moment the suggestion became valid.
        var anchor: String
        /// Remaining (not yet accepted) suggestion text.
        var text: String
        /// Already counted as an accepted suggestion, so accepting word-by-word
        /// counts once (not once per word). Carried across in-place mutations;
        /// reset only when a fresh suggestion is shown. See accept().
        var accepted = false
        /// false for a composed reply: shown whole — in the pill when it
        /// doesn't fit the line — never trimmed to the line like a completion.
        var trimToLine = true
    }

    private var active: Active? { didSet { updateScrollMonitoring(canStop: false) } }
    var hasActiveSuggestion: Bool { active != nil }

    /// Journal record for the currently shown suggestion, opened when it first
    /// appears and written out with its outcome when it resolves. Everything is
    /// local-only (see `SuggestionJournal`). The entry's `app` is captured at
    /// show time: resolution can arrive after focus has already moved (a
    /// `.abandoned` on app switch), and `typingContext` names the NEW app by
    /// then — booking the offer, or journaling it, against that one blames the
    /// wrong app.
    private var pendingJournal: (entry: SuggestionJournal.Entry, shownAt: Date)?

    /// True while the visible suggestion came from the personal n-gram
    /// fast-path (shown instantly, before the LLM answers). The LLM stream
    /// supersedes it via the normal `apply` path; its *abstain* must not
    /// hide it though — a confident personal phrase beats showing nothing.
    private var activeIsInstant = false

    /// Double-tap-a-modifier state — the easy-to-reach twin of the reply chord.
    private var replyTap = ModifierDoubleTap()

    private var keyRefreshScheduled = false
    private var keyRefreshIsFallback = false
    /// AX notifications on the focused field since the last keystroke, and
    /// whether a read ran after both (see `scheduleKeystrokeRefresh`).
    private var axSeenSinceKey = (value: false, selection: false)
    private var axReadSinceKey = false
    private var axRefreshScheduled = false
    /// Successful field reads, so a notification-driven pass can tell one ran.
    private var contextReads = 0
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
    /// What the focus tracker reported, plus the site of a field only the
    /// system-wide fallback found (`currentTextElement`).
    var typingContext: TypingContext {
        var context = trackedContext
        if context.site == nil { context.site = fallbackSite }
        return context
    }
    private var trackedContext = TypingContext()
    /// The last request sent — formatted only when Diagnostics asks, not per query.
    private var lastPromptRequest: CompletionRequest?
    var lastPromptDescription: String? { lastPromptRequest?.completionPrompt(maxChars: 1000) }
    private(set) var lastResultDescription: String?
    var lastEvent = "waiting for typing"
    private var onboardingWindow: OnboardingWindow?

    init() {
        // A model/style/gate rebuild drops the suggestion that belonged to the
        // old engine.
        engineCoordinator.onRebuild = { [weak self] in self?.dismiss() }
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
            if !dictating { self.viewScrolled() }
            // Not from inside the monitor's own handler.
            DispatchQueue.main.async { [weak self] in self?.updateScrollMonitoring() }
        }
        keyTap.mouseDownHandler = { [weak self] in
            guard let self else { return }
            // Dictation keeps the overlay while busy, as for scroll — read
            // before `mouseDown()`, which may end the capture.
            let dictating = self.dictationController.isBusy
            self.dictationController.mouseDown()
            self.dropCompletion(afterUnseenCaretMove: "mouse click", overlay: !dictating)
        }
        keyTap.reenabledHandler = { [weak self] in
            // macOS turned the tap off (a callback ran past its timeout, or
            // input was held off) and keystrokes went by unseen.
            guard let self else { return }
            self.lastAcceptedChunk = nil
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
                flags: event.flags, gesture: Settings.replyGesture, now: Date()) else { return }
            // Off the tap callback before any AX read — same rule as the chord.
            DispatchQueue.main.async { [weak self] in self?.composeReply() }
        }
    }

    func start() {
        focusTracker.start()
        ensureKeyTap()
        if Settings.personalizationLevel != .off {
            PersonalNgram.shared.prepareIfNeeded()
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

    /// Close the pending journal record with its outcome. Idempotent — the
    /// first resolution wins; later calls (e.g. the `dismiss()` that follows an
    /// Escape) find nothing pending.
    private func resolveJournal(_ outcome: SuggestionJournal.Outcome) {
        guard let (shown, shownAt) = pendingJournal else { return }
        pendingJournal = nil
        // The counters are booked HERE, not where the ghost was drawn: what makes
        // a ghost an offer the user could take is how long it survived and what
        // ended it, and neither is known until now. See `Stats.isChance`.
        let shownForMs = Int(Date().timeIntervalSince(shownAt) * 1000)
        Stats.recordOffer(outcome: outcome, shownForMs: shownForMs,
                          tookAny: shown.acceptedChars > 0, app: shown.app)
        guard Settings.suggestionJournalEnabled else { return }
        var entry = shown
        // ONE snapshot for both consumers: observe's delta cursor must see
        // exactly the ctx window the journal stores, or the next launch's
        // replay re-splits the stream differently and double-learns.
        entry.ctx = String(entry.ctx.suffix(1000))
        // Live n-gram learning from the same ctx snapshots the startup build
        // replays — so today's typing predicts today, not from the next launch.
        if Settings.personalizationLevel != .off {
            PersonalNgram.shared.observe(ctx: entry.ctx, app: entry.app)
        }
        entry.ts = SuggestionJournal.timestamp()
        entry.outcome = outcome
        if outcome != .superseded, let active {   // superseded: `active` is already the new ghost
            entry.consumedChars = Self.consumedChars(outcome: outcome, offered: entry.suggestion,
                                                     remaining: active.text)
        }
        entry.shownForMs = shownForMs
        // Read at resolve, not show: the engine publishes the value only
        // after the generation completes, which is after the first streamed
        // partial is shown. By resolve time it belongs to the shown
        // suggestion — except `superseded`, where a newer generation has
        // already overwritten it (see Entry doc: calibration filters those).
        entry.firstWordLogProb = entry.engine == "ngram" ? nil : engine.lastFirstWordLogProb
        SuggestionJournal.shared.append(entry)
    }

    /// Resolve the shown suggestion with `outcome` and take it off screen.
    private func retire(_ outcome: SuggestionJournal.Outcome) {
        resolveJournal(outcome)
        active = nil
        // The query behind this ghost may still be streaming; once its ghost
        // is gone the same text must re-query, not ride the dedupe in
        // `textDidChange` (backspacing onto a retired ghost's text found no
        // suggestion at all).
        refreshKey = nil
        window.hide()
    }

    func dismiss() {
        clearActiveCompletion()
        activeIsInstant = false
        lastAcceptedChunk = nil
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
        let needed = window.isVisible || active != nil || refreshTask != nil
            || dictationController.isBusy || dictationController.isHoldArmed
        if needed || canStop { keyTap.wantsScroll = needed }
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

    /// A scroll strands what is drawn, not what is being written: a reply or
    /// fix in flight (seconds of OCR and generation — scrolling the chat to
    /// read it meanwhile is natural) keeps running and lands on a fresh read of
    /// the caret. Forgetting the cache and the caret is what forces that read,
    /// and keeps the thinking dots from painting at the pre-scroll spot.
    private func viewScrolled() {
        let replyInFlight = refreshTask != nil && refreshKey == nil
        guard replyInFlight || correctionController.inFlight else {
            return dropOverlay(why: "the view scrolled")
        }
        latestTextBeforeCaret = nil
        lastCaretRect = nil
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
        latestTextBeforeCaret = nil
        guard overlay, active != nil || (refreshTask != nil && refreshKey != nil) else { return }
        lastEvent = "dismissed — \(why)"
        clearActiveCompletion()
        if window.showsSuggestion { window.hide() }
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
    /// the wrong target), and one the system disabled when the grant was
    /// revoked stays disabled after the re-grant — so keep watching, and
    /// rebuild it whenever it's down while trust is there.
    private func ensureKeyTap() {
        let rebuild = !keyTap.isActive && Permissions.isTrusted
        if rebuild { keyTap.stop() }
        keyTap.start()
        if rebuild { updateScrollMonitoring() }   // `stop` dropped the scroll monitor too
        guard keyTapWatch == nil else { return }
        // A timer with slack, not a chain of exact 3 s wakeups: macOS folds
        // it into wakeups it runs anyway.
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.ensureKeyTap() }
        }
        timer.tolerance = 1.5
        RunLoop.main.add(timer, forMode: .common)
        keyTapWatch = timer
    }

    private var keyTapWatch: Timer?

    /// The field the pipeline reads and types into — nil while keyboard focus
    /// sits in another process. Launchers (Spotlight, Raycast, Alfred) take
    /// keys through a non-activating panel: the menu bar keeps the app we
    /// track and no activation or focus change fires, so without this check
    /// the old field's ghost would be re-offered on every launcher keystroke,
    /// and ⇥ would type it into the launcher.
    func currentTextElement() -> AXUIElement? {
        guard !keyboardFocusIsElsewhere else { return nil }
        if let element = focusTracker.focusedTextElement { return element }
        guard let element = AXText.systemFocusedTextElement(knownEditable: fallbackSiteElement) else { return nil }
        // The tracker missed this field, so its site was never read and a
        // site switched off would fall through to the app check. Once per field.
        if fallbackSiteElement.map({ !CFEqual($0, element) }) ?? true {
            fallbackSiteElement = element
            fallbackSite = trackedContext.site == nil ? AXText.pageHost(for: element) : nil
        }
        return element
    }

    private var fallbackSiteElement: AXUIElement?
    private var fallbackSite: String?

    /// One system-wide AX read: the process that holds keyboard focus is
    /// neither the tracked app nor Pretype itself (our panels never take focus;
    /// our own windows are `isOwnUIFrontmost`'s business).
    private var keyboardFocusIsElsewhere: Bool {
        var pid: pid_t = 0
        guard let app = AXText.element(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as String),
              AXUIElementGetPid(app, &pid) == .success, pid > 0,
              focusTracker.observedPID > 0 else { return false }
        return pid != focusTracker.observedPID && pid != ProcessInfo.processInfo.processIdentifier
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
        var request = CompletionRequest(textBeforeCaret: text, textAfterCaret: after, appBundleID: typingContext.bundleID,
                                        appName: typingContext.appName, site: typingContext.site)
        if AppPolicy.allowsScreenContext(typingContext) {
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
        request.personalExamples = personalExamples
        return request
    }

    /// Retrieve the accepted phrases most similar to what's being typed, at
    /// most every 25 s and never on the keystroke path. The result set stays
    /// frozen between refreshes so the instruct prompt prefix — and with it the
    /// KV cache — survives incremental typing.
    private func refreshPersonalExamplesIfNeeded(typed: String) {
        guard !examplesRefreshInFlight,
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
                self.warmPromptForCurrentText()
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

    /// The screen block and the retrieved examples sit at the HEAD of the
    /// prompt, so their refresh invalidates the engine's whole KV cache. Have
    /// the engine re-read the prompt now, in the background, rather than on
    /// the next keystroke (where a cold prefill measured ~0.45 s on E4B-8bit).
    private func warmPromptForCurrentText(_ typed: String? = nil) {
        guard Settings.enabled, !isOwnUIFrontmost, !dictationController.isBusy,
              !AppPolicy.pausedForBattery, AppPolicy.allowsCompletions(typingContext),
              !Stats.isUnproductive(typingContext.bundleID),
              let text = typed ?? latestTextBeforeCaret,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        engine.warmPrompt(for: makeRequest(text: text))
    }

    /// A ⌘-chord may have been a copy (⌘C/⌘X, any layout): the clipboard block
    /// also sits at the prompt's head, so a changed clipboard is warmed the
    /// same way as a screen refresh. The check is a counter compare; the
    /// pasteboard is only read (by `makeRequest`) when it moved.
    private func warmPromptIfClipboardChanges() {
        guard Settings.clipboardContextEnabled, AppPolicy.allowsScreenContext(typingContext) else { return }
        let before = NSPasteboard.general.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, NSPasteboard.general.changeCount != before else { return }
            // A ⌘-chord drops the synchronous text cache; read the field for
            // this warm-up only (the cache keeps its own refresh rules).
            let text = self.latestTextBeforeCaret ?? self.currentTextElement().flatMap {
                AXText.context(for: $0)?.textBeforeCaret
            }
            self.warmPromptForCurrentText(text)
        }
    }

    /// Surfaced in the Context submenu.
    var screenContextStatus: String {
        guard Settings.screenContextEnabled else { return "off" }
        guard ScreenContext.hasPermission else {
            return "no Screen Recording permission (grant + relaunch)"
        }
        guard AppPolicy.allowsScreenContext(typingContext) else {
            return "blocked in this app (terminal/code editor)"
        }
        if let screenSummary { return "captured \(screenSummary.count) chars" }
        return screenCaptureInFlight ? "capturing…" : "nothing captured yet"
    }

    /// Refreshes the window OCR at most every 25 s, off the typing path.
    /// Paused on battery: the capture only feeds completions (a reply takes
    /// its own fresh one), and its landing would warm a prompt nobody runs.
    private func refreshScreenContextIfNeeded(typed: String) {
        guard Settings.enabled, Settings.screenContextEnabled, ScreenContext.hasPermission,
              !AppPolicy.pausedForBattery, AppPolicy.allowsScreenContext(typingContext) else { return }
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
                // The first capture after a focus change warms even when it
                // found nothing: the new field's prompt is cold either way.
                let changed = summary != self.screenSummary || self.screenCapturedAt == .distantPast
                self.screenCapturedAt = Date()
                self.screenSummary = summary
                if changed { self.warmPromptForCurrentText() }
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
        // Checked on both sides of the lookup: before it, the app (no AX
        // reads in a terminal); after it, also a site that only resolving a
        // field the tracker missed could read.
        if !AppPolicy.allowsCompletions(typingContext) {
            lastEvent = "suggestions are off in blacklisted apps"
            dismiss()
            return
        }
        guard let element = currentTextElement() else {
            if active != nil { lastEvent = "lost text element" }
            dismiss()
            return
        }
        if fallbackSite != nil, AppPolicy.isBlacklisted(typingContext) {
            lastEvent = "suggestions are off on this site"
            dismiss()
            return
        }

        // A selection just typed over (a selection fix) may still read as
        // selected inside the settle window — and would put its "fix" pill
        // back. Look again once the host has caught up.
        if let deadline = injectionSettleDeadline, Date() < deadline, AXText.selectionInfo(for: element) != nil {
            scheduleKeystrokeRefresh(after: 0.09)
            return
        }
        // A selection switches into fix-selection mode (⌥⇥); the correction
        // controller owns the overlay while it's up. Not in a terminal, where
        // a selection is screen output and the chord is off.
        if !AppPolicy.isTerminal(typingContext.bundleID), correctionController.handleSelection(element) { return }

        guard let ctx = AXText.context(for: element) else {
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
        contextReads &+= 1
        lastCaretRect = ctx.caretRect
        lastHostStyle = ctx.host
        refreshScreenContextIfNeeded(typed: text)
        refreshPersonalExamplesIfNeeded(typed: text)

        // A reviving last-word fix preview, or an inline spell-fix on the word at
        // the caret, preempts a completion — fixing what's written matters more
        // than predicting ahead. Not in a terminal: the key handler leaves ⇥/⎋
        // to the terminal there, so a pill could be neither applied nor dismissed.
        if !AppPolicy.isTerminal(typingContext.bundleID), correctionController.handleCaret(ctx) { return }

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
                retire(delta.hasPrefix(current.text) ? .typedThrough : .diverged)
            } else {
                // Context jumped (backspace, caret move, programmatic edit).
                retire(.abandoned)
            }
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
        // Same placement for the user's battery rule: typo fixes and emoji
        // shortcodes cost nothing, completions are the GPU bursts it's about.
        if AppPolicy.pausedForBattery {
            lastEvent = "paused on battery"
            return
        }

        // Personal n-gram fast-path: a confident hit from the user's own
        // recurring phrases shows at ~0 ms, before the debounce even starts;
        // the LLM stream below then supersedes it through the same apply path.
        if refreshTask != nil, let key = refreshKey,
           key.before == text, key.after == ctx.textAfterCaret { return }

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
            } else if SpellChecker.endsOnCompleteWord(before: text, after: after),
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
        // Nil, not just cancelled: the early returns below would otherwise
        // leave `isCompleting` reading true over a task that will never finish.
        refreshTask = nil
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

        let request = makeRequest(text: text, after: after)
        let engine = engine
        indicator.start()

        refreshSeq += 1
        let refreshID = refreshSeq
        refreshKey = (text, after)
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Settings.debounceMs))
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
            let started = Date()
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
                        Stats.recordLatency(Date().timeIntervalSince(started))
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
                if self.refreshSeq == refreshID { self.refreshTask = nil }
                self.lastEvent = "engine error: \(error.localizedDescription)"
                DebugLog.shared.log("ERROR", error.localizedDescription)
                self.indicator.stop()
                self.indicator.flashTransient(.error(String(localized: "engine error")))
                return
            }
            guard let self, !Task.isCancelled else { return }
            if self.refreshSeq == refreshID { self.refreshTask = nil }
            self.lastPromptRequest = request
            if shown {
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
                       allowEmpty: Bool = false, trimToLine: Bool = true) -> Bool {
        indicator.stop()
        guard Settings.enabled else { return false }
        var suggestion = result.map { sanitize($0, maxChars: maxChars) } ?? ""
        guard !suggestion.isEmpty else {
            // nil/empty is an abstain — or a mid-stream RETRACT ("" from the
            // engine when its final gate rejected what the partials already
            // showed). Close the journal record and clear the stale suggestion
            // so a hidden one can't still be accepted.
            lastEvent = "engine returned no suggestion"
            retire(.abandoned)
            return false
        }
        // While an injection settles, every anchor in reach (cache or AX read)
        // either predates or trails the synthetic keystrokes: narrowing a
        // streamed partial against one resurrects the just-accepted word (and
        // across a step of the AX window's start the offsets diverge outright).
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
                  let fresh = AXText.context(for: element, allowEmpty: allowEmpty) {
            // The host hasn't caught up with a key the tap already saw ("hel"
            // read, "hell" cached): anchoring here would let ⇥ type the "l"
            // twice. Wait for the keystroke's own refresh instead.
            if let cached = latestTextBeforeCaret, cached.count > fresh.textBeforeCaret.count,
               cached.hasPrefix(fresh.textBeforeCaret) {
                lastEvent = "field read trails the last keystroke; result dropped"
                return false
            }
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
            retire(.abandoned)
            return false
        }

        // Preserve the "already counted as accepted" flag across streamed growth
        // of the same suggestion (countShown == false, no recordShown); reset it
        // only for a genuinely fresh suggestion. Keeps accepted ≤ shown even when
        // the user accepts word-by-word while the model is still streaming.
        // A stream whose ghost was retired under it (a backspace, a ⌘-chord)
        // re-showing it is a fresh offer too: with no record open it would be
        // shown — and acceptable — with nothing booked against it.
        let opensRecord = countShown || pendingJournal == nil
        active = Active(anchor: current, text: suggestion,
                        accepted: opensRecord ? false : (active?.accepted ?? false),
                        trimToLine: trimToLine)
        activeIsInstant = instant
        if opensRecord {
            // A fresh suggestion opens a journal record; an unresolved one at
            // this point was replaced before the user reacted to it. The offer
            // itself is booked when this record resolves — resolveJournal.
            resolveJournal(.superseded)
            // ts, outcome, typed, shownForMs and the logprob are stamped at
            // resolve; ctx is capped there.
            pendingJournal = (entry: SuggestionJournal.Entry(
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
                screen: screenSummary != nil
                    && AppPolicy.allowsScreenContext(typingContext)),
                shownAt: Date())
        } else {
            // Streamed growth of the same suggestion — keep the record current.
            let recordCtx = pendingJournal?.entry.ctx
            pendingJournal?.entry.suggestion = Self.journalSuggestion(suggestion, current: current, recordCtx: recordCtx)
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
        let firstWord = String(suggestion.prefix(while: \.isWordChar))
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
        let shown = window.show(mode: .suggestion(text), at: rect, host: ctx.host,
                                trimToLine: active?.trimToLine ?? true) ?? text
        if shown != text {
            active?.text = shown
            let recordCtx = pendingJournal?.entry.ctx
            pendingJournal?.entry.suggestion = Self.journalSuggestion(shown, current: ctx.textBeforeCaret,
                                                                      recordCtx: recordCtx)
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
    private func sanitize(_ raw: String, maxChars: Int) -> String {
        let line = String(raw.replacingOccurrences(of: "\t", with: " ").prefix { !$0.isNewline })
        // Runs collapsed first, so at most one space can trail the cut. The
        // regex only when there is a run: this runs on every streamed partial.
        let collapsed = line.contains("  ")
            ? line.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression) : line
        let out = collapsed.prefix(maxChars)
        return String(out.hasSuffix(" ") ? out.dropLast() : out)
    }

    // MARK: - Reply

    /// Write the user's next message for them: OCR the conversation in front of
    /// them, ask the engine to answer it, and offer the whole thing as one ghost
    /// the normal accept keys take (⇥ word by word, ⇧⇥ all of it, ⎋ to drop it).
    /// Asked for by the chord, or — `auto`, with "Offer replies in chats" on —
    /// by the caret landing in an empty message box. Nothing is typed unasked.
    /// An automatic reply stays silent when it can't run: no hints, no
    /// download of a fix model nobody asked for. Returns whether it started.
    ///
    /// It borrows `refreshTask` for the duration, so the thinking dots run, a
    /// keystroke or a focus change cancels it, and it can't race a completion.
    /// Never call inside the event-tap callback: it does synchronous AX reads.
    @discardableResult
    private func composeReply(auto: Bool = false) -> Bool {
        // Every stop below says why, in the console and in the menu's "Last:"
        // line: an explicitly-pressed chord that does nothing, silently, is
        // indistinguishable from a broken build.
        DebugLog.shared.log("REPLY", auto ? "offered — empty message box"
            : "requested (\(Settings.replyGesture.label) / \(Settings.hotkeyStyle.replyLabel))")
        func stop(_ why: String) -> Bool {
            if !auto { lastEvent = "reply: \(why)" }
            DebugLog.shared.log("REPLY", "not composing — \(why)")
            return false
        }
        guard Settings.enabled else { return stop("Pretype is paused") }
        guard !isOwnUIFrontmost else { return stop("our own window is frontmost") }
        // A hands-free capture owns the overlay; a reply would hide its pill.
        guard !dictationController.isBusy else { return stop("dictation is listening") }
        // Element first: it reads the site the blacklist check needs.
        guard let element = currentTextElement() else {
            return stop("no text field in focus")
        }
        guard !AppPolicy.isBlacklisted(typingContext) else {
            return stop("off in \(typingContext.site ?? typingContext.appName ?? "this app")")
        }
        // allowEmpty: an empty chat box is the case this feature exists for —
        // the completion pipeline's "nothing to continue" is not a refusal here.
        guard let ctx = AXText.context(for: element, allowEmpty: true),
              let rect = ctx.caretRect else {
            return stop("cannot read the field or place the ghost")
        }
        if auto {
            guard (ctx.textBeforeCaret + ctx.textAfterCaret).allSatisfy(\.isWhitespace) else {
                return stop("the message box isn't empty")
            }
            guard engine.isCorrectionReady else { return stop("the reply model isn't loaded") }
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
              AppPolicy.allowsScreenContext(typingContext) else {
            _ = stop("needs screen context — \(screenContextStatus)")
            if auto { return false }
            // Say which of the three is missing, in the words the fix is found
            // under — "needs screen context" left the user to work out which.
            let why = !Settings.screenContextEnabled
                ? String(localized: "reply reads the screen — turn on “Use screen context” in Settings")
                : !ScreenContext.hasPermission
                    ? String(localized: "reply needs Screen Recording — allow Pretype in System Settings, then relaunch")
                    : typingContext.appName.map { String(localized: "reply doesn't read the screen in \($0)") }
                        ?? String(localized: "reply doesn't read the screen in this app")
            indicator.flashTransient(.hint(why), hideAfter: 3.5)
            return false
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
        refreshKey = nil
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
                // journal rules as a completion — only longer, reading an
                // empty field as a real (empty) context, and never trimmed to
                // the line: a reply cut to its first 70 chars lost the rest.
                let shown = self.apply(reply, requestText: ctx.textBeforeCaret,
                                       cachedContext: ctx, maxChars: 400, allowEmpty: true,
                                       trimToLine: false)
                DebugLog.shared.log("REPLY", shown ? "shown" : "dropped — \(self.lastEvent)")
            case .success(nil):
                // Two different silences: nothing readable on screen, or the
                // model had nothing to say about it.
                let why = conversation == nil ? "nothing to reply to" : "no answer from the model"
                DebugLog.shared.log("REPLY", why)
                guard !auto else { return }
                self.lastEvent = "reply: \(why)"
                self.indicator.flashTransient(.hint(conversation == nil
                    ? String(localized: "nothing to reply to") : String(localized: "no answer from the model")),
                    orAtPointer: true)
            case .failure(let error):
                DebugLog.shared.log("ERROR", "reply failed: \(error.localizedDescription)")
                guard !auto else { return }
                self.lastEvent = "reply failed: \(error.localizedDescription)"
                self.indicator.flashTransient(Self.failureNotice(error, fallback: String(localized: "reply failed")),
                                              orAtPointer: true)
            }
        }
        return true
    }

    /// The notice for a failed explicit request (⌥⇥, ⌥⇧⇥). An engine that
    /// isn't loaded says so: "failed" would read as a bug, and "looks fine"
    /// (what a bare nil used to show) as a verdict that never ran.
    nonisolated static func failureNotice(_ error: Error, fallback: String) -> SuggestionDisplayMode {
        if let notReady = error as? EngineNotReady { return .hint(notReady.message) }
        return .error(fallback)
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
        // Our own Settings window: `begin` refuses while we are frontmost, so
        // swallowing here would take a keystroke out of our own text fields to
        // do nothing with it. A launcher holding the keys: same, `begin`
        // finds no field of ours there.
        return !isOwnUIFrontmost && !keyboardFocusIsElsewhere
    }

    private func handleKeyDown(_ event: CGEvent) -> Bool {
        guard Settings.enabled else { return false }
        if event.getIntegerValueField(.eventSourceUserData) == TextInjector.magicTag { return false }
        // A real keystroke means a held modifier is part of a chord, not a tap.
        replyTap.keyPressed()

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        if flags.contains(.maskCommand) { warmPromptIfClipboardChanges() }

        // Hands-free dictation, started and ended by the same chord.
        //
        // FIRST, ahead of `keyPressed` below, because that call reads any
        // ordinary keystroke as "the modifier you were holding was part of a
        // chord" and throws the capture away — including the one this very
        // chord is being pressed to continue. Hold ⌥, say a sentence, release,
        // reach for ⌃⌥D to carry on hands-free, and the sentence would vanish
        // with a notice blaming you for typing.
        if isLatchChord(keyCode: keyCode, flags: flags) {
            lastAcceptedChunk = nil
            // Autorepeat is swallowed and otherwise ignored. The WindowServer
            // sends these at ~15 Hz for as long as the chord is held, and a
            // toggle apiece would tear the capture down and re-open the input
            // device on every one — an HFP profile flip per frame on a
            // Bluetooth headset, which is the exact damage the device-change
            // circuit breaker exists to prevent, by a path it can't see.
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                // Off the tap before the AX reads `begin` makes, same rule as
                // the reply chord.
                DispatchQueue.main.async { [weak self] in self?.dictationController.toggleLatch() }
            }
            return true
        }

        // ...and not someone talking either. Unconditional, because the window
        // that matters most is the one where there is no capture yet: ⌥⌫ and
        // ⌥-arrows hold the modifier across several presses, and a hold left
        // armed through them opens the microphone in the middle of a chord.
        // Idle this costs a cleared date. Escape is the explicit "forget that"
        // while listening, so it is ours to swallow — but only when a capture
        // was live as it arrived, which the call below is what ends.
        let wasDictating = dictationController.isBusy
        let isEscape = keyCode == KeyCode.escape
        dictationController.keyPressed(isEscape: isEscape)
        if wasDictating, isEscape { return true }
        // Our own Settings/Debug field is focused — pass every key through
        // untouched (never accept a stale background suggestion into it).
        if isOwnUIFrontmost { return false }
        let keyEvent = NSEvent(cgEvent: event)

        // Exact ⌘Z undoes the last accepted chunk. The cached-text check decides
        // consume vs pass-through synchronously (no AX read inside the tap): a
        // caret moved since the accept (mouse click) means the app's own undo is
        // the right handler, not our backspaces. On a miss the key falls through
        // and the bottom of this function clears `lastAcceptedChunk`.
        if let accepted = lastAcceptedChunk, let expected = lastAcceptedSnapshot,
           Self.isPlainCommandZ(keyCode: keyCode,
                                key: keyEvent?.charactersIgnoringModifiers?.lowercased(),
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
        // In an app (or site) Pretype stays out of, neither chord is ours: the
        // keystroke goes to the app, and nothing of the field reaches a model.
        // Nor while a hands-free capture listens (typing is allowed then): the
        // capture owns the overlay, and a reply or fix would fight its pill.
        let offHere = AppPolicy.isBlacklisted(typingContext) || dictationController.isBusy
        if !offHere, Settings.hotkeyStyle.matchesReply(keyCode: keyCode, flags: flags) {
            lastAcceptedChunk = nil
            DispatchQueue.main.async { [weak self] in self?.composeReply() }
            return true
        }

        // Fix flows (⌥⇥, plus the keys that apply/dismiss a fix preview) get
        // first refusal — a fix preview is only ever up when no completion is.
        switch offHere ? .ignored : correctionController.handleKey(keyCode: keyCode, flags: flags) {
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
            // Only an accept key pays for the focus check (one AX read): a
            // launcher holding the keys must get its ⇥, not our ghost.
            let acceptAll = style.matchesAcceptAll(keyCode: keyCode, flags: flags)
            let acceptWord = !acceptAll && style.matchesAcceptWord(keyCode: keyCode, flags: flags)
            if acceptAll || acceptWord, !keyboardFocusIsElsewhere {
                accept(chunk: acceptAll ? current.text : Self.firstWordChunk(of: current.text))
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
        narrowActive(typed: keyEvent?.characters ?? "", flags: flags)

        // AX change notifications are unreliable in some apps (notably
        // Electron), so every keystroke also schedules a context re-read.
        axSeenSinceKey = (false, false)
        axReadSinceKey = false
        scheduleKeystrokeRefresh(keystrokeFallback: true)
        lastAcceptedChunk = nil
        return false
    }

    /// Synchronously shrinks (or drops) the live suggestion to match a
    /// pass-through keystroke, using the characters `typed` carried by the
    /// event itself — no AX round-trip, so it can't block on a hung target app.
    private func narrowActive(typed: String, flags: CGEventFlags) {
        // Command/control chords carry no typed text but can mutate the field
        // arbitrarily (⌘V, ⌘X, the app's own ⌘Z): both the synchronous cache
        // and the ghost stop being trustworthy — invalidate them and let the
        // scheduled AX refresh re-read the truth, exactly like control input.
        guard !flags.contains(.maskCommand), !flags.contains(.maskControl) else {
            latestTextBeforeCaret = nil
            if active != nil { retire(.abandoned) }
            return
        }
        guard !typed.isEmpty else { return }   // dead keys, bare modifiers
        let isControl = Self.isControlInput(typed)
        // Keep the cache marker truthful for EVERY pass-through keystroke,
        // ghost or not: a streamed partial landing inside the ≤60 ms refresh
        // window anchors on this cache, and pre-keystroke text would make Tab
        // duplicate the typed character. Control input (backspace, arrows)
        // can't be replayed onto the cache — nil it so apply() falls back to a
        // fresh AX read. Typed text is appended with no re-cap: the AX read
        // window's start holds still (`AXText.windowStart`), so a fresh read is
        // this plus what was typed — a cap counted in Characters sat at a
        // different offset than the UTF-16 window and failed the settle/undo
        // equality gates. Every AX read re-syncs it, so it can't grow unbounded.
        if isControl {
            latestTextBeforeCaret = nil
        } else {
            latestTextBeforeCaret? += typed
        }
        guard var current = active else { return }
        guard let remaining = Self.narrowedSuggestion(current.text, typedCharacters: typed) else {
            // Divergent or control input — the ghost no longer matches the field.
            if isControl {
                retire(.abandoned)
            } else if typed.hasPrefix(current.text) {
                // The keystroke completed the remaining suggestion unaided.
                retire(.typedThrough)
            } else {
                retire(.diverged)
            }
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

    /// The one way text is typed into the host — accept, dictation, ⌘Z undo
    /// and every fix. Backspaces `deleteCount` characters, types `text`, moves
    /// the synchronous cache in step and opens the settle window, so an AX
    /// read that still trails the synthetic keys can't re-offer, resurrect or
    /// re-fix what was just typed (a lagging read of the old typo re-showed its
    /// pill, and a second ⇥ applied the fix twice). `before` is the text
    /// before the caret as the edit starts — nil when unknown (a selection
    /// being typed over), which leaves the cache unknown too. Returns the
    /// cache after the edit.
    @discardableResult
    func inject(_ text: String, deletingBackward deleteCount: Int = 0,
                over before: String?) -> String? {
        if deleteCount > 0 { TextInjector.deleteBackward(deleteCount) }
        if !text.isEmpty { TextInjector.insert(text) }
        latestTextBeforeCaret = Self.textAfterInjection(text, deletingBackward: deleteCount, over: before)
        injectionSettleDeadline = Date().addingTimeInterval(0.3)
        return latestTextBeforeCaret
    }

    /// The journal record's suggestion for a ghost now showing `remaining` at
    /// `current`: what was typed since the record's `ctx`, then `remaining` —
    /// a stream that re-anchors after the user typed hands over only the rest,
    /// and storing that alone made `ctx + suggestion` text nobody was offered.
    nonisolated static func journalSuggestion(_ remaining: String, current: String,
                                              recordCtx: String?) -> String {
        guard let recordCtx, current.hasPrefix(recordCtx) else { return remaining }
        return String(current.dropFirst(recordCtx.count)) + remaining
    }

    /// How much of the offered suggestion the user took before it resolved.
    /// Accepted / typed-through took all of it; otherwise what is no longer on
    /// screen (the record holds the whole offer, `remaining` the rest).
    nonisolated static func consumedChars(outcome: SuggestionJournal.Outcome, offered: String,
                                          remaining: String) -> Int {
        outcome == .accepted || outcome == .typedThrough
            ? offered.count : max(0, offered.count - remaining.count)
    }

    /// Pure half of `inject` (testable): the text before the caret once
    /// `deleteCount` backspaces and `text` have landed on `before` — nil when
    /// that can't be known.
    nonisolated static func textAfterInjection(_ text: String, deletingBackward deleteCount: Int,
                                               over before: String?) -> String? {
        guard let before, before.count >= deleteCount else { return nil }
        return before.dropLast(deleteCount) + text
    }

    /// Pure narrowing decision (testable): the suggestion remainder after the
    /// user typed `typed`, or nil when the keystroke invalidates it — control
    /// input (backspace, arrows, function keys), a diverging character, or
    /// typing through the suggestion's end.
    nonisolated static func narrowedSuggestion(_ text: String, typedCharacters typed: String) -> String? {
        guard !isControlInput(typed), typed.count < text.count, text.hasPrefix(typed) else { return nil }
        return String(text.dropFirst(typed.count))
    }

    /// Backspace, arrows, function keys (the private-use F7xx range) and
    /// other non-text input.
    nonisolated private static func isControlInput(_ typed: String) -> Bool {
        typed.unicodeScalars.contains {
            $0.value < 0x20 || $0.value == 0x7F || (0xF700...0xF8FF).contains($0.value)
        }
    }

    /// `keystrokeFallback`: only the keystroke's own re-read, for apps whose
    /// AX notifications don't come. It stands down when they did — both of
    /// the edit's notifications landed and a read ran after them, so it would
    /// repeat that read (each one a round of IPC the typed-in app's main
    /// thread answers). A retry riding on the same timer keeps it.
    func scheduleKeystrokeRefresh(after delay: TimeInterval = 0.06, keystrokeFallback: Bool = false) {
        guard !keyRefreshScheduled else {
            if !keystrokeFallback { keyRefreshIsFallback = false }
            return
        }
        keyRefreshScheduled = true
        keyRefreshIsFallback = keystrokeFallback
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.keyRefreshScheduled = false
            if self.keyRefreshIsFallback, self.axReadSinceKey { return }
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
              let ctx = AXText.context(for: element) else {
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
        // Roll the pipeline back with the text: the shrunk ghost, the live
        // stream and the advanced cache all still assume the chunk is in the
        // field — a Tab or a streamed partial landing before the 0.09 s AX
        // refresh would re-accept or resurrect the just-undone word.
        inject("", deletingBackward: accepted.count, over: ctx.textBeforeCaret)
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
        indicator.flashTransient(.hint(String(localized: "Undone")))
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
        // The cache advances in step with the injection (mirrors narrowActive
        // for user-typed keys). Until the 0.09 s AX refresh lands, a streamed
        // partial and the ⌘Z gate both read it — a stale marker re-arms the
        // just-accepted word (double insert on a second Tab) and makes an
        // immediate ⌘Z fall through to the app.
        lastAcceptedSnapshot = inject(chunk, over: latestTextBeforeCaret)
        // Count the suggestion once even when accepted word-by-word (chars still
        // accrue per chunk), so the menu's "accepted of shown" can't exceed 100%.
        Stats.recordAccepted(chunk: chunk, countSuggestion: !current.accepted,
                             app: typingContext.bundleID)
        current.accepted = true
        lastEvent = "accepted \"\(chunk)\""
        DebugLog.shared.log("ACCEPT", "\"\(chunk)\"")
        pendingJournal?.entry.acceptedChars += chunk.count
        if chunk.count >= current.text.count {
            retire(.accepted)
            // A fully-accepted suggestion ends its stream. Otherwise a later
            // partial re-mints `active` (with no recordShown), re-showing and
            // re-counting a continuation at the stale caret. The 0.09s refresh
            // below re-queries the extended context and re-streams cleanly.
            refreshTask?.cancel()
            refreshTask = nil
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
            onboardingWindow?.celebrate()
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
            TextInjector.pressReturn()
            latestTextBeforeCaret = nil
        }
        if before != nil, !inLauncher, !sends {
            lastAcceptedChunk = chunk
            // ⌘Z removes it exactly like an accepted suggestion — but the undo
            // path books what it removed, and this chunk was spoken.
            lastAcceptedWasDictated = true
            lastAcceptedSnapshot = snapshot
        }
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

    /// The spaces between what is already in the field and what was just
    /// dictated. Speech has no spacebar: the transcript always starts at a
    /// word, and the caret may be sitting right after one — "привет" spoken
    /// after "я сказал" must not land as "я сказалпривет" — or right *before*
    /// one, where "hello|world" would fuse the spoken tail into the word that
    /// follows. Nothing is added after whitespace or an opening bracket, and
    /// nothing before punctuation that belongs to the word it hugs; the right
    /// seam is the same rules mirrored. Both are decided here so the caller
    /// injects, caches and books ONE chunk — a trailing space added by a second
    /// insert would be missing from the cache and the undo snapshot.
    ///
    /// `following` defaults to empty because a caret at the end of the field
    /// has no right seam to judge, which is where dictation usually lands.
    nonisolated static func spacedForInsertion(_ text: String, after context: String,
                                               before following: String = "") -> String {
        // `isWhitespace` covers newlines too.
        func seam(_ last: Character?, _ first: Character?) -> Bool {
            guard let last, let first else { return false }
            return !last.isWhitespace && !first.isWhitespace
                && !"([{«“„<".contains(last) && !".,!?;:)]}»”…".contains(first)
                && !isScriptioContinua(last) && !isScriptioContinua(first)
        }
        return (seam(context.last, text.first) ? " " : "") + text + (seam(text.last, following.first) ? " " : "")
    }

    /// Han, kana, and the CJK/fullwidth punctuation that travels with them —
    /// scripts written without spaces between words, where a seam space is not
    /// a nicety but a typo the user then has to delete. Fullwidth punctuation
    /// carries its own side-bearing for the same reason, so "。" needs no space
    /// before it and "「" none after it. Hangul is deliberately absent: Korean
    /// orthography spaces its words like ours, so it takes the ordinary rules.
    nonisolated private static func isScriptioContinua(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        return scalar.properties.isIdeographic          // Han, every block
            || (0x3000...0x30FF).contains(scalar.value)  // CJK punctuation (、。「」), hiragana, katakana
            || (0xFF00...0xFFEF).contains(scalar.value)  // fullwidth and halfwidth forms (！？，)
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

    /// The prompt as the debug log shows it, OCR'd screen text and clipboard
    /// redacted: the log is exportable (bug reports), and both can hold OTHER
    /// people's text — it must never leave the process under the export
    /// warning's "text you typed" framing.
    nonisolated static func loggablePrompt(_ request: CompletionRequest) -> String {
        var redacted = request
        redacted.screenSummary = request.screenSummary.map {
            "[\($0.count) chars of on-screen text — redacted from log]"
        }
        redacted.clipboardContext = request.clipboardContext.map {
            "[\($0.count) chars of clipboard text — redacted from log]"
        }
        return redacted.completionPrompt(maxChars: 1000)
    }

    /// Leading spaces plus the first run of non-space characters.
    nonisolated static func firstWordChunk(of text: String) -> String {
        let lead = text.prefix { $0 == " " }
        return String(lead + text[lead.endIndex...].prefix { $0 != " " })
    }

}

// MARK: - Focus tracking (wired to `FocusTracker`'s handlers in `init`)

extension SuggestionController {
    private func focusDidChange() {
        // Apps fire the focus notification in duplicate bursts; identical
        // context + identical element means nothing actually changed.
        let newContext = focusTracker.typingContext
        let sameElement: Bool
        switch (focusTracker.focusedTextElement, lastFocusedElement) {
        case let (new?, old?): sameElement = CFEqual(new, old)
        case (nil, nil): sameElement = true
        default: sameElement = false
        }
        if newContext == trackedContext, sameElement { return }

        focusGeneration += 1
        lastFocusedElement = focusTracker.focusedTextElement
        lastCaretRect = nil
        lastHostStyle = HostTextStyle()
        // The overlay's remembered field style and the probe's pixel verdict
        // describe the field we just left; carried across they outrank what the
        // new field reports about itself (dark verdict from the previous app on
        // a white page — the same unreadable pill the tone resolver exists to
        // prevent).
        window.fieldChanged()
        correctionController.focusChanged()
        trackedContext = newContext
        fallbackSiteElement = nil
        fallbackSite = nil
        let policy = !AppPolicy.allowsCompletions(typingContext) ? " — suggestions off (blacklisted)"
            : AppPolicy.isTerminal(typingContext.bundleID) ? " — terminal, AI agent prompts only"
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
        // text (retry loop until the deadline) and the next keystroke would be
        // glued onto it.
        latestTextBeforeCaret = nil
        injectionSettleDeadline = nil
        // Examples anchored to the previous app's text go stale too; the next
        // keystroke in the new field re-retrieves immediately.
        personalExamples = []
        examplesRefreshedAt = .distantPast
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
        if let element = focusTracker.focusedTextElement, Settings.enabled,
           !AppPolicy.pausedForBattery, AppPolicy.allowsCompletions(typingContext),
           !Stats.isUnproductive(typingContext.bundleID) {
            // Entered a text field — start reloading the model now (no-op unless
            // it was idle-unloaded) so the first keystroke doesn't wait for it.
            engine.prewarmIfNeeded()
            if case .preparing = engine.state {
                if let ctx = AXText.context(for: element) {
                    lastCaretRect = ctx.caretRect
                    lastHostStyle = ctx.host
                    indicator.start()
                }
            }
            let generation = focusGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, self.focusGeneration == generation else { return }
                // An empty message box in a chat: the reply's own, wider
                // capture replaces the completion's.
                if Settings.autoReply, AppPolicy.isChat(self.typingContext), self.composeReply(auto: true) {
                    return
                }
                self.refreshScreenContextIfNeeded(typed: "")
                // No capture coming (context off, no permission, blocked app):
                // warm the new field's prompt now — its first keystroke would
                // otherwise prefill the whole text. A capture warms on landing.
                if !self.screenCaptureInFlight {
                    self.warmPromptForCurrentText(self.currentTextElement().flatMap {
                        AXText.context(for: $0)?.textBeforeCaret
                    })
                }
            }
        }
    }

    /// One edit posts two notifications ~0.1 ms apart (selection, then
    /// value) and the main queue drains between them: one short wait answers
    /// both with a single read instead of two identical ones.
    private func focusedTextDidChange(valueChanged: Bool) {
        if valueChanged { axSeenSinceKey.value = true } else { axSeenSinceKey.selection = true }
        guard !axRefreshScheduled else { return }
        axRefreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.004) { [weak self] in
            guard let self else { return }
            axRefreshScheduled = false
            let bothSeen = axSeenSinceKey.value && axSeenSinceKey.selection
            let reads = contextReads
            textDidChange()
            // Only a read that got the field stands in for the fallback: a
            // timed-out one (Electron) still wants its second chance.
            if bothSeen, contextReads != reads { axReadSinceKey = true }
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

// What dictation is allowed to see of this controller — the protocol keeps the
// capture state machine testable without an AX tree or a window server, and
// keeps `DictationController` from growing casual reach into the completion
// pipeline. `insertDictated`, `noteCaret`, `typingContext`, `focusGeneration`
// and `lastEvent` already satisfy their requirements above.
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

    func tidyDictation(_ text: String, before context: String) async -> String? {
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
