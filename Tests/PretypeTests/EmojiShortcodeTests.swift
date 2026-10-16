import XCTest
@testable import Pretype

final class EmojiShortcodeTests: XCTestCase {
    // A shortcode fires an in-place replacement, so the scanner's guards are the
    // whole safety story: everything that merely ends in a colon must stay quiet.
    @MainActor
    func testEmojiShortcodeDetection() {
        // A closed shortcode is detected and resolves.
        XCTAssertEqual(EmojiShortcodes.trailingShortcode(in: "shrug :shrug:"), ":shrug:")
        XCTAssertEqual(EmojiShortcodes.emoji(for: ":shrug:"), "🤷")

        // Only through the system Unicode-name table (no alias entry for these).
        XCTAssertEqual(EmojiShortcodes.emoji(for: ":rocket:"), "🚀")
        XCTAssertEqual(EmojiShortcodes.emoji(for: ":pile_of_poo:"), "💩")
        // Text-presentation legacy dingbat gets VS16 so it renders as emoji.
        XCTAssertEqual(EmojiShortcodes.emoji(for: ":gear:"), "⚙\u{FE0F}")

        // Only through the alias table — Gemoji nicknames are not Unicode names.
        XCTAssertEqual(EmojiShortcodes.emoji(for: ":joy:"), "😂")
        XCTAssertEqual(EmojiShortcodes.emoji(for: ":tada:"), "🎉")
        XCTAssertEqual(EmojiShortcodes.emoji(for: ":cmd:"), "⌘")

        // "+1"/"-1" are the two letterless bodies that ARE names — the reason
        // +/- are in the scanner's charset at all.
        XCTAssertEqual(EmojiShortcodes.trailingShortcode(in: "nice :+1:"), ":+1:")
        XCTAssertEqual(EmojiShortcodes.emoji(for: ":+1:"), "👍")
        XCTAssertEqual(EmojiShortcodes.emoji(for: ":-1:"), "👎")
        // …while a +1 glued to a number is still arithmetic, not a shortcode.
        XCTAssertNil(EmojiShortcodes.trailingShortcode(in: "3:+1:"))

        // Mid-typing must stay silent: nothing fires until the closing colon.
        XCTAssertNil(EmojiShortcodes.trailingShortcode(in: ":shru"))
        XCTAssertNil(EmojiShortcodes.trailingShortcode(in: "type :roc"))

        // The body caps at 32 characters; one more is prose between colons.
        let body32 = String(repeating: "a", count: 32)
        XCTAssertEqual(EmojiShortcodes.trailingShortcode(in: "x :\(body32):"), ":\(body32):")
        XCTAssertNil(EmojiShortcodes.trailingShortcode(in: "x :\(body32)a:"))

        // Detected but unknown body → no emoji, so no pill.
        XCTAssertEqual(EmojiShortcodes.trailingShortcode(in: ":asdfqwer:"), ":asdfqwer:")
        XCTAssertNil(EmojiShortcodes.emoji(for: ":asdfqwer:"))

        // Every quiet case: times, ratios, URLs, code, bare colons.
        for quiet in ["10:30", "meet at 10:30:", "http://", "http:", ":", "::",
                      "foo:bar:", "ratio3:4:", "x :100:", ":a:", "ns::member:"] {
            XCTAssertNil(EmojiShortcodes.trailingShortcode(in: quiet), "should stay quiet: \(quiet)")
        }

        // lastToken is what every revalidation path uses: the shortcode when one
        // is closed at the caret, the plain word otherwise. trailingWord alone
        // stops at ':' and would read the shortcode back as "".
        XCTAssertEqual(CorrectionController.lastToken(of: "hey :shrug:"), ":shrug:")
        XCTAssertEqual(CorrectionController.lastToken(of: "hey teh"), "teh")
        XCTAssertEqual(SpellChecker.trailingWord(of: "hey :shrug:"), "")
    }
}
