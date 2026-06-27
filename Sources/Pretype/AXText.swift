import AppKit
import ApplicationServices
import Carbon.HIToolbox

struct TextContext {
    /// Text immediately before the caret, capped at `maxChars`.
    let textBeforeCaret: String
    /// A short window of text after the caret (for duplication checks).
    let textAfterCaret: String
    /// Caret rectangle in Cocoa (bottom-left origin) screen coordinates.
    let caretRect: CGRect?
    /// Host font point size, when we could measure it (web fallback). The ghost
    /// overlay matches it so the suggestion reads as inline text; `nil` → derive
    /// from the caret height.
    let fontSize: CGFloat?
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
    /// Most of those still engage system-wide secure input, so this is our reliable
    /// cross-app password guard: while it's on, we read no field text at all.
    static func isSecureInputActive() -> Bool {
        IsSecureEventInputEnabled()
    }

    static func isEditableTextElement(_ element: AXUIElement) -> Bool {
        guard let role: String = attribute(element, kAXRoleAttribute),
              editableRoles.contains(role) else { return false }
        guard selectedRange(of: element) != nil else { return false }
        // macOS refuses to expose secure-field contents anyway; don't even attach.
        if let subrole: String = attribute(element, kAXSubroleAttribute), subrole == "AXSecureTextField" {
            return false
        }
        return true
    }

    /// Non-empty selection in the element, if any.
    static func selectionInfo(for element: AXUIElement) -> SelectionInfo? {
        if isSecureInputActive() { return nil }
        guard let range = selectedRange(of: element), range.length > 0 else { return nil }
        guard let text: String = attribute(element, kAXSelectedTextAttribute), !text.isEmpty else { return nil }
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
            guard let textBeforeCaret = text else { return nil }
            var textAfterCaret = ""
            if let total: Int = attribute(element, kAXNumberOfCharactersAttribute) {
                let afterLength = min(192, total - caret)
                if afterLength > 0 {
                    textAfterCaret = string(forRange: CFRange(location: caret, length: afterLength), in: element) ?? ""
                }
            }
            // Measure the real host font (NSTextView-backed fields expose it via
            // AXAttributedStringForRange) so the ghost matches its size exactly
            // and the overlay anchors to a true line height — not an estimate from
            // the caret box, which varies per app. nil → the window falls back.
            let hostFont = attributedFont(of: element, atIndex: max(0, caret - 1))?.pointSize
            return TextContext(textBeforeCaret: textBeforeCaret, textAfterCaret: textAfterCaret,
                               caretRect: caretRect, fontSize: hostFont)
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
        let total: Int = attribute(element, kAXNumberOfCharactersAttribute) ?? value.count
        let hostFont = attributedFont(of: element, atIndex: total - 1)
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
            return TextContext(textBeforeCaret: String(value.suffix(maxChars)), textAfterCaret: "",
                               caretRect: anchor, fontSize: size)
        }
        // A marker that is NOT a collapsed caret spans the whole run — that's a
        // selection or the placeholder/idle state (e.g. Claude's "Describe a
        // task…"). Don't fabricate a completion there: this is the robust
        // placeholder guard, since Electron doesn't expose AXPlaceholderValue.
        if marker != nil {
            DebugLog.shared.log("AX", "web/Electron: marker spans the run (selection/placeholder) — no suggestion")
            return nil
        }

