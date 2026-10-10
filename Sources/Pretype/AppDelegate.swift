import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenuController!
    private var suggestionController: SuggestionController?
    private var permissionTimer: Timer?

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
            alert.messageText = "Pretype needs Accessibility access"
            if Settings.onboardingCompleted {
                // A returning user: the grant didn't vanish, the app's signature
                // changed under it (an update). System Settings still shows
                // Pretype switched ON — a stale entry — so the first-run copy
                // left them flipping a switch that already looked right.
                Permissions.explainedRegrant = true
                alert.informativeText = """
                Pretype was updated, so macOS needs to grant Accessibility again.

                \(Permissions.regrantInstructions)
                """
            } else {
                alert.informativeText = """
                Accessibility is how Pretype reads the text field you're typing in, \
                catches the \(Settings.hotkeyStyle.label) key, and types accepted suggestions back.

                macOS will ask you to grant it next. Everything you type stays on this Mac.
                """
            }
            alert.addButton(withTitle: "Continue")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            Permissions.prompt()
            // Poll until the user grants Accessibility, then start the pipeline.
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
                Task { @MainActor in
                    guard let self else { return }
                    guard Permissions.isTrusted else { return }
                    timer.invalidate()
                    self.permissionTimer = nil
                    self.start()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        suggestionController?.shutdown()
    }

    /// Settings switches the app to `.regular`, and a regular app with no
    /// main menu has no Edit menu: ⌘C/⌘V/⌘A/⌘Z in its fields, ⌘W and ⌘Q were
    /// all dead. Only shown while `.regular` — the menu-bar mode never sees it.
    private func installMainMenu() {
        let app = NSMenu()
        app.addItem(withTitle: "About Pretype",
                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Pretype", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit Pretype", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
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
    }
}
