import AppKit
import QuartzCore

@MainActor
final class OnboardingWindow: NSPanel {
    private weak var controller: SuggestionController?
    
    private let container = NSView()
    private let visualBackdrop = NSVisualEffectView()
    
    private let titleLabel = NSTextField(labelWithString: "Pretype is Ready")
    private let subtitleLabel = NSTextField(labelWithString: Copy.readySubtitle)

    private let statusLabel = NSTextField(wrappingLabelWithString: Copy.waiting)
    private let gotItButton = NSButton(title: "Got It", target: nil, action: nil)
    /// Somewhere to try it without hunting for a text field: a blank TextEdit
    /// document, opened directly (TextEdit launched bare opens its iCloud
    /// Open panel instead of a page to type on).
    private let tryButton = NSButton(title: "Open TextEdit", target: nil, action: nil)
    /// Shown only when the engine failed — the way back without a relaunch.
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)

    private enum Copy {
        static let readySubtitle = "Type in any app — Pretype lives in the menu bar"
        static let waiting = "Type a few words and pause — grey text appears after your cursor."
    }
    /// Mirrors the engine state (model download progress, failures) into the
    /// window — without this, a first launch spends minutes "Waiting for
    /// suggestion…" while the model downloads, with no hint anything is
    /// happening (the menu-bar icon alone is easy to miss).
    private var statusTimer: Timer?
    private var suggestionActive = false

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

        // Without this a new user's only way to make a ghost go away is to
        // type over it — not knowing that is what makes it feel pushy.
        let row4 = makeTutorialRow(
            key: makeKeycap("esc"),
            description: "Dismiss a suggestion"
        )
        tutorialStack.addArrangedSubview(row4)

        // Footer Stack
        let footerStack = NSStackView()
        footerStack.orientation = .horizontal
        footerStack.spacing = 16
        footerStack.alignment = .centerY
        footerStack.translatesAutoresizingMaskIntoConstraints = false
        
        // Two lines, not one truncated one: a failure reason or the waiting
        // instruction is exactly the sentence that must be read in full.
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.preferredMaxLayoutWidth = 340
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        mainStack.addArrangedSubview(statusLabel)

        for (button, action) in [(tryButton, #selector(tryPressed)), (retryButton, #selector(retryPressed)),
                                 (gotItButton, #selector(gotItPressed))] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
            button.controlSize = .regular
        }
        retryButton.isHidden = true
        footerStack.distribution = .gravityAreas
        footerStack.spacing = 8
        footerStack.setViews([tryButton, retryButton, gotItButton], in: .trailing)

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
            statusLabel.widthAnchor.constraint(equalToConstant: 340),
            // Room for two lines in every state, so the card never resizes
            // under the user as the status text changes length.
            statusLabel.heightAnchor.constraint(equalToConstant: 32),
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
            keysContainer.widthAnchor.constraint(equalToConstant: 84),
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
        // Top-right, under the menu bar: centred, it sat on top of the very
        // window it asked the user to type in — and up here it points at
        // where Pretype lives once this card is gone.
        layoutIfNeeded()
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

        refreshEngineStatus()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshEngineStatus()
            }
        }
    }

    /// Same 1 s poll the menu-bar icon uses — no engine callback plumbing.
    private func refreshEngineStatus() {
        guard !suggestionActive, !celebrating else { return }
        let engine = controller?.engine
        var state = engine?.state ?? .ready
        // Idle-unloaded is `.preparing` with nothing running; it reloads on
        // the first keystroke, so for this card it is ready.
        if case .preparing = state, engine?.isLoading == false { state = .ready }
        retryButton.isHidden = true
        tryButton.isHidden = false
        statusLabel.toolTip = nil
        switch state {
        case .preparing(let detail):
            titleLabel.stringValue = "Setting up Pretype"
            // Only a fetch is "one-time"; a model already on disk is loading.
            subtitleLabel.stringValue = detail.hasPrefix("downloading")
                ? "One-time model download" : "Loading the model"
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.stringValue = detail
        case .failed(let detail):
            titleLabel.stringValue = "Pretype hit a problem"
            subtitleLabel.stringValue = "The completion engine couldn't start"
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = detail
            statusLabel.toolTip = detail
            retryButton.isHidden = false
            tryButton.isHidden = true
        case .ready:
            titleLabel.stringValue = "Pretype is Ready"
            subtitleLabel.stringValue = Copy.readySubtitle
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.stringValue = Copy.waiting
        }
    }

    private var celebrating = false

    /// The first accept: say it worked before going, instead of vanishing on
    /// the keystroke — an instant dismissal read as "did I break it?".
    func celebrate() {
        celebrating = true
        titleLabel.layer?.removeAnimation(forKey: "pulse")
        titleLabel.stringValue = "That's it"
        subtitleLabel.stringValue = "Pretype keeps suggesting as you type, in any app"
        statusLabel.textColor = .systemGreen
        statusLabel.stringValue = "✓ Accepted — \(Settings.hotkeyStyle.shiftLabel) takes a whole suggestion next time."
        tryButton.isHidden = true
        retryButton.isHidden = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.dismiss() }
    }

    @objc private func tryPressed() {
        // A blank document to type on: an empty file opened directly, which
        // skips TextEdit's iCloud Open panel.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Try Pretype.txt")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? "".write(to: url, atomically: true, encoding: .utf8)
        }
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: config)
    }

    @objc private func retryPressed() {
        controller?.retryEngine()
        refreshEngineStatus()
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
        guard !celebrating else { return }
        if active {
            // Not the accent colour: with Graphite it is grey, and this is
            // the one line on the card that has to jump out.
            statusLabel.textColor = .labelColor
            statusLabel.stringValue = "See the grey text? Press \(Settings.hotkeyStyle.label) to take a word."

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
