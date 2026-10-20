import FoundationModels
import XCTest
@testable import Pretype

/// The prompt builders every engine shares (`CompletionRequest`) and the
/// protocol's defaults an engine without its own gets.
final class CompletionEngineTests: XCTestCase {
    // The base prompt: the typed tail, after the clipboard and the screen as
    // label-free blocks — and nothing at all with nothing typed.
    func testTheCompletionPrompt() {
        var request = CompletionRequest(textBeforeCaret: "See you at")
        XCTAssertEqual(request.completionPrompt(maxChars: 100), "See you at")
        request.screenSummary = "Ann: lunch?"
        request.clipboardContext = ""
        XCTAssertEqual(request.completionPrompt(maxChars: 100), "Ann: lunch?\n\nSee you at")
        request.clipboardContext = "copied"
        XCTAssertEqual(request.completionPrompt(maxChars: 100), "copied\n\nAnn: lunch?\n\nSee you at")
        request = CompletionRequest(textBeforeCaret: "", screenSummary: "Ann: lunch?")
        XCTAssertEqual(request.completionPrompt(maxChars: 100), "")
    }

    // The window's start holds still at a sentence end (or a line break) in
    // its first quarter; a window that already fits is the whole text.
    func testTheStableTailStartsAtASentenceEndInItsFirstQuarter() {
        let fits = "One. " + String(repeating: "x", count: 95)
        XCTAssertEqual(CompletionRequest.stableTail(fits, maxChars: 100), fits)
        // Ends at 21 of 100: inside the first quarter, outside a fifth.
        let tail = String(repeating: "a", count: 20) + ". " + String(repeating: "word ", count: 15) + "end"
        XCTAssertEqual(tail.count, 100)
        XCTAssertEqual(CompletionRequest.stableTail("Earlier text. " + tail, maxChars: 100),
                       String(repeating: "word ", count: 15) + "end")
        // A dot inside a number ends no sentence: the first space does.
        let number = "pi is 3.14 and " + String(repeating: "more ", count: 17)
        XCTAssertEqual(CompletionRequest.stableTail("x " + number, maxChars: number.count), "is 3.14 and " + String(repeating: "more ", count: 17))
        // A line break ends the line it closes, whatever follows.
        let lines = "first\nSecond " + String(repeating: "line ", count: 18)
        XCTAssertEqual(CompletionRequest.stableTail("x " + lines, maxChars: lines.count), "Second " + String(repeating: "line ", count: 18))
    }

    // Retrieved phrases ride the base prompt three at most, one a line.
    func testThePersonalPreamble() {
        var request = CompletionRequest(textBeforeCaret: "x")
        XCTAssertNil(request.personalPreambleBlock)
        request.personalExamples = (1 ... 4).map { .init(ctx: "see you ", next: "day \($0)") }
        XCTAssertEqual(request.personalPreambleBlock, "see you day 1\nsee you day 2\nsee you day 3")
    }

    // The reply prompt names the app, the conversation's language, the
    // persona and the draft — each only when there is one.
    func testTheReplyPrompt() {
        var request = CompletionRequest(textBeforeCaret: "")
        let plain = request.replyPrompt(conversation: "Ann: lunch at noon tomorrow?", instructions: "")
        XCTAssertTrue(plain.hasPrefix("You are writing the next message the user will send. Answer"), plain)
        XCTAssertTrue(plain.contains("in English, the conversation's language"), plain)
        XCTAssertFalse(plain.contains("About the user") || plain.contains("already started"), plain)
        request.appName = ""
        XCTAssertEqual(request.replyPrompt(conversation: "Ann: lunch at noon tomorrow?", instructions: ""), plain)
        request = CompletionRequest(textBeforeCaret: "  Sure, ", appName: "Slack")
        let full = request.replyPrompt(conversation: "Ann: lunch at noon tomorrow?", instructions: "Writes tersely.")
        XCTAssertTrue(full.hasPrefix("You are writing the next message the user will send in Slack."), full)
        XCTAssertTrue(full.contains("About the user") && full.contains("Writes tersely."), full)
        XCTAssertTrue(full.contains("The user has already started the message: \"Sure,\""), full)
    }

