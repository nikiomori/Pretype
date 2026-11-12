import XCTest
@testable import Pretype

final class PromptContextTests: XCTestCase {
    // Once a document outgrows the context window, typing must not slide the
    // prompt's START (that re-tokenizes everything and voids the KV cache):
    // the cut sits on a sentence boundary and holds while the user types.
    func testStableTailHoldsItsStart() {
        let doc = (0 ..< 40).map { "Sentence number \($0) is here." }.joined(separator: " ")
        let a = CompletionRequest.stableTail(doc, maxChars: 1000)
        XCTAssertTrue(a.hasPrefix("Sentence number"), a.prefix(30).description)
        XCTAssertLessThanOrEqual(a.count, 1000)
        var typed = doc
        for ch in " And more" {
            typed.append(ch)
            XCTAssertEqual(CompletionRequest.stableTail(typed, maxChars: 1000), a + typed.dropFirst(doc.count))
        }
        XCTAssertEqual(CompletionRequest.stableTail("short text", maxChars: 1000), "short text")
        // No boundary at all → plain suffix.
        let unspaced = String(repeating: "字", count: 1200)
        XCTAssertEqual(CompletionRequest.stableTail(unspaced, maxChars: 1000).count, 1000)
    }

    /// OCR reads the keyboard's languages only where one recognizer covers
    /// them all; any other script keeps Vision's auto-detection.
    func testOCRLanguagesFollowTheKeyboard() {
        XCTAssertEqual(ScreenContext.recognitionLanguages(keyboard: ["en", "ru"]), ["en-US", "ru-RU"])
        XCTAssertEqual(ScreenContext.recognitionLanguages(keyboard: ["ru"]), ["ru-RU", "en-US"])
        XCTAssertNil(ScreenContext.recognitionLanguages(keyboard: ["ja", "ru"]), "Japanese first garbles Cyrillic")
        XCTAssertNil(ScreenContext.recognitionLanguages(keyboard: ["en", "xx"]), "unknown to Vision")
    }

    /// A chat line passes in every script: words for spaced scripts, letters
    /// for Han and kana, and the ALL-CAPS rule only where letters have case.
    func testOCRKeepsProseInEveryScript() {
        for line in ["I told you to wait here", "Я же сказал тебе ждать", "我告诉过你在这里等着",
                     "ここで待っててね", "안녕하세요 저는 학생입니다", "قلت لك أن تنتظر هنا", "אמרתי לך לחכות כאן"] {
            XCTAssertTrue(ScreenContext.looksLikeProse(line), line)
        }
        for line in ["Look.", "SEND MESSAGE NOW", "等着", "see ~/notes for it", "12:41 · 3 new"] {
            XCTAssertFalse(ScreenContext.looksLikeProse(line), line)
        }
    }

    /// The report names what kept each line out, and the block is the kept
    /// lines that fit, the bottom of the window first.
    func testTheCaptureSaysWhatBecameOfEachLine() {
        let raw: [(String, Float)] = [
            ("Chats", 0.9), ("12", 0.9), ("see you at seven tonight", 0.2), ("what I am typing", 0.9),
            ("the first message here", 0.9), ("the second message here", 0.9),
        ]
        let read = raw.map { ScreenContext.Reading(text: $0.0, confidence: $0.1, box: .zero) }
        let sifted = ScreenContext.sift(read, excluding: "what I am typing", maxChars: 30)
        XCTAssertEqual(sifted.summary, "the second message here")
        XCTAssertEqual(sifted.lines.map(\.fate), [.notProse, .tooShort, .lowConfidence, .typed, .overLimit, .kept])
        XCTAssertNil(ScreenContext.sift(Array(read.prefix(1)), excluding: "", maxChars: 30).summary)
    }

    /// A chat keeps the bubbles over its box, even one that starts a little
    /// past the edge, and drops the chat list, the side panel and the box.
    func testAChatKeepsOnlyTheColumnAboveItsBox() {
        func line(_ text: String, x: CGFloat, width: CGFloat, y: CGFloat) -> ScreenContext.Reading {
            ScreenContext.Reading(text: text, confidence: 0.9, box: CGRect(x: x, y: y, width: width, height: 16))
        }
        let read = [
            line("a chat in the list on the left", x: 20, width: 260, y: 100),
            line("the message on the left side", x: 330, width: 60, y: 200),
            line("the message on the right side", x: 1300, width: 250, y: 300),
            line("the side panel on the right", x: 1500, width: 200, y: 300),
            line("the draft inside the box", x: 420, width: 200, y: 905),
        ]
        let field = CGRect(x: 400, y: 900, width: 1000, height: 40)
        let sifted = ScreenContext.sift(read, excluding: "", field: field, maxChars: 600)
        XCTAssertEqual(sifted.summary, "the message on the left side\nthe message on the right side")
        XCTAssertEqual(sifted.lines.map(\.fate), [.offColumn, .kept, .kept, .offColumn, .typed])
    }

