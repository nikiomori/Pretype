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
        guard let screenSummary, !screenSummary.isEmpty else { return text }
        // Label-free: for a base model the window text reads as the document
        // being continued (a chat log followed by the reply), which couples
        // the reply to the conversation more strongly than a labeled block.
        return "\(screenSummary)\n\n\(text)"
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

    /// Short live status for the diagnostics menu (model download progress,
    /// connection state, …).
    var statusLine: String? { get }

    /// Readiness, surfaced as an indicator at the caret.
    var state: EngineState { get }

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

    /// Returns a typo/grammar-fixed version of the selected text, or nil
    /// when there is nothing to fix.
    func correct(selection: String, request: CompletionRequest) async throws -> String?

    /// Live update of the user-tunable completion knobs (length, persona).
    /// Style/model changes rebuild the engine instead; these don't.
    func updateCompletion(length: CompletionLength, instructions: String)

    /// Live update of the favored-word biasing strength.
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
    var statusLine: String? { nil }
    var state: EngineState { .ready }
    var supportsCorrection: Bool { false }
    func correct(selection: String, request: CompletionRequest) async throws -> String? { nil }
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
