import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class OnboardingWindow: NSPanel {
    private weak var controller: SuggestionController?
    private let card = OnboardingCard()

    /// Mirrors the engine state (model download progress, failures) into the
    /// window — without this, a first launch spends minutes "Waiting for
    /// suggestion…" while the model downloads, with no hint anything is
    /// happening (the menu-bar icon alone is easy to miss).
    private var statusTimer: Timer?

    init(controller: SuggestionController?) {
        self.controller = controller

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 280),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        card.tryIt = { Self.openTextEdit() }
        card.retry = { [weak self] in
            self?.controller?.engineCoordinator.rebuild()
            self?.refreshEngineStatus()
        }
        card.gotIt = { [weak self] in
            Settings.onboardingCompleted = true
            self?.dismiss()
        }
        contentView = FirstMouseHostingView(rootView: OnboardingCardView(card: card))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        // Top-right, under the menu bar: centred, it sat on top of the very
        // window it asked the user to type in — and up here it points at
        // where Pretype lives once this card is gone.
        refreshEngineStatus()
        let size = contentView?.fittingSize ?? frame.size
        setContentSize(size)
        setFrameOrigin(CGPoint(x: screenFrame.maxX - size.width - 16, y: screenFrame.maxY - size.height - 12))

        alphaValue = 0
        orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }

        statusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshEngineStatus()
            }
        }
    }

    /// Same 1 s poll the menu-bar icon uses — no engine callback plumbing.
    private func refreshEngineStatus() {
        guard !card.suggestionActive, !card.celebrating else { return }
        let engine = controller?.engine
        var state = engine?.state ?? .ready
        // Idle-unloaded is `.preparing` with nothing running; it reloads on
        // the first keystroke, so for this card it is ready.
        if case .preparing = state, engine?.isLoading == false { state = .ready }
        if card.engine != state { card.engine = state }
    }

    /// The first accept: say it worked before going, instead of vanishing on
    /// the keystroke — an instant dismissal read as "did I break it?".
    func celebrate() {
        card.celebrating = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.dismiss() }
    }

    /// A blank document to type on: an empty file opened directly, which
    /// skips TextEdit's iCloud Open panel.
    private static func openTextEdit() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Try Pretype.txt")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? "".write(to: url, atomically: true, encoding: .utf8)
        }
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: config)
    }

    func dismiss() {
        statusTimer?.invalidate()
        statusTimer = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                self?.orderOut(nil)
                self?.controller?.clearOnboarding()
            }
        })
    }

    func updateStatusSuggestionActive(_ active: Bool) {
        // apply() calls this on every suggestion; without the edge check the title
        // restarts its blink on each keystroke and refreshEngineStatus() thrashes.
        guard card.suggestionActive != active else { return }
        card.suggestionActive = active
        if !active { refreshEngineStatus() }
    }
}

/// This panel never becomes key, so without first-mouse a button's click
/// would be spent on focusing the window instead of pressing the button.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// What the card shows: the engine state, overridden by a live suggestion and
/// then by the first accept.
@MainActor
@Observable
final class OnboardingCard {
    var engine = EngineState.ready
    var suggestionActive = false
    var celebrating = false
    @ObservationIgnored var tryIt: () -> Void = {}
    @ObservationIgnored var retry: () -> Void = {}
    @ObservationIgnored var gotIt: () -> Void = {}
}

struct OnboardingCardView: View {
    let card: OnboardingCard
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let readySubtitle = "Type in any app — Pretype lives in the menu bar"
    private static let width: CGFloat = 340

    private var failure: String? {
        if case .failed(let detail) = card.engine { return detail }
        return nil
    }

    private var title: String {
        if card.celebrating { return "That's it" }
        switch card.engine {
        case .preparing: return "Setting up Pretype"
        case .failed: return "Pretype hit a problem"
        case .ready: return "Pretype is Ready"
        }
    }

    private var subtitle: String {
        if card.celebrating { return "Pretype keeps suggesting as you type, in any app" }
        switch card.engine {
        // Only a fetch is "one-time"; a model already on disk is loading.
        case .preparing(let detail): return detail.hasPrefix("downloading") ? "One-time model download" : "Loading the model"
        case .failed: return "The completion engine couldn't start"
        case .ready: return Self.readySubtitle
        }
    }

    private var status: (text: String, color: Color) {
        let hotkey = Settings.hotkeyStyle
        if card.celebrating {
            return ("✓ Accepted — \(hotkey.shiftLabel) takes a whole suggestion next time.", .green)
        }
        if card.suggestionActive {
            // Not the accent colour: with Graphite it is grey, and this is
            // the one line on the card that has to jump out.
            return ("See the grey text? Press \(hotkey.label) to take a word.", .primary)
        }
        switch card.engine {
        case .preparing(let detail): return (detail, .secondary)
        case .failed(let detail): return (detail, .red)
        case .ready: return ("Type a few words and pause — grey text appears after your cursor.", .secondary)
        }
    }

    var body: some View {
        // Keycaps follow the configured hotkey — hardcoding Tab taught the wrong
        // keys to anyone on ⌘/⌥/⌃Space. Same labels the menu and overlay use.
        let hotkey = Settings.hotkeyStyle
        let status = status
        // Pulses the title three times while the first suggestion is up, to
        // draw the eye to it; held at full opacity otherwise.
        let pulsing = card.suggestionActive && !card.celebrating
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .phaseAnimator(reduceMotion ? [1.0] : [1.0, 0.5, 1.0, 0.5, 1.0, 0.5], trigger: pulsing) {
                        $0.opacity(pulsing ? $1 : 1)
                    } animation: { _ in .easeInOut(duration: 0.8) }
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Divider()
                .frame(width: Self.width)
            MenuHintsView(hints: [
                MenuHintsView.Hint(keys: [hotkey.label], action: "Accept next word"),
                MenuHintsView.Hint(keys: [hotkey.shiftLabel], action: "Accept entire suggestion"),
                MenuHintsView.Hint(keys: [hotkey.correctionLabel], action: "Fix last word / selection"),
                // Without this a new user's only way to make a ghost go away is to
                // type over it — not knowing that is what makes it feel pushy.
                MenuHintsView.Hint(keys: ["esc"], action: "Dismiss a suggestion"),
            ], font: .body, width: Self.width)
            // Two lines, not one truncated one: a failure reason or the waiting
            // instruction is exactly the sentence that must be read in full.
            // Room for two lines in every state, so the card never resizes
            // under the user as the status text changes length.
            Text(status.text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(status.color)
                .lineLimit(2)
                .frame(width: Self.width, height: 32, alignment: .leading)
                .help(failure ?? "")
            HStack(spacing: 8) {
                Spacer()
                // Somewhere to try it without hunting for a text field: a blank
                // TextEdit document (TextEdit launched bare opens its iCloud
                // Open panel instead of a page to type on).
                if !card.celebrating, failure == nil {
                    Button("Open TextEdit", action: card.tryIt)
                }
                // Only when the engine failed — the way back without a relaunch.
                if !card.celebrating, failure != nil {
                    Button("Retry", action: card.retry)
                }
                Button("Got It", action: card.gotIt)
            }
            .frame(width: Self.width)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(HUDBackdrop())
    }
}

/// The card's frosted HUD backdrop, blurred against what is behind the window.
private struct HUDBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.state = .active
        view.blendingMode = .behindWindow
        view.wantsLayer = true
        view.layer?.cornerRadius = 16
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
