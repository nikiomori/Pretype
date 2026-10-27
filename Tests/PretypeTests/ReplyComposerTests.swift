import ApplicationServices
import XCTest
@testable import Pretype

/// The pipeline as the reply flow sees it — and the indicator and prompt
/// context it is built with — recording what the flow asks of it.
@MainActor
private final class FakeReplyHost: ReplyHost, IndicatorHost, PromptContextHost {
    private(set) var lastEvent = "waiting for typing"
    var typingContext = TypingContext()
    let engine: CompletionEngine
    var busyReason: String?
    var completionsWelcome = true
    var observedPID: pid_t = 42
    var focusGeneration = 0
    var lastCaretRect: CGRect?
    var lastHostStyle = HostTextStyle()
    var hasActiveSuggestion = false
    var isWorking = false
    var engineState = EngineState.ready
    var knownTextBeforeCaret: String?
    private(set) var adopted: [String] = []
    private(set) var started: [Int] = []
    private(set) var ended: [Int] = []
    private(set) var offered: [(reply: String, on: String)] = []
    private(set) var task: Task<Void, Never>?

    init(engine: CompletionEngine) { self.engine = engine }

    func report(_ event: String) { lastEvent = event }
    func currentTextElement() -> AXUIElement? { FakeWorld.element(1) }
    func adoptReplyField(_ context: TextContext, caret: CGRect) {
        adopted.append(context.textBeforeCaret)
        lastCaretRect = caret
    }
    func startReply(run: (_ id: Int) -> Task<Void, Never>) {
        started.append(started.count + 1)
        task = run(started.count)
    }
    func endReply(_ id: Int) { ended.append(id) }
    func offerReply(_ reply: String, on context: TextContext) -> Bool {
        offered.append((reply, context.textBeforeCaret))
        return true
    }
}

/// The reply flow on a fake host: what stops it and how it says so, what it
/// reads, and that the reply lands on the very read it was asked on.
@MainActor
final class ReplyComposerTests: XCTestCase {
    private let world = FakeWorld()
    private lazy var host = FakeReplyHost(engine: world.engine)
    private lazy var indicator = CaretIndicator(host: host, window: world.window)
    private lazy var replies = ReplyComposer(host: host, env: world.env, indicator: indicator,
                                             prompts: PromptContext(host: host, env: world.env))
    private var savedScreenContext = false

    override func setUp() {
        super.setUp()
        savedScreenContext = Settings.screenContextEnabled
        Settings.screenContextEnabled = true
    }

    override func tearDown() {
        host.task?.cancel()
        Settings.screenContextEnabled = savedScreenContext
        super.tearDown()
    }

    // Asked for, a reply that can't start says why; offered automatically it
    // stays silent. Either way nothing starts.
    func testABusyPipelineStartsNothing() {
        host.busyReason = "dictation is listening"
        XCTAssertFalse(replies.compose(auto: true))
        XCTAssertEqual(host.lastEvent, "waiting for typing")
        XCTAssertFalse(replies.compose())
        XCTAssertEqual(host.lastEvent, "reply: dictation is listening")
        XCTAssertTrue(host.started.isEmpty)
    }

    // A field in an app Pretype stays out of is never even read.
    func testAnAppPretypeStaysOutOfIsNeverRead() {
        host.typingContext = TypingContext(appName: "1Password", bundleID: "com.1password.1password")
        XCTAssertFalse(replies.compose())
        XCTAssertEqual(host.lastEvent, "reply: off in 1Password")
        XCTAssertEqual(world.reads, 0)
    }

    // The field is read once, whole — an empty chat box included — and the
    // reply is offered on that read, after a fresh, wider capture.
    func testTheReplyLandsOnTheReadItWasAskedOn() async {
        world.before = "Ok "
        world.screen = "Alice: lunch?"
        world.engine.reply = "sure, noon"
        XCTAssertTrue(replies.compose())
        XCTAssertEqual(host.adopted, ["Ok "])
        XCTAssertEqual(host.lastEvent, "composing a reply…")
        await host.task?.value
        XCTAssertEqual(world.captures, [1200])
        XCTAssertEqual(world.engine.conversations, ["Alice: lunch?"])
        XCTAssertEqual(host.ended, [1])
        XCTAssertEqual(host.offered.map(\.reply), ["sure, noon"])
        XCTAssertEqual(host.offered.map(\.on), ["Ok "])
    }

