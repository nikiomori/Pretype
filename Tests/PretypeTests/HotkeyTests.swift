import CoreGraphics
import XCTest
@testable import Pretype

final class HotkeyTests: XCTestCase {
    // The hotkey matchers gate every text injection; lock their modifier rules.
    func testHotkeyMatchers() {
        let tab = KeyCode.tab
        let space = KeyCode.space

        // Tab style: bare Tab = accept word, ⇧Tab = accept all, ⌥Tab = correction.
        XCTAssertTrue(HotkeyStyle.tab.matchesAcceptWord(keyCode: tab, flags: []))
        XCTAssertFalse(HotkeyStyle.tab.matchesAcceptWord(keyCode: tab, flags: [.maskShift]))
        XCTAssertTrue(HotkeyStyle.tab.matchesAcceptAll(keyCode: tab, flags: [.maskShift]))
        XCTAssertTrue(HotkeyStyle.tab.matchesCorrection(keyCode: tab, flags: [.maskAlternate]))
        // A different key never matches.
        XCTAssertFalse(HotkeyStyle.tab.matchesAcceptWord(keyCode: space, flags: []))
        // Caps Lock is outside the modifier mask, so it doesn't break bare Tab.
        XCTAssertTrue(HotkeyStyle.tab.matchesAcceptWord(keyCode: tab, flags: [.maskAlphaShift]))

        // ⌘Space style.
        XCTAssertTrue(HotkeyStyle.cmdSpace.matchesAcceptWord(keyCode: space, flags: [.maskCommand]))
        XCTAssertFalse(HotkeyStyle.cmdSpace.matchesAcceptWord(keyCode: space, flags: []))
        XCTAssertTrue(HotkeyStyle.cmdSpace.matchesAcceptAll(keyCode: space, flags: [.maskCommand, .maskShift]))

        // Documented quirk: ⌘Space and ⌥Space share the ⌥⌘Space correction chord
        // (there is no "Opt+Opt"), so both match the same flags.
        XCTAssertTrue(HotkeyStyle.cmdSpace.matchesCorrection(keyCode: space, flags: [.maskCommand, .maskAlternate]))
        XCTAssertTrue(HotkeyStyle.optSpace.matchesCorrection(keyCode: space, flags: [.maskCommand, .maskAlternate]))
    }

    // The tap matches the hands-free latch before the fix chord, so a latch
    // chord equal to a fix chord would silently eat the fix.
    func testLatchChordNeverEqualsFixChord() {
        let flags: CGEventFlags = [.maskControl, .maskAlternate]
        for latch in DictationLatch.allCases where latch != .off {
            let codes = (Int64(0)..<128).filter { latch.matches(keyCode: $0, flags: flags) }
            XCTAssertEqual(codes.count, 1, latch.label)
            for style in HotkeyStyle.allCases {
                XCTAssertFalse(codes.contains { style.matchesCorrection(keyCode: $0, flags: flags) },
                               "\(latch.label) vs \(style.label)")
            }
        }
    }

    // ⌘Z undo-accept must be an EXACT chord: ⇧⌘Z (redo) and ⌥⌘Z belong to the
    // app — matching them swallowed the app's redo and deleted text.
    func testPlainCommandZMatcher() {
        let z = KeyCode.z
        // QWERTY: ANSI Z produces "z".
        XCTAssertTrue(SuggestionController.isPlainCommandZ(keyCode: z, key: "z", flags: [.maskCommand]))
        // ЙЦУКЕН/Greek: no Latin letter produced → the physical ANSI key decides.
        XCTAssertTrue(SuggestionController.isPlainCommandZ(keyCode: z, key: "я", flags: [.maskCommand]))
        XCTAssertTrue(SuggestionController.isPlainCommandZ(keyCode: z, key: nil, flags: [.maskCommand]))
        // QWERTZ/AZERTY: the produced Latin letter decides, wherever Z sits.
        XCTAssertTrue(SuggestionController.isPlainCommandZ(keyCode: 16, key: "z", flags: [.maskCommand]))
        XCTAssertFalse(SuggestionController.isPlainCommandZ(keyCode: z, key: "y", flags: [.maskCommand]))
        // Extra chord modifiers belong to the app (⇧⌘Z redo, ⌥⌘Z, ⌃⌘Z).
        XCTAssertFalse(SuggestionController.isPlainCommandZ(keyCode: z, key: "z", flags: [.maskCommand, .maskShift]))
        XCTAssertFalse(SuggestionController.isPlainCommandZ(keyCode: z, key: "z", flags: [.maskCommand, .maskAlternate]))
        XCTAssertFalse(SuggestionController.isPlainCommandZ(keyCode: z, key: "z", flags: [.maskCommand, .maskControl]))
        XCTAssertFalse(SuggestionController.isPlainCommandZ(keyCode: z, key: "z", flags: []))
        // More than one character produced (a dead-key sequence) is no Latin
        // letter either: the physical key decides.
        XCTAssertTrue(SuggestionController.isPlainCommandZ(keyCode: z, key: "ab", flags: [.maskCommand]))
        XCTAssertFalse(SuggestionController.isPlainCommandZ(keyCode: 16, key: "zz", flags: [.maskCommand]))
        // Caps Lock is outside the modifier mask, so it doesn't break ⌘Z.
        XCTAssertTrue(SuggestionController.isPlainCommandZ(keyCode: z, key: "z", flags: [.maskCommand, .maskAlphaShift]))
    }

