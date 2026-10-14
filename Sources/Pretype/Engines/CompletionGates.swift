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
        textAfterCaret: String, logRejects: Bool = true
    ) -> String? {
        func reject(_ reason: String) -> String? {
            if logRejects {
                DebugLog.shared.log("GATE", "rejected: \(reason)", detail: "raw: \(raw.debugDescription)")
            }
            return nil
        }

        var content = raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""

        // Lossy detokenization or stray control characters must never be typed.
        guard !content.contains("\u{FFFD}"),
              !content.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { return reject("control characters / U+FFFD") }

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
        if content.trimmingCharacters(in: .whitespaces).isEmpty {
            return reject("empty after trimming")
        }
        return content
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
        for candidate in stride(from: min(tailWords.count, bodyLower.count), through: 1, by: -1)
            where Array(tailWords.suffix(candidate)) == Array(bodyLower.prefix(candidate)) {
            overlap = candidate
            break
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

/// Shared prompt preparation for every completion path. Trims the trailing
/// spaces the user typed (a dangling space derails SentencePiece models into
/// a stray newline), enforces a per-path context floor, and records the
/// word-boundary state the output gate needs. nil — abstain — below the floor
/// or when nothing is left to encode.
struct PreparedPrompt {
    /// Context tail (user text + screen block) with trailing spaces removed —
    /// what the context floor, the output gate and the n-gram lookups see.
    /// Never contains the personal preamble: retrieved examples must not
    /// satisfy the floor, flip the language gate, or poison the n-gram
    /// context with words the user never typed here.
    let text: String
    /// What actually gets encoded: the personal-examples preamble (base
    /// path, when present), then `text`.
    let generationText: String
    /// How many trailing spaces the user typed (the gate restores the separator).
    let trailingSpaces: Int
    /// The caret sits right after a run of letters with no separator.
    let endsMidWord: Bool
    /// …and that run is a finished word — so a leading-space suggestion is the
    /// separator the user hasn't typed yet, not a stranded fragment.
    let endsCompleteWord: Bool
    let textAfterCaret: String

    /// `midWordFloor` applies when the caret is mid-word (a partial word is a
    /// strong constraint, so a lower floor is safe and surfaces word
    /// completions earlier); `boundaryFloor` at a word boundary. Screen
    /// context counts toward the threshold.
    init?(_ context: String, request: CompletionRequest,
          midWordFloor: Int, boundaryFloor: Int, preamble: String? = nil) {
        var text = context
        let floor = text.last?.isLetter == true ? midWordFloor : boundaryFloor
        guard text.count >= floor else {
            DebugLog.shared.log("GATE", "below context floor (\(text.count) chars < \(floor)) — not querying the model")
            return nil
        }
        var trailingSpaces = 0
        while text.hasSuffix(" ") {
            text.removeLast()
            trailingSpaces += 1
        }
        guard !text.isEmpty else { return nil }

        let after = request.textAfterCaret
        self.text = text
        generationText = preamble.map { "\($0)\n\n\(text)" } ?? text
        self.trailingSpaces = trailingSpaces
        endsMidWord = trailingSpaces == 0 && text.last?.isLetter == true
        endsCompleteWord = endsMidWord
            && (request.endsOnCompleteWord ?? SpellChecker.endsOnCompleteWord(before: text, after: after))
        textAfterCaret = after
    }

    /// The output gate for this prompt: run a raw decode snapshot (partial or
    /// final) through the shared `CompletionGates`. `cleanInstruct` first
    /// strips wrapping quotes and restores the separator instruct models
    /// answer without — base continuations bring their own separator.
    ///
    /// `logRejects: false` is for streamed partials: a stream gates every
    /// decoded token, and most early snapshots fail (a bare separator is
    /// "empty after trimming") — logged, each keystroke pushed several raw
    /// lines into the 400-entry ring. The final snapshot still logs.
    func gate(cleanInstruct: Bool, logRejects: Bool = true) -> @Sendable (String) -> String? {
        let text = self.text
        let trailing = trailingSpaces
        let endsMidWord = self.endsMidWord
        let endsCompleteWord = self.endsCompleteWord
        let after = textAfterCaret
        return { output in
            var raw = output
            if cleanInstruct {
                raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                for quote in ["\"", "“", "”"] {
                    if raw.hasPrefix(quote) { raw.removeFirst() }
                    if raw.hasSuffix(quote) { raw.removeLast() }
                }
                // Instruct models answer flush (no leading space). Restore the
                // separator the shared gate expects when the user already typed
                // it (trailing > 0) OR the caret sits right after a finished
                // word (the space they haven't typed yet), so the new word
                // doesn't glue onto the previous one.
                if trailing > 0 || endsCompleteWord, !raw.hasPrefix(" ") { raw = " " + raw }
            }
            return CompletionGates.postProcess(
                raw, prompt: text, trailingSpaces: trailing,
                endsMidWord: endsMidWord, endsCompleteWord: endsCompleteWord,
                textAfterCaret: after, logRejects: logRejects
            )
        }
    }
}
