import CoreGraphics
import XCTest
@testable import Pretype

/// What the injector actually posts, recorded instead of sent.
@MainActor
final class TextInjectorTests: XCTestCase {
    private var posted: [CGEvent] = []
    private var realPost = TextInjector.post

    override func setUp() {
        super.setUp()
        realPost = TextInjector.post
        TextInjector.post = { [weak self] in self?.posted.append($0) }
    }

    override func tearDown() {
        TextInjector.post = realPost
        super.tearDown()
    }

    // Injection runs while keys are physically down — ⇧ through ⇧⇥, the
    // dictation modifier under a queued transcript — and an event keeps the
    // hardware's modifiers unless cleared: the text would arrive as ⇧/⌥
    // shortcuts. Every event is bare, and tagged so our own tap lets it by.
    func testEveryInjectedKeyIsBareAndTagged() {
        TextInjector.insert("hé 👋")
        TextInjector.deleteBackward(over: "ab")
        TextInjector.press(KeyCode.returnKey, times: 1)
        XCTAssertEqual(posted.count, 2 + 4 + 2, "down and up for each chunk and press")
        XCTAssertEqual(posted.map(\.type), Array(repeating: [CGEventType.keyDown, .keyUp], count: 4).flatMap { $0 })
        for event in posted {
            XCTAssertEqual(event.flags, [], "flags \(String(event.flags.rawValue, radix: 16))")
            XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), TextInjector.magicTag)
        }
        let typed = posted.first.map { event -> String in
            var length = 0
            var units = [UniChar](repeating: 0, count: 16)
            event.keyboardGetUnicodeString(maxStringLength: 16, actualStringLength: &length, unicodeString: &units)
            return String(utf16CodeUnits: units, count: length)
        }
        XCTAssertEqual(typed, "hé 👋")
        XCTAssertEqual(posted[2...5].map { $0.getIntegerValueField(.keyboardEventKeycode) }, Array(repeating: KeyCode.delete, count: 4))
    }

    // A terminal's line editor deletes a whole cluster per press; AppKit
    // deletes a Devanagari vowel sign at a time. One word, two counts.
    func testATerminalDeletesByCharacterAndAppKitByItsOwnCount() {
        TextInjector.deleteBackward(over: "किताब", perCharacter: true)
        XCTAssertEqual(posted.count, 2 * 3)
        posted = []
        TextInjector.deleteBackward(over: "किताब")
        XCTAssertEqual(posted.count, 2 * 5)
    }

    // Malformed input ending on a lone high surrogate keeps it — the split
    // only ever moves a pair whole, and must still make progress.
    func testATrailingLoneSurrogateStaysInItsChunk() {
        XCTAssertEqual(TextInjector.utf16Chunks([0x41, 0xD800]), [[0x41, 0xD800]])
    }

    // Nothing to type or press posts nothing; a long text goes out in
    // sixteen-unit chunks that add up to it, and each press is one key.
    func testWhatIsPostedForNothingAndForALongText() {
        TextInjector.insert("")
        TextInjector.press(KeyCode.delete, times: 0)
        TextInjector.deleteBackward(over: "")
        XCTAssertTrue(posted.isEmpty)

        let text = String(repeating: "abcdefgh", count: 4) + "!"
        TextInjector.insert(text)
        let downs = posted.filter { $0.type == .keyDown }
        XCTAssertEqual(downs.count, 3)
        let typed = downs.map { event -> String in
            var length = 0
            var units = [UniChar](repeating: 0, count: 32)
            event.keyboardGetUnicodeString(maxStringLength: 32, actualStringLength: &length, unicodeString: &units)
            return String(utf16CodeUnits: units, count: length)
        }
        XCTAssertEqual(typed.joined(), text)
        XCTAssertEqual(typed.map(\.count), [16, 16, 1])

        posted = []
        TextInjector.press(KeyCode.returnKey, times: 2)
        XCTAssertEqual(posted.map { $0.getIntegerValueField(.keyboardEventKeycode) }, Array(repeating: KeyCode.returnKey, count: 4))
    }
}
