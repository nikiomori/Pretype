import AppKit

/// Notify-only update check against the GitHub Releases API.
///
/// It deliberately does NOT install anything. Release builds are ad-hoc signed
/// (`Scripts/dist.sh` — no paid Developer ID), and replacing the bundle in place
/// changes its code signature, which makes macOS revoke the Accessibility grant
/// the whole app runs on. Telling the user to download beats silently breaking
/// their permissions. Swap this for Sparkle once releases are Developer
/// ID-signed and notarized — then the signature is stable across updates.
///
/// ponytail: no appcast, no downloader, no delta — one JSON GET and a link.
@MainActor
enum UpdateChecker {
    private static let api = URL(string: "https://api.github.com/repos/nikiomori/Pretype/releases/latest")!
    private static let page = URL(string: "https://github.com/nikiomori/Pretype/releases/latest")!
    private static let defaults = UserDefaults.standard

    /// Version of a newer published release, or nil when we're current / haven't
    /// checked. Read by the status menu to show the "Update to …" item.
    private(set) static var availableVersion: String?

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Fire-and-forget check at launch, at most once a day, and only if the user
    /// left automatic checks on — this app promises nothing leaves your Mac, so
    /// the one outbound request it makes on its own has to be opt-out-able.
    static func checkInBackground() {
        guard Settings.automaticUpdateCheck else { return }
        let day: TimeInterval = 24 * 60 * 60
        guard Date().timeIntervalSince1970 - defaults.double(forKey: "lastUpdateCheck") > day else { return }
        Task { await check() }
    }

    /// Returns the latest published version, or nil if the check itself failed
    /// (offline, rate-limited, malformed) — so callers can tell "you're current"
    /// apart from "couldn't reach GitHub". Updates `availableVersion` as a side
    /// effect. Never throws, never alerts: a failed update check is not news.
    @discardableResult
    static func check() async -> String? {
        defaults.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
        guard let latest = await fetchLatestVersion() else { return nil }
        availableVersion = isNewer(latest, than: currentVersion) ? latest : nil
        return latest
    }

    private static func fetchLatestVersion() async -> String? {
        var request = URLRequest(url: api)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String
        else { return nil }
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// Component-wise numeric compare: a plain string compare would call 0.9.1
    /// newer than 0.10.0 and pester everyone into a downgrade. Non-numeric
    /// suffixes ("0.2.0-beta") compare by their leading number, so a pre-release
    /// never outranks the final tag of the same version.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let new = parts(candidate), old = parts(current)
        for i in 0 ..< max(new.count, old.count) {
            let a = i < new.count ? new[i] : 0
            let b = i < old.count ? old[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    static func openReleasePage() {
        NSWorkspace.shared.open(page)
    }
}
