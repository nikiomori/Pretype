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

    private let url: URL
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "app.pretype.journal", qos: .utility)
    private let encoder = JSONEncoder()
    private var appended = 0

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
        }
    }

    func reset() {
        queue.sync { try? FileManager.default.removeItem(at: url) }
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
