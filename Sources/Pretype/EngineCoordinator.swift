import Foundation

/// Owns the completion engine's lifecycle and the settings that reshape it, so
/// `SuggestionController` can focus on the input→overlay pipeline. Style, model,
/// and the confidence gate are build-time choices — changing any of them rebuilds
/// the engine; length, persona and personalization apply live. The repeated
/// "shutdown → rebuild → drop the stale suggestion" pattern lives here once.
@MainActor
final class EngineCoordinator {
    /// The active engine. Read-only to the outside; only a rebuild replaces it.
    private(set) var engine: CompletionEngine

    /// Invoked after a rebuild so the owner can clear any live suggestion that
    /// belonged to the previous engine (the controller wires this to `dismiss`).
    var onRebuild: (() -> Void)?

    init() {
        engine = Self.makeEngine(modelID: Settings.mlxModelID)
    }

    /// Tear down the current engine and build a fresh one for the current
    /// settings, then notify the owner. The single rebuild path for every
    /// build-time setting change — and the way back from `.failed`.
    func rebuild() {
        engine.shutdown()
        engine = Self.makeEngine(modelID: Settings.mlxModelID)
        onRebuild?()
    }

    /// The persisted configuration as a pure value — what every setter
    /// cascades from.
    private var current: ProjectionConfig {
        ProjectionConfig(modelID: Settings.mlxModelID,
                         style: Settings.completionStyle,
                         length: Settings.completionLength,
                         logprobGate: Settings.logprobGate,
                         confidenceGate: Settings.confidenceGate,
                         useRecommended: Settings.useRecommendedSettings)
    }

    /// Commit a fully-resolved configuration: one Settings write-out, ONE
    /// engine rebuild. Every build-time setter below routes through here with
    /// `ProjectionConfig.applying` as the single cascade authority — the same
    /// function the settings UI previews with, so preview and commit cannot
    /// diverge.
    func apply(_ target: ProjectionConfig) {
        Settings.mlxModelID = target.modelID
        Settings.useRecommendedSettings = target.useRecommended
        Settings.completionStyle = target.style
        Settings.completionLength = target.length
        Settings.confidenceGate = target.confidenceGate
        Settings.logprobGate = target.logprobGate
        rebuild()
    }

    /// One build-time change (model, style, gate, "use recommended") cascaded
    /// from the persisted config, then committed — e.g. a style switch clears
    /// the Base-only gate rather than leaving it set-but-inert.
    func apply(_ change: ProjectionConfig.Change) { apply(current.applying(change)) }

    /// Length/persona are live — no reload.
    func setCompletionLength(_ length: CompletionLength) {
        Settings.completionLength = length
        engine.updateCompletion(length: length, instructions: Settings.customInstructions)
    }

    func setCustomInstructions(_ instructions: String) {
        Settings.customInstructions = instructions
        engine.updateCompletion(length: Settings.completionLength, instructions: instructions)
    }

    func setPersonalization(_ level: PersonalizationLevel) {
        Settings.personalizationLevel = level
        engine.updatePersonalization(level)
    }

    private static func makeEngine(modelID: String) -> CompletionEngine {
        let engine: CompletionEngine
        if modelID == ModelCatalog.appleIntelligenceID, #available(macOS 26.0, *) {
            engine = FoundationModelsEngine()
        } else {
            engine = MLXEngine(modelID: modelID)
        }
        let config = CompletionConfig.resolved()
        engine.updateCompletion(length: config.length, instructions: config.instructions)
        engine.updatePersonalization(config.personalization)
        return engine
    }
}
