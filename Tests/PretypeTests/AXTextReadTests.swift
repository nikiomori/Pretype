import AppKit
import Carbon
import XCTest
@testable import Pretype

/// `AXText`'s reads over a fake accessibility tree: what a native field, a
/// web field, a terminal and a selection read as, and what reads nothing.
final class AXTextReadTests: XCTestCase {
    private let tree = FakeAXTree()
    private let frame = FakeAXTree.frame

    private func context(_ element: AXUIElement, maxChars: Int = 1200, allowEmpty: Bool = false) -> TextContext? {
        tree.reading { AXText.context(for: element, maxChars: maxChars, allowEmpty: allowEmpty) }
    }

    /// The native caret at `index`, as the overlay gets it (Cocoa coordinates).
    private func caret(at index: Int) -> CGRect {
        AXText.flipped(FakeAXTree.glyphs(in: frame, from: index, count: 0))
    }

    override func setUpWithError() throws {
        try XCTSkipIf(NSScreen.screens.isEmpty, "caret geometry is checked against the attached displays")
    }

    // MARK: - A native field

    func testANativeFieldIsReadAroundTheCaret() throws {
        let mid = try XCTUnwrap(context(tree.field("Hello world", caret: 5)))
        XCTAssertEqual(mid.textBeforeCaret, "Hello")
        XCTAssertEqual(mid.textAfterCaret, " world")
        XCTAssertEqual(mid.caretRect, caret(at: 5))
        XCTAssertEqual(mid.host.fieldRect, AXText.flipped(frame))
        XCTAssertTrue(mid.host.textFollowsCaret)

        let end = try XCTUnwrap(context(tree.field("Hello world")))
        XCTAssertEqual(end.textBeforeCaret, "Hello world")
        XCTAssertEqual(end.textAfterCaret, "")
        XCTAssertEqual(end.caretRect, caret(at: 11))
        XCTAssertFalse(end.host.textFollowsCaret)

        let empty = try XCTUnwrap(context(tree.field("")))
        XCTAssertEqual(empty.textBeforeCaret, "")
        XCTAssertEqual(empty.textAfterCaret, "")

        // ProseMirror's typed space is a no-break one; it reads as a space.
        let nbsp = try XCTUnwrap(context(tree.field("так\u{00A0}же\u{00A0}x", caret: 7)))
        XCTAssertEqual(nbsp.textBeforeCaret, "так же ")
        XCTAssertEqual(nbsp.textAfterCaret, "x")
    }

    // A selection, a caret it can't place, or no caret at all: nothing.
    func testOnlyACollapsedCaretIsRead() {
        let field = tree.field("Hello world")
        tree.set(field, kAXSelectedTextRangeAttribute, CFRange(location: 2, length: 3))
        XCTAssertNil(context(field))
        tree.set(field, kAXSelectedTextRangeAttribute, CFRange(location: -1, length: 0))
        XCTAssertNil(context(field))
        tree.set(field, kAXSelectedTextRangeAttribute, nil)
        XCTAssertNil(context(field))
    }

    // A password field engaged anywhere, an open composition, or a value
    // that renders as mask glyphs: no text is read.
    func testSecureInputCompositionAndMasksReadNothing() {
        let field = tree.field("Hello")
        tree.secureInput = true
        XCTAssertNil(context(field))
        tree.secureInput = false
        XCTAssertNotNil(context(field))

        XCTAssertNil(context(tree.field("•••")))
        XCTAssertNil(context(tree.field("•••", native: false)))
    }

    // A composition is read from the field's marked range where it says
    // one way or the other; only a field that can't say falls back to the
    // input source — composing unless it's a Japanese IME's Roman mode.
    func testACompositionIsTheMarkedRangeOrTheInputSource() {
        let field = tree.field("Hello")
        let mode = kTISTypeKeyboardInputMode as String
        tree.inputSource = (mode, "com.apple.inputmethod.Japanese")
        tree.set(field, "AXTextInputMarkedRange", CFRange(location: 1, length: 2))
        XCTAssertNil(context(field), "marked")
        XCTAssertTrue(tree.reading { AXText.hasMarkedText(field) })
        tree.set(field, "AXTextInputMarkedRange", CFRange(location: 1, length: 1))
        XCTAssertNil(context(field), "one character marked")
        tree.set(field, "AXTextInputMarkedRange", CFRange(location: 1, length: 0))
        XCTAssertNotNil(context(field), "implemented and clear")
        XCTAssertFalse(tree.reading { AXText.hasMarkedText(field) })
        tree.set(field, "AXTextInputMarkedRange", nil)
        tree.fail(field, "AXTextInputMarkedRange", .noValue)
        XCTAssertNotNil(context(field), "implemented, nothing marked")

        let web = tree.field("Hello")   // no marked-range attribute at all
        XCTAssertNil(context(web), "a composing input source")
        XCTAssertFalse(tree.reading { AXText.hasMarkedText(web) }, "only the precise answer")
        tree.inputSource = (mode, "com.apple.inputmethod.Roman")
        XCTAssertNotNil(context(web))
        tree.inputSource = (kTISTypeKeyboardLayout as String, nil)
        XCTAssertNotNil(context(web))
        tree.inputSource = nil
        XCTAssertNotNil(context(web))
    }

