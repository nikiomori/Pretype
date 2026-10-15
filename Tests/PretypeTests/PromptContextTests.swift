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
