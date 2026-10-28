import AppKit
import NaturalLanguage

/// System spell-check (NSSpellChecker) for the Cotypist-style inline typo fix —
/// local, instant, multilingual (RU + EN, etc.). Fast enough to run per keystroke on
/// the word at the caret; the LLM is reserved for the explicit ⌥⇥ fix.
enum SpellChecker {
    /// Every call passes its language explicitly, so the checker's own
    /// language detection never comes into play.
    private static let checker = NSSpellChecker.shared

    /// Reused across calls — NLLanguageRecognizer is expensive to create
    /// (backed by a Core ML model) and `language(for:context:)` runs on every
    /// keystroke. Guarded by `recognizerLock` since it may be called from
    /// the main thread (correction preview) and background (eval harness).
    private static let recognizerLock = NSLock()
    private static let languageRecognizer = NLLanguageRecognizer()
    /// The last sample and its verdict (guarded by `recognizerLock`). One
    /// keystroke asks about the same text 3–5 times — the request, the
    /// n-gram fast path, the spell-fix, the gates — at ~0.8 ms a recognizer
    /// run, and `TypedLanguage` counted that one keystroke as many.
    private static var lastSample = ""
    private static var lastLanguageCode: String?
    /// Every language the recognizer gave that sample, with its probability.
    private static var lastHypotheses: [String: Double] = [:]
    /// Installed spell-check dictionaries: read once — a list walked per
    /// call, and one added mid-session is picked up after a relaunch.
    private static let availableLanguages = NSSpellChecker.shared.availableLanguages

    /// The best correction for `word` if it is a misspelling, else nil. Returns
    /// only a *close* fix (the shared divergence guard rejects a different word),
    /// so a real typo is corrected but a valid-but-unknown word is left alone.
    static func correction(for word: String, context: String) -> String? {
        guard word.count >= 3, word.count <= 40, word.allSatisfy(\.isWordChar) else { return nil }

        let language = self.language(for: word, context: context)
        // Is it actually misspelled?
        guard !spelled(word, language: language) else { return nil }
        // …or only foreign to the dictionary that won: right in another of
        // the user's languages that the text plausibly is in is no typo. Only
        // theirs: on "I saw teh" Indonesian is plausible, and "teh" is tea there.
        if plausibleLanguages(of: context).contains(where: { $0 != language && spelled(word, language: $0) }) {
            return nil
        }
        let range = NSRange(location: 0, length: (word as NSString).length)

        // If the text is still a valid prefix of real words, the user is probably
        // mid-typing one — don't nag with a correction yet (e.g. "recei" is on
        // the way to "receive"; only "recieve" with no completions is a typo).
        if let completions = checker.completions(
            forPartialWordRange: range, in: word, language: language, inSpellDocumentWithTag: 0
        ), !completions.isEmpty {
            return nil
        }

        // Prefer the conservative autocorrection; fall back to the top guess
        // (autocorrect abstains on many Russian typos that `guesses` still nails,
        // e.g. "сабака" → correction nil but guesses ["собака", …]).
        let candidate = checker.correction(
            forWordRange: range, in: word, language: language, inSpellDocumentWithTag: 0
        ) ?? checker.guesses(
            forWordRange: range, in: word, language: language, inSpellDocumentWithTag: 0
        )?.first

        guard let fix = candidate,
              fix.caseInsensitiveCompare(word) != .orderedSame,
              CorrectionGates.isMinimalCorrection(original: word, fixed: fix)
        else { return nil }
        return fix
    }

    /// The dictionary's words that start with `partial`, likeliest first, in
    /// the language it is being typed in (`typingLanguage`). Main-thread only.
    static func completions(of partial: String) -> [String] {
        guard partial.count >= 2, partial.count <= 40, partial.allSatisfy(\.isWordChar) else { return [] }
        let range = NSRange(location: 0, length: (partial as NSString).length)
        return checker.completions(forPartialWordRange: range, in: partial, language: typingLanguage(for: partial),
                                   inSpellDocumentWithTag: 0) ?? []
    }

