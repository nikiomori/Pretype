import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// How the field under the caret renders its own text — what the inline ghost
/// has to match instead of guessing. All three are optional; each one that is
/// missing falls back to the caret-box estimate it replaced.
struct HostTextStyle: Equatable {
    /// The host font, family included — a monospace or serif field used to get a
    /// system-font ghost that lined up with nothing.
    var font: NSFont?
    /// The field's own text color. Tells dark-on-light from light-on-dark with
    /// no screen capture at all, which is what the appearance probe needs
    /// Screen Recording for (and gets wrong when it isn't granted).
    var color: NSColor?
    /// The field's background, where AX reports one — the same question
    /// answered directly instead of by implication from the ink.
    var background: NSColor?
    /// Field bounds in Cocoa (bottom-left origin) screen coordinates. The ghost
    /// must never draw past this — beyond it sits the send button, the page, or
    /// nothing at all.
    var fieldRect: CGRect?

    /// The line continues past the caret: inline ghost text would be drawn
    /// straight over the user's own words, so the overlay goes to the pill
    /// above the line instead. Whitespace up to the next line break doesn't
    /// count — there is nothing there to collide with.
    var textFollowsCaret = false

    /// Nothing resolved at all: the caller had no field to describe (engine
    /// notices). `textFollowsCaret` counts — a read that resolved only that
    /// still knows something the previous field's style would override.
    var isEmpty: Bool {
        font == nil && color == nil && background == nil && fieldRect == nil && !textFollowsCaret
    }
}

struct TextContext {
    /// Text immediately before the caret, from `AXText.windowStart` on.
    let textBeforeCaret: String
    /// A short window of text after the caret (for duplication checks).
    let textAfterCaret: String
    /// Caret rectangle in Cocoa (bottom-left origin) screen coordinates.
    let caretRect: CGRect?
    /// Font/color/box of the field, so the overlay renders like the host text.
    let host: HostTextStyle

    /// A no-break space reads as a plain one. ProseMirror (Claude Desktop)
    /// stores the space the user just typed as U+00A0, so the gates saw no
    /// typed separator and a typed-through suggestion never matched: 0 of 80
    /// such shows landed (journal 07-22 → 10-16). One UTF-16 unit either way,
    /// so offsets and backspace counts stay true.
    init(textBeforeCaret: String, textAfterCaret: String, caretRect: CGRect?, host: HostTextStyle) {
        self.textBeforeCaret = textBeforeCaret.replacingOccurrences(of: "\u{00A0}", with: " ")
        self.textAfterCaret = textAfterCaret.replacingOccurrences(of: "\u{00A0}", with: " ")
        self.caretRect = caretRect
        self.host = host
    }
}

struct SelectionInfo {
    let text: String
    /// Selection bounds in Cocoa (bottom-left origin) screen coordinates.
    let rect: CGRect?
}

enum AXText {
    /// Every accessibility call the reads here make, and the system state
    /// they consult — the system's in the app. A test reads a tree of its own
    /// for the duration of `$calls.withValue` (AXTextReadTests).
    struct Calls: Sendable {
        /// `AXUIElementCopyAttributeValue`.
        var copy: @Sendable (_ element: AXUIElement, _ attribute: String) -> (AXError, CFTypeRef?)
        /// `AXUIElementCopyParameterizedAttributeValue`; nil on any error.
        var copyParameterized: @Sendable (_ element: AXUIElement, _ attribute: String,
                                          _ parameter: CFTypeRef) -> CFTypeRef?
        /// The bundle ID of the app an element belongs to.
        var bundleID: @Sendable (AXUIElement) -> String?
        /// Secure input is engaged system-wide (`IsSecureEventInputEnabled`).
        var secureInput: @Sendable () -> Bool
        /// The keyboard input source's type and input mode.
        var inputSource: @Sendable () -> (type: String, modeID: String?)?

