import AppKit
import AVFoundation
import XCTest
@testable import Pretype

/// The overlay as a recorder: what is on screen is `currentMode`, nothing more.
@MainActor
final class FakeOverlay: SuggestionOverlay {
    var presentation = SuggestionPresentation.panel
    var onVisibilityChange: (() -> Void)?
    private(set) var isVisible = false
    private(set) var currentMode: SuggestionDisplayMode?
    /// Characters of a suggestion that fit on the line, as the inline ghost
    /// trims it; nil: a pill, shown whole.
    var room: Int?
    /// The suggestion drawn, if one is.
    private(set) var ghost: String?
    private var trimToLine = true

    /// What the window reports back: the trimmed text, or nil for "all of it".
    private func draw(_ text: String) -> String? {
        currentMode = .suggestion(text)
        isVisible = true
        guard trimToLine, let room, text.count > room else {
            ghost = text
            return nil
        }
        ghost = String(text.prefix(room))
        return ghost
    }

    /// Where the last thing was drawn, in what style.
    private(set) var drawnAt: (rect: CGRect, host: HostTextStyle)?

    func show(mode: SuggestionDisplayMode, at caretRect: CGRect, host: HostTextStyle, trimToLine: Bool) -> String? {
        drawnAt = (caretRect, host)
        // As the window does: a protected notice holds off only the
        // non-committal modes, and anything else ends the protection.
        if noticeProtected {
            switch mode {
            case .thinking, .status: return nil
            default: noticeProtected = false
            }
        }
        self.trimToLine = trimToLine
        if case .suggestion(let text) = mode { return draw(text) }
        currentMode = mode
        isVisible = true
        ghost = nil
        return nil
    }

    /// How long the last notice was to stay up, and be protected.
    private(set) var noticeTimes: (hideAfter: TimeInterval, protectFor: TimeInterval)?

    func showTransient(_ mode: SuggestionDisplayMode, at caretRect: CGRect, host: HostTextStyle,
                       hideAfter: TimeInterval, protectFor: TimeInterval) {
        noticeTimes = (hideAfter, protectFor)
        drawnAt = (caretRect, host)
        noticeProtected = protectFor > 0
        currentMode = mode
        isVisible = true
        ghost = nil
    }

    /// As the window does: a protected notice outlasts an ordinary hide;
    /// a forced one ends the protection.
    func hide(force: Bool) {
        if force { noticeProtected = false } else if noticeProtected { return }
        currentMode = nil
        isVisible = false
        ghost = nil
    }

    func advance(past accepted: String, remaining: String) -> String? { draw(remaining) }

    /// A notice up with `protectFor` (the window times it out; here it lasts).
    private(set) var noticeProtected = false
    func clearNoticeProtection() { noticeProtected = false }
    private(set) var fieldChanges = 0
    func fieldChanged() { fieldChanges += 1 }
}

/// Holds an engine call mid-flight until the test opens it: `entered` says the
/// call is waiting.
final class HeldCall: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: CheckedContinuation<Void, Never>?
    let entered: AsyncStream<Void>
    private let enter: AsyncStream<Void>.Continuation

    init() { (entered, enter) = AsyncStream.makeStream() }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.withLock { waiting = continuation }
            enter.yield()
        }
    }

    func open() {
        lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { waiting = nil }
            return waiting
        }?.resume()
    }
}

/// Streams `partials` for every completion request, and remembers the requests.
final class FakeEngine: CompletionEngine {
    let name = "fake"
    let statusLine: String? = nil
    var state = EngineState.ready
    let loadedModelID: String? = "fake-model"
    let lastFirstWordLogProb: Double? = -0.5
    var partials: [String] = []
    /// What the stream throws once its partials are out, if anything.
    var completionError: Error?
    /// The streams stay open for the test to feed (`stream`).
    var holdsStreams = false
    private(set) var stream: AsyncThrowingStream<String, Error>.Continuation?
    private(set) var shutdowns = 0
    func shutdown() { shutdowns += 1 }
    var reply: String?
    /// While set, `reply` waits at it.
    var replyGate: HeldCall?
    /// The fix model is on disk (`isCorrectionReady`).
    var correctionReady = true
    var isCorrectionReady: Bool { correctionReady }
    private(set) var requests: [CompletionRequest] = []
    private(set) var conversations: [String] = []

