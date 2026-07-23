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
    private let hostStyle: () -> HostTextStyle
    private let hasActiveSuggestion: () -> Bool
    private let isQueryRunning: () -> Bool

    private var timer: Timer?
    private var thinkingPhase = 0

    init(
        window: SuggestionWindow,
        engineState: @escaping () -> EngineState,
        caretRect: @escaping () -> CGRect?,
        hostStyle: @escaping () -> HostTextStyle,
        hasActiveSuggestion: @escaping () -> Bool,
        isQueryRunning: @escaping () -> Bool
    ) {
        self.window = window
        self.engineState = engineState
        self.caretRect = caretRect
        self.hostStyle = hostStyle
        self.hasActiveSuggestion = hasActiveSuggestion
        self.isQueryRunning = isQueryRunning
    }

    /// Begin showing state at the caret: "downloading…" immediately while the
    /// model is not ready, animated dots when a query is slower than a blink.
    func start() {
        // Idempotent: invalidate any live timer first. A start() without a
        // paired stop() (e.g. ⌥⇥ last-word fix firing mid-completion) would
        // otherwise orphan the previous run-loop-retained timer, which keeps
        // firing update() and can hide a live overlay.
        stop()
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
        // Never overdraw a live suggestion — same invariant update() enforces.
        // Stomping it leaves `active` non-nil under the transient pill, so the
        // suggestion stays Tab-acceptable while invisible. The transient is
        // purely informational; the real ghost wins.
        guard let rect = caretRect(), !hasActiveSuggestion() else { return }
        // The auto-hide is superseded by any later overlay (completion ghost,
        // correction pill, status) via hideGeneration — see showTransient.
        window.showTransient(mode, at: rect, host: hostStyle())
    }

    private func update() {
        guard let rect = caretRect() else { return }
        switch engineState() {
        case .preparing(let detail):
            // Same invariant as .ready: never overdraw a live ghost (the
            // instant n-gram suggestion can be up while the model loads) —
            // `active` would stay Tab-acceptable under the status pill.
            guard !hasActiveSuggestion() else { return }
            window.show(mode: .status(detail), at: rect, host: hostStyle())
        case .ready:
            // A visible suggestion owns the shared window: never overdraw it
            // with thinking dots, and never hide it when the query ends — the
            // gated single-yield path can finish with NO apply() call (abstain
            // with an instant n-gram suggestion kept), so this timer used to
            // stomp a valid suggestion: text → dots → gone.
            if isQueryRunning() {
                guard !hasActiveSuggestion() else { return }
                thinkingPhase += 1
                // The first tick (~0.22 s) stays silent: only queries slower
                // than ~0.45 s earn dots, so mid-speed answers don't flash
                // them for a few frames right before the suggestion lands.
                if thinkingPhase > 1 {
                    // The host from the same keystroke that started this query:
                    // the dots decide ghost-vs-pill on its `textFollowsCaret`,
                    // and a stale one painted them over the user's own words.
                    window.show(mode: .thinking(thinkingPhase), at: rect, host: hostStyle())
                }
            } else {
                stop()
                if !hasActiveSuggestion() { window.hide() }
            }
        case .failed:
            // Show once and stop: no downstream path stops the timer in this
            // state, so a repeating show() would pin the error pill at a stale
            // caret forever. The transient auto-hides.
            stop()
            guard !hasActiveSuggestion() else { return }
            window.showTransient(.error("engine not working"), at: rect, host: hostStyle())
        }
    }
}
