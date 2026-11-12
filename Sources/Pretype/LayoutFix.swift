import Carbon

/// A word typed on the wrong keyboard layout ("ghbdtn" for "привет"), read
/// back key by key on another enabled layout. Offered only when that reading
/// is a dictionary word and the typed one is not.
enum LayoutFix {
    /// One keyboard layout: the character each key gives, plain and with ⇧.
    struct Layout: Equatable {
        /// The input source to select (`select`); "" in tests.
        var id = ""
        /// Its first language ("ru"): the dictionary its words are checked in.
        var language: String
        /// `key(code, shift)` → the character typed.
        var characters: [Int: Character]

        static func key(_ code: Int, shift: Bool) -> Int { code * 2 + (shift ? 1 : 0) }

        /// A layout from its three letter rows, top to bottom, as typed
        /// without ⇧ — what tests and `adjacent` see of a keyboard.
        init(language: String, rows: [String]) {
            self.language = language
            characters = [:]
            for (codes, row) in zip(LayoutFix.rows, rows) {
                for (code, character) in zip(codes, row) {
                    characters[Self.key(code, shift: false)] = character
                    characters[Self.key(code, shift: true)] = Character(character.uppercased())
                }
            }
        }

        init(id: String, language: String, characters: [Int: Character]) {
            (self.id, self.language, self.characters) = (id, language, characters)
        }

        /// The plain key first: a mark is on its key with ⇧ too on some layouts.
        func key(of character: Character) -> Int? {
            characters.filter { $0.value == character }.keys.min { ($0 % 2, $0) < ($1 % 2, $1) }
        }
    }

    /// Key codes of the three letter rows of an ANSI keyboard, left to right.
    static let rows: [[Int]] = [
        [12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30],
        [0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39],
        [6, 7, 8, 9, 11, 45, 46, 43, 47, 44],
    ]

    /// The enabled layouts, read once: they rarely change while Pretype runs.
    /// Tests put their own in.
    static var layouts: [Layout] = enabledLayouts() { didSet { last = nil } }

    private static func enabledLayouts() -> [Layout] {
        guard let sources = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else { return [] }
        return sources.compactMap { source in
            guard let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData),
                  let idPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID),
                  let languages = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages),
                  let language = (Unmanaged<CFArray>.fromOpaque(languages).takeUnretainedValue() as? [String])?.first
            else { return nil }
            let layout = Unmanaged<CFData>.fromOpaque(data).takeUnretainedValue() as Data
            var characters: [Int: Character] = [:]
            layout.withUnsafeBytes { bytes in
                guard let pointer = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return }
                for code in rows.joined() {
                    for shift in [false, true] {
                        var dead: UInt32 = 0
                        var length = 0
                        var units = [UniChar](repeating: 0, count: 4)
                        let status = UCKeyTranslate(pointer, UInt16(code), UInt16(kUCKeyActionDown),
                                                    shift ? UInt32(shiftKey >> 8) : 0, UInt32(LMGetKbdType()),
                                                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &units)
                        if status == noErr, length == 1, let scalar = Unicode.Scalar(units[0]) {
                            characters[Layout.key(code, shift: shift)] = Character(scalar)
                        }
                    }
                }
            }
            let id = Unmanaged<CFString>.fromOpaque(idPointer).takeUnretainedValue() as String
            return characters.isEmpty ? nil : Layout(id: id, language: language.lowercased(), characters: characters)
        }
    }

    /// Two of the enabled layouts type different alphabets (Latin and
    /// Cyrillic, Greek, Hebrew…): there a word on the wrong one is plain
    /// nonsense, and the fix is on by default. Two Latin layouts differ by a
    /// few keys ("zellow"), which a typo does as often.
    static var hasTwoAlphabets: Bool {
        Set(layouts.compactMap { $0.characters[Layout.key(12, shift: false)]?.isASCII }).count == 2
    }

    /// The last chunk asked about and its answer: one keystroke asks several
    /// times (the token, its kind, its fix).
    private static var last: (chunk: String, fix: (text: String, from: Layout, to: Layout)?)?

    /// `token` ("ghbdtn rf": a finished chunk and what was typed after it)
    /// as typed on the layout that makes its first chunk a word, or nil.
    /// Main-thread only.
    static func fix(token: String) -> String? {
        guard let space = token.firstIndex(of: " "), let found = found(String(token[..<space])) else { return nil }
        // What follows was typed on the same wrong layout.
        return found.text + String(token[space...].map { character in
            found.from.key(of: character).flatMap { found.to.characters[$0] } ?? character
        })
    }

    /// Select the layout `token`'s fix reads it on, so the next word is right.
    static func selectLayout(for token: String) {
        guard let id = found(String(token.prefix { $0 != " " }))?.to.id, !id.isEmpty,
              let sources = TISCreateInputSourceList([kTISPropertyInputSourceID: id] as CFDictionary, false)?
                .takeRetainedValue() as? [TISInputSource], let source = sources.first else { return }
        TISSelectInputSource(source)
    }

    private static func found(_ chunk: String) -> (text: String, from: Layout, to: Layout)? {
        guard Settings.fixTypos, Settings.fixLayout else { return nil }
        if let last, last.chunk == chunk { return last.fix }
        // An everyday word, not only one the dictionary holds: it also has
        // "tit" and "заде", which a typo reads as on the other layout.
        let fix = converted(chunk, layouts: layouts) { word, language in
            language.map { SpellChecker.isWord(word, in: $0) && SpellChecker.isOrdinaryWord(word.lowercased()) }
                ?? SpellChecker.isTypedWord(word)
        }
        last = (chunk, fix)
        return fix
    }

    /// `chunk` (no spaces) read on another of `layouts`, when that makes a
    /// word of 4+ letters, with what ended it, and `chunk` itself is none.
    /// `isWord(word, language)`: nil asks for the word's own alphabet.
    /// ponytail: three letters ("rfr" for "как") are as often an
    /// abbreviation or a typo that reads as a word on the other layout;
    /// they need the words around them, which this does not look at.
    static func converted(_ chunk: String, layouts: [Layout],
                          isWord: (String, String?) -> Bool) -> (text: String, from: Layout, to: Layout)? {
        guard (3...40).contains(chunk.count), !isWord(core(of: chunk), nil) else { return nil }
        for from in layouts {
            let keys = chunk.map(from.key(of:))
            guard !keys.contains(nil) else { continue }
            for to in layouts where to.language != from.language {
                let text = String(keys.compactMap { $0.flatMap { to.characters[$0] } })
                let word = core(of: text)
                guard text.count == chunk.count, text != chunk, word.count >= 4,
                      word.allSatisfy(\.isLetter), isWord(word, to.language) else { continue }
                return (text, from, to)
            }
        }
        return nil
    }

    /// `text` without the marks that end it.
    private static func core(of text: String) -> String {
        String(text.reversed().drop { ".,;:!?".contains($0) }.reversed())
    }

    /// `a` and `b` sit side by side in a row of an enabled layout: a finger
    /// that missed its key by one.
    static func adjacent(_ a: Character, _ b: Character) -> Bool { adjacent(a, b, layouts: layouts) }

    static func adjacent(_ a: Character, _ b: Character, layouts: [Layout]) -> Bool {
        layouts.contains { layout in
            guard let first = layout.key(of: a), let second = layout.key(of: b) else { return false }
            return rows.contains { row in
                guard let i = row.firstIndex(of: first / 2), let j = row.firstIndex(of: second / 2) else { return false }
                return abs(i - j) == 1
            }
        }
    }
}