    /// `word` spells a whole word in the language it is being typed in.
    static func isTypedWord(_ word: String) -> Bool {
        spelled(word, language: typingLanguage(for: word))
    }

    /// The dictionary for a word being typed: an enabled keyboard's language
    /// that writes in the word's alphabet — Russian for "завт" on a Russian
    /// and English Mac — else the alphabet's own. Not the recognizer: on a
    /// few words of context it named Bulgarian for "завт" and Czech for
    /// "chec", and their dictionaries completed them into nonsense. Two
    /// keyboards on one alphabet (English and Danish) are told apart by the
    /// language the user has been typing (`TypedLanguage`), else the first.
    static func typingLanguage(for word: String) -> String {
        let cyrillic = isCyrillic(word)
        let candidates = keyboardLanguages.filter { cyrillicLanguages.contains($0) == cyrillic }
        for keyboard in typingOrder(candidates, typed: TypedLanguage.dominant) {
            if let match = availableLanguages.first(where: { $0.lowercased().hasPrefix(keyboard) }) { return match }
        }
        return scriptLanguage(word)
    }

    /// `keyboards` with the one the user has been typing in first.
    static func typingOrder(_ keyboards: [String], typed: String?) -> [String] {
        guard let typed, let i = keyboards.firstIndex(where: { typed.hasPrefix($0) }) else { return keyboards }
        return [keyboards[i]] + keyboards.enumerated().filter { $0.offset != i }.map(\.element)
    }

    /// Enabled keyboard layouts' languages, read once: they rarely change
    /// while Pretype runs, and the list is walked on every keystroke.
    private static let keyboardLanguages = Settings.keyboardLanguages().map { $0.lowercased() }
    private static let cyrillicLanguages: Set<String> = ["ru", "uk", "be", "bg", "sr", "mk", "kk", "ky", "mn", "tg", "tt", "ba"]

    private static func isCyrillic(_ word: String) -> Bool {
        word.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
    }

    /// True when `text` ends right after a complete, correctly-spelled word
    /// (not a partial prefix still being typed). The caret then sits at a real
    /// word boundary, so a new-word (space-led) suggestion — the separator the
    /// user would type next — is safe; mid-prefix it would strand the word.
    /// `after` is the text just past the caret: a letter there means the caret
    /// is *inside* a word ("прив|ет"), so it's never a boundary.
    static func endsOnCompleteWord(before: String, after: String) -> Bool {
        if after.first?.isLetter == true { return false }
        let word = trailingWord(of: before)
        return isCompleteWord(word, context: before)
    }

    /// The run of word characters immediately before the caret — the partial
    /// word being typed — or "" when `text` ends on a non-letter.
    static func trailingWord(of text: String) -> String {
        String(text.reversed().prefix(while: \.isWordChar).reversed())
    }

    /// True when `word` is itself a complete, correctly-spelled word rather than
    /// a prefix on the way to a longer one. Single letters are treated as
    /// incomplete (too ambiguous: "я"/"I" are words but also word-starts), so a
    /// space is only ever offered after a real ≥2-letter word.
    static func isCompleteWord(_ word: String, context: String) -> Bool {
        spelled(word, language: language(for: word, context: context))
    }

    /// At a mid-word caret, the engines prepend a separator space to an instruct
    /// model's flush answer on the assumption it begins a NEW word — right after a
    /// finished word ("привет" → " как дела"), but wrong when the typed prefix is a
    /// complete word that is ALSO the start of a longer one ("при" → "привет"):
    /// there the model is finishing the current word, and the space strands the
    /// ending as "при вет". Detect that — the trailing word glued to the
    /// suggestion's first word is itself a real word — and drop the stray space so
    /// the ending attaches directly. Runs on the main thread (NSSpellChecker).
    static func strippingStraySeparator(suggestion: String, before: String) -> String {
        guard suggestion.hasPrefix(" "), before.last?.isLetter == true else { return suggestion }
        let partial = trailingWord(of: before)
        guard partial.count >= 2 else { return suggestion }
        let body = String(suggestion.drop { $0 == " " })
        let firstWord = String(body.prefix(while: \.isWordChar))
        guard !firstWord.isEmpty, isKnownWord(partial + firstWord) else { return suggestion }
        return body
    }

