import Foundation
import NaturalLanguage

/// Shared output gates for completion suggestions. Both engines (MLX and
/// FoundationModels) funnel a raw generation through `postProcess` so the
/// accept/reject and trimming rules can't drift between them.
enum CompletionGates {
    /// Output gates, in order: first line → control-character safety →
    /// echo-of-prefix stripping → trailing-text duplication → sentence-end
    /// trim → separator-space bookkeeping. A rejected suggestion returns nil
    /// (no suggestion beats a bad one).
    static func postProcess(
        _ raw: String, prompt: String, trailingSpaces: Int,
        endsMidWord: Bool, endsCompleteWord: Bool = false,
        textAfterCaret: String, singleWord: Bool = false
    ) -> String? {
        func reject(_ reason: String) -> String? {
            DebugLog.shared.log("GATE", "rejected: \(reason)", detail: "raw: \(raw.debugDescription)")
            return nil
        }

        var content = raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""

        // Lossy detokenization or stray control characters must never be typed.
        guard !content.contains("\u{FFFD}"),
              !content.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { return reject("control characters / U+FFFD") }

        // The model must never emit our own prompt scaffolding.
        let lowered = content.trimmingCharacters(in: .whitespaces).lowercased()
        if lowered.hasPrefix("nearby on screen") { return reject("prompt scaffolding echo") }

        // A CJK suggestion for a non-CJK prompt is a derailed generation.
        if containsCJK(content), !containsCJK(String(prompt.suffix(200))) {
            return reject("CJK output for non-CJK prompt")
        }

        // Same for any confidently-detected language flip (ru → tr, etc.).
        if languageMismatch(prompt: prompt, suggestion: content) {
            return reject("language flip vs prompt")
        }

        // Degenerate repetition ("мюююююююю") survives a mild penalty.
        if hasDegenerateRun(content) {
            return reject("degenerate character repetition")
        }

        // Models sometimes re-emit the tail of what is already typed.
        guard let deEchoed = stripEcho(of: prompt, from: content) else {
            return reject("fully echoes already-typed text")
        }
        content = deEchoed

        if trailingSpaces > 0 {
            // The user already typed the separator. A continuation that glues
            // onto the previous word ("to" + "morrow") would corrupt the text.
            guard content.hasPrefix(" ") else {
                return reject("would glue onto the previous word (no separator)")
            }
            while content.hasPrefix(" ") {
                content.removeFirst()
            }
        } else if endsMidWord, content.hasPrefix(" ") {
            // The caret sits right after a run of letters with no separator, and
            // the model wants to begin a NEW word (leading space). Two cases:
            //   • the run is already a complete word ("привет|"): this is exactly
            //     the space + next word the user would type next — keep the
            //     leading space so the suggestion carries the separator they
            //     haven't typed yet.
            //   • it's a partial word ("прив|"): a space would strand it — abstain.
            guard endsCompleteWord else {
                return reject("starts a new word at a mid-word caret")
            }
        }

        // Don't suggest what is already written after the caret.
        let after = textAfterCaret.trimmingCharacters(in: .whitespaces)
        if after.count >= 3 {
            let head = content.trimmingCharacters(in: .whitespaces)
            if !head.isEmpty, after.lowercased().hasPrefix(String(head.prefix(24)).lowercased()) {
                return reject("duplicates the text after the caret")
            }
        }

        content = trimAtSentenceEnd(content)
        // Single-word mode: keep only the leading separator + first word.
        if singleWord {
            content = firstWord(of: content)
        }
        if content.trimmingCharacters(in: .whitespaces).isEmpty {
            return reject("empty after trimming")
        }
        return content
    }

    /// Leading whitespace plus the first run of non-space characters (e.g.
    /// " tomorrow" from " tomorrow at noon"). Punctuation stays attached.
    private static func firstWord(of text: String) -> String {
        var result = ""
        var seenNonSpace = false
        for ch in text {
            if ch == " " {
                if seenNonSpace { break }
            } else {
                seenNonSpace = true
            }
            result.append(ch)
        }
        return result
    }

