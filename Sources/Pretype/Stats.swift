import Foundation

/// Daily usage counters, persisted in UserDefaults and shown in the menu.
@MainActor
enum Stats {
    private static let defaults = UserDefaults.standard
    private static let dailyKeys = [
        "stats.shown", "stats.accepted", "stats.acceptedChars",
        "stats.corrections", "stats.latencySumMs", "stats.latencyCount",
        "stats.dictatedChars",
    ]

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static var today: String { dayFormatter.string(from: Date()) }

    /// Net keystrokes per finished day, so the menu can draw a week instead of a
    /// single number. ponytail: one day→count dictionary in UserDefaults, written
    /// once per day rollover and trimmed to the week the sparkline draws.
    private static let historyKey = "stats.savedByDay"

    private static func rollDayIfNeeded() {
        let previous = defaults.string(forKey: "stats.day")
        guard previous != today else { return }
        // Archive the day that just ended before its counters are cleared.
        if let previous {
            var history = savedByDay
            history[previous] = max(
                0,
                defaults.integer(forKey: "stats.acceptedChars") - defaults.integer(forKey: "stats.accepted")
            )
            let cutoff = day(-7)
            defaults.set(history.filter { $0.key >= cutoff }, forKey: historyKey)
        }
        defaults.set(today, forKey: "stats.day")
        for key in dailyKeys {
            defaults.removeObject(forKey: key)
        }
    }

    private static var savedByDay: [String: Int] {
        defaults.dictionary(forKey: historyKey) as? [String: Int] ?? [:]
    }

