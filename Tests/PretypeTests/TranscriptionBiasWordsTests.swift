import XCTest
@testable import Pretype

final class TranscriptionBiasWordsTests: XCTestCase {
    func testPicksNamesAndJargonNotSentenceStarts() {
        let words = Transcription.biasWords(in: """
        Yesterday I met Leonid at the office. We talked about MLX and the iPhone.
        Then GPT4 came up, and Verenko laughed.
        """)
        XCTAssertEqual(Set(words), ["Leonid", "MLX", "iPhone", "GPT4", "Verenko"])
        // Most recent first: what was typed last is likeliest to be said next.
        XCTAssertEqual(words.first, "Verenko")
    }

    func testDeduplicatesCaseInsensitivelyAndCaps() {
        let text = (0..<80).map { "word Name\($0)x" }.joined(separator: " ") + " NAME79X"
        let words = Transcription.biasWords(in: text)
        XCTAssertEqual(words.count, 50)
        XCTAssertEqual(words.filter { $0.lowercased() == "name79x" }.count, 1)
    }

    func testCyrillicNames() {
        XCTAssertEqual(Transcription.biasWords(in: "Вчера говорил с Леонидом про Pretype."),
                       ["Pretype", "Леонидом"])
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
        XCTAssertEqual(Transcription.spell("pre type and verenko", inferred: [], listed: ["Pretype", "Веренко", "Verenko"]),
                       "Pretype and Verenko")
        XCTAssertEqual(Transcription.spell("привет, веренко", inferred: [], listed: ["Веренко"]), "привет, Веренко")
        XCTAssertEqual(Transcription.spell("ask claude code", inferred: [], listed: ["Claude Code"]), "ask Claude Code")
        XCTAssertEqual(Transcription.spell("nothing here", inferred: []), "nothing here")
    }

    // An identifier in the session must not rewrite ordinary speech: parts
    // join only into a listed term or one with a capital first letter.
    func testPartsJoinOnlyIntoSafeTerms() {
        let session = ["forEach", "isEmpty", "inProgress", "QuillParser"]
        XCTAssertEqual(Transcription.spell("for each file, is empty, in progress", inferred: session),
                       "for each file, is empty, in progress")
        XCTAssertEqual(Transcription.spell("foreach and quill parser", inferred: session), "forEach and QuillParser",
                       "one word heard is the term in another case; a capital joins")
        XCTAssertEqual(Transcription.spell("for each file", inferred: [], listed: ["forEach"]), "forEach file",
                       "the user listed it")
    }

    // "Exactly": a term of any length, and one heard with its own hyphen.
    func testAListedTermIsSpelledAsListed() {
        XCTAssertEqual(Transcription.spell("ask the quiet river data team", inferred: [],
                                           listed: ["Quiet River Data Team"]), "ask the Quiet River Data Team")
        XCTAssertEqual(Transcription.spell("a very long project name here", inferred: [],
                                           listed: ["Very Long Project Name Here"]), "a Very Long Project Name Here")
        XCTAssertEqual(Transcription.spell("the pre-trained model", inferred: [], listed: ["Pre-Trained"]),
                       "the Pre-Trained model")
        XCTAssertEqual(Transcription.spell("the pre trained model", inferred: [], listed: ["Pre-Trained"]),
                       "the Pre-Trained model")
        XCTAssertEqual(Transcription.spell("run gpt-4 now", inferred: ["GPT-4"]), "run GPT-4 now")
        XCTAssertEqual(Transcription.spell("well-known", inferred: [], listed: ["Wellknown"]), "well-known",
                       "a hyphen the term doesn't have stays")
    }

    // Keys printed in a session never become hints. The strings are invented,
    // and assembled so that no key-shaped text sits in the repository.
    func testKeysAreNotBiasWords() {
        let tail = String(repeating: "k3Xp", count: 8)
        let keys = ["sk-" + tail, "ghp_" + tail, "xoxb-" + tail, "github_pat_" + tail, "AKIA" + "QZ7TINVENTED1",
                    "sk-" + "demoKEY12", String(repeating: "9f3a", count: 10),
                    "QwErTyUiOpAsDfGhJkLzXcVbNmPlOkIjUh", "postgres://admin:" + tail + "@db.example.com"]
        for key in keys { XCTAssertTrue(Transcription.looksSecret(key), key) }
        XCTAssertTrue(Transcription.looksSecret("TOKEN=ghp_" + tail), "after an assignment")
        for assignment in ["password=" + "plum7lake", "DB_PASSWD=" + "Plum7", "Secret:" + "plum7", "apiKey:" + "Plum7",
                           "pwd:" + "plum7", "auth_token:" + "Plum7", "RETRIES=3"] {
            XCTAssertTrue(Transcription.looksSecret(assignment), assignment)
        }
        XCTAssertEqual(Transcription.biasWords(in: "set password=" + "plum7lake for QuillParser"), ["QuillParser"])
        XCTAssertEqual(Transcription.biasWords(in: "use \(keys[1]) with QuillParser and \"token\":\"\(keys[0])\""),
                       ["QuillParser"])
        for name in ["GPT4", "iPhone", "Qwen3.5-2B-M40-6bit", "sk-learn", "SuggestionControllerKeyHandling", "Foo::Bar",
                     "applicationDidFinishLaunchingWithOptions", "Sources/Pretype/Dictation/Transcription.swift"] {
            XCTAssertFalse(Transcription.looksSecret(name), name)
        }
    }

    // Parakeet that can't start hands over to Apple's model, when there is
    // one; with none, or for a cancelled capture, its error stands.
    func testParakeetFallsBackToAppleOnlyWhenAppleCanServe() async throws {
        let apple = EmptySession()
        func start(_ fallback: (() async throws -> TranscriptionSession)?) async throws -> TranscriptionSession {
            try await Transcription.parakeetFirst({ throw URLError(.notConnectedToInternet) }, orElse: fallback)
        }
        let session = try await start { apple }
        XCTAssertTrue(session === apple)
        do {
            _ = try await start(nil)
            XCTFail("no model to fall back on")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
        let untouched = try await Transcription.parakeetFirst({ apple }, orElse: { throw URLError(.badURL) })
        XCTAssertTrue(untouched === apple)
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
