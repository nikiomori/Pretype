import XCTest
@testable import Pretype

final class PrivacyAndReplyTests: XCTestCase {
    // docs/privacy.md promises the exportable debug log never carries OCR'd
    // screen text or the clipboard — other people's words.
    func testLoggedPromptRedactsScreenAndClipboard() {
        var request = CompletionRequest(textBeforeCaret: "Thanks, see you at")
        request.screenSummary = "Alice: the launch code is 4417"
        request.clipboardContext = "my secret clipboard line"
        let logged = SuggestionController.loggablePrompt(request)
        XCTAssertTrue(logged.contains("see you at"))
        XCTAssertFalse(logged.contains("4417"))
        XCTAssertFalse(logged.contains("secret clipboard"))
        XCTAssertTrue(logged.contains("redacted from log"))
    }

    // The clipboard reaches the prompt as at most 600 characters, edges
    // trimmed — and an all-blank copy as nothing.
    func testClipboardSnippetIsCappedAndTrimmed() {
        let long = "\n  " + String(repeating: "a", count: 5000)
        XCTAssertEqual(SuggestionController.clipboardSnippet(long), String(repeating: "a", count: 600))
        XCTAssertEqual(SuggestionController.clipboardSnippet("  hi there \n"), "hi there")
        XCTAssertNil(SuggestionController.clipboardSnippet(" \n\t "))
    }

    // A reply that restates the screen is dropped — on word boundaries only,
    // and never for sharing a one-word label with it.
    func testReplyEchoMatchesWholeWords() {
        let conversation = "Bob: are you coming to the review tonight?\nDelivered\nmeasure twice"
        XCTAssertTrue(CompletionRequest.isEcho("Are you coming to the review tonight?", of: conversation))
        XCTAssertTrue(CompletionRequest.isEcho("ok — bob: are you coming to the review tonight? yes", of: conversation))
        XCTAssertTrue(CompletionRequest.isEcho("Are you coming to the review tonight", of: conversation), "dropped ?")
        XCTAssertFalse(CompletionRequest.isEcho("Sure", of: conversation), "\"sure\" sits inside \"measure\"")
        XCTAssertFalse(CompletionRequest.isEcho("Has it been delivered yet", of: conversation), "one-word label")
        XCTAssertFalse(CompletionRequest.isEcho("Yes, I'll be there at eight", of: conversation))
        // No spaces to find word boundaries by: a restated line still counts.
        let chat = "小王：你明天下午来开会吗？\n已读"
        XCTAssertTrue(CompletionRequest.isEcho("好的小王你明天下午来开会吗我会去", of: chat))
        XCTAssertFalse(CompletionRequest.isEcho("好的，我明天下午一定到", of: chat))
    }

    // The reply chord must never be mistaken for the fix chord (which would
    // rewrite the user's word instead of composing a message), and a reply that
    // parrots the draft back must not double it in the field.
    func testReplyChordAndDraftEcho() {
        for style in HotkeyStyle.allCases {
            let key = style.keyCode
            let fix: CGEventFlags = {
                switch style {
                case .tab: return [.maskAlternate]
                case .cmdSpace, .optSpace: return [.maskCommand, .maskAlternate]
                case .ctrlSpace: return [.maskControl, .maskAlternate]
                }
            }()
            XCTAssertTrue(style.matchesReply(keyCode: key, flags: fix.union(.maskShift)))
            XCTAssertFalse(style.matchesReply(keyCode: key, flags: fix))
            XCTAssertFalse(style.matchesCorrection(keyCode: key, flags: fix.union(.maskShift)))
            XCTAssertFalse(style.matchesAcceptAll(keyCode: key, flags: fix.union(.maskShift)))
        }

        // Draft echoed back: only the continuation is offered, re-joined with a
        // space (apply() drops it when the draft already ends in one).
        let drafted = CompletionRequest(textBeforeCaret: "Привет, ")
        XCTAssertEqual(drafted.cleanReply("Привет, как дела?"), " как дела?")
        // No draft, quoted answer: unwrapped, first line only.
        let empty = CompletionRequest(textBeforeCaret: "")
        XCTAssertEqual(empty.cleanReply("\"Sure, tomorrow works.\"\nExplanation: …"),
                       "Sure, tomorrow works.")
        // An answer that IS just the draft leaves nothing to show.
        XCTAssertNil(drafted.cleanReply("привет,"))
    }
}
