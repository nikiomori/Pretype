import AppKit

/// What the indicator reads of the pipeline it draws for — `SuggestionController`
/// in the app, a fake in CaretIndicatorTests.
@MainActor
protocol IndicatorHost: AnyObject {
    /// Where the latest context put the caret, and the field's style there.
    var lastCaretRect: CGRect? { get }
    var lastHostStyle: HostTextStyle { get }
    /// A real suggestion owns the window: nothing is drawn over it.
    var hasActiveSuggestion: Bool { get }
    /// A completion query or a fix generation is running — the ⌥⇥ fix flows
    /// run outside the query, and without them the timer would see .ready and
    /// idle at its first tick and kill the thinking dots.
    var isWorking: Bool { get }
    /// The engine as the user sees it (`CompletionEngine.shownState`).
    var engineState: EngineState { get }
}

/// Shows engine state at the caret — "downloading 42%" while a model loads,
/// animated dots when a query runs longer than a blink, and brief transient
/// notices (e.g. "✓ looks fine"). Fast answers never flash anything. It draws
/// into the shared overlay.
@MainActor
final class CaretIndicator {
    private unowned let host: any IndicatorHost
    private let window: any SuggestionOverlay

    private(set) var timer: Timer?
    private var thinkingPhase = 0

    init(host: any IndicatorHost, window: any SuggestionOverlay) {
        self.host = host
        self.window = window
    }

    /// Begin showing state at the caret: "downloading…" once a load outlasts a
    /// warm reload, animated dots when a query is slower than a blink.
    func start() {
        // Idempotent: invalidate any live timer first. A start() without a
        // paired stop() (e.g. ⌥⇥ last-word fix firing mid-completion) would
        // otherwise orphan the previous run-loop-retained timer, which keeps
        // firing tick() and can hide a live overlay.
        stop()
        // Surface "thinking" promptly: warm completions finish in ~0.13 s (no
        // indicator), but a slow one (cold start, cache miss) shows dots quickly
        // so the caret never sits silent.
        // Main run loop: fires on the main thread, synchronously — a Task hop
        // could still run tick() after a stop().
        timer = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        thinkingPhase = 0
    }

    /// How long a transient notice stays up.
    nonisolated static let noticeSeconds: TimeInterval = 1.8

    /// Briefly show `mode` at the caret, then hide it (unless a real suggestion
    /// took the window over in the meantime).
    func flashTransient(_ mode: SuggestionDisplayMode, hideAfter: TimeInterval = noticeSeconds,
                        orAtPointer: Bool = false, atPointer: Bool = false) {
        // Never overdraw a live suggestion — same invariant tick() enforces.
        // Stomping it leaves `active` non-nil under the transient pill, so the
        // suggestion stays Tab-acceptable while invisible. The transient is
        // purely informational; the real ghost wins.
        // `orAtPointer`: the answer to an explicit chord whose caret a scroll
        // forgot (`viewScrolled`) goes where the user is looking instead.
        // `atPointer`: the chord was refused before it read a field, so the
        // caret remembered is another field's — or, behind our own window,
        // another app's.
        let pointer = orAtPointer || atPointer ? DictationController.pointerAnchor() : nil
        guard let rect = atPointer ? pointer : host.lastCaretRect ?? pointer,
              !host.hasActiveSuggestion else { return }
        // The auto-hide is superseded by any later overlay (completion ghost,
        // correction pill, status) via hideGeneration — see showTransient.
        window.showTransient(mode, at: rect, host: host.lastHostStyle, hideAfter: hideAfter)
    }

    /// One beat of the timer `start` runs.
    func tick() {
        guard let rect = host.lastCaretRect else { return }
        // `shownState`: an idle-unloaded reload is just a slow query here
        // (dots), not "idle — model unloaded" flashed over the user's text.
        switch host.engineState {
        case .preparing(let detail):
            // Same invariant as .ready: never overdraw a live ghost (the
            // instant n-gram suggestion can be up while the model loads) —
            // `active` would stay Tab-acceptable under the status pill.
            guard !host.hasActiveSuggestion else { return }
            // A warm reload finishes in well under a second: a status pill
            // that appears for a few frames and is replaced by the ghost is
            // noise. Only a load still running after ~0.9 s (a cold start, a
            // download) earns one; until then the caret stays quiet.
            thinkingPhase += 1
            guard thinkingPhase > 3 else { return }
            window.show(mode: .status(detail), at: rect, host: host.lastHostStyle)
        case .ready:
            // A visible suggestion owns the shared window: never overdraw it
            // with thinking dots, and never hide it when the query ends — the
            // gated single-yield path can finish with NO apply() call (abstain
            // with an instant n-gram suggestion kept), so this timer used to
            // stomp a valid suggestion: text → dots → gone.
            if host.isWorking {
                guard !host.hasActiveSuggestion else { return }
                thinkingPhase += 1
                // The first tick (~0.22 s) stays silent: only queries slower
                // than ~0.45 s earn dots, so mid-speed answers don't flash
                // them for a few frames right before the suggestion lands.
                if thinkingPhase > 1 {
                    // The host from the same keystroke that started this query:
                    // the dots decide ghost-vs-pill on its `textFollowsCaret`,
                    // and a stale one painted them over the user's own words.
                    window.show(mode: .thinking(thinkingPhase), at: rect, host: host.lastHostStyle)
                }
            } else {
                stop()
                if !host.hasActiveSuggestion { window.hide() }
            }
        case .failed:
            // Show once and stop: no downstream path stops the timer in this
            // state, so a repeating show() would pin the error pill at a stale
            // caret forever. The transient auto-hides.
            stop()
            guard !host.hasActiveSuggestion else { return }
            window.showTransient(.error(String(localized: "engine not working")), at: rect, host: host.lastHostStyle)
        }
    }
}

extension SuggestionController: IndicatorHost {
    var isWorking: Bool { isCompleting || correctionController.inFlight }
    var engineState: EngineState { engine.shownState }
}
