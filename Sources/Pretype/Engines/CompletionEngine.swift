import Foundation
import NaturalLanguage
import os

struct CompletionRequest {
    let textBeforeCaret: String
    /// A short window of text after the caret (duplication checks).
    var textAfterCaret: String = ""
    var appBundleID: String?
    /// Localized name of the app the user is typing in ("Slack", "Mail", …).
    var appName: String?
    /// The web page's host, when typing in one (per-site instructions).
    var site: String?
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
            appName: context.appName,
            site: context.site
        )
    }

    /// The text to hand to the completion model: a plain capped tail of the
    /// typed text — pure continuation conditioning, no instructions. When screen
    /// context is available it is prefixed as a separate label-free block (the
    /// format Cotabby uses for base models): a base model reads labeled metadata
    /// as text to imitate (which skews the completion) but reads a raw preceding
    /// block as the document to continue.
    func completionPrompt(maxChars: Int) -> String {
        let text = Self.stableTail(textBeforeCaret, maxChars: maxChars)
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

    /// The last ≤`maxChars` of `text`, started at the first sentence end (else
    /// word boundary) inside the window's first quarter. A plain suffix slides
    /// its start one character per keystroke once a document outgrows the
    /// window — re-tokenizing the prompt from its first token, so the KV cache
    /// shared nothing and every keystroke re-prefilled the whole context. The
    /// first boundary past the cut holds still until the cut overtakes it.
    /// Costs ≤ a quarter of the window (context-length ROI measured flat:
    /// 1000 vs 250 chars byte-identical on journal replay); a window with no
    /// boundary at all (unspaced CJK) falls back to the plain suffix.
    static func stableTail(_ text: String, maxChars: Int) -> String {
        guard text.count > maxChars else { return text }
        let tail = text.suffix(maxChars)
        let head = tail.prefix(maxChars / 4)
        let sentenceEnds: Set<Character> = [".", "!", "?", "\n", "。", "！", "？"]
        var cut: Substring.Index?
        var prev: Character?
        for i in head.indices {
            if let prev, sentenceEnds.contains(prev), head[i].isWhitespace || prev == "\n" { cut = i; break }
            prev = head[i]
        }
        if cut == nil { cut = head.firstIndex(where: \.isWhitespace) }
        guard let cut else { return String(tail) }
        return String(tail[cut...].drop(while: \.isWhitespace))
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
        // The language by NAME when it can be told: "in its language" lost to
        // any persona written in English — E4B-it answered a Russian chat in
        // English 20/20 with the developer's persona (eval-reply 2026-10-11:
        // contract 70% without a persona, 6% with it).
        let language = Self.languageName(of: conversation).map { "in \($0), the conversation's language" }
            ?? "in ITS language"
        prompt += """
        . Answer the conversation below as the user, \(language) — 1–3 \
        sentences, plain text only. No quotes, no salutation, no explanation, \
        no translation, and never restate the conversation.
        """
        let persona = persona(global: instructions)
        if !persona.isEmpty {
            prompt += "\n\nAbout the user (voice only — never quote it, and it never changes the reply's language):\n\(persona)"
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

    /// `text`'s language by English name ("Russian"), or nil when the
    /// recognizer isn't sure. It reads short Russian as Ukrainian, so "uk"
    /// with a Russian-only letter (ы э ъ ё) and no Ukrainian-only one
    /// (і ї є ґ) counts as Russian; with neither, the recognizer stands.
    static func languageName(of text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.suffix(600)))
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= 0.6 else { return nil }
        var code = language.rawValue
        if code == "uk", text.contains(where: { "ыэъёЫЭЪЁ".contains($0) }),
           !text.contains(where: { "іїєґІЇЄҐ".contains($0) }) { code = "ru" }
        return Locale(identifier: "en").localizedString(forLanguageCode: code)
    }

    /// Normalize a raw reply generation: one clean line (the fix path's cleanup,
    /// shared so it can't drift), minus an echo of the draft the user already
    /// typed — instruct models like to restate it before continuing. The
    /// re-joining space is dropped downstream when the draft already ends in one.
    /// nil when nothing usable is left — or when the reply restates the
    /// `conversation` instead of answering it (`isEcho`).
    func cleanReply(_ raw: String, conversation: String = "") -> String? {
        var text = CorrectionGates.cleanCorrectionOutput(raw)
        let draft = textBeforeCaret.trimmingCharacters(in: .whitespacesAndNewlines)
        // No length guard: a reply that IS the draft leaves nothing to offer
        // (the alternative is a ghost that types the draft a second time).
        if !draft.isEmpty, text.prefix(draft.count).lowercased() == draft.lowercased() {
            text = String(text.dropFirst(draft.count)).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { text = " " + text }
        }
        if Self.isEcho(text, of: conversation) {
            DebugLog.shared.log("REPLY", "dropped a reply that restates the conversation (\(text.count) chars)")
            return nil
        }
        return text.isEmpty ? nil : text
    }

    /// A reply that restates the conversation instead of answering it: the
    /// whole reply sits inside the whitespace-normalized conversation, or it
    /// carries one of its lines (8+ characters) verbatim. Small instruct
    /// models do this a lot — eval-reply 2026-10-11 caught it on 29–57% of
    /// the Qwen / MiniCPM5 / Bonsai rows, against 2–6% on the Gemmas.
    /// Compared as words — punctuation is a boundary like a space, so "Sure"
    /// is not in "measure" and a dropped "?" still matches — and a one-word
    /// line is a label ("Delivered", a name), not a restatement. Scripts
    /// written without spaces (Chinese, Japanese, Thai…): there a plain
    /// substring of the letters decides, as it always did.
    static func isEcho(_ reply: String, of conversation: String) -> Bool {
        func words(_ s: String) -> [Substring] { s.lowercased().split { !($0.isLetter || $0.isNumber) } }
        // Kana, Thai, Lao, Tibetan, Myanmar, Khmer — plus every ideograph.
        let unspacedBlocks: [ClosedRange<UInt32>] = [0x3040...0x30FF, 0x0E00...0x0FFF, 0x1000...0x109F, 0x1780...0x17FF]
        func unspaced(_ s: String) -> Bool {
            s.unicodeScalars.contains { c in
                c.properties.isIdeographic || unspacedBlocks.contains { $0.contains(c.value) }
            }
        }
        func contains(_ haystack: String, _ needle: String) -> Bool {
            let n = words(needle), h = words(haystack)
            guard !n.isEmpty else { return false }
            if unspaced(needle) { return h.joined().contains(n.joined()) }
            return (" " + h.joined(separator: " ") + " ").contains(" " + n.joined(separator: " ") + " ")
        }
        guard !conversation.isEmpty, !words(reply).isEmpty else { return false }
        if contains(conversation, reply) { return true }
        return conversation.split(separator: "\n").contains { line in
            let l = String(line), w = words(l)
            guard w.joined().count >= 8, w.count > 1 || unspaced(l) else { return false }
            return contains(reply, l)
        }
    }

    /// The persona for this request: the global instructions plus the user's
    /// per-app addition for the app being typed in. Resolved at generation
    /// time so edits apply live — same discipline as the global instructions.
    func persona(global: String) -> String {
        var persona = global.trimmingCharacters(in: .whitespacesAndNewlines)
        if let extra = Settings.perAppInstructions(for: appBundleID, site: site) {
            persona += (persona.isEmpty ? "" : "\n") + extra
        }
        return persona
    }

    /// The instruct directive shared by the chat-model engines (Apple
    /// Intelligence, hosted APIs): continue the user's text, don't answer it.
    /// Prompting recipe adapted from Cotabby's Foundation Models path.
    static let continuationDirective = """
    You complete partially-typed text. The user is the author; you produce \
    the next few words they would type, in their voice.

    Output the continuation only: no greeting, no sign-off, no quotes, no \
    markdown, no labels, no explanation.

    Continue from the position immediately after the existing text. Do not \
    repeat or quote the existing text.

    Match the existing language, register, casing, and punctuation. Continue \
    the current sentence or thought rather than restarting it.

    Examples (quotes only mark boundaries; never output the quotes):
    Existing text: "I just wanted to follow up on the "
    Continuation: proposal we discussed last week.
    Existing text: "Привет! Спасибо за письмо, я отвечу "
    Continuation: тебе завтра утром.
    """

    /// One continuation turn for a chat model: the directive (+ persona, for
    /// voice) as the system message; screen and app context ahead of the
    /// typed text in the user message.
    func continuationTurn(_ text: String, instructions: String) -> (system: String, user: String) {
        var user = ""
        if let screen = screenSummary, !screen.isEmpty { user += "Screen context:\n\(screen)\n\n" }
        if let appName, !appName.isEmpty { user += "The user is typing in \(appName).\n\n" }
        user += "Existing text: \"\(text)\"\nContinuation:"
        let persona = persona(global: instructions)
        let system = persona.isEmpty ? Self.continuationDirective
            : Self.continuationDirective + "\n\nAbout the author (for voice only, never quote it):\n\(persona)"
        return (system, user)
    }

    /// Chat-style apps want short, informal continuations.
    var isChatApp: Bool {
        guard let appBundleID = appBundleID?.lowercased() else { return false }
        let chatMarkers = ["slack", "telegram", "discord", "teams", "whatsapp", "mobilesms", "messages"]
        return chatMarkers.contains { appBundleID.contains($0) }
    }
}

