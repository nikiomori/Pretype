import AppKit

/// What the prompt context reads of the pipeline — `SuggestionController` in
/// the app, a fake in PromptContextTests.
@MainActor
protocol PromptContextHost: AnyObject {
    var typingContext: TypingContext { get }
    /// Bumped on every focus change: a capture or a retrieval finishing after
    /// one belongs to the field just left.
    var focusGeneration: Int { get }
    var lastCaretRect: CGRect? { get }
    var knownTextBeforeCaret: String? { get }
    /// Why the pipeline can start nothing now, or nil.
    var busyReason: String? { get }
    /// Completions are wanted in the app in front (`SuggestionController.completionsWelcome`).
    var completionsWelcome: Bool { get }
    var engine: CompletionEngine { get }
    /// The app whose window the OCR reads.
    var observedPID: pid_t { get }
    func currentTextElement() -> AXUIElement?
}

/// What a prompt carries beyond the field: the opt-in OCR of the focused
/// window, the opt-in clipboard, and the user's own accepted phrases most like
/// what is being typed. Each is refreshed off the typing path and sits at the
/// prompt's HEAD, so it changes only on a refresh — a change costs the
/// engine's whole KV cache, which `warm` re-reads in the background.
@MainActor
final class PromptContext {
    private unowned let host: any PromptContextHost
    private let env: SuggestionController.Environment

    init(host: any PromptContextHost, env: SuggestionController.Environment) {
        self.host = host
        self.env = env
    }

    // Opt-in OCR context of the focused window.
    private(set) var screenSummary: String?
    private var screenCapturedAt = Date.distantPast
    private(set) var screenCaptureInFlight = false

    /// An AI agent's last turn above its input box, read with the session's
    /// names at a message's first word (`SuggestionController.sessionNames`):
    /// the terminal's block where a chat has its OCR — a terminal gets none.
    var agentTurn: String?

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

