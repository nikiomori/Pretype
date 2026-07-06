import AppKit

/// Shows engine state at the caret — "downloading 42%" while a model loads,
/// animated dots when a query runs longer than a blink, and brief transient
/// notices (e.g. "✓ looks fine"). Fast answers never flash anything.
///
/// It draws into the shared `SuggestionWindow` and reads the caret rect, engine
/// state, and whether a real suggestion is currently showing through closures,
/// so it stays decoupled from the controller that owns those.
final class CaretIndicator {
    private let window: SuggestionWindow
    private let engineState: () -> EngineState
    private let caretRect: () -> CGRect?
    private let hasActiveSuggestion: () -> Bool
    private let isQueryRunning: () -> Bool

    private var timer: Timer?
    private var thinkingPhase = 0
    private var transientHideWork: DispatchWorkItem?

    init(
        window: SuggestionWindow,
        engineState: @escaping () -> EngineState,
        caretRect: @escaping () -> CGRect?,
        hasActiveSuggestion: @escaping () -> Bool,
        isQueryRunning: @escaping () -> Bool
    ) {
        self.window = window
        self.engineState = engineState
        self.caretRect = caretRect
        self.hasActiveSuggestion = hasActiveSuggestion
        self.isQueryRunning = isQueryRunning
    }

    /// Begin showing state at the caret: "downloading…" immediately while the
    /// model is not ready, animated dots when a query is slower than a blink.
    func start() {
        if case .preparing = engineState() {
            update()
        }
        // Surface "thinking" promptly: warm completions finish in ~0.13 s (no
        // indicator), but a slow one (cold start, cache miss) shows dots quickly
        // so the caret never sits silent.
        timer = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: true) { [weak self] _ in
            self?.update()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        thinkingPhase = 0
    }

    /// Briefly show `mode` at the caret, then hide it (unless a real suggestion
    /// took the window over in the meantime).
    func flashTransient(_ mode: SuggestionDisplayMode) {
        guard let rect = caretRect() else { return }
        window.show(mode: mode, at: rect)
        transientHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            if self?.hasActiveSuggestion() == false { self?.window.hide() }
        }
        transientHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }

    private func update() {
        guard let rect = caretRect() else { return }
        switch engineState() {
        case .preparing(let detail):
            window.show(mode: .status(detail), at: rect)
        case .ready:
            if isQueryRunning() {
                thinkingPhase += 1
                // The first tick (~0.22 s) stays silent: only queries slower
                // than ~0.45 s earn dots, so mid-speed answers don't flash
                // them for a few frames right before the suggestion lands.
                if thinkingPhase > 1 {
                    window.show(mode: .thinking(thinkingPhase), at: rect)
                }
            } else {
                stop()
                window.hide()
            }
        case .failed:
            window.show(mode: .error("engine not working"), at: rect)
        }
    }
}