    // A long document is read from its window's start, which holds still
    // while the user types — from the ranged read, or the whole value when
    // the field won't answer one.
    func testALongDocumentIsReadFromItsWindow() throws {
        let text = String(repeating: "abcdefghij", count: 70)   // 700 units
        let field = tree.field(text)
        XCTAssertEqual(context(field, maxChars: 100)?.textBeforeCaret, String(text.dropFirst(512)))
        XCTAssertEqual(context(field, maxChars: 700)?.textBeforeCaret, text)
        tree.answer(field, kAXStringForRangeParameterizedAttribute) { _ in nil }
        XCTAssertEqual(context(field, maxChars: 100)?.textBeforeCaret, String(text.dropFirst(512)))
        let midway = tree.field(text, caret: 650)
        tree.answer(midway, kAXStringForRangeParameterizedAttribute) { _ in nil }
        XCTAssertEqual(context(midway, maxChars: 100)?.textBeforeCaret, String(text.prefix(650).dropFirst(512)))
        tree.set(midway, kAXValueAttribute, nil)
        XCTAssertNil(context(midway), "neither read answers")
    }

    // The text after the caret: 192 units at most, from the field's count —
    // or, for a field that publishes none, its value's length (an empty
    // after-text would read as "the caret is at the end").
    func testTheTextAfterTheCaret() throws {
        let tail = String(repeating: "x", count: 300)
        let field = tree.field("ab" + tail, caret: 2)
        XCTAssertEqual(context(field)?.textAfterCaret, String(tail.prefix(192)))
        tree.set(field, kAXNumberOfCharactersAttribute, nil)
        XCTAssertEqual(context(field)?.textAfterCaret, String(tail.prefix(192)))
        tree.set(field, kAXValueAttribute, nil)
        XCTAssertEqual(context(field)?.textAfterCaret, "")
        let short = tree.field("ab c", caret: 3)
        XCTAssertEqual(context(short)?.textAfterCaret, "c")
    }

    // The caret AX reports after the first character is anchored on that
    // character's box: reported a line too high, it lands on the glyphs.
    func testTheCaretIsAnchoredFromTheFirstCharacter() {
        let field = tree.field("H", caret: 1)
        tree.answer(field, kAXBoundsForRangeParameterizedAttribute) { range in
            range.length == 0 ? CGRect(x: 108, y: 84, width: 1, height: 16)
                : FakeAXTree.glyphs(in: self.frame, from: range.location, count: range.length)
        }
        XCTAssertEqual(context(field)?.caretRect, AXText.flipped(CGRect(x: 108, y: 104, width: 1, height: 16)))
    }

    // No caret box at all: the caret is drawn right after the character
    // before it.
    func testAMissingCaretIsDerivedFromTheGlyphBeforeIt() {
        let field = tree.field("Hi", caret: 1)
        tree.answer(field, kAXBoundsForRangeParameterizedAttribute) { range in
            range.length == 0 ? nil : FakeAXTree.glyphs(in: self.frame, from: range.location, count: range.length)
        }
        XCTAssertEqual(context(field)?.caretRect, AXText.flipped(CGRect(x: 108, y: 104, width: 1, height: 16)))
    }

    // A caret may sit up to 50 pt off every display (a field half off
    // screen), no further.
    func testACaretJustOffScreenIsKept() throws {
        let union = NSScreen.screens.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        func read(outBy distance: CGFloat) -> CGRect? {
            // Left of every display, in Cocoa coordinates; the field reaches it.
            let cocoa = CGRect(x: union.minX - distance, y: union.midY, width: 1, height: 16)
            let ax = AXText.flipped(cocoa)
            let frame = CGRect(x: ax.minX - 10, y: ax.minY - 4, width: 400, height: 60)
            let field = tree.field("", caret: 0, frame: frame)
            tree.answer(field, kAXBoundsForRangeParameterizedAttribute) { _ in ax }
            return context(field)?.caretRect
        }
        XCTAssertNotNil(read(outBy: 20))
        XCTAssertNotNil(read(outBy: 49))
        XCTAssertNil(read(outBy: 51.5))
    }

    // A range that isn't one reads as no caret.
    func testARangeThatIsNoRangeIsNoCaret() {
        let field = tree.field("Hello")
        tree.set(field, kAXSelectedTextRangeAttribute, "not a range")
        XCTAssertNil(context(field))
    }

    // A caret is a hairline: a phantom advance width is cut back to 2 pt,
    // keeping its left edge.
    func testTheCaretIsAHairline() throws {
        let field = tree.field("", caret: 0)
        tree.answer(field, kAXBoundsForRangeParameterizedAttribute) { _ in
            CGRect(x: 120, y: 104, width: 10, height: 16)
        }
        XCTAssertEqual(context(field)?.caretRect, AXText.flipped(CGRect(x: 120, y: 104, width: 2, height: 16)))
    }

