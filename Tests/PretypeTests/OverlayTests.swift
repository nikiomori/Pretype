import AppKit
import CoreGraphics
import XCTest
@testable import Pretype

final class OverlayTests: XCTestCase {
    // An explicit ⌥⇥/⌥⇧⇥ that reached an unloaded engine says so — it used to
    // come back as nil and show "✓ looks fine" for text no model read.
    func testFailureNoticeNamesAnUnloadedEngine() {
        guard case .hint(let message) = SuggestionController.failureNotice(
            EngineNotReady(), fallback: "fix failed") else { return XCTFail("not-ready must be a hint") }
        XCTAssertEqual(message, EngineNotReady().message)
        guard case .error(let fallback) = SuggestionController.failureNotice(
            CocoaError(.fileNoSuchFile), fallback: "fix failed") else { return XCTFail("other errors stay errors") }
        XCTAssertEqual(fallback, "fix failed")
    }

    // The overlay's background probe decides dark-vs-light text from this mean;
    // pin the byte-order/color-space assumptions of the 1-px downsample.
    func testBackgroundProbeMeanLuminance() {
        func solidImage(white: CGFloat) -> CGImage {
            let ctx = CGContext(data: nil, width: 8, height: 4, bitsPerComponent: 8,
                                bytesPerRow: 32, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(srgbRed: white, green: white, blue: white, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
            return ctx.makeImage()!
        }
        let dark = BackgroundProbe.meanLuminance(of: solidImage(white: 0))!
        let light = BackgroundProbe.meanLuminance(of: solidImage(white: 1))!
        XCTAssertLessThan(dark, 0.1)
        XCTAssertGreaterThan(light, 0.9)
    }

    // The ghost takes dark-vs-light from the field's OWN text color, which is
    // what keeps it readable on a white page under a dark system (no screen
    // capture involved). Pin the polarity: a field's dark text must stay a dark
    // ghost, its light text a light one, whatever the hue.
    @MainActor func testGhostTonePolarity() {
        func gray(_ c: NSColor) -> CGFloat { SuggestionWindow.staticLuminance(c)! }
        XCTAssertLessThan(gray(.black), 0.1)
        XCTAssertGreaterThan(gray(.white), 0.9)
        // Hue drops out; only lightness survives, so a syntax-colored field
        // can't tint the ghost.
        XCTAssertEqual(gray(NSColor(srgbRed: 0.2, green: 0.2, blue: 0.2, alpha: 1)), 0.2, accuracy: 0.01)
        XCTAssertLessThan(gray(NSColor(srgbRed: 0.6, green: 0, blue: 0, alpha: 1)), 0.5)   // dark red text
        XCTAssertGreaterThan(gray(NSColor(srgbRed: 0.8, green: 1, blue: 0.8, alpha: 1)), 0.5) // pale green

        // A SEMANTIC color survives the AX boundary dynamic and resolves against
        // our own theme, not the host's — it reported black ink for a dark app's
        // white text and painted a black ghost on black. Must be discarded.
        XCTAssertNil(SuggestionWindow.staticLuminance(.textColor))
        XCTAssertNil(SuggestionWindow.staticLuminance(.labelColor))
        XCTAssertNil(SuggestionWindow.staticLuminance(.controlTextColor))

        // `withAlphaComponent` freezes a catalog color against the CALLING
        // context's appearance — this exact bug shipped: the ghost's ink froze
        // to the system tone and ignored the window's, white-on-white on a
        // light page under a dark system. The alpha'd ink and halo must stay
        // dynamic (staticLuminance returns nil only when the two appearances
        // resolve differently).
        XCTAssertNil(SuggestionWindow.staticLuminance(SuggestionWindow.dynamicAlpha(.labelColor, 0.7)))
        XCTAssertNil(SuggestionWindow.staticLuminance(SuggestionWindow.dynamicAlpha(.textBackgroundColor, 0.4)))
        // And the polarity survives the alpha: dark appearance → light ink.
        var darkInk: CGFloat = -1
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            let c = SuggestionWindow.dynamicAlpha(.labelColor, 0.7).usingColorSpace(.sRGB)!
            darkInk = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        }
        XCTAssertGreaterThan(darkInk, 0.75)
    }

    // The ghost's vertical seat in the caret box: true centring both ways,
    // bottom-line nudge only for the degenerate whole-view caret span.
    func testGhostLift() {
        XCTAssertEqual(SuggestionWindow.ghostLift(caretHeight: 16, lineHeight: 16), 0)    // tight box
        XCTAssertEqual(SuggestionWindow.ghostLift(caretHeight: 24, lineHeight: 16), 4)    // padded line
        XCTAssertEqual(SuggestionWindow.ghostLift(caretHeight: 32, lineHeight: 16), 8)    // generous line-height, uncapped
        XCTAssertEqual(SuggestionWindow.ghostLift(caretHeight: 10, lineHeight: 16), -3)   // cap-height caret: drop to its baseline
        XCTAssertEqual(SuggestionWindow.ghostLift(caretHeight: 200, lineHeight: 16), 6.4, accuracy: 0.001) // whole-view span
    }

    // The ⌥⇥ preview marks what a fix changes, word by word, and gives up on a
    // rewrite rather than striking out most of the text.
    func testFixPreviewWordDiff() {
        typealias R = SuggestionWindow.DiffRun
        XCTAssertEqual(SuggestionWindow.wordDiff(from: "their going too the store",
                                                 to: "they're going to the store"),
                       [R.removed("their"), .inserted("they're"), .same(" going "),
                        .removed("too"), .inserted("to"), .same(" the store")])
        // Applying the runs' kept text reproduces the fix exactly.
        let old = "i think their going too the store tomorow"
        let new = "I think they're going to the store tomorrow."
        let runs = SuggestionWindow.wordDiff(from: old, to: new) ?? []
        XCTAssertEqual(runs.map { if case .removed = $0 { return "" }
                                  if case .same(let s) = $0 { return s }
                                  if case .inserted(let s) = $0 { return s }
                                  return "" }.joined(), new)
        // A rewrite of a longer text is not a diff.
        XCTAssertNil(SuggestionWindow.wordDiff(from: "the cat sat on the mat today",
                                               to: "a dog lay across every rug yesterday"))
        // Short texts always diff, even when every word changed.
        XCTAssertEqual(SuggestionWindow.wordDiff(from: "teh", to: "the"), [R.removed("teh"), .inserted("the")])
    }

    // The ghost hangs off the caret and runs in the writing direction, stopping
    // at the field's far edge. Same rule for the first placement and every
    // post-accept slide, so they cannot drift apart.
    func testGhostSpan() {
        // LTR: starts at the caret's right edge, full width when the field allows.
        var span = SuggestionWindow.ghostSpan(anchorX: 100, textWidth: 60, bound: 400, rtl: false)
        XCTAssertEqual(span.x, 100)
        XCTAssertEqual(span.width, 60)
        // Clipped by the field's right edge.
        span = SuggestionWindow.ghostSpan(anchorX: 380, textWidth: 60, bound: 400, rtl: false)
        XCTAssertEqual(span.x, 380)
        XCTAssertEqual(span.width, 20)
        // RTL: the caret is the ghost's RIGHT edge and it grows leftward.
        span = SuggestionWindow.ghostSpan(anchorX: 300, textWidth: 60, bound: 100, rtl: true)
        XCTAssertEqual(span.x, 240)
        XCTAssertEqual(span.width, 60)
        span = SuggestionWindow.ghostSpan(anchorX: 130, textWidth: 60, bound: 100, rtl: true)
        XCTAssertEqual(span.x, 100)
        XCTAssertEqual(span.width, 30)
        // No room at all in the direction of growth — never a negative width.
        span = SuggestionWindow.ghostSpan(anchorX: 420, textWidth: 60, bound: 400, rtl: false)
        XCTAssertEqual(span.width, 0)
        span = SuggestionWindow.ghostSpan(anchorX: 90, textWidth: 60, bound: 100, rtl: true)
        XCTAssertEqual(span.width, 0)
    }

    // Which side of the caret the ghost belongs on. Decided by the first LETTER:
    // digits, punctuation and currency are direction-neutral.
    func testGhostWritingDirection() {
        XCTAssertFalse(SuggestionWindow.isRightToLeft("hello there"))
        XCTAssertFalse(SuggestionWindow.isRightToLeft(" привет"))
        XCTAssertFalse(SuggestionWindow.isRightToLeft("你好"))
        XCTAssertTrue(SuggestionWindow.isRightToLeft("שלום"))
        XCTAssertTrue(SuggestionWindow.isRightToLeft(" مرحبا"))
        // Neutral run first, then the letter that decides.
        XCTAssertTrue(SuggestionWindow.isRightToLeft("50 ₪ שלום"))
        XCTAssertFalse(SuggestionWindow.isRightToLeft("50 ₪ shekel"))
        // Nothing to go on → the LTR default, which is where the ghost already sat.
        XCTAssertFalse(SuggestionWindow.isRightToLeft("123 …"))
        XCTAssertFalse(SuggestionWindow.isRightToLeft(""))
    }

    // ⇧⇥ accepts the WHOLE suggestion, so the ghost must never show less than it
    // offers: what doesn't fit on the line is cut off the offer too.
    func testFittingPrefix() {
        let font = NSFont.systemFont(ofSize: 13)
        let text = "не забудь взять зонт"
        func width(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }
        // Room for everything → untouched (and no measurement rounding drift).
        XCTAssertEqual(SuggestionWindow.fittingPrefix(of: text, font: font, width: width(text) + 10), text)
        // Cut at a word boundary, trailing space dropped.
        let cut = SuggestionWindow.fittingPrefix(of: text, font: font, width: width("не забудь взять"))
        XCTAssertEqual(cut, "не забудь взять")
        XCTAssertTrue(text.hasPrefix(cut))   // only ever a prefix: narrowing still lines up
        // Not even the first word fits → "" so the caller falls back to the pill,
        // which draws the suggestion whole above the line.
        XCTAssertEqual(SuggestionWindow.fittingPrefix(of: text, font: font, width: width("не") / 2), "")
        XCTAssertEqual(SuggestionWindow.fittingPrefix(of: text, font: font, width: 0), "")
        XCTAssertEqual(SuggestionWindow.fittingPrefix(of: "", font: font, width: 100), "")

        // RTL: the trim is the one place the right-to-left ghost's geometry meets
        // the text logic. The cut is LOGICAL (a prefix of the string, which is
        // what `narrowActive` and ⇧⇥ later re-match against) even though it
        // renders from the right edge — so what's dropped is the visually
        // leftmost run, and the kept text still starts at the caret.
        let arabic = "لا تنس أن تأخذ المظلة"
        let arCut = SuggestionWindow.fittingPrefix(of: arabic, font: font,
                                                   width: width("لا تنس أن"))
        XCTAssertEqual(arCut, "لا تنس أن")
        XCTAssertTrue(arabic.hasPrefix(arCut))
        XCTAssertTrue(SuggestionWindow.isRightToLeft(arCut),
                      "a trimmed RTL suggestion must still lay out RTL")
        // Hebrew, and the same no-room fallback as above.
        let hebrew = "אל תשכח לקחת מטריה"
        XCTAssertEqual(SuggestionWindow.fittingPrefix(of: hebrew, font: font,
                                                      width: width("אל תשכח")), "אל תשכח")
        XCTAssertEqual(SuggestionWindow.fittingPrefix(of: hebrew, font: font,
                                                      width: width("אל") / 2), "")
    }
}
