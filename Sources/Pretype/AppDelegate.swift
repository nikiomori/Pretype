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
