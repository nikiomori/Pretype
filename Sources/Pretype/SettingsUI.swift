import AppKit

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
    static func installedSuggestions(excluding configured: Set<String>) -> [(bundleID: String, text: String)] {
        suggestions.filter {
            !configured.contains($0.bundleID)
                && NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil
        }
    }
}

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