    // An AI agent's box answers the session on the terminal itself: no
    // screen context, no Screen Recording, no capture.
    func testAnAgentsBoxRepliesToItsSessionWithoutTheScreen() async {
        Settings.screenContextEnabled = false
        world.screenRecording = false
        world.terminalField = true
        world.agentSession = "⏺ Tests pass. Commit?"
        world.engine.reply = "yes, commit"
        host.typingContext = TypingContext(appName: "Terminal", bundleID: "com.apple.Terminal")
        XCTAssertTrue(replies.compose())
        await host.task?.value
        XCTAssertTrue(world.captures.isEmpty)
        XCTAssertEqual(world.engine.conversations, ["⏺ Tests pass. Commit?"])
        XCTAssertEqual(host.offered.map(\.reply), ["yes, commit"])

        world.agentSession = nil
        XCTAssertFalse(replies.compose(), "a shell is no agent's box")
        XCTAssertTrue(host.lastEvent.hasPrefix("reply: needs screen context"), host.lastEvent)
        let saved = Settings.userBlacklist
        defer { Settings.userBlacklist = saved }
        Settings.userBlacklist = ["com.apple.terminal"]
        XCTAssertFalse(replies.compose())
        XCTAssertEqual(host.lastEvent, "reply: off in Terminal", "switched off by the user")
    }

    // A reply that fails: asked for, it says so at the caret and in "Last:";
    // offered automatically, it says nothing.
    func testAFailedReplyIsSaidOnlyWhenAskedFor() async {
        world.screen = "Alice: lunch?"
        world.engine.replyError = URLError(.timedOut)
        XCTAssertTrue(replies.compose(auto: true))
        await host.task?.value
        XCTAssertNil(world.window.currentMode)
        XCTAssertEqual(host.lastEvent, "composing a reply…")

        XCTAssertTrue(replies.compose())
        await host.task?.value
        XCTAssertTrue(host.lastEvent.hasPrefix("reply failed: "), host.lastEvent)
        XCTAssertEqual(world.window.currentMode, .error("reply failed"))
        XCTAssertEqual(host.ended, [1, 2])
    }

    // The model had nothing to say about a readable conversation: a different
    // silence from nothing on screen, and said only when asked for.
    func testASilentModelIsSaidOnlyWhenAskedFor() async {
        world.screen = "Alice: lunch?"
        XCTAssertTrue(replies.compose(auto: true))
        await host.task?.value
        XCTAssertNil(world.window.currentMode)
        XCTAssertTrue(replies.compose())
        await host.task?.value
        XCTAssertEqual(host.lastEvent, "reply: no answer from the model")
        XCTAssertEqual(world.window.currentMode, .hint("no answer from the model"))
    }

    // Nothing readable on screen: asked for, it says so at the caret; offered
    // automatically, it says nothing.
    func testNothingOnScreenIsSaidOnlyWhenAskedFor() async {
        XCTAssertTrue(replies.compose(auto: true))
        await host.task?.value
        XCTAssertNil(world.window.currentMode)
        XCTAssertTrue(host.offered.isEmpty)

        XCTAssertTrue(replies.compose())
        await host.task?.value
        XCTAssertEqual(host.lastEvent, "reply: nothing to reply to")
        guard case .hint = world.window.currentMode else { return XCTFail("no notice at the caret") }
        XCTAssertEqual(host.ended, [1, 2])
    }

    // MARK: - What stops it

    // No field, or one that can't be read or placed: asked for, said;
    // offered automatically, silent.
    func testAFieldItCannotUseStopsIt() {
        world.readable = false
        XCTAssertFalse(replies.compose(auto: true))
        XCTAssertEqual(host.lastEvent, "waiting for typing")
        XCTAssertFalse(replies.compose())
        XCTAssertEqual(host.lastEvent, "reply: cannot read the field or place the ghost")
        XCTAssertTrue(host.started.isEmpty)
    }

