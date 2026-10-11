import XCTest
@testable import Pretype

final class InlineCalculatorTests: XCTestCase {
    func testOffersTheResultForAClosedExpression() {
        XCTAssertEqual(InlineCalculator.trailingExpression(in: "that's 12*7="), "12*7=")
        XCTAssertEqual(InlineCalculator.completion(for: "12*7="), "12*7=84")
        XCTAssertEqual(InlineCalculator.completion(for: "(1+2)*3 ="), "(1+2)*3 =9")
        XCTAssertEqual(InlineCalculator.completion(for: "10/4="), "10/4=2.5")
        XCTAssertEqual(InlineCalculator.completion(for: "7÷2×3="), "7÷2×3=10.5")
        XCTAssertEqual(InlineCalculator.completion(for: "-3+5="), "-3+5=2")
    }

    func testStaysQuietOnThingsThatAreNotArithmetic() {
        XCTAssertNil(InlineCalculator.trailingExpression(in: "x = 42="), "no operator")
        XCTAssertNil(InlineCalculator.trailingExpression(in: "-15="), "a sign is not an operator")
        XCTAssertNil(InlineCalculator.trailingExpression(in: "x2*3="), "glued to a word: code")
        XCTAssertNil(InlineCalculator.trailingExpression(in: "a == b"), "no trailing =")
        XCTAssertNil(InlineCalculator.completion(for: "1/0="), "not finite")
        XCTAssertNil(InlineCalculator.completion(for: "1.2.3+4="), "malformed number")
        XCTAssertNil(InlineCalculator.completion(for: "(1+2="), "unbalanced")
    }

    func testTokenLengthMatchesWhatThePillDeletes() {
        let text = "sum: 2 + 3 ="
        let token = InlineCalculator.trailingExpression(in: text)
        XCTAssertEqual(token, "2 + 3 =")
        XCTAssertTrue(text.hasSuffix(token ?? "∅"))
    }
}
