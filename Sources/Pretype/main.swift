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

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
