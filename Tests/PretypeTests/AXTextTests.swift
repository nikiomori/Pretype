import Carbon
import CoreGraphics
import XCTest
@testable import Pretype

final class AXTextTests: XCTestCase {
    // A web password field that slips past every other guard still renders
    // mask glyphs: three or more of them, and nothing else, is never text.
    func testMaskGlyphsAreNeverText() {
        for masked in ["•••", "●●●●", "∙∙∙", "***", "•*●∙"] { XCTAssertTrue(AXText.looksMasked(masked), masked) }
        for text in ["", "•", "••", "**", "a••", "•• ", "abc", "3 * 4"] { XCTAssertFalse(AXText.looksMasked(text), text) }
    }

    // The AX read window's start holds while the user types (so the ghost's
    // anchor and apply's prefix checks survive a long document), moves in 512
    // steps, and never lands inside a surrogate pair or composed character.
    func testAXWindowStartHoldsAndStepsOffSplitCharacters() {
        XCTAssertEqual(AXText.windowStart(caret: 900, maxChars: 1200), 0)
        XCTAssertEqual(Set((1200 ... 1711).map { AXText.windowStart(caret: $0, maxChars: 1200) }), [0])
        XCTAssertEqual(AXText.windowStart(caret: 1712, maxChars: 1200), 512)
        // 7 UTF-16 units a group; the 5-unit pad puts unit 512 on 😀's low half.
        let doc = ("12345" + String(repeating: "ab😀e\u{301} ", count: 400)) as NSString
        var previous: String?
        for caret in stride(from: 1720, to: 2224, by: 35) {   // group boundaries, start = 512
            let window = AXText.substring(doc.substring(to: caret) as NSString,
                                          from: AXText.windowStart(caret: caret, maxChars: 1200))
            XCTAssertTrue(window.hasPrefix("e\u{301} ab"), String(window.prefix(4)))
            if let previous { XCTAssertTrue(window.hasPrefix(previous)) }
            previous = window
        }
        XCTAssertEqual(AXText.substring("ab😀cd", from: 3), "cd")        // inside the surrogate pair
        XCTAssertEqual(AXText.substring("ab😀cd", from: 2), "😀cd")
        XCTAssertEqual(AXText.substring("ae\u{301}x", from: 2), "x")    // inside e + combining acute
        XCTAssertEqual(AXText.substring("abc", from: 3), "")
        XCTAssertEqual(AXText.substring("abc", from: 5), "")
        XCTAssertEqual(AXText.substring("abc", from: -2), "abc")
    }

    // The web fallback's ranged read covers the caret's window, not the
    // field's first `maxChars` units — past those, the model was continuing
    // the middle of a long draft at the real caret.
    func testWebFallbackReadsTheWindowAtTheCaret() {
        func covers(_ range: CFRange, _ units: ClosedRange<Int>) -> Bool {
            range.location <= units.lowerBound && units.upperBound <= range.location + range.length
        }
        let mid = AXText.webReadRange(caret: 5_000, total: 6_000, maxChars: 1_200)
        XCTAssertTrue(covers(mid, 3_800 ... 5_192), "\(mid)")
        XCTAssertEqual(mid.location, AXText.windowStart(caret: 5_000, maxChars: 1_200) - 16)
        let stuck = AXText.webReadRange(caret: 0, total: 6_000, maxChars: 1_200)   // stuck at 0 = the end
        XCTAssertTrue(covers(stuck, 4_800 ... 6_000), "\(stuck)")
        XCTAssertEqual(AXText.webReadRange(caret: 0, total: 300, maxChars: 1_200).location, 0)
        XCTAssertEqual(AXText.webReadRange(caret: 0, total: 300, maxChars: 1_200).length, 300)
        // A caret at 1 is a caret, not the stuck-at-0 breakage; one at the end is the end.
        XCTAssertEqual(AXText.webReadRange(caret: 1, total: 6_000, maxChars: 1_200).length, 193)
        XCTAssertEqual(AXText.webReadRange(caret: 6_000, total: 6_000, maxChars: 1_200).location, 4_592)
    }

    // Inline ghost text may only draw where the line is empty; mid-line it lands
    // on top of the user's own words.
    func testLinePopulatedAfterCaret() {
        XCTAssertFalse(AXText.linePopulatedAfterCaret(""))
        XCTAssertFalse(AXText.linePopulatedAfterCaret("   "))          // trailing spaces
        XCTAssertFalse(AXText.linePopulatedAfterCaret("\nnext line"))  // end of THIS line
        XCTAssertFalse(AXText.linePopulatedAfterCaret("  \n more"))
        XCTAssertTrue(AXText.linePopulatedAfterCaret(" ответ"))
        XCTAssertTrue(AXText.linePopulatedAfterCaret("rest of the line\nmore"))
    }