    func makeRequest(text: String, after: String = "") -> CompletionRequest {
        let typingContext = host.typingContext
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
        } else {
            request.screenSummary = agentTurn
        }
        // Decided here, on the main thread, where NSSpellChecker is safe: lets the
        // engine offer a space + next word right after a finished word.
        request.endsOnCompleteWord = SpellChecker.endsOnCompleteWord(before: text, after: after)
        request.personalExamples = personalExamples
        return request
    }

    /// The focus moved: the old window's text and the examples anchored to
    /// the old app's text are stale. The next keystroke in the new field
    /// re-retrieves immediately.
    func focusChanged() {
        screenSummary = nil
        screenCapturedAt = .distantPast
        agentTurn = nil
        personalExamples = []
        examplesRefreshedAt = .distantPast
    }

    /// Retrieve the accepted phrases most similar to what's being typed, at
    /// most every 25 s and never on the keystroke path. The result set stays
    /// frozen between refreshes so the instruct prompt prefix — and with it the
    /// KV cache — survives incremental typing.
    func refreshExamplesIfNeeded(typed: String) {
        guard !examplesRefreshInFlight,
              typed.count >= 12,
              env.now().timeIntervalSince(examplesRefreshedAt) > 25 else { return }
        examplesRefreshInFlight = true
        let generation = host.focusGeneration
        let query = String(typed.suffix(300))
        let lookup = env.similarAcceptedPhrases
        Task.detached { [weak self] in
            let found = lookup(query)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.examplesRefreshInFlight = false
                guard self.host.focusGeneration == generation else { return }
                self.examplesRefreshedAt = self.env.now()
                guard found != self.personalExamples else { return }
                self.personalExamples = found
                self.warm()
                DebugLog.shared.log(
                    "PROMPT", "personal examples: \(found.count)",
                    detail: found.map { "…\($0.ctx) ⟶\($0.next)" }.joined(separator: "\n"))
            }
        }
    }

    /// Clipboard text for the prompt, re-read only when the pasteboard
    /// changes (reading a multi-MB copy per keystroke would hurt). Concealed
    /// and transient contents — password managers mark both — are never read.
    /// The read itself can stall (a huge or lazily-provided copy): never call
    /// this — or `makeRequest` — inside the event-tap callback.
    private func currentClipboardContext() -> String? {
        let pasteboard = env.pasteboard
        if pasteboard.changeCount != clipboardChangeCount {
            clipboardChangeCount = pasteboard.changeCount
            let concealed = pasteboard.types?.contains {
                $0.rawValue == "org.nspasteboard.ConcealedType"
                    || $0.rawValue == "org.nspasteboard.TransientType"
            } ?? false
            clipboardSnippet = concealed ? nil
                : pasteboard.string(forType: .string).flatMap(SuggestionController.clipboardSnippet)
        }
        return clipboardSnippet
    }

    /// The screen block and the retrieved examples sit at the HEAD of the
    /// prompt, so their refresh invalidates the engine's whole KV cache. Have
    /// the engine re-read the prompt now, in the background, rather than on
    /// the next keystroke (where a cold prefill measured ~0.45 s on E4B-8bit).
    func warm(_ typed: String? = nil) {
        guard host.busyReason == nil, host.completionsWelcome,
              let text = typed ?? host.knownTextBeforeCaret,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        host.engine.warmPrompt(for: makeRequest(text: text))
    }

    /// A ⌘-chord may have been a copy (⌘C/⌘X, any layout): the clipboard block
    /// also sits at the prompt's head, so a changed clipboard is warmed the
    /// same way as a screen refresh. The check is a counter compare; the
    /// pasteboard is only read (by `makeRequest`) when it moved.
    func warmIfClipboardChanges() {
        guard Settings.clipboardContextEnabled, AppPolicy.allowsScreenContext(host.typingContext) else { return }
        let before = env.pasteboard.changeCount
        env.after(0.15) { [weak self] in
            guard let self, self.env.pasteboard.changeCount != before else { return }
            // A ⌘-chord drops the synchronous text cache; read the field for
            // this warm-up only (the cache keeps its own refresh rules).
            let text = self.host.knownTextBeforeCaret ?? self.host.currentTextElement().flatMap {
                self.env.context(of: $0)?.textBeforeCaret
            }
            self.warm(text)
        }
    }

    /// Surfaced in the Context submenu.
    var screenStatus: String {
        guard Settings.screenContextEnabled else { return "off" }
        guard env.screenRecordingAllowed() else {
            return "no Screen Recording permission (grant + relaunch)"
        }
        guard AppPolicy.allowsScreenContext(host.typingContext) else {
            return "blocked in this app (terminal/code editor)"
        }
        if let screenSummary { return "captured \(screenSummary.count) chars" }
        return screenCaptureInFlight ? "capturing…" : "nothing captured yet"
    }

    /// Refreshes the window OCR at most every 25 s, off the typing path.
    /// Paused on battery: the capture only feeds completions (a reply takes
    /// its own fresh one), and its landing would warm a prompt nobody runs.
    func refreshScreenIfNeeded(typed: String) {
        let typingContext = host.typingContext
        guard Settings.enabled, Settings.screenContextEnabled, env.screenRecordingAllowed(),
              !env.pausedForBattery(), AppPolicy.allowsScreenContext(typingContext) else { return }
        guard !screenCaptureInFlight,
              env.now().timeIntervalSince(screenCapturedAt) > 25,
              host.observedPID > 0 else { return }
        screenCaptureInFlight = true
        let pid = host.observedPID
        let generation = host.focusGeneration
        let appName = typingContext.appName ?? "?"
        let caret = host.lastCaretRect
        let capture = env.captureScreen
        Task { [weak self] in
            let summary = await capture(pid, typed, caret, ScreenContext.defaultMaxChars)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.screenCaptureInFlight = false
                guard self.host.focusGeneration == generation else {
                    DebugLog.shared.log("OCR", "discarded stale capture of \(appName) (focus changed)")
                    return
                }
                // The first capture after a focus change warms even when it
                // found nothing: the new field's prompt is cold either way.
                let changed = summary != self.screenSummary || self.screenCapturedAt == .distantPast
                self.screenCapturedAt = self.env.now()
                self.screenSummary = summary
                if changed { self.warm() }
                // Count only, never the text: the log is exportable and this is
                // OTHER people's on-screen text. Passing it as `detail` here
                // leaked it straight past the prompt log's redaction, and past
                // the export warning's "text you typed" framing.
                DebugLog.shared.log(
                    "OCR",
                    summary.map { "captured \($0.count) chars (\(appName))" } ?? "nothing usable captured (\(appName))"
                )
            }
        }
    }
}

extension SuggestionController: PromptContextHost {}
