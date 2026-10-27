import AppKit

/// The input box of an AI agent's terminal UI — the one place in a terminal
/// where ghost text helps: the user is writing prose to a model there, not a
/// shell command. Recognized from the terminal's own text (Terminal.app and
/// iTerm2 expose the screen through AX with the cursor as the caret): a
/// prompt-glyph line between two horizontal rules — Claude Code's `────` /
/// `❯ text` / `────` — with nothing typed after the caret. A shell prompt
/// (even starship's `❯`) has no rule under it, which is what keeps
/// completions out of commands. Claude Code's `!` bash mode has no marker
/// here, so it stays out too.
enum AgentPrompt {
    /// Prompt glyphs; Claude Code follows its `❯` with a no-break space.
    static let markers: Set<Character> = ["❯", ">", "›"]
    /// Longest prompt followed back up the screen, in wrapped lines.
    static let maxLines = 16

    /// What's typed in the box, soft wraps rejoined — nil unless the caret
    /// sits at the end of an agent's input box.
    static func input(before: String, after: String) -> String? {
        guard let (lines, start, width) = box(before: before, after: after) else { return nil }
        var text = String(lines[start].dropFirst(2))
        for i in start + 1 ..< lines.count {
            // A soft wrap keeps the space it broke at, or ran the line
            // to the edge (a word longer than the line); anything else
            // was a newline the user typed.
            let wrapped = text.hasSuffix(" ") || lines[i - 1].count >= width - 2
            text += (wrapped ? "" : "\n") + lines[i].dropFirst(2)
        }
        // In VS Code, Claude Code shows the editor's selection as a
        // chip at the head of the box; it isn't part of the prompt.
        if text.hasPrefix("[⧉"), let end = text.range(of: "] ") { text.removeSubrange(..<end.upperBound) }
        return text
    }

    /// The session above the box — the agent's last turn, at the bottom —
    /// rules dropped, trailing padding trimmed, blank runs cut to one, capped
    /// from the top to `maxChars` at a line start. What a reply answers
    /// (`ReplyComposer`). nil outside an agent box, or with nothing above it.
    static func transcript(before: String, after: String, maxChars: Int = 1500) -> String? {
        guard let (lines, start, _) = box(before: before, after: after) else { return nil }
        var kept: [String] = []
        for raw in lines[..<(start - 1)] {
            let line = String(raw.reversed().drop(while: \.isWhitespace).reversed())
            if ruleWidth(Substring(line)) != nil { continue }
            if line.isEmpty, kept.last?.isEmpty != false { continue }
            kept.append(line)
        }
        while kept.last?.isEmpty == true { kept.removeLast() }
        var text = kept.joined(separator: "\n")
        if text.count > maxChars {
            let tail = text.suffix(maxChars)
            text = String(tail.firstIndex(of: "\n").map { tail[tail.index(after: $0)...] } ?? tail)
        }
        return text.isEmpty ? nil : text
    }

    /// The box around the caret: the lines up to it, the prompt-glyph line's
    /// index in them and the box's width — nil unless the caret sits at the
    /// end of an agent's input box.
    private static func box(before: String, after: String) -> (lines: [String], prompt: Int, width: Int)? {
        let tail = after.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        // Only padding may follow the caret, then the closing rule.
        guard tail.count > 1, tail[0].allSatisfy({ $0 == " " }), let width = ruleWidth(tail[1]) else { return nil }
        let lines = before.components(separatedBy: "\n")
        for start in stride(from: lines.count - 1, through: max(1, lines.count - maxLines), by: -1) {
            let line = lines[start]
            if let first = line.first, markers.contains(first),
               let gap = line.dropFirst().first, gap == " " || gap == "\u{a0}" {
                return ruleWidth(Substring(lines[start - 1])) != nil ? (lines, start, width) : nil
            }
            // Above the caret line, only the box's indented continuation lines.
            guard line.hasPrefix("  ") else { return nil }
        }
        return nil
    }

    /// The agent-prompt view of a terminal's AX context: the typed input as
    /// the text before the caret, nothing after it, and a monospaced host
    /// font (Terminal publishes no attributed text). nil outside an agent box.
    static func context(_ ctx: TextContext) -> TextContext? {
        guard let typed = input(before: ctx.textBeforeCaret, after: ctx.textAfterCaret) else { return nil }
        // The cell height is the measure; no terminal reports its font.
        let size = ctx.caretRect.map { max(9, $0.height / 1.2) } ?? 12
        var host = ctx.host
        host.font = .monospacedSystemFont(ofSize: size, weight: .regular)
        host.textFollowsCaret = false
        return TextContext(textBeforeCaret: typed, textAfterCaret: "", caretRect: ctx.caretRect, host: host)
    }

    /// A horizontal rule's width in columns — nil for any other line.
    static func ruleWidth(_ line: Substring) -> Int? {
        let body = line.trimmingCharacters(in: .whitespaces)
        guard body.count >= 10, body.allSatisfy({ $0 == "─" }) else { return nil }
        return line.count
    }
}
