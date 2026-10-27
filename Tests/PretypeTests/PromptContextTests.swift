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
    /// input fills the gap. Cases from a live trace (2026-10-20).
    func testCaretLineFromATrailingRow() {
        let row = "❯ ну давай еще раз протестируем как раб"   // 39 cells
        // In step: the row as is.
        XCTAssertEqual(AXText.caretLine(row: row, column: 39, recent: "тируем как раб"), row)
        XCTAssertEqual(AXText.caretLine(row: row, column: 39, recent: ""), row)
        // Two letters typed, the row hasn't caught up: they come from the textarea.
        XCTAssertEqual(AXText.caretLine(row: row, column: 41, recent: "тируем как работ"), row + "от")
        // A typed space the right-trimmed row drops.
        XCTAssertEqual(AXText.caretLine(row: row, column: 40, recent: "тируем как раб "), row + " ")
        // Backspace after "работ": the row still shows the deleted "т".
        XCTAssertEqual(AXText.caretLine(row: row + "от", column: 40, recent: "тируем как рабо"), row + "о")
        // Backspace and a new letter: same length, other text.
        XCTAssertEqual(AXText.caretLine(row: row + "от", column: 41, recent: "тируем как рабоа"), row + "оа")
        // A cleared prompt the textarea still remembers: the row when it fits the cursor…
        XCTAssertEqual(AXText.caretLine(row: "❯ ", column: 2, recent: "как рабоает,"), "❯ ")
        // …nothing when it doesn't (the row is behind and the textarea is no help).
        XCTAssertNil(AXText.caretLine(row: "❯ ", column: 3, recent: "как рабоает,к"))
        XCTAssertNil(AXText.caretLine(row: row, column: 43, recent: ""))
        // The cursor not moved yet for a letter the textarea already has.
        XCTAssertEqual(AXText.caretLine(row: row, column: 39, recent: "тируем как рабо"), row)
    }

    // Terminal.app's AX text around the caret, as read from a live Claude
    // Code session (v2.1): the input box is the only place a terminal gets
    // completions, and its soft wraps must rejoin into the typed prompt.
    func testAgentPromptInTerminal() {
        let rule = String(repeating: "─", count: 80)
        let screen = "nikimori@mac ~ % claude\n▗ ▗   ▖ ▖  Claude Code v2.1.296\n\(rule)\n"
        let below = "\n\(rule)\n  ⏵⏵ auto mode on"
        let wrapped = screen + "❯\u{a0}please check why the build fails on CI and fix the flaky test in the \n"
            + "  dictation controller so it stops timing out when the machine is"
        XCTAssertEqual(AgentPrompt.input(before: wrapped, after: below),
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
        XCTAssertEqual(CompletionRequest.userMessages(in: "> rename the flag\n⏺ Done\n❯ now the tests"),
                       "rename the flag\nnow the tests")
        XCTAssertNil(CompletionRequest.userMessages(in: "⏺ Done"))
    }

    // The names worth completing are identifiers and paths, newest first;
    // a name grows as far as every match agrees, by 2+ characters.
    func testSessionNames() {
        let names = AgentPrompt.names(in: "⏺ Fixed `AgentPrompt.input` in Sources/Pretype/AgentPrompt.swift, e.g. the Settings.\n  ⎿  SuggestionController: 2 tests (v2.1)")
        XCTAssertEqual(names, ["v2.1", "SuggestionController", "Sources/Pretype/AgentPrompt.swift", "AgentPrompt.input"])
        XCTAssertEqual(AgentPrompt.completion(of: "see Sugg", names: names), "estionController")
        XCTAssertEqual(AgentPrompt.completion(of: "see Agent", names: names), "Prompt.input")
        XCTAssertEqual(AgentPrompt.completion(of: "see Agent", names: names + ["AgentPrompt.swift"]), "Prompt.",
                       "as far as the matches agree")
        XCTAssertNil(AgentPrompt.completion(of: "see sugg", names: names), "case-sensitive")
        XCTAssertNil(AgentPrompt.completion(of: "see Su", names: names), "3+ characters typed")
        XCTAssertNil(AgentPrompt.completion(of: "see SuggestionControlle", names: names), "one character is no ghost")
        XCTAssertNil(AgentPrompt.completion(of: "see SuggestionController", names: names))
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