    func complete(_ request: CompletionRequest) async throws -> String? { partials.last }

    func completions(for request: CompletionRequest) -> AsyncThrowingStream<String, Error> {
        requests.append(request)
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        partials.forEach { continuation.yield($0) }
        if holdsStreams { self.stream = continuation } else { continuation.finish(throwing: completionError) }
        return stream
    }

    /// Prompts the engine was asked to prefill (their text before the caret).
    private(set) var warmed: [String] = []
    func warmPrompt(for request: CompletionRequest) { warmed.append(request.textBeforeCaret) }
    /// Times the model was woken for a field just entered.
    private(set) var prewarms = 0
    /// A failed load that the prewarm's retry brings back.
    var prewarmRecovers = false
    func prewarmIfNeeded() {
        prewarms += 1
        if prewarmRecovers { state = .preparing("loading") }
    }

    /// What `correct` proposes (nil: nothing to fix).
    var correction: String?
    /// Whether each `correct` call asked for its text to stay out of the log.
    private(set) var redactedCorrections: [Bool] = []
    /// The texts `correct` was asked to fix.
    private(set) var corrected: [String] = []
    /// What `correct` throws, if anything.
    var correctionError: Error?
    func correct(selection: String, redactLog: Bool) async throws -> String? {
        redactedCorrections.append(redactLog)
        corrected.append(selection)
        if let correctionError { throw correctionError }
        return correction
    }
    /// What `reply` throws, if anything.
    var replyError: Error?
    func reply(to conversation: String, request: CompletionRequest) async throws -> String? {
        conversations.append(conversation)
        await replyGate?.wait()
        if let replyError { throw replyError }
        return reply
    }
    /// The voice commands asked for, and the fix-model downloads started.
    private(set) var rewrites: [(selection: String, instruction: String)] = []
    func rewrite(selection: String, instruction: String) async throws -> String? {
        rewrites.append((selection, instruction))
        return nil
    }
    private(set) var correctionPrewarms = 0
    func prewarmCorrection() { correctionPrewarms += 1 }
    func updateCompletion(length: CompletionLength, instructions: String) {}
}

/// A microphone that opens and hears nothing.
@MainActor
final class SilentMicrophone: AudioCapturing {
    func start(deviceUID: String?, outputFormat: AVAudioFormat?,
               onDeviceChange: @escaping @Sendable () -> Void,
               onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws {}
    func stop() {}
}

/// A transcriber that takes the audio and writes nothing down.
final class EmptySession: TranscriptionSession, @unchecked Sendable {
    let audioFormat: AVAudioFormat? = nil
    func feed(_ buffer: AVAudioPCMBuffer) {}
    func finish() async throws -> String { "" }
    func cancel() {}
}

/// A transcriber whose final pass waits for the test to open `gate`, then
/// writes down `transcript`: the capture sits in `.working` until then.
final class HeldSession: TranscriptionSession, @unchecked Sendable {
    let audioFormat: AVAudioFormat? = nil
    let gate = HeldCall()
    let transcript: String
    init(transcript: String) { self.transcript = transcript }
    func feed(_ buffer: AVAudioPCMBuffer) {}
    func finish() async throws -> String {
        await gate.wait()
        return transcript
    }
    func cancel() {}
}

/// Everything outside the controller: one tracked field whose text the test
/// writes, keys recorded instead of posted, a clock that moves only when told,
/// delayed work held until the clock reaches it, and the books recorded.
@MainActor
final class FakeWorld {
    enum Key: Equatable {
        case delete(String, perCharacter: Bool)
        case insert(String)
        case returnKey
    }

    /// A handle no AX call ever reaches: every read goes through `env`.
    static func element(_ id: Int32) -> AXUIElement { AXUIElementCreateApplication(90_000 + id) }

