import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class OnboardingWindow: NSPanel {
    private weak var controller: SuggestionController?
    private let card = OnboardingCard()

    init(controller: SuggestionController?) {
        self.controller = controller
        card.controller = controller

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
        card.retry = { [weak self] in self?.controller?.engineCoordinator.rebuild() }
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
        // restarts its blink on each keystroke.
        guard card.suggestionActive != active else { return }
        card.suggestionActive = active
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
    /// Read live — the view re-reads it once a second, like the menu-bar
    /// icon — so a first launch shows the model download instead of minutes
    /// of waiting with no hint anything is happening.
    var engine: EngineState { controller?.engine.shownState ?? .ready }
    @ObservationIgnored weak var controller: SuggestionController?
    var suggestionActive = false
    var celebrating = false
    @ObservationIgnored var tryIt: () -> Void = {}
    @ObservationIgnored var retry: () -> Void = {}
    @ObservationIgnored var gotIt: () -> Void = {}
}

struct OnboardingCardView: View {
    let card: OnboardingCard
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let width: CGFloat = 340

    private var failure: String? {
        if case .failed(let detail) = card.engine { return detail }
        return nil
    }

    private var title: String {
        if card.celebrating { return String(localized: "That's it") }
        switch card.engine {
        case .preparing: return String(localized: "Setting up Pretype")
        case .failed: return String(localized: "Pretype hit a problem")
        case .ready: return String(localized: "Pretype is Ready")
        }
    }

    private var subtitle: String {
        if card.celebrating { return String(localized: "Pretype keeps suggesting as you type, in any app") }
        switch card.engine {
        // Only a fetch is "one-time"; a model already on disk is loading.
        // Only the download line carries a percentage — a test that holds
        // in every language, unlike its "downloading" prefix.
        case .preparing(let detail):
            return detail.contains("%") ? String(localized: "One-time model download") : String(localized: "Loading the model")
        case .failed: return String(localized: "The completion engine couldn't start")
        case .ready: return String(localized: "Type in any app — Pretype lives in the menu bar")
        }
    }

    private var status: (text: String, color: Color) {
        let hotkey = Settings.hotkeyStyle
        if card.celebrating {
            return (String(localized: "✓ Accepted — \(hotkey.shiftLabel) takes a whole suggestion next time."), .green)
        }
        if card.suggestionActive {
            // Not the accent colour: with Graphite it is grey, and this is
            // the one line on the card that has to jump out.
            return (String(localized: "See the grey text? Press \(hotkey.label) to take a word."), .primary)
        }
        switch card.engine {
        case .preparing(let detail): return (detail, .secondary)
        case .failed(let detail): return (detail, .red)
        case .ready: return (String(localized: "Type a few words and pause — grey text appears after your cursor."), .secondary)
        }
    }

    /// The engine state is polled, not observed: a tick re-reads it.
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in content }
    }

    private var content: some View {
        // Keycaps follow the configured hotkey — hardcoding Tab taught the wrong
        // keys to anyone on ⌘/⌥/⌃Space. Same labels the menu and overlay use.
        let hotkey = Settings.hotkeyStyle
        let status = status
        // Pulses the title three times while the first suggestion is up, to
        // draw the eye to it; held at full opacity otherwise.
        let pulsing = card.suggestionActive && !card.celebrating
        return VStack(spacing: 16) {
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
                MenuHintsView.Hint(keys: [hotkey.label], action: String(localized: "Accept next word")),
                MenuHintsView.Hint(keys: [hotkey.shiftLabel], action: String(localized: "Accept entire suggestion")),
                MenuHintsView.Hint(keys: [hotkey.correctionLabel], action: String(localized: "Fix last word / selection")),
                // Without this a new user's only way to make a ghost go away is to
                // type over it — not knowing that is what makes it feel pushy.
                MenuHintsView.Hint(keys: ["esc"], action: String(localized: "Dismiss a suggestion")),
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
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}
