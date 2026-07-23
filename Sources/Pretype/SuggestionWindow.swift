import AppKit
import QuartzCore

/// What the caret-side panel is currently communicating.
enum SuggestionDisplayMode {
    /// Ghost text the user can accept with Tab.
    case suggestion(String)
    /// The model is generating; `phase` animates the dots.
    case thinking(Int)
    /// Engine not ready yet (downloading/loading a model).
    case status(String)
    /// Something is broken.
    case error(String)
    /// Neutral hint, e.g. the ⌥⇥ fix-selection affordance.
    case hint(String)
    /// A proposed fix for the selection, awaiting the user's accept/cancel.
    case fixPreview(String)
    /// A spell-fix shown in a pill ABOVE the mistyped word (Cotypist-style):
    /// the original struck through, an arrow, then the proposed fix. Tab to apply.
    case correction(original: String, fix: String)
}

/// Draws one line of attributed text with its **baseline pinned to the view's
/// bottom edge** (plus the font descender), so the completion sits exactly on
/// the line it continues — no NSTextField vertical-centering guesswork.
private final class GhostTextView: NSView {
    var attributed = NSAttributedString() {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }

    /// Tight size of the current text; height is the font's full line box.
    var measuredSize: NSSize {
        let s = attributed.size()
        return NSSize(width: ceil(s.width) + 1, height: ceil(s.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        // Drawn INTO a rect, not at a point: the truncating paragraph style then
        // ellipsizes a tail the window is too narrow for, instead of the window
        // edge slicing a glyph in half. The rect is the text's own line box at
        // the view's bottom, which keeps the baseline exactly where `draw(at:
        // .zero)` put it however tall the view is.
        attributed.draw(in: NSRect(x: 0, y: 0, width: bounds.width, height: attributed.size().height))
    }
}

/// Borderless, non-activating floating panel that renders the completion.
///
/// A real suggestion draws as **chromeless inline ghost text** — gray, sized to
/// the host font, baseline-aligned right at the caret — so it reads like text the
/// field already contains (the Cotypist look). Engine-state notices (downloading
/// / error / the ⌥⇥-fix affordance) fall back to a small HUD pill so they stay
/// legible against any background.
final class SuggestionWindow: NSPanel {
    private let container = NSView()
    private let pillLabel = NSTextField(labelWithString: "")
    private let ghost = GhostTextView()
    private var highlightLayer: CALayer?

    /// Panel background. Liquid Glass (`NSGlassEffectView`) on macOS 26+, the
    /// classic HUD blur (`NSVisualEffectView`) below it. The label lives in
    /// `pillHost`, a SIBLING stacked above the backdrop — not inside it.
    /// NOTE: never dim the backdrop via alphaValue — glass/blur materials lose
    /// their blending when translucent, and the text behind bleeds through sharp
    /// (tried; unreadable). The pill must stay opaque to do its job.
    private let pillHost = NSView()
    private let visualBackdrop = NSVisualEffectView()
    private var glassBackdrop: NSView?
    private var panelBackdrop: NSView { glassBackdrop ?? visualBackdrop }

    private let pillPadH: CGFloat = 9
    private let pillPadV: CGFloat = 4

    /// Inline ghost text vs a floating panel beside the caret. Set by the
    /// controller from `Settings.suggestionPresentation`.
    var presentation: SuggestionPresentation = .inline

    /// Flips the window's appearance to match the host app's background under
    /// the caret (dark editor ↔ light page), so every semantic color in the
    /// pill resolves against what it's actually drawn over. Only a *fallback*
    /// for the ghost: it needs Screen Recording, and where that isn't granted
    /// the ghost took the system theme — white-on-white in a light app under a
    /// dark system. `host.color` answers the same question for free.
    private let backgroundProbe = BackgroundProbe()

    /// Font the ghost draws in — the host's own when AX exposed it.
    private var ghostFont: NSFont = .systemFont(ofSize: 13)
    /// Width of the ⇥-acceptable chunk of the current ghost: the part that must
    /// fit inline for inline to be worth doing at all.
    private var ghostHeadWidth: CGFloat = 0
    /// Resolved host-font size for the current caret — drives both the ghost size
    /// and the vertical anchoring of every mode, so placement stays consistent
    /// across apps regardless of the caret box height they report.
    private var lineFont: CGFloat = 13
    /// The caret of the current suggestion, so a panel can re-place on accept.
    private var lastCaret = CGRect.zero
    /// Font/color/box of the field under that caret.
    private var lastHost = HostTextStyle()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        container.wantsLayer = true

        pillLabel.lineBreakMode = .byTruncatingTail
        pillLabel.maximumNumberOfLines = 1
        pillLabel.font = .systemFont(ofSize: 13)
        pillLabel.textColor = .secondaryLabelColor
        pillHost.addSubview(pillLabel)

        if #available(macOS 26.0, *) {
            // Liquid Glass — the macOS 26 material that refracts whatever is
            // behind the caret. Corner is set per-layout to capsule the pill.
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 11
            glassBackdrop = glass
            container.addSubview(glass)
        } else {
            visualBackdrop.material = .hudWindow
            visualBackdrop.state = .active
            visualBackdrop.blendingMode = .behindWindow
            visualBackdrop.wantsLayer = true
            visualBackdrop.layer?.cornerRadius = 6
            visualBackdrop.layer?.masksToBounds = true
            container.addSubview(visualBackdrop)
        }
        container.addSubview(pillHost)
        container.addSubview(ghost)
        contentView = container
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// `caretRect` is in Cocoa (bottom-left origin) screen coordinates; `host`
    /// describes the field it sits in (font, text color, box) when AX exposed
    /// it — each field missing falls back to an estimate from the caret box.
    func show(mode: SuggestionDisplayMode, at caretRect: CGRect, host: HostTextStyle = HostTextStyle()) {
        lastCaret = caretRect
        // Engine notices (CaretIndicator) carry no host info, and the thinking
        // dots are inline ghost text too — keep the style already resolved for
        // this field so they aren't painted in the system theme's ink over a
        // field that contradicts it. Dropped the moment the caret leaves that
        // field, so a focus change can't carry a stale box forward.
        let sameField = lastHost.fieldRect?.contains(CGPoint(x: caretRect.midX, y: caretRect.midY)) ?? false
        if !host.isEmpty || !sameField { lastHost = host }
        // The probe's verdict is the top rung of one shared resolver — it must
        // not assign `appearance` itself, or a nil cache (no Screen Recording)
        // would clobber the AX-derived verdict on every keystroke.
        backgroundProbe.refresh(near: caretRect) { [weak self] _ in self?.resolveAppearance() }
        // The host's own font, family included, when we have it: the ghost then
        // reads as the field's next word instead of a system-font impostor
        // pasted over a monospace editor, and its metrics land the baseline
        // exactly. Otherwise infer the size from the caret height over a typical
        // line-height ratio (1.30, not 1.18 — 1.18 oversized the ghost, which
        // read as "floating too high"). One value drives text size AND the
        // vertical anchors below, so all modes line up the same way everywhere.
        if let font = lastHost.font, (6...96).contains(font.pointSize) {
            lineFont = font.pointSize
            ghostFont = font
        } else {
            lineFont = max(11, min(34, caretRect.height / 1.30))
            ghostFont = .systemFont(ofSize: min(30, max(11, lineFont.rounded())))
        }

        // Inline vs pill is decided per placement, not per setting: the ghost
        // needs room to the right of the caret INSIDE the field, and that room
        // has to be empty — mid-line it would be painted over the user's own
        // words, and at the end of a full input there is none at all.
        var ghostMode = presentation == .inline && isGhostable(mode) && !lastHost.textFollowsCaret
        applyContent(mode, ghost: ghostMode)
        if ghostMode, !inlineHasRoom(at: caretRect) {
            ghostMode = false
            applyContent(mode, ghost: false)
        }
        place(ghost: ghostMode, at: caretRect)

        if case .suggestion = mode, !Settings.onboardingCompleted {
            setHighlight(true)
        } else {
            setHighlight(false)
        }
    }

    /// The focus moved to a different field: everything remembered about the
    /// old one — its style and box, and the probe's pixel verdict — is evidence
    /// about the wrong place, and each would outrank what the new field reports
    /// (the probe by rank, the box via the same-field retention in `show`).
    /// Called on focus changes, not from `hide()`: dismissals within one field
    /// must keep their measured style.
    func fieldChanged() {
        lastHost = HostTextStyle()
        backgroundProbe.invalidate()
    }

    /// Monotonic token: a `show` between fade-out start and completion cancels
    /// the pending `orderOut`, so a new suggestion never gets yanked away.
    private var hideGeneration = 0

    func hide() {
        guard isVisible else { setHighlight(false); return }
        hideGeneration += 1
        let gen = hideGeneration
        // Symmetric to the 0.09 s fade-in: dismissal melts instead of popping.
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.hideGeneration == gen else { return }
            // Drop the accent glow WITH the fade, not a frame before it — any
            // show() landing mid-fade fails the generation check and sets its
            // own highlight, so this can't clear a live one.
            self.setHighlight(false)
            self.orderOut(nil)
            self.alphaValue = 1
        })
    }

    /// Show `mode` briefly, then fade it — unless any later `show()`/`hide()`
    /// supersedes it first. Gated on `hideGeneration` (bumped by every `place()`
    /// and `hide()`), so a completion ghost, correction pill, or status overlay
    /// that takes the window in the meantime cancels the pending auto-hide: the
    /// timed hide can never blank a live overlay of any kind.
    func showTransient(_ mode: SuggestionDisplayMode, at caretRect: CGRect,
                       host: HostTextStyle = HostTextStyle(), hideAfter: TimeInterval = 1.8) {
        show(mode: mode, at: caretRect, host: host)   // bumps hideGeneration via place()
        let gen = hideGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + hideAfter) { [weak self] in
            guard let self, self.hideGeneration == gen else { return }
            self.hide()
        }
    }

    /// After the user accepts `accepted`, slide the ghost forward by that word's
    /// rendered width and show `remaining` in place — no hide, no re-fade. The
    /// next AX refresh corrects any sub-pixel drift, so word-by-word Tab stays
    /// smooth instead of blinking.
    func advance(past accepted: String, remaining: String) {
        guard isVisible, !remaining.isEmpty else { return }
        // `!ghost.isHidden`, not the setting: inline that fell back to the pill
        // for lack of room must re-render as a pill, not slide a hidden ghost.
        guard !ghost.isHidden else {
            // Panel: re-render the box with the remaining text where it sits.
            show(mode: .suggestion(remaining), at: lastCaret, host: lastHost)
            return
        }
        let dx = ceil((accepted as NSString).size(withAttributes: [.font: ghostFont]).width)
        ghost.attributed = suggestionGhost(remaining)
        var f = frame
        f.origin.x += dx
        // Cap to the field (then the screen) so the remainder doesn't overhang for
        // a frame before the next AX refresh re-places it.
        let limit = inlineLimitX(at: CGRect(x: f.origin.x, y: lastCaret.minY,
                                            width: 1, height: lastCaret.height))
            ?? f.origin.x + ghost.measuredSize.width
        f.size.width = max(1, min(ghost.measuredSize.width, limit - f.origin.x))
        setFrame(f, display: false)
        layoutSubviews(ghost: true)
        displayIfNeeded()
    }

    /// Modes that *can* draw as chromeless inline ghost text; engine notices and
    /// fixes are always pills. Whether one actually does also depends on there
    /// being room at the caret — see `inlineHasRoom`.
    private func isGhostable(_ mode: SuggestionDisplayMode) -> Bool {
        switch mode {
        case .suggestion, .thinking: return true
        case .status, .error, .hint, .fixPreview, .correction: return false
        }
    }

    private func applyContent(_ mode: SuggestionDisplayMode, ghost ghostMode: Bool) {
        switch mode {
        case .suggestion(let s):
            if ghostMode {
                ghost.attributed = suggestionGhost(s)
            } else {
                pillLabel.attributedStringValue = panelSuggestion(s)
            }
        case .thinking(let phase):
            // A faint ellipsis pulsing while the model runs — ghost at the caret
            // inline, or in the pill when in panel mode.
            let dots = String(repeating: "·", count: (phase % 3) + 1)
            if ghostMode {
                ghost.attributed = ghostString(dots, dim: 0.6)
                ghostHeadWidth = 0
            } else {
                pillLabel.attributedStringValue = pill(dots, .tertiaryLabelColor)
            }
        case .status(let s):
            pillLabel.attributedStringValue = pill("⏳ \(s)", .tertiaryLabelColor)
        case .error(let s):
            pillLabel.attributedStringValue = pill("⚠︎ \(s)", .systemOrange)
        case .hint(let s):
            pillLabel.attributedStringValue = pill(s, .tertiaryLabelColor)
        case .fixPreview(let s):
            pillLabel.attributedStringValue = fixPreview(s)
        case .correction(let original, let fix):
            pillLabel.attributedStringValue = correctionDiff(original: original, fix: fix)
        }
    }

    private static func keycap(_ text: String) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let bgColor = dynamicAlpha(.labelColor, 0.08)
        let fgColor = NSColor.secondaryLabelColor

        let attr = NSMutableAttributedString(string: "\u{00A0}\(text)\u{00A0}", attributes: [
            .font: font,
            .foregroundColor: fgColor,
            .backgroundColor: bgColor,
            .kern: 0.5
        ])
        attr.addAttribute(.baselineOffset, value: 0.5, range: NSRange(location: 0, length: attr.length))
        return attr
    }

    /// A proposed correction: the fixed text in full strength, then a faint
    /// "⏎ apply · esc" affordance so the user knows it is awaiting confirmation.
    private func fixPreview(_ s: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
        ])
        result.append(NSAttributedString(string: "   "))
        result.append(Self.keycap("⏎ Return"))
        result.append(NSAttributedString(string: "   "))
        result.append(Self.keycap("esc"))
        return result
    }

    /// An inline spell-fix as a readable diff: the mistyped word muted with a
    /// quiet red-tinted strikethrough (a hint of "wrong", not a shout), an
    /// arrow, then the proposed fix in the system accent — noticeable without
    /// being loud. A faint ⇥ marks how to apply it.
    private func correctionDiff(original: String, fix: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: original, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor,
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .strikethroughColor: NSColor.systemRed.withAlphaComponent(0.45),
        ])
        result.append(NSAttributedString(string: "  →  ", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]))
        result.append(NSAttributedString(string: fix, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.controlAccentColor,
        ]))
        result.append(NSAttributedString(string: "   "))
        result.append(Self.keycap(Settings.hotkeyStyle.label))
        return result
    }

    /// The classic panel content: the suggestion text (⇥-acceptable chunk a step
    /// brighter) plus a faint accept hint. The keycap tutoring disappears once
    /// accepting is muscle memory, so the pill stays compact for regulars.
    private func panelSuggestion(_ s: String) -> NSAttributedString {
        let head = SuggestionController.firstWordChunk(of: s)
        let result = NSMutableAttributedString(string: head, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
        ])
        let tail = String(s.dropFirst(head.count))
        if !tail.isEmpty {
            result.append(NSAttributedString(string: tail, attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        guard Stats.lifetimeAccepted < 20 else { return result }
        let style = Settings.hotkeyStyle
        result.append(NSAttributedString(string: "   "))
        result.append(Self.keycap(style.label))
        result.append(NSAttributedString(string: " word   ", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]))
        result.append(Self.keycap(style.shiftLabel))
        result.append(NSAttributedString(string: " all", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]))
        return result
    }

    /// Ghost text with the ⇥-acceptable chunk (same split the controller uses)
    /// a step brighter than the tail, so what one Tab takes is visible at a glance.
    private func suggestionGhost(_ s: String) -> NSAttributedString {
        let head = SuggestionController.firstWordChunk(of: s)
        let result = NSMutableAttributedString(attributedString: ghostString(head, dim: 1))
        ghostHeadWidth = ceil(result.size().width)
        let tail = String(s.dropFirst(head.count))
        if !tail.isEmpty { result.append(ghostString(tail, dim: 0.72)) }
        return result
    }

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
    private func resolveAppearance() {
        func adopt(_ surface: CGFloat, _ source: String) {
            let name: NSAppearance.Name = surface < 0.5 ? .darkAqua : .aqua
            logTone("\(source) → \(name == .darkAqua ? "dark" : "light")")
            if appearance?.name != name { appearance = NSAppearance(named: name); repaint() }
        }
        if let probed = backgroundProbe.appearance {
            logTone("probe → \(probed.name == .darkAqua ? "dark" : "light")")
            if appearance?.name != probed.name { appearance = probed; repaint() }
            return
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
    private var lastToneLog = ""
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
    private func ghostString(_ string: String, dim: CGFloat) -> NSAttributedString {
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
        // Single line, ellipsized when the window can't fit the tail.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: string, attributes: [
            .font: ghostFont,
            .foregroundColor: Self.dynamicAlpha(.labelColor, CGFloat(Settings.ghostOpacity) * dim),
            .shadow: halo,
            .paragraphStyle: paragraph,
        ])
    }

    private func pill(_ string: String, _ color: NSColor) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: color,
        ])
    }

    /// How far right inline ghost text may draw: the end of the field it belongs
    /// to, else the screen. Without the field bound the ghost ran past the input
    /// over the send button beside it — and with a caret near the screen edge the
    /// old `max(40, …)` floor pushed a sliver of window clean off the display.
    private func inlineLimitX(at caretRect: CGRect) -> CGFloat? {
        guard let screen = screenContaining(CGPoint(x: caretRect.midX, y: caretRect.midY)) else { return nil }
        var limit = screen.visibleFrame.maxX - 2
        // Only trust the box when the caret really sits in it — a stale or
        // mis-reported frame must not clamp the ghost to nothing.
        if let field = lastHost.fieldRect, field.width > 20,
           field.insetBy(dx: -8, dy: -8).contains(CGPoint(x: caretRect.midX, y: caretRect.midY)) {
            limit = min(limit, field.maxX - 2)
        }
        return limit
    }

    /// Inline needs room for at least the chunk one ⇥ takes; the tail may
    /// ellipsize. Less than that and the ghost is a sliver hanging off the end
    /// of the input, so the pill above the line takes over — it says the same
    /// thing, in full, and is clamped on-screen.
    private func inlineHasRoom(at caretRect: CGRect) -> Bool {
        guard let limit = inlineLimitX(at: caretRect) else { return false }
        return limit - caretRect.maxX >= min(ghostHeadWidth + 4, ghost.measuredSize.width)
    }

    private func place(ghost ghostMode: Bool, at caretRect: CGRect) {
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
        panelBackdrop.isHidden = ghostMode
        pillHost.isHidden = ghostMode
        // The inline ghost casts no shadow; the floating pill / over-word fix do.
        let wantShadow = !ghostMode
        if hasShadow != wantShadow { hasShadow = wantShadow }

        let target: NSRect
        if ghostMode {
            // Inline ghost text: left edge at the caret, right edge hard-stopped
            // at the field (see inlineLimitX) so it never leaves the input, and
            // the text ellipsizes rather than being sliced.
            let size = ghost.measuredSize
            let limit = inlineLimitX(at: caretRect) ?? visible.maxX - 2
            let x = min(max(visible.minX, caretRect.maxX), limit)
            let lift = Self.ghostLift(caretHeight: caretRect.height, lineHeight: size.height)
            var origin = CGPoint(x: x, y: caretRect.minY + lift)
            origin.y = min(max(visible.minY, origin.y), visible.maxY - size.height)
            target = NSRect(x: origin.x, y: origin.y,
                            width: max(1, min(size.width, limit - x)), height: size.height)
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
            let textTop = caretRect.minY + lineFont
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
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.09
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = 1
            }
        } else if alphaValue < 1 {
            // Caught mid-fade-out: retarget the alpha animation back to opaque.
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

    private func layoutSubviews(ghost ghostMode: Bool) {
        let bounds = container.bounds
        if ghostMode {
            ghost.frame = bounds
        } else {
            // Pill modes and the over-word correction share the panel layout.
            panelBackdrop.frame = bounds
            pillHost.frame = bounds
            pillLabel.frame = pillHost.bounds.insetBy(dx: pillPadH, dy: pillPadV)
            // Capsule the glass to the pill height — the signature Liquid Glass shape.
            if #available(macOS 26.0, *), let glass = glassBackdrop as? NSGlassEffectView {
                glass.cornerRadius = min(16, bounds.height / 2)
            }
        }
        
        if let highlightLayer {
            CATransaction.begin()
            CATransaction.setValue(kCFBooleanTrue, forKey: kCATransactionDisableActions)
            highlightLayer.frame = bounds
            if ghostMode {
                highlightLayer.cornerRadius = 4
            } else {
                if #available(macOS 26.0, *) {
                    highlightLayer.cornerRadius = min(16, bounds.height / 2)
                } else {
                    highlightLayer.cornerRadius = 6
                }
            }
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
        let textSize = pillLabel.attributedStringValue.size()
        // Generous horizontal slack: the glass capsule insets its content a few
        // points, which was clipping the last glyph ("receiv…" for "receive").
        return NSSize(
            width: min(ceil(textSize.width) + 8, 460) + pillPadH * 2,
            height: ceil(textSize.height) + pillPadV * 2
        )
    }

    private func screenContaining(_ point: CGPoint) -> NSScreen? {
        // Slight inset tolerance: a caret at the very screen edge still counts.
        NSScreen.screens.first { $0.frame.insetBy(dx: -10, dy: -10).contains(point) }
    }
}
