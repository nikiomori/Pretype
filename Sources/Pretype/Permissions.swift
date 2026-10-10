import ApplicationServices

enum Permissions {
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// The one re-grant instruction, shared by the launch alert and the
    /// menu's. An entry already switched ON belongs to an earlier signature
    /// of the app (another build, an update) and flipping it changes nothing:
    /// only removing it lets macOS record the copy that is running now.
    static let regrantInstructions = """
    If Pretype already shows as switched on in System Settings, that entry belongs to \
    an earlier build. Select it, remove it with −, then choose Grant Accessibility… in \
    the Pretype menu and switch the new entry on. Pretype starts by itself once it's granted.
    """

    /// `regrantInstructions` was shown this launch, by either alert — the
    /// click those instructions send the user to wants the prompt, not them again.
    @MainActor static var explainedRegrant = false

    @discardableResult
    static func prompt() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
