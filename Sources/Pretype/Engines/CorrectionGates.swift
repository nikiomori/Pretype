import Foundation

/// Shared fix-selection helpers: the prompt, token budget, output cleanup and
/// minimal-edit guard behind every engine's fix, voice-command and reply
/// paths (MLX, FoundationModels, API) plus the inline spell checker, so the
/// post-processing can't drift between them.
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

    /// Voice command mode: a spoken instruction applied to the selected text
    /// ("make it more formal", "translate to English"). Unlike the fix, the
    /// rewrite is the point — no minimal-edit guard follows it.
    static func commandPrompt(instruction: String, text: String) -> String {
        """
        Rewrite the text below following this instruction: \(instruction)
        Keep the text's language unless the instruction asks for another one. \
        Reply with ONLY the rewritten text — no quotes, no explanations, no preamble.

        \(text)
        """
    }

    /// A command's output keeps its line breaks (a rewritten paragraph is
    /// still a paragraph); only surrounding whitespace and a wrapping quote
    /// pair go.
    static func cleanCommandOutput(_ raw: String) -> String {
        unquoted(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `text` without the wrapping quote pairs a model may add, checked in
    /// this order: "…", «…», “…”.
    private static func unquoted(_ text: String) -> String {
        var out = text
        for (open, close) in [("\"", "\""), ("«", "»"), ("“", "”")]
        where out.hasPrefix(open) && out.hasSuffix(close) && out.count > 2 {
            out = String(out.dropFirst().dropLast())
        }
        return out
    }

    /// An engine's one chat turn: a prompt and an output-token budget in, the
    /// raw answer out (nil = the engine declined).
    typealias Generate = (_ prompt: String, _ maxTokens: Int) async throws -> String?

    /// The ⌥⇥ fix on any engine: guard the selection, ask, clean the answer
    /// up, reject an over-rewrite. `redactLog` keeps the text out of the
    /// rejection line (see `CompletionEngine.correct`).
    static func fix(_ selection: String, redactLog: Bool, logTag: String,
                    generate: Generate) async throws -> String? {
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 500, !trimmed.contains("\n"),
              let raw = try await generate("\(correctionDirective)\n\n\(trimmed)",
                                           correctionTokenBudget(forChars: trimmed.count))
        else { return nil }
        // A cancelled request (focus moved on, overlay reset) must not
        // surface its late result.
        try Task.checkCancellation()
        let fixed = trimRunOn(cleanCorrectionOutput(raw), original: trimmed)
        guard !fixed.isEmpty, fixed != trimmed else { return nil }
        guard isMinimalCorrection(original: trimmed, fixed: fixed) else {
            DebugLog.shared.log(
                logTag, "fix rejected (over-rewrite)",
                detail: redactLog
                    ? "\(trimmed.count) → \(fixed.count) chars — redacted from log"
                    : "\"\(trimmed)\" → \"\(fixed)\"")
            return nil
        }
        return fixed
    }

    /// Voice command mode on any engine: `selection` rewritten the way the
    /// spoken `instruction` asks; nil when nothing new came back.
    static func rewrite(_ selection: String, instruction: String,
                        generate: Generate) async throws -> String? {
        let text = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        let spoken = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 2000, !spoken.isEmpty,
              let raw = try await generate(commandPrompt(instruction: spoken, text: text),
                                           min(1024, max(64, text.count)))
        else { return nil }
        try Task.checkCancellation()
        let result = cleanCommandOutput(raw)
        return result.isEmpty || result == text ? nil : result
    }

    /// The reply hotkey on any engine: the user's next message, written from
    /// the conversation on screen.
    static func reply(to conversation: String, request: CompletionRequest, instructions: String,
                      generate: Generate) async throws -> String? {
        // ponytail: flat 200-token budget — a few sentences, doubled for the
        // Cyrillic case rather than measured per script. Tighten if replies ever
        // read as clipped.
        guard let raw = try await generate(
            request.replyPrompt(conversation: conversation, instructions: instructions), 200) else { return nil }
        try Task.checkCancellation()
        return request.cleanReply(raw, conversation: conversation)
    }

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
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first ?? ""
        return unquoted(String(line)).trimmingCharacters(in: .whitespaces)
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
        let trimmedOriginal = original.trimmingCharacters(in: .whitespaces)
        guard let last = trimmedOriginal.last else { return fixed }
        guard terminals.contains(last) || closers.contains(last) else {
            return trimUnpunctuatedRunOn(fixed, original: trimmedOriginal)
        }
        let chars = Array(fixed)
        let slack = max(8, trimmedOriginal.count / 5)
        for i in stride(from: max(4, trimmedOriginal.count - slack), to: chars.count, by: 1) {
            if let end = endingRun(in: chars, at: i) { return String(chars[0..<end]) }
        }
        return fixed
    }

    private static let terminals: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
    private static let closers: Set<Character> = ["\"", "»", "”", "’", "'", ")", "」", "』", "）"]

    /// Where a sentence ending at `chars[i]` stops: past its whole run of
    /// terminals and closers. nil when `chars[i]` ends nothing — not a
    /// terminal, or a dot between digits (a decimal, 3.14).
    private static func endingRun(in chars: [Character], at i: Int) -> Int? {
        guard terminals.contains(chars[i]),
              !(chars[i] == "." && i > 0 && i + 1 < chars.count && chars[i - 1].isNumber && chars[i + 1].isNumber)
        else { return nil }
        var end = i + 1
        while end < chars.count, terminals.contains(chars[end]) || closers.contains(chars[end]) { end += 1 }
        return end
    }

    /// The run-on cut for an original that does NOT end like a sentence.
    ///
    /// This is the shape DICTATION always produces: the system dictation model
    /// writes no punctuation at all for Russian and most locales (measured
    /// 2026-07-26), which is most of what the tidy-up pass is for — so the
    /// contract above ("if the original ends like a sentence, the fix must
    /// too") has no ending to match and used to return the text untouched.
    /// That left the one path where a run-on is least visible completely
    /// unguarded: the junk lands at the end of a message the user is about to
    /// send, and the minimal-edit guard waves it through because a few stray
    /// characters on a hundred-character sentence is a rounding error. Reported
    /// from real use as "strange characters at the end — CJK, sometimes Latin",
    /// which is exactly what an instruct model generating past its answer emits.
    ///
    /// Without an ending to anchor on, LENGTH is the anchor: adding punctuation
    /// and case cannot grow the text by much. Past that budget the answer
    /// ended early — cut back to the last sentence-terminal inside it, or, when
    /// there is none, hand back the original so the caller keeps exactly what
    /// was heard. (A cut that lands too short is then rejected by
    /// `isMinimalCorrection`, so a fix mangled into a fragment never ships.)
    private static func trimUnpunctuatedRunOn(_ fixed: String, original: String) -> String {
        let budget = original.count + max(6, original.count / 8)
        let chars = Array(fixed)
        guard chars.count > budget else { return fixed }
        var cut: Int?
        var i = 0
        while i < min(budget, chars.count) {
            if let end = endingRun(in: chars, at: i) {
                cut = end
                i = end
            } else {
                i += 1
            }
        }
        guard let cut else { return original }
        return String(chars[0..<cut])
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
