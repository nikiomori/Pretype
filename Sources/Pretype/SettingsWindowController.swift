import AppKit

/// A Liquid Glass settings window (macOS 26; frosted fallback below), wired live
/// to the running pipeline: model/style changes reload the engine; length,
/// persona and personalization apply immediately. Opened from the menu (⌘,).
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSTextFieldDelegate {
    private weak var controller: SuggestionController?

    private let statusLabel = NSTextField(labelWithString: "")
    private let enabledCheck = NSButton(checkboxWithTitle: "Enable suggestions", target: nil, action: nil)
    private let useRecommendedCheck = NSButton(checkboxWithTitle: "Use recommended settings (auto)", target: nil, action: nil)
    private let presentationPicker = PresentationPicker()
    private let presentationDesc = NSTextField(wrappingLabelWithString: "")
    private let styleSlider = NSSlider()
    private let styleDesc = NSTextField(wrappingLabelWithString: "")
    private let lengthSlider = NSSlider()
    private let lengthDesc = NSTextField(wrappingLabelWithString: "")
    private let personalizationPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let forgetButton = NSButton(title: "", target: nil, action: nil)
    private let journalCheck = NSButton(checkboxWithTitle: "Keep suggestion journal", target: nil, action: nil)
    private let journalClearButton = NSButton(title: "", target: nil, action: nil)
    private let modelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fineTunedButton = NSButton(title: "Fine-tuned…", target: nil, action: nil)
    private let modelRecLabel = NSTextField(wrappingLabelWithString: "")
    private let fmVariantPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var fmVariantViews: [NSView] = []
    private let idleUnloadPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let screenContextCheck = NSButton(checkboxWithTitle: "Use screen context (OCR)", target: nil, action: nil)
    private let fimCheck = NSButton(checkboxWithTitle: "Smart mid-sentence completion (fill-in-the-middle)", target: nil, action: nil)
    private let confidenceGateCheck = NSButton(checkboxWithTitle: "High-precision mode (confidence gate)", target: nil, action: nil)
    private let blacklistTextField = NSTextField()
    private let hotkeyStylePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let ghostOpacitySlider = NSSlider()
    private var instructionsTextView: NSTextView!
    private var statusTimer: Timer?

    private let contentWidth: CGFloat = 500
    private let controlWidth: CGFloat = 320

    init(controller: SuggestionController) {
        self.controller = controller
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Pretype Settings"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        super.init(window: window)
        window.delegate = self
        buildUI()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        sync()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        startStatusTimer()
    }

    // MARK: - Layout

    private func buildUI() {
        guard let window else { return }
        let content = NSView()
        window.contentView = content
        installBackground(in: content)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        enabledCheck.target = self
        enabledCheck.action = #selector(toggleEnabled)
        useRecommendedCheck.target = self
        useRecommendedCheck.action = #selector(toggleUseRecommended)
        screenContextCheck.target = self
        screenContextCheck.action = #selector(toggleScreenContext)
        fimCheck.target = self
        fimCheck.action = #selector(toggleFIM)
        confidenceGateCheck.target = self
        confidenceGateCheck.action = #selector(toggleConfidenceGate)

        presentationPicker.onSelect = { [weak self] mode in
            self?.controller?.setSuggestionPresentation(mode)
            self?.updatePresentationDescription(mode)
        }
        configureSlider(styleSlider, ticks: 2, action: #selector(styleChanged))
        configureSlider(lengthSlider, ticks: 3, action: #selector(lengthChanged))
        for desc in [presentationDesc, styleDesc, lengthDesc, modelRecLabel] {
            desc.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
            desc.preferredMaxLayoutWidth = contentWidth
        }

        configurePopup(hotkeyStylePopup, action: #selector(hotkeyStyleChanged), items: HotkeyStyle.allCases.map { ($0.label, $0.rawValue) })
        ghostOpacitySlider.target = self
        ghostOpacitySlider.action = #selector(ghostOpacityChanged)
        ghostOpacitySlider.minValue = 0.1
        ghostOpacitySlider.maxValue = 1.0
        ghostOpacitySlider.widthAnchor.constraint(equalToConstant: controlWidth).isActive = true

        configurePopup(personalizationPopup, action: #selector(personalizationChanged), items: [
            ("Off", PersonalizationLevel.off.rawValue),
            ("Subtle", PersonalizationLevel.subtle.rawValue),
            ("Medium", PersonalizationLevel.medium.rawValue),
            ("Strong", PersonalizationLevel.strong.rawValue),
        ])
        forgetButton.target = self
        forgetButton.action = #selector(forgetPersonalization)
        forgetButton.bezelStyle = .rounded
        forgetButton.controlSize = .small
        journalCheck.target = self
        journalCheck.action = #selector(toggleJournal)
        journalClearButton.target = self
        journalClearButton.action = #selector(clearJournal)
        journalClearButton.bezelStyle = .rounded
        journalClearButton.controlSize = .small
        buildModelPopup()
        // The longest catalog title would otherwise stretch the popup (and the
        // whole tab) past the window; the dropdown list still shows full names.
        modelPopup.widthAnchor.constraint(equalToConstant: 250).isActive = true
        (modelPopup.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingTail
        fineTunedButton.target = self
        fineTunedButton.action = #selector(loadFineTunedModel)
        fineTunedButton.bezelStyle = .rounded
        fineTunedButton.controlSize = .small
        // Measured on eval-v2: fewshot best quality, directive fastest.
        configurePopup(fmVariantPopup, action: #selector(fmVariantChanged), items: [
            ("Examples — best quality", FMPromptVariant.fewshot.rawValue),
            ("Terse — lean instructions", FMPromptVariant.terse.rawValue),
            ("Plain — no scaffold", FMPromptVariant.plain.rawValue),
            ("Directive — fastest, full coverage", FMPromptVariant.directive.rawValue),
        ])
        configurePopup(idleUnloadPopup, action: #selector(idleUnloadChanged), items: [
            ("Never", "0"),
            ("After 1 minute", "1"),
            ("After 5 minutes", "5"),
            ("After 15 minutes", "15"),
            ("After 30 minutes", "30"),
        ])

        blacklistTextField.delegate = self
        blacklistTextField.target = self
        blacklistTextField.action = #selector(blacklistChanged)
        blacklistTextField.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        blacklistTextField.placeholderString = "e.g., vscode, cursor, terminal"

        let instructionsScroll = NSTextView.scrollableTextView()
        instructionsScroll.borderType = .lineBorder
        instructionsScroll.hasVerticalScroller = true
        instructionsScroll.drawsBackground = false
        instructionsScroll.translatesAutoresizingMaskIntoConstraints = false
        instructionsScroll.heightAnchor.constraint(equalToConstant: 88).isActive = true
        instructionsScroll.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        instructionsTextView = (instructionsScroll.documentView as! NSTextView)
        instructionsTextView.isRichText = false
        instructionsTextView.drawsBackground = false
        instructionsTextView.font = .systemFont(ofSize: 12)
        instructionsTextView.delegate = self
        instructionsTextView.textContainerInset = NSSize(width: 4, height: 6)

        let resetButton = NSButton(title: "Reset to System", target: self, action: #selector(resetInstructions))
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small

        let personalizationRow = NSStackView(views: [personalizationPopup, forgetButton])
        personalizationRow.spacing = 8

        let journalRow = NSStackView(views: [journalCheck, journalClearButton])
        journalRow.spacing = 8

        let modelRow = NSStackView(views: [modelPopup, fineTunedButton])
        modelRow.spacing = 8

        // Recipe steers only the Apple Intelligence engine — hidden for MLX models.
        let fmVariantRow = row("Recipe", fmVariantPopup)
        let fmVariantCaption = caption("Prompt recipe for the Apple Intelligence engine. Examples is the most accurate; Directive the fastest.")
        fmVariantViews = [fmVariantRow, fmVariantCaption]

        // One tab per topic instead of one long scroll — much easier to scan.
        let generalStack = vstack([
            header("Suggestion display"),
            presentationPicker,
            presentationDesc,
            spacer(6),
            row("Hotkey style", hotkeyStylePopup),
            caption("The shortcut to accept completions, or trigger rewrites and fixes."),
            spacer(4),
            row("Ghost opacity", ghostOpacitySlider),
            caption("Adjust readability contrast of the inline ghost suggestions."),
            spacer(6),
            separator(),
            header("Blacklisted apps"),
            caption("Disable autocomplete in specific applications. Enter bundle IDs or names, comma-separated (e.g. vscode, iterm, slack):"),
            blacklistTextField,
        ])

        let completionStack = vstack([
            useRecommendedCheck,
            caption("On: Style and Length follow what's best for the selected model and update when you switch models. Turn off to tune them by hand."),
            spacer(6),
            header("Style"),
            sliderRow(styleSlider, labels: ["Instruct", "Base"]),
            styleDesc,
            spacer(2),
            confidenceGateCheck,
            caption("Suggests only when the model agrees with itself across several tries — much more accurate on real text (≈39% first-word vs ~19%), but fires less often and adds latency. Available in Base style on an E4B model (≥6-bit)."),
            spacer(6),
            header("Length"),
            sliderRow(lengthSlider, labels: ["Short", "Medium", "Long"]),
            lengthDesc,
        ])

        let personaStack = vstack([
            caption("Auto-filled from your account name and keyboard languages — steers Instruct mode. Edit freely; it stays on your Mac."),
            instructionsScroll,
            resetButton,
            spacer(8),
            separator(),
            row("Learn my words", personalizationRow),
            caption("Biases completions toward words you accept. Collected only while on; nothing leaves your Mac."),
            spacer(8),
            separator(),
            journalRow,
            caption("Records which suggestions you accept, dismiss or type past — the raw data for quality tuning and future personalization. Stays in Application Support on your Mac; the on-screen OCR text is never written."),
        ])

        let modelStack = vstack([
            row("Model", modelRow),
            modelRecLabel,
            caption("Auto-picked for your Mac's memory. Instruct mode always runs a tuned 6-bit model; this choice is the Base-mode model."),
            fmVariantRow,
            fmVariantCaption,
            spacer(4),
            row("Free when idle", idleUnloadPopup),
            caption("Unloads the model after this long unused so Pretype isn't holding several GB idle; the next keystroke reloads it (a focus change pre-warms it)."),
            spacer(6),
            separator(),
            screenContextCheck,
            fimCheck,
            caption("Fill-in uses the text after the cursor for mid-line edits — E4B Instruct only; auto-skipped on the smaller E2B."),
        ])

        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        let tabStacks = [generalStack, completionStack, personaStack, modelStack]
        for (label, stack) in zip(["General", "Completion", "Persona", "Model"], tabStacks) {
            tabView.addTabViewItem(tab(label, stack))
        }

        // Master switch + live engine status, visible on every tab.
        let top = NSStackView(views: [enabledCheck, statusLabel])
        top.orientation = .vertical
        top.alignment = .leading
        top.spacing = 4
        top.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(top)
        content.addSubview(tabView)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 42),
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            top.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -22),
            tabView.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10),
            tabView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            tabView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            tabView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])

        // Fit the window to the tallest tab (captions report their wrapped
        // height thanks to preferredMaxLayoutWidth), plus top bar + tab chrome.
        let tallest = tabStacks.map { ceil($0.fittingSize.height) }.max() ?? 460
        window.setContentSize(NSSize(width: 600, height: tallest + 176))
        window.minSize = NSSize(width: 600, height: 420)
    }

    private func vstack(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return stack
    }

    private func tab(_ label: String, _ stack: NSStackView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: label)
        item.label = label
        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -14),
        ])
        item.view = container
        return item
    }

    /// Liquid Glass fills the window *behind* the controls (macOS 26); a frosted
    /// visual-effect view below it. Added first so it sits at the back.
    private func installBackground(in content: NSView) {
        let background: NSView
        if #available(macOS 26.0, *) {
            window?.isOpaque = false
            window?.backgroundColor = .clear
            let glass = NSGlassEffectView()
            glass.style = .regular
            background = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .windowBackground
            effect.state = .active
            background = effect
        }
        background.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(background)
        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: content.topAnchor),
            background.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            background.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    private func configureSlider(_ slider: NSSlider, ticks: Int, action: Selector) {
        slider.target = self
        slider.action = action
        slider.minValue = 0
        slider.maxValue = Double(ticks - 1)
        slider.numberOfTickMarks = ticks
        slider.allowsTickMarkValuesOnly = true
        slider.tickMarkPosition = .below
        slider.widthAnchor.constraint(equalToConstant: controlWidth).isActive = true
    }

    /// A slider with its option names spread underneath, aligned to the ticks.
    private func sliderRow(_ slider: NSSlider, labels: [String]) -> NSView {
        let tickLabels = labels.map { name -> NSTextField in
            let label = NSTextField(labelWithString: name)
            label.font = .systemFont(ofSize: 10)
            label.textColor = .secondaryLabelColor
            return label
        }
        let labelRow = NSStackView(views: tickLabels)
        labelRow.distribution = .equalCentering
        labelRow.widthAnchor.constraint(equalToConstant: controlWidth).isActive = true
        let column = NSStackView(views: [slider, labelRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        return column
    }

    private func configurePopup(_ popup: NSPopUpButton, action: Selector, items: [(String, String)]) {
        popup.target = self
        popup.action = action
        popup.removeAllItems()
        for (title, tag) in items {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = tag
            popup.menu?.addItem(item)
        }
    }

    private func buildModelPopup() {
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged)
        modelPopup.removeAllItems()
        for entry in SettingsUI.modelEntries() {
            let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
            item.representedObject = entry.id
            modelPopup.menu?.addItem(item)
        }
        let current = Settings.mlxModelID
        if current.hasPrefix("/"),
           modelPopup.menu?.items.contains(where: { $0.representedObject as? String == current }) == false {
            let item = NSMenuItem(title: "Fine-tuned: \((current as NSString).lastPathComponent)", action: nil, keyEquivalent: "")
            item.representedObject = current
            modelPopup.menu?.addItem(item)
        }
    }

    // MARK: - Sync

    private func sync() {
        enabledCheck.state = Settings.enabled ? .on : .off
        screenContextCheck.state = Settings.screenContextEnabled ? .on : .off
        fimCheck.state = Settings.fimEnabled ? .on : .off
        syncConfidenceGate()
        updateModelRecommendation()
        presentationPicker.selected = Settings.suggestionPresentation
        updatePresentationDescription(Settings.suggestionPresentation)
        styleSlider.doubleValue = Settings.completionStyle == .instruct ? 0 : 1
        lengthSlider.doubleValue = Double([CompletionLength.short, .medium, .long].firstIndex(of: Settings.completionLength) ?? 0)
        updateStyleDescription()
        updateLengthDescription()
        let auto = Settings.useRecommendedSettings
        useRecommendedCheck.state = auto ? .on : .off
        styleSlider.isEnabled = !auto   // greyed in auto mode — the model drives them
        lengthSlider.isEnabled = !auto
        select(personalizationPopup, Settings.personalizationLevel.rawValue)
        select(hotkeyStylePopup, Settings.hotkeyStyle.rawValue)
        ghostOpacitySlider.doubleValue = Settings.ghostOpacity
        select(modelPopup, Settings.mlxModelID)
        select(fmVariantPopup, Settings.fmPromptVariant.rawValue)
        select(idleUnloadPopup, String(Settings.idleUnloadMinutes))
        instructionsTextView.string = Settings.customInstructions
        blacklistTextField.stringValue = Settings.userBlacklist.joined(separator: ", ")
        journalCheck.state = Settings.suggestionJournalEnabled ? .on : .off
        updateForgetTitle()
        updateJournalClearTitle()
        refreshStatus()
    }

    /// The confidence gate is a Base-mode feature on a capable E4B model — keep
    /// the checkbox enabled only there, so it never reads as "on but doing nothing".
    private func syncConfidenceGate() {
        let usable = SettingsUI.confidenceGateUsable()
        confidenceGateCheck.isEnabled = usable
        confidenceGateCheck.state = (usable && Settings.confidenceGate) ? .on : .off
    }

    /// Surface the model's recommended settings (and grey fill-in where it can't
    /// run), so picking a model visibly shows what's best for it.
    private func updateModelRecommendation() {
        let rec = ModelCatalog.recommended(for: Settings.mlxModelID)
        modelRecLabel.attributedStringValue = describe("Best for this model", rec.summary)
        fimCheck.isEnabled = rec.fim
        fimCheck.state = (rec.fim && Settings.fimEnabled) ? .on : .off
        let fmActive = Settings.mlxModelID == ModelCatalog.appleIntelligenceID
        for view in fmVariantViews { view.isHidden = !fmActive }
    }

    private func select(_ popup: NSPopUpButton, _ value: String) {
        if let item = popup.menu?.items.first(where: { $0.representedObject as? String == value }) {
            popup.select(item)
        }
    }

    private func describe(_ name: String, _ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "\(name) — ", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ])
        result.append(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return result
    }

    private func updatePresentationDescription(_ mode: SuggestionPresentation) {
        presentationDesc.attributedStringValue = mode == .inline
            ? describe("Inline", "Ghost text continues your line right at the cursor (Cotypist-style) — same size and baseline, seamless in native and Chromium/Electron apps. Tab accepts.")
            : describe("Panel", "A small floating box beside the cursor shows the suggestion with a ⇥ hint. More legible on busy backgrounds, never overlaps your text, and forgiving when the cursor can only be estimated.")
    }

    private func updateStyleDescription() {
        styleDesc.attributedStringValue = styleSlider.doubleValue.rounded() == 0
            ? describe("Instruct", "Steers a 6-bit instruct model (~6.8 GB) with your persona. Best quality — ~85% first-word in our eval, and much stronger on Russian. Warm latency ~0.15 s per keystroke. Recommended.")
            : describe("Base", "Plain next-word continuation — no persona. More literal, so it predicts real text better and unlocks High-precision mode below; the trade-off is no voice or length steering.")
    }

    private func updateLengthDescription() {
        switch Int(lengthSlider.doubleValue.rounded()) {
        case 0:
            lengthDesc.attributedStringValue = describe("Short", "2–3 words. Fastest to generate and least likely to drift from your intent — the least intrusive option.")
        case 2:
            lengthDesc.attributedStringValue = describe("Long", "Up to a full sentence. Saves the most typing per accept, but the slowest to generate and the most likely to wander off — Tab still takes just the first word.")
        default:
            lengthDesc.attributedStringValue = describe("Medium", "About 6 words. Saves more typing per accept; a little slower to generate and slightly more prone to drift.")
        }
    }

    private func updateForgetTitle() {
        let count = Personalization.shared.wordCount
        forgetButton.title = count > 0 ? "Forget \(count) words" : "Nothing learned yet"
        forgetButton.isEnabled = count > 0
    }

    private func updateJournalClearTitle() {
        let size = SuggestionJournal.shared.fileSize
        journalClearButton.title = size > 0
            ? "Clear (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))"
            : "Empty"
        journalClearButton.isEnabled = size > 0
    }

    private func startStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
    }

    private func refreshStatus() {
        guard let engine = controller?.engine else { statusLabel.stringValue = ""; return }
        let state: String
        switch engine.state {
        case .ready: state = "● Ready"
        case .preparing(let detail): state = "⏳ \(detail)"
        case .failed(let detail): state = "⚠︎ \(detail)"
        }
        statusLabel.stringValue = "\(engine.name) — \(state)"
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        Settings.enabled = enabledCheck.state == .on
        if !Settings.enabled { controller?.dismiss() }
    }

    @objc private func hotkeyStyleChanged() {
        if let raw = hotkeyStylePopup.selectedItem?.representedObject as? String,
           let style = HotkeyStyle(rawValue: raw) {
            Settings.hotkeyStyle = style
            controller?.dismiss()
            sync()
        }
    }

    @objc private func ghostOpacityChanged() {
        Settings.ghostOpacity = ghostOpacitySlider.doubleValue
    }

    @objc private func toggleUseRecommended() {
        Settings.useRecommendedSettings = useRecommendedCheck.state == .on
        // Turning auto on snaps Style + Length to the model's recommendation.
        if Settings.useRecommendedSettings { controller?.applyRecommendedSettings() }
        sync()
    }

    @objc private func toggleFIM() {
        Settings.fimEnabled = fimCheck.state == .on
    }

    @objc private func toggleConfidenceGate() {
        controller?.setConfidenceGate(confidenceGateCheck.state == .on)
    }

    @objc private func styleChanged() {
        let style: CompletionStyle = styleSlider.doubleValue.rounded() == 0 ? .instruct : .base
        controller?.setCompletionStyle(style)
        updateStyleDescription()
        syncConfidenceGate()
        refreshStatus()
    }

    @objc private func lengthChanged() {
        let length = [CompletionLength.short, .medium, .long][min(max(Int(lengthSlider.doubleValue.rounded()), 0), 2)]
        controller?.setCompletionLength(length)
        updateLengthDescription()
    }

    @objc private func personalizationChanged() {
        if let raw = personalizationPopup.selectedItem?.representedObject as? String,
           let level = PersonalizationLevel(rawValue: raw) {
            controller?.setPersonalization(level)
            updateForgetTitle()
        }
    }

    @objc private func modelChanged() {
        if let id = modelPopup.selectedItem?.representedObject as? String {
            controller?.setModel(id)
            syncConfidenceGate()
            updateModelRecommendation()
            refreshStatus()
        }
    }

    @objc private func loadFineTunedModel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Model"
        panel.message = "Choose a fused fine-tuned model folder (with config.json + safetensors)."
        if panel.runModal() == .OK, let url = panel.url {
            controller?.setModel(url.path)
            buildModelPopup()   // list the new fine-tuned entry
            sync()
        }
    }

    @objc private func fmVariantChanged() {
        if let raw = fmVariantPopup.selectedItem?.representedObject as? String,
           let variant = FMPromptVariant(rawValue: raw) {
            controller?.setFMPromptVariant(variant)
        }
    }

    @objc private func idleUnloadChanged() {
        if let raw = idleUnloadPopup.selectedItem?.representedObject as? String,
           let minutes = Int(raw) {
            Settings.idleUnloadMinutes = minutes
        }
    }

    @objc private func forgetPersonalization() {
        Personalization.shared.reset()
        updateForgetTitle()
    }

    @objc private func toggleJournal() {
        Settings.suggestionJournalEnabled = journalCheck.state == .on
    }

    @objc private func clearJournal() {
        SuggestionJournal.shared.reset()
        updateJournalClearTitle()
    }

    @objc private func resetInstructions() {
        instructionsTextView.string = Settings.defaultInstructions
        controller?.setCustomInstructions(Settings.defaultInstructions)
    }

    @objc private func toggleScreenContext() {
        SettingsUI.setScreenContext(screenContextCheck.state == .on)
    }

    @objc private func blacklistChanged() {
        let text = blacklistTextField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let list = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
        Settings.userBlacklist = list
        controller?.dismiss()
    }

    func controlTextDidChange(_ obj: Notification) {
        if let textField = obj.object as? NSTextField, textField === blacklistTextField {
            blacklistChanged()
        }
    }

    func textDidChange(_ notification: Notification) {
        controller?.setCustomInstructions(instructionsTextView.string)
    }

    // MARK: - Window lifecycle

    func windowWillClose(_ notification: Notification) {
        controller?.setCustomInstructions(instructionsTextView.string)
        statusTimer?.invalidate()
        statusTimer = nil
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Builders

    private func header(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        return label
    }

    private func caption(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 10)
        label.textColor = .tertiaryLabelColor
        label.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        label.preferredMaxLayoutWidth = contentWidth   // wraps correctly when measured before display
        return label
    }

    private func row(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let stack = NSStackView(views: [label, control])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        return stack
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        return box
    }

    private func spacer(_ height: CGFloat) -> NSView {
        let view = NSView()
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }
}

