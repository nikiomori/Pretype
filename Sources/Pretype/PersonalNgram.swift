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
    /// Folded 3-char prefix → surface word → count (mid-word completion
    /// vocabulary). Bucketed so `completeWord`, run on the main thread every
    /// mid-word keystroke, scans one prefix instead of the whole vocabulary
    /// (~18 ms at 20k words, ahead of the next key event).
    private var unigram: [String: [String: Int]] = [:]
    /// Build kicked off (idempotence guard for `prepareIfNeeded`).
    private var started = false
    /// Build finished — gates live learning (`observe`).
    private var prepared = false
    /// Bumped by `reset()`: a build still in flight when the user cleared the
    /// journal must discard its result, not resurrect the erased data.
    private var epoch = 0
    /// Last ctx snapshot folded in per app — the live-learning cursor (see `observe`).
    private var prevByApp: [String: String] = [:]

    /// Kick off the one-time build from the journal; cheap to call repeatedly.
    /// Predictions return nil until it finishes. The build learns into local
    /// tables and merges under one short lock hold, so keystroke-path lookups
    /// never wait behind a multi-MB journal replay. Text typed after launch is
    /// folded in live by `observe(ctx:app:)` — which stays a no-op until the
    /// build is done, so an entry resolving DURING the build is counted by the
    /// build's own file read (or the next launch's), never twice.
    func prepareIfNeeded(journal: SuggestionJournal = .shared) {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        let startEpoch = epoch
        lock.unlock()
        DispatchQueue.global(qos: .utility).async { [self] in
            let chunks = journal.typedStreamChunks()
            var bi: [String: [String: Int]] = [:]
            var tri: [String: [String: Int]] = [:]
            var uni: [String: [String: Int]] = [:]
            for chunk in chunks { Self.learn(chunk, bigram: &bi, trigram: &tri, unigram: &uni) }
            lock.lock()
            defer { lock.unlock() }
            guard epoch == startEpoch else { return }   // reset() raced the build
            bigram.merge(bi) { $0.merging($1, uniquingKeysWith: +) }
            trigram.merge(tri) { $0.merging($1, uniquingKeysWith: +) }
            unigram.merge(uni) { $0.merging($1, uniquingKeysWith: +) }
            prepared = true
        }
    }

    /// Folded lookup context of `text`: the last word plus, when two words are
    /// present, the "prev2 prev1" trigram key.
    private static func lookupContext(_ text: String) -> (last: String, triKey: String?)? {
        // The tail, not all ~1,200 chars into ~200 Strings per keystroke; with
        // three words in it, the one the cut may split isn't among the two.
        let tail = words(String(text.suffix(200)))
        let context = (tail.count >= 3 ? tail : words(text)).suffix(2).map(fold)
        guard let last = context.last else { return nil }
        return (last, context.count == 2 ? context.joined(separator: " ") : nil)
    }

    /// The next word the user typically types after `text`, when the evidence
    /// is strong: a trigram continuation seen ≥2 times or a bigram seen ≥3,
    /// and in either case ≥50% of everything ever typed after that context.
    func nextWord(after text: String) -> String? {
        guard let context = Self.lookupContext(text) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let triKey = context.triKey,
           let hit = Self.confident(trigram[triKey], minCount: 2) {
            return hit
        }
        return Self.confident(bigram[context.last], minCount: 3)
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
        for (word, count) in unigram[Self.prefixKey(folded)] ?? [:] where word.count >= partial.count + 2 {
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

    /// Live learning from a resolving suggestion's ctx snapshot — the same
    /// per-app delta logic as the startup build (`typedStreamChunks`), applied
    /// as entries resolve so today's typing predicts today, not from the next
    /// launch. The first snapshot per app only seeds the cursor: its text is
    /// already journaled, so the startup build (or the next launch's) covers
    /// it — learning it here would double-count. No-op until the build
    /// FINISHED (`prepared`): entries resolving mid-build are in the file the
    /// build reads, so learning them live too would also double-count.
    func observe(ctx: String, app: String?) {
        guard !ctx.isEmpty else { return }
        let key = app ?? "?"
        lock.lock()
        defer { lock.unlock() }
        guard prepared else { return }
        if let prev = prevByApp[key] {
            let delta = SuggestionJournal.newText(in: ctx, since: prev)
            if !delta.isEmpty { learnLocked(delta) }
        }
        prevByApp[key] = ctx
    }

    /// Size of the personal vocabulary — the Settings "learned words" figure.
    var wordCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return unigram.values.reduce(0) { $0 + $1.count }
    }

    /// Build finished. Lets tests (and the UI, if it ever wants a spinner)
    /// await the async startup replay.
    var isPrepared: Bool {
        lock.lock()
        defer { lock.unlock() }
        return prepared
    }

    func reset() {
        lock.lock()
        bigram = [:]; trigram = [:]; unigram = [:]
        prevByApp = [:]
        started = false
        prepared = false
        epoch += 1
        lock.unlock()
    }

    private func learnLocked(_ text: String) {
        Self.learn(text, bigram: &bigram, trigram: &trigram, unigram: &unigram)
    }

    /// The counting core, table-agnostic so the startup build can learn into
    /// LOCAL tables off the lock and merge at the end.
    private static func learn(_ text: String,
                              bigram: inout [String: [String: Int]],
                              trigram: inout [String: [String: Int]],
                              unigram: inout [String: [String: Int]]) {
        let words = words(text)
        for (i, word) in words.enumerated() {
            if word.count >= 3 { unigram[prefixKey(fold(word)), default: [:]][word, default: 0] += 1 }
            if i >= 1 {
                bigram[fold(words[i - 1]), default: [:]][word, default: 0] += 1
            }
            if i >= 2 {
                let key = fold(words[i - 2]) + " " + fold(words[i - 1])
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
        text.split { !$0.isWordChar }.map(String.init)
    }

    /// `unigram`'s bucket: completion needs ≥3 typed chars, so every match
    /// of a partial shares its first three.
    private static func prefixKey(_ folded: String) -> String { String(folded.prefix(3)) }

    static func fold(_ word: String) -> String {
        word.lowercased().replacingOccurrences(of: "ё", with: "е")
    }
}
