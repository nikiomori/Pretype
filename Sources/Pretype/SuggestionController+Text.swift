import AppKit

/// The pipeline's pure text rules — no AX, no window, no state — each tested
/// on its own (TextShapingTests, PersonalizationTests, PrivacyAndReplyTests).
extension SuggestionController {
    /// The prompt's cut of a clipboard string: capped BEFORE trimming —
    /// trimming first copied a whole multi-MB string to keep 600 characters.
    nonisolated static func clipboardSnippet(_ text: String) -> String? {
        let snippet = text.drop(while: \.isWhitespace).prefix(600).trimmingCharacters(in: .whitespacesAndNewlines)
        return snippet.isEmpty ? nil : snippet
    }

    /// The journal record's suggestion for a ghost now showing `remaining` at
    /// `current`: what was typed since the record's `ctx`, then `remaining` —
    /// a stream that re-anchors after the user typed hands over only the rest,
    /// and storing that alone made `ctx + suggestion` text nobody was offered.
    nonisolated static func journalSuggestion(_ remaining: String, current: String,
                                              recordCtx: String?) -> String {
        guard let recordCtx, current.hasPrefix(recordCtx) else { return remaining }
        return String(current.dropFirst(recordCtx.count)) + remaining
    }

    /// How much of the offered suggestion the user took before it resolved.
    /// Accepted / typed-through took all of it; otherwise what is no longer on
    /// screen (the record holds the whole offer, `remaining` the rest).
    nonisolated static func consumedChars(outcome: SuggestionJournal.Outcome, offered: String,
                                          remaining: String) -> Int {
        outcome == .accepted || outcome == .typedThrough
            ? offered.count : max(0, offered.count - remaining.count)
    }

    /// Pure half of `inject` (testable): the text before the caret once
    /// `deleted` is gone and `text` has landed on `before` — nil when that
    /// can't be known.
    nonisolated static func textAfterInjection(_ text: String, deleting deleted: String,
                                               over before: String?) -> String? {
        guard let before, before.hasSuffix(deleted) else { return nil }
        return before.dropLast(deleted.count) + text
    }

    /// What `inject` presses to turn `deleted` into `text`: only the tails
    /// past their shared head. "12*7=" → "12*7=84" presses no Backspace at
    /// all, and a typo fix keeps the letters it got right — every synthetic
    /// delete is one more key that can land somewhere it shouldn't.
    /// Compared by `Character`, so the cut is a grapheme boundary in both.
    nonisolated static func keystrokes(replacing deleted: String, with text: String) -> (delete: String, type: String) {
        let shared = zip(deleted, text).prefix { $0 == $1 }.count
        return (String(deleted.dropFirst(shared)), String(text.dropFirst(shared)))
    }

    enum GhostUpdate: Equatable {
        case unchanged
        case narrowed(String)
        case retired(SuggestionJournal.Outcome)
    }

    /// What a ghost offered at `anchor`, still showing `remaining`, becomes
    /// once the field reads `text` — the one rule behind a keystroke, an AX
    /// re-read and a stream landing after the user typed on. Typing its head
    /// narrows it; typing all of it, or something else, retires it
    /// (`.typedThrough`, `.diverged`); text that no longer starts with the
    /// anchor (a backspace, a caret move, a programmatic edit) abandons it.
    nonisolated static func ghostUpdate(anchor: String, remaining: String, text: String) -> GhostUpdate {
        guard text.hasPrefix(anchor) else { return .retired(.abandoned) }
        let delta = String(text.dropFirst(anchor.count))
        if delta.isEmpty { return .unchanged }
        if delta.count < remaining.count, remaining.hasPrefix(delta) {
            return .narrowed(String(remaining.dropFirst(delta.count)))
        }
        return .retired(delta.hasPrefix(remaining) ? .typedThrough : .diverged)
    }

    /// Backspace, arrows, function keys (the private-use F7xx range) and
    /// other non-text input.
    nonisolated static func isControlInput(_ typed: String) -> Bool {
        typed.unicodeScalars.contains {
            $0.value < 0x20 || $0.value == 0x7F || (0xF700...0xF8FF).contains($0.value)
        }
    }