/// Two selectable preview cards — each renders a miniature of how that mode looks
/// at the caret — so the choice is visual, not abstract. Clearer than a slider.
final class PresentationPicker: NSStackView {
    var onSelect: ((SuggestionPresentation) -> Void)?
    private let inlineCard = ModeCard(mode: .inline, title: "Inline")
    private let panelCard = ModeCard(mode: .panel, title: "Panel")

    var selected: SuggestionPresentation = .inline {
        didSet {
            inlineCard.isSelected = selected == .inline
            panelCard.isSelected = selected == .panel
        }
    }

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 12
        addArrangedSubview(inlineCard)
        addArrangedSubview(panelCard)
        inlineCard.onClick = { [weak self] in self?.choose(.inline) }
        panelCard.onClick = { [weak self] in self?.choose(.panel) }
        selected = .inline
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func choose(_ mode: SuggestionPresentation) {
        guard mode != selected else { return }
        selected = mode
        onSelect?(mode)
    }
}

/// One preview card: a faux text line in a field, drawn either as inline ghost
/// text or as a floating box, plus a title and a selection ring.
private final class ModeCard: NSView {
    let mode: SuggestionPresentation
    private let title: String
    var onClick: (() -> Void)?
    var isSelected = false { didSet { needsDisplay = true } }