    /// In a chat a line loses its time, however OCR spelled it, and a short
    /// reply counts. Outside a chat both stay as they were.
    func testAChatLineLosesItsTimeAndMayBeShort() {
        let raw = ["да нет ПОТОМ 7:48 PM", "ну хорошо 7:49 PM //", "уже иду 7:49 Рм", "Как скажешь 6:25 м", "ну 7:49 PM v/",
                   ") 7:48 PM V/", "7:47 PM //", "SEND", "see ~/notes 14:05"]
        let read = raw.map { ScreenContext.Reading(text: $0, confidence: 0.9, box: CGRect(x: 100, y: 100, width: 100, height: 16)) }
        let sifted = ScreenContext.sift(read, excluding: "", field: CGRect(x: 0, y: 900, width: 1000, height: 40), maxChars: 600)
        XCTAssertEqual(sifted.summary, "да нет ПОТОМ\nну хорошо\nуже иду\nКак скажешь\nну")
        XCTAssertEqual(sifted.lines.map(\.fate), [.kept, .kept, .kept, .kept, .kept, .tooShort, .tooShort, .notProse, .notProse])
        XCTAssertEqual(sifted.lines[6].text, "7:47 PM //", "the list shows a line that had only the time")

        let plain = ScreenContext.Reading(text: "see you there 7:49 PM", confidence: 0.9, box: .zero)
        XCTAssertEqual(ScreenContext.sift([plain], excluding: "", maxChars: 600).summary, "see you there 7:49 PM")
    }

    /// Only as far as needed: a shell line reads no row above it; a box
    /// reads up to its prompt line and the line over it, no further.
    func testAgentBoxRowsReadOnlyWhatTheyNeed() {
        var asked: [Int] = []
        let screen = ["  indented output", "  more", "❯ first line that", "  wraps here"]
        XCTAssertEqual(AXText.agentBoxRows(above: 4, typed: "$ git sta") { asked.append($0); return screen[$0] }, [])
        XCTAssertEqual(asked, [])
        let rows = AXText.agentBoxRows(above: 4, typed: "  and on") { asked.append($0); return screen[$0] }
        XCTAssertEqual(rows, ["  more", "❯ first line that", "  wraps here"])
        XCTAssertEqual(asked, [3, 2, 1])
    }

    /// The xterm reader fetches only the rows over the caret `AgentPrompt`
    /// reads: the verdict must match the whole 20-row window it used to read.
    func testAgentBoxRowsMatchTheFullWindow() {
        let rule = String(repeating: "─", count: 40)
        let screens: [[String]] = [
            ["$ make", "ok", rule, "❯ fix the", rule],
            ["⏺ Done.", rule, "❯ first line that", "  wraps here", rule],
            ["~ % ls", "README.md", "❯ git sta", rule],
            [rule, "❯\u{a0}[⧉ In README.md] explain", rule],
            ["output"] + Array(repeating: "  more", count: 18) + ["  tail", rule],
            [rule, "❯ a"] + Array(repeating: "  b", count: 16) + ["  c", rule],
        ]
        for screen in screens {
            let cursorRow = screen.count - 2
            let typed = screen[cursorRow]
            let full = screen[max(0, cursorRow - 20)..<cursorRow] + [typed]
            let lazy = AXText.agentBoxRows(above: cursorRow, typed: typed) { screen[$0] } + [typed]
            XCTAssertEqual(AgentPrompt.input(before: lazy.joined(separator: "\n"), after: "\n" + rule),
                           AgentPrompt.input(before: full.joined(separator: "\n"), after: "\n" + rule), "\(screen)")
        }
    }

