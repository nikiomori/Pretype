import XCTest
@testable import Pretype

/// Words mode (`WordCompletion`): the rest of the word, from the user's own
/// words first and the dictionary for the rest, only when the word clearly
/// beats the letters as typed — and never in code.
@MainActor
final class WordCompletionTests: XCTestCase {
    private func suggest(_ text: String, after: String = "", learned: String = "",
                         dictionary: [String] = [], isWord: Bool = false) -> String? {
        let ngram = PersonalNgram()
        ngram.learn(learned)
        return WordCompletion.suggestion(text: text, after: after, ngram: ngram,
                                         isWord: { _, _ in isWord }, dictionary: { _, _ in dictionary })
    }

    func testTheUsersOwnWordFinishesWhenItClearlyLeads() {
        let typed = String(repeating: "tomorrow works, see you tomorrow. ", count: 3)
        XCTAssertEqual(suggest("see you tomo", learned: typed), "rrow")
        // Seen once: not yet a habit.
        XCTAssertNil(suggest("see you tomo", learned: "tomorrow"))
        // Mid-word caret, too few letters, nothing left worth a key.
        XCTAssertNil(suggest("see you tomo", after: "rrow", learned: typed))
        XCTAssertNil(suggest("see you t", learned: typed))
        XCTAssertNil(suggest("see you tomorro", learned: typed))
    }

    /// The letters typed as a finished word count against every longer one:
    /// "the" typed a hundred times never grows a "re".
    func testAFinishedWordOutweighsItsLongerKin() {
        let typed = String(repeating: "the cat ", count: 40) + String(repeating: "there ", count: 3)
        XCTAssertNil(suggest("look at the", learned: typed))
        XCTAssertEqual(suggest("look at the", learned: String(repeating: "there ", count: 3)), "re")
    }

    func testTheDictionaryAnswersOnlyForWordsNeverTyped() {
        XCTAssertEqual(suggest("I recei", dictionary: ["received", "receive"]), "ved")
        // The letters already spell a word: no guess at a longer one.
        XCTAssertNil(suggest("I recei", dictionary: ["received"], isWord: true))
        // Three letters are too few for the dictionary.
        XCTAssertNil(suggest("I rec", dictionary: ["received"]))
        // Typed from these letters before, but split: the user's words decide.
        XCTAssertNil(suggest("I recei", learned: "receipt receipt receive receive", dictionary: ["received"]))
    }

    func testNoGuessesInCode() {
        for (token, line) in [("user_na", "fix user_na"), ("/usr/lo", "cd /usr/lo"), ("getUserNa", "getUserNa"),
                              ("foo@exam", "mail foo@exam"), ("v2bet", "v2bet")] {
            XCTAssertFalse(WordCompletion.isProse(token: token, line: line), token)
        }
        XCTAssertFalse(WordCompletion.isProse(token: "comm", line: "/comm"))
        XCTAssertTrue(WordCompletion.isProse(token: "tomo", line: "see you tomo"))
        XCTAssertTrue(WordCompletion.isProse(token: "Tomo", line: "Tomo"))
    }

    /// The space Words types after a word: a space typed next is the same
    /// space, closing punctuation takes its place, anything else leaves it.
    func testTheProvisionalSpaceSettles() {
        XCTAssertEqual(SuggestionController.spaceSettlement(" "), " ")
        XCTAssertEqual(SuggestionController.spaceSettlement("."), ".")
        XCTAssertEqual(SuggestionController.spaceSettlement(")"), ")")
        XCTAssertNil(SuggestionController.spaceSettlement("a"))
        XCTAssertNil(SuggestionController.spaceSettlement("("))
        XCTAssertNil(SuggestionController.spaceSettlement(".."))
    }
}
