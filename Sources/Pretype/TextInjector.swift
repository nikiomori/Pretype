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
        let utf16 = Array(text.utf16)
        let chunkSize = 16 // keyboardSetUnicodeString silently truncates long strings
        var index = 0
        while index < utf16.count {
            let chunk = Array(utf16[index..<min(index + chunkSize, utf16.count)])
            post(chunk: chunk, keyDown: true, source: source)
            post(chunk: chunk, keyDown: false, source: source)
            index += chunkSize
        }
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
