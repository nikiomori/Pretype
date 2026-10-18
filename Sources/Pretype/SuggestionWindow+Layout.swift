import AppKit
import QuartzCore

extension SuggestionWindow {
    /// How far the inline ghost may draw *in its writing direction*: the far
    /// edge of the field it belongs to, else the screen's. Without the field
    /// bound the ghost ran past the input over the send button beside it — and
    /// with a caret near the screen edge the old `max(40, …)` floor pushed a
    /// sliver of window clean off the display.
    func inlineBound(at caretRect: CGRect, rtl: Bool) -> CGFloat? {
        guard let screen = screenContaining(CGPoint(x: caretRect.midX, y: caretRect.midY)) else { return nil }
        let visible = screen.visibleFrame
        var bound = rtl ? visible.minX + 2 : visible.maxX - 2
        // Only trust the box when the caret really sits in it — a stale or
        // mis-reported frame must not clamp the ghost to nothing.
        if let field = lastHost.fieldRect, field.width > 20,
           field.insetBy(dx: -8, dy: -8).contains(CGPoint(x: caretRect.midX, y: caretRect.midY)) {
            bound = rtl ? max(bound, field.minX + 2) : min(bound, field.maxX - 2)
        }
        return bound
    }

    /// Space between the caret and that bound — what the ghost has to live in.
    func inlineRoom(at caretRect: CGRect, rtl: Bool) -> CGFloat? {
        guard let bound = inlineBound(at: caretRect, rtl: rtl) else { return nil }
        return max(0, rtl ? caretRect.minX - bound : bound - caretRect.maxX)
    }

    /// Inline needs room for at least the chunk one ⇥ takes. Less than that and
    /// the ghost is a sliver hanging off the end of the input, so the pill above
    /// the line takes over — it says the same thing, in full, and is clamped
    /// on-screen. (A suggestion is trimmed to the room in `show`, so this only
    /// still decides for the thinking dots and as a backstop.)
    func inlineHasRoom(at caretRect: CGRect) -> Bool {
        guard let room = inlineRoom(at: caretRect, rtl: ghostRTL) else { return false }
        return room >= min(ghostHeadWidth + 4, ghost.measuredSize.width)
    }

    /// Where the ghost's window sits for a caret anchor and a rendered text
    /// width. LTR grows right from the caret's right edge, RTL grows LEFT from
    /// its left edge, and neither crosses `bound` (the field's far edge, else
    /// the screen's). Both the first placement and the post-accept slide go
    /// through this, so they cannot drift apart. Pinned by a test.
    nonisolated static func ghostSpan(anchorX: CGFloat, textWidth: CGFloat,
                                      bound: CGFloat, rtl: Bool) -> (x: CGFloat, width: CGFloat) {
        let width = min(textWidth, max(0, rtl ? anchorX - bound : bound - anchorX))
        return (rtl ? anchorX - width : anchorX, width)
    }

