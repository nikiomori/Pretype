import AppKit
import SwiftUI

/// Ready-made per-app style templates — detailed enough to work unedited, so
/// the user tweaks taste instead of writing instructions from scratch. All
/// texts are English like the persona and directives (measured best there);
/// they steer style, not language.
///
/// They are community files, `AppStyles/{apps,sites}/*.txt` at the repo root,
/// shipped in the app bundle: anyone adds support for their app with one
/// plain-text file (AppStyles/README.md has the format), and Settings' share
/// button opens that file prefilled on GitHub.
enum PerAppPresets {
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

    /// Bundle-ID words → the community file an app of that kind borrows when
    /// nobody has written one for it ("com.readdle.smartemail…" reads as email).
    static let kinds: [(words: [String], key: String)] = [
        (["mail", "outlook", "email"], "com.apple.mail"),
        (["slack", "teams"], "com.tinyspeck.slackmacgap"),
        (["telegram", "whatsapp", "discord", "signal", "viber", "mobilesms"], "ru.keepcoder.telegram"),
        (["notes", "notion", "obsidian", "bear", "craft"], "com.apple.notes"),
        (["pages", "word"], "com.apple.iwork.pages"),
    ]

    /// Template for an arbitrary picked app or typed site — its community file
    /// first, then the file of its kind (`kinds`). nil = no guess, start blank.
    static func template(for key: String, in styles: [String: String] = community) -> String? {
        let id = key.lowercased()
        if let exact = styles[id] { return exact }
        guard AppPolicy.siteHost(fromEntry: id) == nil else { return nil }
        return kinds.first { $0.words.contains(where: id.contains) }.flatMap { styles[$0.key] }
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
            // displayName keeps ".app" when Finder shows all extensions.
            (name: (FileManager.default.displayName(atPath: $0.path) as NSString).deletingPathExtension,
             icon: NSWorkspace.shared.icon(forFile: $0.path))
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
        alert.messageText = String(localized: "Screen Recording permission")
        alert.informativeText = String(localized: """
        Screen context reads the window you're typing in, on this Mac, and macOS \
        asks for Screen Recording permission for that. Enable Pretype in System \
        Settings → Privacy & Security → Screen Recording, then quit and relaunch \
        Pretype — macOS applies this permission only at app launch.
        """)
        alert.addButton(withTitle: String(localized: "Open System Settings"))
        alert.addButton(withTitle: String(localized: "Cancel"))
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
            alert.messageText = String(localized: "Pretype needs the microphone")
            alert.informativeText = String(localized: """
            Dictation transcribes what you say on this Mac and types it into the field \
            you're in. Nothing is recorded to disk and nothing leaves your computer.

            Allow Pretype under System Settings → Privacy & Security → Microphone, \
            then switch dictation on again.
            """)
            alert.addButton(withTitle: String(localized: "Open System Settings"))
            alert.addButton(withTitle: String(localized: "Cancel"))
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

/// The interface language. macOS reads a per-app override from the app's own
/// defaults domain at launch — `AppleLanguages`, the key System Settings →
/// General → Language & Region → Applications writes — so both places show
/// the same choice, and a change applies on the next start.
enum AppLanguage {
    private static let key = "AppleLanguages"

    /// The translated languages (lproj codes), English first.
    static var available: [String] {
        let codes = Bundle.main.localizations.filter { $0 != "Base" }
        return codes.isEmpty ? ["en"] : codes.sorted { $0 == "en" || ($1 != "en" && $0 < $1) }
    }

    /// The app's own override, or nil while it follows the system. Read from
    /// the app domain alone: `UserDefaults.standard` would fall through to the
    /// global list and report the system's choice as an override.
    static var override: String? {
        get {
            let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
            return (UserDefaults.standard.persistentDomain(forName: domain)?[key] as? [String])?.first
        }
        set {
            if let newValue {
                UserDefaults.standard.set([newValue], forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    /// What the system's preferred languages resolve to for this app.
    static var systemChoice: String {
        let preferred = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[key] as? [String]
        return Bundle.preferredLocalizations(from: available, forPreferences: preferred ?? []).first ?? "en"
    }

    /// The language this process is drawing in.
    static var running: String { Bundle.main.preferredLocalizations.first ?? "en" }

    /// "English", "Русский" — each language in its own words, as language
    /// lists show them.
    static func nativeName(_ code: String) -> String {
        let locale = Locale(identifier: code)
        return locale.localizedString(forLanguageCode: code)?.capitalized(with: locale) ?? code
    }

    /// Only a bundled app can reopen itself; a bare dev binary is restarted by hand.
    static var canRelaunch: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Quits and opens the app again — the one way a running process picks up
    /// a new language. A shell waits for this process to exit, then reopens
    /// the bundle (opening it any earlier would just activate the old one).
    @MainActor static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$0\"",
                          Bundle.main.bundlePath, "\(ProcessInfo.processInfo.processIdentifier)"]
        try? task.run()
        NSApp.terminate(nil)
    }
}
