import AppKit

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private weak var suggestionController: SuggestionController?

    private var statusLineItem: NSMenuItem!
    private var statsItems: [NSMenuItem] = []
    private var contextMenu: NSMenu!
    private var diagnosticsMenu: NSMenu!
    private var permissionItem: NSMenuItem!
    private var enabledItem: NSMenuItem!
    private var screenContextItem: NSMenuItem!
    private var modelItems: [String: NSMenuItem] = [:]
    private var fineTunedItem: NSMenuItem!
    private var styleItems: [CompletionStyle: NSMenuItem] = [:]
    private var lengthItems: [CompletionLength: NSMenuItem] = [:]
    private var presentationItems: [SuggestionPresentation: NSMenuItem] = [:]
    private var fimItem: NSMenuItem!
    private var confidenceGateItem: NSMenuItem!
    private var useRecommendedItem: NSMenuItem!
    private var personalizationItems: [PersonalizationLevel: NSMenuItem] = [:]
    private var forgetItem: NSMenuItem!
    private var fmVariantItems: [FMPromptVariant: NSMenuItem] = [:]
    private var fmVariantHeader: NSMenuItem!
    private var fmVariantSeparator: NSMenuItem!

    private var statusTimer: Timer?
    private var settingsWindow: SettingsWindowController?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = statusItem.button {
            button.image = BrandMark.statusItemImage(.ready)
            button.image?.accessibilityDescription = "pretype.ready"
        }
        buildMenu()
        menu.delegate = self
        statusItem.menu = menu
        // Live status light: the icon reflects engine state at a glance even
        // when the menu is closed, so "no suggestion" is never a silent mystery.
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatusIcon()
            }
        }
        updateStatusIcon()
    }

    /// Maps engine/permission/enabled state to the menu-bar symbol + tooltip.
    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        // Always the Pretype mark; the caret morphs to reflect state.
        let state: BrandMark.State
        if !Permissions.isTrusted {
            state = .failed                       // attention: Accessibility not granted
        } else if !Settings.enabled {
            state = .disabled                     // paused
        } else {
            switch suggestionController?.engine.state {
            case .ready, .none: state = .ready
            case .preparing: state = .preparing   // downloading / loading model
            case .failed: state = .failed         // engine not working
            }
        }
        let id = "pretype.\(state.rawValue)"
        if button.image?.accessibilityDescription != id {
            let mark = BrandMark.statusItemImage(state)
            mark.accessibilityDescription = id
            button.image = mark
        }
        // The last pipeline event explains per-app silence on hover ("off in
        // terminal apps", "lost text element", "engine returned no suggestion").
        var tip = "Pretype — \(statusSummary())"
        if let last = suggestionController?.lastEvent { tip += "\nLast: \(last)" }
        button.toolTip = tip
    }

    func bind(to controller: SuggestionController) {
        suggestionController = controller
    }

    private func buildMenu() {
        statusLineItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
        menu.addItem(statusLineItem)

        for _ in 0..<4 {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            statsItems.append(item)
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        contextMenu = NSMenu()
        let contextItem = NSMenuItem(title: "Context", action: nil, keyEquivalent: "")
        contextItem.submenu = contextMenu
        menu.addItem(contextItem)

        diagnosticsMenu = NSMenu()
        let diagnosticsItem = NSMenuItem(title: "Diagnostics", action: nil, keyEquivalent: "")
        diagnosticsItem.submenu = diagnosticsMenu
        menu.addItem(diagnosticsItem)

        let debugItem = NSMenuItem(title: "Debug Console…", action: #selector(openDebugConsole), keyEquivalent: "d")
        debugItem.target = self
        menu.addItem(debugItem)

        menu.addItem(.separator())

        permissionItem = NSMenuItem(
            title: "Grant Accessibility permission…",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        permissionItem.target = self
        menu.addItem(permissionItem)

        enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        menu.addItem(enabledItem)

        screenContextItem = NSMenuItem(
            title: "Use Screen Context (OCR)",
            action: #selector(toggleScreenContext),
            keyEquivalent: ""
        )
        screenContextItem.target = self
        menu.addItem(screenContextItem)

        let modelMenu = NSMenu()
        for entry in SettingsUI.modelEntries(includeAppleIntelligenceSize: true) {
            let item = NSMenuItem(title: entry.title, action: #selector(selectModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.id
            modelMenu.addItem(item)
            modelItems[entry.id] = item
        }
        modelMenu.addItem(.separator())
        fineTunedItem = NSMenuItem(
            title: "Load fine-tuned model…",
            action: #selector(loadFineTunedModel),
            keyEquivalent: ""
        )
        fineTunedItem.target = self
        modelMenu.addItem(fineTunedItem)
        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)

        let completionItem = NSMenuItem(title: "Completion", action: nil, keyEquivalent: "")
        completionItem.submenu = buildCompletionMenu()
        menu.addItem(completionItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "⇥ word · ⇧⇥ all · ⌥⇥ fix selection / last word → ⏎ apply · esc keep", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(
            title: "Quit Pretype",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
    }

    private func buildCompletionMenu() -> NSMenu {
        let completionMenu = NSMenu()
        // We disable the confidence-gate item on models it can't help; NSMenu's
        // default auto-enabling would override that, so manage enablement here.
        completionMenu.autoenablesItems = false

        useRecommendedItem = NSMenuItem(title: "Use recommended settings (auto)",
                                        action: #selector(toggleUseRecommended), keyEquivalent: "")
        useRecommendedItem.target = self
        useRecommendedItem.toolTip = "Style and Length follow what's best for the selected model. Turn off to choose them yourself."
        completionMenu.addItem(useRecommendedItem)
        completionMenu.addItem(.separator())

        let styleHeader = NSMenuItem(title: "Style", action: nil, keyEquivalent: "")
        styleHeader.isEnabled = false
        completionMenu.addItem(styleHeader)
        let styleTitles: [CompletionStyle: String] = [
            .base: "Base — raw continuation",
            .instruct: "Instruct — persona-aware",
        ]
        for style in CompletionStyle.allCases {
            let item = NSMenuItem(title: styleTitles[style] ?? style.rawValue,
                                  action: #selector(selectStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            completionMenu.addItem(item)
            styleItems[style] = item
        }

        completionMenu.addItem(.separator())
        let lengthHeader = NSMenuItem(title: "Length", action: nil, keyEquivalent: "")
        lengthHeader.isEnabled = false
        completionMenu.addItem(lengthHeader)
        let lengthTitles: [CompletionLength: String] = [
            .word: "Word — single word (great for Apple Intelligence)",
            .short: "Short — 2–3 words",
            .medium: "Medium — ~6 words",
            .long: "Long — up to a sentence",
        ]
        for length in CompletionLength.allCases {
            let item = NSMenuItem(title: lengthTitles[length] ?? length.rawValue,
                                  action: #selector(selectLength(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = length.rawValue
            completionMenu.addItem(item)
            lengthItems[length] = item
        }

        completionMenu.addItem(.separator())
        let displayHeader = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
        displayHeader.isEnabled = false
        completionMenu.addItem(displayHeader)
        let presentationTitles: [SuggestionPresentation: String] = [
            .inline: "Inline — ghost text at cursor",
            .panel: "Panel — floating box",
        ]
        for presentation in SuggestionPresentation.allCases {
            let item = NSMenuItem(title: presentationTitles[presentation] ?? presentation.rawValue,
                                  action: #selector(selectPresentation(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = presentation.rawValue
            completionMenu.addItem(item)
            presentationItems[presentation] = item
        }

        completionMenu.addItem(.separator())
        fimItem = NSMenuItem(title: "Smart mid-sentence completion (fill-in)",
                             action: #selector(toggleFIM), keyEquivalent: "")
        fimItem.target = self
        completionMenu.addItem(fimItem)

        confidenceGateItem = NSMenuItem(title: "High-precision mode (confidence gate)",
                                        action: #selector(toggleConfidenceGate), keyEquivalent: "")
        confidenceGateItem.target = self
        confidenceGateItem.toolTip = "Only suggest when the model agrees with itself across several tries — "
            + "fewer but far more accurate suggestions on real text. Best with Base style; costs extra latency."
        completionMenu.addItem(confidenceGateItem)

        completionMenu.addItem(.separator())
        let editItem = NSMenuItem(title: "Edit Custom Instructions…",
                                  action: #selector(editInstructions), keyEquivalent: "")
        editItem.target = self
        completionMenu.addItem(editItem)

        completionMenu.addItem(.separator())
        let personalizationHeader = NSMenuItem(title: "Personalization (learns your words)",
                                               action: nil, keyEquivalent: "")
        personalizationHeader.isEnabled = false
        completionMenu.addItem(personalizationHeader)
        let personalizationTitles: [PersonalizationLevel: String] = [
            .off: "Off",
            .subtle: "Subtle",
            .medium: "Medium",
            .strong: "Strong",
        ]
        for level in PersonalizationLevel.allCases {
            let item = NSMenuItem(title: personalizationTitles[level] ?? level.rawValue,
                                  action: #selector(selectPersonalization(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = level.rawValue
            completionMenu.addItem(item)
            personalizationItems[level] = item
        }
        forgetItem = NSMenuItem(title: "Forget learned words",
                                action: #selector(forgetPersonalization), keyEquivalent: "")
        forgetItem.target = self
        completionMenu.addItem(forgetItem)

        // Apple Intelligence prompt recipe — only meaningful when the system
        // model is the active engine, so the whole section hides otherwise
        // (see menuNeedsUpdate). Measured on eval-v2: fewshot best, directive fastest.
        fmVariantSeparator = .separator()
        completionMenu.addItem(fmVariantSeparator)
        fmVariantHeader = NSMenuItem(title: "Recipe (Apple Intelligence)", action: nil, keyEquivalent: "")
        fmVariantHeader.isEnabled = false
        completionMenu.addItem(fmVariantHeader)
        let fmVariantTitles: [FMPromptVariant: String] = [
            .fewshot: "Examples — best quality",
            .terse: "Terse — lean instructions",
            .plain: "Plain — no scaffold",
            .directive: "Directive — fastest, full coverage",
        ]
        for variant in FMPromptVariant.allCases {
            let item = NSMenuItem(title: fmVariantTitles[variant] ?? variant.rawValue,
                                  action: #selector(selectFMVariant(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = variant.rawValue
            completionMenu.addItem(item)
            fmVariantItems[variant] = item
        }
        return completionMenu
    }

    // MARK: - Live updates

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateStatusIcon()
        statusLineItem.title = statusSummary()

        let stats = Stats.lines
        for (i, item) in statsItems.enumerated() {
            item.isHidden = i >= stats.count
            if i < stats.count { item.title = stats[i] }
        }

        rebuildContextMenu()
        rebuildDiagnosticsMenu()

        permissionItem.isHidden = Permissions.isTrusted
        enabledItem.state = Settings.enabled ? .on : .off
        screenContextItem.state = Settings.screenContextEnabled ? .on : .off
        let currentModel = Settings.mlxModelID
        for (id, item) in modelItems {
            item.state = id == currentModel ? .on : .off
        }
        if modelItems[currentModel] == nil, currentModel.hasPrefix("/") {
            fineTunedItem.title = "Fine-tuned: \((currentModel as NSString).lastPathComponent)"
            fineTunedItem.state = .on
        } else {
            fineTunedItem.title = "Load fine-tuned model…"
            fineTunedItem.state = .off
        }
        let auto = Settings.useRecommendedSettings
        useRecommendedItem.state = auto ? .on : .off
        let currentStyle = Settings.completionStyle
        for (style, item) in styleItems {
            item.state = style == currentStyle ? .on : .off
            item.isEnabled = !auto   // the model drives these in auto mode
        }
        let currentLength = Settings.completionLength
        for (length, item) in lengthItems {
            item.state = length == currentLength ? .on : .off
            item.isEnabled = !auto
        }
        let currentPresentation = Settings.suggestionPresentation
        for (presentation, item) in presentationItems {
            item.state = presentation == currentPresentation ? .on : .off
        }
        // Per-model availability: fill-in is E4B-only; the gate is a Base-style
        // feature on a capable E4B model (≥6-bit). Grey them out elsewhere.
        let rec = ModelCatalog.recommended(for: currentModel)
        fimItem.isEnabled = rec.fim
        fimItem.state = (rec.fim && Settings.fimEnabled) ? .on : .off
        let gateUsable = SettingsUI.confidenceGateUsable()
        confidenceGateItem.isEnabled = gateUsable
        confidenceGateItem.state = (gateUsable && Settings.confidenceGate) ? .on : .off
        confidenceGateItem.toolTip = gateUsable
            ? "Only suggest when the model agrees with itself across several tries — fewer but far more accurate suggestions on real text. Costs extra latency."
            : "Switch to Base style on an E4B model (≥6-bit) to use this — instruct/lighter models have nothing reliable to gate on."
        let currentPersonalization = Settings.personalizationLevel
        for (level, item) in personalizationItems {
            item.state = level == currentPersonalization ? .on : .off
        }
        let learned = Personalization.shared.wordCount
        forgetItem.title = learned > 0 ? "Forget learned words (\(learned))" : "Forget learned words"
        forgetItem.isEnabled = learned > 0

        // The recipe only steers the Apple Intelligence engine; hide it for MLX.
        let fmActive = currentModel == ModelCatalog.appleIntelligenceID
        fmVariantSeparator.isHidden = !fmActive
        fmVariantHeader.isHidden = !fmActive
        let currentFMVariant = Settings.fmPromptVariant
        for (variant, item) in fmVariantItems {
            item.isHidden = !fmActive
            item.state = variant == currentFMVariant ? .on : .off
        }
    }

    private func statusSummary() -> String {
        guard Permissions.isTrusted else { return "⚠︎ Accessibility permission required" }
        guard let controller = suggestionController else { return "Starting…" }
        guard Settings.enabled else { return "⏸ Paused" }
        switch controller.engine.state {
        case .ready:
            return "● \(controller.engine.statusLine ?? "\(controller.engine.name) ready")"
        case .preparing(let detail):
            return "⏳ \(detail)"
        case .failed(let detail):
            return "⚠︎ \(detail)"
        }
    }

    private func rebuildContextMenu() {
        contextMenu.removeAllItems()
        let context = suggestionController?.typingContext ?? TypingContext()
        let lines = [
            "App: \(context.appName ?? "—")",
            "Window: \(context.windowTitle.map { String($0.prefix(60)) } ?? "—")",
            "Field: \(context.fieldLabel.map { String($0.prefix(40)) } ?? "—")",
            "Screen: \(suggestionController?.screenContextStatus ?? "—")",
        ]
        for line in lines {
            contextMenu.addItem(NSMenuItem(title: line, action: nil, keyEquivalent: ""))
        }
        contextMenu.addItem(.separator())
        let show = NSMenuItem(title: "Show Last Prompt…", action: #selector(showLastPrompt), keyEquivalent: "")
        show.target = self
        contextMenu.addItem(show)
    }

    private func rebuildDiagnosticsMenu() {
        diagnosticsMenu.removeAllItems()
        let lines = suggestionController?.diagnostics ?? ["Pipeline not started yet"]
        for line in lines {
            diagnosticsMenu.addItem(NSMenuItem(title: line, action: nil, keyEquivalent: ""))
        }
        diagnosticsMenu.addItem(.separator())
        let unload = NSMenuItem(title: "Unload model from memory",
                                action: #selector(unloadModel), keyEquivalent: "")
        unload.target = self
        diagnosticsMenu.addItem(unload)
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        Settings.enabled.toggle()
        if !Settings.enabled {
            suggestionController?.dismiss()
        }
    }

    @objc private func toggleScreenContext() {
        SettingsUI.setScreenContext(!Settings.screenContextEnabled)
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        suggestionController?.setModel(id)
    }

    @objc private func loadFineTunedModel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Model"
        panel.message = "Choose a fused fine-tuned model folder (with config.json + safetensors)."
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            suggestionController?.setModel(url.path)
        }
    }

    @objc private func selectStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = CompletionStyle(rawValue: raw) else { return }
        suggestionController?.setCompletionStyle(style)
    }

    @objc private func selectLength(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let length = CompletionLength(rawValue: raw) else { return }
        suggestionController?.setCompletionLength(length)
    }

    @objc private func selectPersonalization(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let level = PersonalizationLevel(rawValue: raw) else { return }
        suggestionController?.setPersonalization(level)
    }

    @objc private func selectPresentation(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let presentation = SuggestionPresentation(rawValue: raw) else { return }
        suggestionController?.setSuggestionPresentation(presentation)
    }

    @objc private func toggleFIM() {
        Settings.fimEnabled.toggle()
    }

    @objc private func toggleConfidenceGate() {
        suggestionController?.setConfidenceGate(!Settings.confidenceGate)
    }

    @objc private func toggleUseRecommended() {
        Settings.useRecommendedSettings.toggle()
        if Settings.useRecommendedSettings { suggestionController?.applyRecommendedSettings() }
    }

    @objc private func selectFMVariant(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let variant = FMPromptVariant(rawValue: raw) else { return }
        suggestionController?.setFMPromptVariant(variant)
    }

    @objc private func forgetPersonalization() {
        Personalization.shared.reset()
    }

    @objc private func editInstructions() {
        let alert = NSAlert()
        alert.messageText = "Custom AI Instructions"
        alert.informativeText = """
        Persona/voice used in Instruct mode. Auto-filled from your account name \
        and preferred languages — edit it to add your role, tone, anything. Plain \
        text; stays on your Mac. “Reset to System” restores the auto-filled text.
        """

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 140))
        let textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.string = Settings.customInstructions
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        alert.accessoryView = scroll

        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Reset to System")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            suggestionController?.setCustomInstructions(textView.string)
        case .alertThirdButtonReturn:
            suggestionController?.setCustomInstructions(Settings.defaultInstructions)
        default:
            break
        }
    }

    @objc private func showLastPrompt() {
        let prompt = suggestionController?.lastPromptDescription ?? "No prompt has been sent yet."
        let result = suggestionController?.lastResultDescription

        let alert = NSAlert()
        alert.messageText = "Last prompt sent to the engine"
        alert.informativeText = "Exactly what the model saw. Nothing leaves your Mac."

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
        let textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.string = prompt + (result.map { "\n\n——— suggestion ———\n\($0)" } ?? "")
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        alert.accessoryView = scroll

        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func openSettings() {
        guard let controller = suggestionController else { return }
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(controller: controller)
        }
        settingsWindow?.present()
    }

    @objc private func openDebugConsole() {
        DebugWindowController.shared.show()
    }

    @objc private func unloadModel() {
        suggestionController?.releaseEngineModel()
    }

    @objc private func openAccessibilitySettings() {
        Permissions.prompt()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
