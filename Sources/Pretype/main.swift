import AppKit
import ApplicationServices

Settings.migrate()

MainActor.assumeIsolated {
    // Diagnostic: print what Accessibility exposes for the focused text field, to
    // debug caret positioning in tricky apps (Electron/Chromium, etc.):
    // `Pretype --ax-probe`. The fuller dev/eval harness lives outside the app
    // (see dev-tools/), since it depends on the engine and overlay internals.
    if CommandLine.arguments.contains("--ax-probe") {
        _ = NSApplication.shared
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            print("Not trusted yet — a system prompt was shown. Enable this binary in")
            print("System Settings → Privacy & Security → Accessibility, then run --ax-probe again.")
            exit(0)
        }
        print("Probing for 25s — click into a text field (e.g. Claude Desktop) and type a few chars…")
        let started = Date()
        Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { _ in
            Task { @MainActor in
                print("[probe] \(AXText.probeDescription())")
                if Date().timeIntervalSince(started) > 25 { exit(0) }
            }
        }
        RunLoop.main.run()
    }

    // Diagnostic: why holding the dictation key does nothing. Prints every
    // modifier edge with the hold state it produced, so a key the gesture
    // rejects names itself. The settings and the checks a capture makes are
    // in the app's own menu: Diagnostics → Dictation.
    // `Pretype --dictation-probe`; observes only, injects nothing.
    if CommandLine.arguments.contains("--dictation-probe") {
        _ = NSApplication.shared
        setvbuf(stdout, nil, _IOLBF, 0)
        guard AXIsProcessTrusted() else {
            print("Accessibility is NOT granted for this binary — no key events can be seen.")
            exit(0)
        }
        print("Hold the dictation key (\(Settings.dictationGesture.label)) now. Ctrl-C to stop.\n")
        let tap = KeyTap()
        var hold = ModifierHold()
        tap.handler = { _ in false }   // observe only, swallow nothing
        let modifierNames: [(CGEventFlags, String)] = [
            (.maskCommand, "⌘"), (.maskAlternate, "⌥"), (.maskControl, "⌃"),
            (.maskShift, "⇧"), (.maskSecondaryFn, "fn"), (.maskAlphaShift, "caps"),
        ]
        let knownCodes: [Int64: String] = [
            58: "left ⌥", 61: "right ⌥", 55: "left ⌘", 54: "right ⌘",
            56: "left ⇧", 60: "right ⇧", 59: "left ⌃", 62: "right ⌃",
            63: "fn", 57: "caps lock",
        ]
        tap.flagsHandler = { event in
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            let mods = modifierNames.filter { flags.contains($0.0) }.map(\.1).joined()
            let outcome = hold.modifierChanged(keyCode: code, flags: flags,
                                               gesture: Settings.dictationGesture, now: Date())
            print("[flags] keyCode=\(code) (\(knownCodes[code] ?? "UNKNOWN KEY"))"
                + " mods=[\(mods.isEmpty ? "none" : mods)] raw=0x\(String(flags.rawValue, radix: 16))"
                + " armed=\(hold.isArmed)" + (outcome.map { " → \($0)" } ?? ""))
            // The diagnosis that matters: this keyboard raised the gesture's
            // modifier, but under a key code the side-specific match rejects.
            if let keys = Settings.dictationGesture.keys, flags.contains(keys.mask),
               !keys.codes.contains(code) {
                print("        ^ \(Settings.dictationGesture.label) expects keyCode "
                    + "\(keys.codes.map(String.init).joined(separator: "/")) — this is a different key")
            }
        }
        tap.start()
        print(tap.isActive ? "key tap: active" : "key tap: FAILED TO START")
        // The hold only turns into a `.begin` (and its release into `.end`)
        // when ticked past the threshold, as the app's arm timer does.
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                if hold.tick(now: Date()) == .begin { print("[hold]  threshold passed → begin") }
            }
        }
        RunLoop.main.run()
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