    // The conversation's language by name — when the recognizer is sure,
    // from the last 600 characters; short Russian it calls Ukrainian is
    // Russian when a Russian-only letter says so.
    func testTheConversationsLanguage() {
        XCTAssertEqual(CompletionRequest.languageName(of: "Hello there, how are you doing today?"), "English")
        XCTAssertEqual(CompletionRequest.languageName(of: "Bonjour, comment allez-vous aujourd'hui?"), "French")
        XCTAssertEqual(CompletionRequest.languageName(of: "Guten Tag, wie geht es Ihnen heute?"), "German")
        XCTAssertEqual(CompletionRequest.languageName(of: "Hola, ¿cómo estás hoy, amigo mío?"), "Spanish")
        XCTAssertEqual(CompletionRequest.languageName(of: "Привет, как у тебя дела сегодня вечером?"), "Russian")
        XCTAssertNil(CompletionRequest.languageName(of: "Hallo"), "not sure")
        XCTAssertNil(CompletionRequest.languageName(of: "ы" + String(repeating: " ", count: 600)), "past the window")
        XCTAssertEqual(CompletionRequest.languageName(of: "Що ты робиш зараз"), "Russian")
        XCTAssertEqual(CompletionRequest.languageName(of: "Що там у тебе"), "Ukrainian")
        XCTAssertEqual(CompletionRequest.languageName(of: "Привіт, як справи?"), "Ukrainian")
    }

    // A reply is one clean line minus the draft it restates; a reply that
    // restates the conversation is none.
    func testACleanReply() {
        let request = CompletionRequest(textBeforeCaret: "Sure, ")
        XCTAssertEqual(request.cleanReply("\"Sure, see you at noon\""), " see you at noon")
        XCTAssertNil(request.cleanReply("Sure,"))
        XCTAssertNil(request.cleanReply("Lunch at noon tomorrow", conversation: "Ann: lunch at noon tomorrow?"))
        // The space comes back only where the model had one.
        XCTAssertEqual(CompletionRequest(textBeforeCaret: "Hi").cleanReply("Hi, how are you?"), ", how are you?")
        XCTAssertEqual(CompletionRequest(textBeforeCaret: "Thank").cleanReply("Thanks for the update!"), "s for the update!")
        XCTAssertEqual(CompletionRequest(textBeforeCaret: "Hello").cleanReply("Hello there"), " there")
    }

    // Which conversation lines a reply may not carry: 8 letters and two
    // words at least (a one-word line is a label), or any unspaced line.
    func testWhichLinesARestatementCarries() {
        let conversation = "Delivered\nok then\nlunch now\nこんにちはげんき"
        XCTAssertFalse(CompletionRequest.isEcho("Delivered yesterday, thanks", of: conversation), "a one-word label")
        XCTAssertFalse(CompletionRequest.isEcho("ok then I will come", of: conversation), "6 letters")
        XCTAssertTrue(CompletionRequest.isEcho("lunch now sounds great", of: conversation), "8 letters, 2 words")
        XCTAssertTrue(CompletionRequest.isEcho("はいこんにちはげんきです", of: conversation), "kana: no spaces to split")
        XCTAssertTrue(CompletionRequest.isEcho("好的明天见", of: "小王：好的明天见吗"), "Han inside the conversation")
    }

    // A chat model's continuation turn: the directive (+ persona), the
    // screen and the app ahead of the typed text — each only when there.
    func testTheContinuationTurn() {
        var request = CompletionRequest(textBeforeCaret: "x")
        let bare = request.continuationTurn("See you", instructions: "")
        XCTAssertEqual(bare.system, CompletionRequest.continuationDirective)
        XCTAssertEqual(bare.user, "Existing text: \"See you\"\nContinuation:")
        request.screenSummary = ""
        request.appName = ""
        XCTAssertEqual(request.continuationTurn("See you", instructions: "").user, bare.user)
        request.screenSummary = "Ann: lunch?"
        request.appName = "Mail"
        let full = request.continuationTurn("See you", instructions: "Writes tersely.")
        XCTAssertEqual(full.user, "Screen context:\nAnn: lunch?\n\nThe user is typing in Mail.\n\nExisting text: \"See you\"\nContinuation:")
        XCTAssertTrue(full.system.hasPrefix(CompletionRequest.continuationDirective + "\n\nAbout the author"), full.system)
        XCTAssertTrue(full.system.hasSuffix("Writes tersely."))
    }

    func testChatApps() {
        XCTAssertFalse(CompletionRequest(textBeforeCaret: "x").isChatApp)
        XCTAssertFalse(CompletionRequest(textBeforeCaret: "x", appBundleID: "com.apple.TextEdit").isChatApp)
        XCTAssertTrue(CompletionRequest(textBeforeCaret: "x", appBundleID: "com.tinyspeck.slackmacgap").isChatApp)
    }