    /// Word-by-word overlap between the prompt tail and the suggestion head:
    /// strips the duplicated words, rejects fully-echoed suggestions.
    private static func stripEcho(of prompt: String, from suggestion: String) -> String? {
        let body = String(suggestion.drop(while: { $0 == " " }))
        guard !body.isEmpty else { return suggestion }
        let tailWords = prompt.suffix(200).split(separator: " ").suffix(15).map { $0.lowercased() }
        guard !tailWords.isEmpty else { return suggestion }
        let bodyWords = body.split(separator: " ", omittingEmptySubsequences: false)
        let bodyLower = bodyWords.map { $0.lowercased() }

        var overlap = 0
        for candidate in stride(from: min(tailWords.count, bodyLower.count), through: 1, by: -1) {
            if Array(tailWords.suffix(candidate)) == Array(bodyLower.prefix(candidate)) {
                overlap = candidate
                break
            }
        }
        guard overlap > 0 else { return suggestion }
        let remaining = bodyWords.dropFirst(overlap).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        // The echoed words ended at a word boundary, so the continuation
        // needs its separator back.
        return remaining.isEmpty ? nil : " " + remaining
    }

    /// True when both the prompt tail and the suggestion have a confident
    /// dominant language and they differ — a derailed generation marker.
    /// Runs inside the `@Sendable` output gate on the generation thread, so the
    /// shared recognizer is guarded by `languageLock`. Reusing one instance
    /// avoids allocating + initializing a new recognizer (and its backing ML
    /// model) on every token during streaming.
    private static let languageLock = NSLock()
    private static let languageRecognizer = NLLanguageRecognizer()
    /// `dominantLanguage` is deterministic per input, and the streaming gate calls
    /// it on every decode token with the SAME prompt (constant across a generation)
    /// plus repeated suggestion snapshots. Memoizing by exact string turns the
    /// per-token NL inference into a dictionary lookup — the prompt is computed once
    /// and repeated snapshots hit the cache. Bounded; flushed wholesale when it fills.
    private static var languageMemo: [String: String?] = [:]

    private static func languageMismatch(prompt: String, suggestion: String) -> Bool {
        guard suggestion.count >= 12 else { return false }
        guard let promptLanguage = dominantLanguage(String(prompt.suffix(160))),
              let suggestionLanguage = dominantLanguage(suggestion) else { return false }
        return promptLanguage != suggestionLanguage
    }

    private static func dominantLanguage(_ text: String) -> String? {
        languageLock.lock()
        defer { languageLock.unlock() }
        if let cached = languageMemo[text] { return cached }
        languageRecognizer.reset()
        languageRecognizer.processString(text)
        let result: String? = languageRecognizer.dominantLanguage.flatMap { language in
            (languageRecognizer.languageHypotheses(withMaximum: 1)[language] ?? 0) > 0.7
                ? language.rawValue : nil
        }
        if languageMemo.count >= 64 { languageMemo.removeAll(keepingCapacity: true) }
        languageMemo[text] = result
        return result
    }

    /// Four or more identical consecutive letters is never legitimate prose.
    private static func hasDegenerateRun(_ text: String) -> Bool {
        var run = 1
        var previous: Character?
        for ch in text {
            if ch == previous, ch.isLetter {
                run += 1
                if run >= 4 { return true }
            } else {
                run = 1
            }
            previous = ch
        }
        return false
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let v = scalar.value
            return (0x3040...0x30FF).contains(v)    // hiragana, katakana
                || (0x3400...0x4DBF).contains(v)    // CJK ext. A
                || (0x4E00...0x9FFF).contains(v)    // CJK ideographs
                || (0xAC00...0xD7AF).contains(v)    // hangul
                || (0x20000...0x2FA1F).contains(v)  // CJK ext. B–F (e.g. 𨐈)
        }
    }

    /// Cuts a suggestion after the first sentence boundary — long completions
    /// drift, and short precise ones win trust.
    private static func trimAtSentenceEnd(_ text: String, minChars: Int = 2) -> String {
        let enders: Set<Character> = [".", "!", "?", "…"]
        var count = 0
        var index = text.startIndex
        while index < text.endIndex {
            count += 1
            if count >= minChars, enders.contains(text[index]) {
                let next = text.index(after: index)
                if next == text.endIndex || text[next] == " " {
                    return String(text[..<next])
                }
            }
            index = text.index(after: index)
        }
        return text
    }
}
