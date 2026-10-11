import AppKit
import SwiftUI

/// Ready-made per-app style templates — detailed enough to work unedited, so
/// the user tweaks taste instead of writing instructions from scratch. All
/// texts are English like the persona and directives (measured best there);
/// they steer style, not language.
///
/// The per-app ones are community files, `AppStyles/{apps,sites}/*.txt` at the
/// repo root, shipped in the app bundle: anyone adds support for their app with
/// one plain-text file (AppStyles/README.md has the format), and Settings'
/// share button opens that file prefilled on GitHub. The kinds below are the
/// fallback for apps nobody has written one for yet.
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

    /// Per-app-instructions key → text, from the bundle's AppStyles folder
    /// (`Scripts/make-app.sh` copies it in; `Scripts/dev.sh` next to the binary).
    static let community = load(from: Bundle.main.resourceURL?.appendingPathComponent("AppStyles"))

    /// `apps/<lowercased bundle ID>.txt` → that ID, `sites/<host>.txt` →
    /// "site:<host>"; the text is the file minus its `#` comment lines.
    static func load(from root: URL?) -> [String: String] {
        guard let root else { return [:] }
        var styles: [String: String] = [:]
        for (folder, prefix) in [("apps", ""), ("sites", AppPolicy.sitePrefix)] {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "txt" {
                guard let contents = try? String(contentsOf: file, encoding: .utf8),
                      let text = styleText(contents) else { continue }
                styles[prefix + file.deletingPathExtension().lastPathComponent.lowercased()] = text
            }
        }
        return styles
    }

    static func styleText(_ contents: String) -> String? {
        let text = contents.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("#") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Template for an arbitrary picked app or typed site — its community file
    /// first, then a bundle-ID heuristic for apps outside the folder
    /// ("com.readdle.smartemail…" reads as email). nil = no guess, start blank.
    static func template(for key: String) -> String? {
        let id = key.lowercased()
        if let exact = community[id] { return exact }
        guard AppPolicy.siteHost(fromEntry: id) == nil else { return nil }
        if ["mail", "outlook", "email"].contains(where: id.contains) { return email }
        if ["slack", "teams"].contains(where: id.contains) { return workChat }
        if ["telegram", "whatsapp", "discord", "signal", "viber", "mobilesms"].contains(where: id.contains) {
            return casualChat
        }
        if ["notes", "notion", "obsidian", "bear", "craft"].contains(where: id.contains) { return notes }
        if ["pages", "word"].contains(where: id.contains) { return documents }
        return nil
    }

    /// Community styles for apps actually installed on this Mac and not
    /// configured yet. Sites aren't offered wholesale — "Add Website…" fills in
    /// the one typed.
    @MainActor
    static func installedSuggestions(excluding configured: Set<String>) -> [(bundleID: String, text: String)] {
        community.sorted { $0.key < $1.key }
            .filter { AppPolicy.siteHost(fromEntry: $0.key) == nil && !configured.contains($0.key)
                && InstalledApps.lookup($0.key) != nil }
            .map { (bundleID: $0.key, text: $0.value) }
    }

    /// GitHub's new-file page, prefilled with this style as its AppStyles file:
    /// GitHub forks the repo for the user and turns it into a pull request.
    /// Nothing leaves the Mac until they submit it there.
    static func shareURL(key: String, name: String, text: String) -> URL? {
        let path = AppPolicy.siteHost(fromEntry: key).map { "sites/\($0)" } ?? "apps/\(key)"
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#")
        func escape(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        let file = "# \(name)\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        return URL(string: "https://github.com/nikiomori/Pretype/new/main"
            + "?filename=\(escape("AppStyles/\(path).txt"))&value=\(escape(file))")
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
    static func present(_ alert: NSAlert, confirmed: @escaping () -> Void) {
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