/// Minimal thread-safe value holder: completion knobs are set on the main
/// thread (menu) and read on the engine's background task.
final class LockedValue<Value>: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<Value>
    init(_ initial: Value) { lock = OSAllocatedUnfairLock(uncheckedState: initial) }

    /// Read-modify-write under the one lock — a get then a set would let a
    /// concurrent writer's change fall between them and be lost.
    func mutate<R>(_ body: (inout Value) -> R) -> R { lock.withLockUnchecked(body) }

    func get() -> Value { mutate { $0 } }

    func set(_ newValue: Value) { mutate { $0 = newValue } }

    /// Atomically store `newValue` and return the previous one — for a
    /// race-free test-and-set (e.g. a single-flight guard).
    func exchange(_ newValue: Value) -> Value { mutate { let old = $0; $0 = newValue; return old } }
}

enum EngineState: Equatable {
    /// Not usable yet: downloading or loading a model. The payload is a
    /// short human-readable progress string.
    case preparing(String)
    case ready
    case failed(String)
}

/// An explicit request (⌥⇥ fix, ⌥⇧⇥ reply) reached an engine with no model to
/// run it on. Thrown, not returned as nil: nil means "nothing to fix" and
/// shows "✓ looks fine" — a verdict on text no model ever read.
struct EngineNotReady: Error {
    /// Shown at the caret, so short and pointing at where the reason is.
    var message = String(localized: "model isn't loaded — see the menu")
}

