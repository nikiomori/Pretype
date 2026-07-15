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
    /// build-time setting change.
    private func rebuild() {
        engine.shutdown()
        engine = Self.makeEngine(modelID: Settings.mlxModelID)
        onRebuild?()
    }

    /// Commit a fully-resolved configuration in one shot — presets and the
    /// model-map settings dots land here. One Settings write-out, ONE engine
    /// rebuild, instead of a rebuild per field like the individual setters.
    /// The target comes from `ProjectionConfig.applying`, cascades included.
    // ponytail: the per-field setters below still hand-encode the same
    // cascade rules ProjectionConfig.applying centralizes; route them through
    // apply(_:) if the rules grow again.
    func apply(_ target: ProjectionConfig) {
        Settings.mlxModelID = target.modelID
        Settings.useRecommendedSettings = target.useRecommended
        Settings.completionStyle = target.style
        Settings.completionLength = target.length
        Settings.confidenceGate = target.confidenceGate
        Settings.logprobGate = target.logprobGate
        rebuild()
    }

    func setModel(_ id: String) {
        Settings.mlxModelID = id
        let rec = ModelCatalog.recommended(for: id)
        // In "auto" mode the per-model recommendation drives style + length.
        if Settings.useRecommendedSettings {
            Settings.completionStyle = rec.style
            Settings.completionLength = rec.length
        }
        // Instruct is measured-broken on base-only models (answers instead of
        // continuing, ~0% first-word) — a model switch must not carry it there.
        if rec.style == .base, Settings.completionStyle == .instruct {
            Settings.completionStyle = .base
        }
        // The confidence gate only helps as a Base-style feature on a gate-capable
        // model — clear it when that no longer holds, so it can't cost latency for nothing.
        if Settings.confidenceGate, !(rec.gateCapable && Settings.completionStyle == .base) {
            Settings.confidenceGate = false
        }
        if Settings.logprobGate, Settings.completionStyle != .base {
            Settings.logprobGate = false   // logprob gate is Base-only
        }
        rebuild()
    }

    /// Snap Style + Length to the selected model's recommendation (the "auto"
    /// switch turning on, or a one-shot re-apply). Rebuilds since style is a
    /// build-time choice.
    func applyRecommendedSettings() {
        let rec = ModelCatalog.recommended(for: Settings.mlxModelID)
        Settings.completionStyle = rec.style
        Settings.completionLength = rec.length
        if !(rec.gateCapable && rec.style == .base) { Settings.confidenceGate = false }
        if rec.style != .base { Settings.logprobGate = false }
        rebuild()
    }

    /// Base ↔ instruct switches the loaded model, so rebuild. The precision
    /// gates are Base-only: leaving Base turns them off rather than leaving
    /// them set-but-inert ("Confident-only" in the UI while doing nothing).
    func setCompletionStyle(_ style: CompletionStyle) {
        Settings.completionStyle = style
        if style != .base {
            Settings.logprobGate = false
            Settings.confidenceGate = false
        }
        rebuild()
    }

    /// The confidence gate is read when the engine is built, so toggling it
    /// rebuilds (same as a style switch). The two high-precision gates are mutually
    /// exclusive — enabling one drops the other.
    func setConfidenceGate(_ enabled: Bool) {
        Settings.confidenceGate = enabled
        if enabled { Settings.logprobGate = false }
        rebuild()
    }

    /// Logprob gate: same build-time-then-rebuild contract; enabling it drops the
    /// self-consistency gate (both abstain on low confidence, but logprob is 0× decode).
    func setLogprobGate(_ enabled: Bool) {
        Settings.logprobGate = enabled
        if enabled { Settings.confidenceGate = false }
        rebuild()
    }

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

    /// Free the engine's resident model now (reloads on next use).
    func releaseModelNow() {
        engine.releaseModelNow()
    }

    /// Flush engine state before the app quits.
    func shutdown() {
        engine.shutdown()
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
