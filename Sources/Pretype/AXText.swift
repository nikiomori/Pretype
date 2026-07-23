import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// What one AX attributed-string read tells us about how a character is drawn.
struct AXTextStyle {
    var font: NSFont?
    var color: NSColor?
    var background: NSColor?
}

/// How the field under the caret renders its own text — what the inline ghost
/// has to match instead of guessing. All three are optional; each one that is
/// missing falls back to the caret-box estimate it replaced.
struct HostTextStyle {
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
    /// Text immediately before the caret, capped at `maxChars`.
    let textBeforeCaret: String
    /// A short window of text after the caret (for duplication checks).
    let textAfterCaret: String
    /// Caret rectangle in Cocoa (bottom-left origin) screen coordinates.
    let caretRect: CGRect?
    /// Font/color/box of the field, so the overlay renders like the host text.
    let host: HostTextStyle
}

struct SelectionInfo {
    let text: String
    /// Selection bounds in Cocoa (bottom-left origin) screen coordinates.
    let rect: CGRect?
}

enum AXText {

    /// Fallback for apps whose focus notifications never fire (some Electron
    /// builds): ask the system-wide element who has focus right now.
    static func systemFocusedTextElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, FocusTracker.axMessagingTimeout)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        let element = ref as! AXUIElement
        AXUIElementSetMessagingTimeout(element, FocusTracker.axMessagingTimeout)
        return isEditableTextElement(element) ? element : nil
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
        IsSecureEventInputEnabled()
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
        var ref: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, "AXTextInputMarkedRange" as CFString, &ref) {
        case .success:
            guard let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return false }
            var range = CFRange()
            guard AXValueGetValue(ref as! AXValue, .cfRange, &range) else { return false }
            return range.length > 0
        case .noValue:
            return false  // attribute implemented, nothing marked
        default:
            return isComposingInputSourceActive()
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
        // TISCopy* is a Copy (retained); TISGetInputSourceProperty is a Get.
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let typePtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else { return false }
        let type = Unmanaged<CFString>.fromOpaque(typePtr).takeUnretainedValue() as String
        let modeID = TISGetInputSourceProperty(source, kTISPropertyInputModeID).map {
            Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String
        }
        return isCompositionInputMode(type: type, modeID: modeID)
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

    private static func looksLikePasswordField(_ element: AXUIElement) -> Bool {
        guard let label = fieldLabel(for: element)?.lowercased() else { return false }
        return passwordLabelMarkers.contains { label.contains($0) }
    }

    /// Web password fields that slip past every other guard still *render* as
    /// mask glyphs when the AX value is exposed at all. Never treat that as text.
    static func looksMasked(_ text: String) -> Bool {
        text.count >= 3 && text.allSatisfy { "•●∙*".contains($0) }
    }

    static func isEditableTextElement(_ element: AXUIElement) -> Bool {
        guard let role: String = attribute(element, kAXRoleAttribute),
              editableRoles.contains(role) else { return false }
        guard selectedRange(of: element) != nil else { return false }
        // macOS refuses to expose secure-field contents anyway; don't even attach.
        if let subrole: String = attribute(element, kAXSubroleAttribute), subrole == "AXSecureTextField" {
            return false
        }
        // Web/Electron password inputs don't carry the secure subrole; their
        // label/placeholder is the only tell.
        if looksLikePasswordField(element) { return false }
        return true
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
            guard let r = axRect, r != .zero, r.height >= 4 else { return nil }
            if let frame, frame != .zero,
               !frame.insetBy(dx: -24, dy: -24).contains(CGPoint(x: r.midX, y: r.midY)) {
                return nil  // selection reported outside its own field → garbage
            }
            return onScreen(cocoaRect(r))
        }
        return validated(bounds(forRange: range, in: element)) ?? validated(webCaretBounds(element))
    }

    /// Human-readable label of the field (title, description or placeholder) —
    /// e.g. "Subject" in Mail. Used as model context.
    static func fieldLabel(for element: AXUIElement) -> String? {
        for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute] {
            if let value: String = attribute(element, key),
               !value.trimmingCharacters(in: .whitespaces).isEmpty {
                return value
            }
        }
        return nil
    }

    static func context(for element: AXUIElement, maxChars: Int) -> TextContext? {
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
            let start = max(0, caret - maxChars)
            let windowRange = CFRange(location: start, length: caret - start)
            var text: String? = ""
            if windowRange.length > 0 {
                text = string(forRange: windowRange, in: element)
                if text == nil, let full: String = attribute(element, kAXValueAttribute) {
                    let ns = full as NSString
                    let caretLoc = min(caret, ns.length)
                    let from = max(0, caretLoc - maxChars)
                    text = ns.substring(with: NSRange(location: from, length: caretLoc - from))
                }
            }
            guard let textBeforeCaret = text, !looksMasked(textBeforeCaret) else { return nil }
            var textAfterCaret = ""
            if let total: Int = attribute(element, kAXNumberOfCharactersAttribute) {
                let afterLength = min(192, total - caret)
                if afterLength > 0 {
                    textAfterCaret = string(forRange: CFRange(location: caret, length: afterLength), in: element) ?? ""
                }
            }
            // Measure the real host style (NSTextView-backed fields expose it via
            // AXAttributedStringForRange) so the ghost matches the font exactly
            // and the overlay anchors to a true line height — not an estimate from
            // the caret box, which varies per app. nil → the window falls back.
            let style = attributedStyle(of: element, atIndex: max(0, caret - 1))
            return TextContext(textBeforeCaret: textBeforeCaret, textAfterCaret: textAfterCaret,
                               caretRect: caretRect,
                               host: HostTextStyle(font: style.font, color: style.color,
                                                   background: style.background,
                                                   fieldRect: cocoaFieldRect(frame),
                                                   textFollowsCaret: linePopulatedAfterCaret(textAfterCaret)))
        }

        // Electron/web fallback: AX exposes the field box but a broken caret
        // (selectedRange stuck at 0, garbage bounds). Use the whole field value
        // with the caret assumed at the end and float the overlay just above the
        // field — right for typing at the end of a chat input (the common case).
        guard let frame, frame.width > 20, frame.height > 0 else { return nil }
        var value: String? = attribute(element, kAXValueAttribute)
        if value?.isEmpty ?? true, let total: Int = attribute(element, kAXNumberOfCharactersAttribute), total > 0 {
            value = string(forRange: CFRange(location: 0, length: min(total, maxChars)), in: element)
        }
        guard let value, !value.isEmpty else {
            DebugLog.shared.log("AX", "web field with no readable text — no suggestion")
            return nil
        }
        // Some Electron inputs (Claude Desktop) expose their placeholder as the AX
        // value when empty — don't autocomplete "Type / for commands".
        if let placeholder: String = attribute(element, kAXPlaceholderValueAttribute),
           !placeholder.isEmpty,
           value.trimmingCharacters(in: .whitespacesAndNewlines)
               == placeholder.trimmingCharacters(in: .whitespacesAndNewlines) {
            DebugLog.shared.log("AX", "web field shows placeholder \"\(placeholder)\" — no suggestion")
            return nil
        }
        if looksMasked(value) { return nil }
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
        let caretLoc = (caret > 0 && caret < ns.length) ? caret : ns.length
        let beforeCaret = ns.substring(to: caretLoc)
        let afterCaret = String(ns.substring(from: caretLoc).prefix(192))
        let style = attributedStyle(of: element, atIndex: max(0, caretLoc - 1))
        let hostFont = style.font
        let box = cocoaFieldRect(frame)
        let marker = webCaretBounds(element)

        // Best case: Chromium's text-marker API returns the REAL caret rect even
        // though the range/caret APIs return garbage (x=0). A collapsed caret
        // inside the field is the genuine cursor — pixel-accurate, like a native
        // caret, no width estimate needed.
        if let caret = marker, caret.width < 4,
           caret.height >= 6, caret.height <= frame.height + 4,
           caret.midX >= frame.minX - 4, caret.midX <= frame.maxX + 12,
           caret.midY >= frame.minY - 4, caret.midY <= frame.maxY + 4,
           let anchor = onScreen(cocoaRect(CGRect(x: caret.minX, y: caret.minY, width: 1, height: caret.height))) {
            let size = hostFont?.pointSize ?? caret.height / 1.18
            DebugLog.shared.log("AX", "web/Electron: real caret via text-marker at x=\(Int(caret.minX)), \(Int(size))pt")
            return TextContext(textBeforeCaret: String(beforeCaret.suffix(maxChars)), textAfterCaret: afterCaret,
                               caretRect: anchor,
                               host: HostTextStyle(font: hostFont ?? .systemFont(ofSize: size),
                                                   color: style.color, background: style.background,
                                                   fieldRect: box,
                                                   textFollowsCaret: linePopulatedAfterCaret(afterCaret)))
        }
        // A marker that is NOT a collapsed caret spans the whole run — that's a
        // selection or the placeholder/idle state (e.g. Claude's "Describe a
        // task…"). Don't fabricate a completion there: this is the robust
        // placeholder guard, since Electron doesn't expose AXPlaceholderValue.
        if marker != nil {
            DebugLog.shared.log("AX", "web/Electron: marker spans the run (selection/placeholder) — no suggestion")
            return nil
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
        guard let anchor = onScreen(cocoaRect(caretBox)) else { return nil }
        DebugLog.shared.log("AX", "web/Electron fallback: \(value.count) chars, "
            + "font \(hostFont != nil ? "real " : "guessed ")\(Int(fontSize))pt, caret≈\(caretLoc == ns.length ? "end-of-text" : "mid-text \(caretLoc)")")
        return TextContext(textBeforeCaret: String(beforeCaret.suffix(maxChars)), textAfterCaret: afterCaret,
                           caretRect: anchor,
                           host: HostTextStyle(font: font, color: style.color,
                                               background: style.background, fieldRect: box,
                                               textFollowsCaret: linePopulatedAfterCaret(afterCaret)))
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
        return cocoaRect(frame)
    }

    // MARK: - Caret geometry

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
        guard let r = rect, r != .zero, r.height >= 4, r.height <= 200 else { return nil }
        if let frame, frame != .zero,
           !frame.insetBy(dx: -24, dy: -24).contains(CGPoint(x: r.midX, y: r.midY)) {
            return nil  // caret reported outside its own field → garbage
        }
        return onScreen(cocoaRect(r))
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
        guard var rect = reported, rect != .zero, rect.minY + 1 >= prev.minY else {
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

    /// AX coordinates are top-left-origin; Cocoa screen coordinates are bottom-left.
    private static func cocoaRect(_ axRect: CGRect) -> CGRect {
        var r = axRect
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
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              let posRef, CFGetTypeID(posRef) == AXValueGetTypeID(),
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let sizeRef, CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// Diagnostic: what AX exposes for the currently-focused element. Used by
    /// `--ax-probe` to see why caret geometry fails in some apps (e.g. Electron).
    static func probeDescription() -> String {
        guard AXIsProcessTrusted() else { return "NOT trusted — grant Accessibility to this binary first" }
        let systemWide = AXUIElementCreateSystemWide()
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return "no focused element" }
        let element = ref as! AXUIElement
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
        func fmt(_ r: CGRect?) -> String {
            guard let r else { return "nil" }
            return "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height)))"
        }
        // The three marked-range states are the whole design, and this is the
        // only place they're visible: there is deliberately no per-keystroke
        // logging (`isComposing` runs up to ~16×/s). "unsupported" means the
        // coarse input-source fallback is what's deciding in this app; a stuck
        // "loc+len" that never clears is the field bug worth reporting.
        var markedRef: CFTypeRef?
        let markedDesc: String
        switch AXUIElementCopyAttributeValue(element, "AXTextInputMarkedRange" as CFString, &markedRef) {
        case .success:
            var marked = CFRange()
            if let markedRef, CFGetTypeID(markedRef) == AXValueGetTypeID(),
               AXValueGetValue(markedRef as! AXValue, .cfRange, &marked) {
                markedDesc = "\(marked.location)+\(marked.length)"
            } else {
                markedDesc = "unreadable"
            }
        case .noValue: markedDesc = "none"
        default: markedDesc = "unsupported"
        }
        var extra = ""
        if role == "AXWebArea" {
            // Chromium exposes caret position via private text-marker attributes.
            extra += " markerCaret=\(fmt(webCaretBounds(element)))"
            var innerRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &innerRef) == .success,
               let innerRef, CFGetTypeID(innerRef) == AXUIElementGetTypeID() {
                let inner = innerRef as! AXUIElement
                let innerRole: String = attribute(inner, kAXRoleAttribute) ?? "?"
                let innerSame = CFEqual(inner, element)
                extra += " inner=\(innerRole)\(innerSame ? "(self)" : "")/\(fmt(elementFrame(inner)))"
            } else {
                extra += " inner=none"
            }
        }
        // The two things that could fix the Electron estimate: the real font, and
        // real bounds for an actual character range (not the broken caret range).
        let lastIdx = (nChars ?? value?.count ?? 0) - 1
        let attrStyle = lastIdx >= 0 ? attributedStyle(of: element, atIndex: lastIdx) : AXTextStyle()
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
    }

    /// What `context(for:)` actually computes for the focused element — verifies
    /// the live pipeline (incl. the Electron marker path) end to end via `--ax-probe`.
    static func probeContextLine() -> String {
        let systemWide = AXUIElementCreateSystemWide()
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return "ctx: no focus" }
        let element = ref as! AXUIElement
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success, pid > 0 {
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        guard isEditableTextElement(element) else { return "ctx: focus not editable" }
        guard let ctx = context(for: element, maxChars: 200) else { return "ctx: nil" }
        func fmt(_ rect: CGRect?) -> String {
            rect.map { "(\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height)))" } ?? "nil"
        }
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
        func fmt(_ r: CGRect?) -> String {
            guard let r else { return "nil" }
            return "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height)))"
        }
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

    /// Caret/selection bounds inside a Chromium web area via the private
    /// text-marker API (the standard range API returns garbage for web content).
    static func webCaretBounds(_ element: AXUIElement) -> CGRect? {
        var markerRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &markerRef) == .success,
              let markerRef else { return nil }
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, "AXBoundsForTextMarkerRange" as CFString, markerRef, &boundsRef
        ) == .success, let boundsRef, CFGetTypeID(boundsRef) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect) else { return nil }
        return rect == .zero ? nil : rect
    }

    /// The font AND text color of the character at `index`, via
    /// `AXAttributedStringForRange` — one round trip for both, since the ghost
    /// needs both to look like the text it continues. Chromium/WebKit expose
    /// them here even though caret bounds are broken; some providers store real
    /// `NSFont`/`NSColor` objects, others an "AXFont" descriptor dict and a
    /// `CGColor`.
    static func attributedStyle(of element: AXUIElement, atIndex index: Int) -> AXTextStyle {
        guard index >= 0 else { return AXTextStyle() }
        var range = CFRange(location: index, length: 1)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return AXTextStyle() }
        var ref: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXAttributedStringForRangeParameterizedAttribute as CFString, rangeValue, &ref
        ) == .success, let attributed = ref as? NSAttributedString, attributed.length > 0 else { return AXTextStyle() }
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
        return AXTextStyle(
            font: font,
            color: color([.foregroundColor, NSAttributedString.Key("AXForegroundColor")]),
            background: color([.backgroundColor, NSAttributedString.Key("AXBackgroundColor")])
        )
    }

    // MARK: - Low-level helpers

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success else { return nil }
        return ref as? T
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(ref as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func string(forRange range: CFRange, in element: AXUIElement) -> String? {
        var r = range
        guard let rangeValue = AXValueCreate(.cfRange, &r) else { return nil }
        var ref: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &ref
        ) == .success else { return nil }
        return ref as? String
    }

    private static func bounds(forRange range: CFRange, in element: AXUIElement) -> CGRect? {
        var r = range
        guard let rangeValue = AXValueCreate(.cfRange, &r) else { return nil }
        var ref: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &ref
        ) == .success, let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(ref as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }
}
