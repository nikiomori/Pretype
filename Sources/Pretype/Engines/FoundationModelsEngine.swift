import Foundation
import FoundationModels

/// Completion via the system Apple Intelligence model (macOS 26+).
/// Zero download, zero app memory — the ~3B model is OS-managed and runs on
/// the Neural Engine. Quality differs from Gemma; it's the lightweight option.
/// Prompting recipe adapted from Cotabby's Foundation Models path.
final class FoundationModelsEngine: CompletionEngine {
    let name = "Apple Intelligence"

    /// Fixed at init: availability is read once, like a model load.
    let state: EngineState
    private let lengthBox = LockedValue<CompletionLength>(.medium)
    private let instructionsBox = LockedValue<String>("")

    /// Greedy, the decoder every booked Apple Intelligence number was measured
    /// with (`ModelMetrics`, the kana/han/hangul silence). Apple's default
    /// sampler picked a less likely word some of the time — worse for
    /// predicting what the user types next, and no figure described it.
    static let greedy = LockedValue<Bool>(true)

    var statusLine: String? {
        switch state {
        case .ready: return String(localized: "Apple Intelligence: ready (system model)")
        case .preparing(let detail), .failed(let detail): return "Apple Intelligence: \(detail)"
        }
    }

    /// Fix and reply are explicit requests: an unavailable model is said so
    /// (the status line carries why), never answered with "nothing to fix".
    private func requireReady() throws {
        guard case .ready = state else {
            throw EngineNotReady(message: String(localized: "Apple Intelligence isn't available — see the menu"))
        }
    }

    /// `availability`: the system model's; tests pin it.
    init(availability: SystemLanguageModel.Availability = SystemLanguageModel.default.availability) {
        switch availability {
        case .available:
            state = .ready
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
            state = .failed(why)
        }
    }

    private let silentScripts = ModelCatalog.silentScripts(for: ModelCatalog.appleIntelligenceID)

    func complete(_ request: CompletionRequest) async throws -> String? {
        guard case .ready = state else { return nil }
        if let script = GateScript.of(request.textBeforeCaret), silentScripts.contains(script) { return nil }

        // Lower the floor mid-word: a partial word ("apprecia…") is a strong,
        // safe constraint, so offer its completion even on short context — that
        // is exactly when whole-word prediction can't help yet.
        guard let prepared = PreparedPrompt(String(request.textBeforeCaret.suffix(1200)), request: request,
                                            midWordFloor: 5, boundaryFloor: 8) else { return nil }
        let turn = request.continuationTurn(prepared.text, instructions: instructionsBox.get())

        // A fresh session per request: autocomplete must not accumulate a
        // multi-turn transcript, and separate sessions take overlapping
        // requests (a cancelled keystroke's still winding down) — probed
        // 2026-10-16: 3 and 6 at once all answered.
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

    /// Decoding options: greedy (`greedy`), else Apple's default sampler. FM tokens run shorter than MLX's, so the budget carries a
    /// little headroom.
    private func generationOptions() -> GenerationOptions {
        let maxTokens = lengthBox.get().maxTokens + 8
        return Self.greedy.get()
            ? Self.greedyOptions(maxTokens: maxTokens)
            : GenerationOptions(maximumResponseTokens: maxTokens)
    }

    /// Greedy decoding in both SDKs' spelling: Xcode 26 (CI) has only
    /// `sampling:`, Xcode 27 renamed it `samplingMode:` and deprecated the old.
    private static func greedyOptions(maxTokens: Int) -> GenerationOptions {
        #if compiler(>=6.4)
        GenerationOptions(samplingMode: .greedy, maximumResponseTokens: maxTokens)
        #else
        GenerationOptions(sampling: .greedy, maximumResponseTokens: maxTokens)
        #endif
    }

    func updateCompletion(length: CompletionLength, instructions: String) {
        lengthBox.set(length)
        instructionsBox.set(instructions)
    }

    func correct(selection: String, redactLog: Bool) async throws -> String? {
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

    func rewrite(selection: String, instruction: String) async throws -> String? {
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
                to: prompt, options: greedyOptions(maxTokens: maxTokens)
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