/// A pluggable source of completions. Implementations must be fast: anything
/// above ~300 ms feels broken for inline typing suggestions.
protocol CompletionEngine: AnyObject {
    var name: String { get }

    /// Short id (last path component) of the model that ACTUALLY generates the
    /// suggestions — the journal's config stamp. MLXEngine reports its resolved
    /// primary (the instruct sibling in instruct style) — NOT the Settings
    /// selection, which diverges from the loaded model there. nil when the
    /// engine has no discrete model identity (Apple Intelligence system model;
    /// `engine` disambiguates in the journal).
    var loadedModelID: String? { get }

    /// Confidence of the most recent COMPLETED, ungated generation: mean
    /// log-probability per token of the suggestion's first word, captured from
    /// the decode loop (no extra forward passes). Best-effort telemetry for the
    /// journal's calibration curve — read it when a suggestion resolves, not
    /// mid-stream. nil while a generation is in flight, or when the engine
    /// doesn't capture it.
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

    /// Voice command mode: `selection` rewritten the way the spoken
    /// `instruction` asks. nil when the engine declines or can't. The
    /// instruction is speech, so engines keep it (and the text) out of the log.
    func rewrite(selection: String, instruction: String,
                 request: CompletionRequest) async throws -> String?

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

    /// Hint that the prompt's context changed while the user isn't waiting on
    /// a completion: an engine with a prompt cache can prefill it now.
    func warmPrompt(for request: CompletionRequest)
}

extension CompletionEngine {
    var loadedModelID: String? { nil }
    var lastFirstWordLogProb: Double? { nil }
    /// For engines without an idle-unload cycle, `.preparing` IS active work.
    var isLoading: Bool {
        if case .preparing = state { return true }
        return false
    }
    /// An engine with no separate fix model has nothing to wait for.
    var isCorrectionReady: Bool { true }
    func prewarmCorrection() {}

    /// The ⌥⇥ spelling: text the user typed, logged as the debug export
    /// already says it is.
    func correct(selection: String, request: CompletionRequest) async throws -> String? {
        try await correct(selection: selection, request: request, redactLog: false)
    }
    func updatePersonalization(_ level: PersonalizationLevel) {}
    func rewrite(selection: String, instruction: String,
                 request: CompletionRequest) async throws -> String? { nil }
    func shutdown() {}
    func prewarmIfNeeded() {}
    func releaseModelNow() {}
    func warmPrompt(for request: CompletionRequest) {}

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