    /// Instruct models often capitalize the first word of their answer as if
    /// starting a fresh sentence. When the suggestion actually continues the
    /// current sentence (the text before the caret doesn't end on a sentence
    /// break), lowercase that leading capital — unless it's legitimately upper:
    /// the very start, an acronym, the English "I"/"I'm", or a proper noun (kept
    /// because lowercasing it would spell-check as wrong). Main-thread only.
    static func decapitalizeContinuation(_ suggestion: String, before: String) -> String {
        guard let letterIndex = suggestion.firstIndex(where: { $0.isLetter }),
              suggestion[letterIndex].isUppercase else { return suggestion }
        // A capital is correct at the very start or after a sentence terminator.
        guard let prev = before.last(where: { $0 != " " }), !".!?…\n\r".contains(prev) else {
            return suggestion
        }
        let firstChar = suggestion[letterIndex]
        let word = String(suggestion[letterIndex...].prefix(while: \.isWordChar))
        // Leave acronyms and the English first-person pronoun alone.
        if word.count >= 2, word == word.uppercased() { return suggestion }
        if word == "I" || word.hasPrefix("I'") || word.hasPrefix("I’") { return suggestion }
        let lowered = firstChar.lowercased()
        // Multi-letter words: keep the capital if lowercasing yields a misspelling
        // (a proper noun like "Москву"); single letters (Russian "Я" → "я") just drop.
        if word.count >= 2, !isKnownWord(lowered + String(word.dropFirst())) {
            return suggestion
        }
        var result = suggestion
        result.replaceSubrange(letterIndex..<suggestion.index(after: letterIndex), with: lowered)
        return result
    }

    /// Spell-correctness using a dictionary chosen by the WORD's own script
    /// (Cyrillic → Russian, else English), not the surrounding context. The
    /// `NLLanguageRecognizer` confidently mislabels short Cyrillic text — "я хочу "
    /// reads as Ukrainian, where a perfectly good Russian word ("поехать") spells
    /// as wrong — so the continuation normalizers judge the word against its own
    /// script, where it's unambiguous. Main-thread only (NSSpellChecker).
    private static func isKnownWord(_ word: String) -> Bool {
        spelled(word, language: scriptLanguage(word))
    }

    /// A correctly-spelled ≥2-letter word yields no misspelling range. Pass the
    /// language explicitly — the language-less check waves Cyrillic through (it
    /// looks fine to the English dictionary), which would call every prefix
    /// complete. `language` is only evaluated for a word that passes the shape
    /// guard, so the recognizer never runs on an empty trailing word.
    private static func spelled(_ word: String, language: @autoclosure () -> String) -> Bool {
        guard word.count >= 2, word.count <= 40, word.allSatisfy(\.isWordChar) else { return false }
        let misspelled = checker.checkSpelling(
            of: word, startingAt: 0, language: language(), wrap: false,
            inSpellDocumentWithTag: 0, wordCount: nil
        )
        return misspelled.location == NSNotFound
    }

    /// The available spell-check language for the word's own script:
    /// Cyrillic → a Russian variant, anything else → English.
    private static func scriptLanguage(_ word: String) -> String {
        let want = isCyrillic(word) ? "ru" : "en"
        return availableLanguages.first { $0.lowercased().hasPrefix(want) } ?? want
    }

