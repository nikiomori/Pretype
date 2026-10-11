import Foundation

/// "12*7=" → "84", offered in the inline pill like an emoji shortcode (⇥ takes
/// it). Only a closed expression with a real operator triggers — "=" after a
/// lone number, a date or a version string stays quiet.
///
/// A tiny recursive-descent parser, not `NSExpression`: that raises an
/// Objective-C exception on malformed input, which Swift cannot catch.
enum InlineCalculator {
    /// The arithmetic expression just before the caret, "=" included, or nil.
    static func trailingExpression(in text: String) -> String? {
        guard text.hasSuffix("=") else { return nil }
        let allowed = Set("0123456789.+-*/×÷() ")
        let run = text.dropLast().reversed().prefix { allowed.contains($0) }
        // Leading spaces belong to the sentence; inner ones stay, so the
        // token's length is exactly what the pill deletes.
        let expr = String(run.reversed().drop { $0 == " " })
        guard expr.filter(\.isNumber).count >= 2,
              expr.dropFirst().contains(where: { "+-*/×÷".contains($0) }) else { return nil }
        // Glued to a word ("x2*3=", "v1.2-3=") it is code or a version string.
        let before = text.dropLast(expr.count + 1).last
        guard before.map({ !($0.isLetter || $0.isNumber || $0 == "_") }) ?? true else { return nil }
        return expr + "="
    }

    /// The token with its result appended ("12*7=" → "12*7=84"), or nil when
    /// it doesn't parse or doesn't come out a finite number.
    static func completion(for token: String) -> String? {
        guard token.hasSuffix("=") else { return nil }
        var parser = Parser(Array(token.dropLast()))
        guard let value = parser.expression(), parser.atEnd, value.isFinite else { return nil }
        return token + format(value)
    }

    static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        var text = String(format: "%.10g", value)
        if text.contains("."), !text.contains("e") {
            while text.hasSuffix("0") { text.removeLast() }
        }
        return text
    }

    private struct Parser {
        let chars: [Character]
        var pos = 0
        init(_ chars: [Character]) { self.chars = chars }
        var atEnd: Bool { pos == chars.count }

        mutating func expression() -> Double? {
            guard var value = term() else { return nil }
            while pos < chars.count, chars[pos] == "+" || chars[pos] == "-" {
                let op = chars[pos]; pos += 1
                guard let rhs = term() else { return nil }
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }

        mutating func term() -> Double? {
            guard var value = factor() else { return nil }
            while pos < chars.count, "*/×÷".contains(chars[pos]) {
                let op = chars[pos]; pos += 1
                guard let rhs = factor() else { return nil }
                value = op == "*" || op == "×" ? value * rhs : value / rhs
            }
            return value
        }

        /// Spaces separate tokens, never join them: "12 3+4" is no 123+4.
        mutating func skipSpaces() {
            while pos < chars.count, chars[pos] == " " { pos += 1 }
        }

        mutating func factor() -> Double? {
            skipSpaces()
            guard pos < chars.count else { return nil }
            if chars[pos] == "-" { pos += 1; return factor().map { -$0 } }
            if chars[pos] == "(" {
                pos += 1
                guard let value = expression(), pos < chars.count, chars[pos] == ")" else { return nil }
                pos += 1
                skipSpaces()
                return value
            }
            let start = pos
            while pos < chars.count, chars[pos].isNumber || chars[pos] == "." { pos += 1 }
            let value = Double(String(chars[start..<pos]))
            skipSpaces()
            return value
        }
    }
}
