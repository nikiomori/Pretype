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
}