    // Garbage caret geometry — a zero rect, a sliver, a box taller than any
    // line, a caret off its field — is not trusted: the read goes to the web
    // fallback, which refuses a field this narrow. A plausible caret is read
    // natively whatever the field's width.
    func testGarbageCaretGeometryIsNotTrusted() {
        let narrow = CGRect(x: 100, y: 100, width: 20, height: 60)
        func read(_ caretRect: CGRect) -> TextContext? {
            let field = tree.field("Hi", caret: 0, frame: narrow)
            tree.answer(field, kAXBoundsForRangeParameterizedAttribute) { _ in caretRect }
            return context(field)
        }
        XCTAssertNotNil(read(CGRect(x: 104, y: 104, width: 1, height: 16)))
        XCTAssertNotNil(read(CGRect(x: 104, y: 104, width: 1, height: 4)))
        XCTAssertNotNil(read(CGRect(x: 104, y: 0, width: 1, height: 200)))
        XCTAssertNotNil(read(CGRect(x: 140, y: 104, width: 1, height: 16)), "within 24 pt of the field")
        XCTAssertNil(read(.zero))
        XCTAssertNil(read(CGRect(x: 104, y: 104, width: 1, height: 3)))
        XCTAssertNil(read(CGRect(x: 104, y: 0, width: 1, height: 201)))
        XCTAssertNil(read(CGRect(x: 150, y: 104, width: 1, height: 16)), "off the field")
        XCTAssertNil(read(CGRect(x: 104, y: 190, width: 1, height: 16)), "below the field")
        XCTAssertNotNil(read(CGRect(x: 143, y: 104, width: 1, height: 16)), "its middle 23.5 pt off")
        XCTAssertNil(read(CGRect(x: 144, y: 104, width: 1, height: 16)), "its middle 24.5 pt off")
        XCTAssertNotNil(read(CGRect(x: 104, y: 175, width: 1, height: 16)), "its middle 23 pt below")
        XCTAssertNil(read(CGRect(x: 104, y: 176, width: 1, height: 16)), "its middle 24 pt below")
    }

    // A field that reports no frame can't be checked against: its caret is
    // taken as AX gives it.
    func testAFieldWithNoFrameTakesItsCaret() throws {
        let field = tree.field("Hi", frame: .zero)
        tree.answer(field, kAXBoundsForRangeParameterizedAttribute) { _ in CGRect(x: 300, y: 300, width: 1, height: 16) }
        XCTAssertEqual(context(field)?.caretRect, AXText.flipped(CGRect(x: 300, y: 300, width: 1, height: 16)))
    }

    // The host's own font and colours, read at the character before the caret.
    func testTheHostStyleIsReadAtTheCaret() throws {
        let field = tree.field("Hello", caret: 3)
        var asked: [Int] = []
        tree.answer(field, kAXAttributedStringForRangeParameterizedAttribute) { range in
            asked.append(range.location)
            return NSAttributedString(string: "l", attributes: [
                .font: NSFont(name: "Menlo", size: 13) as Any, .foregroundColor: NSColor.red,
                .backgroundColor: NSColor.white])
        }
        let host = try XCTUnwrap(context(field)).host
        XCTAssertEqual(asked, [2])
        let start = tree.field("Hello", caret: 0)
        tree.answer(start, kAXAttributedStringForRangeParameterizedAttribute) { range in
            asked.append(range.location)
            return nil
        }
        _ = context(start)
        XCTAssertEqual(asked, [2, 0], "at the field's start, its first character")
        XCTAssertEqual(host.font?.familyName, "Menlo")
        XCTAssertEqual(host.color, .red)
        XCTAssertEqual(host.background, .white)
    }

    // A web field's style is read at the character before its caret too.
    func testAWebFieldsStyleIsReadBeforeTheCaret() {
        let field = tree.field("Hello", caret: 3, native: false)
        var asked: [Int] = []
        tree.answer(field, kAXAttributedStringForRangeParameterizedAttribute) { range in
            asked.append(range.location)
            return nil
        }
        _ = context(field)
        XCTAssertEqual(asked, [2])
    }

    // Chromium and WebKit hand back a font descriptor and CGColors under
    // the AX-prefixed keys.
    func testAWebHostStyle() {
        let field = FakeAXTree.newElement()
        func style(_ attributes: [NSAttributedString.Key: Any], at index: Int = 0) -> HostTextStyle {
            tree.answer(field, kAXAttributedStringForRangeParameterizedAttribute) { _ in
                NSAttributedString(string: "x", attributes: attributes)
            }
            return tree.reading { AXText.attributedStyle(of: field, atIndex: index) }
        }
        let fontKey = NSAttributedString.Key("AXFont")
        XCTAssertEqual(style([fontKey: ["AXFontName": "Menlo", "AXFontSize": 15]]).font?.familyName, "Menlo")
        XCTAssertEqual(style([fontKey: ["AXFontName": "Menlo", "AXFontSize": 15]]).font?.pointSize, 15)
        XCTAssertEqual(style([fontKey: ["AXFontName": "No Such Font", "AXFontSize": 15]]).font?.pointSize, 15)
        XCTAssertEqual(style([fontKey: ["AXFontSize": 15]]).font?.pointSize, 15)
        XCTAssertNil(style([fontKey: ["AXFontName": "Menlo", "AXFontSize": 0]]).font)
        let both = style([.font: NSFont.systemFont(ofSize: 11), fontKey: ["AXFontName": "Menlo", "AXFontSize": 15]])
        XCTAssertEqual(both.font?.pointSize, 11, "a real font wins over the descriptor")
        let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        let fg = style([NSAttributedString.Key("AXForegroundColor"): red])
        XCTAssertNotNil(fg.color)
        XCTAssertNil(fg.background)
        XCTAssertNotNil(style([NSAttributedString.Key("AXBackgroundColor"): red]).background)
        XCTAssertNil(style([NSAttributedString.Key("AXForegroundColor"): "red"]).color, "not a colour")
        XCTAssertTrue(style([.font: NSFont.systemFont(ofSize: 12)], at: -1).isEmpty)
        tree.answer(field, kAXAttributedStringForRangeParameterizedAttribute) { _ in NSAttributedString() }
        XCTAssertTrue(tree.reading { AXText.attributedStyle(of: field, atIndex: 0) }.isEmpty)
    }

