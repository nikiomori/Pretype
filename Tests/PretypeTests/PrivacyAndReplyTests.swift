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
}