        static let live = Calls(
            copy: { element, attribute in
                var ref: CFTypeRef?
                let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
                return (error, ref)
            },
            copyParameterized: { element, attribute, parameter in
                var ref: CFTypeRef?
                guard AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, parameter, &ref)
                    == .success else { return nil }
                return ref
            },
            bundleID: { element in
                var pid: pid_t = 0
                guard AXUIElementGetPid(element, &pid) == .success else { return nil }
                return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            },
            secureInput: { IsSecureEventInputEnabled() },
            inputSource: {
                // TISCopy* is a Copy (retained); TISGetInputSourceProperty is a Get.
                guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
                      let typePtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else { return nil }
                let type = Unmanaged<CFString>.fromOpaque(typePtr).takeUnretainedValue() as String
                let modeID = TISGetInputSourceProperty(source, kTISPropertyInputModeID).map {
                    Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String
                }
                return (type, modeID)
            })
    }

    @TaskLocal static var calls = Calls.live

    /// Fallback for apps whose focus notifications never fire (some Electron
    /// builds): ask the system-wide element who has focus right now.
    /// `knownEditable`: an element already found editable — focus still on
    /// it skips the re-check (role, range, subrole, label: up to seven round
    /// trips), which the fallback path otherwise paid on every keystroke.
    static func systemFocusedTextElement(knownEditable known: AXUIElement? = nil) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, FocusTracker.axMessagingTimeout)
        guard let element = Self.element(systemWide, kAXFocusedUIElementAttribute) else { return nil }
        if let known, known == element { return known }
        AXUIElementSetMessagingTimeout(element, FocusTracker.axMessagingTimeout)
        return editableTextLabel(element) != nil ? element : nil
    }

    /// AX roles that actually hold editable text. Electron/Chromium sometimes
    /// reports a bogus `AXSelectedTextRange` on buttons and other controls; if we
    /// trusted that, the caret query returns garbage coordinates (e.g. x=0) and
    /// the overlay teleports to a screen corner. So gate on the role too.
    private static let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]

    /// True when macOS has secure input engaged — a password field is focused
    /// somewhere. The native `AXSecureTextField` subrole only flags AppKit secure
    /// fields; web/Electron password inputs (`<input type=password>`) report a
    /// plain `AXTextField`/`AXTextArea` and would otherwise be read via `kAXValue`.
    /// Browsers *often* engage system-wide secure input for those too, but not
    /// always — so this guard is backed up by the label/mask-glyph heuristics
    /// below rather than trusted alone. While it's on, we read no field text at all.
    static func isSecureInputActive() -> Bool {
        calls.secureInput()
    }

    /// True while an input method is mid-composition (Pinyin, kana, Telex,
    /// Hangul, dictation). AX reports the *uncommitted* composition as field
    /// text, so the ghost would predict off a half-typed romanisation — and Tab,
    /// our accept key, is the IME's own candidate key. So we read nothing at all.
    ///
    /// `AXTextInputMarkedRange` is a real AppKit attribute (10.6+) but isn't
    /// bridged into Swift, hence the string literal — same as
    /// "AXSelectedTextMarkerRange" below. Three answers, three meanings:
    /// implemented-and-marked, implemented-and-clear, and not implemented at all
    /// (Chromium/Electron/Java, or a timeout on a hung app) — only the last one
    /// pays for the input-source fallback.
    static func isComposing(_ element: AXUIElement) -> Bool {
        switch markedRangeAnswer(element) {
        case .marked: return true
        case .clear: return false
        case .unsupported: return isComposingInputSourceActive()
        }
    }

    /// The precise answer only: the element implements the marked-range
    /// attribute AND something is marked right now. `false` where the attribute
    /// is unsupported — no input-source fallback. This is the dictation gate:
    /// refusing on the coarse fallback would ban dictation outright for anyone
    /// with a CJK source selected in Electron/Chromium (where it demonstrably
    /// works today), to guard against a composition those apps never report.
    static func hasMarkedText(_ element: AXUIElement) -> Bool {
        if case .marked = markedRangeAnswer(element) { return true }
        return false
    }

    private enum MarkedRangeAnswer { case marked(CFRange), clear, unsupported }

    private static func markedRangeAnswer(_ element: AXUIElement) -> MarkedRangeAnswer {
        let (error, ref) = calls.copy(element, "AXTextInputMarkedRange")
        switch error {
        case .success:
            guard let range = axValue(ref, .cfRange, CFRange()), range.length > 0 else { return .clear }
            return .marked(range)
        case .noValue:
            return .clear  // attribute implemented, nothing marked
        default:
            return .unsupported
        }
    }

    /// Fallback when the element can't tell us: is a *composing* input source
    /// selected at all? Coarse by construction — where the marked-range
    /// attribute is unsupported this suppresses suggestions for the whole time
    /// such a source is selected, not just between the first and last keystroke
    /// of a composition. Vietnamese Telex and Korean have no Roman sub-mode, so
    /// those users get no ghost in Electron/Chromium apps while that source is
    /// picked. That is the price of not fighting the candidate window.
    ///
    /// ponytail: deliberately not the Chromium "AXTextInputMarkedTextMarkerRange"
    /// opaque-marker round-trip — twenty lines to recover what one line covers;
    /// upgrade path if the Telex/Korean cost is ever reported as real. Also no
    /// kTISNotifySelectedKeyboardInputSourceChanged observer: the TIS pair
    /// benchmarks at ~13 ns and is only reached from the already-throttled AX
    /// read path. And no Settings toggle — this is correctness, not taste.
    private static func isComposingInputSourceActive() -> Bool {
        guard let source = calls.inputSource() else { return false }
        return isCompositionInputMode(type: source.type, modeID: source.modeID)
    }

    /// The rule, kept pure so it can be pinned by a test. Only input *modes*
    /// compose; a plain keyboard layout (ABC, "Russian – PC") never does. The one
    /// input mode that doesn't compose is a Japanese IME's alphanumeric sub-mode,
    /// which reports exactly "com.apple.inputmethod.Roman" for both Romaji and
    /// Kana typing — that carve-out is what keeps Tab and the ghost alive for the
    /// English half of a Japanese user's day.
    nonisolated static func isCompositionInputMode(type: String, modeID: String?) -> Bool {
        type == kTISTypeKeyboardInputMode as String && modeID != "com.apple.inputmethod.Roman"
    }

    /// Label keywords that mark a password-ish field in web/Electron content,
    /// where neither the secure subrole nor (sometimes) secure input applies.
    private static let passwordLabelMarkers =
        ["password", "passcode", "passphrase", "пароль", "passwort", "contraseña", "mot de passe"]

    private static func looksLikePasswordField(label: String?) -> Bool {
        guard let label = label?.lowercased() else { return false }
        return passwordLabelMarkers.contains { label.contains($0) }
    }

    /// Web password fields that slip past every other guard still *render* as
    /// mask glyphs when the AX value is exposed at all. Never treat that as text.
    static func looksMasked(_ text: String) -> Bool {
        text.count >= 3 && text.allSatisfy { "•●∙*".contains($0) }
    }

    /// An editable text element's label (see `fieldLabel`) — `.some(nil)` for
    /// one without — or nil when it isn't one. The check reads the label
    /// anyway, so a caller wanting both asks once.
    static func editableTextLabel(_ element: AXUIElement) -> String?? {
        guard let role: String = attribute(element, kAXRoleAttribute),
              editableRoles.contains(role) else { return nil }
        guard selectedRange(of: element) != nil else { return nil }
        // macOS refuses to expose secure-field contents anyway; don't even attach.
        if let subrole: String = attribute(element, kAXSubroleAttribute), subrole == "AXSecureTextField" {
            return nil
        }
        // Web/Electron password inputs don't carry the secure subrole; their
        // label/placeholder is the only tell.
        let label = fieldLabel(for: element)
        if looksLikePasswordField(label: label) { return nil }
        return .some(label)
    }

    /// Non-empty selection in the element, if any.
    static func selectionInfo(for element: AXUIElement) -> SelectionInfo? {
        if isSecureInputActive() { return nil }
        // Several IMEs expose marked text as `AXSelectedText` with length > 0,
        // which would pop the ⌥⇥ fix hint on top of the candidate window.
        if isComposing(element) { return nil }
        guard let range = selectedRange(of: element), range.length > 0 else { return nil }
        guard let text: String = attribute(element, kAXSelectedTextAttribute), !text.isEmpty,
              !looksMasked(text) else { return nil }
        return SelectionInfo(text: text, rect: selectionRect(for: range, in: element))
    }

    /// A selection rect we trust. Native `AXBoundsForRange` when it lands inside
    /// the field, else Chromium's text-marker bounds — the range API returns x=0
    /// garbage for web/Electron content, the same breakage we route around for
    /// the caret. A rect whose center sits outside its own field is rejected, so
    /// the ⌥⇥ fix-selection hint falls back to the last caret instead of
    /// teleporting to a screen corner (the pre-text-marker behaviour the
    /// selection path still carried).
    private static func selectionRect(for range: CFRange, in element: AXUIElement) -> CGRect? {
        let frame = elementFrame(element)
        func validated(_ axRect: CGRect?) -> CGRect? {
            guard let r = axRect, r != .zero, r.height >= 4, centerInField(r, frame: frame) else { return nil }
            return onScreen(flipped(r))
        }
        return validated(bounds(forRange: range, in: element)) ?? validated(webCaretBounds(element))
    }

    /// Human-readable label of the field (title, description or placeholder) —
    /// e.g. "Subject" in Mail. Feeds the password check above and the focus
    /// snapshot (`TypingContext.fieldLabel`); never the prompt.
    static func fieldLabel(for element: AXUIElement) -> String? {
        for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute] {
            if let value: String = attribute(element, key),
               !value.trimmingCharacters(in: .whitespaces).isEmpty {
                return value
            }
        }
        return nil
    }

    /// Where the before-caret window starts, in UTF-16 units: 0 while the
    /// caret is within `maxChars`, then a multiple of 512 that holds still as
    /// the user types. End-anchored, the window slid a unit per keystroke past
    /// `maxChars`, and every `hasPrefix` check on the text downstream (ghost
    /// anchor, apply, the injection cache) failed on each key of a long
    /// document; now once per 512 typed. Same idea as `stableTail`.
    static func windowStart(caret: Int, maxChars: Int) -> Int {
        caret <= maxChars ? 0 : (caret - maxChars) / 512 * 512
    }

    /// What the web fallback reads when `AXValue` is empty: the window before
    /// the caret — the end of the field for a stuck-at-0 caret — plus the
    /// after-text, a few units early so a split character can be stepped over.
    static func webReadRange(caret: Int, total: Int, maxChars: Int) -> CFRange {
        let end = caret > 0 && caret < total ? caret : total
        let from = max(0, windowStart(caret: end, maxChars: maxChars) - 16)
        return CFRange(location: from, length: min(total, end + 192) - from)
    }

    /// `text` from `from` on, moved forward off a split surrogate pair or
    /// composed character — a snapped start can land inside either.
    static func substring(_ text: NSString, from: Int) -> String {
        guard from > 0, from < text.length else { return text.substring(from: min(max(0, from), text.length)) }
        let unit = text.rangeOfComposedCharacterSequence(at: from)
        return text.substring(from: unit.location == from ? from : NSMaxRange(unit))
    }

    /// `allowEmpty` keeps an EMPTY field readable: the completion pipeline has
    /// nothing to continue there and treats it as no context at all, but the
    /// reply flow's whole case is an empty chat box with a conversation above it.
    /// Only the web/Electron fallback is affected — it is the path that refuses
    /// an empty (or placeholder-showing) value.
    static func context(for element: AXUIElement, maxChars: Int = 1200,
                        allowEmpty: Bool = false) -> TextContext? {
        // A terminal is text only inside an AI agent's input box — the whole
        // screen otherwise, and the shell's command line is never ours. Read
        // wider there: the box sits under its rule, a full terminal row up.
        // An xterm.js panel sits in an editor, not a terminal app: outside an
        // agent box it reads as before (an empty field — dictation still
        // types there; completions find nothing).
        switch kind(of: element) {
        case .xterm:
            return xtermContext(element).flatMap(AgentPrompt.context)
                ?? fieldContext(for: element, maxChars: maxChars, allowEmpty: allowEmpty)
        case .terminal:
            // An agent's box has its closing rule on the line under the caret.
            // Checked first, from the short after-caret read: at a shell
            // prompt — most terminal typing — the full read below fetched
            // 4,000 characters a keystroke only for `AgentPrompt` to refuse.
            guard ruleUnderCaret(element) else { return nil }
            return fieldContext(for: element, maxChars: max(maxChars, 4000), allowEmpty: allowEmpty)
                .flatMap(AgentPrompt.context)
        case .plain:
            return fieldContext(for: element, maxChars: maxChars, allowEmpty: allowEmpty)
        }
    }

    /// The agent's session above its input box (`AgentPrompt.transcript`) —
    /// nil outside one. Read on demand, never per keystroke: in an xterm it
    /// is every row of the viewport, two AX reads each.
    static func agentTranscript(for element: AXUIElement) -> String? {
        switch kind(of: element) {
        case .xterm:
            return xtermContext(element, wholeScreen: true).flatMap {
                AgentPrompt.transcript(before: $0.textBeforeCaret, after: $0.textAfterCaret)
            }
        case .terminal:
            guard ruleUnderCaret(element),
                  let ctx = fieldContext(for: element, maxChars: 4000, allowEmpty: true) else { return nil }
            return AgentPrompt.transcript(before: ctx.textBeforeCaret, after: ctx.textAfterCaret)
        case .plain:
            return nil
        }
    }

    private enum FieldKind { case xterm, terminal, plain }

    /// A terminal's line editor — a terminal app's, or xterm.js inside an
    /// editor (VS Code, Cursor), where Claude Code's prompt sits — some of
    /// which delete a whole grapheme cluster per Backspace. The app's bundle
    /// can't tell: an xterm panel lives in a code editor. Free after the
    /// field's first read (`kind` is remembered).
    static func isTerminalField(_ element: AXUIElement) -> Bool { kind(of: element) != .plain }

    /// The line after the caret's is a horizontal rule — what `AgentPrompt`
    /// demands first — read the way `fieldContext` reads the after-text (192
    /// characters from a collapsed caret), so both agree. Unreadable counts as
    /// yes: the full read then decides, as before.
    private static func ruleUnderCaret(_ element: AXUIElement) -> Bool {
        guard let selection = selectedRange(of: element) else { return true }
        guard selection.length == 0 else { return false }   // `fieldContext` refuses a selection too
        guard let total: Int = attribute(element, kAXNumberOfCharactersAttribute) else { return true }
        let length = min(192, total - selection.location)
        guard length > 0 else { return false }
        guard let after = string(forRange: CFRange(location: selection.location, length: length), in: element)
        else { return true }
        let lines = after.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        return lines.count > 1 && AgentPrompt.ruleWidth(lines[1]) != nil
    }

    /// The focused field's kind, remembered: it can't change while the element
    /// lives, and asking took an AX round trip plus a LaunchServices lookup on
    /// every read — several reads a keystroke (~15% of one on a native field,
    /// far more where each round trip costs milliseconds).
    private static let lastKind = LockedValue<(element: AXUIElement, kind: FieldKind)?>(nil)

    private static func kind(of element: AXUIElement) -> FieldKind {
        if let hit = lastKind.get(), hit.element == element { return hit.kind }
        let (read, ref) = calls.copy(element, "AXDOMClassList")
        let kind: FieldKind
        if (ref as? [String])?.contains("xterm-helper-textarea") == true {
            kind = .xterm
        } else {
            kind = AppPolicy.isTerminal(calls.bundleID(element)) ? .terminal : .plain
        }
        // Only a definite answer is kept: a timeout or a just-woken Chromium
        // tree's failure would pin the wrong kind for the element's life.
        if read == .success || read == .attributeUnsupported { lastKind.set((element, kind)) }
        return kind
    }

    private static func fieldContext(for element: AXUIElement, maxChars: Int,
                                     allowEmpty: Bool) -> TextContext? {
        // Privacy floor: never read field text while a password field is active
        // anywhere (covers web/Electron password inputs the subrole check misses).
        if isSecureInputActive() { return nil }
        // The chokepoint: six call sites route through here, and
        // `SuggestionController.textDidChange` already turns a nil into a
        // dismiss, so one guard both stops the read and kills a live ghost.
        // Secure input goes first — while it's on the element may be unreadable
        // anyway and the extra AX round-trip buys nothing.
        if isComposing(element) { return nil }
        guard let selection = selectedRange(of: element),
              selection.length == 0, selection.location >= 0 else { return nil }
        let caret = selection.location
        let frame = elementFrame(element)

        // Native path: a caret that sits inside the field gives precise geometry
        // and selection-relative text.
        if let caretRect = validCaretRect(in: element, caret: caret, frame: frame) {
            let start = windowStart(caret: caret, maxChars: maxChars)
            // A few units early, so a character the start splits can be stepped over.
            let readFrom = max(0, start - 16)
            var text: String? = ""
            if caret > readFrom {
                text = string(forRange: CFRange(location: readFrom, length: caret - readFrom), in: element)
                    .map { substring($0 as NSString, from: start - readFrom) }
                if text == nil, let full: String = attribute(element, kAXValueAttribute) {
                    let ns = full as NSString
                    let caretLoc = min(caret, ns.length)
                    text = substring(ns.substring(to: caretLoc) as NSString,
                                     from: windowStart(caret: caretLoc, maxChars: maxChars))
                }
            }
            guard let textBeforeCaret = text, !looksMasked(textBeforeCaret) else { return nil }
            var textAfterCaret = ""
            // A field that doesn't publish `AXNumberOfCharacters` used to yield
            // an EMPTY after-text — indistinguishable from "the caret is at the
            // end", which is what `textFollowsCaret`, the caret-splits-a-word
            // guard and the gates' duplication check all read. All three then go
            // quiet at once and the ghost paints over the user's own words. The
            // value's own length answers the same question; `??` keeps that read
            // off the path of every field that does publish the count.
            let total: Int? = attribute(element, kAXNumberOfCharactersAttribute)
                ?? (attribute(element, kAXValueAttribute) as String?).map { ($0 as NSString).length }
            if let total {
                let afterLength = min(192, total - caret)
                if afterLength > 0 {
                    textAfterCaret = string(forRange: CFRange(location: caret, length: afterLength), in: element) ?? ""
                }
            }
            // Measure the real host style (NSTextView-backed fields expose it via
            // AXAttributedStringForRange) so the ghost matches the font exactly
            // and the overlay anchors to a true line height — not an estimate from
            // the caret box, which varies per app. nil → the window falls back.
            var host = attributedStyle(of: element, atIndex: max(0, caret - 1))
            host.fieldRect = cocoaFieldRect(frame)
            host.textFollowsCaret = linePopulatedAfterCaret(textAfterCaret)
            return TextContext(textBeforeCaret: textBeforeCaret, textAfterCaret: textAfterCaret,
                               caretRect: caretRect, host: host)
        }

        // Electron/web fallback: AX exposes the field box but a broken caret
        // (selectedRange stuck at 0, garbage bounds). Use the whole field value
        // with the caret assumed at the end and float the overlay just above the
        // field — right for typing at the end of a chat input (the common case).
        guard let frame, frame.width > 20, frame.height > 0 else { return nil }
        var read: String? = attribute(element, kAXValueAttribute)
        // Where `read` starts in the field. A ranged read takes the window
        // before the caret (the end, for a stuck-at-0 one — see below) plus
        // the after-text, not the field's first `maxChars` units: past those,
        // the model was continuing the middle of the draft at the real caret.
        var offset = 0
        if read?.isEmpty ?? true, let total: Int = attribute(element, kAXNumberOfCharactersAttribute), total > 0 {
            let range = webReadRange(caret: caret, total: total, maxChars: maxChars)
            offset = range.location
            read = string(forRange: range, in: element)
        }
        var value = read ?? ""
        // Some Electron inputs (Claude Desktop) expose their placeholder as the AX
        // value when empty — don't autocomplete "Type / for commands". For the
        // reply flow the placeholder is proof the box is empty, not a reason to
        // stop: read it as "".
        if let placeholder: String = attribute(element, kAXPlaceholderValueAttribute),
           !placeholder.isEmpty,
           value.trimmingCharacters(in: .whitespacesAndNewlines)
               == placeholder.trimmingCharacters(in: .whitespacesAndNewlines) {
            DebugLog.shared.log("AX", "web field shows placeholder \"\(placeholder)\""
                + (allowEmpty ? " — reading it as an empty field" : " — no suggestion"))
            if !allowEmpty { return nil }
            value = ""
        }
        if value.isEmpty, !allowEmpty {
            DebugLog.shared.log("AX", "web field with no readable text — no suggestion")
            return nil
        }
        if looksMasked(value) { return nil }
        let marker = webCaretBounds(element)
        // A marker that is NOT a collapsed caret spans a whole run, and that has
        // two meanings needing opposite answers: the user has text selected
        // (never suggest into that), or the box is idle and what AX calls its
        // value is the placeholder being drawn. The second is the exact case the
        // reply flow exists for — and Electron publishes such a placeholder as
        // `AXValue` and NOT as `AXPlaceholderValue` (Claude Desktop's "Describe
        // what you want to create…"), so the check above cannot see it and
        // `value` still holds decoration. Zero it, or the model would be handed
        // the placeholder as the user's own draft.
        let idle = marker.map { !isCollapsedCaret($0, in: frame) } ?? false
        if idle {
            let selected: String? = attribute(element, kAXSelectedTextAttribute)
            guard markerMeansIdleBox(allowEmpty: allowEmpty, selectedText: selected, caret: caret) else {
                DebugLog.shared.log("AX", "web/Electron: marker spans the run (selection/placeholder) — no suggestion")
                return nil
            }
            DebugLog.shared.log(
                "AX", "web/Electron: idle box, \(value.count)-char placeholder as value — reading it as an empty field")
            value = ""
        }
        // Chromium often reports a real selectedRange even where caret GEOMETRY
        // is garbage (which is why this fallback runs at all). When it's
        // plausible, split the value there instead of assuming end-of-field:
        // with the caret mid-text the whole-value context asked the model to
        // continue text the caret isn't at, and an empty `textAfterCaret`
        // defeated every mid-line guard downstream (`textFollowsCaret`, the
        // gates' duplication check, the caret-splits-a-word rule) — so the
        // ghost drew over the words after the caret. A location of 0 in a
        // non-empty field is indistinguishable from the stuck-at-0 breakage,
        // so it keeps the end-of-field assumption.
        let ns = value as NSString
        let caretLoc = (caret > 0 && caret - offset > 0 && caret - offset < ns.length) ? caret - offset : ns.length
        let beforeCaret = ns.substring(to: caretLoc)
        let window = substring(beforeCaret as NSString,
                               from: windowStart(caret: offset + caretLoc, maxChars: maxChars) - offset)
        let afterCaret = String(ns.substring(from: caretLoc).prefix(192))
        var host = attributedStyle(of: element, atIndex: max(0, offset + caretLoc - 1))
        let hostFont = host.font
        host.fieldRect = cocoaFieldRect(frame)
        host.textFollowsCaret = linePopulatedAfterCaret(afterCaret)

        // Best case: Chromium's text-marker API returns the REAL caret rect even
        // though the range/caret APIs return garbage (x=0). A collapsed caret
        // inside the field is the genuine cursor — pixel-accurate, like a native
        // caret, no width estimate needed. The idle box (decided above; its
        // value, and so both texts, are already "") anchors the same way: its
        // run rect is exactly where the placeholder is drawn, which is where the
        // user's own first character would land — a better anchor than the
        // estimate below, which would put the ghost on the box's LAST line from
        // a value that was decoration. Any other marker was refused above. An
        // unusable rect falls through to that estimate rather than refusing.
        if let run = marker,
           let anchor = onScreen(flipped(CGRect(x: run.minX, y: run.minY, width: 1, height: run.height))) {
            let size = hostFont?.pointSize ?? run.height / 1.18
            DebugLog.shared.log("AX", (idle ? "web/Electron: ghost anchored to the placeholder run"
                                            : "web/Electron: real caret via text-marker")
                + " at x=\(Int(run.minX)), \(Int(size))pt")
            host.font = hostFont ?? .systemFont(ofSize: size)
            return TextContext(textBeforeCaret: window, textAfterCaret: afterCaret, caretRect: anchor, host: host)
        }

        // No marker at all (older Electron / non-Chromium web view): estimate
        // the caret at the end of the text BEFORE it by measuring that text's
        // last line — the whole value put the estimate at the end of the field
        // even when the caret (per selectedRange) sat mid-text. The biggest
        // source of drift is a wrong font, so use the real one if exposed.
        let font = hostFont ?? NSFont.systemFont(ofSize: max(12, min(17, frame.height * 0.36)))
        let fontSize = font.pointSize
        let lastLine = beforeCaret.components(separatedBy: "\n").last ?? beforeCaret
        let textWidth = (lastLine as NSString).size(withAttributes: [.font: font]).width
        let lineHeight = ceil(fontSize * 1.35)
        let caretX = min(frame.minX + 8 + textWidth, frame.maxX - 24)
        // Anchor the line from the BOTTOM by the hard lines still after the
        // caret — mid-text on an earlier line, the bottom-line assumption put
        // the overlay a field-height off. Soft wraps stay invisible to this
        // estimate (as everywhere in it), and an undercount from the 192-char
        // cap just degrades toward the old bottom-line guess.
        let linesAfter = CGFloat(afterCaret.filter(\.isNewline).count)
        let caretBox = CGRect(x: caretX,
                              y: max(frame.minY + 2, frame.maxY - (linesAfter + 1) * lineHeight - 4),
                              width: 1, height: lineHeight)
        guard let anchor = onScreen(flipped(caretBox)) else { return nil }
        DebugLog.shared.log("AX", "web/Electron fallback: \(value.count) chars, "
            + "font \(hostFont != nil ? "real " : "guessed ")\(Int(fontSize))pt, caret≈\(caretLoc == ns.length ? "end-of-text" : "mid-text \(caretLoc)")")
        host.font = font
        return TextContext(textBeforeCaret: window, textAfterCaret: afterCaret, caretRect: anchor, host: host)
    }

    /// An xterm.js terminal (VS Code's, Cursor's, Hyper): the focused element
    /// is a hidden textarea parked on the cursor cell, and the screen's text
    /// lives in a separate accessibility tree, one element per viewport row.
    /// Rebuilds the text around the cursor from the rows near it — enough for
    /// `AgentPrompt` to find an input box — at two AX reads a row;
    /// `wholeScreen` reads every row above the cursor instead.
    private static func xtermContext(_ helper: AXUIElement, wholeScreen: Bool = false) -> TextContext? {
        guard let cursor = elementFrame(helper), cursor.height >= 4 else { return nil }
        var nodes = xtermNodes.get().flatMap { $0.helper == helper ? $0 : nil }
        var rows = nodes.flatMap { attribute($0.tree, kAXChildrenAttribute) as [AXUIElement]? }
        if rows == nil {
            nodes = findXtermNodes(helper)
            rows = nodes.flatMap { attribute($0.tree, kAXChildrenAttribute) as [AXUIElement]? }
            xtermNodes.set(rows == nil ? nil : nodes)
        }
        guard let nodes, let rows, let screenFrame = elementFrame(nodes.screen) else { return nil }
        let cursorRow = Int(((cursor.minY - screenFrame.minY) / cursor.height).rounded())
        // Read lazily, in the order `AgentPrompt.input` needs the rows: the
        // closing rule under the caret first (anything else and there is no
        // box — the common case, a shell, ends here), then upward only to the
        // prompt-glyph line and the rule over it. All 23 rows around the
        // caret, every keystroke, was ~7 ms of main thread in VS Code.
        func rowText(_ i: Int) -> String {
            (attribute(rows[i], kAXChildrenAttribute) as [AXUIElement]?)?.first
                .flatMap { attribute($0, kAXValueAttribute) as String? } ?? ""
        }
        guard rows.indices.contains(cursorRow), rows.indices.contains(cursorRow + 1) else { return nil }
        let below = rowText(cursorRow + 1)
        // Rows are right-trimmed, so the full-width rule gives the column count.
        guard let rule = AgentPrompt.ruleWidth(Substring(below)) else { return nil }
        let line = Array(rowText(cursorRow))
        let columns = max(rule, line.count)
        let column = max(0, Int(((cursor.minX - screenFrame.minX) / (screenFrame.width / CGFloat(columns))).rounded()))
        // ponytail: one cell per character — a wide (CJK, emoji) cell before
        // the cursor shifts the split; fine for the box's end-of-input caret.
        guard let typed = caretLine(row: String(line), column: column,
                                    recent: attribute(helper, kAXValueAttribute) ?? "") else { return nil }
        let above = wholeScreen ? (0..<cursorRow).map(rowText) : agentBoxRows(above: cursorRow, typed: typed, read: rowText)
        guard let caret = onScreen(flipped(CGRect(x: cursor.minX, y: cursor.minY, width: 1, height: cursor.height)))
        else { return nil }
        return TextContext(textBeforeCaret: (above + [typed]).joined(separator: "\n"),
                           textAfterCaret: String(line.dropFirst(column)) + "\n" + below,
                           caretRect: caret, host: HostTextStyle(fieldRect: cocoaFieldRect(screenFrame)))
    }

    /// The caret row up to the cursor's `column`, from a row read that may
    /// trail the terminal: VS Code's AX rows lag 0.3–0.8 s (Chromium defers
    /// their updates), and the old split padded the missing letters with
    /// spaces — a ghost for text no longer there, ⇥ landing before a letter.
    /// The cursor and xterm's helper textarea are live, and the textarea's
    /// value is the recent input, ending at the caret. So: the row's first
    /// `column − k` cells plus the textarea's newest `k` characters, for the
    /// smallest `k` whose textarea characters just before them match the row
    /// there. The row alone when its length already fits the cursor and no
    /// split does (a prompt cleared under a textarea that still remembers);
    /// nil when nothing fits — no ghost until the row catches up.
    nonisolated static func caretLine(row: String, column: Int, recent: String) -> String? {
        let row = Array(row), recent = Array(recent)
        for k in 0...min(recent.count, column) {
            let a = column - k
            guard a <= row.count else { continue }
            let v = min(4, recent.count - k, a)
            let fits = v == 0 ? a == row.count
                : recent[(recent.count - k - v)..<(recent.count - k)] == row[(a - v)..<a]
            if fits { return String(row[..<a] + recent.suffix(k)) }
        }
        return row.count == column ? String(row) : nil
    }

    /// The rows over the caret line `AgentPrompt.input` reads, oldest first —
    /// up to the prompt-glyph line and the rule over it, or the first line
    /// that rules a box out — fetched through `read` only as far as that.
    nonisolated static func agentBoxRows(above cursorRow: Int, typed: String, read: (Int) -> String) -> [String] {
        var rows: [String] = []
        var current = typed
        for i in stride(from: cursorRow - 1, through: max(0, cursorRow - AgentPrompt.maxLines), by: -1) {
            let isPrompt = current.first.map(AgentPrompt.markers.contains) == true
            guard isPrompt || current.hasPrefix("  ") else { break }
            current = read(i)
            rows.insert(current, at: 0)
            if isPrompt { break }
        }
        return rows
    }

    /// The screen element and row container of an xterm.js terminal around
    /// its helper textarea — a walk up and across the tree (a class read per
    /// sibling), kept for the helper while its rows still answer.
    private static let xtermNodes = LockedValue<(helper: AXUIElement, screen: AXUIElement, tree: AXUIElement)?>(nil)

    private static func findXtermNodes(_ helper: AXUIElement) -> (helper: AXUIElement, screen: AXUIElement, tree: AXUIElement)? {
        guard let screen = element(helper, kAXParentAttribute).flatMap({ element($0, kAXParentAttribute) }),
              let root = element(screen, kAXParentAttribute),
              let a11y = (attribute(root, kAXChildrenAttribute) as [AXUIElement]?)?
                .first(where: { domClasses($0).contains("xterm-accessibility") }),
              let tree = (attribute(a11y, kAXChildrenAttribute) as [AXUIElement]?)?.first else { return nil }
        return (helper, screen, tree)
    }

    private static func domClasses(_ element: AXUIElement) -> [String] {
        attribute(element, "AXDOMClassList") ?? []
    }

    /// Is this text-marker rect the genuine cursor? A caret is a hairline of
    /// roughly text height sitting inside its own field; anything wider spans a
    /// whole run (a selection, or the placeholder line of an idle box) and
    /// anything outside the field is the garbage geometry this path exists for.
    nonisolated static func isCollapsedCaret(_ rect: CGRect, in frame: CGRect) -> Bool {
        rect.width < 4 && rect.height >= 6 && rect.height <= frame.height + 4
            && rect.midX >= frame.minX - 4 && rect.midX <= frame.maxX + 12
            && rect.midY >= frame.minY - 4 && rect.midY <= frame.maxY + 4
    }

    /// Given a run-spanning marker, is this an IDLE box (placeholder drawn, no
    /// text) rather than a selection? Only the reply flow asks — a completion
    /// has nothing to continue either way — and only when nothing contradicts
    /// it: a real selection publishes `AXSelectedText` and a caret past 0, an
    /// idle box publishes neither. Wrong in one direction it costs a ghost drawn
    /// at the start of a draft the model then writes around; wrong in the other
    /// it costs the whole feature in every Electron box with a placeholder.
    nonisolated static func markerMeansIdleBox(allowEmpty: Bool, selectedText: String?, caret: Int) -> Bool {
        allowEmpty && (selectedText?.isEmpty ?? true) && caret == 0
    }

    /// Is there anything but whitespace between the caret and the end of its
    /// line? That is what inline ghost text would be painted on top of. Trailing
    /// spaces and the following lines don't collide with it, so they don't count.
    ///
    /// ponytail: only the native path can answer this — the web/Electron
    /// fallback reads no text after the caret at all (it assumes end-of-field,
    /// which is the case it exists for). Upgrade path if a mid-line caret in
    /// Electron ever overlaps: read the trailing run via the text-marker API.
    nonisolated static func linePopulatedAfterCaret(_ textAfterCaret: String) -> Bool {
        textAfterCaret.prefix { !$0.isNewline }.contains { !$0.isWhitespace }
    }

    /// The field's own box in Cocoa coordinates, when AX reports a usable one.
    /// A degenerate box (Electron sometimes reports 0×0) is worse than none: it
    /// would clamp the ghost to nothing.
    private static func cocoaFieldRect(_ frame: CGRect?) -> CGRect? {
        guard let frame, frame.width > 20, frame.height > 4 else { return nil }
        return flipped(frame)
    }

    // MARK: - Caret geometry

    /// False when an AX rect's center sits outside its own field (±24 pt of
    /// slack) — reported there, it is garbage. No usable frame: can't tell.
    private static func centerInField(_ rect: CGRect, frame: CGRect?) -> Bool {
        guard let frame, frame != .zero else { return true }
        return frame.insetBy(dx: -24, dy: -24).contains(CGPoint(x: rect.midX, y: rect.midY))
    }

    /// A caret rect only when AX gives plausible geometry that sits inside the
    /// field. Electron returns x=0 / off-field garbage, which we reject here so
    /// the caller can fall back to anchoring on the field box.
    private static func validCaretRect(in element: AXUIElement, caret: Int, frame: CGRect?) -> CGRect? {
        var rect = bounds(forRange: CFRange(location: caret, length: 0), in: element)
        if caret > 0 {
            rect = glyphAnchoredCaret(
                reported: rect,
                prevChar: bounds(forRange: CFRange(location: caret - 1, length: 1), in: element))
        }
        guard var r = rect, r != .zero, r.height >= 4, r.height <= 200,
              centerInField(r, frame: frame) else { return nil }
        // A caret is a hairline. Apps that answer a zero-length range with the
        // next character's full advance width report one many points wide, and
        // the inline ghost starts at the caret's RIGHT edge — so it would sit a
        // whole character clear of the caret it's supposed to continue. The
        // Chromium marker path already demands `width < 4`; this is the same
        // rule for the native one, applied instead of rejecting. Keeping the
        // LEFT edge assumes the phantom advance ran rightward (LTR); an RTL
        // misreport would leave the caret at the right edge instead — but the
        // ghost only draws with nothing after the caret, where there is no
        // next character to mis-measure.
        r.size.width = min(r.width, 2)
        return onScreen(flipped(r))
    }

    /// The caret rect to trust vertically, in AX (top-left origin) coordinates.
    /// The zero-length caret rect is app lore — TextEdit reports it a whole line
    /// too high, others report a cap-height sliver whose bottom is the baseline
    /// — while the previous character's box is measured glyph truth, and the
    /// ghost's baseline is only right when the caret box vertically IS the glyph
    /// line box. Missing or floating above the glyphs → derive from the glyph
    /// box; overlapping it (same visual line) with a different span → keep the
    /// caret's x, adopt the glyph box's vertical span; strictly below (a
    /// legitimate line start) → keep as reported.
    nonisolated static func glyphAnchoredCaret(reported: CGRect?, prevChar: CGRect?) -> CGRect? {
        guard let prev = prevChar, prev != .zero, prev.height >= 4 else { return reported }
        // Terminal.app answers the zero-length range with a zero-size rect
        // at a nonsense y: no caret at all, like a missing one.
        guard var rect = reported, rect.height > 0, rect.minY + 1 >= prev.minY else {
            return CGRect(x: prev.maxX, y: prev.minY, width: 1, height: prev.height)
        }
        if rect.minY < prev.maxY - 1, rect.maxY > prev.minY + 1,
           abs(rect.minY - prev.minY) + abs(rect.height - prev.height) > 1 {
            rect.origin.y = prev.minY
            rect.size.height = prev.height
        }
        return rect
    }

    /// Returns the rect only when its center lies on (or within 50 pt of)
    /// some attached display.
    private static func onScreen(_ rect: CGRect) -> CGRect? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let visible = NSScreen.screens.contains {
            $0.frame.insetBy(dx: -50, dy: -50).contains(center)
        }
        return visible ? rect : nil
    }

    /// AX (and Quartz/CG global) coordinates are top-left-origin; Cocoa screen
    /// coordinates are bottom-left. The flip is its own inverse, so this one
    /// function converts in either direction.
    static func flipped(_ rect: CGRect) -> CGRect {
        var r = rect
        // AX measures Y downward from the top of the PRIMARY display — the one
        // whose Cocoa frame origin is (0,0). `screens.first` is usually that, but
        // on a multi-display layout it may not be, so pick the zero-origin screen
        // explicitly; the flip is then correct regardless of monitor arrangement.
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first
        let primaryHeight = primary?.frame.height ?? 0
        r.origin.y = primaryHeight - r.origin.y - r.height
        return r
    }

    private static func elementFrame(_ element: AXUIElement) -> CGRect? {
        guard let position = axValue(attribute(element, kAXPositionAttribute), .cgPoint, CGPoint.zero),
              let size = axValue(attribute(element, kAXSizeAttribute), .cgSize, CGSize.zero) else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// Diagnostic: what AX exposes for the currently-focused element, then on
    /// a second line what `context(for:)` computes from it. Used by
    /// `--ax-probe` to see why caret geometry fails in some apps (e.g. Electron).
    static func probeDescription() -> String {
        guard AXIsProcessTrusted() else { return "NOT trusted — grant Accessibility to this binary first" }
        guard let element = Self.element(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute) else {
            return "no focused element"
        }
        // Wake Chromium's accessibility tree (Electron) so it exposes inner
        // text nodes / markers — the real pipeline does this too.
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success, pid > 0 {
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        let role: String = attribute(element, kAXRoleAttribute) ?? "?"
        let subrole: String = attribute(element, kAXSubroleAttribute) ?? "-"
        let value: String? = attribute(element, kAXValueAttribute)
        let nChars: Int? = attribute(element, kAXNumberOfCharactersAttribute)
        let range = selectedRange(of: element)
        var caretBounds: CGRect?
        var prevBounds: CGRect?
        if let range {
            caretBounds = bounds(forRange: CFRange(location: range.location, length: 0), in: element)
            if range.location > 0 {
                prevBounds = bounds(forRange: CFRange(location: range.location - 1, length: 1), in: element)
            }
        }
        // The three marked-range states are the whole design, and this is the
        // only place they're visible: there is deliberately no per-keystroke
        // logging (`isComposing` runs up to ~16×/s). "unsupported" means the
        // coarse input-source fallback is what's deciding in this app; a stuck
        // "loc+len" that never clears is the field bug worth reporting.
        let markedDesc = switch markedRangeAnswer(element) {
        case .marked(let marked): "\(marked.location)+\(marked.length)"
        case .clear: "none"
        case .unsupported: "unsupported"
        }
        var extra = ""
        if role == "AXWebArea" {
            // Chromium exposes caret position via private text-marker attributes.
            extra += " markerCaret=\(fmt(webCaretBounds(element)))"
            if let inner = Self.element(element, kAXFocusedUIElementAttribute) {
                let innerRole: String = attribute(inner, kAXRoleAttribute) ?? "?"
                let innerSame = inner == element
                extra += " inner=\(innerRole)\(innerSame ? "(self)" : "")/\(fmt(elementFrame(inner)))"
            } else {
                extra += " inner=none"
            }
        }
        // The two things that could fix the Electron estimate: the real font, and
        // real bounds for an actual character range (not the broken caret range).
        let lastIdx = (nChars ?? value?.count ?? 0) - 1
        let attrStyle = attributedStyle(of: element, atIndex: lastIdx)
        let lastCharBounds = lastIdx >= 0 ? bounds(forRange: CFRange(location: lastIdx, length: 1), in: element) : nil
        let fontDesc = attrStyle.font.map { "\($0.fontName) \(Int($0.pointSize))pt" } ?? "nil"
        // The ghost picks dark-vs-light from this color — but only a concrete one.
        // "none"/"dynamic" here is why an app falls back to the probe/system theme.
        func toneDesc(_ c: NSColor?) -> String {
            guard let c else { return "none" }
            return SuggestionWindow.staticLuminance(c)
                .map { "gray \(String(format: "%.2f", $0))" } ?? "dynamic(ignored)"
        }
        let colorDesc = toneDesc(attrStyle.color)
        let bgDesc = toneDesc(attrStyle.background)
        let valueDesc = value.map { "\"\($0.suffix(24))\"(\($0.count))" } ?? "nil"
        // Real geometry candidates: whole-text bounds, marker caret, and the
        // child AX tree (Chromium often keeps real frames on inner text nodes).
        let wholeBounds = (nChars ?? 0) > 0 ? bounds(forRange: CFRange(location: 0, length: nChars ?? 0), in: element) : nil
        let kids = probeChildren(element, prefix: "\n    ", depth: 3)
        return "role=\(role)/\(subrole) frame=\(fmt(elementFrame(element))) "
            + "range=\(range.map { "\($0.location)+\($0.length)" } ?? "nil") "
            + "value=\(valueDesc) nChars=\(nChars.map(String.init) ?? "nil") "
            + "caret=\(fmt(caretBounds)) prevChar=\(fmt(prevBounds)) "
            + "attrFont=\(fontDesc) attrColor=\(colorDesc) attrBg=\(bgDesc) lastChar=\(fmt(lastCharBounds)) whole=\(fmt(wholeBounds)) "
            + "marker=\(fmt(webCaretBounds(element))) markedRange=\(markedDesc)\(extra)\(kids)"
            + "\n[probe] " + probeContextLine(element)
    }

    /// What `context(for:)` actually computes for the focused element — verifies
    /// the live pipeline (incl. the Electron marker path) end to end.
    private static func probeContextLine(_ element: AXUIElement) -> String {
        guard editableTextLabel(element) != nil else { return "ctx: focus not editable" }
        guard let ctx = context(for: element, maxChars: 200) else { return "ctx: nil" }
        let font = ctx.host.font.map { "\($0.fontName) \(Int($0.pointSize))pt" } ?? "nil"
        return "ctx: text=\"…\(ctx.textBeforeCaret.suffix(16))\" caret=\(fmt(ctx.caretRect)) "
            + "font=\(font) field=\(fmt(ctx.host.fieldRect))"
    }

    /// Recursively dumps the child AX tree (role/frame/value) — to find inner
    /// text nodes whose frame is real even when range/caret geometry is broken.
    static func probeChildren(_ element: AXUIElement, prefix: String, depth: Int) -> String {
        guard depth > 0 else { return "" }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success,
              let kids = ref as? [AXUIElement], !kids.isEmpty else { return "" }
        var out = ""
        for kid in kids.prefix(6) {
            let role: String = attribute(kid, kAXRoleAttribute) ?? "?"
            let val: String? = attribute(kid, kAXValueAttribute)
            let v = val.map { " \"\($0.prefix(18))\"" } ?? ""
            out += "\(prefix)\(role) \(fmt(elementFrame(kid)))\(v)"
            out += probeChildren(kid, prefix: prefix + "  ", depth: depth - 1)
        }
        return out
    }

    /// A rect as the probe lines print it.
    private static func fmt(_ r: CGRect?) -> String {
        guard let r else { return "nil" }
        return "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height)))"
    }

    /// Caret/selection bounds inside a Chromium web area via the private
    /// text-marker API (the standard range API returns garbage for web content).
    static func webCaretBounds(_ element: AXUIElement) -> CGRect? {
        guard let marker: CFTypeRef = attribute(element, "AXSelectedTextMarkerRange"),
              let rect = axValue(parameterized(element, "AXBoundsForTextMarkerRange", marker), .cgRect, CGRect.zero)
        else { return nil }
        return rect == .zero ? nil : rect
    }

    /// The font AND text color of the character at `index`, via
    /// `AXAttributedStringForRange` — one round trip for both, since the ghost
    /// needs both to look like the text it continues. Chromium/WebKit expose
    /// them here even though caret bounds are broken; some providers store real
    /// `NSFont`/`NSColor` objects, others an "AXFont" descriptor dict and a
    /// `CGColor`.
    static func attributedStyle(of element: AXUIElement, atIndex index: Int) -> HostTextStyle {
        guard index >= 0,
              let attributed = parameterized(element, kAXAttributedStringForRangeParameterizedAttribute,
                                             range: CFRange(location: index, length: 1)) as? NSAttributedString,
              attributed.length > 0 else { return HostTextStyle() }
        var font = attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        if font == nil,
           let dict = attributed.attribute(NSAttributedString.Key("AXFont"), at: 0, effectiveRange: nil) as? [String: Any],
           let size = (dict["AXFontSize"] as? NSNumber)?.doubleValue, size > 0 {
            let name = dict["AXFontName"] as? String
            font = name.flatMap { NSFont(name: $0, size: size) } ?? .systemFont(ofSize: size)
        }
        // WebKit/Chromium hand back a CGColor under the AX-prefixed key; AppKit
        // fields an NSColor under the standard one.
        func color(_ keys: [NSAttributedString.Key]) -> NSColor? {
            for key in keys {
                guard let value = attributed.attribute(key, at: 0, effectiveRange: nil) else { continue }
                if let ns = value as? NSColor { return ns }
                // `as? CGColor` always succeeds on an Any (CF bridging) — check the type.
                if CFGetTypeID(value as CFTypeRef) == CGColor.typeID,
                   let ns = NSColor(cgColor: value as! CGColor) { return ns }
            }
            return nil
        }
        return HostTextStyle(
            font: font,
            color: color([.foregroundColor, NSAttributedString.Key("AXForegroundColor")]),
            background: color([.backgroundColor, NSAttributedString.Key("AXBackgroundColor")])
        )
    }

    // MARK: - Low-level helpers

    /// The host of the web page `element` sits in: the URL of its OUTERMOST
    /// `AXWebArea` ancestor (the tab, not an iframe inside it) — Safari,
    /// Chromium browsers and most Electron apps publish one. Lowercased,
    /// "www." dropped; nil outside a web page and for non-http(s) pages. Walks
    /// ancestors, so it belongs on the focus-change path, never per keystroke;
    /// stops at the window, since nothing above it is a page.
    static func pageHost(for element: AXUIElement) -> String? {
        var host: String?
        var node: AXUIElement? = element
        for _ in 0..<60 {
            guard let current = node else { break }
            let role: String? = attribute(current, kAXRoleAttribute)
            if role == kAXWindowRole || role == kAXApplicationRole { break }
            if role == "AXWebArea",
               let url: URL = attribute(current, "AXURL"),
               url.scheme == "https" || url.scheme == "http",
               let name = url.host?.lowercased() {
                host = name.hasPrefix("www.") ? String(name.dropFirst(4)) : name
            }
            node = self.element(current, kAXParentAttribute)
        }
        return host
    }

    static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        let (error, ref) = calls.copy(element, name)
        guard error == .success else { return nil }
        return ref as? T
    }

    /// An element-valued attribute (focused element, focused window). Type-
    /// checked, because `as?` to a CF type succeeds on anything.
    static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        let (error, ref) = calls.copy(element, name)
        guard error == .success, let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    /// The app destroyed the node behind this handle: every read fails from
    /// here on, and only a fresh lookup finds the field again.
    static func isDead(_ element: AXUIElement) -> Bool {
        calls.copy(element, kAXRoleAttribute).0 == .invalidUIElement
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        axValue(attribute(element, kAXSelectedTextRangeAttribute), .cfRange, CFRange())
    }

    private static func string(forRange range: CFRange, in element: AXUIElement) -> String? {
        parameterized(element, kAXStringForRangeParameterizedAttribute, range: range) as? String
    }

    private static func bounds(forRange range: CFRange, in element: AXUIElement) -> CGRect? {
        axValue(parameterized(element, kAXBoundsForRangeParameterizedAttribute, range: range), .cgRect, CGRect.zero)
    }

    /// The point/size/rect/range an `AXValue` ref holds. Type-checked, because
    /// `as?` to a CF type succeeds on anything.
    private static func axValue<T: BitwiseCopyable>(_ ref: CFTypeRef?, _ type: AXValueType, _ zero: T) -> T? {
        guard let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var value = zero
        return AXValueGetValue(ref as! AXValue, type, &value) ? value : nil
    }

    /// A parameterized attribute for the range `range`.
    private static func parameterized(_ element: AXUIElement, _ name: String, range: CFRange) -> CFTypeRef? {
        var r = range
        return AXValueCreate(.cfRange, &r).flatMap { parameterized(element, name, $0) }
    }

    private static func parameterized(_ element: AXUIElement, _ name: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        calls.copyParameterized(element, name, parameter)
    }
}
