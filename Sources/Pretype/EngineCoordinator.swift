import Foundation

/// Owns the completion engine's lifecycle and the settings that reshape it, so
/// `SuggestionController` can focus on the input→overlay pipeline. Style and
/// model are build-time choices — changing either rebuilds the engine; the
/// logprob gate, length, persona and personalization apply live. The repeated
/// "shutdown → rebuild → drop the stale suggestion" pattern lives here once.
@MainActor
final class EngineCoordinator {
    /// The active engine. Read-only to the outside; only a rebuild replaces it.
    private(set) var engine: CompletionEngine

    /// Invoked after a rebuild so the owner can clear any live suggestion that
    /// belonged to the previous engine (the controller wires this to `dismiss`).
    var onRebuild: (() -> Void)?

    /// How a local engine is built — after the one it replaces, if any;
    /// tests build theirs on a tiny model.
    typealias MakeMLX = (_ modelID: String, _ previous: MLXEngine?) -> MLXEngine
    private let makeMLX: MakeMLX

    init(makeMLX: @escaping MakeMLX = { MLXEngine(modelID: $0, after: $1) }) {
        self.makeMLX = makeMLX
        engine = Self.makeEngine(modelID: Settings.mlxModelID, mlx: makeMLX)
    }

    /// Tear down the current engine and build a fresh one for the current
    /// settings, then notify the owner. The single rebuild path for every
    /// build-time setting change — and the way back from `.failed`.
    func rebuild() {
        engine.shutdown()
        engine = Self.makeEngine(modelID: Settings.mlxModelID, after: engine, mlx: makeMLX)
        onRebuild?()
    }

    /// The persisted configuration as a pure value — what every setter
    /// cascades from.
    var current: ProjectionConfig {
        ProjectionConfig(modelID: Settings.mlxModelID,
                         style: Settings.completionStyle,
                         length: Settings.completionLength,
                         logprobGate: Settings.logprobGate,
                         useRecommended: Settings.useRecommendedSettings)
    }

    /// Commit a fully-resolved configuration: one Settings write-out, at most
    /// ONE engine rebuild. Every build-time setter below routes through here
    /// with `ProjectionConfig.applying` as the single cascade authority — the
    /// same function the settings UI previews with, so preview and commit
    /// cannot diverge.
    func apply(_ target: ProjectionConfig) {
        let before = current
        Settings.mlxModelID = target.modelID
        Settings.useRecommendedSettings = target.useRecommended
        Settings.completionStyle = target.style
        Settings.completionLength = target.length
        Settings.logprobGate = target.logprobGate
        // The same model in the same style keeps its weights: a rebuild would
        // read them from disk again, re-run the warm-up and drop the prompt
        // cache for a gate or auto-mode toggle. A failed engine still gets
        // its fresh start.
        let failed = if case .failed = engine.state { true } else { false }
        if target.modelID == before.modelID, target.style == before.style, !failed {
            let config = CompletionConfig.resolved()
            engine.updateCompletion(length: config.length, instructions: config.instructions)
            (engine as? MLXEngine)?.updateGate()
        } else {
            rebuild()
        }
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

    private static func makeEngine(modelID: String, after previous: CompletionEngine? = nil,
                                   mlx: MakeMLX) -> CompletionEngine {
        let engine: CompletionEngine
        if Settings.apiText.enabled {
            engine = CloudEngine(Settings.apiText)
        } else if modelID == ModelCatalog.appleIntelligenceID {
            engine = FoundationModelsEngine()
        } else {
            engine = mlx(modelID, previous as? MLXEngine)
        }
        let config = CompletionConfig.resolved()
        engine.updateCompletion(length: config.length, instructions: config.instructions)
        return engine
    }
}