    // MARK: - A web field

    // A web field's caret geometry is garbage, its value is the text: split
    // at a plausible caret, or at the end for a caret stuck at 0.
    func testAWebFieldIsReadFromItsValue() throws {
        let stuck = try XCTUnwrap(context(tree.field("Hello world", caret: 0, native: false)))
        XCTAssertEqual(stuck.textBeforeCaret, "Hello world")
        XCTAssertEqual(stuck.textAfterCaret, "")
        XCTAssertNotNil(stuck.caretRect)
        XCTAssertEqual(stuck.host.font?.pointSize, 17, "guessed from the field's height")
        XCTAssertEqual(stuck.host.fieldRect, AXText.flipped(frame))

        let mid = try XCTUnwrap(context(tree.field("Hello world", caret: 5, native: false)))
        XCTAssertEqual(mid.textBeforeCaret, "Hello")
        XCTAssertEqual(mid.textAfterCaret, " world")
        XCTAssertTrue(mid.host.textFollowsCaret)
        XCTAssertEqual(context(tree.field("Hello world", caret: 11, native: false))?.textBeforeCaret, "Hello world")
        XCTAssertEqual(context(tree.field("Hello world", caret: 40, native: false))?.textBeforeCaret, "Hello world")
        XCTAssertEqual(context(tree.field("Hello", caret: 1, native: false))?.textBeforeCaret, "H",
                       "a caret at 1 is a caret")
        XCTAssertNotNil(context(tree.field("Hi", frame: CGRect(x: 100, y: 100, width: 400, height: 1), native: false)),
                        "a hairline-high box is still a box")
        let low = try XCTUnwrap(context(tree.field("Hi", frame: CGRect(x: 100, y: 100, width: 400, height: 30), native: false)))
        XCTAssertEqual(low.host.font?.pointSize, 12, "never under 12 pt")
    }

    // A web field's text after the caret is 192 characters at most; a field
    // box is reported only above 20 × 4 pt.
    func testAWebFieldsAfterTextAndBox() throws {
        let tail = String(repeating: "x", count: 300)
        let web = try XCTUnwrap(context(tree.field("ab" + tail, caret: 2, native: false)))
        XCTAssertEqual(web.textAfterCaret, String(tail.prefix(192)))
        XCTAssertNil(try XCTUnwrap(context(tree.field("Hi", frame: CGRect(x: 100, y: 100, width: 400, height: 4))))
            .host.fieldRect, "4 pt high")
        XCTAssertNotNil(try XCTUnwrap(context(tree.field("Hi", frame: CGRect(x: 100, y: 100, width: 400, height: 5))))
            .host.fieldRect)
        XCTAssertNil(try XCTUnwrap(context(tree.field("Hi", frame: CGRect(x: 100, y: 100, width: 20, height: 60))))
            .host.fieldRect, "20 pt wide")
    }

    // Too small to be a field, or nothing in it: nothing to continue — but
    // an empty box is the reply's whole case.
    func testAnEmptyOrTinyWebField() throws {
        XCTAssertNil(context(tree.field("Hi", frame: CGRect(x: 100, y: 100, width: 20, height: 60), native: false)))
        XCTAssertNil(context(tree.field("Hi", frame: CGRect(x: 100, y: 100, width: 400, height: 0), native: false)))
        XCTAssertNotNil(context(tree.field("Hi", frame: CGRect(x: 100, y: 100, width: 21, height: 60), native: false)))
        let empty = tree.field("", native: false)
        XCTAssertNil(context(empty))
        let reply = try XCTUnwrap(context(empty, allowEmpty: true))
        XCTAssertEqual(reply.textBeforeCaret, "")
        tree.set(empty, kAXValueAttribute, nil)
        XCTAssertNil(context(empty))
        XCTAssertEqual(context(empty, allowEmpty: true)?.textBeforeCaret, "")
    }

    // An empty value with characters behind it: the ranged read gets them.
    func testAWebValueReadByRange() {
        let field = tree.field("Hello world", caret: 0, native: false)
        tree.set(field, kAXValueAttribute, "")
        XCTAssertEqual(context(field)?.textBeforeCaret, "Hello world")
        // A long one: the range read starts in the text, and the window is
        // counted from the field's start, not the read's.
        let text = String(repeating: "abcdefghij", count: 200)
        let long = tree.field(text, caret: 0, native: false)
        tree.set(long, kAXValueAttribute, "")
        XCTAssertEqual(context(long)?.textBeforeCaret, String(text.dropFirst(512)))
        tree.set(field, kAXNumberOfCharactersAttribute, 0)
        XCTAssertNil(context(field))
    }

