import XCTest
@testable import Pretype

final class TextShapingTests: XCTestCase {
    func testTrailingWord() {
        XCTAssertEqual(SpellChecker.trailingWord(of: "hello world"), "world")
        XCTAssertEqual(SpellChecker.trailingWord(of: "hello world "), "")
        XCTAssertEqual(SpellChecker.trailingWord(of: "hello-world"), "hello-world")
        XCTAssertEqual(SpellChecker.trailingWord(of: "don't"), "don't")
        XCTAssertEqual(SpellChecker.trailingWord(of: "привет"), "привет")
    }

    func testFirstWordChunk() {
        XCTAssertEqual(SuggestionController.firstWordChunk(of: " hello world"), " hello")
        XCTAssertEqual(SuggestionController.firstWordChunk(of: "word"), "word")
        XCTAssertEqual(SuggestionController.firstWordChunk(of: "   multiple   words"), "   multiple")
    }

    func testKeystrokesRetypeOnlyTheTail() {
        let keys = FieldState.keystrokes
        XCTAssertTrue(keys("12*7=", "12*7=84") == ("", "84"))
        XCTAssertTrue(keys("teh", "the") == ("eh", "he"))
        XCTAssertTrue(keys(":smile:", "😄") == (":smile:", "😄"))
        XCTAssertTrue(keys("", "word") == ("", "word"))
        XCTAssertTrue(keys("word", "") == ("word", ""))
        // Whole graphemes: a base letter shared with an accented one is not a head.
        XCTAssertTrue(keys("cafe", "café") == ("e", "é"))
        XCTAssertTrue(keys("👨‍👩‍👧x", "👨‍👩‍👦x") == ("👨‍👩‍👧x", "👨‍👩‍👦x"))
    }

    func testGhostUpdate() {
        let update = FieldState.ghostUpdate
        // Typing the suggestion's head shrinks it.
        XCTAssertEqual(update("go", "ing to the store", "goi"), .narrowed("ng to the store"))
        XCTAssertEqual(update("", " привет мир", " "), .narrowed("привет мир"))
        // A keystroke narrows on its own characters: a Thai tone mark typed
        // after "ข" would merge into the anchor if appended to it.
        XCTAssertEqual(update("", "\u{E49}\u{E32}\u{E27}", "\u{E49}"), .narrowed("\u{E32}\u{E27}"))
        // A re-read with no text change keeps it.
        XCTAssertEqual(update("go", "ing", "go"), .unchanged)
        // A diverging character, or typing all of it, retires it.
        XCTAssertEqual(update("go", "ing to", "gox"), .retired(.diverged))
        XCTAssertEqual(update("go", "i", "goi"), .retired(.typedThrough))
        XCTAssertEqual(update("go", "ing", "goings"), .retired(.typedThrough))
        // The anchor itself changed (a backspace, a caret move): abandoned.
        XCTAssertEqual(update("go", "ing", "g"), .retired(.abandoned))
        XCTAssertEqual(update("go", "ing", "to"), .retired(.abandoned))
    }

    func testStrippingStraySeparator() {
        // Prefix is a complete word AND the start of a longer one: the model is
        // finishing the current word, so the stray separator must go.
        XCTAssertEqual(SpellChecker.strippingStraySeparator(suggestion: " вет", before: "при"), "вет")
        XCTAssertEqual(SpellChecker.strippingStraySeparator(suggestion: " ма", before: "до"), "ма")
        // Genuine next word after a finished word keeps its separator.
        XCTAssertEqual(
            SpellChecker.strippingStraySeparator(suggestion: " как дела", before: "привет"),
            " как дела"
        )
        // No leading space, or caret not mid-word: untouched.
        XCTAssertEqual(SpellChecker.strippingStraySeparator(suggestion: "вет", before: "при"), "вет")
        XCTAssertEqual(SpellChecker.strippingStraySeparator(suggestion: " вет", before: "при "), " вет")
    }

