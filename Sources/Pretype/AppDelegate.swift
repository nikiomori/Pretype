import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenuController!
    private var suggestionController: SuggestionController?
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusMenu = StatusMenuController()

        if Permissions.isTrusted {
            start()
        } else {
            // A bare system Accessibility dialog with no context reads as scary
            // for an app that watches typing — explain the why first.
            let alert = NSAlert()
            alert.messageText = "Pretype needs Accessibility access"
            alert.informativeText = """
            Accessibility is how Pretype reads the text field you're typing in, \
            catches the \(Settings.hotkeyStyle.label) key, and types accepted suggestions back.

            macOS will ask you to grant it next. Everything you type stays on this Mac.
            """
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
