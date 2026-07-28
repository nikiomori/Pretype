import Foundation

struct CompletionRequest {
    let textBeforeCaret: String
    /// A short window of text after the caret (duplication checks).
    var textAfterCaret: String = ""
    var appBundleID: String?
    /// Localized name of the app the user is typing in ("Slack", "Mail", …).
    var appName: String?
    /// OCR text from the focused window (opt-in), e.g. the conversation
    /// above a chat input.
    var screenSummary: String?
    /// Current clipboard text (opt-in, capped) — what's being replied to is
    /// often just-copied. Prefixed to the prompt like the screen block.
    var clipboardContext: String?
    /// Retrieval-augmented few-shot: the user's own past accepted phrases most
    /// similar to the current context, injected into the instruct directive as
    /// style/phrasing examples. Refreshed off the typing path (like the screen
    /// context) so the prompt prefix stays stable for the KV cache.
    var personalExamples: [SuggestionJournal.AcceptedPhrase] = []
    /// Whether the caret sits right after a complete word (vs. mid-prefix).
    /// Computed on the main thread — `NSSpellChecker` isn't documented as
    /// background-safe — and read by the engines' output gate to decide whether
    /// a space-led new-word suggestion is allowed. `nil` ⇒ not precomputed (the
    /// dev/eval harness builds requests off the main thread); the engine then
    /// computes it itself.
    var endsOnCompleteWord: Bool?
}

extension CompletionRequest {
    init(textBeforeCaret: String, textAfterCaret: String = "", context: TypingContext) {
        self.init(
            textBeforeCaret: textBeforeCaret,
            textAfterCaret: textAfterCaret,
            appBundleID: context.bundleID,
            appName: context.appName
        )
    }

    /// The text to hand to the completion model: a plain capped tail of the
    /// typed text — pure continuation conditioning, no instructions. When screen
    /// context is available it is prefixed as a separate label-free block (the
    /// format Cotabby uses for base models): a base model reads labeled metadata
    /// as text to imitate (which skews the completion) but reads a raw preceding
    /// block as the document to continue.
    func completionPrompt(maxChars: Int) -> String {
        let text = String(textBeforeCaret.suffix(maxChars))
        guard !text.isEmpty else { return "" }
        // Label-free: for a base model the window text reads as the document
        // being continued (a chat log followed by the reply), which couples
        // the reply to the conversation more strongly than a labeled block.
        // The screen block stays adjacent to the typed text; the clipboard
        // reads as an earlier fragment.
        let blocks = [clipboardContext, screenSummary].compactMap { $0 }.filter { !$0.isEmpty }
        guard !blocks.isEmpty else { return text }
        return (blocks + [text]).joined(separator: "\n\n")
    }

    /// Retrieved accepted phrases as one label-free block — the base path
    /// prepends it to the encoded prompt so the examples read as earlier
    /// fragments of the document being continued (same format as the screen
    /// block), pulling the continuation toward the user's own phrasing. Kept
    /// OUT of `completionPrompt` deliberately: the preamble must not satisfy
    /// the context floor, flip the language gate, or feed the n-gram context —
    /// those all reason about the user's text. The instruct path injects the
    /// same examples into its directive instead. ctx+next verbatim: next is
    /// literally what followed ctx when the user accepted it.
    var personalPreambleBlock: String? {
        guard !personalExamples.isEmpty else { return nil }
        return personalExamples.prefix(3).map { $0.ctx + $0.next }.joined(separator: "\n")
    }

    /// Prompt for the reply hotkey: the model writes the user's next message
    /// itself from the conversation OCR'd off the screen. Written as an
    /// instruction (not as text to continue) — it rides the engines' chat
    /// templates, the same path the ⌥⇥ fix uses.
    func replyPrompt(conversation: String, instructions: String) -> String {
        var prompt = "You are writing the next message the user will send"
        if let appName, !appName.isEmpty { prompt += " in \(appName)" }
        prompt += """
        . Answer the conversation below as the user, in ITS language — 1–3 \
        sentences, plain text only. No quotes, no salutation, no explanation, \
        no translation, and never restate the conversation.
        """
        let persona = persona(global: instructions)
        if !persona.isEmpty {
            prompt += "\n\nAbout the user (voice only, never quote it):\n\(persona)"
        }
        prompt += "\n\nConversation on screen:\n\(conversation)"
        let draft = textBeforeCaret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !draft.isEmpty {
            prompt += """


            The user has already started the message: "\(String(draft.suffix(200)))"
            Continue it — reply with ONLY the words that come after it.
            """
        }
        return prompt
    }

