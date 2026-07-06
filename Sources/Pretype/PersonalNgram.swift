import Foundation

/// Personal word n-gram model built from the user's own typing (the journal's
/// reconstructed stream) — the Gboard-style layer that knows the user's
/// recurring phrases, names and slang, which no pretrained model can. Used as
/// an instant fast-path: a confident hit is shown at ~0 ms while the LLM
/// streams, and the LLM then supersedes it.
///
/// Predictions are deliberately conservative — a personal n-gram should fire
/// rarely but precisely; below the evidence thresholds it returns nil and the
/// LLM path proceeds alone. Everything is local, derived from the journal, and
/// gated on the "Learn my words" setting.
final class PersonalNgram: @unchecked Sendable {
    static let shared = PersonalNgram()

    private let lock = NSLock()
    /// Folded previous word → surface next word → count.
    private var bigram: [String: [String: Int]] = [:]
    /// "prev2 prev1" folded → surface next word → count.
    private var trigram: [String: [String: Int]] = [:]
    /// Surface word → count (mid-word completion vocabulary).
    private var unigram: [String: Int] = [:]
    private var prepared = false

    /// Kick off the one-time build from the journal; cheap to call repeatedly.
    /// Predictions return nil until it finishes.
    /// ponytail: rebuilt only per launch — text typed after launch is learned
    /// next start; add incremental learning if that lag ever matters.
    func prepareIfNeeded(journal: SuggestionJournal = .shared) {
        lock.lock()
        guard !prepared else { lock.unlock(); return }
        prepared = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).async { [self] in
            let chunks = journal.typedStreamChunks()
            lock.lock()
            for chunk in chunks { learnLocked(chunk) }
            lock.unlock()
        }
    }

    /// The next word the user typically types after `text`, when the evidence
    /// is strong: a trigram continuation seen ≥2 times or a bigram seen ≥3,
    /// and in either case ≥50% of everything ever typed after that context.
    func nextWord(after text: String) -> String? {
        let context = Self.words(text).suffix(2).map(Self.fold)
        guard let last = context.last else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if context.count == 2,
           let hit = Self.confident(trigram[context.joined(separator: " ")], minCount: 2) {
            return hit
        }
        return Self.confident(bigram[last], minCount: 3)
    }

    /// Complete the partial word at the caret from the personal vocabulary:
    /// the dominant surface form starting with it (count ≥3, ≥2× the runner-up,
    /// adding ≥2 chars). Returns only the remainder to type.
    func completeWord(partial: String) -> String? {
        guard partial.count >= 3 else { return nil }
        let folded = Self.fold(partial)
        lock.lock()
        defer { lock.unlock() }
        var best: (word: String, count: Int)?
        var runnerUp = 0
        for (word, count) in unigram where word.count >= partial.count + 2 {
            guard Self.fold(word).hasPrefix(folded) else { continue }
            if count > (best?.count ?? 0) {
                runnerUp = best?.count ?? 0
                best = (word, count)
            } else if count > runnerUp {
                runnerUp = count
            }
        }
        guard let best, best.count >= 3, best.count >= runnerUp * 2 else { return nil }
        return String(best.word.dropFirst(partial.count))
    }

    /// Fold a stretch of the user's text into the counts. Callers hold no lock.
    func learn(_ text: String) {
        lock.lock()
        learnLocked(text)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        bigram = [:]; trigram = [:]; unigram = [:]
        prepared = false
        lock.unlock()
    }

    private func learnLocked(_ text: String) {
        let words = Self.words(text)
        for (i, word) in words.enumerated() {
            if word.count >= 3 { unigram[word, default: 0] += 1 }
            if i >= 1 {
                bigram[Self.fold(words[i - 1]), default: [:]][word, default: 0] += 1
            }
            if i >= 2 {
                let key = Self.fold(words[i - 2]) + " " + Self.fold(words[i - 1])
                trigram[key, default: [:]][word, default: 0] += 1
            }
        }
    }

    /// The dominant continuation, or nil when the evidence is thin or split.
    private static func confident(_ counts: [String: Int]?, minCount: Int) -> String? {
        guard let counts, !counts.isEmpty else { return nil }
        let total = counts.values.reduce(0, +)
        guard let top = counts.max(by: { $0.value < $1.value }),
              top.value >= minCount, top.value * 2 > total else { return nil }
        return top.key
    }

    /// Letter-runs in order, surface case preserved (names must stay "Никита").
    static func words(_ text: String) -> [String] {
        text.split { !$0.isLetter && $0 != "'" && $0 != "’" && $0 != "-" }
            .map(String.init)
    }

    static func fold(_ word: String) -> String {
        word.lowercased().replacingOccurrences(of: "ё", with: "е")
    }
}