    let window = FakeOverlay()
    let engine = FakeEngine()
    var tracked: AXUIElement? = element(1)
    /// The field's text before the caret. A read that ends on a word of three
    /// letters or more asks the system spell checker (the inline fix), so the
    /// tests that read after an accept accept short words.
    var before = ""
    var after = ""
    /// A web or Electron field: read empty, it reports nothing unless asked
    /// to (`allowEmpty`).
    var emptyReadsNil = false
    /// The field's font and colours, as a read reports them.
    var host = HostTextStyle()
    /// false: a live field that reads nothing (an IME composition, an empty web field).
    var readable = true
    /// Reads that got the field.
    private(set) var reads = 0
    /// Handles whose node the app destroyed, and the one a re-latch finds.
    var dead: [AXUIElement] = []
    var replacement: AXUIElement?
    var terminalField = false
    /// The agent session a terminal field reads above its input box.
    var agentSession: String?
    /// A launcher-style panel holding the keys, and its field.
    var panelOwner: pid_t?
    /// Unplugged, with "pause on battery" on.
    var pausedForBattery = false
    var networkUnmetered = true
    /// The accepted phrases the journal finds like the text typed, and the
    /// lookups made — off the main actor, hence the lock.
    private let journal = LockedValue((phrases: [SuggestionJournal.AcceptedPhrase](), lookups: 0, query: ""))
    var phrases: [SuggestionJournal.AcceptedPhrase] {
        get { journal.withLock { $0.phrases } }
        set { journal.withLock { $0.phrases = newValue } }
    }
    var phraseLookups: Int { journal.withLock { $0.lookups } }
    /// The text the last lookup was for.
    var phraseQuery: String { journal.withLock { $0.query } }
    /// Settings or the Debug console is frontmost.
    var ownWindowFrontmost = false
    /// The bundle IDs of the processes a panel can belong to.
    var bundles: [pid_t: String] = [:]
    var launcherField: AXUIElement?
    /// What the launcher's own field reads.
    var launcherText = ""
    /// The field the system reports focused when the tracker has none, and
    /// the page it is on — read how many times.
    var systemField: AXUIElement?
    var site: String?
    private(set) var siteReads = 0
    var markedText = false
    /// The field's selection, if any.
    var selected: SelectionInfo?
    var secureInput = false
    var screenRecording = true
    /// What OCR reads off the window, and the captures asked for (their caps).
    var screen: String?
    private(set) var captures: [Int] = []
    /// How long a liveness probe takes: an app that answers slowly is one
    /// whose reads are timing out.
    var probeTakes: TimeInterval = 0
    var now = Date(timeIntervalSinceReferenceDate: 0)
    private(set) var keys: [Key] = []
    /// A clipboard of the test's own — never the user's.
    let pasteboard = NSPasteboard.withUniqueName()
    /// What the clipboard holds: a transcript put there instead of typed.
    var copied: [String] { pasteboard.string(forType: .string).map { [$0] } ?? [] }
    /// The apps whose suggestions go unused (`Stats.isUnproductive`).
    var unproductive: Set<String> = []
    /// The user's own n-gram, empty until a test teaches it — built from a
    /// journal of the test's own, never the user's.
    let ngram: PersonalNgram = {
        let ngram = PersonalNgram()
        ngram.prepareIfNeeded(journal: SuggestionJournal(
            url: FileManager.default.temporaryDirectory.appendingPathComponent("no-journal-\(UUID().uuidString).jsonl")))
        return ngram
    }()
    private(set) var probes: [AXUIElement] = []
    private(set) var scheduled: [(due: Date, work: @MainActor () -> Void)] = []
    private(set) var hops: [@MainActor () -> Void] = []
    /// What the controller booked, in order.
    private(set) var bookings: [SuggestionController.Booking] = []
    var offers: [SuggestionJournal.Entry] {
        bookings.compactMap { if case .offer(let entry) = $0 { return entry } else { return nil } }
    }
    var undos: [SuggestionJournal.Entry] {
        bookings.compactMap { if case .undo(let entry) = $0 { return entry } else { return nil } }
    }
    /// The accepted chunks booked, and whether each counted as a suggestion.
    var accepts: [String] {
        bookings.compactMap {
            if case .accepted(let chunk, let counted, _) = $0 { return counted ? "+" + chunk : chunk } else { return nil }
        }
    }

    var env: SuggestionController.Environment { env(tracking: nil) }

