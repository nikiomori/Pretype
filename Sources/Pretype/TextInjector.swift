import CoreGraphics

/// Inserts text into the focused field by posting synthetic keyboard events.
/// This is the most app-agnostic insertion path (works in AppKit, Electron,
/// web views and terminals alike).
enum TextInjector {
    /// Marks our synthetic events so the key tap can ignore them.
    static let magicTag: Int64 = 0x5052_5459 // "PRTY"

    static func insert(_ text: String) {
        guard !text.isEmpty else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        for chunk in utf16Chunks(Array(text.utf16)) {
            post(chunk: chunk, keyDown: true, source: source)
            post(chunk: chunk, keyDown: false, source: source)
        }
    }

    /// Split UTF-16 units into chunks of at most `chunkSize` (keyboardSetUnicode
    /// String silently truncates longer strings), never cutting a surrogate pair
    /// across a boundary — a chunk ending on a lone high surrogate (emoji, astral
    /// CJK) would post as a broken glyph. A trailing lone surrogate in malformed
    /// input stays as-is (nothing better to do with it).
    static func utf16Chunks(_ utf16: [UniChar], chunkSize: Int = 16) -> [[UniChar]] {
        var chunks: [[UniChar]] = []
        var index = 0
        while index < utf16.count {
            var end = min(index + chunkSize, utf16.count)
            if end < utf16.count, (0xD800...0xDBFF).contains(utf16[end - 1]) {
                end -= 1
            }
            chunks.append(Array(utf16[index..<end]))
            index = end
        }
        return chunks
    }

    /// Posts `count` Delete (backspace) keypresses — used to remove the
    /// just-typed last word before re-typing its correction. Tagged so the key
    /// tap ignores them (they pass straight through to the focused app).
    static func deleteBackward(_ count: Int) {
        guard count > 0 else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        let deleteKey: CGKeyCode = 0x33 // kVK_Delete (backspace)
        for _ in 0..<count {
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: deleteKey, keyDown: keyDown) else { continue }
                event.setIntegerValueField(.eventSourceUserData, value: magicTag)
                event.post(tap: .cghidEventTap)
            }
        }
    }

    private static func post(chunk: [UniChar], keyDown: Bool, source: CGEventSource?) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { return }
        chunk.withUnsafeBufferPointer { buffer in
            event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        }
        event.setIntegerValueField(.eventSourceUserData, value: magicTag)
        event.post(tap: .cghidEventTap)
    }
}
