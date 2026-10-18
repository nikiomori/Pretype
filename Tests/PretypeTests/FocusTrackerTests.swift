import ApplicationServices
import XCTest
@testable import Pretype

/// The tracked app as `FocusTracker` reads it: which field holds focus, the
/// fields' labels, the window title and the nodes the app destroyed.
final class FakeFocusApp {
    let element = AXUIElementCreateApplication(90_100)
    var window: AXUIElement? = AXUIElementCreateApplication(90_101)
    var fields: [(element: AXUIElement, label: String?)] = []
    var focused: AXUIElement?
    var title: String? = "Chat"
    var bundleID: String?
    /// The web page the fields are on (`AXText.pageHost`).
    var site: String?
    var dead: [AXUIElement] = []
    /// Times its accessibility tree was woken.
    private(set) var wakes = 0
    /// The notifications an observer posts, per element, and how many
    /// registrations were made in all.
    private(set) var registered: [AXUIElement: Set<String>] = [:]
    private(set) var registrations = 0

    var calls: FocusTracker.AXCalls {
        FocusTracker.AXCalls(
            focusedElement: { [unowned self] _ in focused },
            focusedWindow: { [unowned self] _ in window },
            title: { [unowned self] _ in title },
            editableLabel: { [unowned self] element in fields.first { $0.element == element }.map(\.label) },
            pageHost: { [unowned self] _ in site },
            bundleID: { [unowned self] _ in bundleID },
            isDead: { [unowned self] element in dead.contains(element) },
            wake: { [unowned self] _ in wakes += 1 },
            register: { [unowned self] _, element, name, _ in
                registrations += 1
                registered[element, default: []].insert(name)
            },
            unregister: { [unowned self] _, element, name in
                registered[element]?.remove(name)
                if registered[element]?.isEmpty == true { registered[element] = nil }
            })
    }
}

/// The real tracker over `FakeFocusApp`: the focus-report dedupe and the
/// quiet re-latch of a node the app replaced.
@MainActor
final class FocusTrackerTests: XCTestCase {
    private let message = AXUIElementCreateApplication(90_001)
    private let remounted = AXUIElementCreateApplication(90_002)
    private let search = AXUIElementCreateApplication(90_003)
    private var app = FakeFocusApp()
    private var tracker = FocusTracker()
    private var reports = 0

    override func setUp() {
        super.setUp()
        app = FakeFocusApp()
        app.fields = [(message, "Message"), (remounted, "Message"), (search, "Search")]
        app.focused = message
        tracker = FocusTracker(ax: app.calls)
        reports = 0
        tracker.onFocusChange = { [unowned self] in reports += 1 }
    }

    /// Let the reports the tracker queued on the main actor run.
    private func settle() async {
        for _ in 0..<3 { await Task.yield() }
    }

    private func focusNotification() {
        tracker.handleNotification(kAXFocusedUIElementChangedNotification, element: app.element)
    }

    // Apps fire the focus notification in duplicate bursts: the same field is
    // no change, and a burst that ends where it started reports nothing.
    func testDuplicateFocusNotificationsReportOnce() async {
        tracker.follow(app.element, observer: nil)
        await settle()
        XCTAssertEqual(reports, 1)
        XCTAssertEqual(tracker.reportedContext.fieldLabel, "Message")
        focusNotification()
        await settle()
        XCTAssertEqual(reports, 1)

        app.focused = search
        focusNotification()
        await settle()
        XCTAssertEqual(reports, 2)
        XCTAssertEqual(tracker.reportedContext.fieldLabel, "Search")

        app.focused = message
        focusNotification()
        app.focused = search
        focusNotification()
        await settle()
        XCTAssertEqual(reports, 2, "compared when the report runs")
    }

    // A web app re-mounting the field under the caret (same label, same window)
    // is swapped in quietly — and stays the same field for every later focus
    // notification, or the pipeline would tear down its ghost and ⌘Z on the next.
    func testAQuietRelatchIsNoFocusChange() async {
        tracker.follow(app.element, observer: nil)
        await settle()
        app.dead = [message]
        app.focused = remounted
        XCTAssertTrue(tracker.relatchIfDead(message))
        XCTAssertEqual(tracker.focusedTextElement, remounted)
        await settle()
        XCTAssertEqual(reports, 1)
        focusNotification()
        await settle()
        XCTAssertEqual(reports, 1, "the re-latched handle is the reported one")
    }

    // Another field, an unlabeled one (nothing says it is the same) or another
    // window behind the dead handle is a focus change.
    func testARelatchOntoAnotherFieldIsAFocusChange() async {
        tracker.follow(app.element, observer: nil)
        await settle()
        app.dead = [message]
        app.focused = search
        XCTAssertTrue(tracker.relatchIfDead(message))
        XCTAssertEqual(tracker.focusedTextElement, search)
        await settle()
        XCTAssertEqual(reports, 2, "another field")

        app.fields = [(search, "Search"), (remounted, nil)]
        app.dead = [search]
        app.focused = remounted
        XCTAssertTrue(tracker.relatchIfDead(search))
        await settle()
        XCTAssertEqual(reports, 3, "unlabeled")

        app.fields = [(remounted, "Search"), (message, "Search")]
        focusNotification()
        await settle()
        XCTAssertEqual(reports, 4)
        app.dead = [remounted]
        app.focused = message
        app.title = "Another chat"
        XCTAssertTrue(tracker.relatchIfDead(remounted))
        await settle()
        XCTAssertEqual(reports, 5, "another window")
    }