    /// Exact ⌘Z on the current layout: any extra chord modifier (⇧⌘Z redo,
    /// ⌥⌘Z, …) is the app's key. Layouts that move Z (QWERTZ, AZERTY) are
    /// decided by the produced character; layouts with no Latin letters at all
    /// (ЙЦУКЕН, Greek) fall back to the physical ANSI key — the same
    /// resolution macOS uses for its own ⌘-shortcuts.
    nonisolated static func isPlainCommandZ(keyCode: Int64, key: String?, flags: CGEventFlags) -> Bool {
        guard flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]) == [.maskCommand] else {
            return false
        }
        if let key, key.count == 1, ("a"..."z").contains(key) {
            return key == "z"
        }
        return keyCode == KeyCode.z
    }

    /// True when showing `suggestion` after `current` would glue a standalone new
    /// word onto the half-typed word at the caret. Only fires when the caret is
    /// mid-word (a letter, no trailing space), the suggestion claims to continue
    /// it (no leading space), its first word is itself a real word, and the
    /// merged form is NOT — i.e. it's a fresh word fused on, not a completion
    /// ("appreci" + "ate" = "appreciate" is a real word, so it passes). Runs on
    /// the main thread, where NSSpellChecker is safe.
    static func wouldGlueMidWord(current: String, suggestion: String) -> Bool {
        guard current.last?.isLetter == true, !suggestion.hasPrefix(" ") else { return false }
        let partial = SpellChecker.trailingWord(of: current)
        let firstWord = String(suggestion.prefix(while: \.isWordChar))
        guard !partial.isEmpty, !firstWord.isEmpty else { return false }
        return SpellChecker.isCompleteWord(firstWord, context: current)
            && !SpellChecker.isCompleteWord(partial + firstWord, context: current)
    }

    /// `maxChars` is the hard backstop on what can reach the field: a keystroke
    /// completion is a few words, a composed reply a few sentences.
    static func sanitized(_ raw: String, maxChars: Int) -> String {
        let line = String(raw.replacingOccurrences(of: "\t", with: " ").prefix { !$0.isNewline })
        // Runs collapsed first, so at most one space can trail the cut. The
        // regex only when there is a run: this runs on every streamed partial.
        let collapsed = line.contains("  ")
            ? line.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression) : line
        let out = collapsed.prefix(maxChars)
        return String(out.hasSuffix(" ") ? out.dropLast() : out)
    }

    /// The notice for a failed explicit request (⌥⇥, ⌥⇧⇥). An engine that
    /// isn't loaded says so: "failed" would read as a bug, and "looks fine"
    /// (what a bare nil used to show) as a verdict that never ran.
    nonisolated static func failureNotice(_ error: Error, fallback: String) -> SuggestionDisplayMode {
        if let notReady = error as? EngineNotReady { return .hint(notReady.message) }
        return .error(fallback)
    }

    /// The spaces between what is already in the field and what was just
    /// dictated. Speech has no spacebar: the transcript always starts at a
    /// word, and the caret may be sitting right after one — "привет" spoken
    /// after "я сказал" must not land as "я сказалпривет" — or right *before*
    /// one, where "hello|world" would fuse the spoken tail into the word that
    /// follows. Nothing is added after whitespace or an opening bracket, and
    /// nothing before punctuation that belongs to the word it hugs; the right
    /// seam is the same rules mirrored. Both are decided here so the caller
    /// injects, caches and books ONE chunk — a trailing space added by a second
    /// insert would be missing from the cache and the undo snapshot.
    ///
    /// `following` defaults to empty because a caret at the end of the field
    /// has no right seam to judge, which is where dictation usually lands.
    nonisolated static func spacedForInsertion(_ text: String, after context: String,
                                               before following: String = "") -> String {
        // `isWhitespace` covers newlines too.
        func seam(_ last: Character?, _ first: Character?) -> Bool {
            guard let last, let first else { return false }
            return !last.isWhitespace && !first.isWhitespace
                && !"([{«“„<".contains(last) && !".,!?;:)]}»”…".contains(first)
                && !isScriptioContinua(last) && !isScriptioContinua(first)
        }
        return (seam(context.last, text.first) ? " " : "") + text + (seam(text.last, following.first) ? " " : "")
    }

    /// Han, kana, and the CJK/fullwidth punctuation that travels with them —
    /// scripts written without spaces between words, where a seam space is not
    /// a nicety but a typo the user then has to delete. Fullwidth punctuation
    /// carries its own side-bearing for the same reason, so "。" needs no space
    /// before it and "「" none after it. Hangul is deliberately absent: Korean
    /// orthography spaces its words like ours, so it takes the ordinary rules.
    nonisolated private static func isScriptioContinua(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        return scalar.properties.isIdeographic          // Han, every block
            || (0x3000...0x30FF).contains(scalar.value)  // CJK punctuation (、。「」), hiragana, katakana
            || (0xFF00...0xFFEF).contains(scalar.value)  // fullwidth and halfwidth forms (！？，)
    }

    /// Drop a leading space the context already supplies. You type "спасибо за "
    /// and the model predicts a fresh word as " ответ" — the space is right
    /// after a word, wrong after a space. Shown, it is a stray gap between the
    /// caret and the ghost that looks like the suggestion is mispositioned;
    /// typed, it is a real double space in the sentence.
    ///
    /// `strippingStraySeparator` is the mirror case (a separator prepended to a
    /// *word continuation*) and deliberately only fires after a letter, so it
    /// never saw this one.
    nonisolated static func deduplicatingSeamSpace(_ suggestion: String, after context: String) -> String {
        guard context.hasSuffix(" "), suggestion.hasPrefix(" ") else { return suggestion }
        return String(suggestion.drop { $0 == " " })
    }

    /// The prompt as the debug log shows it, OCR'd screen text and clipboard
    /// redacted: the log is exportable (bug reports), and both can hold OTHER
    /// people's text — it must never leave the process under the export
    /// warning's "text you typed" framing.
    nonisolated static func loggablePrompt(_ request: CompletionRequest) -> String {
        var redacted = request
        redacted.screenSummary = request.screenSummary.map {
            "[\($0.count) chars of on-screen text — redacted from log]"
        }
        redacted.clipboardContext = request.clipboardContext.map {
            "[\($0.count) chars of clipboard text — redacted from log]"
        }
        return redacted.completionPrompt(maxChars: 1000)
    }

    /// Leading spaces plus the first run of non-space characters.
    nonisolated static func firstWordChunk(of text: String) -> String {
        let lead = text.prefix { $0 == " " }
        return String(lead + text[lead.endIndex...].prefix { $0 != " " })
    }
}
