import AppKit

/// Settings-surface logic shared outside the SwiftUI store: the Screen
/// Recording permission flow (TCC registration + relaunch alert).
@MainActor
enum SettingsUI {
    /// Turn screen-context OCR on or off from a toggling control. Enabling it when
    /// permission isn't granted yet registers the app with TCC, opens the Screen
    /// Recording pane, and shows the relaunch alert (macOS applies this permission
    /// only at launch). Shared by the menu and the settings window.
    static func setScreenContext(_ enable: Bool) {
        guard enable else {
            Settings.screenContextEnabled = false
            return
        }
        Settings.screenContextEnabled = true
        guard !ScreenContext.hasPermission else { return }
        ScreenContext.registerWithTCC()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission"
        alert.informativeText = """
        Pretype should now appear in System Settings → Privacy & Security → \
        Screen Recording. Enable it there, then quit and relaunch Pretype — \
        macOS applies this permission only at app launch.
        """
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
