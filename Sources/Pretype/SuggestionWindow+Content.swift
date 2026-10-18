import AppKit
import QuartzCore

extension SuggestionWindow {
    static let pillFont = NSFont.systemFont(ofSize: 13)

    func applyContent(_ mode: SuggestionDisplayMode, ghost ghostMode: Bool) {
        switch mode {
        case .suggestion(let s):
            if ghostMode {
                ghost.attributed = suggestionGhost(s)
            } else {
                // Wraps: ⇧⇥ accepts all of it, so all of it must be on screen —
                // an ellipsized pill offered a tail nobody saw. Ten lines at
                // 460 pt hold more than the longest reply (400 chars).
                setPill(panelSuggestion(s), wraps: true)
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
        result.append(Self.plain(text.isEmpty ? String(localized: "Listening…") : text,
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
        return attachment(image, y: ((font.capHeight - cap.height) / 2).rounded())
    }

    /// `image` inline, its bottom `y` off the baseline. Drawn at draw time
    /// (`cacheMode = .never`), so its colours follow the window's appearance.
    private static func attachment(_ image: NSImage, y: CGFloat) -> NSAttributedString {
        image.cacheMode = .never
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(origin: NSPoint(x: 0, y: y), size: image.size)
        return NSAttributedString(attachment: attachment)
    }

    /// The Pretype mark in `color`, leading an engine notice.
    private static func mark(_ state: BrandMark.State, _ color: NSColor) -> NSAttributedString {
        let template = BrandMark.statusItemImage(state, phase: 2)
        let image = NSImage(size: template.size, flipped: false) { rect in
            template.draw(in: rect)
            // sourceIn, not sourceAtop: the colour REPLACES the black template
            // (its own alpha kept), where atop blended a translucent grey over
            // black and drew the mark near-black on a light pill.
            color.set()
            rect.fill(using: .sourceIn)
            return true
        }
        let out = NSMutableAttributedString(
            attributedString: attachment(image, y: ((pillFont.capHeight - template.size.height) / 2).rounded()))
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
        result.append(Self.plain(" " + String(localized: "apply") + "   ", .secondaryLabelColor, .systemFont(ofSize: 11)))
        result.append(Self.keycap("esc"))
        result.append(Self.plain(" " + String(localized: "cancel"), .secondaryLabelColor, .systemFont(ofSize: 11)))
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
        guard Stats.tutorsAccept else { return result }
        let style = Settings.hotkeyStyle
        let hint = NSFont.systemFont(ofSize: 11)
        result.append(Self.plain("   "))
        result.append(Self.keycap(style.label))
        result.append(Self.plain(" " + String(localized: "word") + "   ", .secondaryLabelColor, hint))
        result.append(Self.keycap(style.shiftLabel))
        result.append(Self.plain(" " + String(localized: "all"), .secondaryLabelColor, hint))
        return result
    }

    /// The accept keycap that trails a new user's inline ghost: a small key
    /// dimmed to the ghost's own strength, so it reads as part of the offer
    /// rather than as UI stuck onto the user's text.
    func ghostKeycap() -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: ghostString("  ", dim: 1))
        out.append(Self.keycap(Settings.hotkeyStyle.label, size: max(8, (ghostFont.pointSize * 0.7).rounded()),
                               beside: ghostFont, strength: min(1, ghostStrength(1) / 0.7)))
        return out
    }

    /// Ghost text with the ⇥-acceptable chunk (same split the controller uses)
    /// a step brighter than the tail, so what one Tab takes is visible at a glance.
    func suggestionGhost(_ s: String) -> NSAttributedString {
        let head = SuggestionController.firstWordChunk(of: s)
        let result = NSMutableAttributedString(attributedString: ghostString(head, dim: 1))
        ghostHeadWidth = ceil(result.size().width)
        let tail = String(s.dropFirst(head.count))
        if !tail.isEmpty { result.append(ghostString(tail, dim: 0.72)) }
        if ghostShowsKeycap { result.append(ghostKeycap()) }
        return result
    }
}
