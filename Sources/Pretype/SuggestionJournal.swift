import Foundation

/// Local-only journal of suggestion outcomes: one JSONL line per shown
/// suggestion, written when it resolves (accepted / dismissed / diverged /
/// typed-through / …). This is the raw dataset for the offline replay bench and
/// future personalization (retrieval few-shot, personal n-grams, reranking).
///
/// Privacy: nothing ever leaves the Mac. Entries only exist where suggestions
/// ran at all (so the app blacklist / terminal policy already applies), the OCR
/// screen block is never written, and Settings has a kill switch + Clear.
final class SuggestionJournal: @unchecked Sendable {
    static let shared = SuggestionJournal()

    enum Outcome: String, Codable {
        case accepted       // fully accepted (possibly word by word)
        case dismissed      // Escape while the ghost was up
        case diverged       // the user typed something else
        case typedThrough   // the user typed exactly the suggested text, unaided
        case superseded     // replaced by a newer suggestion before resolving
        case abandoned      // focus change, control key, engine rebuild, …
        case undone         // ⌘Z reverted an accept (its own event)
    }

    struct Entry: Codable {
        var ts: String
        var app: String?
        var engine: String?
        /// The config regime that produced this suggestion — snapshotted at
        /// show-time so the offline replay can A/B *live days*, not just models.
        /// All optional: absent on older entries (decode → nil) and on undo
        /// events. `model` is the ACTUALLY LOADED model (instruct sibling in
        /// instruct style, fine-tune dir name for local models); nil for the
        /// ngram fast-path and Apple Intelligence (`engine` disambiguates).
        /// Compact by design — `gate` is "K@thr" or "off", `personalization`
        /// is "level[+rag]". Defaults keep the memberwise init source-compatible
        /// with pre-stamp call sites (undo events, tests).
        var model: String? = nil
        var style: String? = nil
        var gate: String? = nil
        var personalization: String? = nil
        /// Mean per-token log-probability of the FIRST word of `suggestion`,
        /// captured from the live decode loop (zero extra forward passes) — the
        /// raw material for the confidence→correctness calibration curve that
        /// decides whether a logprob threshold can replace the K-sample gate.
        /// Best-effort: nil for ngram/FM/gated/undo entries and legacy rows;
        /// read at resolve time, so a `superseded` entry may carry the value of
        /// the generation that superseded it — filter calibration to
        /// accepted/dismissed/diverged/typedThrough outcomes.
        var firstWordLogProb: Double? = nil
        /// Text before the caret when the suggestion appeared (capped tail).
        var ctx: String
        var after: String
        /// The suggestion as last shown (streamed partials keep it current).
        var suggestion: String
        var outcome: Outcome
        /// Characters the user accepted; negative when an accept was undone.
        var acceptedChars: Int
        /// What the user typed instead, for `diverged` (first chars only).
        var typed: String?
        var shownForMs: Int
        /// Whether the prompt also carried OCR screen context (not logged itself).
        var screen: Bool
    }

    /// A phrase the user demonstrably wanted (accepted or typed through),
    /// with the context it appeared in — the corpus for retrieval-augmented
    /// personalization (dynamic few-shot from the user's own writing).
    struct AcceptedPhrase: Sendable, Equatable {
        let ctx: String
        let next: String
        /// Index words of ctx+next, precomputed for retrieval scoring.
        let words: Set<String>

        init(ctx: String, next: String) {
            self.ctx = ctx
            self.next = next
            self.words = Set(SuggestionJournal.indexWords(ctx + " " + next))
        }
    }