    /// Normalize a raw reply generation: one clean line (the fix path's cleanup,
    /// shared so it can't drift), minus an echo of the draft the user already
    /// typed — instruct models like to restate it before continuing. The
    /// re-joining space is dropped downstream when the draft already ends in one.
    /// nil when nothing usable is left.
    func cleanReply(_ raw: String) -> String? {
        var text = CorrectionGates.cleanCorrectionOutput(raw)
        let draft = textBeforeCaret.trimmingCharacters(in: .whitespacesAndNewlines)
        // No length guard: a reply that IS the draft leaves nothing to offer
        // (the alternative is a ghost that types the draft a second time).
        if !draft.isEmpty, text.prefix(draft.count).lowercased() == draft.lowercased() {
            text = String(text.dropFirst(draft.count)).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { text = " " + text }
        }
        return text.isEmpty ? nil : text
    }

    /// The persona for this request: the global instructions plus the user's
    /// per-app addition for the app being typed in. Resolved at generation
    /// time so edits apply live — same discipline as the global instructions.
    func persona(global: String) -> String {
        var persona = global.trimmingCharacters(in: .whitespacesAndNewlines)
        if let extra = Settings.perAppInstructions(for: appBundleID) {
            persona += (persona.isEmpty ? "" : "\n") + extra
        }
        return persona
    }

    /// Chat-style apps want short, informal continuations.
    var isChatApp: Bool {
        guard let appBundleID = appBundleID?.lowercased() else { return false }
        let chatMarkers = ["slack", "telegram", "discord", "teams", "whatsapp", "mobilesms", "messages"]
        return chatMarkers.contains { appBundleID.contains($0) }
    }
}

/// Thread-safe engine-state holder shared by engine implementations.
final class StateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: EngineState = .preparing("starting…")

    func set(_ newValue: EngineState) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> EngineState {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Minimal thread-safe value holder: completion knobs are set on the main
/// thread (menu) and read on the engine's background task.
final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ initial: Value) { value = initial }

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    /// Atomically store `newValue` and return the previous one — for a
    /// race-free test-and-set (e.g. a single-flight guard).
    func exchange(_ newValue: Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        let old = value
        value = newValue
        return old
    }
}

enum EngineState: Equatable {
    /// Not usable yet: downloading or loading a model. The payload is a
    /// short human-readable progress string.
    case preparing(String)
    case ready
    case failed(String)
}

/// A pluggable source of completions. Implementations must be fast: anything
/// above ~300 ms feels broken for inline typing suggestions.
protocol CompletionEngine: AnyObject {
    var name: String { get }

    /// Short id (last path component) of the model that ACTUALLY generates the
    /// suggestions — the journal's config stamp. MLXEngine reports its resolved
    /// primary (the instruct sibling in instruct style, a fine-tune's directory
    /// name for local models) — NOT the Settings selection, which diverges from
    /// the loaded model in both those cases. nil when the engine has no discrete
    /// model identity (Apple Intelligence system model; `engine` disambiguates
    /// in the journal).
    var loadedModelID: String? { get }

    /// Confidence of the most recent COMPLETED, ungated generation: mean
    /// log-probability per token of the suggestion's first word, captured from
    /// the decode loop (no extra forward passes). Best-effort telemetry for the
    /// journal's calibration curve — read it when a suggestion resolves, not
    /// mid-stream. nil while a generation is in flight, under the K-sample
    /// gate, or when the engine doesn't capture it.
    var lastFirstWordLogProb: Double? { get }

    /// Short live status for the diagnostics menu (model download progress,
    /// connection state, …).
    var statusLine: String? { get }

    /// Readiness, surfaced as an indicator at the caret.
    var state: EngineState { get }