    /// VS Code's xterm rows trail the cursor; the helper textarea's recent
    /// input fills the gap.
    func testCaretLineFromATrailingRow() {
        let row = "❯ сосед снова чинит часы понять как раб"   // 39 cells
        // In step: the row as is.
        XCTAssertEqual(AXText.caretLine(row: row, column: 39, recent: "понять как раб"), row)
        XCTAssertEqual(AXText.caretLine(row: row, column: 39, recent: ""), row)
        // Two letters typed, the row hasn't caught up: they come from the textarea.
        XCTAssertEqual(AXText.caretLine(row: row, column: 41, recent: "понять как работ"), row + "от")
        // A typed space the right-trimmed row drops.
        XCTAssertEqual(AXText.caretLine(row: row, column: 40, recent: "понять как раб "), row + " ")
        // Backspace after "работ": the row still shows the deleted "т".
        XCTAssertEqual(AXText.caretLine(row: row + "от", column: 40, recent: "понять как рабо"), row + "о")
        // Backspace and a new letter: same length, other text.
        XCTAssertEqual(AXText.caretLine(row: row + "от", column: 41, recent: "понять как рабоа"), row + "оа")
        // A cleared prompt the textarea still remembers: the row when it fits the cursor…
        XCTAssertEqual(AXText.caretLine(row: "❯ ", column: 2, recent: "как рабоает,"), "❯ ")
        // …nothing when it doesn't (the row is behind and the textarea is no help).
        XCTAssertNil(AXText.caretLine(row: "❯ ", column: 3, recent: "как рабоает,к"))
        XCTAssertNil(AXText.caretLine(row: row, column: 43, recent: ""))
        // The cursor not moved yet for a letter the textarea already has.
        XCTAssertEqual(AXText.caretLine(row: row, column: 39, recent: "понять как рабо"), row)
    }

    // Terminal.app's AX text around the caret, as read from a live Claude
    // Code session (v2.1): the input box is the only place a terminal gets
    // completions, and its soft wraps must rejoin into the typed prompt.
    func testAgentPromptInTerminal() {
        let rule = String(repeating: "─", count: 80)
        let screen = "user@mac ~ % claude\n▗ ▗   ▖ ▖  Claude Code v2.1.296\n\(rule)\n"
        let below = "\n\(rule)\n  ⏵⏵ auto mode on"
        let wrapped = screen + "❯\u{a0}please check why the build fails on CI and fix the flaky test in the \n"
            + "  dictation controller so it stops timing out when the machine is"
        XCTAssertEqual(AgentPrompt.input(before: wrapped, after: below),
                       "please check why the build fails on CI and fix the flaky test in the "
                       + "dictation controller so it stops timing out when the machine is")
        // Kelp trims the row: no wrap space, but "dictation" had no room left.
        XCTAssertEqual(AgentPrompt.input(before: wrapped.replacingOccurrences(of: "the \n", with: "the\n"), after: below),
                       "please check why the build fails on CI and fix the flaky test in the "
                       + "dictation controller so it stops timing out when the machine is")
        XCTAssertEqual(AgentPrompt.input(before: screen + "❯ ", after: below), "")
        // VS Code: the editor-selection chip is not part of the prompt.
        XCTAssertEqual(AgentPrompt.input(before: screen + "❯\u{a0}[⧉ In README.md] explain", after: below), "explain")
        // A newline the user typed: the line ended short, without a wrap space.
        XCTAssertEqual(AgentPrompt.input(before: screen + "❯ first line\n  second", after: below),
                       "first line\nsecond")
        // Caret mid-input, or the placeholder Claude Code draws in an empty box.
        XCTAssertNil(AgentPrompt.input(before: screen + "❯ fix the", after: " test" + below))
        // A shell prompt — starship's ❯ included — has no rule under it.
        XCTAssertNil(AgentPrompt.input(before: screen + "❯ git sta", after: "\n\n"))
        XCTAssertNil(AgentPrompt.input(before: "~ % ls\nREADME.md\n❯ git sta", after: below))
        // Agent output above the box is not the box.
        XCTAssertNil(AgentPrompt.input(before: screen + "⏺ Done. The build passes", after: below))
        // Claude Code's `!` bash mode stays a shell.
        XCTAssertNil(AgentPrompt.input(before: screen + "! git push", after: below))
    }

