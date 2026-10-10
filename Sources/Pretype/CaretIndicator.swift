import AppKit

/// Shows engine state at the caret — "downloading 42%" while a model loads,
/// animated dots when a query runs longer than a blink, and brief transient
/// notices (e.g. "✓ looks fine"). Fast answers never flash anything.
///
/// It draws into the owner's shared `SuggestionWindow` and reads the caret
/// rect, engine state, and whether a real suggestion is showing from it.
@MainActor
final class CaretIndicator {
    private unowned let owner: SuggestionController
    private var window: SuggestionWindow { owner.window }

    private var timer: Timer?
    private var thinkingPhase = 0

    init(owner: SuggestionController) {
        self.owner = owner
    }

    /// The idle-unloaded resting state reports `.preparing` with nothing
    /// running; the keystroke reloads it in well under a second. At the caret
    /// that is just a slow query (dots), not "idle — model unloaded" flashed
    /// over the user's text.
    private var engineState: EngineState {
        let engine = owner.engine
        if case .preparing = engine.state, !engine.isLoading { return .ready }
        return engine.state
    }

    /// The ⌥⇥ fix flows run outside the completion query; without them the
    /// timer sees .ready + idle at its first tick and kills the thinking dots.
    private var isQueryRunning: Bool {
        owner.isCompleting || owner.correctionController.inFlight
    }

    /// Begin showing state at the caret: "downloading…" once a load outlasts a
    /// warm reload, animated dots when a query is slower than a blink.
    func start() {
        // Idempotent: invalidate any live timer first. A start() without a
        // paired stop() (e.g. ⌥⇥ last-word fix firing mid-completion) would
        // otherwise orphan the previous run-loop-retained timer, which keeps
        // firing update() and can hide a live overlay.
        stop()
        // Surface "thinking" promptly: warm completions finish in ~0.13 s (no
        // indicator), but a slow one (cold start, cache miss) shows dots quickly
        // so the caret never sits silent.
        // Main run loop: fires on the main thread, synchronously — a Task hop
        // could still run update() after a stop().
        timer = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        thinkingPhase = 0
    }

    /// Briefly show `mode` at the caret, then hide it (unless a real suggestion
    /// took the window over in the meantime).
    func flashTransient(_ mode: SuggestionDisplayMode, hideAfter: TimeInterval = 1.8) {
        // Never overdraw a live suggestion — same invariant update() enforces.
        // Stomping it leaves `active` non-nil under the transient pill, so the
        // suggestion stays Tab-acceptable while invisible. The transient is
        // purely informational; the real ghost wins.
        guard let rect = owner.lastCaretRect, !owner.hasActiveSuggestion else { return }
        // The auto-hide is superseded by any later overlay (completion ghost,
        // correction pill, status) via hideGeneration — see showTransient.
        window.showTransient(mode, at: rect, host: owner.lastHostStyle, hideAfter: hideAfter)
    }

    private func update() {
        guard let rect = owner.lastCaretRect else { return }
        switch engineState {
        case .preparing(let detail):
            // Same invariant as .ready: never overdraw a live ghost (the
            // instant n-gram suggestion can be up while the model loads) —
            // `active` would stay Tab-acceptable under the status pill.
            guard !owner.hasActiveSuggestion else { return }
            // A warm reload finishes in well under a second: a status pill
            // that appears for a few frames and is replaced by the ghost is
            // noise. Only a load still running after ~0.9 s (a cold start, a
            // download) earns one; until then the caret stays quiet.
            thinkingPhase += 1
            guard thinkingPhase > 3 else { return }
            window.show(mode: .status(detail), at: rect, host: owner.lastHostStyle)
        case .ready:
            // A visible suggestion owns the shared window: never overdraw it
            // with thinking dots, and never hide it when the query ends — the
            // gated single-yield path can finish with NO apply() call (abstain
            // with an instant n-gram suggestion kept), so this timer used to
            // stomp a valid suggestion: text → dots → gone.
            if isQueryRunning {
                guard !owner.hasActiveSuggestion else { return }
                thinkingPhase += 1
                // The first tick (~0.22 s) stays silent: only queries slower
                // than ~0.45 s earn dots, so mid-speed answers don't flash
                // them for a few frames right before the suggestion lands.
                if thinkingPhase > 1 {
                    // The host from the same keystroke that started this query:
                    // the dots decide ghost-vs-pill on its `textFollowsCaret`,
                    // and a stale one painted them over the user's own words.
                    window.show(mode: .thinking(thinkingPhase), at: rect, host: owner.lastHostStyle)
                }
            } else {
                stop()
                if !owner.hasActiveSuggestion { window.hide() }
            }
        case .failed:
            // Show once and stop: no downstream path stops the timer in this
            // state, so a repeating show() would pin the error pill at a stale
            // caret forever. The transient auto-hides.
            stop()
            guard !owner.hasActiveSuggestion else { return }
            window.showTransient(.error("engine not working"), at: rect, host: owner.lastHostStyle)
        }
    }
}
