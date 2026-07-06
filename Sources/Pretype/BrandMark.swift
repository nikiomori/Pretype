import AppKit

/// The Pretype brand mark — a double chevron flowing into a text caret (`»|`).
///
/// Drawn in code (not loaded from a bundled asset) so it stays vector-crisp at
/// any menu-bar size / backing scale and renders as a proper template image that
/// adapts to light/dark menu bars. The chevrons are constant; the caret morphs
/// to signal engine state, so the icon is recognisably Pretype in every state
/// instead of being swapped out for a generic SF Symbol. Coordinates mirror
/// `Assets/pretype-glyph.svg` and use a top-left (flipped) coordinate space.
enum BrandMark {
    enum State: String { case ready, disabled, preparing, failed }

    /// Template image for the `NSStatusItem` button. `height` is in points.
    /// `phase` (0…2) animates the typing dots of the `.preparing` state; the
    /// caller advances it on its refresh timer.
    static func statusItemImage(_ state: State = .ready, phase: Int = 0, height: CGFloat = 13) -> NSImage {
        // Native design bounding box (1024 canvas), padded for the stroke caps.
        let nx: CGFloat = 285, ny: CGFloat = 329, nw: CGFloat = 494, nh: CGFloat = 366
        let size = NSSize(width: (nw / nh) * height, height: height)

        let image = NSImage(size: size, flipped: true) { rect in
            let s = min(rect.width / nw, rect.height / nh)
            let offsetX = rect.minX + (rect.width - nw * s) / 2 - s * nx
            let offsetY = rect.minY + (rect.height - nh * s) / 2 - s * ny
            let xform = NSAffineTransform()
            xform.translateX(by: offsetX, yBy: offsetY)
            xform.scale(by: s)
            xform.concat()

            // Template images are masked by alpha; a dimmed stroke reads as "off".
            let alpha: CGFloat = (state == .disabled) ? 0.38 : 1.0
            NSColor.black.withAlphaComponent(alpha).set()

            // Two chevrons pointing toward the caret — the constant brand element.
            let chevrons = NSBezierPath()
            chevrons.lineWidth = 74
            chevrons.lineCapStyle = .round
            chevrons.lineJoinStyle = .round
            chevrons.move(to: NSPoint(x: 322, y: 366))
            chevrons.line(to: NSPoint(x: 454, y: 512))
            chevrons.line(to: NSPoint(x: 322, y: 658))
            chevrons.move(to: NSPoint(x: 474, y: 366))
            chevrons.line(to: NSPoint(x: 606, y: 512))
            chevrons.line(to: NSPoint(x: 474, y: 658))
            chevrons.stroke()

            // The caret carries the state.
            let caret = NSBezierPath()
            caret.lineWidth = 56
            caret.lineCapStyle = .round
            caret.lineJoinStyle = .round
            switch state {
            case .ready, .disabled: // I-beam text cursor
                caret.move(to: NSPoint(x: 695, y: 380)); caret.line(to: NSPoint(x: 695, y: 644))
                caret.move(to: NSPoint(x: 648, y: 372)); caret.line(to: NSPoint(x: 742, y: 372))
                caret.move(to: NSPoint(x: 648, y: 652)); caret.line(to: NSPoint(x: 742, y: 652))
                caret.stroke()
            case .preparing: // typing dots (model loading / downloading)
                for i in 0...(phase % 3) {
                    let cx: CGFloat = 647 + CGFloat(i) * 48
                    NSBezierPath(ovalIn: NSRect(x: cx - 22, y: 598, width: 44, height: 44)).fill()
                }
            case .failed: // exclamation (engine error / missing permission)
                caret.move(to: NSPoint(x: 695, y: 372)); caret.line(to: NSPoint(x: 695, y: 582))
                caret.stroke()
                let dot = NSBezierPath(ovalIn: NSRect(x: 695 - 30, y: 646 - 30, width: 60, height: 60))
                dot.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
