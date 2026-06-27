import Foundation

/// On-device personalization: learns the words the user actually accepts and
/// later biases the model's logits toward them (the interpolation idea from
/// Gmail Smart Compose, done as a simple favored-word bias). Everything lives in
/// a local JSON file under Application Support; nothing is ever sent anywhere,
/// and collection only happens while personalization is enabled.
final class Personalization: @unchecked Sendable {
    static let shared = Personalization()

    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private let url: URL
    /// Bound the store so the file and the bias build stay cheap.
    private let maxWords = 3000
    private let queue = DispatchQueue(label: "app.pretype.personalization", qos: .utility)

    /// Cached sorted word list — invalidated on `record()` / `reset()`, rebuilt
    /// lazily in `topWords()`. Without this, every keystroke re-sorted the full
    /// 3000-entry dictionary (O(n log n)) even when nothing changed.
    private var cachedTopWords: [String]?
    private var cacheDirty = true

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pretype", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("personalization.json")
        if let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode([String: Int].self, from: data) {
            counts = stored
        }
    }

    /// Learn from text the user accepted. Cheap and called off the typing path.
    func record(_ text: String) {
        let words = Self.words(in: text)
        guard !words.isEmpty else { return }
        lock.lock()
        for word in words { counts[word, default: 0] += 1 }
        if counts.count > maxWords { trimLocked() }
        cacheDirty = true
        let snapshot = counts
        lock.unlock()
        persist(snapshot)
    }

    /// The most frequently accepted words, for logit biasing.
    func topWords(_ n: Int) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        if cacheDirty {
            cachedTopWords = counts.sorted { $0.value > $1.value }.map(\.key)
            cacheDirty = false
        }
        guard let cached = cachedTopWords else { return [] }
        return cached.count <= n ? cached : Array(cached.prefix(n))
    }

    var wordCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return counts.count
    }

    func reset() {
        lock.lock()
        counts = [:]
        cachedTopWords = nil
        cacheDirty = true
        lock.unlock()
        try? FileManager.default.removeItem(at: url)
    }

    private func trimLocked() {
        let kept = counts.sorted { $0.value > $1.value }.prefix(maxWords)
        counts = Dictionary(kept.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
    }

    private func persist(_ snapshot: [String: Int]) {
        let url = self.url
        queue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Lowercased letter-runs of length ≥ 3 (skips punctuation, short stop-words).
    static func words(in text: String) -> [String] {
        text.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 3 }
    }
}
