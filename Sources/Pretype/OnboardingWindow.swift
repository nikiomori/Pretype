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
        
        // Row 1: Tab
        let row1 = makeTutorialRow(
            keys: [makeKeycap("Tab")],
            description: "Accept next word"
        )
        tutorialStack.addArrangedSubview(row1)
        
        // Row 2: Shift + Tab
        let row2 = makeTutorialRow(
            keys: [makeKeycap("Shift"), makeKeycap("Tab")],
            description: "Accept entire suggestion"
        )
        tutorialStack.addArrangedSubview(row2)
        
        // Row 3: Option + Tab
        let row3 = makeTutorialRow(
            keys: [makeKeycap("Option"), makeKeycap("Tab")],
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
        footerStack.addArrangedSubview(statusLabel)
        
        gotItButton.target = self
        gotItButton.action = #selector(gotItPressed)
        gotItButton.bezelStyle = .rounded
        gotItButton.controlSize = .regular
        footerStack.addArrangedSubview(gotItButton)
        
        mainStack.addArrangedSubview(footerStack)
        
        // AutoLayout constraints
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: contentView!.topAnchor),
            container.bottomAnchor.constraint(equalTo: contentView!.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: contentView!.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: contentView!.trailingAnchor),
            
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
    
    private func makeTutorialRow(keys: [NSView], description: String) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 12
        row.alignment = .centerY
        
        // Keys container stack
        let keysStack = NSStackView()
        keysStack.orientation = .horizontal
        keysStack.spacing = 4
        keysStack.alignment = .centerY
        
        for (index, key) in keys.enumerated() {
            if index > 0 {
                let plusLabel = NSTextField(labelWithString: "+")
                plusLabel.font = .systemFont(ofSize: 11, weight: .bold)
                plusLabel.textColor = .tertiaryLabelColor
                keysStack.addArrangedSubview(plusLabel)
            }
            keysStack.addArrangedSubview(key)
        }
        
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
    
    @objc private func gotItPressed() {
        Settings.onboardingCompleted = true
        dismiss()
    }
    
    func updateStatusSuggestionActive(_ active: Bool) {
        if active {
            statusLabel.textColor = .controlAccentColor
            statusLabel.stringValue = "Suggestion ready! Press Tab"
            
            // Subtle pulse animation on title to draw attention
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.duration = 0.8
            pulse.fromValue = 1.0
            pulse.toValue = 0.5
            pulse.autoreverses = true
            pulse.repeatCount = 3
            titleLabel.layer?.add(pulse, forKey: "pulse")
        } else {
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.stringValue = "Waiting for suggestion…"
        }
    }
}