    // A placeholder shown as the value is no text — and, for a reply, an
    // empty box.
    func testAPlaceholderIsNoText() {
        let field = tree.field(" Type / for commands", native: false)
        tree.set(field, kAXPlaceholderValueAttribute, "Type / for commands ")
        XCTAssertNil(context(field))
        XCTAssertEqual(context(field, allowEmpty: true)?.textBeforeCaret, "")
        tree.set(field, kAXPlaceholderValueAttribute, "Message")
        XCTAssertEqual(context(field)?.textBeforeCaret, " Type / for commands")
        tree.set(field, kAXPlaceholderValueAttribute, "")
        XCTAssertNotNil(context(field))
    }

    /// A text marker whose bounds are `rect`.
    private func mark(_ field: AXUIElement, _ rect: CGRect) {
        tree.set(field, "AXSelectedTextMarkerRange", "marker")
        tree.answerMarker(field, "AXBoundsForTextMarkerRange") { _ in rect }
    }

    // Chromium's text marker is the real caret where the range APIs return
    // garbage: a hairline inside the field is placed exactly.
    func testTheTextMarkerIsTheWebCaret() throws {
        let field = tree.field("Hello", caret: 0, native: false)
        mark(field, CGRect(x: 150, y: 110, width: 1, height: 18))
        let read = try XCTUnwrap(context(field))
        XCTAssertEqual(read.caretRect, AXText.flipped(CGRect(x: 150, y: 110, width: 1, height: 18)))
        XCTAssertEqual(read.host.font?.pointSize ?? 0, 18 / 1.18, accuracy: 0.01)
        XCTAssertEqual(read.textBeforeCaret, "Hello")
        mark(field, .zero)
        XCTAssertNotEqual(try XCTUnwrap(context(field)).caretRect,
                          AXText.flipped(CGRect(x: 150, y: 110, width: 1, height: 18)), "a zero marker is none")
        XCTAssertNil(tree.reading { AXText.webCaretBounds(field) })
    }

    // A marker spanning a run is a selection — or, untouched with nothing
    // selected, the placeholder of an idle box, which a reply reads as empty
    // and anchors at the run.
    func testAMarkerSpanningARun() throws {
        let field = tree.field("Describe what you want", caret: 0, native: false)
        let run = CGRect(x: 104, y: 104, width: 276, height: 21)
        mark(field, run)
        XCTAssertNil(context(field))
        let reply = try XCTUnwrap(context(field, allowEmpty: true))
        XCTAssertEqual(reply.textBeforeCaret, "")
        XCTAssertEqual(reply.textAfterCaret, "")
        XCTAssertEqual(reply.caretRect, AXText.flipped(CGRect(x: 104, y: 104, width: 1, height: 21)))
        tree.set(field, kAXSelectedTextAttribute, "Describe")
        XCTAssertNil(context(field, allowEmpty: true), "a selection")
    }

    // With no marker the caret is estimated at the end of the text before
    // it, on its own line counted up from the bottom.
    func testTheEstimatedWebCaret() throws {
        let end = try XCTUnwrap(context(tree.field("Hello\nworld", native: false)))
        let mid = try XCTUnwrap(context(tree.field("Hello\nworld", caret: 5, native: false)))
        let font = NSFont.systemFont(ofSize: 17)
        let lineHeight = ceil(17 * 1.35)
        let world = ("world" as NSString).size(withAttributes: [.font: font]).width
        XCTAssertEqual(end.caretRect, AXText.flipped(CGRect(x: frame.minX + 8 + world, y: frame.maxY - lineHeight - 4,
                                                            width: 1, height: lineHeight)))
        XCTAssertEqual(try XCTUnwrap(mid.caretRect).minY - (try XCTUnwrap(end.caretRect).minY), lineHeight,
                       "a line up for the line after it")
        let long = try XCTUnwrap(context(tree.field(String(repeating: "W", count: 39), native: false)))
        XCTAssertEqual(long.caretRect?.minX, frame.maxX - 24, "never past the field's end")
    }

    // MARK: - Terminals

    private let rule = String(repeating: "─", count: 40)

    // A terminal is text only inside an agent's input box: a shell prompt
    // reads nothing; the box reads as what is typed in it.
    func testATerminalReadsOnlyAnAgentsBox() throws {
        let shell = tree.field("~ % git sta\n\n")
        tree.set(shell, kAXSelectedTextRangeAttribute, CFRange(location: 11, length: 0))
        tree.belongs(shell, to: "com.apple.Terminal")
        XCTAssertNil(context(shell))
        XCTAssertTrue(tree.reading { AXText.isTerminalField(shell) })

        let box = "\(rule)\n❯ fix the test"
        let agent = tree.field(box + "\n\(rule)\n  ⏵⏵ auto mode on", caret: (box as NSString).length)
        tree.belongs(agent, to: "com.apple.Terminal")
        XCTAssertEqual(context(agent)?.textBeforeCaret, "fix the test")

        let plain = tree.field(box + "\n\(rule)\n", caret: (box as NSString).length)
        XCTAssertEqual(context(plain)?.textBeforeCaret, box, "outside a terminal the box is plain text")
        XCTAssertFalse(tree.reading { AXText.isTerminalField(plain) })
    }