    private let url: URL
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "app.pretype.journal", qos: .utility)
    private let encoder = JSONEncoder()
    private var appended = 0
    /// Retrieval corpus, lazily loaded from the file and kept current by
    /// `append`. `nil` until first use. Guarded by `queue`.
    private var phrases: [AcceptedPhrase]?
    /// Document frequency of index words across `phrases` (for IDF scoring).
    private var wordDocFreq: [String: Int] = [:]
    private let maxPhrases = 2000

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func timestamp() -> String { iso.string(from: Date()) }

    init(url: URL? = nil, maxBytes: Int = 5_000_000) {
        if let url {
            self.url = url
        } else {
            let dir = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Pretype", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.url = dir.appendingPathComponent("suggestion-journal.jsonl")
        }
        self.maxBytes = maxBytes
        queue.async { [self] in trim() }
    }

    func append(_ entry: Entry) {
        queue.async { [self] in
            guard var data = try? encoder.encode(entry) else { return }
            data.append(0x0A)
            if let handle = FileHandle(forWritingAtPath: url.path) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
            appended += 1
            if appended % 200 == 0 { trim() }
            if phrases != nil, let phrase = Self.phrase(from: entry) { indexPhrase(phrase) }
        }
    }

    func reset() {
        queue.sync {
            try? FileManager.default.removeItem(at: url)
            phrases = nil
            wordDocFreq = [:]
        }
    }

    // MARK: - Retrieval (RAG few-shot from the user's own accepted phrases)

    /// The accepted phrases most similar to `query`, by IDF-weighted word
    /// overlap (rare shared words — names, project slang — count for much more
    /// than common ones). Requires ≥2 shared index words so a single stop-wordy
    /// match never surfaces an unrelated example. Deduped by phrase text.
    func similarAcceptedPhrases(to query: String, limit: Int = 3) -> [AcceptedPhrase] {
        let queryWords = Set(Self.indexWords(query))
        guard queryWords.count >= 2 else { return [] }
        return queue.sync {
            loadPhrasesLocked()
            guard let phrases, !phrases.isEmpty else { return [] }
            let n = Double(phrases.count)
            var scored: [(AcceptedPhrase, Double)] = []
            for phrase in phrases {
                let shared = phrase.words.intersection(queryWords)
                guard shared.count >= 2 else { continue }
                let score = shared.reduce(0.0) {
                    $0 + log(1.0 + n / Double(max(1, wordDocFreq[$1] ?? 1)))
                }
                scored.append((phrase, score))
            }
            var seen = Set<String>()
            return Array(scored.sorted { $0.1 > $1.1 }
                .map(\.0)
                .filter { seen.insert($0.ctx + $0.next).inserted }
                .prefix(limit))
        }
    }

    /// The user's typed text reconstructed from the journal, for n-gram
    /// training. Consecutive entries in one field snapshot overlapping ctx
    /// tails, so counting them raw would multiply every sentence; instead each
    /// entry contributes only its DELTA vs the previous snapshot of the same
    /// app: common prefix stripped, or — when the 1000-char ctx window has
    /// slid — everything after the previous tail's reappearance.
    /// ponytail: heuristic dedup; residual duplicates only inflate counts, they
    /// don't corrupt predictions.
    func typedStreamChunks() -> [String] {
        queue.sync {
            guard let data = try? Data(contentsOf: url),
                  let content = String(data: data, encoding: .utf8) else { return [] }
            let decoder = JSONDecoder()
            var prevByApp: [String: String] = [:]
            var chunks: [String] = []
            for line in content.split(separator: "\n") {
                guard let entry = try? decoder.decode(Entry.self, from: Data(line.utf8)),
                      entry.outcome != .undone, !entry.ctx.isEmpty else { continue }
                let app = entry.app ?? "?"
                let prev = prevByApp[app] ?? ""
                prevByApp[app] = entry.ctx
                let delta = Self.newText(in: entry.ctx, since: prev)
                if !delta.isEmpty { chunks.append(delta) }
            }
            return chunks
        }
    }

    /// What `ctx` adds over the previous snapshot `prev` of the same field.
    static func newText(in ctx: String, since prev: String) -> String {
        guard !prev.isEmpty else { return ctx }
        let lcp = zip(ctx, prev).prefix { $0 == $1 }.count
        if lcp >= 30 || lcp == prev.count {
            return String(ctx.dropFirst(lcp))
        }
        // The capped tail slid: look for the previous snapshot's ending inside
        // this one and keep only what follows it.
        let tail = String(prev.suffix(40))
        if tail.count >= 20, let range = ctx.range(of: tail) {
            return String(ctx[range.upperBound...])
        }
        return ctx   // genuinely new text (new document/conversation)
    }

    /// An entry the retrieval corpus should learn from: the user accepted the
    /// text or typed it out themselves.
    private static func phrase(from e: Entry) -> AcceptedPhrase? {
        guard e.outcome == .accepted || e.outcome == .typedThrough,
              !e.suggestion.isEmpty, !e.ctx.isEmpty else { return nil }
        return AcceptedPhrase(ctx: String(e.ctx.suffix(120)), next: e.suggestion)
    }

    /// Parse the journal into the corpus once. Phrases later reverted with ⌘Z
    /// are dropped — an undone accept must not teach. Runs on `queue`.
    private func loadPhrasesLocked() {
        guard phrases == nil else { return }
        var loaded: [AcceptedPhrase] = []
        var undone = Set<String>()
        if let data = try? Data(contentsOf: url),
           let content = String(data: data, encoding: .utf8) {
            let decoder = JSONDecoder()
            for line in content.split(separator: "\n") {
                guard let entry = try? decoder.decode(Entry.self, from: Data(line.utf8)) else { continue }
                if entry.outcome == .undone { undone.insert(entry.suggestion) }
                else if let phrase = Self.phrase(from: entry) { loaded.append(phrase) }
            }
        }
        phrases = []
        for phrase in loaded.suffix(maxPhrases) where !undone.contains(phrase.next) {
            indexPhrase(phrase)
        }
    }

    /// Add one phrase to the corpus + document frequencies. Runs on `queue`.
    private func indexPhrase(_ phrase: AcceptedPhrase) {
        phrases?.append(phrase)
        for word in phrase.words { wordDocFreq[word, default: 0] += 1 }
        // ponytail: unbounded within a session past maxPhrases — the cap
        // re-applies on next launch's load; sessions never grow that far.
    }

    /// Lowercased ё-folded letter-runs ≥3 chars — the retrieval vocabulary.
    static func indexWords(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "ё", with: "е")
            .split { !$0.isLetter }.map(String.init).filter { $0.count >= 3 }
    }

    var fileSize: Int {
        queue.sync {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            return (attrs?[.size] as? NSNumber)?.intValue ?? 0
        }
    }

    /// Keep the newest half when the file outgrows `maxBytes`, cut on a line
    /// boundary. Runs on `queue`.
    /// ponytail: whole-file rewrite; fine at the few KB/day real typing produces.
    private func trim() {
        guard fileSizeLocked() > maxBytes,
              let data = try? Data(contentsOf: url) else { return }
        var start = max(0, data.count - maxBytes / 2)
        while start < data.count, data[start] != 0x0A { start += 1 }
        start = min(start + 1, data.count)
        try? Data(data[start...]).write(to: url, options: .atomic)
    }

    private func fileSizeLocked() -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.intValue ?? 0
    }
}