    /// True when the text's first *letter* is right-to-left — Hebrew through
    /// Arabic Extended-A is one contiguous block, plus the Arabic presentation
    /// forms. Digits, punctuation and spaces are direction-neutral and keep the
    /// search going, so "50 ₪ שלום" still reads as RTL. Pinned by a test.
    nonisolated static func isRightToLeft(_ text: String) -> Bool {
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            return (0x0590...0x08FF).contains(scalar.value)
                || (0xFB1D...0xFDFF).contains(scalar.value)
                || (0xFE70...0xFEFF).contains(scalar.value)
        }
        return false
    }

    /// The longest prefix of `text` that renders inside `width`, cut where the
    /// line would break (a word boundary in prose, a cluster in Chinese) and
    /// with the trailing space dropped. "" when not even the first word fits —
    /// the caller then falls back to the pill, which draws it whole.
    ///
    /// This is what keeps ⇧⇥ honest: it accepts the WHOLE suggestion, so a tail
    /// that only ellipsized into "…" was text the user took unseen. Past the end
    /// of the line the host would have wrapped that tail anyway, so the
    /// single-line ghost was never a truthful preview of it either.
    nonisolated static func fittingPrefix(of text: String, font: NSFont, width: CGFloat) -> String {
        guard width > 0, !text.isEmpty else { return "" }
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        guard attributed.size().width > width else { return text }
        let ns = text as NSString
        // CoreText's own line-breaker: one call, and it knows where every
        // script may break (walking word boundaries would cost a measurement
        // per word on the keystroke path).
        let count = CTTypesetterSuggestLineBreak(
            CTTypesetterCreateWithAttributedString(attributed), 0, Double(width))
        guard count > 0, count < ns.length else { return "" }
        var cut = ns.substring(to: count)
        while cut.hasSuffix(" ") { cut.removeLast() }
        // A first word longer than the room comes back whole regardless (there
        // is always at least one break candidate) — that one doesn't fit.
        guard (cut as NSString).size(withAttributes: [.font: font]).width <= width else { return "" }
        return cut
    }

    func place(ghost ghostMode: Bool, at caretRect: CGRect) {
        // Never clamp garbage coordinates into a screen corner: no screen under
        // the caret → no overlay.
        guard let screen = screenContaining(CGPoint(x: caretRect.midX, y: caretRect.midY)) else {
            hide()
            return
        }
        let visible = screen.visibleFrame
        hideGeneration += 1   // cancel any in-flight fade-out
        let appearing = !isVisible

        ghost.isHidden = !ghostMode
        // Both the floating panel and the over-word correction draw in the pill.
        backdrop.isHidden = ghostMode
        pillText.isHidden = ghostMode
        // The inline ghost casts no shadow; the floating pill / over-word fix do.
        let wantShadow = !ghostMode
        if hasShadow != wantShadow { hasShadow = wantShadow }

        let target: NSRect
        if ghostMode {
            // Inline ghost text: it starts at the caret and runs in the writing
            // direction, hard-stopped at the field (see inlineBound) so it never
            // leaves the input, and the text ellipsizes rather than being sliced.
            let size = ghost.measuredSize
            ghostAnchorX = ghostRTL ? caretRect.minX : caretRect.maxX
            let bound = inlineBound(at: caretRect, rtl: ghostRTL)
                ?? (ghostRTL ? visible.minX + 2 : visible.maxX - 2)
            let span = Self.ghostSpan(anchorX: ghostAnchorX, textWidth: size.width,
                                      bound: bound, rtl: ghostRTL)
            let lift = Self.ghostLift(caretHeight: caretRect.height, lineHeight: size.height)
            var origin = CGPoint(x: span.x, y: caretRect.minY + lift)
            origin.y = min(max(visible.minY, origin.y), visible.maxY - size.height)
            target = NSRect(x: origin.x, y: origin.y,
                            width: max(1, span.width), height: size.height)
        } else {
            // HUD pill — the floating panel suggestion AND the inline spell-fix
            // diff. Lifted just ABOVE the line so it never covers the text you're
            // typing (panel) or the word it's correcting (fix). The left edge
            // tracks the anchor — the caret for the panel, the word start for the
            // fix — and it drops just below the line only when the caret is too
            // near the top of the screen to fit above.
            let size = pillSize()
            // Sit just above the TEXT top (font-derived), not the caret box top —
            // an inflated caret box pushed the panel too high above the line.
            let gap: CGFloat = 3
            // A fix anchors on the selection's whole box, which spans every
            // line a wrapped selection covers: sit above its TOP line (and, with
            // no room there, flip below its bottom one) — measured from the
            // box's bottom, the pill landed on the selection's own upper lines,
            // over the very text it was fixing.
            let textTop = anchorsOnSelection(currentMode)
                ? max(caretRect.maxY, caretRect.minY + lineFont)
                : caretRect.minY + lineFont
            var origin = CGPoint(x: caretRect.minX, y: textTop + gap)
            if origin.y + size.height > visible.maxY - 2 {
                origin.y = caretRect.minY - size.height - gap
            }
            origin.x = min(max(visible.minX, origin.x), visible.maxX - size.width)
            origin.y = min(max(visible.minY, origin.y), visible.maxY - size.height)
            target = NSRect(origin: origin, size: size)
        }

        setFrame(target, display: false)
        layoutSubviews(ghost: ghostMode)
        displayIfNeeded()

        if appearing {
            // A quick fade so the suggestion doesn't pop; repositions don't re-fade.
            alphaValue = 0
            orderFrontRegardless()
            onVisibilityChange?()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.09
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = 1
            }
        } else if fadingOut {
            // Caught mid-fade-out: retarget the alpha animation back to opaque.
            // On the flag, not on alpha: a hide() earlier in this same pass still
            // reads 1.0 here (AppKit steps alpha on later frames), and its
            // completion is already cancelled — skipping this left the window
            // ordered in at 0. A plain reposition animates nothing.
            fadingOut = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.06
                animator().alphaValue = 1
            }
        }
    }

    /// How far above the caret box's bottom the ghost's line box sits.
    /// TRUE centring, negative included: identical to the bottom-pin when the
    /// caret box IS the line box (native fields, glyph-anchored); a taller
    /// caret (padded single-line inputs, web line-height) lifts by the real
    /// half-leading — the old 0.4-line cap under-lifted the generous ones and
    /// sat the ghost low; a SHORTER caret (a cap-height sliver whose bottom is
    /// the baseline) drops the ghost by about the descender, which is where
    /// that baseline actually is. Past a couple of line-heights the box is the
    /// degenerate whole-view span some Electron builds report — assume typing
    /// at its bottom line and keep the old capped nudge. Pinned by a test.
    nonisolated static func ghostLift(caretHeight: CGFloat, lineHeight: CGFloat) -> CGFloat {
        caretHeight <= lineHeight * 2.2
            ? (caretHeight - lineHeight) / 2
            : lineHeight * 0.4
    }

    func layoutSubviews(ghost ghostMode: Bool) {
        let bounds = container.bounds
        if ghostMode {
            ghost.frame = bounds
        } else {
            // Pill modes and the over-word correction share the panel layout.
            backdrop.frame = bounds
            pillText.frame = bounds.insetBy(dx: pillPadH, dy: pillPadV)
            // Capsule the glass to the pill height — the signature Liquid Glass shape.
            backdrop.cornerRadius = min(16, bounds.height / 2)
        }
        
        if let highlightLayer {
            CATransaction.begin()
            CATransaction.setValue(kCFBooleanTrue, forKey: kCATransactionDisableActions)
            highlightLayer.frame = bounds
            // Match the backdrop: glass capsule (macOS 26+) or the HUD's 6 pt.
            highlightLayer.cornerRadius = ghostMode ? 4 : min(16, bounds.height / 2)
            CATransaction.commit()
        }
    }

    func setHighlight(_ highlighted: Bool) {
        if highlighted {
            if highlightLayer == nil {
                let layer = CALayer()
                layer.borderColor = NSColor.controlAccentColor.cgColor
                layer.borderWidth = 2.0
                layer.shadowColor = NSColor.controlAccentColor.cgColor
                layer.shadowOffset = .zero
                layer.shadowRadius = 8.0
                layer.shadowOpacity = 0.8
                
                // Pulse draws the eye to the caret, but an infinite autoreversing
                // glow is exactly what Reduce Motion exists to suppress. The static
                // border + glow already carries the meaning on its own.
                if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    let anim = CABasicAnimation(keyPath: "shadowOpacity")
                    anim.fromValue = 0.4
                    anim.toValue = 0.9
                    anim.duration = 1.0
                    anim.autoreverses = true
                    anim.repeatCount = .infinity
                    layer.add(anim, forKey: "pulse")
                }

                self.highlightLayer = layer
                container.layer?.addSublayer(layer)
            }
            layoutSubviews(ghost: !ghost.isHidden)
        } else {
            highlightLayer?.removeFromSuperlayer()
            highlightLayer = nil
        }
    }

    private func pillSize() -> NSSize {
        // Measured with the same options it draws with, so the box fits the
        // text exactly. A wrapping pill (fix preview, suggestion) is capped at
        // ten lines — past that the last visible line ellipsizes rather than
        // the pill growing over half the screen. A point of slack absorbs rounding.
        let line = Self.pillFont.boundingRectForFont.height
        let text = pillText.fittingSize(maxWidth: 460, maxHeight: pillWraps ? ceil(line * 10) : 10_000)
        pillPadV = text.height > line * 1.5 ? 6 : 4
        return NSSize(width: text.width + 1 + pillPadH * 2, height: text.height + pillPadV * 2)
    }

    private func screenContaining(_ point: CGPoint) -> NSScreen? {
        // Slight inset tolerance: a caret at the very screen edge still counts.
        NSScreen.screens.first { $0.frame.insetBy(dx: -10, dy: -10).contains(point) }
    }
}
