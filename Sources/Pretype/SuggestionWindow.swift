import AppKit
import QuartzCore

/// What the caret-side panel is currently communicating.
enum SuggestionDisplayMode: Equatable {
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
final class GhostTextView: NSView {
    var attributed = NSAttributedString() {
        didSet { needsDisplay = true }
    }

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
final class PillTextView: NSView {
    var attributed = NSAttributedString() {
        didSet { needsDisplay = true }
    }

    static let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading,
                                                   .truncatesLastVisibleLine]

    override var isFlipped: Bool { true }

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
    let container = NSView()
    let pillText = PillTextView()
    let ghost = GhostTextView()
    var highlightLayer: CALayer?

    /// Panel background: Liquid Glass. The label (`pillText`) is a SIBLING
    /// stacked above the backdrop — not inside it.
    /// NOTE: never dim the backdrop via alphaValue — glass/blur materials lose
    /// their blending when translucent, and the text behind bleeds through sharp
    /// (tried; unreadable). The pill must stay opaque to do its job.
    let backdrop = NSGlassEffectView()

    let pillPadH: CGFloat = 9

    /// Inline ghost text vs a floating panel beside the caret. Set by the
    /// controller from `Settings.suggestionPresentation`.
    var presentation: SuggestionPresentation = .panel { didSet { lastShow = nil } }

    /// Flips the window's appearance to match the host app's background under
    /// the caret (dark editor ↔ light page), so every semantic color in the
    /// pill resolves against what it's actually drawn over. Only a *fallback*
    /// for the ghost: it needs Screen Recording, and where that isn't granted
    /// the ghost took the system theme — white-on-white in a light app under a
    /// dark system. `host.color` answers the same question for free.
    let backgroundProbe = BackgroundProbe()

    /// Font the ghost draws in — the host's own when AX exposed it.
    var ghostFont: NSFont = .systemFont(ofSize: 13)
    /// Width of the ⇥-acceptable chunk of the current ghost: the part that must
    /// fit inline for inline to be worth doing at all.
    var ghostHeadWidth: CGFloat = 0
    /// Resolved host-font size for the current caret — drives both the ghost size
    /// and the vertical anchoring of every mode, so placement stays consistent
    /// across apps regardless of the caret box height they report.
    var lineFont: CGFloat = 13
    /// The caret of the current suggestion, so a panel can re-place on accept.
    private var lastCaret = CGRect.zero
    /// The last `show`'s inputs and what it rendered. The same call again — an
    /// AX event that moved nothing (a selection notification, a terminal
    /// redrawing around the agent box), a status pill re-shown per tick —
    /// returns that instead of a full layout, redraw and alpha animation.
    private var lastShow: (mode: SuggestionDisplayMode, caret: CGRect, host: HostTextStyle,
                           trimToLine: Bool, shown: String?)?
    /// A `hide()` fade is running; `place` must pull it back to opaque.
    var fadingOut = false
    /// The window just came on screen, or just left it.
    var onVisibilityChange: (() -> Void)?
    /// Font/color/box of the field under that caret.
    var lastHost = HostTextStyle()
    /// Writing direction of the ghost currently drawn: an Arabic or Hebrew
    /// completion grows LEFT from the caret, not right.
    var ghostRTL = false
    /// The caret edge the ghost hangs off (its right edge in LTR, left in RTL),
    /// advanced in place by `advance` so a word-by-word accept doesn't wait for
    /// the next AX read to know where the caret got to.
    var ghostAnchorX: CGFloat = 0

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