    // A field's kind is asked once — a definite answer is kept for its life,
    // a read that timed out is asked again.
    func testAFieldsKindIsAskedOnce() {
        let field = tree.field("Hello")
        _ = context(field)
        _ = context(field)
        XCTAssertEqual(tree.reads(field, "AXDOMClassList"), 1)
        let slow = tree.field("Hello")
        tree.fail(slow, "AXDOMClassList", .cannotComplete)
        _ = context(slow)
        _ = context(slow)
        XCTAssertEqual(tree.reads(slow, "AXDOMClassList"), 2)
    }

    // The rule check under the caret: a selection is no caret, a read it
    // can't make leaves the decision to the full read.
    func testTheRuleUnderTheCaret() {
        let box = "\(rule)\n❯ fix"
        let field = tree.field(box + "\n\(rule)\n", caret: (box as NSString).length)
        tree.belongs(field, to: "com.googlecode.iterm2")
        XCTAssertNotNil(context(field))
        tree.set(field, kAXSelectedTextRangeAttribute, CFRange(location: 3, length: 2))
        XCTAssertNil(context(field))
        let atEnd = tree.field(box)
        tree.belongs(atEnd, to: "com.googlecode.iterm2")
        XCTAssertNil(context(atEnd), "nothing after the caret")
        let lastLine = tree.field(box + "\n" + rule, caret: (box as NSString).length)
        tree.belongs(lastLine, to: "com.googlecode.iterm2")
        XCTAssertEqual(context(lastLine)?.textBeforeCaret, "fix", "the closing rule is the field's last line")
        let uncounted = tree.field(box + "\n" + rule + "\n", caret: (box as NSString).length)
        tree.belongs(uncounted, to: "com.googlecode.iterm2")
        tree.set(uncounted, kAXNumberOfCharactersAttribute, nil)
        XCTAssertEqual(context(uncounted)?.textBeforeCaret, "fix", "no count: the full read decides")
    }

    // MARK: - xterm.js

    /// An xterm.js terminal: its hidden helper textarea parked on the
    /// cursor cell, and the screen's rows in an accessibility tree beside it
    /// — 10×20 pt cells from (100, 100).
    /// The screen's container, whose children the walk to the rows reads.
    private var xtermRoot: AXUIElement?

    private func xterm(_ rows: [String], cursor: (row: Int, column: Int)) -> AXUIElement {
        let helper = FakeAXTree.newElement(), parent = FakeAXTree.newElement()
        let screen = FakeAXTree.newElement(), root = FakeAXTree.newElement()
        let a11y = FakeAXTree.newElement(), rowTree = FakeAXTree.newElement()
        tree.set(helper, "AXDOMClassList", ["xterm-helper-textarea"])
        tree.set(helper, kAXPositionAttribute, CGPoint(x: 100 + 10 * cursor.column, y: 100 + 20 * cursor.row))
        tree.set(helper, kAXSizeAttribute, CGSize(width: 1, height: 20))
        tree.set(helper, kAXParentAttribute, parent)
        tree.set(parent, kAXParentAttribute, screen)
        tree.set(screen, kAXParentAttribute, root)
        tree.set(screen, kAXPositionAttribute, CGPoint(x: 100, y: 100))
        tree.set(screen, kAXSizeAttribute, CGSize(width: 400, height: 20 * rows.count))
        let other = FakeAXTree.newElement()
        tree.set(other, "AXDOMClassList", ["xterm-screen"])
        tree.set(a11y, "AXDOMClassList", ["xterm-accessibility"])
        tree.set(root, kAXChildrenAttribute, [other, a11y])
        xtermRoot = root
        tree.set(a11y, kAXChildrenAttribute, [rowTree])
        let rowElements = rows.map { text -> AXUIElement in
            let row = FakeAXTree.newElement(), cell = FakeAXTree.newElement()
            tree.set(row, kAXChildrenAttribute, [cell])
            tree.set(cell, kAXValueAttribute, text)
            return row
        }
        tree.set(rowTree, kAXChildrenAttribute, rowElements)
        return helper
    }

    // xterm.js in an editor (VS Code, Cursor): only an agent's input box is
    // text; the box is rebuilt from the rows around the cursor.
    func testAnXtermReadsOnlyAnAgentsBox() throws {
        let rule = String(repeating: "─", count: 40)
        let rows = ["$ make", "ok", rule, "❯ fix the test", rule, "  ⏵⏵ auto mode on"]
        let helper = xterm(rows, cursor: (3, 14))
        XCTAssertTrue(tree.reading { AXText.isTerminalField(helper) })
        let read = try XCTUnwrap(context(helper))
        XCTAssertEqual(read.textBeforeCaret, "fix the test")
        XCTAssertEqual(read.caretRect, AXText.flipped(CGRect(x: 240, y: 160, width: 1, height: 20)))
        let root = try XCTUnwrap(xtermRoot)
        XCTAssertEqual(tree.reads(root, kAXChildrenAttribute), 1)
        XCTAssertEqual(context(helper)?.textBeforeCaret, "fix the test")
        XCTAssertEqual(tree.reads(root, kAXChildrenAttribute), 1, "the nodes found once are kept")

        let wrapped = xterm([rule, "❯ fix the flaky test in", "  the dictation controller", rule, ""],
                            cursor: (2, 26))
        XCTAssertEqual(context(wrapped)?.textBeforeCaret, "fix the flaky test in\nthe dictation controller",
                       "the rows over the caret line, up to the prompt")

        XCTAssertNil(context(xterm([rule, "❯ ", rule], cursor: (1, 0))), "before the prompt glyph")
        let midInput = xterm(rows, cursor: (3, 6))
        XCTAssertNil(context(midInput), "the caret mid-input is no end of a box")

        let atTheBottom = xterm(["$ make", rule, "❯ fix it", rule], cursor: (2, 8))
        XCTAssertEqual(context(atTheBottom)?.textBeforeCaret, "fix it", "the closing rule on the last row")

        XCTAssertNil(context(xterm(["$ make", "ok", "$ git sta", "", ""], cursor: (2, 9))), "a shell")
        XCTAssertNil(context(xterm(["$ make", rule, "❯ fix"], cursor: (2, 5))), "no row under the cursor")
        let tiny = xterm(rows, cursor: (3, 14))
        tree.set(tiny, kAXSizeAttribute, CGSize(width: 1, height: 3))
        XCTAssertNil(context(tiny), "a cell under 4 pt is no cursor")
    }

