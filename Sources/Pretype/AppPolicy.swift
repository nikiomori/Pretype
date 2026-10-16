import Foundation
import IOKit.ps

/// Per-app behavior policy. Terminals get suggestions only inside an AI
/// agent's input box (`AgentPrompt`) — ghost text next to shell commands is
/// dangerous noise, and the fix/reply chords stay off there; password managers get neither
/// suggestions nor screen OCR (their windows are full of secrets, and the
/// secure-input guard only covers focused password *fields*, not item lists,
/// search boxes or secure notes); code editors keep suggestions but never
/// feed screen OCR to the model (their windows are full of code and UI text
/// that poisons a prose model).
enum AppPolicy {
    /// The Mac is drawing on its battery right now.
    static var isOnBattery: Bool {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        return IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? == kIOPSBatteryPowerValue
    }

    /// Completions are paused because the user asked for that on battery.
    static var pausedForBattery: Bool { Settings.pauseOnBattery && isOnBattery }

    static func isTerminal(_ bundleID: String?) -> Bool {
        matches(bundleID, ["terminal", "iterm", "warp", "alacritty", "kitty", "hyper", "ghostty"])
    }

    /// Completions may run here: anywhere not switched off — and in a
    /// terminal, off for everything else, while the user hasn't switched it
    /// off too (`AXText.context` reads only an agent's input box there).
    static func allowsCompletions(_ context: TypingContext) -> Bool {
        !isBlacklisted(context)
            || (isTerminal(context.bundleID) && userBlacklistEntries(for: context.bundleID).isEmpty)
    }

    static func isCredentialApp(_ bundleID: String?) -> Bool {
        matches(bundleID, ["1password", "onepassword", "bitwarden", "keepass", "dashlane",
                           "lastpass", "enpass", "nordpass", "protonpass", "proton.pass", "strongbox",
                           "keychainaccess", "passwords"])
    }

    static func isCodeEditor(_ bundleID: String?) -> Bool {
        // "todesktop" is Cursor's wrapper bundle prefix.
        matches(bundleID, ["vscode", "vscodium", "cursor", "todesktop", "xcode", "jetbrains", "sublime", "zed", "nova"])
    }

    /// Website entries share the per-app lists (`Settings.userBlacklist`,
    /// `Settings.perAppInstructions`) under this prefix: "site:mail.google.com".
    static let sitePrefix = "site:"

    static func siteEntry(_ host: String) -> String { sitePrefix + host.lowercased() }

    /// The host a list entry names, or nil for an app entry.
    static func siteHost(fromEntry entry: String) -> String? {
        entry.hasPrefix(sitePrefix) ? String(entry.dropFirst(sitePrefix.count)) : nil
    }

    /// "site:google.com" covers mail.google.com too; "site:mail.google.com"
    /// doesn't cover docs.google.com.
    static func site(_ host: String, matches entry: String) -> Bool {
        guard let entryHost = siteHost(fromEntry: entry), !entryHost.isEmpty else { return false }
        return host == entryHost || host.hasSuffix("." + entryHost)
    }

    /// Off in this app, or on this website.
    static func isBlacklisted(_ context: TypingContext) -> Bool {
        if let host = context.site, Settings.userBlacklist.contains(where: { site(host, matches: $0) }) {
            return true
        }
        return isBlacklisted(context.bundleID)
    }

    /// Menu-bar "Disable/Enable on <site>": the exact host, and on the way back
    /// every entry that covered it — same contract as `toggleUserBlacklist`.
    static func toggleUserBlacklist(site host: String) {
        toggle(siteEntry(host), hits: Settings.userBlacklist.filter { site(host, matches: $0) },
               in: &Settings.userBlacklist)
    }

    static func isBlacklisted(_ bundleID: String?) -> Bool {
        if !userBlacklistEntries(for: bundleID).isEmpty {
            return true
        }
        return isTerminal(bundleID) || isCredentialApp(bundleID)
    }

    /// The user-list entries this bundle ID trips. The list holds lowercased
    /// *substring markers*, not exact IDs — "mail" silences com.apple.Mail —
    /// so anything that wants to undo a block has to remove the entry that
    /// matched, not an exact ID that may never have been in the list.
    static func userBlacklistEntries(for bundleID: String?) -> [String] {
        guard let id = bundleID?.lowercased() else { return [] }
        return Settings.userBlacklist.filter { id.contains($0) }
    }

    /// Menu-bar "Disable/Enable in <app>". Off → on appends the exact ID; on →
    /// off drops every marker that covered it, so one click always reverses the
    /// previous one even when the block came from a hand-typed fragment.
    static func toggleUserBlacklist(_ bundleID: String) {
        toggle(bundleID.lowercased(), hits: userBlacklistEntries(for: bundleID), in: &Settings.userBlacklist)
    }

    /// Nothing hit → add `entry` to `list`; else drop every entry that hit.
    private static func toggle(_ entry: String, hits: [String], in list: inout [String]) {
        if hits.isEmpty {
            list.append(entry)
        } else {
            list.removeAll { hits.contains($0) }
        }
    }

    /// A messenger, where an empty message box waits for a reply. AI chats are
    /// not here: there the user writes the first message.
    static func isChat(_ context: TypingContext) -> Bool {
        if let host = context.site {
            return ["web.telegram.org", "web.whatsapp.com", "app.slack.com", "discord.com",
                    "teams.microsoft.com", "teams.live.com", "messenger.com", "chat.google.com"]
                .contains { host == $0 || host.hasSuffix("." + $0) }
        }
        return matches(context.bundleID, ["mobilesms", "telegram", "whatsapp", "slack", "discord", "signal",
                                          "microsoft.teams", "mattermost", "im.riot", "viber", "wechat", "xinwechat"])
    }

    /// The `Settings.dictationSendApps` entry for this field: the website in a
    /// browser (one browser holds many chats), else the app's bundle ID.
    static func dictationSendEntry(_ context: TypingContext) -> String? {
        if let host = context.site { return siteEntry(host) }
        return context.bundleID?.lowercased()
    }

    /// The `Settings.dictationSendApps` entries that cover this field: its
    /// website (a parent domain covers its subdomains, as in the blacklist) and
    /// its app — a browser added in Settings means every page in it.
    static func dictationSendHits(_ context: TypingContext) -> [String] {
        let app = context.bundleID?.lowercased()
        return Settings.dictationSendApps.filter { entry in
            if let host = context.site, site(host, matches: entry) { return true }
            return entry == app
        }
    }

    /// Dictation presses ⏎ after typing here.
    static func sendsAfterDictation(_ context: TypingContext) -> Bool {
        !dictationSendHits(context).isEmpty
    }

    /// Nothing covers the field → add its entry; else drop every entry that
    /// does, or unchecking on one site of a browser added whole would not stick.
    static func toggleDictationSend(_ context: TypingContext) {
        guard let entry = dictationSendEntry(context) else { return }
        toggle(entry, hits: dictationSendHits(context), in: &Settings.dictationSendApps)
    }

    /// Screen OCR and clipboard context for this app and website: not where
    /// Pretype is off, not in a code editor.
    static func allowsScreenContext(_ context: TypingContext) -> Bool {
        !isBlacklisted(context) && !isCodeEditor(context.bundleID)
    }

    /// A marker at the start of a bundle-ID component: "dev.zed.zed" is Zed and
    /// "com.googlecode.iterm2" is iTerm, but "com.organized.app" isn't Zed and
    /// "com.innovation.notes" isn't Nova.
    static func matches(_ bundleID: String?, _ markers: [String]) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        let dotted = "." + id
        return markers.contains { dotted.contains("." + $0) }
    }
}