    /// Pick a concrete available spell-check language by the word's script and surrounding context:
    /// NaturalLanguage recognizer is run on the preceding context if present.
    /// Otherwise, Cyrillic → a Russian variant, English/other language fallback (checking the word itself).
    private static func language(for word: String, context: String) -> String {
        // 1. Try to recognize language from the context using NLLanguageRecognizer
        if !context.isEmpty {
            let (langCode, hypotheses, fresh) = recognized(context)
            if let langCode {
                // The one place the app already knows what language is being
                // typed. Recorded here rather than re-detected elsewhere: this
                // runs on the typing path anyway, and a second recognizer would
                // be a second Core ML model for an answer we already have.
                if fresh { TypedLanguage.observe(langCode) }
                let pick = dictionaryLanguage(recognized: langCode, hypotheses: hypotheses,
                                              keyboards: usersLanguages)
                // Find if the spellchecker supports this language
                if let matched = availableLanguages.first(where: {
                    $0.lowercased().hasPrefix(pick.lowercased())
                }) {
                    return matched
                }
            }
        }

        // 2. Fallback to Cyrillic / English check based on the word itself
        return scriptLanguage(word)
    }

    /// The recognizer's verdict on the context's last 150 characters, once
    /// per sample: its language, every hypothesis, and whether it is new.
    private static func recognized(_ context: String) -> (String?, [String: Double], Bool) {
        recognizerLock.lock()
        defer { recognizerLock.unlock() }
        let sample = String(context.suffix(150))
        if sample == lastSample { return (lastLanguageCode, lastHypotheses, false) }
        languageRecognizer.reset()
        languageRecognizer.processString(sample)
        lastSample = sample
        lastLanguageCode = languageRecognizer.dominantLanguage?.rawValue
        lastHypotheses = Dictionary(uniqueKeysWithValues: languageRecognizer.languageHypotheses(withMaximum: 10)
            .map { ($0.key.rawValue, $0.value) })
        return (lastLanguageCode, lastHypotheses, true)
    }

    /// The dictionary language for text the recognizer called `recognized`:
    /// one of the user's languages (`usersLanguages`) it also finds plausible
    /// (≥ 0.05) beats its pick from outside them. On a few words it reads
    /// Danish as Norwegian or Swedish — 22% of Danish lines with a typo went
    /// to the Norwegian dictionary, which "fixed" Danish into Norwegian ("Hvad"
    /// → "Vad"); with the keyboard's language first, 44% of the typos come back
    /// right instead of 40%, false fixes on correct text 14 instead of 20
    /// (Swedish 60 vs 56%, English 74 vs 71%; Eval/runs-2026-10-28-issue4/spell).
    static func dictionaryLanguage(recognized: String, hypotheses: [String: Double],
                                   keyboards: [String]) -> String {
        func onKeyboard(_ code: String) -> Bool { keyboards.contains { code.lowercased().hasPrefix($0) } }
        guard !onKeyboard(recognized) else { return recognized }
        return hypotheses.filter { onKeyboard($0.key) && $0.value >= 0.05 }
            .max { $0.value < $1.value }?.key ?? recognized
    }

    /// Dictionaries for the user's languages the context plausibly is in (≥ 0.1).
    private static func plausibleLanguages(of context: String) -> [String] {
        guard !context.isEmpty else { return [] }
        let mine = usersLanguages
        return recognized(context).1
            .filter { hypothesis in hypothesis.value >= 0.1 && mine.contains { hypothesis.key.lowercased().hasPrefix($0) } }
            .keys.compactMap { code in availableLanguages.first { $0.lowercased().hasPrefix(code.lowercased()) } }
    }

    /// The languages this user writes: the keyboards, and the one they have
    /// been typing (a Danish writer on an English layout has no Danish keyboard).
    private static var usersLanguages: [String] {
        keyboardLanguages + [TypedLanguage.dominant].compactMap { $0 }
    }
}

extension Character {
    /// A letter or an in-word apostrophe/hyphen ("don't", "по-русски") — what
    /// the spell-fix, the mid-word glue guard and the n-gram all count as a word.
    var isWordChar: Bool { isLetter || self == "'" || self == "’" || self == "-" }
}