    // An automatic offer needs an empty box — whitespace is empty — and a
    // reply model already loaded; asked for, neither holds it back.
    func testAnAutomaticOfferNeedsAnEmptyBoxAndALoadedModel() {
        world.screen = "Alice: lunch?"
        world.before = "Hi"
        XCTAssertFalse(replies.compose(auto: true))
        world.before = " \n"
        world.after = "x"
        XCTAssertFalse(replies.compose(auto: true), "text after the caret")
        world.after = "  "
        world.engine.correctionReady = false
        XCTAssertFalse(replies.compose(auto: true))
        XCTAssertEqual(host.lastEvent, "waiting for typing")
        XCTAssertTrue(host.started.isEmpty)
        world.engine.correctionReady = true
        XCTAssertTrue(replies.compose(auto: true))
        XCTAssertEqual(host.adopted, [" \n"])
    }

    // Without the screen there is nothing to reply to: the notice names which
    // of the three is missing, in the words the fix is found under.
    func testTheScreenNoticeNamesWhatIsMissing() {
        func notice() -> SuggestionDisplayMode? {
            XCTAssertFalse(replies.compose())
            XCTAssertTrue(host.lastEvent.hasPrefix("reply: needs screen context — "), host.lastEvent)
            defer { world.window.hide() }
            return world.window.currentMode
        }
        Settings.screenContextEnabled = false
        XCTAssertEqual(notice(), .hint("reply reads the screen — turn on “Use screen context” in Settings"))
        Settings.screenContextEnabled = true
        world.screenRecording = false
        XCTAssertEqual(notice(), .hint("reply needs Screen Recording — allow Pretype in System Settings, then relaunch"))
        world.screenRecording = true
        host.typingContext = TypingContext(appName: "Xcode", bundleID: "com.apple.dt.Xcode")
        XCTAssertEqual(notice(), .hint("reply doesn't read the screen in Xcode"))
        host.typingContext = TypingContext(bundleID: "com.apple.dt.Xcode")
        XCTAssertEqual(notice(), .hint("reply doesn't read the screen in this app"))
        XCTAssertFalse(replies.compose(auto: true))
        XCTAssertNil(world.window.currentMode, "an automatic offer stays silent")
        XCTAssertTrue(host.started.isEmpty)
    }

    // MARK: - Called off

    // A reply called off — before its capture lands, or while the engine
    // writes — ends nothing, offers nothing and says nothing.
    func testACalledOffReplyLandsNothing() async {
        world.screen = "Alice: lunch?"
        world.engine.reply = "sure"
        XCTAssertTrue(replies.compose())
        host.task?.cancel()
        await host.task?.value
        XCTAssertTrue(world.engine.conversations.isEmpty, "never asked")
        XCTAssertTrue(host.ended.isEmpty)

        let gate = HeldCall()
        world.engine.replyGate = gate
        XCTAssertTrue(replies.compose())
        var entered = gate.entered.makeAsyncIterator()
        _ = await entered.next()
        host.task?.cancel()
        gate.open()
        await host.task?.value
        XCTAssertTrue(host.ended.isEmpty)
        XCTAssertTrue(host.offered.isEmpty)
        XCTAssertEqual(host.lastEvent, "composing a reply…")
    }

    // An engine that throws CancellationError was called off too.
    func testAnEngineCancellationIsNoFailure() async {
        world.screen = "Alice: lunch?"
        world.engine.replyError = CancellationError()
        XCTAssertTrue(replies.compose())
        await host.task?.value
        XCTAssertTrue(host.ended.isEmpty)
        XCTAssertNil(world.window.currentMode)
        XCTAssertEqual(host.lastEvent, "composing a reply…")
    }

    // A model that isn't loaded says so — not "failed".
    func testAReplyModelNotReadySaysSo() async {
        world.screen = "Alice: lunch?"
        world.engine.replyError = EngineNotReady()
        XCTAssertTrue(replies.compose())
        await host.task?.value
        XCTAssertEqual(world.window.currentMode, .hint(EngineNotReady().message))
    }
}
