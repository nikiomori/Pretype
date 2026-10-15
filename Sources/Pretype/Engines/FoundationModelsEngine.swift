import Foundation
import FoundationModels

/// Completion via the system Apple Intelligence model (macOS 26+).
/// Zero download, zero app memory — the ~3B model is OS-managed and runs on
/// the Neural Engine. Quality differs from Gemma; it's the lightweight option.
/// Prompting recipe adapted from Cotabby's Foundation Models path.
final class FoundationModelsEngine: CompletionEngine {
    let name = "Apple Intelligence"

    private let stateBox = LockedValue<EngineState>(.preparing(String(localized: "starting…")))
    /// Single-flight guard: the session API rejects concurrent requests, so a
    /// fresh keystroke's request abstains while one is mid-flight (the caller
    /// cancels the prior task, so latest-wins still holds).
    private let inFlight = LockedValue<Bool>(false)
    private let lengthBox = LockedValue<CompletionLength>(.medium)
    private let instructionsBox = LockedValue<String>("")

    static let greedy = LockedValue<Bool>(false)

    var state: EngineState { stateBox.get() }

    var statusLine: String? {
        switch stateBox.get() {
        case .preparing(let detail): return "Apple Intelligence: \(detail)"
        case .ready: return String(localized: "Apple Intelligence: ready (system model)")
        case .failed(let detail): return "Apple Intelligence: \(detail)"
        }
    }

    /// Fix and reply are explicit requests: an unavailable model is said so
    /// (the status line carries why), never answered with "nothing to fix".
    private func requireReady() throws {
        guard case .ready = stateBox.get() else {
            throw EngineNotReady(message: String(localized: "Apple Intelligence isn't available — see the menu"))
        }
    }

    init() {
        switch SystemLanguageModel.default.availability {
        case .available:
            stateBox.set(.ready)
            // Warm the system model so the first keystroke doesn't pay.
            let session = LanguageModelSession(instructions: CompletionRequest.continuationDirective)
            session.prewarm()
        case .unavailable(let reason):
            // A sentence, not the enum case: this lands verbatim in the menu
            // header and the onboarding card ("unavailable: modelNotReady").
            let why: String
            switch reason {
            case .deviceNotEligible: why = String(localized: "this Mac doesn't support Apple Intelligence")
            case .appleIntelligenceNotEnabled: why = String(localized: "turn on Apple Intelligence in System Settings")
            case .modelNotReady: why = String(localized: "Apple Intelligence is still downloading — retry in a few minutes")
            @unknown default: why = String(localized: "Apple Intelligence is unavailable (\(String(describing: reason)))")
            }
            stateBox.set(.failed(why))
        }
    }

    func complete(_ request: CompletionRequest) async throws -> String? {
        guard case .ready = stateBox.get() else { return nil }
        // Atomic single-flight: test-and-set in one locked op so two concurrent
        // callers can't both acquire. Wait up to 200ms if a request is already
        // running (e.g. during cancellation cleanup of the previous task).
        // Re-setting true while the holder still runs is a harmless no-op.
        var limit = 0
        while inFlight.exchange(true) {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
            limit += 1
            if limit > 20 {
                return nil
            }
        }
        defer { inFlight.set(false) }

        // Lower the floor mid-word: a partial word ("apprecia…") is a strong,
        // safe constraint, so offer its completion even on short context — that
        // is exactly when whole-word prediction can't help yet.
        guard let prepared = PreparedPrompt(String(request.textBeforeCaret.suffix(1200)), request: request,
                                            midWordFloor: 5, boundaryFloor: 8) else { return nil }
        let turn = request.continuationTurn(prepared.text, instructions: instructionsBox.get())

        // A fresh session per request: autocomplete must not accumulate a
        // multi-turn transcript.
        let session = LanguageModelSession(instructions: turn.system)
        do {
            let response = try await session.respond(to: turn.user, options: generationOptions())
            try Task.checkCancellation()
            // The model answers flush and sometimes quoted, like any instruct model.
            return prepared.gate(cleanInstruct: true)(response.content)
        } catch let error as LanguageModelSession.GenerationError {
            // Apple's model declines some inputs — safety guardrails, rate limits
            // during fast typing, context-window or unsupported-language limits.
            // For an autocomplete these are a normal *abstain*, never a user-facing
            // error: log the reason (visible in the Debug Console) and offer
            // nothing, exactly like any other no-suggestion. (CancellationError is
            // not a GenerationError, so it still propagates and cancels cleanly.)
            DebugLog.shared.log("FM", "abstain — \(Self.reason(error))")
            return nil
        }
    }

    /// Decoding options: greedy for eval determinism, else Apple's default
    /// sampler. FM tokens run shorter than MLX's, so the budget carries a
    /// little headroom.
    private func generationOptions() -> GenerationOptions {
        let maxTokens = lengthBox.get().maxTokens + 8
        return Self.greedy.get()
            ? GenerationOptions(samplingMode: .greedy, maximumResponseTokens: maxTokens)
            : GenerationOptions(maximumResponseTokens: maxTokens)
    }

    func updateCompletion(length: CompletionLength, instructions: String) {
        lengthBox.set(length)
        instructionsBox.set(instructions)
    }

    func correct(selection: String, request: CompletionRequest,
                 redactLog: Bool) async throws -> String? {
        try requireReady()
        return try await CorrectionGates.fix(selection, redactLog: redactLog, logTag: "FM") {
            try await Self.respond(to: $0, maxTokens: $1, label: "fix")
        }
    }

    func reply(to conversation: String, request: CompletionRequest) async throws -> String? {
        try requireReady()
        return try await CorrectionGates.reply(to: conversation, request: request,
                                               instructions: instructionsBox.get()) {
            try await Self.respond(to: $0, maxTokens: $1, label: "reply")
        }
    }

    func rewrite(selection: String, instruction: String,
                 request: CompletionRequest) async throws -> String? {
        try requireReady()
        return try await CorrectionGates.rewrite(selection, instruction: instruction) {
            try await Self.respond(to: $0, maxTokens: $1, label: "voice command")
        }
    }

    /// One greedy turn in a fresh session, for fix, reply and voice commands —
    /// greedy so a fix stays faithful (no paraphrasing). A resource error
    /// (rate limit, concurrent request) throws, so the UI shows "fix failed"
    /// rather than "✓ looks fine" for a selection that may well be broken;
    /// any other decline is a no-op (nil), same as completion.
    private static func respond(to prompt: String, maxTokens: Int, label: String) async throws -> String? {
        do {
            return try await LanguageModelSession().respond(
                to: prompt, options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: maxTokens)
            ).content
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .rateLimited, .concurrentRequests:
                throw error
            default:
                DebugLog.shared.log("FM", "\(label) abstain — \(reason(error))")
                return nil
            }
        }
    }

    /// Short, log-friendly reason for an Apple Intelligence abstain: the case
    /// name only — the attached context is Apple's, not ours to vouch for in a
    /// log the dictation path promises never holds the spoken text.
    private static func reason(_ error: Error) -> Substring {
        "\(error)".prefix { $0 != "(" }
    }
}
