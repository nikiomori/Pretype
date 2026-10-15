import XCTest
@testable import Pretype

final class GatesTests: XCTestCase {
    // The output gate decides what raw model text reaches the user's keystrokes —
    // the single most safety-critical pure function in the app. Pin its rules.
    func testCompletionGatesPostProcess() {
        func pp(_ raw: String, prompt: String = "hello world", trailingSpaces: Int = 0,
                endsMidWord: Bool = false, endsCompleteWord: Bool = false,
                after: String = "") -> String? {
            CompletionGates.postProcess(
                raw, prompt: prompt, trailingSpaces: trailingSpaces,
                endsMidWord: endsMidWord, endsCompleteWord: endsCompleteWord,
                textAfterCaret: after)
        }

        // Control characters / the replacement char must never be typed back.
        XCTAssertNil(pp("a\u{07}b"))
        XCTAssertNil(pp("te\u{FFFD}xt"))
        // A CJK derail for a non-CJK prompt is rejected.
        XCTAssertNil(pp("你好 there", prompt: "hello world"))
        // Degenerate character repetition is rejected.
        XCTAssertNil(pp("юююю", prompt: "привет как дела друзья"))
        // A suggestion that fully echoes the typed text is rejected.
        XCTAssertNil(pp("hello world", prompt: "hello world"))
        // A partial echo of the prompt tail is stripped, keeping the continuation.
        XCTAssertEqual(pp(" world hi", prompt: "hello world"), " hi")
        // With a typed trailing space, a continuation must carry its own separator…
        XCTAssertNil(pp("morrow", prompt: "to", trailingSpaces: 1))
        // …and a leading space the model adds is normalized away.
        XCTAssertEqual(pp(" there", prompt: "hello", trailingSpaces: 1), "there")
        // Mid-word caret: a new word (leading space) is dropped unless the run is a
        // complete word, where the space is the separator the user hasn't typed yet.
        XCTAssertNil(pp(" world", prompt: "hel", endsMidWord: true, endsCompleteWord: false))
        XCTAssertEqual(pp(" world", prompt: "hello", endsMidWord: true, endsCompleteWord: true), " world")
        // Don't re-suggest what already follows the caret.
        XCTAssertNil(pp("world", prompt: "hello", after: "world tour"))
        // Trim at the first sentence boundary.
        XCTAssertEqual(pp("sure. and more", prompt: "ok"), "sure.")
    }

    func testLevenshteinDistance() {
        XCTAssertTrue(CorrectionGates.isMinimalCorrection(original: "teh", fixed: "the"))
        XCTAssertTrue(CorrectionGates.isMinimalCorrection(original: "recei", fixed: "receive"))
        XCTAssertTrue(CorrectionGates.isMinimalCorrection(original: "привет", fixed: "привет!"))
        
        // Massive rewrites should be rejected
        XCTAssertFalse(CorrectionGates.isMinimalCorrection(original: "hello how are you", fixed: "goodbye my friend"))
    }

    func testCleanCorrectionOutput() {
        XCTAssertEqual(CorrectionGates.cleanCorrectionOutput("\"hello\""), "hello")
        XCTAssertEqual(CorrectionGates.cleanCorrectionOutput("«привет»"), "привет")
        XCTAssertEqual(CorrectionGates.cleanCorrectionOutput("“test”"), "test")
        XCTAssertEqual(CorrectionGates.cleanCorrectionOutput("  trimmed  \n  newline  "), "trimmed")
    }

