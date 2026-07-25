import Foundation

/// Shared fix-selection helpers: the prompt, token budget, output cleanup and
/// minimal-edit guard used by every engine's `correct(...)` path (MLX and
/// FoundationModels) plus the inline spell checker, so the post-processing
/// can't drift between them.
enum CorrectionGates {
    /// Shared prompt for the fix-selection feature. Emphasises MINIMAL edits so
    /// the model corrects mistakes instead of paraphrasing — a repeated failure
    /// mode of instruct models that rewrote the user's text wholesale. The
    /// caller appends the text via its own template.
    static let correctionDirective = """
    Correct only the real spelling, typo, capitalization and punctuation \
    mistakes in the text below. Keep every already-correct word exactly as \
    written — do NOT rephrase, reword, reorder, translate, change the style, or \
    otherwise "improve" it. Preserve the original meaning, language and \
    formatting. If there are no mistakes, return the text unchanged. Reply with \
    ONLY the corrected text — no quotes, no explanations.
    """

    /// A generous output-token budget for a correction: the fix is about the
    /// length of the input, but tokens run shorter than characters (≈2× denser
    /// for Russian), so budget the worst case to stop long selections clipping
    /// (the "doesn't fix the whole thing" bug). Capped so it can't run away.
    static func correctionTokenBudget(forChars count: Int) -> Int {
        min(512, max(64, count))
    }

    /// Normalize a raw correction generation into one clean line: trim, take the
    /// first non-empty line, and strip a wrapping quote pair the model may have
    /// added. Shared by both engines so the post-processing can't drift.
    static func cleanCorrectionOutput(_ raw: String) -> String {
        var fixed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        fixed = fixed.split(separator: "\n").first.map(String.init) ?? ""
        for (open, close) in [("\"", "\""), ("«", "»"), ("“", "”")] {
            if fixed.hasPrefix(open), fixed.hasSuffix(close), fixed.count > 2 {
                fixed = String(fixed.dropFirst().dropLast())
            }
        }
        return fixed.trimmingCharacters(in: .whitespaces)
    }

    /// Cut same-line run-on after the fix. 4-bit instruct models — E4B-it
    /// worst at 39% of eval-correct rows (2026-07-25) — finish the correction
    /// and keep generating junk on the same line without ever closing the
    /// turn ("fix.less than 100 words"), which the minimal-edit guard and the
    /// user's eyes both read as a mangled fix. The contract: if the ORIGINAL
    /// ends like a sentence, the fix must too — cut at the first
    /// sentence-terminal at/after the original's length neighborhood, keeping
    /// the whole trailing punctuation run ("...", "?!", closing quotes) so a
    /// multi-terminal ending survives intact. A dot between digits is a
    /// decimal (3.14), not a terminal. Quotes/apostrophes never START a cut
    /// (didn't, d'impôts — measured regressions when they did). Known cost: a
    /// late abbreviation dot can cut early ("…al Sr. González" — 1 row of
    /// 2040 across the 4-model eval).
    static func trimRunOn(_ fixed: String, original: String) -> String {
        let terminals: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
        let closers: Set<Character> = ["\"", "»", "”", "’", "'", ")", "」", "』", "）"]
        let trimmedOriginal = original.trimmingCharacters(in: .whitespaces)
        guard let last = trimmedOriginal.last,
              terminals.contains(last) || closers.contains(last) else { return fixed }
        let chars = Array(fixed)
        let slack = max(8, trimmedOriginal.count / 5)
        var i = max(4, trimmedOriginal.count - slack)
        while i < chars.count {
            if terminals.contains(chars[i]) {
                if chars[i] == ".", i > 0, i + 1 < chars.count,
                   chars[i - 1].isNumber, chars[i + 1].isNumber {
                    i += 1
                    continue
                }
                var j = i + 1
                while j < chars.count,
                      terminals.contains(chars[j]) || closers.contains(chars[j]) { j += 1 }
                return String(chars[0..<j])
            }
            i += 1
        }
        return fixed
    }

    /// True when `fixed` is a plausible *minimal* correction of `original`
    /// rather than a paraphrase/rewrite. A fix keeps most of the text; a rewrite
    /// changes it wholesale. Rejects a big length change or >50% of the
    /// (case-insensitive) characters changed, so the engine offers nothing
    /// instead of mangling the user's wording.
    static func isMinimalCorrection(original: String, fixed: String) -> Bool {
        let a = Array(original.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        let b = Array(fixed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        guard !b.isEmpty, !a.isEmpty else { return false }
        let lenA = a.count, lenB = b.count
        if lenB > lenA * 2 || lenB * 2 < lenA { return false }
        let distance = levenshtein(a, b)
        // A single transposition in a short word ("teh"→"the") is already 67% of
        // the characters, so allow more change on short strings; long selections
        // must stay close, where a high ratio means a paraphrase/rewrite.
        let threshold = lenA <= 12 ? 0.7 : 0.5
        return Double(distance) / Double(max(lenA, lenB)) <= threshold
    }

    /// Character-level edit distance (two-row DP; selections are ≤500 chars).
    private static func levenshtein(_ s: [Character], _ t: [Character]) -> Int {
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }
        var prev = Array(0...t.count)
        var curr = [Int](repeating: 0, count: t.count + 1)
        for i in 1...s.count {
            curr[0] = i
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[t.count]
    }
}
