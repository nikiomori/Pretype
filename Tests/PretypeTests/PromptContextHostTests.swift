import ApplicationServices
import XCTest
@testable import Pretype

@MainActor
private final class FakePromptHost: PromptContextHost {
    var typingContext = TypingContext()
    var focusGeneration = 0
    var lastCaretRect: CGRect?
    var knownTextBeforeCaret: String?
    var busyReason: String?
    var completionsWelcome = true
    let engine: CompletionEngine
    var observedPID: pid_t = 42
    var field: AXUIElement? = FakeWorld.element(1)
    func currentTextElement() -> AXUIElement? { field }

    init(engine: CompletionEngine) { self.engine = engine }
}

/// The prompt context on a fake host: when it warms the engine, which window
/// captures it keeps, and what it says about the screen.
@MainActor
final class PromptContextHostTests: XCTestCase {
    private var world = FakeWorld()
    private lazy var host = FakePromptHost(engine: world.engine)
    private lazy var context = PromptContext(host: host, env: world.env)
    private var saved = (screen: false, clipboard: false, enabled: true, battery: false)

    override func setUp() {
        super.setUp()
        saved = (Settings.screenContextEnabled, Settings.clipboardContextEnabled, Settings.enabled,
                 Settings.pauseOnBattery)
        Settings.screenContextEnabled = true
        Settings.clipboardContextEnabled = false
        Settings.enabled = true
    }

    override func tearDown() {
        (Settings.screenContextEnabled, Settings.clipboardContextEnabled, Settings.enabled, Settings.pauseOnBattery)
            = saved
        super.tearDown()
    }