    func testTrimRunOn() {
        // The measured failure: exact fix + same-line junk (E4B-it-4bit, 39%
        // of eval-correct rows) — junk after the sentence terminal is cut.
        XCTAssertEqual(
            CorrectionGates.trimRunOn("Завтра уже уезжать, а я не собрал чемодан.гуглгугл",
                                      original: "Звтра уже уезжать, а я не собрал чемодан."),
            "Завтра уже уезжать, а я не собрал чемодан.")
        // Closing quote after the terminal survives the cut.
        XCTAssertEqual(
            CorrectionGates.trimRunOn("Он сказал: «Готово.» мусор",
                                      original: "Он сказал: «Готово.»"),
            "Он сказал: «Готово.»")
        // Apostrophes/quotes never start a cut (measured regressions).
        let apostrophe = "Il a rempli ma feuille d'impôts."
        XCTAssertEqual(CorrectionGates.trimRunOn(apostrophe, original: apostrophe), apostrophe)
        let tag = "You learned English from Miss Long, didn't you?"
        XCTAssertEqual(CorrectionGates.trimRunOn(tag + " junk", original: tag), tag)
        // Original without a sentence ending — the shape DICTATION always has,
        // since the system dictation model writes no punctuation. There is no
        // ending to anchor on, so length is the anchor: a tidy-up adds
        // punctuation and case, it does not add words.
        //
        // Reported from real use: strange characters at the end of a dictation,
        // CJK or stray Latin — an instruct model generating past its answer.
        let heard = "завтра уже уезжать а я не собрал чемодан"
        let tidied = "Завтра уже уезжать, а я не собрал чемодан."
        XCTAssertEqual(CorrectionGates.trimRunOn(tidied, original: heard), tidied,
                       "adding punctuation and case must survive untouched")
        XCTAssertEqual(CorrectionGates.trimRunOn(tidied + "你好世界你好世界", original: heard), tidied)
        XCTAssertEqual(CorrectionGates.trimRunOn(tidied + " fix.less than 100 words",
                                                 original: heard), tidied)
        // Junk with no sentence terminal anywhere to cut back to: hand back the
        // original, which makes the caller keep exactly what was heard.
        XCTAssertEqual(
            CorrectionGates.trimRunOn("Завтра уже уезжать а я не собрал чемодан 你好世界你好世界你好世界",
                                      original: heard),
            heard)
        // Growth within the budget is left alone — a short fix has room to
        // breathe (the +6 floor), so ordinary ⌥⇥ on a fragment still works.
        XCTAssertEqual(CorrectionGates.trimRunOn("fixed words", original: "fixd words"),
                       "fixed words")
        // …but a fragment the model CONTINUED instead of fixing is refused.
        XCTAssertEqual(CorrectionGates.trimRunOn("fixed words and then some more",
                                                 original: "fixd words"),
                       "fixd words")
        // Exact fix passes through untouched.
        let clean = "Nothing to trim here."
        XCTAssertEqual(CorrectionGates.trimRunOn(clean, original: clean), clean)
        // Multi-terminal endings ("...", "?!", "!!!") survive whole — the cut
        // keeps the full punctuation run, junk after it still goes.
        let ellipsis = "I don't know..."
        XCTAssertEqual(CorrectionGates.trimRunOn(ellipsis, original: "I dont know..."), ellipsis)
        XCTAssertEqual(CorrectionGates.trimRunOn(ellipsis + "junk", original: "I dont know..."),
                       ellipsis)
        XCTAssertEqual(CorrectionGates.trimRunOn("Really?!", original: "Realy?!"), "Really?!")
        let bang = "Ну и ну!!!"
        XCTAssertEqual(CorrectionGates.trimRunOn(bang, original: bang), bang)
        // A dot between digits is a decimal, not a sentence end.
        let decimal = "The total is 3.14159."
        XCTAssertEqual(CorrectionGates.trimRunOn(decimal, original: "The total is 3,14159."),
                       decimal)
        XCTAssertEqual(CorrectionGates.trimRunOn(decimal + "junk",
                                                 original: "The total is 3,14159."),
                       decimal)
        // CJK closing quote after the terminal survives the cut.
        XCTAssertEqual(CorrectionGates.trimRunOn("彼は「終わった。」ごみ", original: "彼は「終わった。」"),
                       "彼は「終わった。」")
    }
}
