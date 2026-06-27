import AppKit

/// Shared settings-surface logic so the menu (`StatusMenuController`) and the
/// window (`SettingsWindowController`) don't each reimplement the model-catalog
/// listing, the confidence-gate availability rule, and the Screen Recording
/// permission flow. These three were previously copied between both files and
/// had to be kept in lock-step by hand — any new model or changed gate rule
/// meant editing two places, and they drifted.
@MainActor
enum SettingsUI {
    /// One selectable model row: a stable id (stored in the control's
    /// `representedObject`) and a display title carrying the size and the
    /// "recommended for this Mac" mark.
    struct ModelEntry {
        let id: String
        let title: String
    }

    /// The model list both surfaces render: every catalog option (sized, with the
    /// system-fit pick marked), then the Apple Intelligence system row on macOS
    /// 26+. The menu labels that row with its "(0 GB)" footprint; the window
    /// doesn't — `includeAppleIntelligenceSize` keeps that one cosmetic difference.
    /// The user's fine-tuned local model is appended by each caller (only the
    /// window pre-lists it), so it's not included here.
    static func modelEntries(includeAppleIntelligenceSize: Bool) -> [ModelEntry] {
        let recommendedID = ModelCatalog.defaultID  // the system-fit pick for this Mac
        var entries = ModelCatalog.options.map { option -> ModelEntry in
            var title = "\(option.title) (≈\(option.approxSizeMB) MB)"
            if option.id == recommendedID { title += " — recommended for this Mac" }
            return ModelEntry(id: option.id, title: title)
        }
        if #available(macOS 26.0, *) {
            let title = includeAppleIntelligenceSize
                ? "Apple Intelligence — system model (0 GB)"
                : "Apple Intelligence — system model"
            entries.append(ModelEntry(id: ModelCatalog.appleIntelligenceID, title: title))
        }
        return entries
    }

    /// The confidence gate only helps as a Base-style feature on a gate-capable
    /// model (E4B at ≥6-bit). Both UIs grey it out elsewhere so it never reads as
    /// "on but doing nothing".
    static func confidenceGateUsable() -> Bool {
        Settings.completionStyle == .base
            && ModelCatalog.recommended(for: Settings.mlxModelID).gateCapable
    }

    /// Turn screen-context OCR on or off from a toggling control. Enabling it when
    /// permission isn't granted yet registers the app with TCC, opens the Screen
    /// Recording pane, and shows the relaunch alert (macOS applies this permission
    /// only at launch). Shared by the menu and the settings window.
    static func setScreenContext(_ enable: Bool) {
        guard enable else {
            Settings.screenContextEnabled = false
            return
        }
        Settings.screenContextEnabled = true
        guard !ScreenContext.hasPermission else { return }
        ScreenContext.registerWithTCC()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission"
        alert.informativeText = """
        Pretype should now appear in System Settings → Privacy & Security → \
        Screen Recording. Enable it there, then quit and relaunch Pretype — \
        macOS applies this permission only at app launch.
        """
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
