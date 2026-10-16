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
}

/// Why a transcript went to the clipboard instead of the field.
enum DictationRescue {
    case focusMoved
    case timedOut
}

/// What `DictationController` needs from the app around it — a protocol, not
/// `SuggestionController` itself, so the capture state machine can be driven in
/// a test with no microphone, no AX focus and no frontmost app. Every member is
/// something the controller genuinely cannot answer alone: where the caret is,
/// what has focus, how to draw at it, and how to type into it.
@MainActor
protocol DictationHost: AnyObject {
    /// One-line activity readout, surfaced in the Diagnostics menu.
    var lastEvent: String { get set }
    var typingContext: TypingContext { get }
    /// Bumped by the host on every real focus change; a transcript is only
    /// inserted while the value still matches the one captured at `begin`.
    var focusGeneration: Int { get }
    /// Keyboard focus is in a launcher (Spotlight, Raycast) over the tracked
    /// app. Opening or closing one fires no focus change, so a transcript
    /// started on one side of it is rescued, not typed, on the other.
    var focusIsInLauncher: Bool { get }
    /// The last caret the host drew at — where a refusal notice goes when this
    /// capture never got far enough to read a caret of its own.
    var fallbackCaretRect: CGRect? { get }
    var fallbackHostStyle: HostTextStyle { get }

    /// An editable text element has keyboard focus — the one hard requirement:
    /// typing into a window with no text focus fires shortcuts, not sentences.
    func hasFocusedTextField() -> Bool
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
    /// preview of a take whose transcription outran its watchdog.
    func rescueDictated(_ text: String, because reason: DictationRescue)
    /// Voice command mode: rewrite `selection` as the spoken `instruction`
    /// asks, previewed like a ⌥⇥ fix (⏎/⇥ applies, ⎋ keeps the original).
    func applyVoiceCommand(_ instruction: String, to selection: String)
    /// The engine's minimal-edit fix over the transcript, or nil to keep it
    /// exactly as heard. May be slow — the caller owns the time budget.
    func tidyDictation(_ text: String, before context: String) async -> String?
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