        // No marker at all (older Electron / non-Chromium web view): estimate the
        // caret at the end of the last line by measuring the text width. The
        // biggest source of drift is a wrong font, so use the real one if exposed.
        let font = hostFont ?? NSFont.systemFont(ofSize: max(12, min(17, frame.height * 0.36)))
        let fontSize = font.pointSize
        let lastLine = value.components(separatedBy: "\n").last ?? value
        let textWidth = (lastLine as NSString).size(withAttributes: [.font: font]).width
        let lineHeight = ceil(fontSize * 1.35)
        let caretX = min(frame.minX + 8 + textWidth, frame.maxX - 24)
        let caretBox = CGRect(x: caretX, y: frame.maxY - lineHeight - 4, width: 1, height: lineHeight)
        guard let anchor = onScreen(cocoaRect(caretBox)) else { return nil }
        DebugLog.shared.log("AX", "web/Electron fallback: \(value.count) chars, "
            + "font \(hostFont != nil ? "real " : "guessed ")\(Int(fontSize))pt, caret≈end-of-text")
        return TextContext(textBeforeCaret: String(value.suffix(maxChars)), textAfterCaret: "",
                           caretRect: anchor, fontSize: fontSize)
    }

    // MARK: - Caret geometry

    /// A caret rect only when AX gives plausible geometry that sits inside the
    /// field. Electron returns x=0 / off-field garbage, which we reject here so
    /// the caller can fall back to anchoring on the field box.
    private static func validCaretRect(in element: AXUIElement, caret: Int, frame: CGRect?) -> CGRect? {
        var rect = bounds(forRange: CFRange(location: caret, length: 0), in: element)
        // The previous character's bounds track the real glyph line. Anchor the
        // caret to them when the zero-length caret rect is missing OR sits ABOVE
        // them — TextEdit reports the empty-range caret a whole line too high
        // (AX-y above the glyphs), which floated every overlay up off the text.
        // A legitimate line start puts the caret BELOW the prev char, so this
        // only rewrites the genuinely-wrong case.
        if caret > 0, let prev = bounds(forRange: CFRange(location: caret - 1, length: 1), in: element),
           prev != .zero, prev.height >= 4 {
            if rect == nil || rect == .zero || rect!.minY + 1 < prev.minY {
                rect = CGRect(x: prev.maxX, y: prev.minY, width: 1, height: prev.height)
            }
        }
        guard let r = rect, r != .zero, r.height >= 4, r.height <= 200 else { return nil }
        if let frame, frame != .zero,
           !frame.insetBy(dx: -24, dy: -24).contains(CGPoint(x: r.midX, y: r.midY)) {
            return nil  // caret reported outside its own field → garbage
        }
        return onScreen(cocoaRect(r))
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
        let attrFont = lastIdx >= 0 ? attributedFont(of: element, atIndex: lastIdx) : nil
        let lastCharBounds = lastIdx >= 0 ? bounds(forRange: CFRange(location: lastIdx, length: 1), in: element) : nil
        let fontDesc = attrFont.map { "\($0.fontName) \(Int($0.pointSize))pt" } ?? "nil"
        let valueDesc = value.map { "\"\($0.suffix(24))\"(\($0.count))" } ?? "nil"
        // Real geometry candidates: whole-text bounds, marker caret, and the
        // child AX tree (Chromium often keeps real frames on inner text nodes).
        let wholeBounds = (nChars ?? 0) > 0 ? bounds(forRange: CFRange(location: 0, length: nChars!), in: element) : nil
        let kids = probeChildren(element, prefix: "\n    ", depth: 3)
        return "role=\(role)/\(subrole) frame=\(fmt(elementFrame(element))) "
            + "range=\(range.map { "\($0.location)+\($0.length)" } ?? "nil") "
            + "value=\(valueDesc) nChars=\(nChars.map(String.init) ?? "nil") "
            + "caret=\(fmt(caretBounds)) prevChar=\(fmt(prevBounds)) "
            + "attrFont=\(fontDesc) lastChar=\(fmt(lastCharBounds)) whole=\(fmt(wholeBounds)) "
            + "marker=\(fmt(webCaretBounds(element)))\(extra)\(kids)"
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
        let r = ctx.caretRect.map { "(\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height)))" } ?? "nil"
        return "ctx: text=\"…\(ctx.textBeforeCaret.suffix(16))\" caret=\(r) font=\(ctx.fontSize.map { String(Int($0)) } ?? "nil")"
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

    /// The font of the character at `index`, via `AXAttributedStringForRange`.
    /// Chromium/WebKit expose it here even though caret bounds are broken; some
    /// providers store an `NSFont` directly, others an "AXFont" descriptor dict.
    static func attributedFont(of element: AXUIElement, atIndex index: Int) -> NSFont? {
        guard index >= 0 else { return nil }
        var range = CFRange(location: index, length: 1)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var ref: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXAttributedStringForRangeParameterizedAttribute as CFString, rangeValue, &ref
        ) == .success, let attributed = ref as? NSAttributedString, attributed.length > 0 else { return nil }
        if let font = attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
            return font
        }
        if let dict = attributed.attribute(NSAttributedString.Key("AXFont"), at: 0, effectiveRange: nil) as? [String: Any],
           let size = (dict["AXFontSize"] as? NSNumber)?.doubleValue, size > 0 {
            let name = dict["AXFontName"] as? String
            return name.flatMap { NSFont(name: $0, size: size) } ?? .systemFont(ofSize: size)
        }
        return nil
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
