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

    static func isBlacklisted(_ bundleID: String?) -> Bool {
        if matches(bundleID, Settings.userBlacklist) {
            return true
        }
        return isTerminal(bundleID) || isCredentialApp(bundleID)
    }

    static func allowsScreenContext(_ bundleID: String?) -> Bool {
        !isBlacklisted(bundleID) && !isCodeEditor(bundleID)
    }

    private static func matches(_ bundleID: String?, _ markers: [String]) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        return markers.contains { id.contains($0) }
    }
}
