import Foundation
import FoundationModels

/// Completion via the system Apple Intelligence model (macOS 26+).
/// Zero download, zero app memory — the ~3B model is OS-managed and runs on
/// the Neural Engine. Quality differs from Gemma; it's the lightweight option.
/// Prompting recipe adapted from Cotabby's Foundation Models path.
@available(macOS 26.0, *)
final class FoundationModelsEngine: CompletionEngine {
    let name = "Apple Intelligence"

    private let stateBox = LockedValue<EngineState>(.preparing("starting…"))
    /// Single-flight guard: the session API rejects concurrent requests, so a
    /// fresh keystroke's request abstains while one is mid-flight (the caller
    /// cancels the prior task, so latest-wins still holds).
    private let inFlight = LockedValue<Bool>(false)
    private let lengthBox = LockedValue<CompletionLength>(.medium)
    private let instructionsBox = LockedValue<String>("")

    static let greedy = LockedValue<Bool>(false)

    /// Live-path sampling temperature (env `PRETYPE_FM_TEMPERATURE`); nil ⇒
    /// Apple's default sampler. Ignored under `greedy`.
    private static var temperatureOverride: Double? {
        ProcessInfo.processInfo.environment["PRETYPE_FM_TEMPERATURE"].flatMap(Double.init)
    }

    private static let instructions = """
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

    var state: EngineState { stateBox.get() }

    var statusLine: String? {
        switch stateBox.get() {
        case .preparing(let detail): return "Apple Intelligence: \(detail)"
        case .ready: return "Apple Intelligence: ready (system model)"
        case .failed(let detail): return "Apple Intelligence: \(detail)"
        }
    }

    init() {
        switch SystemLanguageModel.default.availability {
        case .available:
            stateBox.set(.ready)
            // Warm the system model so the first keystroke doesn't pay.
            let session = LanguageModelSession(instructions: Self.instructions)
            session.prewarm()
        case .unavailable(let reason):
            // A sentence, not the enum case: this lands verbatim in the menu
            // header and the onboarding card ("unavailable: modelNotReady").
            let why: String
            switch reason {
            case .deviceNotEligible: why = "this Mac doesn't support Apple Intelligence"
            case .appleIntelligenceNotEnabled: why = "turn on Apple Intelligence in System Settings"
            case .modelNotReady: why = "Apple Intelligence is still downloading — retry in a few minutes"
            @unknown default: why = "Apple Intelligence is unavailable (\(String(describing: reason)))"
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
        // Screen/app context, when present, rides ahead of the text.
        var prompt = ""
        if let screen = request.screenSummary, !screen.isEmpty {
            prompt += "Screen context:\n\(screen)\n\n"
        }
        if let app = request.appName, !app.isEmpty {
            prompt += "The user is typing in \(app).\n\n"
        }
        prompt += "Existing text: \"\(prepared.text)\"\nContinuation:"

        // Persona (when set) sharpens voice; length caps the response.
        let persona = request.persona(global: instructionsBox.get())
        let instructions = persona.isEmpty
            ? Self.instructions
            : Self.instructions + "\n\nAbout the author (for voice only, never quote it):\n\(persona)"

        // A fresh session per request: autocomplete must not accumulate a
        // multi-turn transcript.
        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(to: prompt, options: generationOptions())
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

    /// Decoding options: greedy (eval determinism) wins; otherwise an optional
    /// temperature override rides on Apple's default sampler. FM tokens run
    /// shorter than MLX's, so the budget carries a little headroom.
    private func generationOptions() -> GenerationOptions {
        let maxTokens = lengthBox.get().maxTokens + 8
        if Self.greedy.get() {
            return GenerationOptions(sampling: .greedy, maximumResponseTokens: maxTokens)
        }
        if let temperature = Self.temperatureOverride {
            return GenerationOptions(temperature: temperature, maximumResponseTokens: maxTokens)
        }
        return GenerationOptions(maximumResponseTokens: maxTokens)
    }

    func updateCompletion(length: CompletionLength, instructions: String) {
        lengthBox.set(length)
        instructionsBox.set(instructions)
    }

    func correct(selection: String, request: CompletionRequest,
                 redactLog: Bool) async throws -> String? {
        guard case .ready = stateBox.get() else { return nil }
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 500, !trimmed.contains("\n") else { return nil }

        let session = LanguageModelSession()
        let prompt = """
        \(CorrectionGates.correctionDirective)

        \(trimmed)
        """
        let fixed: String
        do {
            // Greedy + a budget scaled to the selection: faithful (no
            // paraphrasing) and never clipped on long lines.
            let response = try await session.respond(
                to: prompt,
                options: GenerationOptions(
                    sampling: .greedy,
                    maximumResponseTokens: CorrectionGates.correctionTokenBudget(forChars: trimmed.count)
                )
            )
            // Same as complete(): a cancelled request (focus moved on, overlay
            // reset) must not surface its late result.
            try Task.checkCancellation()
            fixed = CorrectionGates.trimRunOn(
                CorrectionGates.cleanCorrectionOutput(response.content), original: trimmed)
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .rateLimited, .concurrentRequests:
                // A transient resource error must not read as "nothing to
                // fix" — rethrow so the UI shows "fix failed", not "✓ looks
                // fine", for a selection that may well be broken.
                throw error
            default:
                // A declined fix is a no-op, not an error — same as completion.
                DebugLog.shared.log("FM", "fix abstain — \(Self.reason(error))")
                return nil
            }
        }
        guard !fixed.isEmpty, fixed != trimmed else { return nil }
        guard CorrectionGates.isMinimalCorrection(original: trimmed, fixed: fixed) else {
            DebugLog.shared.log(
                "FM", "fix rejected (over-rewrite)",
                detail: redactLog
                    ? "\(trimmed.count) → \(fixed.count) chars — redacted from log"
                    : "\"\(trimmed)\" → \"\(fixed)\"")
            return nil
        }
        return fixed
    }

    func reply(to conversation: String, request: CompletionRequest) async throws -> String? {
        guard case .ready = stateBox.get() else { return nil }
        let session = LanguageModelSession()
        let prompt = request.replyPrompt(
            conversation: conversation, instructions: instructionsBox.get())
        do {
            let response = try await session.respond(
                to: prompt,
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 200)
            )
            try Task.checkCancellation()
            return request.cleanReply(response.content)
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            // Same split as correct(): a resource error is a failure the user
            // should see, anything else is a decline.
            case .rateLimited, .concurrentRequests:
                throw error
            default:
                DebugLog.shared.log("FM", "reply abstain — \(Self.reason(error))")
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