    // MARK: - Selections

    func testASelectionIsReadWithItsBox() throws {
        let field = tree.field("Hello world")
        tree.set(field, kAXSelectedTextRangeAttribute, CFRange(location: 0, length: 5))
        tree.set(field, kAXSelectedTextAttribute, "Hello")
        let info = try XCTUnwrap(tree.reading { AXText.selectionInfo(for: field) })
        XCTAssertEqual(info.text, "Hello")
        XCTAssertEqual(info.rect, AXText.flipped(FakeAXTree.glyphs(in: frame, from: 0, count: 5)))

        // A box AX gets wrong falls back to the text marker, then to none.
        tree.answer(field, kAXBoundsForRangeParameterizedAttribute) { _ in CGRect(x: 0, y: 0, width: 40, height: 16) }
        XCTAssertNil(tree.reading { AXText.selectionInfo(for: field) }?.rect)
        mark(field, CGRect(x: 104, y: 104, width: 40, height: 16))
        XCTAssertEqual(tree.reading { AXText.selectionInfo(for: field) }?.rect,
                       AXText.flipped(CGRect(x: 104, y: 104, width: 40, height: 16)))
        mark(field, CGRect(x: 104, y: 104, width: 40, height: 3))
        XCTAssertNil(tree.reading { AXText.selectionInfo(for: field) }?.rect)
    }

    // One character selected is a selection.
    func testOneCharacterIsASelection() {
        let field = tree.field("Hello")
        tree.set(field, kAXSelectedTextRangeAttribute, CFRange(location: 0, length: 1))
        tree.set(field, kAXSelectedTextAttribute, "H")
        XCTAssertEqual(tree.reading { AXText.selectionInfo(for: field) }?.text, "H")
    }

    func testWhatIsNoSelection() {
        let field = tree.field("Hello world")
        tree.set(field, kAXSelectedTextRangeAttribute, CFRange(location: 0, length: 5))
        tree.set(field, kAXSelectedTextAttribute, "Hello")
        XCTAssertNotNil(tree.reading { AXText.selectionInfo(for: field) })
        tree.secureInput = true
        XCTAssertNil(tree.reading { AXText.selectionInfo(for: field) })
        tree.secureInput = false
        tree.set(field, "AXTextInputMarkedRange", CFRange(location: 0, length: 5))
        XCTAssertNil(tree.reading { AXText.selectionInfo(for: field) }, "an IME's marked text")
        tree.set(field, "AXTextInputMarkedRange", CFRange(location: 0, length: 0))
        tree.set(field, kAXSelectedTextAttribute, "•••")
        XCTAssertNil(tree.reading { AXText.selectionInfo(for: field) })
        tree.set(field, kAXSelectedTextAttribute, "")
        XCTAssertNil(tree.reading { AXText.selectionInfo(for: field) })
        tree.set(field, kAXSelectedTextAttribute, "Hello")
        tree.set(field, kAXSelectedTextRangeAttribute, CFRange(location: 5, length: 0))
        XCTAssertNil(tree.reading { AXText.selectionInfo(for: field) })
    }

    // MARK: - Which elements are fields

    func testAnEditableFieldAndItsLabel() {
        func label(_ element: AXUIElement) -> String?? { tree.reading { AXText.editableTextLabel(element) } }
        let field = tree.field("x", role: "AXTextField")
        XCTAssertEqual(label(field), .some(nil), "editable, no label")
        tree.set(field, kAXTitleAttribute, "  ")
        tree.set(field, kAXDescriptionAttribute, "Subject")
        tree.set(field, kAXPlaceholderValueAttribute, "Write here")
        XCTAssertEqual(label(field), .some("Subject"))
        tree.set(field, kAXTitleAttribute, "To")
        XCTAssertEqual(label(field), .some("To"))
        tree.set(field, kAXTitleAttribute, nil)
        tree.set(field, kAXDescriptionAttribute, nil)
        XCTAssertEqual(label(field), .some("Write here"))
        tree.set(field, kAXPlaceholderValueAttribute, "Enter your Password")
        XCTAssertNil(label(field), "a web password input")
        tree.set(field, kAXPlaceholderValueAttribute, "Пароль")
        XCTAssertNil(label(field))
        tree.set(field, kAXPlaceholderValueAttribute, nil)
        tree.set(field, kAXSubroleAttribute, "AXSecureTextField")
        XCTAssertNil(label(field))
        tree.set(field, kAXSubroleAttribute, "AXSearchField")
        XCTAssertNotNil(label(field))

        XCTAssertNotNil(label(tree.field("x", role: "AXComboBox")))
        XCTAssertNil(label(tree.field("x", role: "AXButton")), "Chromium reports a range on buttons too")
        let noRange = tree.field("x")
        tree.set(noRange, kAXSelectedTextRangeAttribute, nil)
        XCTAssertNil(label(noRange))
    }

