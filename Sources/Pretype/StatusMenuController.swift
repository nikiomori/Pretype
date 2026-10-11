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
    private var batteryItem: NSMenuItem!
    private var appBlacklistItem: NSMenuItem!
    private var languageHintItem: NSMenuItem!
    private var updateItem: NSMenuItem!
    private var settingsItem: NSMenuItem!
    private var retryItem: NSMenuItem!
    /// While the menu is open the header redraws on every status tick, so a
    /// download percentage moves instead of freezing at the value it had when
    /// the menu opened.
    private var menuIsOpen = false

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
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.updateStatusIcon()
                if self.menuIsOpen { self.refreshHeader() }
            }
        }
        // .common, not the default mode: menu tracking runs the event loop in
        // its own mode, and a default-mode timer stops for exactly as long as
        // the user is looking at the menu.
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
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
        } else if suggestionController?.dictationController.isCapturing == true {
            state = .listening                    // the microphone is open right now
        } else if let engine = suggestionController?.engine {
            switch engine.state {
            case .ready: state = .ready
            // Idle-unloaded is `.preparing` with nothing running — the app's
            // most common resting state, and it reloads on the next keystroke.
            // Animating "loading" dots for hours over it was a false alarm.
            case .preparing: state = engine.isLoading ? .preparing : .ready
            case .failed: state = .failed         // engine not working
            }
        } else {
            state = .ready
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
        let status = "Pretype — \(Self.status(of: suggestionController).text)"
        button.image?.accessibilityDescription = status
        var tip = status
        if let last = suggestionController?.lastEvent { tip += "\nLast: \(last)" }
        button.toolTip = tip
    }

    func bind(to controller: SuggestionController) {
        suggestionController = controller
        // Push, not poll: a capture lasts seconds, and the 1 s status timer
        // would show the mic late — or, for a short sentence, never.
        controller.onDictationActivity = { [weak self] in self?.updateStatusIcon() }
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

        // The long form ("Grant Accessibility permission…") was 25pt wider than
        // the header on its own, so an ungranted Mac met a wider menu than a
        // granted one. The sentence moved to the tooltip.
        permissionItem = item("Grant Accessibility…", #selector(openAccessibilitySettings),
                              symbol: "exclamationmark.triangle.fill")
        permissionItem.toolTip =
            "Pretype needs Accessibility permission to read the field you're typing in."

        // A verb, not a checkmark: "Enabled" with a pause icon and no ✓ read
        // as either state. Title and icon flip in menuNeedsUpdate.
        enabledItem = item("Pause Pretype", #selector(toggleEnabled))
        // A checkmark this time: it's a standing rule, not an action now.
        batteryItem = item("Pause on Battery", #selector(togglePauseOnBattery), symbol: "battery.50")

        // Only while the engine has failed: the background retry is silent and
        // Apple Intelligence never re-checks on its own, so without this the
        // way back from a failure was a relaunch.
        retryItem = item("Retry Loading the Model", #selector(retryEngine), symbol: "arrow.clockwise")

        // Title filled in menuNeedsUpdate — it names the app the user was last
        // typing in, which isn't known until the menu opens.
        appBlacklistItem = item("", #selector(toggleFrontmostAppBlacklist))

        // Hidden unless the language being typed is one this model is bad at —
        // see refreshLanguageHintItem.
        languageHintItem = item("", #selector(showModelsForTypedLanguage), symbol: "globe")

        settingsItem = item("Settings…", #selector(openSettings), key: ",", symbol: "gearshape")

        // One item, two states: an offer to download when a newer release is
        // known, a manual check otherwise (title refreshed in menuNeedsUpdate).
        updateItem = item("Check for Updates…", #selector(checkForUpdates))

        diagnosticsMenu = NSMenu()
        item("Diagnostics", nil, symbol: "waveform.path.ecg").submenu = diagnosticsMenu

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

    /// What a menu row costs beyond its title text: the item's indent and
    /// template image on the left, the key-equivalent column and margin on the
    /// right. Measured off a menu built like this one (`NSMenu.size` came back
    /// at text + 99.2…100.0 for every title tried), not guessed.
    private static let titleChrome: CGFloat = 100

    /// Keeps a title inside the header's width. Every row here is a short verb
    /// except the two that name an app or a language, and those were setting the
    /// menu's width themselves — so the whole menu grew by a third whenever
    /// Pretype had gone quiet somewhere, and snapped back the next time it
    /// hadn't. The header is the one item with a designed width, so it stays the
    /// only one that sets it; anything longer is truncated here and the full
    /// sentence goes on the item's tooltip.
    private func fitting(_ title: String) -> String {
        let font = NSFont.menuFont(ofSize: 0)
        let budget = MenuHeaderView.width - Self.titleChrome
        func width(_ text: String) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width
        }
        guard width(title) > budget else { return title }
        var text = title
        while !text.isEmpty, width(text + "…") > budget { text.removeLast() }
        return text.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Menu-sized template symbol. Every action row gets one: half-iconned rows
    /// are a large part of why the menu read as unstructured.
    private func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    /// An action row targeting this controller, appended to `menu` (the status
    /// menu unless given).
    @discardableResult
    private func item(_ title: String, _ action: Selector?, key: String = "", symbol name: String? = nil,
                      in menu: NSMenu? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.image = name.flatMap(symbol)
        (menu ?? self.menu).addItem(item)
        return item
    }

    // MARK: - Live updates

    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuIsOpen = false }

    private func refreshHeader() {
        headerHost.rootView = headerView()
        resize(headerHost)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateStatusIcon()
        // A menu-bar app runs for weeks; a check made only at launch went
        // stale (and one made offline at launch never retried). It throttles
        // itself to once a day and respects the automatic-check setting.
        UpdateChecker.checkInBackground()

        refreshHeader()
        rebuildDiagnosticsMenu()

        permissionItem.isHidden = Permissions.isTrusted
        enabledItem.title = Settings.enabled ? "Pause Pretype" : "Resume Pretype"
        enabledItem.image = symbol(Settings.enabled ? "pause.circle" : "play.circle")
        batteryItem.state = Settings.pauseOnBattery ? .on : .off
        if case .failed = suggestionController?.engine.state {
            retryItem.isHidden = false
        } else {
            retryItem.isHidden = true
        }
        // Settings needs the pipeline, which starts once Accessibility is
        // granted — until then the item greys out (nil action) and says why,
        // instead of silently doing nothing when clicked.
        settingsItem.action = suggestionController == nil ? nil : #selector(openSettings)
        settingsItem.toolTip = suggestionController == nil ? "Available once Accessibility is granted." : nil
        refreshAppBlacklistItem()
        refreshLanguageHintItem()
        let newer = UpdateChecker.availableVersion
        updateItem.title = newer.map { "Update to \($0)…" } ?? "Check for Updates…"
        updateItem.image = symbol(newer != nil ? "arrow.down.circle.fill" : "arrow.down.circle")
        hintsHost.rootView = MenuHintsView(hints: shortcutHints())
        resize(hintsHost)
    }

    private func headerView() -> MenuHeaderView {
        let (color, text) = Self.status(of: suggestionController)
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
        // Same clamp as the diagnostics lines, before `fitting` measures what's
        // left: one long app name must not set the menu's width.
        let name = String((context.appName ?? bundleID).prefix(40))
        appBlacklistItem.toolTip = nil
        if AppPolicy.isTerminal(bundleID) || AppPolicy.isCredentialApp(bundleID) {
            // Built-in blocks can't be lifted, so the item states the fact and
            // greys itself out (nil action + NSMenu autoenabling) rather than
            // offering a toggle that would silently do nothing. Code editors are
            // deliberately not here: they only lose screen OCR, and stay
            // toggleable.
            appBlacklistItem.title = fitting("Always off in \(name)")
            appBlacklistItem.action = nil
            appBlacklistItem.image = symbol("hand.raised")
        } else if AppPolicy.userBlacklistEntries(for: bundleID).isEmpty,
                  Stats.isUnproductive(bundleID), let record = Stats.record(for: bundleID) {
            // Pretype silenced itself here. The block is ours, not the user's, so
            // the item that would offer "Disable" becomes the way back instead.
            // It says only that — the accept rate that justified going quiet is a
            // sentence-long aside that widened the menu every time it appeared,
            // so it hovers rather than prints.
            appBlacklistItem.title = fitting("Resume in \(name)")
            appBlacklistItem.toolTip = "Pretype went quiet here: "
                + "\(record.accepted * 100 / record.shown)% of \(record.shown) suggestions taken."
            appBlacklistItem.action = #selector(resumeInFrontmostApp)
            appBlacklistItem.image = symbol("play.circle")
        } else if AppPolicy.userBlacklistEntries(for: bundleID).isEmpty, let host = context.site {
            // In a browser the useful switch is the website: Gmail and the
            // docs you're reading share one bundle ID. The whole browser stays
            // one click away in Settings.
            let off = Settings.userBlacklist.contains { AppPolicy.site(host, matches: $0) }
            appBlacklistItem.title = fitting(off ? "Enable on \(host)" : "Disable on \(host)")
            appBlacklistItem.action = #selector(toggleFrontmostSiteBlacklist)
            appBlacklistItem.image = symbol(off ? "checkmark.circle" : "nosign")
        } else {
            let off = !AppPolicy.userBlacklistEntries(for: bundleID).isEmpty
            // No .state checkmark: a ✓ next to "Disable in Mail" reads either way.
            appBlacklistItem.title = fitting(off ? "Enable in \(name)" : "Disable in \(name)")
            appBlacklistItem.action = #selector(toggleFrontmostAppBlacklist)
            appBlacklistItem.image = symbol(off ? "checkmark.circle" : "nosign")
        }
    }

    /// "Better models for Hebrew", hovering "Gemma E2B 8-bit measures 18% on
    /// Hebrew — this one 1%."
    ///
    /// The model is chosen once, sized to the Mac's memory, and never revisited
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
        let display = ModelMetrics.axisDisplayName(language)
        // The evidence hovers instead of printing, for the same reason the
        // quiet-app row's does: a full sentence here was the widest thing in the
        // menu, and the click already lands on the ranked table that shows it.
        languageHintItem.title = fitting("Better models for \(display)")
        languageHintItem.toolTip =
            "\(name) measures \(better.best)% on \(display) — this one \(better.current)%."
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
    private func shortcutHints() -> [MenuHintsView.Hint] {
        let s = Settings.hotkeyStyle
        let reply = Settings.replyGesture == .off ? s.replyLabel : Settings.replyGesture.label
        // Only once it's switched on: a shortcut for a feature the user hasn't
        // enabled is a line of noise in a list that has to stay scannable.
        let talk = Settings.dictationEnabled && Settings.dictationGesture != .off
            ? "Hold \(Settings.dictationGesture.shortLabel)" : nil
        let latch = Settings.dictationEnabled && Settings.dictationLatch != .off
            ? Settings.dictationLatch.label : nil
        guard Stats.lifetimeAccepted < 20 else {
            // One cap per key: three chords in one cap read as a single combo.
            // Dictation stays in the short form too — it may be switched on
            // long after the 20th accept, and then it would never be hinted.
            var keys = [s.label, s.correctionLabel, reply]
            var actions = ["accept", "fix", "reply"]
            if let talk { keys.append(talk); actions.append("talk") }
            return [MenuHintsView.Hint(keys: keys, action: actions.joined(separator: " · "))]
        }
        // One line each, and short enough to survive the widest keycap column
        // without truncating — the menu's width is set by the header, not here.
        // "esc", not ⎋: the overlay's keycap says esc, and ⎋ at caption size
        // is an unreadable swirl.
        var hints = [
            MenuHintsView.Hint(keys: [s.label], action: "accept a word — \(s.shiftLabel) for all"),
            MenuHintsView.Hint(keys: [s.correctionLabel], action: "fix the word or selection"),
            MenuHintsView.Hint(keys: ["⏎"], action: "apply the fix — esc keeps yours"),
            MenuHintsView.Hint(keys: [reply], action: "reply to what's on screen"),
        ]
        if let talk { hints.append(MenuHintsView.Hint(keys: [talk], action: "talk instead of typing")) }
        if let latch { hints.append(MenuHintsView.Hint(keys: [latch], action: "hands-free — again to stop")) }
        return hints
    }

    /// The one status line — the menu header, the icon's label and the
    /// Settings sidebar footer all read it.
    static func status(of controller: SuggestionController?) -> (color: NSColor, text: String) {
        guard Permissions.isTrusted else { return (.systemRed, "Accessibility permission required") }
        guard let controller else { return (.systemGray, "Starting…") }
        guard Settings.enabled else { return (.systemGray, "Paused") }
        if controller.dictationController.isCapturing {
            return (.systemRed, "Listening — dictation is capturing")
        }
        // Completions only — dictation still works on battery, hence after it.
        if AppPolicy.pausedForBattery { return (.systemGray, "Paused on battery") }
        // Secure input blinds the key tap system-wide (a password field, or a
        // terminal's Secure Keyboard Entry left on) — the one silence a
        // "ready" light would otherwise misreport.
        if AXText.isSecureInputActive() {
            return (.systemOrange, "Paused by secure input — a password field or Secure Keyboard Entry is on")
        }
        // The model the user PICKED, by the name Settings shows it under. The
        // engine's own line is a repo slug, and in Instruct style the slug of
        // a sibling the user never chose ("gemma-4-e4b-it-4bit: ready").
        let engine = controller.engine
        let id = Settings.mlxModelID
        let name = ModelMetrics.metrics(for: id)?.shortName ?? ModelCatalog.option(for: id)?.title ?? engine.name
        switch engine.state {
        case .ready:
            return (.systemGreen, "\(name) ready")
        case .preparing where !engine.isLoading:
            // Idle-unloaded: nothing is wrong, and the next keystroke reloads it.
            return (.systemGreen, "\(name) ready · idle")
        case .preparing(let detail):
            return (.systemOrange, "\(name) — \(detail)")
        case .failed(let detail):
            return (.systemRed, "\(name) failed — \(detail)")
        }
    }

    /// Context + pipeline + debug tools, merged into one submenu.
    private func rebuildDiagnosticsMenu() {
        diagnosticsMenu.removeAllItems()
        func section(_ title: String, _ lines: [String]) {
            diagnosticsMenu.addItem(.sectionHeader(title: title))
            for line in lines {
                diagnosticsMenu.addItem(NSMenuItem(title: line, action: nil, keyEquivalent: ""))
            }
        }

        section("Today", Stats.diagnosticLines)
        let context = suggestionController?.typingContext ?? TypingContext()
        section("Context", [
            "App: \(context.appName ?? "—")",
            "Window: \(context.windowTitle.map { String($0.prefix(60)) } ?? "—")",
            "Field: \(context.fieldLabel.map { String($0.prefix(40)) } ?? "—")",
            "Screen: \(suggestionController?.screenContextStatus ?? "—")",
        ])
        section("Pipeline", suggestionController?.diagnostics ?? ["Pipeline not started yet"])

        diagnosticsMenu.addItem(.separator())
        item("Show Last Prompt…", #selector(showLastPrompt), in: diagnosticsMenu)
        item("Unload Model from Memory", #selector(unloadModel), in: diagnosticsMenu)
        item("Debug Console…", #selector(openDebugConsole), key: "d", in: diagnosticsMenu)
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        guard let controller = suggestionController else { Settings.enabled.toggle(); return }
        controller.setEnabled(!Settings.enabled)
        // An open Settings window mirrors these; it only re-reads on sync().
        settingsWindow?.store.sync()
    }

    /// Read on the keystroke path (`AppPolicy.pausedForBattery`), like the
    /// blacklist below — nothing to propagate.
    @objc private func togglePauseOnBattery() {
        Settings.pauseOnBattery.toggle()
        suggestionController?.clearActiveCompletion()
        refreshHeader()
    }

    /// The pipeline needs no propagation: AppPolicy.isBlacklisted reads
    /// UserDefaults on the keystroke path, so the next keypress already obeys
    /// the new list.
    @objc private func toggleFrontmostAppBlacklist() {
        guard let bundleID = suggestionController?.typingContext.bundleID else { return }
        AppPolicy.toggleUserBlacklist(bundleID)
        // A ghost already on screen for the app we just silenced has to go.
        suggestionController?.dismiss()
        settingsWindow?.store.sync()
    }

    @objc private func toggleFrontmostSiteBlacklist() {
        guard let host = suggestionController?.typingContext.site else { return }
        AppPolicy.toggleUserBlacklist(site: host)
        suggestionController?.dismiss()
        settingsWindow?.store.sync()
    }

    /// Wipe the app's track record, which is the only thing keeping Pretype
    /// quiet there — the next keystroke offers again, and the app has to earn
    /// its way back to `isUnproductive` from zero.
    @objc private func resumeInFrontmostApp() {
        guard let bundleID = suggestionController?.typingContext.bundleID else { return }
        Stats.clearRecord(for: bundleID)
        DebugLog.shared.log("STATS", "resumed suggestions in \(bundleID)")
        settingsWindow?.store.sync()
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
                : "Pretype doesn't update itself — download it and replace the copy in Applications.")
            + (UpdateChecker.isAdHocSigned
                ? "\n\nmacOS will ask you to grant Accessibility again afterwards." : "")
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

    @objc private func retryEngine() {
        suggestionController?.engineCoordinator.rebuild()
    }

    @objc private func unloadModel() {
        suggestionController?.engine.releaseModelNow()
    }

    @objc private func openAccessibilitySettings() {
        // Someone who granted it before almost always finds Pretype already
        // switched ON — a stale entry (see `regrantInstructions`). Once per
        // launch: the instructions send them back here after removing it,
        // and that click wants the prompt, not the same alert again.
        if Settings.onboardingCompleted, !Permissions.explainedRegrant {
            Permissions.explainedRegrant = true
            let alert = NSAlert()
            alert.messageText = "Grant Accessibility again"
            alert.informativeText = Permissions.regrantInstructions
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        Permissions.prompt()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
