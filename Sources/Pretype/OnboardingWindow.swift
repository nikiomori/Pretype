import AppKit
import QuartzCore

@MainActor
final class OnboardingWindow: NSPanel {
    private weak var controller: SuggestionController?
    
    private let container = NSView()
    private let visualBackdrop = NSVisualEffectView()
    
    private let titleLabel = NSTextField(labelWithString: "Pretype is Ready")
    private let subtitleLabel = NSTextField(labelWithString: "Try typing in TextEdit")
    
    private let statusLabel = NSTextField(labelWithString: "Waiting for suggestion…")
    private let gotItButton = NSButton(title: "Got It", target: nil, action: nil)
    /// Mirrors the engine state (model download progress, failures) into the
    /// window — without this, a first launch spends minutes "Waiting for
    /// suggestion…" while the model downloads, with no hint anything is
    /// happening (the menu-bar icon alone is easy to miss).
    private var statusTimer: Timer?
    private var suggestionActive = false

    init(controller: SuggestionController) {
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
        
        setupUI()
    }
    
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    
    private func setupUI() {
        container.wantsLayer = true
        container.translatesAutoresizingMaskIntoConstraints = false
        contentView = container
        
        // 1. Backdrop
        visualBackdrop.material = .hudWindow
        visualBackdrop.state = .active
        visualBackdrop.blendingMode = .behindWindow
        visualBackdrop.wantsLayer = true
        visualBackdrop.layer?.cornerRadius = 16
        visualBackdrop.layer?.masksToBounds = true
        visualBackdrop.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(visualBackdrop)
        
        // 2. Main Stack
        let mainStack = NSStackView()
        mainStack.orientation = .vertical
        mainStack.spacing = 16
        mainStack.alignment = .centerX
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        visualBackdrop.addSubview(mainStack)
        
        // Title & Subtitle Stack
        let titleStack = NSStackView()
        titleStack.orientation = .vertical
        titleStack.spacing = 4
        titleStack.alignment = .centerX
        
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleStack.addArrangedSubview(titleLabel)
        
        subtitleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        titleStack.addArrangedSubview(subtitleLabel)
        
        mainStack.addArrangedSubview(titleStack)
        
        // Divider
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        divider.widthAnchor.constraint(equalToConstant: 340).isActive = true
        mainStack.addArrangedSubview(divider)
        
        // Tutorial Rows Stack
        let tutorialStack = NSStackView()
        tutorialStack.orientation = .vertical
        tutorialStack.spacing = 12
        tutorialStack.alignment = .leading
        tutorialStack.translatesAutoresizingMaskIntoConstraints = false
        mainStack.addArrangedSubview(tutorialStack)
        
        // Keycaps follow the configured hotkey — hardcoding Tab taught the wrong
        // keys to anyone on ⌘/⌥/⌃Space. Same labels the menu and overlay use.
        let hotkey = Settings.hotkeyStyle
        let row1 = makeTutorialRow(
            key: makeKeycap(hotkey.label),
            description: "Accept next word"
        )
        tutorialStack.addArrangedSubview(row1)

        let row2 = makeTutorialRow(
            key: makeKeycap(hotkey.shiftLabel),
            description: "Accept entire suggestion"
        )
        tutorialStack.addArrangedSubview(row2)

        let row3 = makeTutorialRow(
            key: makeKeycap(hotkey.correctionLabel),
            description: "Fix last word / selection"
        )
        tutorialStack.addArrangedSubview(row3)
        
        // Footer Stack
        let footerStack = NSStackView()
        footerStack.orientation = .horizontal
        footerStack.spacing = 16
        footerStack.alignment = .centerY
        footerStack.translatesAutoresizingMaskIntoConstraints = false
        
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        footerStack.addArrangedSubview(statusLabel)
        
        gotItButton.target = self
        gotItButton.action = #selector(gotItPressed)
        gotItButton.bezelStyle = .rounded
        gotItButton.controlSize = .regular
        footerStack.addArrangedSubview(gotItButton)
        
        mainStack.addArrangedSubview(footerStack)
        
        // AutoLayout constraints (container IS the contentView — the window
        // sizes it directly, so it needs no constraints of its own)
        NSLayoutConstraint.activate([
            visualBackdrop.topAnchor.constraint(equalTo: container.topAnchor),
            visualBackdrop.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            visualBackdrop.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            visualBackdrop.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            
            mainStack.topAnchor.constraint(equalTo: visualBackdrop.topAnchor, constant: 20),
            mainStack.bottomAnchor.constraint(equalTo: visualBackdrop.bottomAnchor, constant: -20),
            mainStack.leadingAnchor.constraint(equalTo: visualBackdrop.leadingAnchor, constant: 24),
            mainStack.trailingAnchor.constraint(equalTo: visualBackdrop.trailingAnchor, constant: -24),
            
            tutorialStack.widthAnchor.constraint(equalToConstant: 340),
            footerStack.widthAnchor.constraint(equalToConstant: 340)
        ])
    }
    