    // The system-wide fallback: the focused element when it is a field, and
    // a field already known editable without asking again.
    func testTheSystemsFocusedField() {
        let system = AXUIElementCreateSystemWide()
        let field = tree.field("x")
        XCTAssertNil(tree.reading { AXText.systemFocusedTextElement() })
        tree.set(system, kAXFocusedUIElementAttribute, field)
        XCTAssertEqual(tree.reading { AXText.systemFocusedTextElement() }, field)
        tree.set(field, kAXRoleAttribute, "AXButton")
        XCTAssertNil(tree.reading { AXText.systemFocusedTextElement() })
        XCTAssertEqual(tree.reading { AXText.systemFocusedTextElement(knownEditable: field) }, field)
        XCTAssertNil(tree.reading { AXText.systemFocusedTextElement(knownEditable: tree.field("y")) })
        tree.set(system, kAXFocusedUIElementAttribute, "not an element")
        XCTAssertNil(tree.reading { AXText.systemFocusedTextElement() })
    }

    // The page a field is on: the outermost web area's http(s) host, up to
    // the window.
    func testThePageHost() {
        let field = FakeAXTree.newElement(), group = FakeAXTree.newElement()
        let frameArea = FakeAXTree.newElement(), page = FakeAXTree.newElement()
        let window = FakeAXTree.newElement(), above = FakeAXTree.newElement()
        tree.set(field, kAXParentAttribute, group)
        tree.set(group, kAXParentAttribute, frameArea)
        tree.set(frameArea, kAXRoleAttribute, "AXWebArea")
        tree.set(frameArea, "AXURL", URL(string: "https://ads.example.net/frame"))
        tree.set(frameArea, kAXParentAttribute, page)
        tree.set(page, kAXRoleAttribute, "AXWebArea")
        tree.set(page, "AXURL", URL(string: "https://WWW.Mail.Example.com/inbox"))
        tree.set(page, kAXParentAttribute, window)
        tree.set(window, kAXRoleAttribute, kAXWindowRole)
        tree.set(window, kAXParentAttribute, above)
        tree.set(above, kAXRoleAttribute, "AXWebArea")
        tree.set(above, "AXURL", URL(string: "https://outside.example.org"))
        XCTAssertEqual(tree.reading { AXText.pageHost(for: field) }, "mail.example.com")
        tree.set(page, "AXURL", URL(string: "file:///Users/me/page.html"))
        XCTAssertEqual(tree.reading { AXText.pageHost(for: field) }, "ads.example.net")
        tree.set(frameArea, "AXURL", URL(string: "http://example.net"))
        XCTAssertEqual(tree.reading { AXText.pageHost(for: field) }, "example.net")
        tree.set(window, kAXRoleAttribute, kAXApplicationRole)
        XCTAssertEqual(tree.reading { AXText.pageHost(for: field) }, "example.net", "nothing above the app is a page")
        XCTAssertNil(tree.reading { AXText.pageHost(for: FakeAXTree.newElement()) })
    }

    // The walk up to the page stops after 60 ancestors.
    func testThePageHostWalkIsBounded() {
        func chain(webAreaAt depth: Int) -> AXUIElement {
            let nodes = (0...depth).map { _ in FakeAXTree.newElement() }
            for (child, parent) in zip(nodes, nodes.dropFirst()) { tree.set(child, kAXParentAttribute, parent) }
            tree.set(nodes[depth], kAXRoleAttribute, "AXWebArea")
            tree.set(nodes[depth], "AXURL", URL(string: "https://deep.example.com"))
            return nodes[0]
        }
        XCTAssertEqual(tree.reading { AXText.pageHost(for: chain(webAreaAt: 59)) }, "deep.example.com")
        XCTAssertNil(tree.reading { AXText.pageHost(for: chain(webAreaAt: 60)) })
    }

    // Only an element the app destroyed is dead; a slow or odd answer isn't.
    func testADeadElement() {
        let field = tree.field("x")
        XCTAssertFalse(tree.reading { AXText.isDead(field) })
        tree.fail(field, kAXRoleAttribute, .cannotComplete)
        XCTAssertFalse(tree.reading { AXText.isDead(field) })
        tree.fail(field, kAXRoleAttribute, .invalidUIElement)
        XCTAssertTrue(tree.reading { AXText.isDead(field) })
    }

    // AX's top-left origin flips onto Cocoa's bottom-left one about the
    // primary display, and back.
    func testTheFlipIsItsOwnInverse() throws {
        let primary = try XCTUnwrap(NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first)
        let rect = CGRect(x: 10, y: 20, width: 30, height: 40)
        XCTAssertEqual(AXText.flipped(rect), CGRect(x: 10, y: primary.frame.height - 60, width: 30, height: 40))
        XCTAssertEqual(AXText.flipped(AXText.flipped(rect)), rect)
    }
}