    /// With `tracker`, the handle and its re-latch are the real tracker's.
    func env(tracking tracker: FocusTracker?) -> SuggestionController.Environment {
        SuggestionController.Environment(
            window: window,
            engine: engine,
            trackedElement: { [unowned self] in tracker.map { $0.focusedTextElement } ?? tracked },
            focusedPanelOwner: { [unowned self] in panelOwner },
            ownUIFrontmost: { [unowned self] in ownWindowFrontmost },
            pausedForBattery: { [unowned self] in pausedForBattery },
            bundleIdentifier: { [unowned self] in bundles[$0] },
            systemFocusedElement: { [unowned self] _ in panelOwner == nil ? systemField : launcherField },
            pageHost: { [unowned self] _ in
                siteReads += 1
                return site
            },
            relatchIfDead: { [unowned self] element in
                probes.append(element)
                now += probeTakes
                if let tracker { return tracker.relatchIfDead(element) }
                guard dead.contains(element) else { return false }
                tracked = replacement
                return true
            },
            readContext: { [unowned self] element, allowEmpty in
                guard readable, !dead.contains(element) else { return nil }
                if emptyReadsNil, !allowEmpty, before.isEmpty, after.isEmpty { return nil }
                reads += 1
                return TextContext(textBeforeCaret: element == launcherField ? launcherText : before, textAfterCaret: after,
                                   caretRect: CGRect(x: 100, y: 100, width: 1, height: 16), host: host)
            },
            selection: { [unowned self] _ in selected },
            hasMarkedText: { [unowned self] _ in markedText },
            secureInputActive: { [unowned self] in secureInput },
            isTerminalField: { [unowned self] _ in terminalField },
            agentTranscript: { [unowned self] _ in terminalField ? agentSession : nil },
            deleteBackward: { [unowned self] in keys.append(.delete($0, perCharacter: $1)) },
            insert: { [unowned self] in keys.append(.insert($0)) },
            pressReturn: { [unowned self] in keys.append(.returnKey) },
            pasteboard: pasteboard,
            now: { [unowned self] in now },
            after: { [unowned self] delay, work in scheduled.append((now.addingTimeInterval(delay), work)) },
            hop: { [unowned self] work in hops.append(work) },
            debounce: {},
            screenRecordingAllowed: { [unowned self] in screenRecording },
            // Weak: a reply task cancelled at teardown still captures first.
            networkUnmetered: { [unowned self] in networkUnmetered },
            captureScreen: { [weak self] _, _, _, maxChars in
                self?.captures.append(maxChars)
                return self?.screen
            },
            book: { [weak self] in self?.bookings.append($0) },
            isUnproductive: { [unowned self] in $0.map(unproductive.contains) ?? false },
            personalNgram: ngram,
            similarAcceptedPhrases: { [journal] query in
                journal.withLock {
                    $0.lookups += 1
                    $0.query = query
                    return $0.phrases
                }
            })
    }

    deinit { pasteboard.releaseGlobally() }

    /// Move the clock on by `seconds`, running the delayed work that comes
    /// due on the way, in the order it comes due.
    func advance(_ seconds: TimeInterval) {
        let end = now.addingTimeInterval(seconds)
        while let next = scheduled.enumerated().filter({ $0.element.due <= end })
            .min(by: { $0.element.due < $1.element.due }) {
            scheduled.remove(at: next.offset)
            now = max(now, next.element.due)
            next.element.work()
        }
        now = end
    }

    /// Run all the delayed work pending now, in the order it comes due, and
    /// leave the clock where it was.
    func runScheduled() {
        let work = scheduled.sorted { $0.due < $1.due }
        scheduled = []
        work.forEach { $0.work() }
    }

    /// Run what the key tap handed off its callback.
    func runHops() {
        let work = hops
        hops = []
        work.forEach { $0() }
    }
}

/// A real `SuggestionController` over `FakeWorld`, driven step by step — no
/// AX tree, no posted events, no window server, no model, no real timers. The
/// base of the pipeline's instance suites.
@MainActor
class PipelineTestCase: XCTestCase {
    var fake: FakeWorld!
    var controller: SuggestionController!
    private var restore: [() -> Void] = []

