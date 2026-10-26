import CoreGraphics
import XCTest
@testable import Pretype

/// The key tap's gate for the pipeline — `SuggestionController.keyAction` —
/// row by row, then every combination of its inputs against each rule.
@MainActor
final class KeyGateTests: XCTestCase {
    private typealias C = SuggestionController

    private struct Key {
        let name: String
        let code: Int64
        let flags: CGEventFlags
        var isCommandZ = false
    }

    private let tab = Key(name: "⇥", code: KeyCode.tab, flags: [])
    private let shiftTab = Key(name: "⇧⇥", code: KeyCode.tab, flags: .maskShift)
    private let escape = Key(name: "⎋", code: KeyCode.escape, flags: [])
    private let commandZ = Key(name: "⌘Z", code: KeyCode.z, flags: .maskCommand, isCommandZ: true)
    private let redo = Key(name: "⇧⌘Z", code: KeyCode.z, flags: [.maskCommand, .maskShift])
    private let replyChord = Key(name: "⌥⇧⇥", code: KeyCode.tab, flags: [.maskAlternate, .maskShift])
    private let fixChord = Key(name: "⌥⇥", code: KeyCode.tab, flags: .maskAlternate)
    private let letter = Key(name: "a", code: 0, flags: [])
    private let ghost = FieldState.Ghost(anchor: "Hi ", after: "!", text: "to be")

    private func action(_ key: Key, canUndo: Bool = false, offHere: Bool = false, ghost: Bool = true,
                        onScreen: Bool = true, fix: CorrectionController.KeyOutcome = .ignored,
                        elsewhere: Bool = false, fixes: Bool = true, replies: Bool = true) -> C.KeyAction {
        let state = C.KeyState(keyCode: key.code, flags: key.flags, isCommandZ: key.isCommandZ,
                               canUndo: canUndo, offHere: offHere, ghost: ghost ? self.ghost : nil,
                               ghostOnScreen: onScreen, style: .tab, fixes: fixes, replies: replies)
        return C.keyAction(for: state, fix: { fix }, focusElsewhere: { elsewhere })
    }

    /// A feature turned off gives its chord back to the app, unasked — the
    /// fix flows are not even consulted — and leaves the others alone.
    func testChordsOfAFeatureTurnedOffAreTheAppsKeys() {
        XCTAssertEqual(action(replyChord, replies: false), .type)
        XCTAssertEqual(action(fixChord, fix: .consumed, fixes: false), .type)
        XCTAssertEqual(action(tab, fix: .consumed, fixes: false), .accept("to"))
        XCTAssertEqual(action(replyChord, fixes: false), .reply)
        XCTAssertEqual(action(fixChord, fix: .consumed, replies: false), .fix(swallowed: true))
    }

    func testRows() {
        XCTAssertEqual(action(tab), .accept("to"))
        XCTAssertEqual(action(shiftTab), .accept("to be"))
        XCTAssertEqual(action(escape), .decline(before: "Hi ", after: "!"))
        XCTAssertEqual(action(letter), .type)
        // A ghost a pill or notice covers is not the user's to accept or decline.
        XCTAssertEqual(action(tab, onScreen: false), .type)
        XCTAssertEqual(action(escape, onScreen: false), .type)
        XCTAssertEqual(action(tab, ghost: false), .type)
        // A launcher holding the keys gets its ⇥.
        XCTAssertEqual(action(tab, elsewhere: true), .type)
        // ⌘Z only while the record matches the field; redo is the app's.
        XCTAssertEqual(action(commandZ, canUndo: true), .undo)
        XCTAssertEqual(action(commandZ, canUndo: true, offHere: true), .undo)
        XCTAssertEqual(action(commandZ), .type)
        XCTAssertEqual(action(redo, canUndo: true), .type)
        // The chords, unless Pretype stays out of here.
        XCTAssertEqual(action(replyChord), .reply)
        XCTAssertEqual(action(replyChord, offHere: true), .type)
        XCTAssertEqual(action(fixChord, fix: .consumed), .fix(swallowed: true))
        XCTAssertEqual(action(fixChord, offHere: true, fix: .consumed), .type)
        // A fix preview outranks the ghost: ⇥ applies it, ⎋ keeps the original.
        XCTAssertEqual(action(tab, fix: .consumed), .fix(swallowed: true))
        XCTAssertEqual(action(escape, fix: .passThrough), .fix(swallowed: false))
    }

    func testEveryCombination() {
        let keys = [tab, shiftTab, escape, commandZ, redo, replyChord, fixChord, letter]
        let outcomes: [CorrectionController.KeyOutcome] = [.consumed, .passThrough, .ignored]
        let flags = [false, true]
        for key in keys {
            for canUndo in flags { for offHere in flags { for hasGhost in flags { for onScreen in flags {
                for outcome in outcomes { for elsewhere in flags {
                    var askedFix = false, askedFocus = false
                    let state = C.KeyState(keyCode: key.code, flags: key.flags, isCommandZ: key.isCommandZ,
                                           canUndo: canUndo, offHere: offHere, ghost: hasGhost ? ghost : nil,
                                           ghostOnScreen: onScreen, style: .tab)
                    let got = C.keyAction(for: state, fix: { askedFix = true; return outcome },
                                          focusElsewhere: { askedFocus = true; return elsewhere })
                    let row = "\(key.name) undo=\(canUndo) off=\(offHere) ghost=\(hasGhost) screen=\(onScreen) "
                        + "fix=\(outcome) elsewhere=\(elsewhere) → \(got)"

                    let undo = canUndo && key.isCommandZ
                    let reply = !undo && !offHere && key.name == replyChord.name
                    let fixAsked = !undo && !offHere && !reply
                    XCTAssertEqual(askedFix, fixAsked, row)
                    let fixTook = fixAsked && outcome != .ignored
                    let visible = hasGhost && onScreen
                    let acceptKey = key.name == tab.name || key.name == shiftTab.name
                    let early = undo || reply || fixTook
                    XCTAssertEqual(askedFocus, !early && visible && acceptKey, row)

                    switch got {
                    case .undo: XCTAssertTrue(undo, row)
                    case .reply: XCTAssertTrue(reply, row)
                    case .fix(let swallowed):
                        XCTAssertTrue(fixTook, row)
                        XCTAssertEqual(swallowed, outcome == .consumed, row)
                    case .accept(let chunk):
                        XCTAssertTrue(!early && visible && acceptKey && !elsewhere, row)
                        XCTAssertEqual(chunk, key.name == shiftTab.name ? "to be" : "to", row)
                    case .decline:
                        XCTAssertTrue(!early && visible && key.name == escape.name, row)
                    case .type:
                        XCTAssertFalse(early, row)
                        XCTAssertFalse(visible && (key.name == escape.name || acceptKey && !elsewhere), row)
                    }
                } }
            } } } }
        }
    }
}
