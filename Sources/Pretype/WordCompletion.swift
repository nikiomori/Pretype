import Foundation

/// Words mode: the rest of the word at the caret, with no model — a
/// personal word n-gram with a dictionary prior. The user's words from the journal (`PersonalNgram`) answer
/// first; the system dictionary covers a word they never typed.
///
/// What makes it quiet is the share rule: a word shows only when it holds a
/// clear share of everything typed from those letters — the letters as a
/// finished word included, so "the" never grows a "re".
///
/// Tuned on a replay of a real journal (2026-10-27: 7,181 typed chunks,
/// learned on the first half, measured on the other 12,474 words). A share
/// of 0.15 saved 16% of keystrokes but showed 35 wrong words per 100;
/// a majority share and a strong previous-word context save 13.6% at 10.9
/// wrong — where the n-gram fast path's rule (`completeWord`) saved 6.3% at
/// 14.5 wrong. The dictionary adds 0.7 pp for ~4 wrong per 100 words.
enum WordCompletion {
    struct Tuning {
        /// The best word's share of the words typed from the prefix.
        var threshold = 0.6
        /// The best word's weight, its boost included: one sighting with
        /// nothing before it is no habit yet.
        var minCount = 2
        /// A word typed after the same previous word counts this much more.
        var boost = 80
        /// Characters the word must still add: one is no saving.
        var minAdded = 2
        /// Letters typed before the dictionary may answer.
        var dictionaryMinPrefix = 4
    }

    /// The rest of the word, or nil. `isWord` and `dictionary` are the system
    /// spell-checker's (main thread); tests and the replay pass their own.
    @MainActor
    static func suggestion(text: String, after: String, ngram: PersonalNgram,
                           tuning: Tuning = Tuning(),
                           isWord: (String, String) -> Bool = SpellChecker.isCompleteWord,
                           dictionary: (String, String) -> [String] = SpellChecker.completions) -> String? {
        guard text.last?.isLetter == true, !RequestGate.caretSplitsWord(before: after),
              isProse(token: CorrectionController.lastToken(of: text), line: currentLine(of: text)) else { return nil }
        let prefix = SpellChecker.trailingWord(of: text)
        guard prefix.count >= 2, prefix.first?.isLetter == true else { return nil }
        let previous = PersonalNgram.words(String(text.dropLast(prefix.count).suffix(80))).last

        let typed = ngram.words(startingWith: prefix, after: previous, boost: tuning.boost)
        if !typed.isEmpty {
            let total = typed.reduce(0) { $0 + $1.count }
            // A tie goes to the word first in the alphabet: the same letters
            // always grow the same ghost.
            guard let best = typed.max(by: { $0.count != $1.count ? $0.count < $1.count : $0.word > $1.word }),
                  best.count >= tuning.minCount,
                  Double(best.count) / Double(total) >= tuning.threshold else { return nil }
            return remainder(of: best.word, after: prefix, minAdded: tuning.minAdded)
        }
        // Never typed from these letters: the dictionary's likeliest word,
        // unless the letters already spell one.
        guard prefix.count >= tuning.dictionaryMinPrefix, !isWord(prefix, text) else { return nil }
        let folded = PersonalNgram.fold(prefix)
        guard let word = dictionary(prefix, text).first(where: { PersonalNgram.fold($0).hasPrefix(folded) })
        else { return nil }
        return remainder(of: word, after: prefix, minAdded: tuning.minAdded)
    }

    /// No guesses in code: identifiers, paths, addresses, numbers, or a
    /// line that is a slash command.
    static func isProse(token: String, line: String) -> Bool {
        if line.drop(while: \.isWhitespace).hasPrefix("/") { return false }
        if token.contains(where: { "\\/@_=:{}[]<>#$%^&*|~`".contains($0) || $0.isNumber }) { return false }
        // camelCase: a capital after a lowercase letter.
        return !zip(token, token.dropFirst()).contains { $0.isLowercase && $1.isUppercase }
    }

    private static func currentLine(of text: String) -> String {
        String(text.reversed().prefix { !$0.isNewline }.reversed())
    }

    private static func remainder(of word: String, after prefix: String, minAdded: Int) -> String? {
        guard word.count >= prefix.count + minAdded else { return nil }
        return String(word.dropFirst(prefix.count))
    }
}