    /// Set a setting for this test; `tearDown` puts it back.
    func set<T>(_ path: ReferenceWritableKeyPath<Settings.Type, T>, _ value: T) {
        let saved = Settings.self[keyPath: path]
        restore.append { Settings.self[keyPath: path] = saved }
        Settings.self[keyPath: path] = value
    }

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared   // `isOwnUIFrontmost` asks NSApp
        set(\.enabled, true)
        set(\.onboardingCompleted, true)
        set(\.hotkeyStyle, .tab)
        set(\.dictationEnabled, false)
        // Nothing here may touch the user's real data: no n-gram, no journal.
        set(\.personalizationLevel, .off)
        set(\.suggestionJournalEnabled, false)
        set(\.screenContextEnabled, false)
        set(\.clipboardContextEnabled, false)
        set(\.pauseOnBattery, false)
        fake = FakeWorld()
        controller = SuggestionController(env: fake.env)
    }

    override func tearDown() {
        controller.dismiss()   // cancels the query, stops the indicator's timer
        controller.dictationController.invalidate()   // and a capture's silence clock
        controller = nil
        fake = nil
        focusApp = nil
        restore.reversed().forEach { $0() }
        restore = []
        super.tearDown()
    }

    // MARK: - Helpers

    static let keyC: Int64 = 8

    /// A key the user presses: the tap's view of it, `typing` its characters.
    @discardableResult
    func press(_ keyCode: Int64, _ flags: CGEventFlags = [], typing text: String? = nil) throws -> Bool {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true))
        event.flags = flags
        if let text {
            let units = Array(text.utf16)
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        }
        return controller.handleKeyDown(event)
    }

    /// The user types `text`: one key event carrying it, as an IME commit does.
    @discardableResult
    func type(_ text: String) throws -> Bool { try press(0, typing: text) }

    /// The field reads `before`, and a streamed partial offering `ghost` lands.
    func showGhost(_ ghost: String, on before: String) {
        fake.before = before
        controller.textDidChange()
        XCTAssertTrue(controller.apply(ghost, requestText: before))
        XCTAssertEqual(fake.window.ghost, ghost)
    }

    /// Let what the controller queued on the main actor run (a focus report).
    func settleMain() async {
        for _ in 0..<3 { await Task.yield() }
    }

    /// Rebuild the controller over a real `FocusTracker` reading `app`, focused
    /// on its first field, with the first focus report landed.
    func trackRealFocus(_ app: FakeFocusApp) async -> FocusTracker {
        let tracker = FocusTracker(ax: app.calls)
        controller.dismiss()
        controller = SuggestionController(env: fake.env(tracking: tracker), focusTracker: tracker)
        tracker.follow(app.element, observer: nil)
        await settleMain()
        return tracker
    }

    /// Rebuild the controller over a real tracker focused on a field of the
    /// app `bundleID`, its focus report landed.
    func enterApp(_ bundleID: String) async {
        let app = FakeFocusApp()
        app.fields = [(FakeWorld.element(1), "Message")]
        app.focused = FakeWorld.element(1)
        app.bundleID = bundleID
        focusApp = app   // the tracker's calls hold it unowned
        _ = await trackRealFocus(app)
    }

    /// The app `enterApp` entered.
    private(set) var focusApp: FakeFocusApp?

    /// Rebuild the controller over a dictation that can listen — a silent
    /// microphone, a transcriber that hears nothing — and start a hands-free
    /// capture in the tracked field.
    func startHandsFreeCapture(session: any TranscriptionSession = EmptySession()) async {
        set(\.dictationEnabled, true)
        let dictation = DictationController(capture: SilentMicrophone())
        dictation.gates.micBundled = { true }
        dictation.gates.micStatus = { .authorized }
        dictation.gates.transcriptionSupported = { true }
        dictation.gates.startSession = { _, _ in session }
        controller.dismiss()
        controller = SuggestionController(env: fake.env, dictation: dictation)
        dictation.toggleLatch()
        await dictation.sessionTask?.value
    }

    func finishQuery() async throws {
        let task = try XCTUnwrap(controller.queries.current?.task, "no query in flight")
        await task.value
    }
}
