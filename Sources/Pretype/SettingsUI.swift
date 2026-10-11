import AppKit
import SwiftUI

/// Ready-made per-app style templates — detailed enough to work unedited, so
/// the user tweaks taste instead of writing instructions from scratch. All
/// texts are English like the persona and directives (measured best there);
/// they steer style, not language.
enum PerAppPresets {
    static let email = "This is email: complete, grammatical sentences in a polite, professional tone. "
        + "Open replies with a brief greeting and close politely. No slang, no emoji."
    static let workChat = "This is work chat: short, direct messages in a friendly professional tone. "
        + "Contractions are fine. Skip greetings and sign-offs. Emoji only when it adds meaning."
    static let casualChat = "This is casual chat with friends: very short, relaxed, conversational replies. "
        + "Informal wording and contractions. Never formal phrases, greetings or sign-offs."
    static let notes = "These are personal notes: concise and factual. Prefer short phrases over full "
        + "sentences. No conversational filler, no emoji."
    static let documents = "This is a document: clear, well-structured prose in complete sentences, "
        + "neutral and polished. No chat mannerisms, no emoji."

    /// Exact bundle IDs (lowercased — the engines match exactly) for the
    /// one-click suggestions.
    static let suggestions: [(bundleID: String, text: String)] = [
        ("com.apple.mail", email),
        ("com.microsoft.outlook", email),
        ("com.readdle.smartemail-macos", email),  // Spark
        ("com.tinyspeck.slackmacgap", workChat),
        ("com.microsoft.teams2", workChat),
        ("com.apple.mobilesms", casualChat),  // Messages
        ("ru.keepcoder.telegram", casualChat),
        ("org.telegram.desktop", casualChat),
        ("net.whatsapp.whatsapp", casualChat),
        ("com.hnc.discord", casualChat),
        ("org.whispersystems.signal-desktop", casualChat),
        ("com.apple.notes", notes),
        ("notion.id", notes),
        ("md.obsidian", notes),
        ("net.shinyfrog.bear", notes),
        ("com.apple.iwork.pages", documents),
    ]

    /// Template for an arbitrary picked app — exact ID first, then a bundle-ID
    /// heuristic for apps outside the list ("com.readdle.smartemail…" reads as
    /// email). nil = no guess, start blank.
    static func template(for bundleID: String) -> String? {
        let id = bundleID.lowercased()
        if let exact = suggestions.first(where: { $0.bundleID == id }) { return exact.text }
        if ["mail", "outlook", "email"].contains(where: id.contains) { return email }
        if ["slack", "teams"].contains(where: id.contains) { return workChat }
        if ["telegram", "whatsapp", "discord", "signal", "viber", "mobilesms"].contains(where: id.contains) {
            return casualChat
        }
        if ["notes", "notion", "obsidian", "bear", "craft"].contains(where: id.contains) { return notes }
        if ["pages", "word"].contains(where: id.contains) { return documents }
        return nil
    }

    /// Suggestions for apps actually installed on this Mac and not configured yet.
    @MainActor
    static func installedSuggestions(excluding configured: Set<String>) -> [(bundleID: String, text: String)] {
        suggestions.filter { !configured.contains($0.bundleID) && InstalledApps.lookup($0.bundleID) != nil }
    }
}

/// LaunchServices lookups for Settings, memoized: the rows that show app names
/// and icons re-render on every keystroke in the persona and per-app fields,
/// and each lookup (plus `icon(forFile:)`) is a LaunchServices round-trip —
/// about twenty of them per keystroke before this.
/// ponytail: never invalidated — an app installed or removed while Pretype
/// runs reads as it was until a relaunch.
@MainActor
enum InstalledApps {
    private static var cache: [String: (name: String, icon: NSImage)?] = [:]

    static func lookup(_ bundleID: String) -> (name: String, icon: NSImage)? {
        if let hit = cache[bundleID] { return hit }
        let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map {
            (name: FileManager.default.displayName(atPath: $0.path), icon: NSWorkspace.shared.icon(forFile: $0.path))
        }
        cache[bundleID] = found
        return found
    }
}

/// Settings-surface logic shared outside the SwiftUI store: the permission
/// flows (explain first, then open System Settings) and the sheets they and
/// the store's file pickers present on the Settings window.
@MainActor
enum SettingsUI {
    /// Turn screen-context OCR on or off from a toggling control. Enabling it
    /// without permission explains what is needed first, as a sheet; only on
    /// "Open System Settings" does it register the app with TCC and open the
    /// Screen Recording pane — and it doesn't pull Pretype back in front after,
    /// which raced System Settings for the user's attention.
    static func setScreenContext(_ enable: Bool) {
        guard enable else {
            Settings.screenContextEnabled = false
            return
        }
        Settings.screenContextEnabled = true
        guard !ScreenContext.hasPermission else { return }
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission"
        alert.informativeText = """
        Screen context reads the window you're typing in, on this Mac, and macOS \
        asks for Screen Recording permission for that. Enable Pretype in System \
        Settings → Privacy & Security → Screen Recording, then quit and relaunch \
        Pretype — macOS applies this permission only at app launch.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        present(alert) { openScreenRecordingPane() }
    }

    /// Register with TCC first — the pane lists Pretype only after a capture
    /// attempt — then open it. Every "Open System Settings" for Screen
    /// Recording goes through here, or the user lands on a list without us.
    static func openScreenRecordingPane() {
        ScreenContext.registerWithTCC()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Turn hold-to-talk dictation on or off. Enabling asks for the microphone
    /// the first time; a refusal — just now, or earlier, which macOS never asks
    /// about twice — can only be undone in System Settings, so that case says
    /// so and offers the pane instead of leaving a switch that flips and does
    /// nothing. `completion` reports whether the feature is actually usable,
    /// so the caller can snap its toggle back.
    static func setDictation(_ enable: Bool, completion: @escaping (Bool) -> Void) {
        guard enable else {
            Settings.dictationEnabled = false
            completion(true)
            return
        }
        Task { @MainActor in
            let granted = await MicrophoneAccess.request()
            Settings.dictationEnabled = granted
            completion(granted)
            guard !granted else { return }
            let alert = NSAlert()
            alert.messageText = "Pretype needs the microphone"
            alert.informativeText = """
            Dictation transcribes what you say on this Mac and types it into the field \
            you're in. Nothing is recorded to disk and nothing leaves your computer.

            Allow Pretype under System Settings → Privacy & Security → Microphone, \
            then switch dictation on again.
            """
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            present(alert) {
                if let url = MicrophoneAccess.settingsURL { NSWorkspace.shared.open(url) }
            }
        }
    }

    /// The Settings window, for sheets — nil once it has closed.
    private static var settingsWindow: NSWindow? {
        NSApp.windows.first {
            $0.isVisible && $0.contentViewController is NSHostingController<SettingsRootView>
        }
    }

    /// `alert` as a sheet on the Settings window (app-modal only if that is
    /// gone); `confirmed` runs on its first button.
    private static func present(_ alert: NSAlert, confirmed: @escaping () -> Void) {
        guard let window = settingsWindow else {
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { confirmed() }
            return
        }
        alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { confirmed() } }
    }

    /// `panel` as a sheet on the Settings window (app-modal only if that is
    /// gone); `picked` gets the chosen URLs on OK.
    static func run(_ panel: NSOpenPanel, picked: @escaping ([URL]) -> Void) {
        guard let window = settingsWindow else {
            if panel.runModal() == .OK { picked(panel.urls) }
            return
        }
        panel.beginSheetModal(for: window) { if $0 == .OK { picked(panel.urls) } }
    }
}
