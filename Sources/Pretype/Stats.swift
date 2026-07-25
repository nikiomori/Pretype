import Foundation

/// Daily usage counters, persisted in UserDefaults and shown in the menu.
@MainActor
enum Stats {
    private static let defaults = UserDefaults.standard
    private static let dailyKeys = [
        "stats.shown", "stats.accepted", "stats.acceptedChars",
        "stats.corrections", "stats.latencySumMs", "stats.latencyCount",
    ]

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static var today: String { dayFormatter.string(from: Date()) }

    private static func rollDayIfNeeded() {
        guard defaults.string(forKey: "stats.day") != today else { return }
        defaults.set(today, forKey: "stats.day")
        for key in dailyKeys {
            defaults.removeObject(forKey: key)
        }
    }

    private static func bump(_ key: String, by amount: Int = 1) {
        rollDayIfNeeded()
        defaults.set(defaults.integer(forKey: key) + amount, forKey: key)
    }

    static func recordShown(app: String? = nil) {
        bump("stats.shown")
        bumpApp(app, shown: 1)
    }

    static func recordAccepted(chunk: String, countSuggestion: Bool = true, app: String? = nil) {
        // A suggestion accepted word-by-word calls this per word: count it as one
        // accepted suggestion (keeps "accepted ≤ shown"), but accrue chars per chunk.
        if countSuggestion {
            bump("stats.accepted")
            bumpApp(app, accepted: 1)
            defaults.set(lifetimeAccepted + 1, forKey: "stats.lifetimeAccepted")
        }
        bump("stats.acceptedChars", by: chunk.count)
        defaults.set(
            defaults.integer(forKey: "stats.lifetimeChars") + chunk.count,
            forKey: "stats.lifetimeChars"
        )
    }

    /// Lifetime accept count — the UI uses it to retire tutoring hints once
    /// accepting is muscle memory.
    static var lifetimeAccepted: Int {
        defaults.integer(forKey: "stats.lifetimeAccepted")
    }

    static func recordCorrection() {
        bump("stats.corrections")
    }

    static func recordLatency(_ seconds: TimeInterval) {
        bump("stats.latencySumMs", by: Int(seconds * 1000))
        bump("stats.latencyCount")
    }

    static var lines: [String] {
        rollDayIfNeeded()
        let shown = defaults.integer(forKey: "stats.shown")
        let accepted = defaults.integer(forKey: "stats.accepted")
        let chars = defaults.integer(forKey: "stats.acceptedChars")
        let fixes = defaults.integer(forKey: "stats.corrections")
        let lifetime = defaults.integer(forKey: "stats.lifetimeChars")
        let latencyCount = defaults.integer(forKey: "stats.latencyCount")

        let rate = shown > 0 ? " (\(accepted * 100 / shown)%)" : ""
        var lines = [
            "Today: \(accepted) accepted of \(shown) shown\(rate)",
            "Keystrokes saved: \(chars) today · \(lifetime) total",
        ]
        if fixes > 0 {
            lines.append("Fixes applied today: \(fixes)")
        }
        if latencyCount > 0 {
            let avg = defaults.integer(forKey: "stats.latencySumMs") / latencyCount
            lines.append("Engine latency: ~\(avg) ms")
        }
        return lines
    }

    // MARK: - Per-app track record

    /// Suggestions shown and taken per app, so Pretype can stop offering where it
    /// demonstrably isn't helping instead of interrupting forever. Kept lifetime
    /// rather than daily — a verdict needs a few dozen suggestions, which is more
    /// than a day of typing in most apps.
    ///
    /// ponytail: one dictionary of two ints per app in UserDefaults, rewritten on
    /// each suggestion. At typing rates that is nothing, and it needs no schema,
    /// no store and no migration.
    private static let appKey = "stats.byApp"
    /// Suggestions needed before the record says anything at all.
    static let appVerdictMinShown = 60
    /// Below this share taken, the app is one Pretype is only interrupting.
    /// Deliberately brutal: the point is to stop being useless somewhere, not to
    /// prune every app that is merely below average.
    static let appQuietRate = 0.05
    /// Halve both counts past this many shown, so a new model — or a change of
    /// habit — is felt within a few hundred suggestions instead of being
    /// outvoted by last month's.
    static let appDecayAt = 400

    static func record(for app: String?) -> (shown: Int, accepted: Int)? {
        guard let app, let pair = records()[app], pair.count == 2, pair[0] > 0 else { return nil }
        return (pair[0], pair[1])
    }

    /// True when this app has shown enough to judge and almost nothing was taken.
    /// Read on the keystroke path, like `AppPolicy.isBlacklisted` — a dictionary
    /// of a few entries out of UserDefaults, next to nothing beside the AX read
    /// that same keystroke already did.
    ///
    /// Note the one-way door: going quiet stops `recordShown`, so the counts
    /// freeze and nothing can lift this by itself. That is why the status menu
    /// surfaces it with the numbers and a one-click Resume (`clearRecord`) —
    /// a silent, self-inflicted block the user can't see or undo would be worse
    /// than the nagging it replaces.
    static func isUnproductive(_ app: String?) -> Bool {
        guard let record = record(for: app), record.shown >= appVerdictMinShown else { return false }
        return Double(record.accepted) / Double(record.shown) < appQuietRate
    }

    static func clearRecord(for app: String?) {
        guard let app else { return }
        var all = records()
        all.removeValue(forKey: app)
        defaults.set(all, forKey: appKey)
    }

    private static func records() -> [String: [Int]] {
        defaults.dictionary(forKey: appKey) as? [String: [Int]] ?? [:]
    }

    private static func bumpApp(_ app: String?, shown: Int = 0, accepted: Int = 0) {
        guard let app else { return }
        var all = records()
        var pair = all[app] ?? [0, 0]
        guard pair.count == 2 else { return }
        pair[0] += shown
        pair[1] += accepted
        if pair[0] >= appDecayAt {
            pair = [pair[0] / 2, pair[1] / 2]
        }
        all[app] = pair
        defaults.set(all, forKey: appKey)
    }
}