    /// A model load or download is actually in flight. NOT derivable from
    /// `state` alone: MLXEngine's idle-unloaded resting state also reports
    /// `.preparing`, with no task behind it and nothing touching the disk
    /// cache — and that is the one state where deleting cached weights is
    /// safest, so a gate keyed on `.preparing` would disable it exactly when
    /// it should be allowed.
    var isLoading: Bool { get }

    /// Returns the text that should appear after the caret, or nil.
    /// If the context ends mid-word, the result must start with the remainder
    /// of that word; if it ends with a space, with the next word.
    func complete(_ request: CompletionRequest) async throws -> String?

    /// Streams progressively longer continuations as the model decodes. Each
    /// element is a fully-gated suggestion snapshot (same gates as `complete`);
    /// the last element is the final answer. An engine that can't stream yields
    /// once. This lets the UI show the first word after ~one token instead of
    /// waiting for the whole generation — the dominant cost on slow machines.
    func completions(for request: CompletionRequest) -> AsyncThrowingStream<String, Error>

    /// Whether `correct(selection:request:)` does anything.
    var supportsCorrection: Bool { get }

    /// Whether `correct` can run *now* without first fetching a model. False
    /// means the call would block on a download — which the dictation tidy-up
    /// pass, on a three-second budget, could never wait out anyway.
    var isCorrectionReady: Bool { get }

    /// Start loading whatever `correct` needs, in the background. Called by a
    /// caller that just declined to wait for it, so the next one doesn't have
    /// to decline too.
    func prewarmCorrection()

    /// Returns a typo/grammar-fixed version of the selected text, or nil
    /// when there is nothing to fix.
    ///
    /// `redactLog` keeps the text itself out of the debug log — lengths only.
    /// The caller knows what the text IS and the engine cannot: a ⌥⇥ fix works
    /// on words the user typed, which the log export already declares, while
    /// the dictation tidy-up pass is handed a spoken sentence, which
    /// `docs/privacy.md` promises never reaches the log.
    func correct(selection: String, request: CompletionRequest,
                 redactLog: Bool) async throws -> String?

    /// Composes the user's whole next message from the conversation on screen
    /// (the reply hotkey), instead of continuing what they typed. nil when the
    /// engine declines — or can't do it at all.
    func reply(to conversation: String, request: CompletionRequest) async throws -> String?

    /// Live update of the user-tunable completion knobs (length, persona).
    /// Style/model changes rebuild the engine instead; these don't.
    func updateCompletion(length: CompletionLength, instructions: String)

    /// Live update of the personal n-gram boost strength.
    func updatePersonalization(_ level: PersonalizationLevel)

    /// Flush state before the engine is released or the app quits.
    func shutdown()

    /// Hint that the user is about to type (focus gained / keystroke): an engine
    /// that idle-unloads its model can start reloading now to hide the latency.
    func prewarmIfNeeded()

    /// Free any resident model now (manual / menu-triggered); reload on next use.
    func releaseModelNow()
}

extension CompletionEngine {
    var loadedModelID: String? { nil }
    var lastFirstWordLogProb: Double? { nil }
    var statusLine: String? { nil }
    var state: EngineState { .ready }
    /// For engines without an idle-unload cycle, `.preparing` IS active work.
    var isLoading: Bool {
        if case .preparing = state { return true }
        return false
    }
    var supportsCorrection: Bool { false }
    /// An engine with no separate fix model has nothing to wait for.
    var isCorrectionReady: Bool { supportsCorrection }
    func prewarmCorrection() {}
    func correct(selection: String, request: CompletionRequest,
                 redactLog: Bool) async throws -> String? { nil }

    /// The ⌥⇥ spelling: text the user typed, logged as the debug export
    /// already says it is.
    func correct(selection: String, request: CompletionRequest) async throws -> String? {
        try await correct(selection: selection, request: request, redactLog: false)
    }
    func reply(to conversation: String, request: CompletionRequest) async throws -> String? { nil }
    func updateCompletion(length: CompletionLength, instructions: String) {}
    func updatePersonalization(_ level: PersonalizationLevel) {}
    func shutdown() {}
    func prewarmIfNeeded() {}
    func releaseModelNow() {}

    /// One-shot fallback: drive `complete` and yield its single result. Engines
    /// that decode token-by-token override this to stream partials.
    func completions(for request: CompletionRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let result = try await complete(request) { continuation.yield(result) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