    // The caret box AX reports is app lore; the previous glyph's box is
    // measured truth. This anchoring is what the ghost's baseline stands on.
    // AX coordinates: top-left origin, y grows downward.
    func testGlyphAnchoredCaret() {
        let prev = CGRect(x: 100, y: 50, width: 8, height: 16)
        // Missing caret rect → derived from the glyph box.
        XCTAssertEqual(AXText.glyphAnchoredCaret(reported: nil, prevChar: prev),
                       CGRect(x: 108, y: 50, width: 1, height: 16))
        // Zero-size rect at a nonsense y (Terminal.app) → missing, too.
        XCTAssertEqual(AXText.glyphAnchoredCaret(reported: CGRect(x: 0, y: 1329, width: 0, height: 0), prevChar: prev),
                       CGRect(x: 108, y: 50, width: 1, height: 16))
        // Reported a line ABOVE the glyphs (TextEdit) → rewritten onto them.
        XCTAssertEqual(AXText.glyphAnchoredCaret(reported: CGRect(x: 108, y: 30, width: 1, height: 16),
                                                 prevChar: prev),
                       CGRect(x: 108, y: 50, width: 1, height: 16))
        // BELOW the glyphs is a legitimate line start — kept as reported.
        XCTAssertEqual(AXText.glyphAnchoredCaret(reported: CGRect(x: 10, y: 66, width: 1, height: 16),
                                                 prevChar: prev),
                       CGRect(x: 10, y: 66, width: 1, height: 16))
        // Same line, cap-height sliver (bottom = baseline): keep x, adopt the
        // glyph box's vertical span.
        XCTAssertEqual(AXText.glyphAnchoredCaret(reported: CGRect(x: 108, y: 54, width: 1, height: 9),
                                                 prevChar: prev),
                       CGRect(x: 108, y: 50, width: 1, height: 16))
        // Identical span → untouched; no glyph info → reported wins.
        XCTAssertEqual(AXText.glyphAnchoredCaret(reported: CGRect(x: 108, y: 50, width: 1, height: 16),
                                                 prevChar: prev),
                       CGRect(x: 108, y: 50, width: 1, height: 16))
        XCTAssertEqual(AXText.glyphAnchoredCaret(reported: CGRect(x: 5, y: 5, width: 1, height: 12),
                                                 prevChar: nil),
                       CGRect(x: 5, y: 5, width: 1, height: 12))
        XCTAssertNil(AXText.glyphAnchoredCaret(reported: nil, prevChar: .zero))
        // The edges: a glyph box under 4 pt is none; a caret a point above the
        // glyphs is on them; overlapping by a point is not overlapping; a
        // span off by a point in all is the same span.
        XCTAssertEqual(AXText.glyphAnchoredCaret(reported: CGRect(x: 5, y: 5, width: 1, height: 12),
                                                 prevChar: CGRect(x: 100, y: 50, width: 8, height: 3)),
                       CGRect(x: 5, y: 5, width: 1, height: 12))
        XCTAssertEqual(AXText.glyphAnchoredCaret(reported: CGRect(x: 108, y: 49, width: 1, height: 2), prevChar: prev),
                       CGRect(x: 108, y: 49, width: 1, height: 2), "ends where the glyphs begin, plus a point")
        XCTAssertEqual(AXText.glyphAnchoredCaret(reported: CGRect(x: 108, y: 48.5, width: 1, height: 16), prevChar: prev),
                       CGRect(x: 108, y: 50, width: 1, height: 16), "over a point above: off the line")
        XCTAssertEqual(AXText.glyphAnchoredCaret(reported: CGRect(x: 108, y: 65, width: 1, height: 16), prevChar: prev),
                       CGRect(x: 108, y: 65, width: 1, height: 16), "starts where the glyphs end, less a point")
        XCTAssertEqual(AXText.glyphAnchoredCaret(reported: CGRect(x: 108, y: 51, width: 1, height: 16), prevChar: prev),
                       CGRect(x: 108, y: 51, width: 1, height: 16), "a point off in all")
        XCTAssertEqual(AXText.glyphAnchoredCaret(reported: CGRect(x: 108, y: 51, width: 1, height: 16.5), prevChar: prev),
                       CGRect(x: 108, y: 50, width: 1, height: 16))
    }

