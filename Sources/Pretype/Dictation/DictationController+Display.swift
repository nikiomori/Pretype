import AppKit
import AVFoundation

@MainActor
extension DictationController {
    // MARK: - Caret display

    func render() {
        guard let owner else { return }
        // A capture with no readable caret still has to LOOK like one. The pill
        // is the only sign at the caret that the microphone is open, and the
        // fields that publish no caret — web and Electron inputs, before their
        // first keystroke and again whenever the app replaces the focused node
        // — are exactly where someone reaches for dictation. Reported from real
        // use: the second sentence recorded fine but showed nothing at all,
        // only the menu-bar dot. Hence `noticeRect`, pointer and all.
        let mode: SuggestionDisplayMode
        switch phase {
        case .idle:
            owner.hideOverlay()
            return
        case .preparing:
            mode = .status(String(localized: "starting dictation…"))
        case .listening(let text):
            mode = .listening(Self.tail(text))
        case .working:
            mode = .status(String(localized: "writing it down…"))
        }
        owner.showOverlay(mode, at: noticeRect, host: hostStyle)
    }

    /// Where this capture draws: its own caret, then the last one the field
    /// drew at, then the pointer — the same ladder a refusal notice uses.
    var noticeRect: CGRect {
        caretRect ?? owner?.fallbackCaretRect ?? Self.pointerAnchor()
    }

    /// Where to draw a notice that has no caret to belong to: a one-point box
    /// just under the pointer, in the same Cocoa screen coordinates the caret
    /// rects use. Internal, not private: `insertDictated`'s own drop notices
    /// fall back to it too.
    static func pointerAnchor() -> CGRect {
        let point = NSEvent.mouseLocation
        return CGRect(x: point.x, y: point.y - 22, width: 1, height: 18)
    }

    /// The END of a long dictation, not its beginning: what the pill is for is
    /// showing that the words being said right now are being heard.
    nonisolated static func tail(_ text: String, limit: Int = 64) -> String {
        guard text.count > limit else { return text }
        return "…" + String(text.suffix(limit))
    }

    /// One clean line: a transcript with a newline in it would *send* the
    /// message in half the apps this types into, and trailing whitespace is
    /// never wanted at a caret.
    nonisolated static func clean(_ raw: String) -> String {
        raw.split(whereSeparator: { $0.isNewline || $0 == " " }).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
