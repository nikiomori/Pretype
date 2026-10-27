import AVFoundation
import AppKit

/// Where a capture's words will be shown and, eventually, typed. The caret
/// geometry and host style ride together because they come out of one AX read.
struct DictationAnchor {
    /// Screen rect of the caret — nil when the field publishes no caret yet
    /// (web and Electron inputs before their first keystroke). No rect means
    /// no pill; the words still land.
    var caretRect: CGRect?
    var host: HostTextStyle
    /// Text before the caret, so the tidy-up pass can see what the sentence is
    /// continuing.
    var textBeforeCaret: String
    /// The field's selection when the capture began — the target of a voice
    /// command (`Settings.dictationCommands`). Empty when nothing is selected.
    var selectedText: String = ""
    /// The AI agent's session above its input box, when the field is one:
    /// the names it printed are what the user is about to say.
    var session: String? = nil
}

/// What holds keyboard focus, as far as a capture is concerned.
enum DictationFocus {
    /// An editable field: the words can be typed into it.
    case field
    /// Nothing editable — typed at, the words would fire shortcuts.
    case noField
    /// A panel Pretype stays out of holds the keys: see `panel(ownedBy:hasTextField:)`.
    case offLimits

    /// A non-activating panel holding keyboard focus over the tracked app,
    /// judged by the app that owns it. A launcher's field (Spotlight, Raycast)
    /// takes dictation — a search spoken into Spotlight is a fine use. A
    /// password manager's quick-access panel takes keys the same way, and
    /// `begin`'s app check only sees the app underneath, so its field would be
    /// read for the tidy-up context and typed into: the panel's own app is
    /// held to the same lists the tracked app is.
    ///
    /// The owner is judged FIRST, and `hasTextField` — an AX read of the
    /// panel — only asked when it passes: with the arrow keys in a password
    /// manager's item list nothing editable is focused, and judged as "no
    /// field" the panel got a "click into a text field" pill drawn over it.
    static func panel(ownedBy bundleID: String?, hasTextField: () -> Bool) -> DictationFocus {
        if AppPolicy.isBlacklisted(bundleID) { return .offLimits }
        return hasTextField() ? .field : .noField
    }
}

/// Why a transcript went to the clipboard instead of the field.
enum DictationRescue {
    case focusMoved
    /// A keystroke or click landed while the take was being written down.
    case caretMoved
    /// The last live preview of a take whose final pass outran its watchdog...
    case timedOut
    /// ...or failed outright: a model error, a local server that went away.
    case failed
}

/// What `DictationController` needs from the app around it — a protocol, not
/// `SuggestionController` itself, so the capture state machine can be driven in
/// a test with no microphone, no AX focus and no frontmost app. Every member is
/// something the controller genuinely cannot answer alone: where the caret is,
/// what has focus, how to draw at it, and how to type into it.
@MainActor
protocol DictationHost: AnyObject {
    /// One line of what just happened, surfaced in the Diagnostics menu.
    func report(_ event: String)
    var typingContext: TypingContext { get }
    /// Bumped by the host on every real focus change; a transcript is only
    /// inserted while the value still matches the one captured at `begin`.
    var focusGeneration: Int { get }
    /// Keyboard focus is in a launcher (Spotlight, Raycast) over the tracked
    /// app. Opening or closing one fires no focus change, so a transcript
    /// started on one side of it is rescued, not typed, on the other.
    var focusIsInLauncher: Bool { get }
    /// One of Pretype's own windows is frontmost: its fields are no place
    /// for a transcript, and the tracked field is behind it.
    var isOwnUIFrontmost: Bool { get }
    /// macOS reports secure input: a password field has the keys somewhere.
    var isSecureInputActive: Bool { get }
    /// The last caret the host drew at — where a refusal notice goes when this
    /// capture never got far enough to read a caret of its own.
    var fallbackCaretRect: CGRect? { get }
    var fallbackHostStyle: HostTextStyle { get }

    /// Whether an editable text element has keyboard focus — the one hard
    /// requirement: typing into a window with no text focus fires shortcuts,
    /// not sentences — and whether it is one Pretype may type into.
    func dictationFocus() -> DictationFocus
    /// The focused field has an open IME composition (marked text). Synthetic
    /// keystrokes land INSIDE a live composition — garbling or force-committing
    /// it, IME-dependent — so a capture must not start over one, and a finished
    /// transcript must not be typed into one.
    func isComposingInFocusedField() -> Bool
    /// A capture is starting: drop the ghost, stop the progress indicator, and
    /// cancel any in-flight ⌥⇥ fix — its preview lands whenever the engine
    /// returns (focus generation alone does not stop it: dictating in the same
    /// field bumps nothing), and over a live capture it would fight the
    /// listening pill for the window on every partial.
    func prepareForDictation()
    /// The focused field's caret and context, or nil when it publishes none.
    /// Advisory either way — dictation needs no coordinates to type.
    func dictationAnchor() -> DictationAnchor?
    /// Remember this caret as the live one (feeds `fallbackCaretRect`).
    func noteCaret(rect: CGRect, host: HostTextStyle)
    func showOverlay(_ mode: SuggestionDisplayMode, at rect: CGRect, host: HostTextStyle)
    func showTransientOverlay(_ mode: SuggestionDisplayMode, at rect: CGRect, host: HostTextStyle)
    func hideOverlay()
    /// Type a finished transcript into the focused field, with all the
    /// bookkeeping an accepted suggestion gets (seam spacing, ⌘Z, stats).
    func insertDictated(_ text: String)
    /// A finished transcript that can no longer be typed — the focus moved
    /// while it was being captured or written down. Put it on the clipboard and
    /// say so: a latched capture can be minutes of speech. Also the last live
    /// preview of a take whose final pass timed out or failed.
    func rescueDictated(_ text: String, because reason: DictationRescue)
    /// Voice command mode: rewrite `selection` as the spoken `instruction`
    /// asks, previewed like a ⌥⇥ fix (⏎/⇥ applies, ⎋ keeps the original).
    func applyVoiceCommand(_ instruction: String, to selection: String)
    /// The engine's minimal-edit fix over the transcript, or nil to keep it
    /// exactly as heard. May be slow — the caller owns the time budget.
    func tidyDictation(_ text: String) async -> String?
    /// A capture started whose transcript will go through `tidyDictation` or
    /// a voice command: load that model while the user speaks, so its reload
    /// isn't paid inside the tidy-up's time budget.
    func prewarmTidy()
    /// The controller went busy (`.preparing` on) or back to idle.
    func dictationBusyChanged()
}

/// The slice of `AudioCapture` the controller drives, injectable so a test can
/// run the state machine without ever touching a real input device (opening
/// the microphone from a test runner is a TCC prompt at best).
///
/// `start` is async because opening the device can genuinely take time — a
/// Bluetooth microphone negotiates its hands-free profile for 0.5–2 s — and
/// the main thread it would otherwise block is the one the event tap runs on.
@MainActor
protocol AudioCapturing: AnyObject {
    func start(
        deviceUID: String?,
        outputFormat: AVAudioFormat?,
        onDeviceChange: @escaping @Sendable () -> Void,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) async throws
    func stop()
}

extension AudioCapture: AudioCapturing {}