    /// The clipboard holds `text`, marked `type` (a password manager's).
    private func copy(_ text: String, marked type: String? = nil) {
        world.pasteboard.clearContents()
        world.pasteboard.setString(text, forType: .string)
        if let type { world.pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType(type)) }
    }

    /// Until `condition` holds — the capture's task hops off the main actor and
    /// back. The deadline only bounds a wedge.
    private func waitUntil(_ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(5)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(1)) }
    }

    // A warm-up re-reads the prompt for text being typed into an idle
    // pipeline — none while paused, our window is up or a capture listens,
    // and none for a field with nothing in it.
    func testWarmsOnlyAnIdlePipelineWithText() {
        host.busyReason = "dictation is listening"
        context.warm("Hi")
        XCTAssertTrue(world.engine.warmed.isEmpty)
        host.busyReason = nil
        context.warm("   ")
        context.warm()
        XCTAssertTrue(world.engine.warmed.isEmpty)
        context.warm("Hi")
        host.knownTextBeforeCaret = "Yo"
        context.warm()
        XCTAssertEqual(world.engine.warmed, ["Hi", "Yo"])
    }

    // The OCR lands seconds later: one for the field just left is dropped,
    // or the next field's prompt would carry another app's screen.
    func testACaptureForTheFieldJustLeftIsDropped() async {
        world.screen = "Alice: lunch?"
        context.refreshScreenIfNeeded(typed: "Hi")
        host.focusGeneration += 1
        await waitUntil { !context.screenCaptureInFlight }
        XCTAssertNil(context.screenSummary)
        XCTAssertTrue(world.engine.warmed.isEmpty)
    }

    func testAFreshCaptureJoinsThePromptAndWarmsIt() async {
        world.screen = "Alice: lunch?"
        host.knownTextBeforeCaret = "Hi"
        context.refreshScreenIfNeeded(typed: "Hi")
        await waitUntil { !context.screenCaptureInFlight }
        XCTAssertEqual(context.screenSummary, "Alice: lunch?")
        XCTAssertEqual(world.engine.warmed, ["Hi"])
        XCTAssertEqual(context.makeRequest(text: "Hi").screenSummary, "Alice: lunch?")
        // Never in a code editor: its window is code, which poisons a prose model.
        host.typingContext = TypingContext(bundleID: "com.microsoft.VSCode")
        XCTAssertNil(context.makeRequest(text: "Hi").screenSummary)
    }

    // The window is OCR'd at most every 25 s: a capture within that window
    // of the last one is not made.
    func testTheScreenIsReadAtMostEvery25Seconds() async {
        world.screen = "Alice: lunch?"
        context.refreshScreenIfNeeded(typed: "Hi")
        await waitUntil { !context.screenCaptureInFlight }
        world.now += 25
        context.refreshScreenIfNeeded(typed: "Hi")
        XCTAssertFalse(context.screenCaptureInFlight)
        world.now += 0.5
        context.refreshScreenIfNeeded(typed: "Hi")
        await waitUntil { !context.screenCaptureInFlight }
        XCTAssertEqual(world.captures.count, 2)
    }

    // A capture warms the prompt only when it changed it — or when it is
    // the first since the focus moved, which finds the prompt cold even with
    // nothing captured.
    func testACaptureWarmsOnlyAChangedPrompt() async {
        host.knownTextBeforeCaret = "Hi"
        context.refreshScreenIfNeeded(typed: "Hi")
        await waitUntil { !context.screenCaptureInFlight }
        XCTAssertEqual(world.engine.warmed, ["Hi"], "the first capture, empty or not")
        world.now += 26
        context.refreshScreenIfNeeded(typed: "Hi")
        await waitUntil { !context.screenCaptureInFlight }
        XCTAssertEqual(world.engine.warmed, ["Hi"], "nothing new on screen")
        world.screen = "Alice: lunch?"
        world.now += 26
        context.refreshScreenIfNeeded(typed: "Hi")
        await waitUntil { !context.screenCaptureInFlight }
        XCTAssertEqual(world.engine.warmed, ["Hi", "Hi"])
    }

    /// Retrieve the examples for `typed`, and let the lookup land.
    private func retrieve(_ typed: String) async {
        let lookups = world.phraseLookups
        context.refreshExamplesIfNeeded(typed: typed)
        await waitUntil { world.phraseLookups > lookups }
        for _ in 0..<5 { await Task.yield() }
    }

    // The user's own phrases are looked up for twelve characters or more,
    // at most every 25 s, and warm the prompt only when they changed.
    func testExamplesAreRetrievedSparingly() async {
        host.knownTextBeforeCaret = "see you at noon"
        world.phrases = [SuggestionJournal.AcceptedPhrase(ctx: "see you", next: " soon")]
        context.refreshExamplesIfNeeded(typed: "see you at ")
        XCTAssertEqual(world.phraseLookups, 0, "eleven characters say too little")
        await retrieve("see you at n")
        XCTAssertEqual(world.phraseLookups, 1)
        XCTAssertEqual(context.makeRequest(text: "see you at n").personalExamples, world.phrases)
        XCTAssertEqual(world.engine.warmed, ["see you at noon"])

        world.now += 25
        context.refreshExamplesIfNeeded(typed: "see you at no")
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(world.phraseLookups, 1, "within 25 s of the last")
        world.now += 0.5
        await retrieve("see you at noo")
        XCTAssertEqual(world.phraseLookups, 2)
        XCTAssertEqual(world.engine.warmed.count, 1, "the same phrases: the prompt is unchanged")

        world.phrases = []
        world.now += 26
        await retrieve("see you at noon")
        XCTAssertEqual(world.engine.warmed.count, 2)
        XCTAssertEqual(context.makeRequest(text: "x").personalExamples, [])
    }

    // The request carries the field, the app and site, and whether the text
    // ends on a complete word (a space and a next word may follow).
    func testTheRequestCarriesTheField() {
        host.typingContext = TypingContext(appName: "Mail", bundleID: "com.apple.mail", site: "mail.example.com")
        let request = context.makeRequest(text: "see you there", after: "!")
        XCTAssertEqual(request.textBeforeCaret, "see you there")
        XCTAssertEqual(request.textAfterCaret, "!")
        XCTAssertEqual(request.appBundleID, "com.apple.mail")
        XCTAssertEqual(request.appName, "Mail")
        XCTAssertEqual(request.site, "mail.example.com")
        XCTAssertEqual(request.endsOnCompleteWord, true)
        XCTAssertEqual(context.makeRequest(text: "see you ther").endsOnCompleteWord, false)
    }

    // MARK: - The clipboard

    // The clipboard joins the prompt — opted in, in an app the screen may be
    // read in, not once it's pasted, never a concealed or transient copy.
    func testTheClipboardJoinsThePrompt() {
        copy("meeting at 5pm in room 4")
        XCTAssertNil(context.makeRequest(text: "Hi").clipboardContext, "opt-in")
        Settings.clipboardContextEnabled = true
        XCTAssertEqual(context.makeRequest(text: "Hi").clipboardContext, "meeting at 5pm in room 4")
        XCTAssertNil(context.makeRequest(text: "see meeting at 5pm in room 4").clipboardContext, "already pasted")
        host.typingContext = TypingContext(bundleID: "com.microsoft.VSCode")
        XCTAssertNil(context.makeRequest(text: "Hi").clipboardContext, "a code editor's clipboard is code")
        host.typingContext = TypingContext()
        copy("hunter2", marked: "org.nspasteboard.ConcealedType")
        XCTAssertNil(context.makeRequest(text: "Hi").clipboardContext)
        copy("one-time code", marked: "org.nspasteboard.TransientType")
        XCTAssertNil(context.makeRequest(text: "Hi").clipboardContext)
        copy("lunch?")
        XCTAssertEqual(context.makeRequest(text: "Hi").clipboardContext, "lunch?")
    }

    // A ⌘-chord may have been a copy: a clipboard that changed warms the
    // prompt, with the cache's text or, unknown, a read of the field.
    func testACopyWarmsThePrompt() {
        Settings.clipboardContextEnabled = true
        host.knownTextBeforeCaret = "Hi"
        context.warmIfClipboardChanges()
        world.advance(0.2)
        XCTAssertTrue(world.engine.warmed.isEmpty, "nothing was copied")

        context.warmIfClipboardChanges()
        copy("lunch?")
        world.advance(0.1)
        XCTAssertTrue(world.engine.warmed.isEmpty, "not before the copy lands")
        world.advance(0.1)
        XCTAssertEqual(world.engine.warmed, ["Hi"])

        host.knownTextBeforeCaret = nil
        world.before = "Hey"
        context.warmIfClipboardChanges()
        copy("noon?")
        world.advance(0.2)
        XCTAssertEqual(world.engine.warmed, ["Hi", "Hey"])
    }

    // Opted out, or where the screen isn't read, a chord asks nothing.
    func testACopyIsIgnoredWhereTheClipboardIsNot() {
        host.knownTextBeforeCaret = "Hi"
        context.warmIfClipboardChanges()
        Settings.clipboardContextEnabled = true
        host.typingContext = TypingContext(bundleID: "com.microsoft.VSCode")
        context.warmIfClipboardChanges()
        copy("lunch?")
        world.advance(0.2)
        XCTAssertTrue(world.engine.warmed.isEmpty)
    }

    // MARK: - When the screen is read

    // Opted in, permitted, plugged in or unpaused, in an app the screen may
    // be read in, with an app to read, and one capture at a time.
    func testWhenTheScreenIsRead() async {
        func captures(_ change: () -> Void) async -> Int {
            change()
            let before = world.captures.count
            context.refreshScreenIfNeeded(typed: "Hi")
            await waitUntil { !context.screenCaptureInFlight }
            return world.captures.count - before
        }
        let gates: [(String, () -> Void, Int)] = [
            ("opted out", { Settings.screenContextEnabled = false }, 0),
            ("no permission", { Settings.screenContextEnabled = true; self.world.screenRecording = false }, 0),
            ("paused", { self.world.screenRecording = true; Settings.enabled = false }, 0),
            ("on battery", { Settings.enabled = true; self.world.pausedForBattery = true }, 0),
            ("a code editor", {
                self.world.pausedForBattery = false
                self.host.typingContext = TypingContext(bundleID: "com.microsoft.VSCode")
            }, 0),
            ("no app", { self.host.typingContext = TypingContext(); self.host.observedPID = 0 }, 0),
            ("all clear", { self.host.observedPID = 42 }, 1),
        ]
        for (name, change, want) in gates {
            let made = await captures(change)
            XCTAssertEqual(made, want, name)
        }

        world.now += 30
        context.refreshScreenIfNeeded(typed: "Hi")
        XCTAssertTrue(context.screenCaptureInFlight)
        XCTAssertEqual(context.screenStatus, "capturing…")
        context.refreshScreenIfNeeded(typed: "Hi")
        await waitUntil { !context.screenCaptureInFlight }
        XCTAssertEqual(world.captures.count, 2, "one at a time")
    }

    // A focus change forgets the old window and the old examples, and the
    // new field's are read at once.
    func testAFocusChangeStartsTheContextOver() async {
        world.screen = "Alice: lunch?"
        world.phrases = [SuggestionJournal.AcceptedPhrase(ctx: "see you", next: " soon")]
        context.refreshScreenIfNeeded(typed: "Hi")
        await waitUntil { !context.screenCaptureInFlight }
        await retrieve("see you at n")
        XCTAssertEqual(context.screenStatus, "captured 13 chars")
        context.focusChanged()
        XCTAssertNil(context.screenSummary)
        XCTAssertEqual(context.makeRequest(text: "x").personalExamples, [])
        context.refreshScreenIfNeeded(typed: "Hi")
        await waitUntil { !context.screenCaptureInFlight }
        XCTAssertEqual(world.captures.count, 2, "not held to the old window's 25 s")
        await retrieve("see you at no")
        XCTAssertEqual(world.phraseLookups, 2)
    }

    // A pipeline that wants no completions here warms nothing.
    func testNoWarmWhereCompletionsAreUnwelcome() {
        host.completionsWelcome = false
        context.warm("Hi")
        XCTAssertTrue(world.engine.warmed.isEmpty)
    }

    // The phrases are looked up for the last 300 characters typed.
    func testTheLookupIsForTheTextsTail() async {
        let typed = String(repeating: "word ", count: 100)
        await retrieve(typed)
        XCTAssertEqual(world.phraseQuery, String(typed.suffix(300)))
    }

    // One retrieval at a time: a second ask while one runs asks nothing.
    func testOneRetrievalAtATime() async {
        world.phrases = [SuggestionJournal.AcceptedPhrase(ctx: "see you", next: " soon")]
        context.refreshExamplesIfNeeded(typed: "see you at noon")
        context.refreshExamplesIfNeeded(typed: "see you at noon!")
        await waitUntil { world.phraseLookups > 0 }
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(world.phraseLookups, 1)
    }

    // The Context menu says which of the three is missing.
    func testScreenStatusNamesWhatIsMissing() {
        XCTAssertEqual(context.screenStatus, "nothing captured yet")
        world.screenRecording = false
        XCTAssertEqual(context.screenStatus, "no Screen Recording permission (grant + relaunch)")
        world.screenRecording = true
        host.typingContext = TypingContext(bundleID: "com.microsoft.VSCode")
        XCTAssertEqual(context.screenStatus, "blocked in this app (terminal/code editor)")
        Settings.screenContextEnabled = false
        XCTAssertEqual(context.screenStatus, "off")
    }
}
