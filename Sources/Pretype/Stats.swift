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

    static func recordShown() {
        bump("stats.shown")
    }

    static func recordAccepted(chunk: String) {
        bump("stats.accepted")
        bump("stats.acceptedChars", by: chunk.count)
        defaults.set(
            defaults.integer(forKey: "stats.lifetimeChars") + chunk.count,
            forKey: "stats.lifetimeChars"
        )
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
}
