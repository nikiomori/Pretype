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
    /// Neutral one-line notice ("✓ looks fine", "dictation cancelled").
    case hint(String)
    /// A key and what it does, drawn as a keycap — the ⌥⇥ fix-selection
    /// affordance.
    case shortcut(key: String, action: String)
    /// A proposed fix for the selection (or the last word), awaiting the
    /// user's accept/cancel. Drawn as a word diff against `original`, wrapped
    /// so a long fix can be read in full before ⏎ applies it.
    case fixPreview(original: String, fix: String)
    /// A spell-fix shown in a pill ABOVE the mistyped word (Cotypist-style):
    /// the original struck through, an arrow, then the proposed fix. Tab to apply.
    case correction(original: String, fix: String)
    /// Dictation is capturing the microphone; the payload is the transcript so
    /// far (empty right after the key goes down).
    case listening(String)
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

/// The pill's text. Drawn rather than an NSTextField so the size it asks for
/// is exactly the size it draws in — the field cell's private insets clipped
/// the last glyph ("receiv…") — and so a fix preview can wrap. A truncating
/// paragraph style keeps every other mode on one ellipsized line.
private final class PillTextView: NSView {
    var attributed = NSAttributedString() {
        didSet { needsDisplay = true }
    }

    static let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading,
                                                   .truncatesLastVisibleLine]

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    /// The text's laid-out size within `maxWidth`, at most `maxHeight` tall.
    func fittingSize(maxWidth: CGFloat, maxHeight: CGFloat) -> NSSize {
        let r = attributed.boundingRect(with: NSSize(width: maxWidth, height: maxHeight), options: Self.options)
        return NSSize(width: min(maxWidth, ceil(r.width)), height: min(maxHeight, ceil(r.height)))
    }

    override func draw(_ dirtyRect: NSRect) {
        attributed.draw(with: bounds, options: Self.options)
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
    private let pillText = PillTextView()
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
    /// Writing direction of the ghost currently drawn: an Arabic or Hebrew
    /// completion grows LEFT from the caret, not right.
    private var ghostRTL = false
    /// The caret edge the ghost hangs off (its right edge in LTR, left in RTL),
    /// advanced in place by `advance` so a word-by-word accept doesn't wait for
    /// the next AX read to know where the caret got to.
    private var ghostAnchorX: CGFloat = 0

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

        pillHost.addSubview(pillText)

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
    /// Returns the suggestion text actually rendered — an inline ghost trims it
    /// to what fits on the line (see `fittingPrefix`), and the caller must trim
    /// what ⇧⇥ accepts to match. nil for every other mode, and for a pill: that
    /// one floats free of the field and shows the suggestion whole.
    @discardableResult
    func show(mode: SuggestionDisplayMode, at caretRect: CGRect, host: HostTextStyle = HostTextStyle()) -> String? {
        // A protected notice outranks the pipeline's own chatter. The keystroke
        // that discards a dictation ALSO restarts completion, which blanks or
        // repaints this window within ~60 ms — so the one line explaining where
        // the sentence went used to flash and vanish. Only the non-committal
        // modes are held off: a real suggestion still takes the window, because
        // an invisible ghost that ⇥ would accept is a worse failure than a
        // shortened notice.
        if noticeIsProtected {
            switch mode {
            case .thinking, .status: return nil
            default: noticeProtectedUntil = .distantPast
            }
        }
        currentMode = mode
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
        // needs room beside the caret INSIDE the field, and that room has to be
        // empty — mid-line it would be painted over the user's own words, and at
        // the end of a full input there is none at all.
        var ghostMode = presentation == .inline && isGhostable(mode) && !lastHost.textFollowsCaret
        var rendered = mode
        var shown: String?
        if case .suggestion(let s) = mode {
            ghostRTL = Self.isRightToLeft(s)
            if ghostMode {
                // Show only what fits, and tell the caller — offering more than
                // the line can draw is how ⇧⇥ ends up inserting text unseen.
                // Two points short of the real room: the window is sized from
                // `measuredSize`, which rounds the text width up and adds a
                // pixel of slack, so text that "fits" to the point would come
                // back a pixel too wide for its own window and be ellipsized —
                // which is the exact thing this trim exists to prevent.
                let room = max(0, (inlineRoom(at: caretRect, rtl: ghostRTL) ?? 0) - 2)
                // A new user's ghost carries the accept keycap when the line
                // has room for it and at least a word; otherwise the words win.
                let keycapWidth = Self.tutorsAccept ? ceil(ghostKeycap().size().width) : 0
                var fitted = keycapWidth > 0
                    ? Self.fittingPrefix(of: s, font: ghostFont, width: room - keycapWidth) : ""
                ghostShowsKeycap = !fitted.isEmpty
                if fitted.isEmpty { fitted = Self.fittingPrefix(of: s, font: ghostFont, width: room) }
                if fitted.isEmpty {
                    ghostMode = false   // not even one word — the pill says it in full
                } else {
                    rendered = .suggestion(fitted)
                    shown = fitted
                }
            }
        }
        applyContent(rendered, ghost: ghostMode)
        if ghostMode, !inlineHasRoom(at: caretRect) {
            ghostMode = false
            shown = nil
            applyContent(mode, ghost: false)
        }
        place(ghost: ghostMode, at: caretRect)

        if case .suggestion = mode, !Settings.onboardingCompleted {
            setHighlight(true)
        } else {
            setHighlight(false)
        }
        return shown
    }

    /// The focus moved to a different field: everything remembered about the
    /// old one — its style and box, and the probe's pixel verdict — is evidence
    /// about the wrong place, and each would outrank what the new field reports
    /// (the probe by rank, the box via the same-field retention in `show`).
    /// Called on focus changes, not from `hide()`: dismissals within one field
    /// must keep their measured style.
    func fieldChanged() {
        // Notice protection survives on purpose: an app switch raises "dictation
        // stopped — the focus moved" on resign, a hop before this runs, and it
        // holds off only thinking/status for ≤1.2 s — a real overlay still wins.
        lastHost = HostTextStyle()
        // The thinking dots inherit the direction of the last suggestion (they
        // have no letters of their own); across a field change that is the wrong
        // field's direction, and they'd open on the wrong side of the caret.
        ghostRTL = false
        backgroundProbe.invalidate()
    }

    /// Monotonic token: a `show` between fade-out start and completion cancels
    /// the pending `orderOut`, so a new suggestion never gets yanked away.
    private var hideGeneration = 0

    /// What the window is currently offering, or nil when it offers nothing.
    ///
    /// The keyboard gates used to ask `isVisible`, which answers a different
    /// question: an overlay of ANY kind — a dictation notice, an engine status,
    /// a spell pill — made a completion ghost or a fix preview look live to ⇥
    /// and ⏎ even though what was on screen belonged to someone else, and the
    /// key then applied text nobody could see. Each owner asks about its own
    /// mode instead.
    private(set) var currentMode: SuggestionDisplayMode?

    /// A completion ghost (or panel) is the thing on screen right now.
    var showsSuggestion: Bool { Self.offersSuggestion(currentMode) }

    /// A correction is on screen: the ⌥⇥ preview awaiting accept, or the inline
    /// spell pill over the word at the caret.
    var showsCorrection: Bool { Self.offersCorrection(currentMode) }

    /// Which owner a displayed mode belongs to. Static and mode-only so the
    /// keyboard gates can be pinned by a test without a window server: what
    /// they decide is whether ⇥ inserts text, which is the one thing in this
    /// app that must never fire over something the user cannot see.
    nonisolated static func offersSuggestion(_ mode: SuggestionDisplayMode?) -> Bool {
        if case .suggestion = mode { return true }
        return false
    }

    nonisolated static func offersCorrection(_ mode: SuggestionDisplayMode?) -> Bool {
        switch mode {
        case .fixPreview, .correction: return true
        default: return false
        }
    }

    /// While this is in the future, a notice on screen is being given time to
    /// be read — see `show` and `showTransient(protectFor:)`.
    private var noticeProtectedUntil = Date.distantPast
    private var noticeIsProtected: Bool { Date() < noticeProtectedUntil }

    /// Give up the protection early: the caret this notice belongs to has moved
    /// or gone (scroll, window move, app switch), so holding the window for
    /// it would only strand a pill over unrelated text.
    func clearNoticeProtection() { noticeProtectedUntil = .distantPast }

    /// `force` overrides an active notice protection. Everything that means
    /// "this overlay is now in the wrong place" passes it; the ordinary
    /// pipeline dismissals do not.
    func hide(force: Bool = false) {
        if force { clearNoticeProtection() } else if noticeIsProtected { return }
        // Before the visibility guard: "nothing is being offered" has to become
        // true the moment the dismissal is accepted, not when the fade lands.
        currentMode = nil
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
    /// `protectFor` seconds of immunity from the completion pipeline's own
    /// repaints — for notices raised by the same keystroke that restarts it.
    func showTransient(_ mode: SuggestionDisplayMode, at caretRect: CGRect,
                       host: HostTextStyle = HostTextStyle(), hideAfter: TimeInterval = 1.8,
                       protectFor: TimeInterval = 0) {
        show(mode: mode, at: caretRect, host: host)   // bumps hideGeneration via place()
        if protectFor > 0 { noticeProtectedUntil = Date().addingTimeInterval(protectFor) }
        let gen = hideGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + hideAfter) { [weak self] in
            guard let self, self.hideGeneration == gen else { return }
            // Force: this hide IS the notice's own expiry. Anything that
            // replaced it in the meantime bumped `hideGeneration` and never
            // reaches here.
            self.hide(force: true)
        }
    }

    /// After the user accepts `accepted`, slide the ghost forward by that word's
    /// rendered width and show `remaining` in place — no hide, no re-fade. The
    /// next AX refresh corrects any sub-pixel drift, so word-by-word Tab stays
    /// smooth instead of blinking.
    /// Returns what was rendered when the pill re-render flips back into a
    /// ghost — accepting the first word can free exactly the room its remainder
    /// needs, and that flip trims like any `show` — so the caller must narrow
    /// what ⇧⇥ accepts to match. nil from the slide path: it draws `remaining`
    /// whole in the room the accepted word vacated.
    func advance(past accepted: String, remaining: String) -> String? {
        guard isVisible, !remaining.isEmpty else { return nil }
        // `!ghost.isHidden`, not the setting: inline that fell back to the pill
        // for lack of room must re-render as a pill, not slide a hidden ghost.
        guard !ghost.isHidden else {
            // Panel: re-render the box with the remaining text where it sits —
            // and forward the verdict: this is the one path where a pill can
            // become a (trimmed) ghost without the controller calling show.
            return show(mode: .suggestion(remaining), at: lastCaret, host: lastHost)
        }
        // The caret moved by the accepted word's width — forward in the ghost's
        // own writing direction, which is leftward for Arabic or Hebrew.
        let dx = ceil((accepted as NSString).size(withAttributes: [.font: ghostFont]).width)
        ghostAnchorX += ghostRTL ? -dx : dx
        ghost.attributed = suggestionGhost(remaining)
        // Cap to the field (then the screen) so the remainder doesn't overhang for
        // a frame before the next AX refresh re-places it.
        let size = ghost.measuredSize
        let bound = inlineBound(at: lastCaret, rtl: ghostRTL)
            ?? (ghostRTL ? ghostAnchorX - size.width : ghostAnchorX + size.width)
        let span = Self.ghostSpan(anchorX: ghostAnchorX, textWidth: size.width,
                                  bound: bound, rtl: ghostRTL)
        var f = frame
        f.origin.x = span.x
        f.size.width = max(1, span.width)
        setFrame(f, display: false)
        layoutSubviews(ghost: true)
        displayIfNeeded()
        return nil
    }

    /// Modes that *can* draw as chromeless inline ghost text; engine notices and
    /// fixes are always pills. Whether one actually does also depends on there
    /// being room at the caret — see `inlineHasRoom`.
    /// The ⌥⇥ affordance and preview: anchored on a selection box (or the
    /// caret, for a last-word fix) rather than on a caret line.
    private func anchorsOnSelection(_ mode: SuggestionDisplayMode?) -> Bool {
        switch mode {
        case .shortcut, .fixPreview: return true
        default: return false
        }
    }

    private func isGhostable(_ mode: SuggestionDisplayMode) -> Bool {
        switch mode {
        case .suggestion, .thinking: return true
        case .status, .error, .hint, .shortcut, .fixPreview, .correction, .listening: return false
        }
    }

    private static let pillFont = NSFont.systemFont(ofSize: 13)

    private func applyContent(_ mode: SuggestionDisplayMode, ghost ghostMode: Bool) {
        switch mode {
        case .suggestion(let s):
            if ghostMode {
                ghost.attributed = suggestionGhost(s)
            } else {
                setPill(panelSuggestion(s))
            }
        case .thinking(let phase):
            if ghostMode {
                ghost.attributed = thinkingGhost(phase)
                ghostHeadWidth = 0
            } else {
                setPill(Self.dots(phase, beside: Self.pillFont) { Self.dynamicAlpha(.labelColor, 0.7 * $0) })
            }
        case .status(let s):
            // The mark says whose "loading…" this is — at the caret, a bare
            // engine notice reads as the host app's own.
            let text = NSMutableAttributedString(attributedString: Self.mark(.ready, .secondaryLabelColor))
            text.append(Self.plain(s, .secondaryLabelColor))
            setPill(text)
        case .error(let s):
            // Orange marks the severity; the words stay full-strength ink —
            // orange text on a light pill was the hardest line here to read.
            let text = NSMutableAttributedString(attributedString: Self.mark(.failed, .systemOrange))
            text.append(Self.plain(s, .labelColor))
            setPill(text)
        case .hint(let s):
            // Wraps: the actionable notices ("allow Pretype in System
            // Settings, then relaunch") run past one line, and the clipped
            // tail was the instruction itself.
            setPill(Self.plain(s, .secondaryLabelColor), wraps: true)
        case .shortcut(let key, let action):
            let text = NSMutableAttributedString(attributedString: Self.keycap(key))
            text.append(Self.plain(" " + action, .secondaryLabelColor))
            setPill(text)
        case .fixPreview(let original, let fix):
            setPill(fixPreview(original: original, fix: fix), wraps: true)
        case .correction(let original, let fix):
            let text = NSMutableAttributedString(attributedString: Self.replacement(original, fix))
            text.append(Self.plain("   "))
            text.append(Self.keycap(Settings.hotkeyStyle.label))
            setPill(text)
        case .listening(let s):
            setPill(listening(s))
        }
    }

    /// Whether the current pill may wrap (a fix preview, a notice) — it then
    /// gets a height cap instead of one line.
    private var pillWraps = false
    /// Set by `pillSize`: a pill that actually wrapped gets a little more
    /// vertical padding than a one-line capsule.
    private var pillPadV: CGFloat = 4

    /// One ellipsized line unless `wraps`; any paragraph settings the content
    /// already carries (an RTL base direction) are kept.
    private func setPill(_ text: NSAttributedString, wraps: Bool = false) {
        let out = NSMutableAttributedString(attributedString: text)
        let existing = out.length > 0
            ? out.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle : nil
        let paragraph = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        paragraph.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        out.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: out.length))
        pillWraps = wraps
        pillText.attributed = out
    }

    private static func plain(_ s: String, _ color: NSColor = .labelColor,
                              _ font: NSFont = pillFont) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
    }

    /// The dictation pill: a red dot — the universal "live" — then the words as
    /// they are recognized. The point of showing them is that you can tell
    /// you're being heard *before* you finish the sentence, so the caller feeds
    /// the tail of the transcript rather than its start.
    private func listening(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "●  ", attributes: [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.systemRed,
        ])
        result.append(Self.plain(text.isEmpty ? "Listening…" : text,
                                 text.isEmpty ? .secondaryLabelColor : .labelColor))
        // The leading dot forces the line's base direction LTR, which renders
        // an Arabic or Hebrew transcript backwards: words in RTL order but the
        // line laid out from the left, ellipsis on the wrong side. Basing the
        // paragraph on the transcript mirrors the whole pill — dot on the
        // right, tail growing leftwards — which is what an RTL reader expects.
        if Self.isRightToLeft(text) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.baseWritingDirection = .rightToLeft
            result.addAttribute(.paragraphStyle, value: paragraph,
                                range: NSRange(location: 0, length: result.length))
        }
        return result
    }

    /// A key drawn as a key: a rounded, hairline-edged cap with the label
    /// centred on it, the cap centred on `font`'s cap height so it sits level
    /// with the words around it. The old flat background-colour run hugged the
    /// glyphs in a hard box. Rendered at draw time (`cacheMode = .never`), so
    /// its colours resolve against the window's appearance like every other
    /// colour here, async tone flips included. `strength` dims the whole cap
    /// to sit inside a ghost.
    static func keycap(_ key: String, size: CGFloat = 10, beside font: NSFont = pillFont,
                       strength: CGFloat = 1) -> NSAttributedString {
        let labelFont = NSFont.systemFont(ofSize: size, weight: .semibold)
        let label = NSAttributedString(string: key, attributes: [
            .font: labelFont,
            .foregroundColor: dynamicAlpha(.labelColor, 0.62 * strength),
        ])
        let textWidth = ceil(label.size().width)
        let cap = NSSize(width: textWidth + 2 * ceil(size * 0.45), height: ceil(size * 1.5))
        let image = NSImage(size: cap, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                    xRadius: min(4, rect.height / 3), yRadius: min(4, rect.height / 3))
            dynamicAlpha(.labelColor, 0.07 * strength).setFill()
            path.fill()
            dynamicAlpha(.labelColor, 0.2 * strength).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            // Optical centre: the cap-height midline, not the line box's.
            label.draw(at: NSPoint(x: (rect.width - textWidth) / 2,
                                   y: rect.height / 2 + labelFont.descender - labelFont.capHeight / 2
                                      - (labelFont.ascender + labelFont.descender - labelFont.capHeight) / 2))
            return true
        }
        image.cacheMode = .never
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: ((font.capHeight - cap.height) / 2).rounded(),
                                   width: cap.width, height: cap.height)
        return NSAttributedString(attachment: attachment)
    }

    /// The Pretype mark in `color`, leading an engine notice.
    private static func mark(_ state: BrandMark.State, _ color: NSColor) -> NSAttributedString {
        let template = BrandMark.statusItemImage(state, phase: 2, height: 10)
        let image = NSImage(size: template.size, flipped: false) { rect in
            template.draw(in: rect)
            // sourceIn, not sourceAtop: the colour REPLACES the black template
            // (its own alpha kept), where atop blended a translucent grey over
            // black and drew the mark near-black on a light pill.
            color.set()
            rect.fill(using: .sourceIn)
            return true
        }
        image.cacheMode = .never
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: ((pillFont.capHeight - template.size.height) / 2).rounded(),
                                   width: template.size.width, height: template.size.height)
        let out = NSMutableAttributedString(attachment: attachment)
        out.append(plain("  "))
        return out
    }

    /// Three dots, one lit, the light walking left to right. Constant width,
    /// so it pulses in place instead of growing and shrinking at the caret the
    /// way the old 1-2-3 ellipsis did. The dots sit on `font`'s x-height
    /// midline; a zero-width space in `font` keeps the line box the host's, so
    /// the inline ghost places them on the line like any other ghost text.
    private static func dots(_ phase: Int, beside font: NSFont,
                             extra: [NSAttributedString.Key: Any] = [:],
                             ink: (CGFloat) -> NSColor) -> NSAttributedString {
        let dotFont = NSFont.systemFont(ofSize: max(8, (font.pointSize * 0.7).rounded()))
        let lift = (font.xHeight - dotFont.xHeight) / 2
        let out = NSMutableAttributedString(string: "\u{200B}", attributes: extra.merging([.font: font]) { $1 })
        for i in 0..<3 {
            out.append(NSAttributedString(string: i == 0 ? "•" : "\u{2009}•", attributes: extra.merging([
                .font: dotFont,
                .baselineOffset: lift,
                .foregroundColor: ink(i == phase % 3 ? 1 : 0.3),
            ]) { $1 }))
        }
        return out
    }

    private func thinkingGhost(_ phase: Int) -> NSAttributedString {
        let strength = ghostStrength(1)
        return Self.dots(phase, beside: ghostFont, extra: ghostAttributes(dim: 1)) {
            Self.dynamicAlpha(.labelColor, strength * $0)
        }
    }

    /// "original → fix": the original muted under a quiet red-tinted
    /// strikethrough (a hint of "wrong", not a shout), a muted arrow, then the
    /// fix in full-strength semibold ink. Not the accent colour: with the
    /// Graphite accent that drew the fix in the same grey as the word it
    /// replaces, and the one word that matters came out the faintest.
    private static func replacement(_ original: String, _ fix: String) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: removedRun(original))
        result.append(plain("  →  ", .tertiaryLabelColor, .systemFont(ofSize: 11)))
        result.append(insertedRun(fix, highlighted: false))
        return result
    }

    private static func removedRun(_ s: String) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: pillFont,
            .foregroundColor: NSColor.secondaryLabelColor,
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .strikethroughColor: dynamicAlpha(.systemRed, 0.6),
        ])
    }

    private static func insertedRun(_ s: String, highlighted: Bool) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        if highlighted { attributes[.backgroundColor] = dynamicAlpha(.systemGreen, 0.18) }
        return NSAttributedString(string: s, attributes: attributes)
    }

    /// A proposed fix, as what it CHANGES: a sentence re-typed in full left the
    /// user proofreading it against their own to find the two words that
    /// moved, and a long one was cut to a single ellipsized line — ⏎ applied
    /// text nobody could read. Now the edits are marked in place and the pill
    /// wraps, so everything ⏎ will type is on screen. A single word reads as
    /// the same "old → new" the spell pill uses. Then the two keys, with verbs.
    private func fixPreview(original: String, fix: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let trimmed = original.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace), !fix.contains(where: \.isWhitespace) {
            result.append(Self.replacement(original, fix))
        } else if let runs = Self.wordDiff(from: original, to: fix) {
            var previous: DiffRun?
            for run in runs {
                switch run {
                case .same(let s): result.append(Self.plain(s))
                case .removed(let s): result.append(Self.removedRun(s))
                case .inserted(let s):
                    // "their" struck, then "they're": keep them two words.
                    if case .removed(let r)? = previous, r.last?.isWhitespace == false,
                       s.first?.isWhitespace == false {
                        result.append(Self.plain(" "))
                    }
                    result.append(Self.insertedRun(s, highlighted: true))
                }
                previous = run
            }
        } else {
            result.append(Self.plain(fix))
        }
        result.append(Self.plain("   "))
        result.append(Self.keycap("⏎"))
        result.append(Self.plain(" apply   ", .secondaryLabelColor, .systemFont(ofSize: 11)))
        result.append(Self.keycap("esc"))
        result.append(Self.plain(" cancel", .secondaryLabelColor, .systemFont(ofSize: 11)))
        return result
    }

    enum DiffRun: Equatable {
        case same(String), removed(String), inserted(String)
    }

    /// Word-level diff of a fix against the text it replaces. Tokens are runs
    /// of letters/digits, single punctuation marks, and whitespace runs, so
    /// "their" → "they're" is one replaced word, not a smear of characters.
    /// nil when the fix rewrote most of a longer text: a paragraph of
    /// strikethrough reads worse than the fix itself. Pinned by a test.
    nonisolated static func wordDiff(from old: String, to new: String) -> [DiffRun]? {
        func tokens(_ s: String) -> [String] {
            var out: [String] = []
            var current = ""
            var kind = 0
            for ch in s {
                let k = ch.isLetter || ch.isNumber ? 1 : ch.isWhitespace ? 2 : 3
                if k != kind || k == 3, !current.isEmpty { out.append(current); current = "" }
                current.append(ch)
                kind = k
            }
            if !current.isEmpty { out.append(current) }
            return out
        }
        let a = tokens(old), b = tokens(new)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in b.difference(from: a) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        // "Most of it" by characters, not tokens: "they're" is three tokens
        // and one word, and counting tokens tipped a two-word fix into "a
        // rewrite" and dropped its diff.
        let isWord = { (t: String) in t.contains { $0.isLetter || $0.isNumber } }
        let words = b.filter(isWord).count
        let total = b.filter(isWord).reduce(0) { $0 + $1.count }
        let changed = inserted.filter { isWord(b[$0]) }.reduce(0) { $0 + b[$1].count }
        guard words > 0, words < 4 || changed * 2 <= total else { return nil }

        var runs: [DiffRun] = []
        func push(_ run: DiffRun) {
            switch (runs.last, run) {
            case (.same(let x)?, .same(let y)): runs[runs.count - 1] = .same(x + y)
            case (.removed(let x)?, .removed(let y)): runs[runs.count - 1] = .removed(x + y)
            case (.inserted(let x)?, .inserted(let y)): runs[runs.count - 1] = .inserted(x + y)
            default: runs.append(run)
            }
        }
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) {
                push(.removed(a[i])); i += 1
            } else if j < b.count, inserted.contains(j) {
                push(.inserted(b[j])); j += 1
            } else {
                if j < b.count { push(.same(b[j])) }
                i += 1; j += 1
            }
        }
        return runs
    }

    /// The classic panel content: the suggestion text (⇥-acceptable chunk a step
    /// brighter) plus a faint accept hint. The keycap tutoring disappears once
    /// accepting is muscle memory, so the pill stays compact for regulars.
    private func panelSuggestion(_ s: String) -> NSAttributedString {
        let head = SuggestionController.firstWordChunk(of: s)
        let result = NSMutableAttributedString(attributedString: Self.plain(head))
        let tail = String(s.dropFirst(head.count))
        if !tail.isEmpty { result.append(Self.plain(tail, .secondaryLabelColor)) }
        guard Self.tutorsAccept else { return result }
        let style = Settings.hotkeyStyle
        let hint = NSFont.systemFont(ofSize: 11)
        result.append(Self.plain("   "))
        result.append(Self.keycap(style.label))
        result.append(Self.plain(" word   ", .secondaryLabelColor, hint))
        result.append(Self.keycap(style.shiftLabel))
        result.append(Self.plain(" all", .secondaryLabelColor, hint))
        return result
    }

    /// New users get the accept key spelled out next to the suggestion — in
    /// the panel AND inline, where a bare grey continuation gave no clue that
    /// a key takes it — until accepting is muscle memory.
    private static var tutorsAccept: Bool { Stats.lifetimeAccepted < 20 }

    /// Whether the ghost currently on screen carries the accept keycap — kept
    /// for `advance`, which re-renders the remainder in place.
    private var ghostShowsKeycap = false

    /// The accept keycap that trails a new user's inline ghost: a small key
    /// dimmed to the ghost's own strength, so it reads as part of the offer
    /// rather than as UI stuck onto the user's text.
    private func ghostKeycap() -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: ghostString("  ", dim: 1))
        out.append(Self.keycap(Settings.hotkeyStyle.label, size: max(8, (ghostFont.pointSize * 0.7).rounded()),
                               beside: ghostFont, strength: min(1, ghostStrength(1) / 0.7)))
        return out
    }

    /// Ghost text with the ⇥-acceptable chunk (same split the controller uses)
    /// a step brighter than the tail, so what one Tab takes is visible at a glance.
    private func suggestionGhost(_ s: String) -> NSAttributedString {
        let head = SuggestionController.firstWordChunk(of: s)
        let result = NSMutableAttributedString(attributedString: ghostString(head, dim: 1))
        ghostHeadWidth = ceil(result.size().width)
        let tail = String(s.dropFirst(head.count))
        if !tail.isEmpty { result.append(ghostString(tail, dim: 0.72)) }
        if ghostShowsKeycap { result.append(ghostKeycap()) }
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
        NSAttributedString(string: string, attributes: ghostAttributes(dim: dim))
    }

    /// The ghost's ink strength for `dim`: the opacity setting scaled by it.
    private func ghostStrength(_ dim: CGFloat) -> CGFloat {
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

    private func ghostAttributes(dim: CGFloat) -> [NSAttributedString.Key: Any] {
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

    /// How far the inline ghost may draw *in its writing direction*: the far
    /// edge of the field it belongs to, else the screen's. Without the field
    /// bound the ghost ran past the input over the send button beside it — and
    /// with a caret near the screen edge the old `max(40, …)` floor pushed a
    /// sliver of window clean off the display.
    private func inlineBound(at caretRect: CGRect, rtl: Bool) -> CGFloat? {
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
    private func inlineRoom(at caretRect: CGRect, rtl: Bool) -> CGFloat? {
        guard let bound = inlineBound(at: caretRect, rtl: rtl) else { return nil }
        return max(0, rtl ? caretRect.minX - bound : bound - caretRect.maxX)
    }

    /// Inline needs room for at least the chunk one ⇥ takes. Less than that and
    /// the ghost is a sliver hanging off the end of the input, so the pill above
    /// the line takes over — it says the same thing, in full, and is clamped
    /// on-screen. (A suggestion is trimmed to the room in `show`, so this only
    /// still decides for the thinking dots and as a backstop.)
    private func inlineHasRoom(at caretRect: CGRect) -> Bool {
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
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.09
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = 1
            }
        } else {
            // Caught mid-fade-out: retarget the alpha animation back to opaque.
            // Unconditional: a hide() earlier in this same pass still reads 1.0
            // here (AppKit steps alpha on later frames), and its completion is
            // already cancelled — skipping this left the window ordered in at 0.
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
            pillText.frame = pillHost.bounds.insetBy(dx: pillPadH, dy: pillPadV)
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
        // Measured with the same options it draws with, so the box fits the
        // text exactly. A wrapping fix preview is capped at ten lines — past
        // that the last visible line ellipsizes rather than the pill growing
        // over half the screen. A point of slack absorbs rounding.
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