        // Liquid Glass refracts whatever is behind the caret. Corner is set
        // per-layout to capsule the pill.
        backdrop.style = .regular
        backdrop.cornerRadius = 11
        container.addSubview(backdrop)
        container.addSubview(pillText)
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
    /// one floats free of the field and wraps to show the suggestion whole.
    /// `trimToLine: false` never trims: a suggestion that doesn't fit the line
    /// whole goes to the pill instead (a composed reply — its point is the
    /// sentences after the first line).
    @discardableResult
    func show(mode: SuggestionDisplayMode, at caretRect: CGRect, host: HostTextStyle = HostTextStyle(),
              trimToLine: Bool = true) -> String? {
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
        if let last = lastShow, isVisible, !fadingOut, last.mode == mode, last.caret == caretRect,
           last.host == host, last.trimToLine == trimToLine {
            hideGeneration += 1   // as `place` would: a show cancels a pending timed hide
            return last.shown
        }
        currentMode = mode
        lastCaret = caretRect
        self.trimToLine = trimToLine
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
        backgroundProbe.refresh(near: caretRect) { [weak self] in self?.resolveAppearance() }
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
                let keycapWidth = Stats.tutorsAccept ? ceil(ghostKeycap().size().width) : 0
                var fitted = keycapWidth > 0
                    ? Self.fittingPrefix(of: s, font: ghostFont, width: room - keycapWidth) : ""
                ghostShowsKeycap = !fitted.isEmpty
                if fitted.isEmpty { fitted = Self.fittingPrefix(of: s, font: ghostFont, width: room) }
                if fitted.isEmpty || (!trimToLine && fitted != s) {
                    ghostMode = false   // not even one word (or not all of it) — the pill says it in full
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

        setHighlight(Self.offersSuggestion(mode) && !Settings.onboardingCompleted)
        lastShow = isVisible && !fadingOut ? (mode, caretRect, host, trimToLine, shown) : nil
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
        lastShow = nil
        // The thinking dots inherit the direction of the last suggestion (they
        // have no letters of their own); across a field change that is the wrong
        // field's direction, and they'd open on the wrong side of the caret.
        ghostRTL = false
        backgroundProbe.invalidate()
    }

    /// The last `show`'s trim rule, so the pill re-render in `advance` keeps it.
    private var trimToLine = true

    /// Monotonic token: a `show` between fade-out start and completion cancels
    /// the pending `orderOut`, so a new suggestion never gets yanked away.
    var hideGeneration = 0

    /// What the window is currently offering, or nil when it offers nothing.
    ///
    /// The keyboard gates used to ask `isVisible`, which answers a different
    /// question: an overlay of ANY kind — a dictation notice, an engine status,
    /// a spell pill — made a completion ghost or a fix preview look live to ⇥
    /// and ⏎ even though what was on screen belonged to someone else, and the
    /// key then applied text nobody could see. Each owner asks about its own
    /// mode instead.
    private(set) var currentMode: SuggestionDisplayMode?

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
        lastShow = nil
        guard isVisible else { setHighlight(false); return }
        hideGeneration += 1
        let gen = hideGeneration
        fadingOut = true
        // Symmetric to the 0.09 s fade-in: dismissal melts instead of popping.
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.hideGeneration == gen else { return }
            self.fadingOut = false
            // Drop the accent glow WITH the fade, not a frame before it — any
            // show() landing mid-fade fails the generation check and sets its
            // own highlight, so this can't clear a live one.
            self.setHighlight(false)
            self.orderOut(nil)
            self.alphaValue = 1
            self.onVisibilityChange?()
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
        // Gone in under two seconds and never focused: VoiceOver reads a
        // notice ("dictation copied, ⌘V to paste") only when told to.
        if case .hint(let text) = mode { Self.announce(text) }
        if case .error(let text) = mode { Self.announce(text) }
        let gen = hideGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + hideAfter) { [weak self] in
            guard let self, self.hideGeneration == gen else { return }
            // Force: this hide IS the notice's own expiry. Anything that
            // replaced it in the meantime bumped `hideGeneration` and never
            // reaches here.
            self.hide(force: true)
        }
    }

    private static func announce(_ text: String) {
        guard let app = NSApp else { return }
        NSAccessibility.post(element: app, notification: .announcementRequested, userInfo: [
            .announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
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
            return show(mode: .suggestion(remaining), at: lastCaret, host: lastHost, trimToLine: trimToLine)
        }
        // The caret moved by the accepted word's width — forward in the ghost's
        // own writing direction, which is leftward for Arabic or Hebrew.
        lastShow = nil
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
    func anchorsOnSelection(_ mode: SuggestionDisplayMode?) -> Bool {
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

    /// Whether the current pill may wrap (a fix preview, a notice) — it then
    /// gets a height cap instead of one line.
    var pillWraps = false
    /// Set by `pillSize`: a pill that actually wrapped gets a little more
    /// vertical padding than a one-line capsule.
    var pillPadV: CGFloat = 4

    /// Whether the ghost currently on screen carries the accept keycap — kept
    /// for `advance`, which re-renders the remainder in place.
    var ghostShowsKeycap = false

    /// See `logTone`.
    var lastToneLog = ""
}