    // Apple Intelligence out of reach: the engine says why, offers no
    // suggestion, and an explicit request says it can't run.
    func testAnUnavailableSystemModel() async throws {
        let reasons: [(SystemLanguageModel.Availability.UnavailableReason, String)] = [
            (.deviceNotEligible, "this Mac doesn't support Apple Intelligence"),
            (.appleIntelligenceNotEnabled, "turn on Apple Intelligence in System Settings"),
            (.modelNotReady, "Apple Intelligence is still downloading — retry in a few minutes"),
        ]
        for (reason, why) in reasons {
            let engine = FoundationModelsEngine(availability: .unavailable(reason))
            XCTAssertEqual(engine.state, .failed(why))
            XCTAssertEqual(engine.statusLine, "Apple Intelligence: \(why)")
        }
        let engine = FoundationModelsEngine(availability: .unavailable(.deviceNotEligible))
        let none = try await engine.complete(CompletionRequest(textBeforeCaret: "See you at the "))
        XCTAssertNil(none)
        let explicit: [() async throws -> String?] = [
            { try await engine.correct(selection: "teh") },
            { try await engine.reply(to: "Ann: hi", request: CompletionRequest(textBeforeCaret: "")) },
            { try await engine.rewrite(selection: "hi", instruction: "formal") },
        ]
        for call in explicit {
            do {
                _ = try await call()
                XCTFail("an explicit request must say the model can't run")
            } catch {
                XCTAssertTrue(error is EngineNotReady, "\(error)")
            }
        }
    }

    // MARK: - Protocol defaults

    private final class Engine: CompletionEngine {
        let name = "test"
        var statusLine: String? { nil }
        var state: EngineState = .ready
        var loading: Bool?
        var isLoading: Bool { loading ?? { if case .preparing = state { return true }; return false }() }
        var answer: () async throws -> String? = { "next" }
        var redacted: [Bool] = []
        func complete(_ request: CompletionRequest) async throws -> String? { try await answer() }
        func correct(selection: String, redactLog: Bool) async throws -> String? { redacted.append(redactLog); return nil }
        func reply(to conversation: String, request: CompletionRequest) async throws -> String? { nil }
        func rewrite(selection: String, instruction: String) async throws -> String? { nil }
        func updateCompletion(length: CompletionLength, instructions: String) {}
    }

    /// An engine with only the protocol's own `isLoading`, `shownState` and
    /// `isCorrectionReady`.
    private final class PlainEngine: CompletionEngine {
        let name = "plain"
        var statusLine: String? { nil }
        var state: EngineState = .ready
        func complete(_ request: CompletionRequest) async throws -> String? { nil }
        func correct(selection: String, redactLog: Bool) async throws -> String? { nil }
        func reply(to conversation: String, request: CompletionRequest) async throws -> String? { nil }
        func rewrite(selection: String, instruction: String) async throws -> String? { nil }
        func updateCompletion(length: CompletionLength, instructions: String) {}
    }

    // With no idle-unload cycle, preparing IS loading; an engine resting
    // unloaded (preparing, nothing running) shows as ready.
    func testTheShownStateAndLoading() {
        let plain = PlainEngine()
        XCTAssertFalse(plain.isLoading)
        XCTAssertTrue(plain.isCorrectionReady)
        plain.state = .preparing("loading…")
        XCTAssertTrue(plain.isLoading)
        XCTAssertEqual(plain.shownState, .preparing("loading…"))
        plain.state = .failed("x")
        XCTAssertFalse(plain.isLoading)
        XCTAssertEqual(plain.shownState, .failed("x"))
        let resting = Engine()
        resting.state = .preparing("idle — model unloaded")
        resting.loading = false
        XCTAssertEqual(resting.shownState, .ready)
    }

    // ⌥⇥ on typed text logs it: the short spelling never redacts.
    func testTheTypedFixIsNotRedacted() async throws {
        let engine = Engine()
        _ = try await engine.correct(selection: "teh")
        XCTAssertEqual(engine.redacted, [false])
    }

    // An engine that can't stream yields its one answer and ends — on
    // nothing when it has none, on the error when it fails — and a consumer
    // that stops listening calls the request off.
    func testTheOneShotStream() async throws {
        let engine = Engine()
        func drain() async throws -> [String] {
            var out: [String] = []
            for try await s in engine.completions(for: CompletionRequest(textBeforeCaret: "x")) { out.append(s) }
            return out
        }
        let one = try await drain()
        XCTAssertEqual(one, ["next"])
        engine.answer = { nil }
        let none = try await drain()
        XCTAssertEqual(none, [])
        engine.answer = { throw URLError(.timedOut) }
        do {
            _ = try await drain()
            XCTFail("the error comes through")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        let calledOff = LockedValue(false)
        engine.answer = {
            do { try await Task.sleep(for: .seconds(30)) } catch { calledOff.set(true) }
            return nil
        }
        let listener = Task { try await drain() }
        try await Task.sleep(for: .milliseconds(50))
        listener.cancel()
        let deadline = Date() + 10
        while !calledOff.get(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(calledOff.get(), "the request was not called off")
    }
}