    func testDecapitalizeContinuation() {
        // Mid-sentence capital from the model gets lowered.
        XCTAssertEqual(SpellChecker.decapitalizeContinuation("Поехать домой", before: "я хочу "), "поехать домой")
        XCTAssertEqual(SpellChecker.decapitalizeContinuation(" Как дела", before: "привет,"), " как дела")
        // Sentence start (after a terminator, or empty) keeps the capital.
        XCTAssertEqual(SpellChecker.decapitalizeContinuation("Как дела", before: "Привет. "), "Как дела")
        XCTAssertEqual(SpellChecker.decapitalizeContinuation("Hello", before: ""), "Hello")
        // English "I" / contractions stay capital.
        XCTAssertEqual(SpellChecker.decapitalizeContinuation("I think so", before: "well "), "I think so")
        XCTAssertEqual(SpellChecker.decapitalizeContinuation("I'm sure", before: "and "), "I'm sure")
        // Acronyms stay upper.
        XCTAssertEqual(SpellChecker.decapitalizeContinuation("API call", before: "the "), "API call")
    }

    // Every synthetic edit (accept, fix, ⌘Z undo, dictation) moves the cache
    // through this one rule — the settle window and the undo snapshot compare
    // against what it returns.
    func testTextAfterInjection() {
        typealias C = FieldState
        XCTAssertEqual(C.textAfterInjection("lo there", deleting: "", over: "hel"), "hello there")
        XCTAssertEqual(C.textAfterInjection("hello", deleting: "helo", over: "say helo"), "say hello")
        XCTAssertEqual(C.textAfterInjection("", deleting: " there", over: "hello there"), "hello")
        XCTAssertEqual(C.textAfterInjection("🤷", deleting: ":shrug:", over: "ok :shrug:"), "ok 🤷")
        // Unknown stays unknown, and a delete of text that isn't there can't be placed.
        XCTAssertNil(C.textAfterInjection("x", deleting: "", over: nil))
        XCTAssertNil(C.textAfterInjection("x", deleting: "abcde", over: "abc"))
    }

    // Backspaces delete what AppKit deletes per press: a whole emoji or
    // Latin letter, one code point of Thai, Arabic, Hebrew or Devanagari.
    // Counting `Character`s left half a Thai word behind on ⌘Z.
    @MainActor
    func testBackspacesFollowAppKitDeletion() {
        XCTAssertEqual(TextInjector.backspaces(over: "привет"), 6)
        XCTAssertEqual(TextInjector.backspaces(over: "caf\u{E9}"), 4)
        XCTAssertEqual(TextInjector.backspaces(over: "cafe\u{301}"), 4)
        XCTAssertEqual(TextInjector.backspaces(over: "👨‍👩‍👧 🇷🇺👍🏽"), 4)
        XCTAssertEqual(TextInjector.backspaces(over: "\u{E17}\u{E35}\u{E48}\u{E19}\u{E35}\u{E48}"), 6)  // ที่นี่
        XCTAssertEqual(TextInjector.backspaces(over: "\u{5E9}\u{5B8}\u{5C1}\u{5DC}\u{5D5}\u{5B9}\u{5DD}"), 7)  // שָׁלוֹם
        XCTAssertEqual(TextInjector.backspaces(over: "\u{915}\u{93F}\u{924}\u{93E}\u{92C}"), 5)  // किताब
    }

    // A space the context already ends with must not be shown or typed twice.
    func testSeamSpaceDedup() {
        let f = SuggestionController.deduplicatingSeamSpace
        XCTAssertEqual(f(" ответ", "Спасибо за "), "ответ")
        XCTAssertEqual(f("  ответ", "Спасибо за "), "ответ")
        // No space before the caret: the suggestion's own space is the separator.
        XCTAssertEqual(f(" ответ", "Спасибо за"), " ответ")
        XCTAssertEqual(f("вет", "при"), "вет")
        XCTAssertEqual(f(" ", "за "), "")
    }

    // The injection path chunks UTF-16 at 16 units; a surrogate pair straddling
    // a boundary must never be split (it would post as a broken glyph).
    func testInjectorSurrogateSafeChunking() {
        func chunks(_ s: String, size: Int = 16) -> [[UniChar]] {
            TextInjector.utf16Chunks(Array(s.utf16), chunkSize: size)
        }
        // Every chunk must reassemble to valid UTF-16 (no lone surrogate at an
        // interior chunk's edges) and the concatenation must be lossless.
        func assertClean(_ s: String, size: Int = 16) {
            let cs = chunks(s, size: size)
            XCTAssertEqual(cs.flatMap { $0 }, Array(s.utf16), "lossless round-trip")
            for (i, c) in cs.enumerated() {
                // A non-final chunk must not end on a high surrogate.
                if i < cs.count - 1, let last = c.last {
                    XCTAssertFalse((0xD800...0xDBFF).contains(last), "split surrogate at chunk \(i)")
                }
            }
        }
        // 15 ASCII + one emoji (2 units): the pair would land at units 15–16 and
        // split under naive fixed chunking. It must move whole into chunk 2.
        assertClean(String(repeating: "a", count: 15) + "😀")
        assertClean(String(repeating: "😀", count: 20))          // all astral
        assertClean("plain ascii text under the limit")
        assertClean("")                                            // empty → no chunks
        // Forced tiny size to exercise the boundary densely.
        assertClean("a😀b😀c😀d😀", size: 2)
        // Never emits an empty chunk / never loops forever.
        for c in chunks(String(repeating: "😀", count: 9), size: 2) {
            XCTAssertFalse(c.isEmpty)
        }
    }

