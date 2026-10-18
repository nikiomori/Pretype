import ApplicationServices
import XCTest
@testable import Pretype

/// The pipeline's field rules on their own: what a read, a result, a key, an
/// injection and a decline do to the cache, the ghost, the settle window, the
/// liveness probe and ⌘Z.
final class FieldStateTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private let first = AXUIElementCreateApplication(90_001)
    private let second = AXUIElementCreateApplication(90_002)

    private enum Verdict: Equatable {
        case taken(String)
        case retry
        case lost
    }

    private func read(_ before: String, _ after: String = "") -> TextContext {
        TextContext(textBeforeCaret: before, textAfterCaret: after, caretRect: nil, host: HostTextStyle())
    }

    private func admit(_ field: inout FieldState, _ context: TextContext?, at time: TimeInterval,
                       of element: AXUIElement? = nil) -> Verdict {
        switch field.admit(context, of: element ?? first, probe: nil, clock: { self.t0.addingTimeInterval(time) }) {
        case .taken(let taken): return .taken(taken.textBeforeCaret)
        case .retry: return .retry
        case .lost: return .lost
        }
    }

    // Inside the window the cache outranks a read that disagrees with it; the
    // first read that agrees, or any read past the deadline, ends it.
    func testSettleWindowTrustsTheCacheOverATrailingRead() {
        var field = FieldState()
        XCTAssertEqual(field.injected("there", deleting: "", over: "Hi ", at: t0), "Hi there")
        XCTAssertTrue(field.isSettling(at: t0.addingTimeInterval(0.1)))
        XCTAssertEqual(admit(&field, read("Hi "), at: 0.1), .retry, "trails the keys")
        XCTAssertEqual(field.cache, "Hi there")
        XCTAssertEqual(admit(&field, read("Hi there"), at: 0.2), .taken("Hi there"))
        XCTAssertFalse(field.isSettling(at: t0.addingTimeInterval(0.2)), "an agreeing read ends it")

        _ = field.injected("!", deleting: "", over: "Hi there", at: t0)
        XCTAssertEqual(admit(&field, read("Hi"), at: 0.31), .taken("Hi"), "the deadline bounds the wait")
        XCTAssertEqual(field.cache, "Hi")
    }

    // A result lands on the context it was asked for while the cache says
    // nothing was typed since; otherwise on a fresh read — unless an edit is
    // settling or the read trails a key the tap saw.
    func testResultAnchor() {
        func anchor(_ field: FieldState, cached: String?, fresh: String?, at time: TimeInterval = 1) -> String {
            var reads = 0
            let anchored = field.anchor(cached: cached.map { read($0) },
                                        read: { reads += 1; return fresh.map { self.read($0) } },
                                        at: t0.addingTimeInterval(time))
            switch anchored {
            case .context(let context): return "\(context.textBeforeCaret) after \(reads) read(s)"
            case .settling: return "settling"
            case .trailing: return "trailing"
            case .unreadable: return "unreadable"
            }
        }
        var field = FieldState()
        field.cache = "hell"
        XCTAssertEqual(anchor(field, cached: "hell", fresh: "x"), "hell after 0 read(s)")
        XCTAssertEqual(anchor(field, cached: "hel", fresh: "hell"), "hell after 1 read(s)")
        XCTAssertEqual(anchor(field, cached: "hel", fresh: "hel"), "trailing")
        XCTAssertEqual(anchor(field, cached: "hel", fresh: "help"), "help after 1 read(s)")
        XCTAssertEqual(anchor(field, cached: nil, fresh: nil), "unreadable")
        _ = field.injected("o", deleting: "", over: "hell", at: t0)
        XCTAssertEqual(anchor(field, cached: "hello", fresh: "hello", at: 0.1), "settling")
    }

    func testKeystrokesMoveTheCacheAndTheGhostTogether() {
        var field = FieldState()
        field.cache = "Hi t"
        field.offer("here you", before: "Hi t", after: "", fresh: true, trimToLine: true, instant: false)
        XCTAssertEqual(field.keystroke("h", chord: false), .narrowed("ere you"))
        XCTAssertEqual(field.cache, "Hi th")
        XCTAssertEqual(field.ghost?.anchor, "Hi th")
        XCTAssertNil(field.keystroke("", chord: false), "a dead key changes nothing")
        XCTAssertEqual(field.cache, "Hi th")
        // A backspace can't be replayed onto either: the cache goes unknown,
        // and the ghost is left for the caller to retire.
        XCTAssertEqual(field.keystroke("\u{7F}", chord: false), .retired(.abandoned))
        XCTAssertNil(field.cache)
        XCTAssertNotNil(field.ghost)

        field.ghost = nil
        field.cache = "Hi"
        XCTAssertNil(field.keystroke("!", chord: false), "no ghost, but the cache still follows")
        XCTAssertEqual(field.cache, "Hi!")
        XCTAssertNil(field.keystroke("v", chord: true), "⌘V can rewrite the field")
        XCTAssertNil(field.cache)
    }

    // ⇥ advances the ghost past what it typed; the flag that books one accept
    // per suggestion survives streamed growth, and only a fresh offer resets it.
    func testAcceptAdvancesTheGhostAndCountsItOnce() {
        var field = FieldState()
        field.offer("there you", before: "Hi ", after: "", fresh: true, trimToLine: true, instant: false)
        XCTAssertEqual(field.advanceGhost(past: "there"), " you")
        XCTAssertEqual(field.ghost?.anchor, "Hi there")
        XCTAssertEqual(field.ghost?.accepted, true)
        field.offer(" you are", before: "Hi there", after: "", fresh: false, trimToLine: true, instant: false)
        XCTAssertEqual(field.ghost?.accepted, true, "streamed growth of the same offer")
        XCTAssertNil(field.advanceGhost(past: " you are"), "all of it: the caller retires it")
        XCTAssertEqual(field.ghost?.text, " you are")
        field.offer("again", before: "Hi there", after: "", fresh: true, trimToLine: true, instant: false)
        XCTAssertEqual(field.ghost?.accepted, false)
    }

    func testDeclineLastsUntilTheFieldChanges() {
        var field = FieldState()
        field.decline(before: "Hi ", after: "!")
        XCTAssertEqual(admit(&field, read("Hi ", "!"), at: 0), .taken("Hi "))
        XCTAssertTrue(field.isDeclined, "a notification that leaves the text alone")
        XCTAssertEqual(admit(&field, read("Hi "), at: 0), .taken("Hi "))
        XCTAssertFalse(field.isDeclined, "the text after the caret changed")
        field.decline(before: "Hi ", after: "")
        field.focusMoved()
        XCTAssertFalse(field.isDeclined)
    }

    func testUndoIsOfferedOnlyWhileTheFieldReadsAsTyped() {
        var field = FieldState()
        let snapshot = field.injected("there", deleting: "", over: "Hi ", at: t0)
        field.typed("there", snapshot: snapshot, dictated: false)
        XCTAssertEqual(field.pendingUndo?.chunk, "there")
        _ = field.keystroke("!", chord: false)
        XCTAssertNil(field.pendingUndo, "the field moved on")
        XCTAssertNotNil(field.undoable)

        field.typed("x", snapshot: "Hi there!x", dictated: true)
        field.sent()
        XCTAssertNil(field.undoable, "Return sent it: nothing for ⌘Z")
        XCTAssertNil(field.cache)
    }

    // MARK: - The liveness probe

    /// A nil read of `element` at `time`, with a probe that takes `takes`
    /// seconds and finds the handle `dead`.
    private struct Prober {
        let t0: Date
        var field = FieldState()
        var now: TimeInterval = 0
        var probes: [AXUIElement] = []

        mutating func nilRead(of element: AXUIElement, takes: TimeInterval = 0.001, dead: Bool = false) -> Verdict {
            let start = t0
            var clock = now, probed = probes
            let admission = field.admit(nil, of: element,
                                        probe: { probed.append(element); clock += takes; return dead },
                                        clock: { start.addingTimeInterval(clock) })
            now = clock
            probes = probed
            if case .retry = admission { return .retry }
            return .lost
        }

        mutating func answers(_ text: String) {
            let start = t0
            let clock = now
            _ = field.admit(TextContext(textBeforeCaret: text, textAfterCaret: "", caretRect: nil, host: HostTextStyle()),
                            of: AXUIElementCreateApplication(90_001), probe: nil,
                            clock: { start.addingTimeInterval(clock) })
        }
    }

    // A responsive app: once a second per handle while its reads fail, at once
    // for another handle, and at once again after a read it answered — the
    // node replaced right after a legitimate nil read (an IME composition).
    func testProbeThrottleIsPerHandleAndReArmedByAFastApp() {
        var prober = Prober(t0: t0)
        XCTAssertEqual(prober.nilRead(of: first), .lost)
        prober.now = 0.5
        XCTAssertEqual(prober.nilRead(of: first), .lost)
        XCTAssertEqual(prober.probes, [first], "once a second")
        XCTAssertEqual(prober.nilRead(of: second), .lost)
        XCTAssertEqual(prober.probes, [first, second], "another handle at once")

        prober.answers("Hi")
        prober.now = 0.6
        XCTAssertEqual(prober.nilRead(of: second, dead: true), .retry, "dead: read again")
        XCTAssertEqual(prober.probes, [first, second, second], "it answered since")
        prober.now = 1.5
        XCTAssertEqual(prober.nilRead(of: second), .lost)
        XCTAssertEqual(prober.probes.count, 3, "within the second")
        prober.now = 1.7
        XCTAssertEqual(prober.nilRead(of: second), .lost)
        XCTAssertEqual(prober.probes.count, 4, "a second later")
    }

    // An app whose reads time out — or alternate with reads it answers —
    // answers its probes slowly, and pays at most one a second.
    func testASlowAppProbesAtMostOnceASecond() {
        var prober = Prober(t0: t0)
        let slow = FieldState.fastProbe * 2
        XCTAssertEqual(prober.nilRead(of: first, takes: slow), .lost)
        prober.answers("Hi")
        prober.now = 0.5
        XCTAssertEqual(prober.nilRead(of: first, takes: slow), .lost)
        prober.answers("Hi")
        prober.now = 0.9
        XCTAssertEqual(prober.nilRead(of: first, takes: slow), .lost)
        XCTAssertEqual(prober.probes, [first])
        prober.now = 1.1
        XCTAssertEqual(prober.nilRead(of: first, takes: slow), .lost)
        XCTAssertEqual(prober.probes, [first, first])
    }

    // A read shorter than the cache trails it only when it is the cache's
    // head; any other text is the field as it is now (rewritten from under
    // the cache — select-all and type).
    func testOnlyAHeadOfTheCacheTrailsIt() {
        var field = FieldState()
        field.adoptRead("Hi there")
        let now = Date()
        let head = TextContext(textBeforeCaret: "Hi the", textAfterCaret: "", caretRect: nil, host: HostTextStyle())
        guard case .trailing = field.anchor(cached: nil, read: { head }, at: now) else { return XCTFail("a head trails") }
        let other = TextContext(textBeforeCaret: "x", textAfterCaret: "", caretRect: nil, host: HostTextStyle())
        guard case .context(let ctx) = field.anchor(cached: nil, read: { other }, at: now) else { return XCTFail("other text is the field") }
        XCTAssertEqual(ctx.textBeforeCaret, "x")
    }

    // The caret: noted by a read with its style, by a side flow alone,
    // recovered only once forgotten, and forgotten — with the text before
    // it — by a scroll under work in flight.
    func testTheCaretIsNotedRecoveredAndForgotten() {
        var field = FieldState()
        let caret = CGRect(x: 10, y: 10, width: 1, height: 16), moved = CGRect(x: 40, y: 10, width: 1, height: 16)
        var style = HostTextStyle()
        style.textFollowsCaret = true
        field.noteCaret(caret, style: style)
        XCTAssertEqual(field.caret, caret)
        XCTAssertEqual(field.style, style)
        field.noteCaret(moved)
        XCTAssertEqual(field.caret, moved)
        XCTAssertEqual(field.style, style, "a side flow measures the caret alone")
        field.recoverCaret(caret)
        XCTAssertEqual(field.caret, moved, "a known caret is kept")
        field.adoptRead("Hi")
        field.forgetCaret()
        XCTAssertNil(field.caret)
        XCTAssertNil(field.cache)
        field.recoverCaret(caret)
        XCTAssertEqual(field.caret, caret)
    }

    // A field the tracker missed has its site read once, and only when the
    // tracker read none; another field is read anew.
    func testAnUntrackedFieldsSiteIsReadOnce() {
        var field = FieldState()
        var reads = 0
        func host(_: AXUIElement) -> String? {
            reads += 1
            return "mail.example.com"
        }
        XCTAssertEqual(field.foundUntracked(first, trackerSite: nil, pageHost: host), first)
        XCTAssertEqual(field.untracked?.site, "mail.example.com")
        _ = field.foundUntracked(first, trackerSite: nil, pageHost: host)
        XCTAssertEqual(reads, 1)
        _ = field.foundUntracked(second, trackerSite: "chat.example.com", pageHost: host)
        XCTAssertEqual(reads, 1, "the tracker's site stands")
        XCTAssertNil(field.untracked?.site)
        XCTAssertEqual(field.untracked?.element, second)
    }

    // The focus moved: everything known about the field just left goes.
    func testAFocusMoveForgetsTheField() {
        var field = FieldState()
        var style = HostTextStyle()
        style.textFollowsCaret = true
        field.noteCaret(CGRect(x: 10, y: 10, width: 1, height: 16), style: style)
        _ = field.foundUntracked(first, trackerSite: nil) { _ in "mail.example.com" }
        _ = field.injected("there", deleting: "", over: "Hi ", at: t0)
        field.decline(before: "Hi there", after: "")
        field.focusMoved()
        XCTAssertNil(field.caret)
        XCTAssertEqual(field.style, HostTextStyle())
        XCTAssertNil(field.untracked?.element)
        XCTAssertNil(field.cache)
        XCTAssertFalse(field.isSettling(at: t0))
        XCTAssertFalse(field.isDeclined)
    }

    // MARK: - Boundaries

    // The settle window is 0.3 s from the edit, the probe throttle a second
    // per handle, and a probe answered in half the AX timeout is fast.
    func testTheWindowsEdges() {
        var field = FieldState()
        _ = field.injected("x", deleting: "", over: "Hi", at: t0)
        XCTAssertTrue(field.isSettling(at: t0.addingTimeInterval(0.299)))
        XCTAssertFalse(field.isSettling(at: t0.addingTimeInterval(0.3)))

        var prober = Prober(t0: t0)
        _ = prober.nilRead(of: first, takes: FieldState.fastProbe)
        prober.answers("Hi")
        prober.now = 0.5
        _ = prober.nilRead(of: first)
        XCTAssertEqual(prober.probes.count, 1, "a probe that took half the timeout was slow")
        prober.now = 1
        _ = prober.nilRead(of: first)
        XCTAssertEqual(prober.probes.count, 1, "exactly a second after the probe began")
        prober.now = 1.01
        _ = prober.nilRead(of: first)
        XCTAssertEqual(prober.probes.count, 2)
        XCTAssertEqual(FieldState.fastProbe, 0.05, accuracy: 0.0001)
    }

    // Control input: C0 controls, DEL, and the private-use function keys —
    // nothing either side of them.
    func testWhatIsControlInput() {
        for control in ["\u{0}", "\u{8}", "\u{1F}", "\u{7F}", "\u{F700}", "\u{F728}", "\u{F8FF}", "a\u{1B}"] {
            XCTAssertTrue(FieldState.isControlInput(control), control.unicodeScalars.map { "\($0.value)" }.joined())
        }
        for text in [" ", "~", "\u{80}", "\u{F6FF}", "\u{F900}", "é", "😀", ""] {
            XCTAssertFalse(FieldState.isControlInput(text), text)
        }
    }

    // A ghost's whole text typed exactly is typed through, not narrowed to
    // nothing; one character short narrows it to the last.
    func testTypingAGhostsWholeText() {
        XCTAssertEqual(FieldState.ghostUpdate(anchor: "Hi ", remaining: "to", text: "Hi to"), .retired(.typedThrough))
        XCTAssertEqual(FieldState.ghostUpdate(anchor: "Hi ", remaining: "to", text: "Hi t"), .narrowed("o"))
        XCTAssertEqual(FieldState.ghostUpdate(anchor: "Hi ", remaining: "to", text: "Hi "), .unchanged)
        XCTAssertEqual(FieldState.ghostUpdate(anchor: "Hi ", remaining: "to", text: "Hi tox"), .retired(.typedThrough))
        XCTAssertEqual(FieldState.ghostUpdate(anchor: "Hi ", remaining: "to", text: "Hi x"), .retired(.diverged))
        XCTAssertEqual(FieldState.ghostUpdate(anchor: "Hi ", remaining: "to", text: "H"), .retired(.abandoned))
    }

    // What an injection leaves, and what it presses: only the tails past the
    // shared head.
    func testWhatAnInjectionPressesAndLeaves() {
        XCTAssertEqual(FieldState.textAfterInjection("the", deleting: "teh", over: "I saw teh"), "I saw the")
        XCTAssertNil(FieldState.textAfterInjection("the", deleting: "teh", over: "I saw tea"), "not what it deletes")
        XCTAssertNil(FieldState.textAfterInjection("the", deleting: "", over: nil))
        XCTAssertTrue(FieldState.keystrokes(replacing: "12*7=", with: "12*7=84") == ("", "84"))
        XCTAssertTrue(FieldState.keystrokes(replacing: "teh", with: "the") == ("eh", "he"))
        XCTAssertTrue(FieldState.keystrokes(replacing: "", with: "hi") == ("", "hi"))
        XCTAssertTrue(FieldState.keystrokes(replacing: "abc", with: "abc") == ("", ""))
    }
}
