import AppKit
import ApplicationServices

enum Permissions {
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// What System Settings calls the pane: macOS 27 relabeled Privacy &
    /// Security → Accessibility as "Device Control and Data Access" (same
    /// TCC service, same deep link), so the old name sends users hunting.
    static var paneName: String {
        if #available(macOS 27, *) { return String(localized: "Device Control and Data Access") }
        return String(localized: "Accessibility")
    }

    /// The one re-grant instruction, shared by the launch alert and the
    /// menu's. An entry already switched ON belongs to an earlier signature
    /// of the app (another build, an update) and flipping it changes nothing:
    /// only removing it lets macOS record the copy that is running now.
    static var regrantInstructions: String { String(localized: """
    If Pretype already shows as switched on in System Settings → Privacy & Security → \
    \(paneName), that entry belongs to an earlier build. Select it, remove it with −, \
    then choose Grant Accessibility… in the Pretype menu and switch the new entry on. \
    Pretype starts by itself once it's granted.
    """) }

    /// `regrantInstructions` was shown this launch, by either alert — the
    /// click those instructions send the user to wants the prompt, not them again.
    @MainActor static var explainedRegrant = false

    static func prompt() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// "Grant Accessibility…", from the menu or the Settings banner: the
    /// prompt plus the pane it points at.
    @MainActor static func openSettings() {
        // Someone who granted it before almost always finds Pretype already
        // switched ON — a stale entry (see `regrantInstructions`). Once per
        // launch: the instructions send them back here after removing it,
        // and that click wants the prompt, not the same alert again.
        if Settings.onboardingCompleted, !explainedRegrant {
            explainedRegrant = true
            let alert = NSAlert()
            alert.messageText = String(localized: "Grant Accessibility again")
            alert.informativeText = regrantInstructions
            alert.addButton(withTitle: String(localized: "Open System Settings"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        prompt()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