    // What a transcript looks like by the time it reaches the field. A newline
    // would SEND the message in half the apps this types into, and speech has
    // no spacebar — the seam with what is already typed is ours to get right.
    func testDictationTextShaping() {
        XCTAssertEqual(DictationController.clean("  hello   there\nfriend \n"), "hello there friend")
        XCTAssertEqual(DictationController.clean("a\r\nb\u{2028}c"), "a b c")
        XCTAssertEqual(DictationController.clean("   "), "")

        // The pill shows the END of a long dictation — that is where the words
        // being spoken right now are.
        XCTAssertEqual(DictationController.tail("short", limit: 10), "short")
        XCTAssertEqual(DictationController.tail("abcdefghijkl", limit: 4), "…ijkl")

        func seam(_ text: String, _ context: String) -> String {
            SuggestionController.spacedForInsertion(text, after: context)
        }
        XCTAssertEqual(seam("привет", "я сказал"), " привет")     // word + word
        XCTAssertEqual(seam("привет", "я сказал "), "привет")     // space already typed
        XCTAssertEqual(seam("hello", ""), "hello")                // empty field
        XCTAssertEqual(seam("hello", "line\n"), "hello")          // start of a line
        XCTAssertEqual(seam(", then", "yes"), ", then")           // punctuation hugs the word
        XCTAssertEqual(seam("word", "("), "word")                 // just opened a bracket
        XCTAssertEqual(seam("word", "«"), "word")

        // Chinese and Japanese are written without spaces between words, so a
        // seam space there is a typo the user has to delete. Either side of the
        // boundary being Han or kana is enough to suppress it.
        XCTAssertEqual(seam("世界", "你好"), "世界")               // Han + Han
        XCTAssertEqual(seam("それ", "です"), "それ")               // kana + kana
        XCTAssertEqual(seam("です", "hello"), "です")              // Latin, then kana
        XCTAssertEqual(seam("world", "你好"), "world")            // Han, then Latin
        // Korean is NOT scriptio continua — Hangul spaces its words like ours.
        XCTAssertEqual(seam("하세요", "안녕"), " 하세요")
        // Fullwidth punctuation carries its own side-bearing: none before a
        // closing "。", none after an opening bracket.
        XCTAssertEqual(seam("。", "你好"), "。")
        XCTAssertEqual(seam("こんにちは", "「"), "こんにちは")

        // The RIGHT seam, when the caret sits before existing text. Same rules
        // mirrored — otherwise "hello|world" fuses the dictated tail into the
        // word that follows it.
        func seamed(_ text: String, _ context: String, _ following: String) -> String {
            SuggestionController.spacedForInsertion(text, after: context, before: following)
        }
        XCTAssertEqual(seamed("there", "hello", "world"), " there ")  // both sides fuse
        XCTAssertEqual(seamed("there", "hello", " world"), " there")  // space already there
        XCTAssertEqual(seamed("there", "hello", ""), " there")        // caret at the end
        XCTAssertEqual(seamed("there", "hello", "\nnext"), " there")  // end of the line
        XCTAssertEqual(seamed("yes", "", ", then"), "yes")            // punctuation hugs it
        XCTAssertEqual(seamed("(", "", "word"), "(")                  // opened a bracket
        XCTAssertEqual(seamed("世界", "", "です"), "世界")             // no space either side
    }

