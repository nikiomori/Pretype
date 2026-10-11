import Foundation

/// Per-app behavior policy. Terminals get no suggestions at all (ghost text
/// next to shell commands is dangerous noise); password managers get neither
/// suggestions nor screen OCR (their windows are full of secrets, and the
/// secure-input guard only covers focused password *fields*, not item lists,
/// search boxes or secure notes); code editors keep suggestions but never
/// feed screen OCR to the model (their windows are full of code and UI text
/// that poisons a prose model).
enum AppPolicy {
    static func isTerminal(_ bundleID: String?) -> Bool {
        matches(bundleID, ["terminal", "iterm", "warp", "alacritty", "kitty", "hyper", "ghostty"])
    }

    static func isCredentialApp(_ bundleID: String?) -> Bool {
        matches(bundleID, ["1password", "onepassword", "bitwarden", "keepass", "dashlane",
                           "lastpass", "enpass", "nordpass", "protonpass", "strongbox",
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
        let hits = Settings.userBlacklist.filter { site(host, matches: $0) }
        if hits.isEmpty {
            Settings.userBlacklist.append(siteEntry(host))
        } else {
            Settings.userBlacklist.removeAll { hits.contains($0) }
        }
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
        let hits = userBlacklistEntries(for: bundleID)
        if hits.isEmpty {
            Settings.userBlacklist.append(bundleID.lowercased())
        } else {
            Settings.userBlacklist.removeAll { hits.contains($0) }
        }
    }

    static func allowsScreenContext(_ bundleID: String?) -> Bool {
        !isBlacklisted(bundleID) && !isCodeEditor(bundleID)
    }

    /// Same, with the website: a site switched off feeds no OCR or clipboard either.
    static func allowsScreenContext(_ context: TypingContext) -> Bool {
        !isBlacklisted(context) && !isCodeEditor(context.bundleID)
    }

    private static func matches(_ bundleID: String?, _ markers: [String]) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        return markers.contains { id.contains($0) }
    }
}
