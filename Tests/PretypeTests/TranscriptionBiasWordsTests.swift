import XCTest
@testable import Pretype

final class TranscriptionBiasWordsTests: XCTestCase {
    func testPicksNamesAndJargonNotSentenceStarts() {
        let words = Transcription.biasWords(in: """
        Yesterday I met Nikolai at the office. We talked about MLX and the iPhone.
        Then GPT4 came up, and Dubina laughed.
        """)
        XCTAssertEqual(Set(words), ["Nikolai", "MLX", "iPhone", "GPT4", "Dubina"])
        // Most recent first: what was typed last is likeliest to be said next.
        XCTAssertEqual(words.first, "Dubina")
    }

    func testDeduplicatesCaseInsensitivelyAndCaps() {
        let text = (0..<80).map { "word Name\($0)x" }.joined(separator: " ") + " NAME79X"
        let words = Transcription.biasWords(in: text)
        XCTAssertEqual(words.count, 50)
        XCTAssertEqual(words.filter { $0.lowercased() == "name79x" }.count, 1)
    }

    func testCyrillicNames() {
        XCTAssertEqual(Transcription.biasWords(in: "Вчера говорил с Николаем про Pretype."),
                       ["Pretype", "Николаем"])
    }

    // Heard in another case or split, a term comes out as written; a page's
    // plain capitalized word never recases what was said.
    func testSpellsTheTermsAsWritten() {
        let inferred = ["SuggestionController", "MLX", "iPhone", "Settings", "GPT4"]
        XCTAssertEqual(Transcription.spell("open suggestion controller and mlx on the iphone", inferred: inferred),
                       "open SuggestionController and MLX on the iPhone")
        XCTAssertEqual(Transcription.spell("change the settings, then gpt 4", inferred: inferred),
                       "change the settings, then GPT4")
        XCTAssertEqual(Transcription.spell("suggestion, controller", inferred: inferred), "suggestion, controller",
                       "joined across single spaces only")
        XCTAssertEqual(Transcription.spell("pre type and dubina", inferred: [], listed: ["Pretype", "Дубина", "Dubina"]),
                       "Pretype and Dubina")
        XCTAssertEqual(Transcription.spell("привет, дубина", inferred: [], listed: ["Дубина"]), "привет, Дубина")
        XCTAssertEqual(Transcription.spell("nothing here", inferred: []), "nothing here")
    }

    // The Parakeet switch shows to whoever reads the app in the language they
    // dictate, and stays in sight once on.
    func testParakeetIsOfferedInTheInterfacesLanguage() {
        let ru = Locale(identifier: "ru_RU")
        XCTAssertTrue(Parakeet.isOffered(dictating: ru, interface: "ru", isOn: false))
        XCTAssertFalse(Parakeet.isOffered(dictating: ru, interface: "en", isOn: false))
        XCTAssertTrue(Parakeet.isOffered(dictating: ru, interface: "en", isOn: true), "on: it can go off")
        XCTAssertFalse(Parakeet.isOffered(dictating: Locale(identifier: "ja_JP"), interface: "ja", isOn: true), "not a Parakeet language")
    }
}
