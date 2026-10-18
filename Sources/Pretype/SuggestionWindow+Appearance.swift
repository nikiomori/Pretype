import AppKit
import QuartzCore

extension SuggestionWindow {
    /// Point the whole overlay at the appearance of what the caret actually sits
    /// on, not at the system theme. ONE channel for every mode: the ghost's ink
    /// and halo, the pill's label, the correction diff, and the backdrop
    /// materials are all semantic colors, so they resolve against this together
    /// and cannot contradict each other. (On macOS 26 the pill's glass is clear
    /// — it takes the backdrop's tone, so a black label on a dark app was as
    /// unreadable as an invisible ghost.)
    ///
    /// Four sources, strictly in this order, because each later one is weaker
    /// evidence:
    ///   1. the probe *looked* at the pixels under the caret (Screen Recording);
    ///      nothing an app reports about itself outranks having looked,
    ///   2. the field's own background, when AX reports a concrete one — the
    ///      same question answered directly, free, no permission,
    ///   3. the field's ink, which answers it by implication,
    ///   4. nil: follow the system theme, which knows nothing about a themed app.
    func resolveAppearance() {
        func adopt(_ surface: CGFloat, _ source: String) {
            let name: NSAppearance.Name = surface < 0.5 ? .darkAqua : .aqua
            logTone("\(source) → \(name == .darkAqua ? "dark" : "light")")
            if appearance?.name != name { appearance = NSAppearance(named: name); repaint() }
        }
        if let probed = backgroundProbe.appearance {
            return adopt(probed.name == .darkAqua ? 0 : 1, "probe")
        }
        if let bg = lastHost.background.flatMap(Self.staticLuminance) {
            return adopt(bg, "field bg \(String(format: "%.2f", bg))")
        }
        // Only an ink at the extremes is evidence: a mid-gray (a placeholder, a
        // secondary label) is legible on either surface and would flip the whole
        // overlay on a coin toss. Dark ink ⇒ light surface, and vice versa.
        if let ink = lastHost.color.flatMap(Self.staticLuminance), ink < 0.25 || ink > 0.75 {
            return adopt(1 - ink, "field ink \(String(format: "%.2f", ink))")
        }
        logTone("system")
        if appearance != nil { appearance = nil; repaint() }
    }

    /// Nothing here caches an appearance-aware color, so a flip just repaints.
    private func repaint() {
        container.needsDisplay = true
        ghost.needsDisplay = true
    }

    /// One line in the Debug Console whenever that decision changes: which of
    /// the four sources answered, and what it said. This is the only way to tell
    /// from the outside why an overlay came out unreadable in some app.
    private func logTone(_ verdict: String) {
        guard verdict != lastToneLog else { return }
        lastToneLog = verdict
        DebugLog.shared.log("SHOW", "overlay tone: \(verdict)")
    }

    /// A color's sRGB luminance — but only when it means the same thing under
    /// both appearances. AppKit archives *semantic* colors across the AX
    /// boundary intact, and an unarchived dynamic color resolves against OUR
    /// process's appearance, not the host's: a dark-themed field under a light
    /// system then reports black ink for text it draws white, which painted a
    /// black ghost on black. Such a color describes our theme, not the field —
    /// discard it and let the appearance path answer. Internal: the polarity and
    /// this discard are what the ghost's readability turns on, so both are pinned
    /// by a test.
    static func staticLuminance(_ color: NSColor) -> CGFloat? {
        var resolved: [CGFloat] = []
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            guard let appearance = NSAppearance(named: name) else { return nil }
            appearance.performAsCurrentDrawingAppearance {
                guard let c = color.usingColorSpace(.sRGB) else { return }
                resolved.append(0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent)
            }
        }
        guard resolved.count == 2, abs(resolved[0] - resolved[1]) < 0.02 else { return nil }
        return resolved[0]
    }

    /// A semantic color with alpha that STAYS semantic. `withAlphaComponent`
    /// on a catalog color resolves it against the calling context's appearance
    /// and returns a frozen component color — the ghost built its ink that
    /// way, so it wore the SYSTEM tone no matter what the resolver set the
    /// window to: white-on-white on a light page under a dark system, with
    /// the halo frozen dark to match. A dynamic-provider color defers both
    /// the resolution and the alpha to draw time, against the window's
    /// appearance — back in the same tone channel as everything else, async
    /// probe flips included (repaint re-resolves, no string rebuild). Pinned
    /// by a test.
    static func dynamicAlpha(_ base: NSColor, _ alpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            var resolved = base
            appearance.performAsCurrentDrawingAppearance {
                resolved = base.usingColorSpace(.sRGB) ?? base
            }
            return resolved.withAlphaComponent(alpha)
        }
    }

    /// `dim` scales the opacity setting: 1 for the ⇥ chunk, less for the tail.
    func ghostString(_ string: String, dim: CGFloat) -> NSAttributedString {
        NSAttributedString(string: string, attributes: ghostAttributes(dim: dim))
    }

    /// The ghost's ink strength for `dim`: the opacity setting scaled by it.
    func ghostStrength(_ dim: CGFloat) -> CGFloat {
        // "Increase contrast" exists to stop exactly this: text you have to
        // squint at. Floor the opacity SETTING, not the finished ink: `dim`
        // still scales it, so the head-vs-tail split survives (it's what shows
        // how far one ⇥ reaches) and the ⇥ chunk stays visibly lighter than the
        // words the user actually typed — at full label alpha the ghost reads
        // as already committed text.
        var opacity = CGFloat(Settings.ghostOpacity)
        if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast { opacity = max(0.85, opacity) }
        return opacity * dim
    }

    func ghostAttributes(dim: CGFloat) -> [NSAttributedString.Key: Any] {
        // Both semantic, so they resolve together at draw time against the
        // window's appearance (see resolveAppearance) and can never disagree:
        // the paper tone is by definition the label tone's opposite. The ghost
        // has no backdrop, so that opposite becomes a soft halo — an outline
        // separating it from whatever the host draws underneath, where the old
        // window-background tone was a gray smudge over the glyph edges.
        let halo = NSShadow()
        halo.shadowColor = Self.dynamicAlpha(.textBackgroundColor, 0.4)
        halo.shadowBlurRadius = 2.5
        halo.shadowOffset = .zero
        // Single line, ellipsized when the window can't fit the tail. An RTL
        // ghost hangs off the caret on its right edge, so it has to be laid out
        // right-aligned in its own writing direction — left-aligned it would
        // start at the far end of the window with a gap at the caret.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        if ghostRTL {
            paragraph.baseWritingDirection = .rightToLeft
            paragraph.alignment = .right
        }
        return [
            .font: ghostFont,
            .foregroundColor: Self.dynamicAlpha(.labelColor, ghostStrength(dim)),
            .shadow: halo,
            .paragraphStyle: paragraph,
        ]
    }
}