    // The session above an agent's box is what a reply answers: rules and
    // padding go, blank runs shrink to one line, and a long session keeps
    // its newest lines, from a line start.
    func testAgentSessionAboveTheBox() {
        let rule = String(repeating: "─", count: 40)
        let below = "\n\(rule)\n  ⏵⏵ auto mode on"
        let screen = ["", "> rename the flag", "", "", "⏺ Renamed it in Settings.swift.   ", "  ⎿  2 files changed", rule]
        XCTAssertEqual(AgentPrompt.transcript(before: (screen + ["❯ "]).joined(separator: "\n"), after: below),
                       "> rename the flag\n\n⏺ Renamed it in Settings.swift.\n  ⎿  2 files changed")
        XCTAssertEqual(AgentPrompt.transcript(before: (screen + ["❯ and the", "  tests"]).joined(separator: "\n"), after: below),
                       "> rename the flag\n\n⏺ Renamed it in Settings.swift.\n  ⎿  2 files changed", "a wrapped draft")
        XCTAssertEqual(AgentPrompt.transcript(before: (screen + ["❯ "]).joined(separator: "\n"), after: below, maxChars: 40),
                       "⏺ Renamed it in Settings.swift.\n  ⎿  2 files changed".split(separator: "\n").last.map(String.init),
                       "cut at a line start")
        XCTAssertNil(AgentPrompt.transcript(before: [rule, "❯ "].joined(separator: "\n"), after: below), "nothing above")
        XCTAssertNil(AgentPrompt.transcript(before: "~ % ls\n❯ git sta", after: below), "a shell")
        XCTAssertEqual(AgentPrompt.tail(of: "first line\nsecond line", maxChars: 15), "second line")
        XCTAssertEqual(AgentPrompt.tail(of: "short", maxChars: 15), "short")
        XCTAssertEqual(CompletionRequest.userMessages(in: "> rename the flag\n⏺ Done\n❯ now the tests"),
                       "rename the flag\nnow the tests")
        XCTAssertNil(CompletionRequest.userMessages(in: "⏺ Done"))
    }

    // The names worth completing are identifiers and paths, newest first;
    // a name grows as far as every match agrees, by 2+ characters.
    func testSessionNames() {
        let names = AgentPrompt.names(in: "⏺ Fixed `AgentPrompt.input` in Sources/Pretype/AgentPrompt.swift, e.g. the Settings.\n  ⎿  SuggestionController: 2 tests (v2.1)")
        XCTAssertEqual(names, ["v2.1", "SuggestionController", "Sources/Pretype/AgentPrompt.swift", "AgentPrompt.input"])
        XCTAssertEqual(AgentPrompt.completion(of: "see Sugg", names: names)?.rest, "estionController")
        XCTAssertEqual(AgentPrompt.completion(of: "see Sugg", names: names)?.whole, true)
        XCTAssertEqual(AgentPrompt.completion(of: "see Agent", names: names)?.rest, "Prompt.input")
        let both = names + ["AgentPrompt.swift"]
        XCTAssertEqual(AgentPrompt.completion(of: "see Agent", names: both)?.rest, "Prompt.", "as far as the matches agree")
        XCTAssertEqual(AgentPrompt.completion(of: "see Agent", names: both)?.whole, false)
        XCTAssertEqual(AgentPrompt.completion(of: "see Agen", names: ["Agents", "Agents.md"])?.whole, true,
                       "where they part is itself a name")
        XCTAssertNil(AgentPrompt.completion(of: "see sugg", names: names), "case-sensitive")
        XCTAssertNil(AgentPrompt.completion(of: "see Su", names: names), "3+ characters typed")
        XCTAssertNil(AgentPrompt.completion(of: "see SuggestionControlle", names: names), "one character is no ghost")
        XCTAssertNil(AgentPrompt.completion(of: "see SuggestionController", names: names))
    }

