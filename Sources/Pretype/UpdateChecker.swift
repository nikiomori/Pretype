import AppKit
import Security

/// Notify-only update check against the GitHub Releases API.
///
/// It deliberately does NOT install anything. Releases from 2.5.0 on are
/// Developer ID-signed and notarized, so the signature (and with it the
/// Accessibility grant) now survives an update — which makes Sparkle an
/// option, not yet a need. Everything up to 2.4.0 was ad-hoc signed, and an
/// in-place swap from one of those still costs a one-time re-grant.
///
/// ponytail: no appcast, no downloader, no delta — one JSON GET, and either a
/// link or the one-line Homebrew command, depending on how this copy arrived.
@MainActor
enum UpdateChecker {
    private static let page = URL(string: "https://github.com/nikiomori/Pretype/releases/latest")!
    private static let defaults = UserDefaults.standard

    /// Version of a newer published release, or nil when we're current / haven't
    /// checked. Read by the status menu to show the "Update to …" item.
    private(set) static var availableVersion: String?

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// What to tell a Homebrew user to run. `brew` has to move the cask's own
    /// metadata forward, so downloading over /Applications behind its back
    /// leaves the two disagreeing about what is installed.
    static let upgradeCommand = "brew upgrade --cask pretype"

    /// True when this copy came from the tap. The cask's metadata directory
    /// stays in the Caskroom even though the app itself is installed into
    /// /Applications, so its presence names the install channel.
    ///
    /// ponytail: one `fileExists` — asking `brew` itself means spawning a
    /// process from a menu item to learn something a directory already says.
    /// Apple Silicon only, so `/opt/homebrew` is the only prefix that can apply.
    static var isHomebrewInstall: Bool {
        FileManager.default.fileExists(atPath: "/opt/homebrew/Caskroom/pretype")
    }

    /// Fire-and-forget check at launch, at most once a day, and only if the user
    /// left automatic checks on — this app promises nothing leaves your Mac, so
    /// the one outbound request it makes on its own has to be opt-out-able.
    static func checkInBackground() {
        guard Settings.automaticUpdateCheck, !backgroundCheckRunning else { return }
        let day: TimeInterval = 24 * 60 * 60
        guard Date().timeIntervalSince1970 - defaults.double(forKey: "lastUpdateCheck") > day else { return }
        // Called on every menu open, and the stamp lands only on success — so
        // offline, without this, each open would start another 10 s fetch.
        backgroundCheckRunning = true
        Task {
            await check()
            backgroundCheckRunning = false
        }
    }

    private static var backgroundCheckRunning = false

    /// Returns the latest published version, or nil if the check itself failed
    /// (offline, rate-limited, malformed) — so callers can tell "you're current"
    /// apart from "couldn't reach GitHub". Updates `availableVersion` as a side
    /// effect. Never throws, never alerts: a failed update check is not news.
    @discardableResult
    static func check() async -> String? {
        guard let latest = await fetchLatestVersion() else { return nil }
        // Stamped on success only: stamped up front, a check made offline
        // suppressed every retry for a day.
        defaults.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
        availableVersion = isNewer(latest, than: currentVersion) ? latest : nil
        return latest
    }

    private static func fetchLatestVersion() async -> String? {
        guard let tag = await latestRelease(of: "Pretype")?["tag_name"] as? String else { return nil }
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// The latest release of one of our repos, as GitHub's JSON; nil on any failure.
    private static func latestRelease(of repo: String) async -> [String: Any]? {
        guard let url = URL(string: "https://api.github.com/repos/nikiomori/\(repo)/releases/latest") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - Refrain

    /// Refrain (github.com/nikiomori/Refrain), the on-device speech engine
    /// Settings → API can dictate through. The status menu offers it until
    /// it's installed.
    static var isRefrainInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "dev.nikiomori.refrain") != nil
    }

    /// Opens the latest release's zip, so the browser downloads it in one
    /// click; the release page when GitHub can't name the file.
    ///
    /// ponytail: the browser downloads and the user drags it to Applications.
    /// Installing it ourselves would skip the quarantine flag, and with it
    /// Gatekeeper's check of the download.
    static func downloadRefrain() async {
        // The lookup can take its full ten seconds with nothing on screen; a
        // second click meanwhile must not start a second download.
        guard !fetchingRefrain else { return }
        fetchingRefrain = true
        defer { fetchingRefrain = false }
        let assets = await latestRelease(of: "Refrain")?["assets"] as? [[String: Any]] ?? []
        // The app's own zip ("Refrain-<version>.zip"), not a dSYM or source zip.
        let zip = assets.lazy
            .filter { ($0["name"] as? String)?.hasPrefix("Refrain") == true }
            .compactMap { $0["browser_download_url"] as? String }
            .first { $0.hasPrefix("https://github.com/") && $0.hasSuffix(".zip") }
        let fallback = URL(string: "https://github.com/nikiomori/Refrain/releases/latest")!
        NSWorkspace.shared.open(zip.flatMap(URL.init(string:)) ?? fallback)
    }

    private static var fetchingRefrain = false

    /// Numeric compare: a plain string compare would call 0.9.1 newer than
    /// 0.10.0 and pester everyone into a downgrade. The "-beta" suffix goes
    /// first, so a pre-release never outranks the final tag of the same
    /// version ("2.6.0-beta.1" compared whole reads as 2.6.0.1).
    /// ponytail: "1.0.0" reads newer than "1.0" — every tag and bundle version
    /// has three parts; pad them if that ever changes.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func release(_ v: String) -> String { String(v.prefix { $0 != "-" }) }
        // Garbage ("nightly") must not read as newer.
        guard candidate.first?.isNumber == true else { return false }
        return release(candidate).compare(release(current), options: .numeric) == .orderedDescending
    }

    /// True when this copy has no Team ID (ad-hoc signed). Only then does
    /// replacing it change the identity macOS keys the Accessibility grant to;
    /// a Developer ID build keeps its grant across updates.
    static var isAdHocSigned: Bool {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return true }
        return dict[kSecCodeInfoTeamIdentifier as String] == nil
    }

    static func openReleasePage() {
        NSWorkspace.shared.open(page)
    }
}