    private func makeTutorialRow(key: NSView, description: String) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 12
        row.alignment = .centerY
        
        // Keys container stack
        let keysStack = NSStackView()
        keysStack.orientation = .horizontal
        keysStack.spacing = 4
        keysStack.alignment = .centerY
        
        keysStack.addArrangedSubview(key)

        // Wrap keysStack in a fixed-width container so descriptions align nicely
        let keysContainer = NSView()
        keysContainer.translatesAutoresizingMaskIntoConstraints = false
        keysContainer.addSubview(keysStack)
        keysStack.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            keysContainer.widthAnchor.constraint(equalToConstant: 110),
            keysContainer.heightAnchor.constraint(equalToConstant: 24),
            keysStack.leadingAnchor.constraint(equalTo: keysContainer.leadingAnchor),
            keysStack.centerYAnchor.constraint(equalTo: keysContainer.centerYAnchor)
        ])
        
        row.addArrangedSubview(keysContainer)
        
        let descLabel = NSTextField(labelWithString: description)
        descLabel.font = .systemFont(ofSize: 13, weight: .regular)
        descLabel.textColor = .labelColor
        row.addArrangedSubview(descLabel)
        
        return row
    }
    
    private func makeKeycap(_ text: String) -> NSView {
        let keycap = NSView()
        keycap.wantsLayer = true
        keycap.layer?.cornerRadius = 5
        keycap.layer?.borderWidth = 1
        keycap.layer?.borderColor = NSColor.separatorColor.cgColor
        keycap.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        keycap.addSubview(label)
        
        NSLayoutConstraint.activate([
            keycap.heightAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: keycap.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: keycap.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: keycap.centerYAnchor)
        ])
        
        return keycap
    }
    
    func show() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - frame.width / 2
        // Position slightly above center so it is prominent
        let y = screenFrame.midY - frame.height / 3
        setFrameOrigin(CGPoint(x: x, y: y))
        
        alphaValue = 0
        orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }

        refreshEngineStatus()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshEngineStatus()
            }
        }
    }

    /// Same 1 s poll the menu-bar icon uses — no engine callback plumbing.
    private func refreshEngineStatus() {
        guard !suggestionActive else { return }
        switch controller?.engine.state {
        case .preparing(let detail):
            titleLabel.stringValue = "Setting up Pretype"
            subtitleLabel.stringValue = "One-time model download"
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.stringValue = detail
        case .failed(let detail):
            titleLabel.stringValue = "Pretype hit a problem"
            subtitleLabel.stringValue = "The completion engine couldn't start"
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = detail
        case .ready, .none:
            titleLabel.stringValue = "Pretype is Ready"
            subtitleLabel.stringValue = "Try typing in TextEdit"
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.stringValue = "Waiting for suggestion…"
        }
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
    
    @objc private func gotItPressed() {
        Settings.onboardingCompleted = true
        dismiss()
    }
    
    func updateStatusSuggestionActive(_ active: Bool) {
        // apply() calls this on every suggestion; without the edge check the title
        // restarts its blink on each keystroke and refreshEngineStatus() thrashes.
        guard suggestionActive != active else { return }
        suggestionActive = active
        if active {
            statusLabel.textColor = .controlAccentColor
            statusLabel.stringValue = "Suggestion ready! Press \(Settings.hotkeyStyle.label)"

            // Subtle pulse animation on title to draw attention
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.duration = 0.8
                pulse.fromValue = 1.0
                pulse.toValue = 0.5
                pulse.autoreverses = true
                pulse.repeatCount = 3
                titleLabel.layer?.add(pulse, forKey: "pulse")
            }
        } else {
            // The pulse runs ~4.8s; without this it keeps blinking after the
            // suggestion it was pointing at is already gone.
            titleLabel.layer?.removeAnimation(forKey: "pulse")
            refreshEngineStatus()
        }
    }
}