    /// `offset` days from today, as a "yyyy-MM-dd" key — Calendar rather than
    /// 86 400-second arithmetic, which skips or repeats a day across a DST shift.
    private static func day(_ offset: Int) -> String {
        guard let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) else { return today }
        return dayFormatter.string(from: date)
    }

    private static func bump(_ key: String, by amount: Int = 1) {
        rollDayIfNeeded()
        defaults.set(defaults.integer(forKey: key) + amount, forKey: key)
    }

    static func recordShown(app: String? = nil) {
        bump("stats.shown")
        bumpApp(app, shown: 1)
    }

    /// How long a ghost must survive before ignoring it counts as ignoring it.
    ///
    /// Calibrated against this Mac's own journal: the 10th percentile of
    /// ACCEPTED offers is ~680 ms and their median ~980 ms, while the median
    /// offer overall dies at ~230 ms — one keystroke, before a reader could
    /// finish looking at it.
    static let offerNoticeMs = 400

    /// True when the user had a real chance to take this offer. Booking every
    /// ghost the instant it was drawn made a denominator mostly of offers
    /// nobody could act on: the completion pipeline re-offers after each
    /// keystroke, so fast typing manufactures "shown" faster than a human can
    /// read. On a week of this Mac's journal that read 1.7% taken in every app
    /// the user actually types in — which is below the go-quiet floor, i.e. the
    /// app was on course to silence itself everywhere.
    ///
    /// Excluded, and why:
    /// * `superseded` — a newer generation replaced it; it was never an offer.
    /// * `typedThrough` — the user typed exactly what was suggested. The model
    ///   was right, so counting it as a rejection punishes it for being right.
    /// * anything gone in under `offerNoticeMs` — read before it could be read.
    ///
    /// Always counted: anything taken, whole or word-by-word (so `accepted`
    /// can never exceed `shown`), and an explicit ⎋, which is a real rejection
    /// however fast it lands.
    static func isChance(outcome: SuggestionJournal.Outcome, shownForMs: Int, tookAny: Bool) -> Bool {
        if tookAny { return true }
        switch outcome {
        case .accepted, .undone, .dismissed: return true
        case .superseded, .typedThrough: return false
        case .diverged, .abandoned: return shownForMs >= offerNoticeMs
        }
    }

    /// Book a resolved offer — see `isChance` for what makes one countable.
    static func recordOffer(
        outcome: SuggestionJournal.Outcome, shownForMs: Int, tookAny: Bool, app: String?
    ) {
        guard isChance(outcome: outcome, shownForMs: shownForMs, tookAny: tookAny) else { return }
        recordShown(app: app)
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

    /// Characters a finished dictation carried into the field — the transcript
    /// itself, not the seam spaces the injector adds around it.
    ///
    /// Booked on its OWN counter, deliberately outside `netSaved…` and the
    /// header's time figure. Speaking a sentence produces in one gesture what
    /// autocomplete accrues over dozens of accepted words: folded into the same
    /// number it would swamp it within a day, and the week of history behind
    /// the sparkline would stop meaning what it meant when it was recorded.
    /// Different gesture, different saving, different counter.
    static func recordDictated(chars: Int) {
        guard chars > 0 else { return }
        bump("stats.dictatedChars", by: chars)
        defaults.set(
            defaults.integer(forKey: "stats.lifetimeDictatedChars") + chars,
            forKey: "stats.lifetimeDictatedChars"
        )
    }

    static var dictatedToday: Int {
        rollDayIfNeeded()
        return defaults.integer(forKey: "stats.dictatedChars")
    }

    static var dictatedTotal: Int { defaults.integer(forKey: "stats.lifetimeDictatedChars") }

    static func recordLatency(_ seconds: TimeInterval) {
        bump("stats.latencySumMs", by: Int(seconds * 1000))
        bump("stats.latencyCount")
    }

    // MARK: - What the user got out of it

    /// Keystrokes saved, net of the key it cost to accept them. The gross
    /// character count treats the accept press itself as a saving, which it
    /// isn't — and this is the number the menu turns into minutes.
    static var netSavedToday: Int {
        rollDayIfNeeded()
        return max(0, defaults.integer(forKey: "stats.acceptedChars") - defaults.integer(forKey: "stats.accepted"))
    }

    static var netSavedTotal: Int {
        max(0, defaults.integer(forKey: "stats.lifetimeChars") - lifetimeAccepted)
    }

    /// ponytail: 200 chars/min ≈ 40 WPM, an average touch-typist. Measuring the
    /// user's own rate means keeping a keystroke-timing histogram for a figure
    /// that is only ever read as "roughly" — do it if anyone asks for exact.
    private static let charsPerMinute = 200.0

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()

    private static func duration(_ keystrokes: Int) -> String {
        let seconds = Double(keystrokes) / charsPerMinute * 60
        guard seconds >= 60, let text = durationFormatter.string(from: seconds) else { return "under a minute" }
        return text
    }

    /// A value and its unit, kept apart so the header can set them at different
    /// sizes — and so no wording ("under a minute") can overflow the big figure.
    private static func figure(_ keystrokes: Int) -> (value: String, unit: String) {
        let minutes = Double(keystrokes) / charsPerMinute
        if minutes < 1 { return ("<1", "min") }
        if minutes < 60 { return ("\(Int(minutes.rounded()))", "min") }
        let hours = minutes / 60
        return (hours < 10 ? String(format: "%.1f", hours) : "\(Int(hours.rounded()))", "h")
    }

    /// What the menu header leads with: time bought, not counts. An acceptance
    /// rate up front reads as a grade the user is failing — it belongs in
    /// Diagnostics, next to the latency it explains.
    /// Plain formatted data — the header reads it off the main actor without
    /// reaching back into UserDefaults or the shared formatter.
    struct Savings {
        let todayKeystrokes: Int
        let totalKeystrokes: Int
        /// Net keystrokes saved per day, oldest first, seven entries.
        let week: [Int]
        let todayFigure: (value: String, unit: String)
        let todayText: String
        let totalText: String

        /// Nothing has ever been accepted — the header shows the invitation.
        var isEmpty: Bool { totalKeystrokes == 0 }
    }

    static var savings: Savings {
        rollDayIfNeeded()
        let history = savedByDay
        let today = netSavedToday, total = netSavedTotal
        return Savings(
            todayKeystrokes: today,
            totalKeystrokes: total,
            week: (0 ..< 7).reversed().map { back in
                let key = day(-back)
                return key == Self.today ? today : (history[key] ?? 0)
            },
            todayFigure: figure(today),
            todayText: duration(today),
            totalText: duration(total)
        )
    }

    /// The raw counters, for the Diagnostics submenu.
    static var diagnosticLines: [String] {
        rollDayIfNeeded()
        let shown = defaults.integer(forKey: "stats.shown")
        let accepted = defaults.integer(forKey: "stats.accepted")
        let latencyCount = defaults.integer(forKey: "stats.latencyCount")

        let rate = shown > 0 ? " (\(accepted * 100 / shown)%)" : ""
        var lines = [
            "Suggestions: \(accepted) accepted of \(shown) shown\(rate)",
            "Fixes applied: \(defaults.integer(forKey: "stats.corrections"))",
        ]
        if latencyCount > 0 {
            lines.append("Engine latency: ~\(defaults.integer(forKey: "stats.latencySumMs") / latencyCount) ms")
        }
        let dictated = defaults.integer(forKey: "stats.dictatedChars")
        if dictated > 0 || dictatedTotal > 0 {
            lines.append("Dictated: \(dictated) chars today, \(dictatedTotal) in total")
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
    /// Chances (see `isChance`) needed before the record says anything at all.
    static let appVerdictMinShown = 60
    /// Below this share taken, the app is one Pretype is only interrupting.
    /// Deliberately brutal: the point is to stop being useless somewhere, not to
    /// prune every app that is merely below average.
    ///
    /// 2%, not the 5% this shipped with, because the denominator changed under
    /// it: counting only offers the user could act on, the apps on this Mac's
    /// journal where completions clearly do work sit at 4.5–6.4% taken, so a 5%
    /// floor would still have silenced them. Apps where the ghost is genuinely
    /// useless read a flat 0%, and that is what this is for.
    static let appQuietRate = 0.02
    /// Halve both counts past this many shown, so a new model — or a change of
    /// habit — is felt within a few hundred suggestions instead of being
    /// outvoted by last month's.
    static let appDecayAt = 400

    /// Drop track records collected under the old counting rule, once.
    ///
    /// They were built from a denominator that counted every ghost the typing
    /// outran (see `isChance`), which read ~1.7% taken everywhere and silenced
    /// the first app to reach the sample bar. Keeping those numbers would leave
    /// the user quietly muted in apps that were never judged fairly, with only a
    /// menu item they'd have to find to undo it — so the verdicts start over.
    /// Nonisolated: `Settings.registerDefaults` runs before the main actor.
    nonisolated static func migrateAppRecordsIfNeeded() {
        let defaults = UserDefaults.standard
        let key = "stats.byAppRule"
        guard defaults.integer(forKey: key) < 2 else { return }
        defaults.removeObject(forKey: appKey)
        defaults.set(2, forKey: key)
    }

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