    // Suppressing suggestions while an IME composes is all-or-nothing per input
    // source in the apps that don't expose a marked range, so the classification
    // decides whether a Japanese user keeps Tab for the English half of their day.
    func testCompositionInputModeClassification() {
        let mode = kTISTypeKeyboardInputMode as String
        let layout = kTISTypeKeyboardLayout as String

        // Every real IME input mode composes: half-typed romanisation in the
        // field, candidate window owning Tab.
        for modeID in ["com.apple.inputmethod.SCIM.ITABC",           // Pinyin – Simplified
                       "com.apple.inputmethod.Japanese",             // Kotoeri, kana
                       "com.apple.inputmethod.Korean.2SetKorean",    // Hangul
                       "com.apple.inputmethod.VietnameseTelex",      // Telex
                       "com.apple.inputmethod.TransliterationIM.hi"] // Hindi transliteration
        {
            XCTAssertTrue(AXText.isCompositionInputMode(type: mode, modeID: modeID), modeID)
        }

        // The one input mode that does not compose: a Japanese IME's
        // alphanumeric sub-mode reports exactly this for both Romaji and Kana
        // typing — the carve-out that keeps Tab alive for English.
        XCTAssertFalse(AXText.isCompositionInputMode(type: mode, modeID: "com.apple.inputmethod.Roman"))

        // A plain keyboard layout (ABC, "Russian – PC") never composes.
        XCTAssertFalse(AXText.isCompositionInputMode(type: layout, modeID: nil))
        XCTAssertFalse(AXText.isCompositionInputMode(type: layout, modeID: "com.apple.keylayout.ABC"))
    }

    // Chromium's text-marker rect is the only caret Electron gives us, and the
    // reply flow's whole case — an empty chat box — is the one state where that
    // rect spans a run instead of collapsing. Measured off Claude Desktop:
    // field (21,1181 276×63), marker (21,1181 276×21), value = the placeholder.
    func testElectronMarkerCaretVersusIdleBox() {
        let field = CGRect(x: 21, y: 1181, width: 276, height: 63)
        // A hairline of text height inside the field is the real cursor.
        XCTAssertTrue(AXText.isCollapsedCaret(CGRect(x: 40, y: 1183, width: 1, height: 17), in: field))
        // The placeholder's whole run is not — nor is a rect off in a corner,
        // nor a full-height "caret" taller than the field.
        XCTAssertFalse(AXText.isCollapsedCaret(CGRect(x: 21, y: 1181, width: 276, height: 21), in: field))
        XCTAssertFalse(AXText.isCollapsedCaret(CGRect(x: 0, y: 39, width: 0, height: 0), in: field))
        XCTAssertFalse(AXText.isCollapsedCaret(CGRect(x: 40, y: 1183, width: 1, height: 200), in: field))
        // The edges: under 4 pt wide, 6 pt tall to the field's height plus 4,
        // its middle within 4 pt of the field (12 to the right).
        let box = CGRect(x: 100, y: 100, width: 200, height: 20)
        func caret(x: CGFloat = 150, midY: CGFloat = 110, width: CGFloat = 1, height: CGFloat = 16) -> Bool {
            AXText.isCollapsedCaret(CGRect(x: x - width / 2, y: midY - height / 2, width: width, height: height), in: box)
        }
        XCTAssertTrue(caret(width: 3.9))
        XCTAssertFalse(caret(width: 4))
        XCTAssertTrue(caret(height: 6))
        XCTAssertFalse(caret(height: 5.9))
        XCTAssertTrue(caret(height: 24))
        XCTAssertFalse(caret(height: 24.1))
        XCTAssertTrue(caret(x: 96))
        XCTAssertFalse(caret(x: 95.9))
        XCTAssertTrue(caret(x: 312))
        XCTAssertFalse(caret(x: 312.1))
        XCTAssertTrue(caret(midY: 96))
        XCTAssertFalse(caret(midY: 95.9))
        XCTAssertTrue(caret(midY: 124))
        XCTAssertFalse(caret(midY: 124.1))

        // Idle box vs selection, given such a run: only the reply flow asks, and
        // only an untouched caret with no selected text answers yes.
        XCTAssertTrue(AXText.markerMeansIdleBox(allowEmpty: true, selectedText: nil, caret: 0))
        XCTAssertTrue(AXText.markerMeansIdleBox(allowEmpty: true, selectedText: "", caret: 0))
        XCTAssertFalse(AXText.markerMeansIdleBox(allowEmpty: true, selectedText: "picked", caret: 0))
        XCTAssertFalse(AXText.markerMeansIdleBox(allowEmpty: true, selectedText: nil, caret: 12))
        XCTAssertFalse(AXText.markerMeansIdleBox(allowEmpty: false, selectedText: nil, caret: 0))
    }
}