    // A field with no label, replaced by another with none: nothing says it
    // is the same field, so it is a focus change — never a quiet swap.
    func testAnUnlabeledFieldReplacedIsAFocusChange() async {
        app.fields = [(message, nil), (remounted, nil)]
        tracker.follow(app.element, observer: nil)
        await settle()
        app.dead = [message]
        app.focused = remounted
        XCTAssertTrue(tracker.relatchIfDead(message))
        await settle()
        XCTAssertEqual(reports, 2)
    }

    // MARK: - Observer registrations

    private let window = AXUIElementCreateApplication(90_101)
    private let otherWindow = AXUIElementCreateApplication(90_102)
    private let text: Set<String> = [kAXValueChangedNotification, kAXSelectedTextChangedNotification]
    private let frame: Set<String> = [kAXWindowMovedNotification, kAXWindowResizedNotification]

    /// An observer of this process: what it registers goes to `app`.
    private func observer() throws -> AXObserver {
        var created: AXObserver?
        XCTAssertEqual(AXObserverCreate(getpid(), { _, _, _, _ in }, &created), .success)
        return try XCTUnwrap(created)
    }

    // Followed, the app reports focus changes, the focused field its text
    // and selection, its window moves and resizes.
    func testFollowingRegistersTheFieldAndItsWindow() throws {
        tracker.follow(app.element, observer: try observer())
        XCTAssertEqual(app.registered, [app.element: [kAXFocusedUIElementChangedNotification],
                                        message: text, window: frame])
    }

    // Focus moving between the window's fields re-registers the field only;
    // a field in another window, the window too; nothing editable, nothing.
    func testRegistrationsFollowTheFocus() throws {
        tracker.follow(app.element, observer: try observer())
        let base = app.registrations
        app.focused = search
        focusNotification()
        XCTAssertEqual(app.registered[message], nil)
        XCTAssertEqual(app.registered[search], text)
        XCTAssertEqual(app.registered[window], frame)
        XCTAssertEqual(app.registrations, base + 2, "the window is not re-registered")

        app.window = otherWindow
        focusNotification()
        XCTAssertEqual(app.registered[window], nil)
        XCTAssertEqual(app.registered[otherWindow], frame)

        app.focused = AXUIElementCreateApplication(90_009)   // not a field
        focusNotification()
        XCTAssertNil(tracker.focusedTextElement)
        XCTAssertEqual(app.registered[search], nil)
        XCTAssertEqual(Set(app.registered.keys), [app.element, otherWindow])

        app.window = nil
        focusNotification()
        XCTAssertEqual(Set(app.registered.keys), [app.element])
    }

    // A quiet re-latch moves the field's registrations to the new node.
    func testARelatchMovesTheFieldsRegistrations() async throws {
        tracker.follow(app.element, observer: try observer())
        await settle()
        app.dead = [message]
        app.focused = remounted
        XCTAssertTrue(tracker.relatchIfDead(message))
        XCTAssertEqual(app.registered[message], nil)
        XCTAssertEqual(app.registered[remounted], text)
    }

    // A tracker let go unregisters everything it registered.
    func testATrackerLetGoUnregistersEverything() async throws {
        tracker.follow(app.element, observer: try observer())
        await settle()   // the focus report holds the tracker until it runs
        tracker = FocusTracker()
        XCTAssertEqual(app.registered, [:])
    }

    // Without an observer (a test following by hand) nothing is registered.
    func testNoObserverRegistersNothing() {
        tracker.follow(app.element, observer: nil)
        XCTAssertEqual(app.registered, [:])
        XCTAssertEqual(tracker.focusedTextElement, message)
    }

    // The tracked field's own changes, and only its, reach the pipeline; a
    // window move or resize says the overlay was placed for another frame.
    func testNotificationsReachThePipeline() async {
        var changes: [Bool] = [], viewports = 0
        tracker.onTextChange = { changes.append($0) }
        tracker.onViewportChange = { viewports += 1 }
        tracker.follow(app.element, observer: nil)
        tracker.handleNotification(kAXValueChangedNotification, element: message)
        tracker.handleNotification(kAXSelectedTextChangedNotification, element: message)
        tracker.handleNotification(kAXValueChangedNotification, element: search)
        tracker.handleNotification(kAXWindowMovedNotification, element: window)
        tracker.handleNotification(kAXWindowResizedNotification, element: window)
        tracker.handleNotification(kAXTitleChangedNotification, element: window)
        await settle()
        XCTAssertEqual(changes, [true, false])
        XCTAssertEqual(viewports, 2)
    }

    // A dead handle with nothing focused after it: the field is gone, and
    // that is a focus change.
    func testADeadHandleWithNothingFocusedIsAFocusChange() async {
        tracker.follow(app.element, observer: nil)
        await settle()
        app.dead = [message]
        app.focused = nil
        XCTAssertTrue(tracker.relatchIfDead(message))
        XCTAssertNil(tracker.focusedTextElement)
        await settle()
        XCTAssertEqual(reports, 2)
    }

    func testALiveHandleIsLeftAlone() async {
        tracker.follow(app.element, observer: nil)
        await settle()
        app.focused = search
        XCTAssertFalse(tracker.relatchIfDead(message))
        XCTAssertEqual(tracker.focusedTextElement, message)
        await settle()
        XCTAssertEqual(reports, 1)
    }
}
