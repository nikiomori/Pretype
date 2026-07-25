import AppKit
import SwiftUI

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private weak var suggestionController: SuggestionController?

    private var headerHost: NSHostingView<MenuHeaderView>!
    private var hintsHost: NSHostingView<MenuHintsView>!
    private var diagnosticsMenu: NSMenu!
    private var permissionItem: NSMenuItem!
    private var enabledItem: NSMenuItem!
    private var appBlacklistItem: NSMenuItem!
    private var languageHintItem: NSMenuItem!
    private var updateItem: NSMenuItem!

    private var statusTimer: Timer?
    private var iconPhase = 0   // animates the preparing-state typing dots
    private var lastIconID = ""  // gates the icon redraw (kept off the a11y label)
    private var settingsWindow: SettingsWindowController?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = statusItem.button {
            button.image = BrandMark.statusItemImage(.ready)
            button.image?.accessibilityDescription = "Pretype"
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
        // Rebuild the template image only when the drawn state changes; this token
        // gates the redraw and must NOT double as the accessible label.
        let id = "pretype.\(state.rawValue).\(iconPhase)"
        if id != lastIconID {
            button.image = BrandMark.statusItemImage(state, phase: iconPhase)
            lastIconID = id
        }
        // VoiceOver reads the image description as the button's name, so it gets
        // the human status line — the same text the tooltip shows ("Pretype —
        // MiniCPM ready", "Pretype — downloading 42%"). The last pipeline event
        // explains per-app silence on hover, so it stays in the tooltip only.
        let status = "Pretype — \(statusInfo().text)"
        button.image?.accessibilityDescription = status
        var tip = status
        if let last = suggestionController?.lastEvent { tip += "\nLast: \(last)" }
        button.toolTip = tip
    }

    func bind(to controller: SuggestionController) {
        suggestionController = controller
    }

    /// Status + a single diagnostics submenu; every setting lives in the
    /// Settings window (⌘,).
    private func buildMenu() {
        // Status + savings as one drawn block. `sizingOptions` lets the hosting
        // view report its own height, so the item grows with the two- or
        // three-line status text instead of clipping it.
        headerHost = NSHostingView(rootView: headerView())
        headerHost.sizingOptions = .intrinsicContentSize
        resize(headerHost)
        let headerItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        headerItem.view = headerHost
        menu.addItem(headerItem)
        menu.addItem(.separator())

        permissionItem = NSMenuItem(
            title: "Grant Accessibility permission…",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        permissionItem.target = self
        permissionItem.image = symbol("exclamationmark.triangle.fill")
        menu.addItem(permissionItem)

        enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        menu.addItem(enabledItem)

        // Title filled in menuNeedsUpdate — it names the app the user was last
        // typing in, which isn't known until the menu opens.
        appBlacklistItem = NSMenuItem(title: "", action: #selector(toggleFrontmostAppBlacklist), keyEquivalent: "")
        appBlacklistItem.target = self
        menu.addItem(appBlacklistItem)

        // Hidden unless the language being typed is one this model is bad at —
        // see refreshLanguageHintItem.
        languageHintItem = NSMenuItem(title: "", action: #selector(showModelsForTypedLanguage), keyEquivalent: "")
        languageHintItem.target = self
        languageHintItem.image = symbol("globe")
        menu.addItem(languageHintItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = symbol("gearshape")
        menu.addItem(settingsItem)

        // One item, two states: an offer to download when a newer release is
        // known, a manual check otherwise (title refreshed in menuNeedsUpdate).
        updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        diagnosticsMenu = NSMenu()
        let diagnosticsItem = NSMenuItem(title: "Diagnostics", action: nil, keyEquivalent: "")
        diagnosticsItem.submenu = diagnosticsMenu
        diagnosticsItem.image = symbol("waveform.path.ecg")
        menu.addItem(diagnosticsItem)

        menu.addItem(.separator())
        // Drawn keycaps rather than a paragraph of grey text, and refreshed in
        // menuNeedsUpdate so they track the chosen accept hotkey.
        hintsHost = NSHostingView(rootView: MenuHintsView(hints: shortcutHints()))
        hintsHost.sizingOptions = .intrinsicContentSize
        resize(hintsHost)
        let hintItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        hintItem.view = hintsHost
        menu.addItem(hintItem)
        menu.addItem(NSMenuItem(
            title: "Quit Pretype",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
    }

    /// NSMenu lays a custom-view item out at the view's own `frame`, and an
    /// `NSHostingView` starts at zero — `sizingOptions` alone reports an
    /// intrinsic size nothing asks for, and the item renders as a blank sliver.
    /// So the frame is set from the SwiftUI fitting size here, and again after
    /// every `rootView` swap: the header's height changes with the status text.
    private func resize(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
    }

    /// Menu-sized template symbol. Every action row gets one: half-iconned rows
    /// are a large part of why the menu read as unstructured.
    private func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    // MARK: - Live updates

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateStatusIcon()

        headerHost.rootView = headerView()
        resize(headerHost)
        rebuildDiagnosticsMenu()

        permissionItem.isHidden = Permissions.isTrusted
        enabledItem.state = Settings.enabled ? .on : .off
        enabledItem.image = symbol(Settings.enabled ? "text.cursor" : "pause.circle")
        refreshAppBlacklistItem()
        refreshLanguageHintItem()
        let newer = UpdateChecker.availableVersion
        updateItem.title = newer.map { "Update to \($0)…" } ?? "Check for Updates…"
        updateItem.image = symbol(newer != nil ? "arrow.down.circle.fill" : "arrow.down.circle")
        hintsHost.rootView = MenuHintsView(hints: shortcutHints())
        resize(hintsHost)
    }

    private func headerView() -> MenuHeaderView {
        let (color, text) = statusInfo()
        return MenuHeaderView(
            statusColor: Color(nsColor: color),
            statusText: text,
            statusOK: color == .systemGreen,
            savings: Stats.savings,
            acceptLabel: Settings.hotkeyStyle.label
        )
    }

    /// "Disable in Mail" / "Enable in Mail", named from the context the user was
    /// last typing in. Opening the menu makes Pretype frontmost, but
    /// FocusTracker.attach bails on our own PID *before* it detaches, so
    /// typingContext still names the app behind the menu.
    private func refreshAppBlacklistItem() {
        let context = suggestionController?.typingContext ?? TypingContext()
        guard let bundleID = context.bundleID else {
            // Cold start, or an app with no bundle ID — nothing to toggle.
            appBlacklistItem.isHidden = true
            return
        }
        appBlacklistItem.isHidden = false
        // Same clamp as the diagnostics lines: one long app name must not set
        // the menu's width.
        let name = String((context.appName ?? bundleID).prefix(40))
        if AppPolicy.isTerminal(bundleID) || AppPolicy.isCredentialApp(bundleID) {
            // Built-in blocks can't be lifted, so the item states the fact and
            // greys itself out (nil action + NSMenu autoenabling) rather than
            // offering a toggle that would silently do nothing. Code editors are
            // deliberately not here: they only lose screen OCR, and stay
            // toggleable.
            appBlacklistItem.title = "Always off in \(name)"
            appBlacklistItem.action = nil
            appBlacklistItem.image = symbol("hand.raised")
        } else if AppPolicy.userBlacklistEntries(for: bundleID).isEmpty,
                  Stats.isUnproductive(bundleID), let record = Stats.record(for: bundleID) {
            // Pretype silenced itself here. The block is ours, not the user's, so
            // the item that would offer "Disable" states the reason with its own
            // evidence and becomes the way back instead.
            appBlacklistItem.title = "Quiet in \(name) — \(record.accepted * 100 / record.shown)% "
                + "of \(record.shown) taken · Resume"
            appBlacklistItem.action = #selector(resumeInFrontmostApp)
            appBlacklistItem.image = symbol("play.circle")
        } else {
            let off = !AppPolicy.userBlacklistEntries(for: bundleID).isEmpty
            // No .state checkmark: a ✓ next to "Disable in Mail" reads either way.
            appBlacklistItem.title = off ? "Enable in \(name)" : "Disable in \(name)"
            appBlacklistItem.action = #selector(toggleFrontmostAppBlacklist)
            appBlacklistItem.image = symbol(off ? "checkmark.circle" : "nosign")
        }
    }

    /// "Typing Hebrew? Gemma E2B 8-bit measures 18% there, this one 1%."
    ///
    /// The model is chosen once, from keyboard layouts, and then never revisited
    /// — so someone who types a language their model is bad at gets a quiet 1%
    /// forever with nothing telling them why. This is the telling. It appears
    /// only when the language signal is settled AND the gap is outside the eval's
    /// own noise (`ModelMetrics.materiallyBetter`), and it never switches
    /// anything: clicking opens the model list ranked for that language, where
    /// the sizes are visible, because the better model is usually the bigger one
    /// and that is the user's call to make.
    ///
    /// ponytail: computed when the menu opens, so the check costs nothing while
    /// typing; and no "don't show again" state — ignoring a menu line is already
    /// free, and the item disappears by itself once the model fits the language.
    private func refreshLanguageHintItem() {
        guard let language = TypedLanguage.dominant,
              let better = ModelMetrics.materiallyBetter(than: Settings.mlxModelID, on: language),
              let name = ModelMetrics.metrics(for: better.id)?.shortName
        else {
            languageHintItem.isHidden = true
            return
        }
        languageHintItem.isHidden = false
        languageHintItem.title =
            "Typing \(ModelMetrics.axisDisplayName(language))? \(name) measures "
            + "\(better.best)% there, this one \(better.current)%"
    }

    /// Show the catalog ranked for the language being typed. Sets the axis first
    /// so `present()`'s `sync()` picks it up — that also makes the map, the cards
    /// and the presets re-resolve to that language, which is the whole point:
    /// the user sees the evidence, not just a recommendation.
    @objc private func showModelsForTypedLanguage() {
        if let language = TypedLanguage.dominant {
            Settings.accuracyAxis = language
            // Written directly, so the store didSet that normally clears map
            // mode on a language pick never runs (sync() assigns under its
            // syncing guard) — clear it here or the tab opens on the pooled
            // EN+RU sample with this language selected in the picker.
            Settings.settingsMapMode = false
        }
        openSettings()
        // After present(): sync() would otherwise be the last writer, and the
        // tab is view state rather than a setting, so it is set on the store.
        settingsWindow?.store.activeTab = .model
    }

    /// The shortcut hints, keyed to the user's accept hotkey so their notation
    /// matches the overlay and onboarding (Tab / ⇧Tab / ⌥Tab) instead of a
    /// hardcoded ⇥ that also went stale whenever the hotkey was changed.
    ///
    /// Four rows of keycaps is a wall to read every time the menu opens, and it
    /// stops being news the moment accepting is muscle memory — so it shrinks to
    /// one row at the same 20-acceptance mark the suggestion pill uses.
    /// Onboarding and Settings still spell all of it out.
    private func shortcutHints() -> [(keys: String, action: String)] {
        let s = Settings.hotkeyStyle
        let reply = Settings.replyGesture == .off ? s.replyLabel : Settings.replyGesture.label
        guard Stats.lifetimeAccepted < 20 else {
            return [(keys: "\(s.label)  \(s.correctionLabel)  \(reply)", action: "accept · fix · reply")]
        }
        // One line each, and short enough to survive the widest keycap column
        // without truncating — the menu's width is set by the header, not here.
        return [
            (keys: s.label, action: "accept a word — \(s.shiftLabel) for all"),
            (keys: s.correctionLabel, action: "fix the word or selection"),
            (keys: "⏎", action: "apply the fix — ⎋ keeps yours"),
            (keys: reply, action: "reply to what's on screen"),
        ]
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

        diagnosticsMenu.addItem(.sectionHeader(title: "Today"))
        for line in Stats.diagnosticLines {
            diagnosticsMenu.addItem(NSMenuItem(title: line, action: nil, keyEquivalent: ""))
        }

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

    /// No propagation needed: AppPolicy.isBlacklisted reads UserDefaults on the
    /// keystroke path, so the next keypress already obeys the new list.
    /// ponytail: an already-open Settings window keeps showing the stale
    /// blacklist until its next sync() (⌘, again) — an observer for that one
    /// window isn't worth the wiring.
    @objc private func toggleFrontmostAppBlacklist() {
        guard let bundleID = suggestionController?.typingContext.bundleID else { return }
        AppPolicy.toggleUserBlacklist(bundleID)
        // A ghost already on screen for the app we just silenced has to go.
        suggestionController?.dismiss()
    }

    /// Wipe the app's track record, which is the only thing keeping Pretype
    /// quiet there — the next keystroke offers again, and the app has to earn
    /// its way back to `isUnproductive` from zero.
    @objc private func resumeInFrontmostApp() {
        guard let bundleID = suggestionController?.typingContext.bundleID else { return }
        Stats.clearRecord(for: bundleID)
        DebugLog.shared.log("STATS", "resumed suggestions in \(bundleID)")
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

    /// Known update → offer it straight away. Otherwise check now and report
    /// either way: a manual check that answers with silence reads as broken.
    @objc private func checkForUpdates() {
        if let newer = UpdateChecker.availableVersion {
            presentUpdate(newer)
            return
        }
        Task { @MainActor in
            let latest = await UpdateChecker.check()
            if let newer = UpdateChecker.availableVersion {
                presentUpdate(newer)
                return
            }
            let alert = NSAlert()
            if let latest {
                alert.messageText = "Pretype \(latest) is the latest version"
                alert.informativeText = "You're up to date."
                alert.addButton(withTitle: "OK")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
                return
            }
            alert.messageText = "Couldn't check for updates"
            alert.informativeText = "GitHub was unreachable. Try again later, or open the releases page."
            alert.addButton(withTitle: "Open Releases…")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                UpdateChecker.openReleasePage()
            }
        }
    }

    /// How the update is taken depends on how the app arrived: a Homebrew copy
    /// upgrades with one command (and only `brew` keeps the cask's own record of
    /// what is installed straight), everything else downloads from the release
    /// page. Either way macOS may ask for Accessibility again afterwards —
    /// updates change the code signature of an ad-hoc signed build.
    private func presentUpdate(_ version: String) {
        let alert = NSAlert()
        alert.messageText = "Pretype \(version) is available"
        let brew = UpdateChecker.isHomebrewInstall
        alert.informativeText = "You're on \(UpdateChecker.currentVersion). "
            + (brew
                ? "Installed with Homebrew — upgrade with:\n\n    \(UpdateChecker.upgradeCommand)"
                : "Download it and replace Pretype in Applications — updates are never installed for you.")
            + "\n\nmacOS may ask you to grant Accessibility again afterwards."
        alert.addButton(withTitle: brew ? "Copy Command" : "Download…")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if brew {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(UpdateChecker.upgradeCommand, forType: .string)
        } else {
            UpdateChecker.openReleasePage()
        }
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