    // The double-tap gesture fires an LLM run on whatever is on screen, so it must
    // fire on exactly the gesture and on nothing else the hand does routinely.
    // The double tap's edges: a tap is held under 0.4 s, the second comes
    // under 0.45 s after the first; another modifier between them, or fn
    // held with it, makes it a chord — caps lock doesn't.
    func testModifierDoubleTapEdges() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)   // exact sums at the edges
        func taps(_ times: [(down: TimeInterval, up: TimeInterval)], flags: CGEventFlags = .maskAlternate,
                  between: (inout ModifierDoubleTap) -> Void = { _ in }) -> Bool {
            var gesture = ModifierDoubleTap()
            var fired = false
            for (n, tap) in times.enumerated() {
                if n == 1 { between(&gesture) }
                _ = gesture.modifierChanged(keyCode: KeyCode.leftOption, flags: flags, gesture: .option,
                                            now: t0.addingTimeInterval(tap.down))
                fired = gesture.modifierChanged(keyCode: KeyCode.leftOption, flags: [], gesture: .option,
                                                now: t0.addingTimeInterval(tap.up))
            }
            return fired
        }
        XCTAssertTrue(taps([(0, 0.399), (0.4, 0.44)]))
        XCTAssertFalse(taps([(0, 0.4), (0.5, 0.6)]), "held 0.4 s")
        XCTAssertFalse(taps([(0, 0.1), (0.2, 0.6)]), "the second held 0.4 s")
        XCTAssertTrue(taps([(0, 0.1), (0.3, 0.549)]))
        XCTAssertFalse(taps([(0, 0.1), (0.3, 0.55)]), "0.45 s apart")
        XCTAssertFalse(taps([(0, 0.1), (0.2, 0.3)], flags: [.maskAlternate, .maskSecondaryFn]))
        XCTAssertTrue(taps([(0, 0.1), (0.2, 0.3)], flags: [.maskAlternate, .maskAlphaShift]))
        var joined = ModifierDoubleTap()
        let option = { (flags: CGEventFlags, at: TimeInterval) in
            joined.modifierChanged(keyCode: KeyCode.leftOption, flags: flags, gesture: .option,
                                   now: t0.addingTimeInterval(at))
        }
        _ = option(.maskAlternate, 0)
        _ = joined.modifierChanged(keyCode: KeyCode.leftShift, flags: [.maskAlternate, .maskShift], gesture: .option,
                                   now: t0.addingTimeInterval(0.02))
        _ = option([], 0.05)
        _ = option(.maskAlternate, 0.1)
        XCTAssertFalse(option([], 0.15), "a modifier joining mid-press makes it a chord")
        var later = ModifierDoubleTap()
        func at(_ dt: TimeInterval, _ flags: CGEventFlags) -> Bool {
            later.modifierChanged(keyCode: KeyCode.leftOption, flags: flags, gesture: .option, now: t0.addingTimeInterval(dt))
        }
        _ = at(0, .maskAlternate)
        later.keyPressed()
        _ = at(0.05, [])
        _ = at(1, .maskAlternate)
        _ = at(1.05, [])
        _ = at(1.1, .maskAlternate)
        XCTAssertTrue(at(1.15, []), "a chord spoils its own press only")
        var echo = ModifierDoubleTap()
        _ = echo.modifierChanged(keyCode: KeyCode.leftOption, flags: .maskAlternate, gesture: .option, now: t0)
        _ = echo.modifierChanged(keyCode: KeyCode.leftOption, flags: [], gesture: .option, now: t0.addingTimeInterval(0.05))
        XCTAssertFalse(echo.modifierChanged(keyCode: KeyCode.leftOption, flags: [], gesture: .option,
                                            now: t0.addingTimeInterval(0.1)), "a second release is no second tap")
        XCTAssertFalse(taps([(0, 0.05), (0.1, 0.15), (0.2, 0.25)]) { gesture in gesture.keyPressed() },
                       "a chord between two taps starts the pair over")
        XCTAssertFalse(taps([(0, 0.1), (0.2, 0.3)]) { gesture in
            _ = gesture.modifierChanged(keyCode: KeyCode.leftShift, flags: .maskShift, gesture: .option,
                                        now: t0.addingTimeInterval(0.15))
        }, "another modifier between the taps")
    }

    func testModifierDoubleTap() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        func at(_ dt: TimeInterval) -> Date { t0.addingTimeInterval(dt) }
        var gesture = ModifierDoubleTap()
        func down(_ dt: TimeInterval, _ flags: CGEventFlags = [.maskAlternate]) -> Bool {
            gesture.modifierChanged(keyCode: KeyCode.leftOption, flags: flags,
                                    gesture: .option, now: at(dt))
        }
        func up(_ dt: TimeInterval) -> Bool {
            gesture.modifierChanged(keyCode: KeyCode.leftOption, flags: [],
                                    gesture: .option, now: at(dt))
        }

        // Two clean taps in quick succession — the gesture.
        XCTAssertFalse(down(0))
        XCTAssertFalse(up(0.08))
        XCTAssertFalse(down(0.2))
        XCTAssertTrue(up(0.28))
        // …and it does not re-fire on the next release without a fresh pair.
        XCTAssertFalse(down(0.4))
        XCTAssertFalse(up(0.45))

        // A ⌥-chord (⌥E for an accent, ⌥← to jump a word) is not a tap.
        gesture = ModifierDoubleTap()
        XCTAssertFalse(down(0))
        gesture.keyPressed()
        XCTAssertFalse(up(0.08))
        XCTAssertFalse(down(0.2))
        XCTAssertFalse(up(0.28))

        // Held ⌥ (menu alternates) is not a tap either.
        gesture = ModifierDoubleTap()
        XCTAssertFalse(down(0))
        XCTAssertFalse(up(0.9))
        XCTAssertFalse(down(1.0))
        XCTAssertFalse(up(1.05))

        // Two taps too far apart, and ⌥ pressed as part of ⌘⌥.
        gesture = ModifierDoubleTap()
        XCTAssertFalse(down(0))
        XCTAssertFalse(up(0.08))
        XCTAssertFalse(down(1.0))
        XCTAssertFalse(up(1.05))
        gesture = ModifierDoubleTap()
        XCTAssertFalse(down(0, [.maskAlternate, .maskCommand]))
        XCTAssertFalse(up(0.08))
        XCTAssertFalse(down(0.2, [.maskAlternate, .maskCommand]))
        XCTAssertFalse(up(0.28))

        // The user's choice is honoured: the same clean double tap fires for the
        // selected modifier only, and never when the gesture is off.
        for (selected, code, mask) in [
            (ReplyGesture.shift, KeyCode.leftShift, CGEventFlags.maskShift),
            (.control, KeyCode.rightControl, .maskControl),
            (.command, KeyCode.leftCommand, .maskCommand),
        ] {
            var picked = ModifierDoubleTap()
            var wrong = ModifierDoubleTap()
            var off = ModifierDoubleTap()
            for (dt, flags) in [(0.0, mask), (0.08, []), (0.2, mask), (0.28, [])] {
                let fire = picked.modifierChanged(keyCode: code, flags: flags,
                                                  gesture: selected, now: at(dt))
                XCTAssertEqual(fire, dt == 0.28, "\(selected.label) at \(dt)")
                XCTAssertFalse(wrong.modifierChanged(keyCode: code, flags: flags,
                                                     gesture: .option, now: at(dt)))
                XCTAssertFalse(off.modifierChanged(keyCode: code, flags: flags,
                                                   gesture: .off, now: at(dt)))
            }
        }
    }

    // Hold-to-talk decides when Pretype opens the microphone, so every rule
    // about what is NOT a hold is pinned here: a brushed modifier, a chord, a
    // tap, the other side's key, and — the one that makes the two gestures able
    // to share a modifier — a double tap.
    func testModifierHold() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        func at(_ dt: TimeInterval) -> Date { t0.addingTimeInterval(dt) }
        var hold = ModifierHold()
        func down(_ dt: TimeInterval, _ code: Int64 = KeyCode.rightOption,
                  _ flags: CGEventFlags = [.maskAlternate]) -> ModifierHold.Event? {
            hold.modifierChanged(keyCode: code, flags: flags, gesture: .option, now: at(dt))
        }
        func up(_ dt: TimeInterval, _ code: Int64 = KeyCode.rightOption) -> ModifierHold.Event? {
            hold.modifierChanged(keyCode: code, flags: [], gesture: .option, now: at(dt))
        }

        // Hold past the threshold, then release: capture and use it.
        XCTAssertNil(down(0))
        XCTAssertTrue(hold.isArmed)
        XCTAssertNil(hold.tick(now: at(0.2)))       // too early to open the mic
        XCTAssertEqual(hold.tick(now: at(0.5)), .begin)
        XCTAssertTrue(hold.isActive)
        XCTAssertNil(hold.tick(now: at(0.9)))       // begin fires once, not per tick
        XCTAssertEqual(up(2.0), .end)
        XCTAssertFalse(hold.isActive)

        // A quick brush of the key never records anything.
        hold = ModifierHold()
        XCTAssertNil(down(0))
        XCTAssertNil(up(0.12))
        XCTAssertNil(hold.tick(now: at(0.6)))

        // A double tap — the reply gesture — is not a hold. The two share ⌥
        // precisely because neither can be mistaken for the other.
        hold = ModifierHold()
        for dt in [0.0, 0.08, 0.2, 0.28] {
            XCTAssertNil(dt == 0.0 || dt == 0.2 ? down(dt) : up(dt))
            XCTAssertNil(hold.tick(now: at(dt)))
        }

        // A key pressed during the hold makes it a chord: the capture is
        // cancelled, not used.
        hold = ModifierHold()
        XCTAssertNil(down(0))
        XCTAssertEqual(hold.tick(now: at(0.5)), .begin)
        XCTAssertEqual(hold.keyPressed(), .cancel)
        XCTAssertFalse(hold.isActive)
        XCTAssertNil(up(0.7))   // the release has nothing left to end

        // The same key pressed BEFORE the threshold has to disarm just as
        // firmly, and this is the case a caller is tempted to skip: there is no
        // capture yet, so nothing comes back to cancel. ⌥⌫ word-delete and
        // ⌥-arrow word navigation live entirely inside this window — the
        // modifier stays down across several presses — and a hold still armed
        // when the timer catches up opens the microphone mid-edit.
        hold = ModifierHold()
        XCTAssertNil(down(0))
        XCTAssertTrue(hold.isArmed)
        XCTAssertNil(hold.keyPressed())
        XCTAssertFalse(hold.isArmed)
        XCTAssertNil(hold.tick(now: at(0.5)))   // the timer finds nothing to start
        XCTAssertNil(up(0.9))

        // A click or a scroll inside that window says the same thing: a long
        // ⌥-drag or ⌃-zoom is a gesture, not a sentence.
        hold = ModifierHold()
        XCTAssertNil(down(0))
        XCTAssertNil(hold.interrupt())
        XCTAssertFalse(hold.isArmed)
        XCTAssertNil(hold.tick(now: at(0.5)))

        // Another modifier joining does the same…
        hold = ModifierHold()
        XCTAssertNil(down(0))
        XCTAssertEqual(hold.tick(now: at(0.5)), .begin)
        XCTAssertEqual(down(0.6, KeyCode.leftCommand, [.maskAlternate, .maskCommand]), .cancel)

        // …and so does starting from a chord: ⌥ pressed while ⌘ is already down
        // never arms at all.
        hold = ModifierHold()
        XCTAssertNil(down(0, KeyCode.rightOption, [.maskAlternate, .maskCommand]))
        XCTAssertFalse(hold.isArmed)
        XCTAssertNil(hold.tick(now: at(0.5)))

        // EITHER side fires. This shipped right-hand-only and the left key was
        // the one the first user reached for: no pill, no error, no log line —
        // a dead feature. The chord guards above are what keep the left key
        // usable, not a refusal to look at it.
        for code in [KeyCode.leftOption, KeyCode.rightOption] {
            hold = ModifierHold()
            XCTAssertNil(down(0, code))
            XCTAssertTrue(hold.isArmed, "keyCode \(code) must arm")
            XCTAssertEqual(hold.tick(now: at(0.5)), .begin)
            XCTAssertEqual(up(1.0, code), .end)
        }

        // Every gesture watches its own modifier — both keys of it — and `off`
        // watches none.
        for (gesture, codes) in [
            (DictationGesture.command, [KeyCode.leftCommand, KeyCode.rightCommand]),
            (.control, [KeyCode.leftControl, KeyCode.rightControl]),
        ] {
            let mask = gesture.keys!.mask
            for code in codes {
                var picked = ModifierHold()
                var off = ModifierHold()
                var other = ModifierHold()
                XCTAssertNil(picked.modifierChanged(keyCode: code, flags: mask,
                                                    gesture: gesture, now: at(0)))
                XCTAssertEqual(picked.tick(now: at(0.5)), .begin, "\(gesture.label) / \(code)")
                XCTAssertNil(off.modifierChanged(keyCode: code, flags: mask,
                                                 gesture: .off, now: at(0)))
                XCTAssertNil(off.tick(now: at(0.5)))
                // A different modifier's key must not arm this gesture.
                XCTAssertNil(other.modifierChanged(keyCode: code, flags: mask,
                                                   gesture: .option, now: at(0)))
                XCTAssertNil(other.tick(now: at(0.5)))
            }
        }
    }
}
