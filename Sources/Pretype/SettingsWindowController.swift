import AppKit
import SwiftUI

/// Hosts the SwiftUI settings surface (`SettingsRootView`): a sidebar-driven
/// window in the System Settings shape of macOS 26 — glass sidebar, grouped
/// content, Live Impact inspector — wired live to the running pipeline
/// through `SettingsStore`: model/style changes reload the engine; length,
/// persona and personalization apply immediately. Opened from the menu (⌘,).
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let store: SettingsStore

    init(controller: SuggestionController) {
        store = SettingsStore(controller: controller)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        // The sidebar runs full height under a transparent titlebar; the pane
        // header inside the content names the pane (System Settings-style).
        window.title = "Pretype Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentViewController = NSHostingController(rootView: SettingsRootView(store: store))
        // Assigning contentViewController resizes to the fitting size — restore.
        window.setContentSize(NSSize(width: 1180, height: 720))
        window.minSize = NSSize(width: 1020, height: 620)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        store.sync()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        store.startStatusTimer()
    }

    func windowWillClose(_ notification: Notification) {
        store.stopStatusTimer()
        NSApp.setActivationPolicy(.accessory)
    }
}
