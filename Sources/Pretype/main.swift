import AppKit
import ApplicationServices

Settings.registerDefaults()

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
                print("[probe] \(AXText.probeContextLine())")
                if Date().timeIntervalSince(started) > 25 { exit(0) }
            }
        }
        RunLoop.main.run()
    }

    // Diagnostic: why holding the dictation key does nothing. Prints the
    // environment once, then every modifier edge with the hold state it
    // produced — and, when a hold completes, each condition `begin()` checks,
    // so a silent refusal (blacklisted app, our own window frontmost, no
    // readable caret) names itself instead of looking like a dead feature.
    // `Pretype --dictation-probe`; observes only, injects nothing.
    if CommandLine.arguments.contains("--dictation-probe") {
        _ = NSApplication.shared
        setvbuf(stdout, nil, _IOLBF, 0)
        print("bundled:            \(MicrophoneAccess.isBundled)")
        // The caveat is load-bearing: TCC answers for the RESPONSIBLE process,
        // and a probe launched from a shell inherits the terminal's microphone
        // grant, not Pretype's. Only Diagnostics → Dictation, read inside the
        // running app, states Pretype's own grant truthfully.
        print("microphone auth:    \(MicrophoneAccess.status.rawValue) (3 = authorized)"
            + " — run from a terminal this is the TERMINAL's grant;"
            + " Pretype's own is in its menu under Diagnostics → Dictation")
        print("transcription:      \(Transcription.isSupported ? "available" : "UNAVAILABLE")")
        print("dictation enabled:  \(Settings.dictationEnabled)")
        print("gesture:            \(Settings.dictationGesture.label)")
        let locale = Settings.resolvedDictationLocale
        Task { @MainActor in
            print("language:           \(Transcription.name(of: locale)) — \(await Transcription.support(for: locale))")
        }
        guard AXIsProcessTrusted() else {
            print("\nAccessibility is NOT granted for this binary — no key events can be seen.")
            exit(0)
        }
        print("\nHold the dictation key now. Ctrl-C to stop.\n")
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
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                guard hold.tick(now: Date()) == .begin else { return }
                print("[hold]  threshold passed — what begin() would check:")
                let front = NSWorkspace.shared.frontmostApplication
                print("        our own window frontmost: \(NSApp.isActive) (must be false)")
                print("        front app: \(front?.bundleIdentifier ?? "?")"
                    + " — blacklisted: \(AppPolicy.isBlacklisted(front?.bundleIdentifier))")
                let element = AXText.systemFocusedTextElement()
                let ctx = element.flatMap {
                    AXText.context(for: $0, maxChars: 200, allowEmpty: true)
                }
                print("        text element: \(element == nil ? "NONE" : "found")"
                    + ", caret rect: \(ctx?.caretRect.map { "\($0)" } ?? "NONE")")
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