    // What can reach the field from an engine: one line, tabs as spaces,
    // runs of spaces as one, no trailing space, and never past the cap.
    @MainActor
    func testWhatAnAnswerIsCutTo() {
        let cut = SuggestionController.sanitized
        XCTAssertEqual(cut("a\tb", 120), "a b")
        XCTAssertEqual(cut("line one\nline two", 120), "line one")
        XCTAssertEqual(cut("line one\r\nline two", 120), "line one")
        XCTAssertEqual(cut("a   b  c", 120), "a b c")
        XCTAssertEqual(cut("word ", 120), "word")
        XCTAssertEqual(cut("word  ", 120), "word")
        XCTAssertEqual(cut(" lead", 120), " lead")
        XCTAssertEqual(cut(String(repeating: "x", count: 130), 120).count, 120)
        XCTAssertEqual(cut(String(repeating: "x", count: 120), 120).count, 120)
        XCTAssertEqual(cut(String(repeating: "x", count: 119) + " y", 120).count, 119, "a space left at the cut goes")
        XCTAssertEqual(cut("\nnothing", 120), "")
    }

    // The blocks written without spaces end where they end: the first code
    // point past each one takes the ordinary seam.
    func testTheScriptioContinuaBlocksEdges() {
        func seam(_ text: String) -> String { SuggestionController.spacedForInsertion(text, after: "x") }
        XCTAssertEqual(seam("\u{3001}"), "\u{3001}", "、 opens the CJK block")
        XCTAssertEqual(seam("\u{30FF}"), "\u{30FF}", "ヿ closes katakana")
        XCTAssertEqual(seam("\u{3105}"), " \u{3105}", "bopomofo is past it")
        XCTAssertEqual(seam("\u{3100}"), " \u{3100}")
        XCTAssertEqual(seam("\u{2FFF}"), " \u{2FFF}")
        XCTAssertEqual(seam("\u{FF00}"), "\u{FF00}", "the fullwidth block's first point")
        XCTAssertEqual(seam("\u{FF01}"), "\u{FF01}", "！ fullwidth")
        XCTAssertEqual(seam("\u{FF71}"), "\u{FF71}", "ｱ halfwidth katakana")
        XCTAssertEqual(seam("\u{FFEF}"), "\u{FFEF}")
        XCTAssertEqual(seam("\u{FFF0}"), " \u{FFF0}")
        XCTAssertEqual(seam("\u{FEFF}a"), " \u{FEFF}a")
    }
}

final class DanishSpellingTests: XCTestCase {
    // The recognizer reads short Danish as Norwegian or Swedish; a keyboard
    // language it still finds plausible wins the dictionary, a faint one
    // (< 0.05) or a keyboard it doesn't consider at all does not.
    func testAKeyboardLanguageWinsTheDictionary() {
        let hyps = ["nb": 0.78, "da": 0.21, "sv": 0.01]
        XCTAssertEqual(SpellChecker.dictionaryLanguage(recognized: "nb", hypotheses: hyps, keyboards: ["da", "en"]), "da")
        XCTAssertEqual(SpellChecker.dictionaryLanguage(recognized: "nb", hypotheses: hyps, keyboards: ["en"]), "nb")
        XCTAssertEqual(SpellChecker.dictionaryLanguage(recognized: "nb", hypotheses: hyps, keyboards: ["sv"]), "nb")
        XCTAssertEqual(SpellChecker.dictionaryLanguage(recognized: "ru", hypotheses: ["ru": 0.9], keyboards: ["ru", "en"]), "ru")
    }

    // Words mode on an English + Danish Mac: the dictionary follows the
    // language being typed, not the order the keyboards were added in.
    func testWordsFollowTheTypedLanguage() {
        XCTAssertEqual(SpellChecker.typingOrder(["en", "da"], typed: "da"), ["da", "en"])
        XCTAssertEqual(SpellChecker.typingOrder(["en", "da"], typed: nil), ["en", "da"])
        XCTAssertEqual(SpellChecker.typingOrder(["en", "da"], typed: "sv"), ["en", "da"])
    }

    // A Danish writer (no Danish keyboard needed: the typed language counts)
    // keeps "Hvad" — the Swedish dictionary turned it into "Vad" — and a real
    // Danish typo is still fixed.
    func testACorrectDanishWordIsLeftAlone() {
        TypedLanguage.reset()
        defer { TypedLanguage.reset() }
        for _ in 0 ..< TypedLanguage.minObservations { TypedLanguage.observe("da") }
        XCTAssertNil(SpellChecker.correction(for: "Hvad", context: "Hvad"))
        XCTAssertEqual(SpellChecker.correction(for: "suklle", context: "Jeg synes, vi suklle"), "skulle")
    }
}
