import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenuController!
    private var suggestionController: SuggestionController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusMenu = StatusMenuController()
        installMainMenu()
        UpdateChecker.checkInBackground()

        if Permissions.isTrusted {
            start()
        } else {
            // A bare system Accessibility dialog with no context reads as scary
            // for an app that watches typing — explain the why first.
            let alert = NSAlert()
            alert.messageText = String(localized: "Pretype needs Accessibility access")
            if Settings.onboardingCompleted {
                // A returning user: the grant didn't vanish, the app's signature
                // changed under it (an update). System Settings still shows
                // Pretype switched ON — a stale entry — so the first-run copy
                // left them flipping a switch that already looked right.
                Permissions.explainedRegrant = true
                alert.informativeText = String(localized: """
                Pretype was updated, so macOS needs to grant Accessibility again.

                \(Permissions.regrantInstructions)
                """)
            } else {
                alert.informativeText = String(localized: """
                Accessibility is how Pretype reads the text field you're typing in, \
                catches the \(Settings.hotkeyStyle.label) key, and types accepted suggestions back.

                macOS will ask you to grant it next, under Privacy & Security → \(Permissions.paneName). \
                Everything you type stays on this Mac.
                """)
            }
            alert.addButton(withTitle: String(localized: "Continue"))
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            Permissions.prompt()
            // Poll until the user grants Accessibility, then start the pipeline.
            Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
                Task { @MainActor in
                    guard let self else { return }
                    guard Permissions.isTrusted else { return }
                    timer.invalidate()
                    self.start()
                }
            }
        }
    }

    /// Pretype opened again — from Finder, Spotlight or Launchpad — while it
    /// runs. The menu-bar icon is its only other way in, and macOS hides that
    /// behind the notch or at the user's request; so a reopen shows Settings,
    /// or, before Accessibility is granted, the pane that grants it.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if Permissions.isTrusted { statusMenu.openSettings() } else { Permissions.openSettings() }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        suggestionController?.shutdown()
    }

    /// Settings switches the app to `.regular`, and a regular app with no
    /// main menu has no Edit menu: ⌘C/⌘V/⌘A/⌘Z in its fields, ⌘W and ⌘Q were
    /// all dead. Only shown while `.regular` — the menu-bar mode never sees it.
    private func installMainMenu() {
        let app = NSMenu()
        app.addItem(withTitle: String(localized: "About Pretype"),
                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: String(localized: "Hide Pretype"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: String(localized: "Quit Pretype"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: String(localized: "Edit"))
        edit.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let window = NSMenu(title: String(localized: "Window"))
        // For the Debug Console: Settings has no minimize button (HIG), and
        // AppKit disables the item while it is the key window.
        window.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let main = NSMenu()
        for menu in [app, edit, window] {
            main.addItem(withTitle: menu.title, action: nil, keyEquivalent: "").submenu = menu
        }
        NSApp.mainMenu = main
        NSApp.windowsMenu = window
    }

    private func start() {
        let controller = SuggestionController()
        suggestionController = controller
        statusMenu.bind(to: controller)
        controller.start()
        // Load (or, after an OS update, recompile — ~14 s once) the opted-in
        // Parakeet model now, not at the first held key.
        if Settings.dictationEnabled, Settings.dictationParakeet, Parakeet.isDownloaded {
            Task.detached(priority: .utility) { _ = try? await Parakeet.prepare() }
        }
        // Hourly, not only at launch: a menu-bar app runs for weeks, and a
        // fetch declined at launch (cellular, Low Data Mode, a full disk) or
        // an old build waiting for its replacement to load must not wait for
        // the next one. Every step is a no-op once done.
        Task.detached(priority: .background) {
            while !Task.isCancelled {
                await Self.maintainModels(controller)
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    /// The model upkeep an update can owe this install, in background fetches
    /// that leave the current model serving: new builds of the pick
    /// (`ModelStorage.upgradeToSlim`), the weights its recommended style runs
    /// on, and a default the memory ladder moved (`Settings.pendingDefault`).
    /// None while an API model writes the text: the local one isn't in use.
    nonisolated private static func maintainModels(_ controller: SuggestionController) async {
        guard !Settings.apiText.enabled else { return }
        let selected = Settings.mlxModelID
        await ModelStorage.upgradeToSlim(selected: selected)
        if await ModelStorage.fetchRecommendedWeights(selected: selected) {
            await MainActor.run {
                // The pick may have changed while the weights downloaded.
                guard Settings.mlxModelID == selected, Settings.useRecommendedSettings,
                      Settings.completionStyle != ModelCatalog.recommended(for: selected).style else { return }
                controller.engineCoordinator.apply(.useRecommended(true))
            }
        }
        guard let next = Settings.pendingDefault else { return }
        let style = await MainActor.run { controller.engineCoordinator.current.applying(.model(next)).style }
        guard await ModelStorage.fetchWeights(for: next, style: style) else { return }
        await MainActor.run {
            guard Settings.pendingDefault == next else { return }
            Settings.autoModelID = next
            controller.engineCoordinator.apply(.model(next))
        }
    }
}
