import AppKit

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private weak var suggestionController: SuggestionController?

    private var statusLineItem: NSMenuItem!
    private var statsItem: NSMenuItem!
    private var diagnosticsMenu: NSMenu!
    private var permissionItem: NSMenuItem!
    private var enabledItem: NSMenuItem!

    private var statusTimer: Timer?
    private var iconPhase = 0   // animates the preparing-state typing dots
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
        iconPhase = state == .preparing ? (iconPhase + 1) % 3 : 0
        let id = "pretype.\(state.rawValue).\(iconPhase)"
        if button.image?.accessibilityDescription != id {
            let mark = BrandMark.statusItemImage(state, phase: iconPhase)
            mark.accessibilityDescription = id
            button.image = mark
        }
        // The last pipeline event explains per-app silence on hover ("off in
        // terminal apps", "lost text element", "engine returned no suggestion").
        var tip = "Pretype — \(statusInfo().text)"
        if let last = suggestionController?.lastEvent { tip += "\nLast: \(last)" }
        button.toolTip = tip
    }

    func bind(to controller: SuggestionController) {
        suggestionController = controller
    }

    /// Status + a single diagnostics submenu; every setting lives in the
    /// Settings window (⌘,).
    private func buildMenu() {
        statusLineItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
        menu.addItem(statusLineItem)
        statsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(statsItem)
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

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        diagnosticsMenu = NSMenu()
        let diagnosticsItem = NSMenuItem(title: "Diagnostics", action: nil, keyEquivalent: "")
        diagnosticsItem.submenu = diagnosticsMenu
        menu.addItem(diagnosticsItem)

        menu.addItem(.separator())
        // Small two-line hint so it doesn't dictate the menu's width.
        let hint = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        hint.attributedTitle = NSAttributedString(
            string: "⇥ accept word · ⇧⇥ accept all\n⌥⇥ fix word/selection · ⏎ apply · ⎋ keep",
            attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        menu.addItem(hint)
        menu.addItem(NSMenuItem(
            title: "Quit Pretype",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
    }

    // MARK: - Live updates

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateStatusIcon()

        // Status: a colored state dot + the engine line, at menu size.
        let (color, text) = statusInfo()
        let font = NSFont.menuFont(ofSize: 0)
        let status = NSMutableAttributedString(string: "●  ", attributes: [
            .font: font, .foregroundColor: color,
        ])
        status.append(NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor.labelColor,
        ]))
        statusLineItem.attributedTitle = status

        // Stats: one compact block, labels dimmed so the numbers stand out.
        let small = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
        let stats = NSMutableAttributedString()
        for (i, line) in Stats.lines.enumerated() {
            if i > 0 { stats.append(NSAttributedString(string: "\n")) }
            if let colon = line.range(of: ": ") {
                stats.append(NSAttributedString(string: String(line[..<colon.upperBound]), attributes: [
                    .font: small, .foregroundColor: NSColor.secondaryLabelColor,
                ]))
                stats.append(NSAttributedString(string: String(line[colon.upperBound...]), attributes: [
                    .font: small, .foregroundColor: NSColor.labelColor,
                ]))
            } else {
                stats.append(NSAttributedString(string: line, attributes: [
                    .font: small, .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            }
        }
        statsItem.attributedTitle = stats

        rebuildDiagnosticsMenu()

        permissionItem.isHidden = Permissions.isTrusted
        enabledItem.state = Settings.enabled ? .on : .off
    }

    private func statusInfo() -> (color: NSColor, text: String) {
        guard Permissions.isTrusted else { return (.systemRed, "Accessibility permission required") }
        guard let controller = suggestionController else { return (.systemGray, "Starting…") }
        guard Settings.enabled else { return (.systemGray, "Paused") }
        switch controller.engine.state {
        case .ready:
            return (.systemGreen, controller.engine.statusLine ?? "\(controller.engine.name) ready")
        case .preparing(let detail):
            return (.systemOrange, detail)
        case .failed(let detail):
            return (.systemRed, detail)
        }
    }

    /// Context + pipeline + debug tools, merged into one submenu.
    private func rebuildDiagnosticsMenu() {
        diagnosticsMenu.removeAllItems()

        diagnosticsMenu.addItem(.sectionHeader(title: "Context"))
        let context = suggestionController?.typingContext ?? TypingContext()
        let contextLines = [
            "App: \(context.appName ?? "—")",
            "Window: \(context.windowTitle.map { String($0.prefix(60)) } ?? "—")",
            "Field: \(context.fieldLabel.map { String($0.prefix(40)) } ?? "—")",
            "Screen: \(suggestionController?.screenContextStatus ?? "—")",
        ]
        for line in contextLines {
            diagnosticsMenu.addItem(NSMenuItem(title: line, action: nil, keyEquivalent: ""))
        }

        diagnosticsMenu.addItem(.sectionHeader(title: "Pipeline"))
        let lines = suggestionController?.diagnostics ?? ["Pipeline not started yet"]
        for line in lines {
            diagnosticsMenu.addItem(NSMenuItem(title: line, action: nil, keyEquivalent: ""))
        }

        diagnosticsMenu.addItem(.separator())
        let show = NSMenuItem(title: "Show Last Prompt…", action: #selector(showLastPrompt), keyEquivalent: "")
        show.target = self
        diagnosticsMenu.addItem(show)
        let unload = NSMenuItem(title: "Unload model from memory",
                                action: #selector(unloadModel), keyEquivalent: "")
        unload.target = self
        diagnosticsMenu.addItem(unload)
        let debug = NSMenuItem(title: "Debug Console…", action: #selector(openDebugConsole), keyEquivalent: "d")
        debug.target = self
        diagnosticsMenu.addItem(debug)
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        Settings.enabled.toggle()
        if !Settings.enabled {
            suggestionController?.dismiss()
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