    // The window read is the focused one, never the largest, and never a
    // guess: AX's by frame, by title too on a shared frame, else the one
    // holding the caret.
    func testTheFocusedWindowIsRead() {
        typealias Window = ScreenContext.Window
        let large = Window(frame: CGRect(x: 0, y: 25, width: 1600, height: 1000), title: "Inbox")
        let small = Window(frame: CGRect(x: 200, y: 100, width: 800, height: 600), title: "Docs")
        func pick(_ windows: [Window], _ focused: Window?, caret: CGRect? = nil) -> Int? {
            ScreenContext.focusedWindow(among: windows, focused: focused, caret: caret)
        }
        XCTAssertEqual(pick([large, small], small), 1, "not the largest")
        XCTAssertEqual(pick([large, small], Window(frame: small.frame.offsetBy(dx: 1, dy: -1), title: nil)), 1, "rounding")
        XCTAssertNil(pick([large], small), "the focused window is on another Space: nothing else stands in")
        XCTAssertNil(pick([], small))
        XCTAssertNil(pick([large, small], Window(frame: CGRect(x: 300, y: 200, width: 400, height: 300), title: nil),
                          caret: CGRect(x: 310, y: 210, width: 1, height: 16)),
                     "AX names a window not listed: the one under its caret is not it")

        let twin = Window(frame: large.frame, title: "Docs")
        XCTAssertEqual(pick([large, twin], Window(frame: large.frame, title: "Docs")), 1, "two maximized windows")
        XCTAssertNil(pick([large, twin], Window(frame: large.frame, title: "Mail")))
        XCTAssertNil(pick([large, large], large), "nothing tells them apart")
        XCTAssertEqual(pick([Window(frame: large.frame, title: nil)], large), 0, "the frame alone settles one")

        let caret = CGRect(x: 1500, y: 900, width: 1, height: 16)
        XCTAssertEqual(pick([large, small], nil, caret: caret), 0, "AX has no answer")
        XCTAssertNil(pick([large, small], nil, caret: CGRect(x: 300, y: 200, width: 1, height: 16)), "both hold it")
        XCTAssertNil(pick([small], nil, caret: caret), "the caret is in no window listed")
        XCTAssertNil(pick([large, small], nil), "nothing to go on")

        // AX's frame is off by more than rounding: the caret settles it, but
        // only on a window about that size, and only one.
        let off = Window(frame: large.frame.offsetBy(dx: 12, dy: 8), title: "Inbox")
        XCTAssertEqual(pick([large, small], off, caret: caret), 0, "a frame miss falls through to the caret")
        XCTAssertNil(pick([large, small], off), "no caret to fall through to")
        XCTAssertNil(pick([large, twin], off, caret: caret), "both hold it")
        let panel = Window(frame: CGRect(x: 1400, y: 850, width: 180, height: 120), title: "Find")
        XCTAssertNil(pick([large], panel, caret: caret), "a panel too small to list: the parent behind it is not it")
    }

    // Base-path RAG: accepted phrases form a separate label-free preamble block
    // the engine prepends to the GENERATION prompt only — completionPrompt
    // (what the context floor, the gates and the n-gram context reason about)
    // must never contain it.
    func testPersonalPreambleBlock() {
        var request = CompletionRequest(textBeforeCaret: "пишу тебе про новый релиз")
        XCTAssertNil(request.personalPreambleBlock)
        request.personalExamples = [
            .init(ctx: "мы обсуждали релиз", next: " вчера вечером"),
            .init(ctx: "созвон в", next: " четверг"),
        ]
        XCTAssertEqual(request.personalPreambleBlock,
                       "мы обсуждали релиз вчера вечером\nсозвон в четверг")
        // The floor/gate prompt stays example-free.
        request.screenSummary = "чат про релиз"
        XCTAssertEqual(request.completionPrompt(maxChars: 1000),
                       "чат про релиз\n\nпишу тебе про новый релиз")
    }

    func testClipboardContextBlock() {
        var request = CompletionRequest(textBeforeCaret: "спасибо за письмо, отвечаю")
        request.clipboardContext = "Привет! Когда ждать релиз?"
        XCTAssertEqual(request.completionPrompt(maxChars: 1000),
                       "Привет! Когда ждать релиз?\n\nспасибо за письмо, отвечаю")
        // Clipboard reads as the earlier fragment, screen stays adjacent to the text.
        request.screenSummary = "чат про релиз"
        XCTAssertEqual(request.completionPrompt(maxChars: 1000),
                       "Привет! Когда ждать релиз?\n\nчат про релиз\n\nспасибо за письмо, отвечаю")
    }

    func testPerAppInstructions() {
        let saved = Settings.perAppInstructions
        defer { Settings.perAppInstructions = saved }
        Settings.perAppInstructions = ["com.apple.mail": "Formal, no emoji.", "com.blank.app": "   "]

        var request = CompletionRequest(textBeforeCaret: "hello")
        request.appBundleID = "com.apple.MAIL"  // engines match case-insensitively
        XCTAssertEqual(request.persona(global: "I write concisely."),
                       "I write concisely.\nFormal, no emoji.")
        XCTAssertEqual(request.persona(global: " "), "Formal, no emoji.")

        request.appBundleID = "com.blank.app"  // blank text = not configured
        XCTAssertEqual(request.persona(global: "I write concisely."), "I write concisely.")
        request.appBundleID = nil
        XCTAssertEqual(request.persona(global: "I write concisely."), "I write concisely.")
    }
}

/// A screen region read for its text leaves no picture behind a crash.
final class ScreenRegionTests: XCTestCase {
    func testLaunchRemovesAPictureLeftMidRead() throws {
        let folder = ScreenContext.regionFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let left = folder.appendingPathComponent("region-left.png")
        try Data([0]).write(to: left)
        ScreenContext.removeRegionLeftovers()
        XCTAssertFalse(FileManager.default.fileExists(atPath: left.path))
    }
}
