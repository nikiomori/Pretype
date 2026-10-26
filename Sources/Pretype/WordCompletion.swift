import Foundation

/// Words mode: the rest of the word at the caret, with no model — a
/// personal word n-gram with a dictionary prior. The user's words from the journal (`PersonalNgram`) and the
/// system dictionary of the language being typed both vote for a word.
///
/// What makes it quiet is the share rule: a word shows only when it holds a
/// clear share of the votes for everything typed from those letters — the
/// letters as a finished word included, so "the" never grows a "re".
///
/// Tuned to offer a word nearly every time one is being typed — a wrong
/// one costs a glance. On a replay of a real journal (2026-10-27,
/// learned on its first half, measured on the other 12,479 words): a ghost
/// on 83 words in 100, 37 of them taken, 19.6% of keystrokes saved at 46
/// wrong words per 100 — where the n-gram fast path's rule (`completeWord`)
/// shows 25, saves 6.3% at 14.5 wrong. A one-letter ending is worth its Tab
/// (it brings its space): +2.4 pp. Counting a word's cases as one and the
/// dictionary voting in the language the keyboard types made the rest.
enum WordCompletion {
    struct Tuning {
        /// The best word's share of the votes.
        var threshold = 0.25
        /// The best word's votes: one sighting with nothing before it is no
        /// habit yet.
        var minCount = 2
        /// A word typed after the same previous word counts this much more.
        var boost = 80
        /// Characters the word must still add.
        var minAdded = 1
        /// Letters typed before the dictionary votes.
        var dictionaryMinPrefix = 3
        /// The dictionary's vote: for its likeliest word — or, when the letters
        /// already spell a word, for stopping there.
        var dictionaryVote = 4
    }

    /// The rest of the word, or nil. `isWord` and `dictionary` are the system
    /// spell-checker's (main thread); tests and the replay pass their own.
    @MainActor
    static func suggestion(text: String, after: String, ngram: PersonalNgram,
                           tuning: Tuning = Tuning(),
                           isWord: (String) -> Bool = SpellChecker.isTypedWord,
                           dictionary: (String) -> [String] = SpellChecker.completions) -> String? {
        guard text.last?.isLetter == true, !RequestGate.caretSplitsWord(before: after),
              isProse(token: CorrectionController.lastToken(of: text), line: currentLine(of: text)) else { return nil }
        let prefix = SpellChecker.trailingWord(of: text)
        guard prefix.count >= 2, prefix.first?.isLetter == true else { return nil }
        let previous = PersonalNgram.words(String(text.dropLast(prefix.count).suffix(80))).last

        // One word whatever its case — "Посмотри" and "посмотри" are one
        // habit — spelled as it was typed most.
        let folded = PersonalNgram.fold(prefix)
        var votes: [String: (word: String, count: Int, seen: Int)] = [:]
        func vote(_ word: String, _ count: Int) {
            let key = PersonalNgram.fold(word)
            guard count > 0, key.hasPrefix(folded) else { return }
            let kept = votes[key] ?? (word, 0, 0)
            votes[key] = (count > kept.seen ? word : kept.word, kept.count + count, max(kept.seen, count))
        }
        for (word, count) in ngram.words(startingWith: prefix, after: previous, boost: tuning.boost) {
            vote(word, count)
        }
        if prefix.count >= tuning.dictionaryMinPrefix {
            if isWord(prefix) {
                vote(prefix, tuning.dictionaryVote)
            } else if let likeliest = dictionary(prefix).first {
                vote(likeliest, tuning.dictionaryVote)
            }
        }

        let total = votes.values.reduce(0) { $0 + $1.count }
        // A tie goes to the word first in the alphabet: the same letters
        // always grow the same ghost.
        guard let best = votes.values.max(by: { $0.count != $1.count ? $0.count < $1.count : $0.word > $1.word }),
              best.count >= tuning.minCount,
              Double(best.count) / Double(total) >= tuning.threshold else { return nil }
        return remainder(of: best.word, after: prefix, minAdded: tuning.minAdded)
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