    init(mode: SuggestionPresentation, title: String) {
        self.mode = mode
        self.title = title
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 226).isActive = true
        heightAnchor.constraint(equalToConstant: 96).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        let card = bounds.insetBy(dx: 1.5, dy: 1.5)
        let cardPath = NSBezierPath(roundedRect: card, xRadius: 10, yRadius: 10)
        (isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.08)
                    : NSColor.windowBackgroundColor.withAlphaComponent(0.5)).setFill()
        cardPath.fill()
        (isSelected ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        cardPath.lineWidth = isSelected ? 2 : 1
        cardPath.stroke()

        // Faux text field holding the preview.
        let sample = NSRect(x: card.minX + 12, y: card.minY + 12, width: card.width - 24, height: 44)
        let samplePath = NSBezierPath(roundedRect: sample, xRadius: 6, yRadius: 6)
        NSColor.textBackgroundColor.setFill()
        samplePath.fill()
        NSColor.separatorColor.withAlphaComponent(0.6).setStroke()
        samplePath.lineWidth = 1
        samplePath.stroke()
        drawPreview(in: sample.insetBy(dx: 10, dy: 0))

        // Title + checkmark (selection shown by the ring + check, so the title
        // stays its normal weight/color regardless of the system accent).
        (title as NSString).draw(at: CGPoint(x: card.minX + 12, y: sample.maxY + 9), withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ])
        if isSelected {
            let dia: CGFloat = 16
            let circle = NSRect(x: card.maxX - dia - 10, y: sample.maxY + 8, width: dia, height: dia)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: circle).fill()
            let check = NSAttributedString(string: "✓", attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: NSColor.white,
            ])
            let size = check.size()
            check.draw(at: CGPoint(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2))
        }
    }

    /// Draws "Write " then the completion — inline ghost vs a small floating box.
    private func drawPreview(in rect: NSRect) {
        let font = NSFont.systemFont(ofSize: 13)
        let typed = NSAttributedString(string: "Write ", attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        let lineHeight = typed.size().height
        let textY = rect.midY - lineHeight / 2
        typed.draw(at: CGPoint(x: rect.minX, y: textY))
        let caretX = rect.minX + typed.size().width

        if mode == .inline {
            // Seamless gray continuation on the same baseline.
            NSAttributedString(string: "a reply", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
                .draw(at: CGPoint(x: caretX, y: textY))
        } else {
            // A small rounded box beside the caret with the text + ⇥ hint.
            let boxText = NSMutableAttributedString(string: "a reply", attributes: [
                .font: font, .foregroundColor: NSColor.secondaryLabelColor,
            ])
            boxText.append(NSAttributedString(string: "  ⇥", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
            let ts = boxText.size()
            let padH: CGFloat = 6, padV: CGFloat = 3
            let box = NSRect(x: caretX + 3, y: rect.midY - (ts.height / 2 + padV),
                             width: ts.width + padH * 2, height: ts.height + padV * 2)
            let boxPath = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
            NSColor.secondaryLabelColor.withAlphaComponent(0.22).setFill()
            boxPath.fill()
            boxText.draw(at: CGPoint(x: box.minX + padH, y: box.midY - ts.height / 2))
        }
    }
}
