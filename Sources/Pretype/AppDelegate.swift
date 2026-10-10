import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenuController!
    private var suggestionController: SuggestionController?
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusMenu = StatusMenuController()
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
                alert.informativeText = """
                Pretype was updated, so macOS needs to grant Accessibility again.

                If Pretype already shows as switched on in System Settings, switch it \
                off and on again — or remove it with − and add it back.
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

    private func start() {
        let controller = SuggestionController()
        suggestionController = controller
        statusMenu.bind(to: controller)
        controller.start()
    }
}
