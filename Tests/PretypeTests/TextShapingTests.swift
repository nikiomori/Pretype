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

    func testNarrowedSuggestion() {
        // Typing the suggestion's head shrinks it.
        XCTAssertEqual(SuggestionController.narrowedSuggestion("ing to the store", typedCharacters: "i"), "ng to the store")
        XCTAssertEqual(SuggestionController.narrowedSuggestion(" привет мир", typedCharacters: " "), "привет мир")
        // A diverging character invalidates it.
        XCTAssertNil(SuggestionController.narrowedSuggestion("ing to", typedCharacters: "x"))
        // Typing through the end leaves nothing to suggest.
        XCTAssertNil(SuggestionController.narrowedSuggestion("i", typedCharacters: "i"))
        // Control input (backspace, return, arrows/function keys) invalidates.
        XCTAssertNil(SuggestionController.narrowedSuggestion("ing to", typedCharacters: "\u{08}"))
        XCTAssertNil(SuggestionController.narrowedSuggestion("ing to", typedCharacters: "\r"))
        XCTAssertNil(SuggestionController.narrowedSuggestion("ing to", typedCharacters: "\u{F702}"))
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
        typealias C = SuggestionController
        XCTAssertEqual(C.textAfterInjection("lo there", deletingBackward: 0, over: "hel"), "hello there")
        XCTAssertEqual(C.textAfterInjection("hello", deletingBackward: 4, over: "say helo"), "say hello")
        XCTAssertEqual(C.textAfterInjection("", deletingBackward: 6, over: "hello there"), "hello")
        XCTAssertEqual(C.textAfterInjection("🤷", deletingBackward: 7, over: "ok :shrug:"), "ok 🤷")
        // Unknown stays unknown, and a delete past the known text can't be placed.
        XCTAssertNil(C.textAfterInjection("x", deletingBackward: 0, over: nil))
        XCTAssertNil(C.textAfterInjection("x", deletingBackward: 5, over: "abc"))
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
}
