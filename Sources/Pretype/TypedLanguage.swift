import Foundation

/// Which language the user is actually typing in, accumulated from the language
/// detection `SpellChecker` already runs on the text around the caret — no
/// second recognizer and no new work on the typing path, just a counter bump.
///
/// Deliberately slow to make up its mind. `NLLanguageRecognizer` mislabels short
/// text confidently — the same reason `SpellChecker.isKnownWord` judges by script
/// instead ("я хочу " reads as Ukrainian) — so one observation is worthless and
/// even a run of agreeing ones can be the same misread sentence re-examined on
/// consecutive keystrokes. A language becomes `dominant` only once it holds a
/// clear majority of a decent sample, and even then it only ever *suggests*:
/// nothing here switches a model on its own.
enum TypedLanguage {
    /// Sample size before any verdict, and the share the leader must hold.
    static let minObservations = 60
    static let minShare = 0.7
    /// Halve the counts past this many observations, so someone who switches
    /// languages is noticed within a page or two instead of being outvoted
    /// forever by what they typed this morning.
    static let decayAt = 400

    private static let lock = NSLock()
    private static var counts: [String: Int] = [:]
    private static var total = 0

    /// Feed one detection. Cheap enough to call from the typing path; safe off
    /// the main thread (the detection it rides on is lock-guarded for the same
    /// reason — the eval harness calls it from a background queue).
    static func observe(_ code: String) {
        guard !code.isEmpty else { return }
        // NLLanguageRecognizer tags Chinese with a script ("zh-Hans"/"zh-Hant")
        // while the eval tables key on the bare code — keep only the language
        // subtag or `dominant` could never match a measured axis for Chinese.
        let code = code.prefix(while: { $0 != "-" }).lowercased()
        lock.lock()
        defer { lock.unlock() }
        counts[code, default: 0] += 1
        total += 1
        guard total >= decayAt else { return }
        counts = counts.compactMapValues { $0 / 2 > 0 ? $0 / 2 : nil }
        total = counts.values.reduce(0, +)
    }

    /// The language being typed, or nil while the signal is thin or mixed.
    static var dominant: String? {
        lock.lock()
        defer { lock.unlock() }
        guard total >= minObservations,
              let top = counts.max(by: { $0.value < $1.value }),
              Double(top.value) / Double(total) >= minShare
        else { return nil }
        return top.key
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        counts.removeAll()
        total = 0
    }
}
