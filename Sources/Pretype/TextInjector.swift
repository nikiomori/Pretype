import AppKit

/// Inserts text into the focused field by posting synthetic keyboard events.
/// This is the most app-agnostic insertion path (works in AppKit, Electron,
/// web views and terminals alike).
enum TextInjector {
    /// Marks our synthetic events so the key tap can ignore them.
    static let magicTag: Int64 = 0x5052_5459 // "PRTY"

    /// Where every finished event goes: the HID event stream. A test records
    /// them instead (TextInjectorTests).
    static var post: (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }

    static func insert(_ text: String) {
        guard !text.isEmpty else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        for chunk in utf16Chunks(Array(text.utf16)) {
            postChunk(chunk, keyDown: true, source: source)
            postChunk(chunk, keyDown: false, source: source)
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

    /// Posts the Delete (backspace) keypresses that remove `text` from just
    /// before the caret — the just-typed word before its correction, an
    /// accepted chunk on ⌘Z. Tagged so the key tap ignores them (they pass
    /// straight through to the focused app).
    ///
    /// `perCharacter`: a terminal, where the line editor or an agent's TUI —
    /// not AppKit — handles the key, and some delete a whole cluster per press
    /// (zsh with COMBINING_CHARS, Claude Code's prompt). AppKit's count there
    /// reaches into the user's own text before the chunk; one press per
    /// `Character` can at worst leave a fragment of it behind.
    @MainActor static func deleteBackward(over text: String, perCharacter: Bool = false) {
        press(KeyCode.delete, times: perCharacter ? text.count : backspaces(over: text))
    }

    /// How many presses delete `text`, counted the way AppKit deletes — by an
    /// offscreen text view, not by `Character`s. A press removes a whole emoji
    /// or accented Latin letter, but one code point of Thai, Arabic, Hebrew or
    /// Indic text (a vowel sign or mark at a time): `count` there left
    /// fragments of the word behind. Chromium deletes per code point outside
    /// emoji, so its count is never lower — these presses can't reach past
    /// `text` into the user's own words there either; at worst a decomposed
    /// Latin accent or Hangul jamo is left over.
    @MainActor static func backspaces(over text: String) -> Int {
        guard text.unicodeScalars.count != text.count else { return text.count }
        let view = NSTextView()
        view.string = text
        var presses = 0
        while !view.string.isEmpty, presses < text.unicodeScalars.count {
            view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
            view.deleteBackward(nil)
            presses += 1
        }
        return presses
    }

    /// Posts `count` presses of `key`, tagged so the key tap ignores them.
    static func press(_ key: Int64, times count: Int) {
        guard count > 0 else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<count {
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: keyDown) else { continue }
                event.flags = []
                event.setIntegerValueField(.eventSourceUserData, value: magicTag)
                post(event)
            }
        }
    }

    private static func postChunk(_ chunk: [UniChar], keyDown: Bool, source: CGEventSource?) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { return }
        chunk.withUnsafeBufferPointer { buffer in
            event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        }
        // A `.hidSystemState` event is stamped with the HARDWARE modifiers held
        // at post time — and this path routinely runs while keys are physically
        // down: ⇧ during ⇧⇥ accept-all, and the dictation modifier whenever a
        // queued capture's transcript lands mid-hold. Un-cleared, the text
        // arrives as ⌥/⇧-modified keystrokes, which apps with accelerators
        // treat as shortcuts instead of typing.
        event.flags = []
        event.setIntegerValueField(.eventSourceUserData, value: magicTag)
        post(event)
    }
}
