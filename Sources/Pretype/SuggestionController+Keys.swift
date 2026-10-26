import CoreGraphics

/// The key tap's gate for the completion pipeline — every rule in one table,
/// applied by `handleKeyDown`. Dictation's keys are decided before it (its own
/// table, `DictationController.action`), and keys typed into Pretype's own
/// windows never reach it. KeyGateTests pins the table.
extension SuggestionController {
    enum KeyAction: Equatable {
        /// ⌘Z takes back the chunk just typed: swallowed, deleted off the tap.
        case undo
        /// The reply chord: swallowed, composed off the tap.
        case reply
        /// A fix preview or spell pill took the key — swallowed, or acted on
        /// and passed on (⎋ keeps the original and still reaches the app).
        case fix(swallowed: Bool)
        /// ⇥ or ⇧⇥: type `chunk` of the ghost.
        case accept(String)
        /// ⎋ over the ghost: dropped, its field declined — and still the app's key.
        case decline(before: String, after: String)
        /// The app's key: the ghost narrows past it and the field is re-read.
        case type
    }

    /// What the gate reads, all known before the key is routed.
    struct KeyState {
        var keyCode: Int64
        var flags: CGEventFlags
        /// Exact ⌘Z on the current layout (`isPlainCommandZ`).
        var isCommandZ = false
        /// The ⌘Z record still matches the field (`FieldState.pendingUndo`).
        var canUndo = false
        /// Pretype stays out of this app or site, or a hands-free capture owns
        /// the overlay: neither the reply nor the fix chord is ours.
        var offHere = false
        var ghost: FieldState.Ghost?
        /// The window shows the ghost. A dictation pill, a notice, a fix pill
        /// or an engine status over it means ⇥ would type text nobody sees.
        var ghostOnScreen = false
        var style = HotkeyStyle.tab
        /// The fix and reply features are on (`Settings.fixesEnabled`,
        /// `Settings.repliesEnabled`): off, their chords are the app's keys.
        var fixes = true
        var replies = true
    }

    /// `fix` asks the fix flows, which get first refusal — a fix preview is
    /// only ever up when no completion is. `focusElsewhere` is an AX read, so
    /// only an accept key over a ghost on screen asks it: a launcher holding
    /// the keys must get its ⇥, not our ghost. ⌘Z is checked against the
    /// cache alone, with no read inside the tap: a caret moved since the
    /// accept makes it the app's own undo.
    static func keyAction(for key: KeyState, fix: () -> CorrectionController.KeyOutcome,
                          focusElsewhere: () -> Bool) -> KeyAction {
        if key.canUndo, key.isCommandZ { return .undo }
        if !key.offHere {
            // Before the fix flows only for symmetry: the two chords differ
            // by ⇧ and the fix matcher demands exact flags.
            if key.replies, key.style.matchesReply(keyCode: key.keyCode, flags: key.flags) { return .reply }
            switch key.fixes ? fix() : .ignored {
            case .consumed: return .fix(swallowed: true)
            case .passThrough: return .fix(swallowed: false)
            case .ignored: break
            }
        }
        if let ghost = key.ghost, key.ghostOnScreen {
            let all = key.style.matchesAcceptAll(keyCode: key.keyCode, flags: key.flags)
            if all || key.style.matchesAcceptWord(keyCode: key.keyCode, flags: key.flags), !focusElsewhere() {
                return .accept(all ? ghost.text : firstWordChunk(of: ghost.text))
            }
            if key.keyCode == KeyCode.escape { return .decline(before: ghost.anchor, after: ghost.after) }
        }
        return .type
    }
}
