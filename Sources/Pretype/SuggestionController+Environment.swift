import AppKit

extension SuggestionController {
    /// Everything the pipeline reaches outside the process — AX reads,
    /// synthetic keys, the overlay, the engine, the clock, and the books (Stats
    /// and the journal). The app runs on `live`; a test hands in fakes and
    /// drives a real controller with no AX tree, no posted events, no window
    /// server, no model, no real timers and no writes to the user's journal
    /// (SuggestionControllerTests).
    @MainActor
    struct Environment {
        var window: any SuggestionOverlay
        /// nil: the coordinator's (`engineCoordinator`), built by `start()`.
        var engine: (any CompletionEngine)?
        /// The field `FocusTracker` follows.
        var trackedElement: () -> AXUIElement?
        /// The process holding keyboard focus when it is neither the tracked
        /// app nor Pretype — a launcher-style panel (Spotlight, Raycast) — else
        /// nil. One system-wide AX read, none while no app is tracked.
        var focusedPanelOwner: () -> pid_t?
        /// One of Pretype's own windows is frontmost (`NSApp.isActive`).
        var ownUIFrontmost: () -> Bool
        /// Unplugged with "pause on battery" on (`AppPolicy.pausedForBattery`).
        var pausedForBattery: () -> Bool
        /// The app a process belongs to (`NSRunningApplication`): a panel is
        /// judged by its owner's bundle ID.
        var bundleIdentifier: (pid_t) -> String?
        /// The focused text field as the system reports it
        /// (`AXText.systemFocusedTextElement`), for the field the tracker missed
        /// and a launcher's own.
        var systemFocusedElement: (_ knownEditable: AXUIElement?) -> AXUIElement?
        /// The web page a field is on (`AXText.pageHost`).
        var pageHost: (AXUIElement) -> String?
        /// Probe the tracked handle; if the app destroyed its node, re-latch
        /// the tracker. Whether it was dead (`FocusTracker.relatchIfDead`).
        var relatchIfDead: (AXUIElement) -> Bool
        /// `AXText.context(for:allowEmpty:)` — read through `context(of:)`.
        var readContext: (AXUIElement, _ allowEmpty: Bool) -> TextContext?
        var selection: (AXUIElement) -> SelectionInfo?
        /// An open IME composition in the field (`AXText.hasMarkedText`).
        var hasMarkedText: (AXUIElement) -> Bool
        /// A password field holds secure input somewhere (`AXText.isSecureInputActive`).
        var secureInputActive: () -> Bool
        /// `AXText.isTerminalField`: Backspace deletes a whole grapheme
        /// cluster there.
        var isTerminalField: (AXUIElement) -> Bool
        var deleteBackward: (_ text: String, _ perCharacter: Bool) -> Void
        var insert: (String) -> Void
        /// Press Return (a dictation into a chat that sends on it).
        var pressReturn: () -> Void
        /// The clipboard (`NSPasteboard.general`): read for the prompt's
        /// clipboard block, written with a transcript that can't be typed.
        var pasteboard: NSPasteboard
        var now: () -> Date
        /// Run on the main queue after a delay.
        var after: (TimeInterval, @escaping @MainActor () -> Void) -> Void
        /// Run on the main queue once the current event callback has returned
        /// — the key tap's hop before anything that reads AX.
        var hop: (@escaping @MainActor () -> Void) -> Void
        /// The wait before a completion query starts (`Settings.debounceMs`).
        var debounce: () async -> Void
        /// The Screen Recording grant (`ScreenContext.hasPermission`).
        var screenRecordingAllowed: () -> Bool
        /// No metered or constrained network in the way of a download
        /// (`ModelStorage.isNetworkUnmetered`).
        var networkUnmetered: @MainActor () async -> Bool
        /// OCR of an app's window (`ScreenContext.capture`).
        var captureScreen: (_ pid: pid_t, _ excluding: String, _ caret: CGRect?, _ maxChars: Int) async -> String?
        /// Count something in `Stats`, and journal it while the journal is on.
        var book: (Booking) -> Void
        /// Suggestions in this app have been shown dozens of times and almost
        /// never taken (`Stats.isUnproductive`).
        var isUnproductive: (_ bundleID: String?) -> Bool
        /// The user's own n-gram (`PersonalNgram.shared`), built from the
        /// journal on first use while personalization is on.
        var personalNgram: PersonalNgram
        /// The accepted phrases most like the text being typed
        /// (`SuggestionJournal.similarAcceptedPhrases`). Off the main actor.
        var similarAcceptedPhrases: @Sendable (String) -> [SuggestionJournal.AcceptedPhrase]

        func context(of element: AXUIElement, allowEmpty: Bool = false) -> TextContext? {
            readContext(element, allowEmpty)
        }

        static func live(_ tracker: FocusTracker) -> Environment {
            Environment(
                window: SuggestionWindow(),
                engine: nil,
                trackedElement: { tracker.focusedTextElement },
                focusedPanelOwner: {
                    var pid: pid_t = 0
                    guard tracker.observedPID > 0,
                          let app = AXText.element(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as String),
                          AXUIElementGetPid(app, &pid) == .success, pid > 0, pid != tracker.observedPID,
                          pid != ProcessInfo.processInfo.processIdentifier else { return nil }
                    return pid
                },
                ownUIFrontmost: { NSApp.isActive },
                pausedForBattery: { AppPolicy.pausedForBattery },
                bundleIdentifier: { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier },
                systemFocusedElement: { AXText.systemFocusedTextElement(knownEditable: $0) },
                pageHost: { AXText.pageHost(for: $0) },
                relatchIfDead: { tracker.relatchIfDead($0) },
                readContext: { AXText.context(for: $0, allowEmpty: $1) },
                selection: { AXText.selectionInfo(for: $0) },
                hasMarkedText: { AXText.hasMarkedText($0) },
                secureInputActive: { AXText.isSecureInputActive() },
                isTerminalField: { AXText.isTerminalField($0) },
                deleteBackward: { TextInjector.deleteBackward(over: $0, perCharacter: $1) },
                insert: { TextInjector.insert($0) },
                pressReturn: { TextInjector.press(KeyCode.returnKey, times: 1) },
                pasteboard: .general,
                now: { Date() },
                after: { delay, work in
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(work) }
                },
                hop: { work in DispatchQueue.main.async { MainActor.assumeIsolated(work) } },
                debounce: { try? await Task.sleep(for: .milliseconds(Settings.debounceMs)) },
                screenRecordingAllowed: { ScreenContext.hasPermission },
                networkUnmetered: { await ModelStorage.isNetworkUnmetered() },
                captureScreen: { await ScreenContext.capture(pid: $0, excluding: $1, caretRect: $2, maxChars: $3) },
                book: { booking in
                    switch booking {
                    case .offer(let entry):
                        Stats.recordOffer(outcome: entry.outcome, shownForMs: entry.shownForMs,
                                          tookAny: entry.acceptedChars > 0, app: entry.app)
                        guard Settings.suggestionJournalEnabled else { return }
                        // Live n-gram learning from the same ctx snapshots the
                        // startup build replays — so today's typing predicts today.
                        if Settings.personalizationLevel != .off {
                            PersonalNgram.shared.observe(ctx: entry.ctx, app: entry.app)
                        }
                        SuggestionJournal.shared.append(entry)
                    case .undo(let entry):
                        guard Settings.suggestionJournalEnabled else { return }
                        SuggestionJournal.shared.append(entry)
                    case .accepted(let chunk, let countSuggestion, let app):
                        Stats.recordAccepted(chunk: chunk, countSuggestion: countSuggestion, app: app)
                    case .latency(let seconds):
                        Stats.recordLatency(seconds)
                    case .correction:
                        Stats.recordCorrection()
                    case .dictated(let chars):
                        Stats.recordDictated(chars: chars)
                    }
                },
                isUnproductive: { Stats.isUnproductive($0) },
                personalNgram: .shared,
                similarAcceptedPhrases: { SuggestionJournal.shared.similarAcceptedPhrases(to: $0) })
        }
    }
}

extension SuggestionController {
    /// What the pipeline books (`Environment.book`).
    enum Booking {
        /// An offer resolved (`OfferRecord.resolve`): counted, and journaled —
        /// feeding the n-gram.
        case offer(SuggestionJournal.Entry)
        /// ⌘Z took an accepted suggestion back: journaled only.
        case undo(SuggestionJournal.Entry)
        /// ⇥ typed `chunk` of a suggestion — counted as one (`countSuggestion`)
        /// however many words it is taken in, or "accepted of shown" passes 100 %.
        case accepted(chunk: String, countSuggestion: Bool, app: String?)
        /// The engine's first token, this long after the request.
        case latency(TimeInterval)
        case correction
        /// A dictation typed this many characters of transcript.
        case dictated(chars: Int)
    }

    /// A transcript put on `pasteboard` for this Mac only — Universal
    /// Clipboard ignores the transient marker and would offer it to every
    /// device on the iCloud account — and marked transient, so clipboard
    /// managers keep it out of their on-disk history.
    static func copyTranscript(_ text: String, to pasteboard: NSPasteboard) {
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: transientType)
    }
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
}

/// The overlay as the pipeline, the caret indicator, the fix flows and
/// dictation drive it — `SuggestionWindow` in the app, a recorder in tests.
@MainActor
protocol SuggestionOverlay: AnyObject {
    var presentation: SuggestionPresentation { get set }
    var onVisibilityChange: (() -> Void)? { get set }
    var isVisible: Bool { get }
    /// What the overlay is offering, nil when nothing (`SuggestionWindow.currentMode`).
    var currentMode: SuggestionDisplayMode? { get }
    @discardableResult
    func show(mode: SuggestionDisplayMode, at caretRect: CGRect, host: HostTextStyle, trimToLine: Bool) -> String?
    func showTransient(_ mode: SuggestionDisplayMode, at caretRect: CGRect, host: HostTextStyle,
                       hideAfter: TimeInterval, protectFor: TimeInterval)
    func hide(force: Bool)
    func advance(past accepted: String, remaining: String) -> String?
    func clearNoticeProtection()
    func fieldChanged()
}

extension SuggestionOverlay {
    /// A completion ghost (or panel) is the thing on screen right now.
    var showsSuggestion: Bool { SuggestionWindow.offersSuggestion(currentMode) }

    /// A correction is on screen: the ⌥⇥ preview awaiting accept, or the inline
    /// spell pill over the word at the caret.
    var showsCorrection: Bool { SuggestionWindow.offersCorrection(currentMode) }

    @discardableResult
    func show(mode: SuggestionDisplayMode, at caretRect: CGRect, host: HostTextStyle = HostTextStyle()) -> String? {
        show(mode: mode, at: caretRect, host: host, trimToLine: true)
    }

    func showTransient(_ mode: SuggestionDisplayMode, at caretRect: CGRect,
                       host: HostTextStyle = HostTextStyle(), hideAfter: TimeInterval = 1.8) {
        showTransient(mode, at: caretRect, host: host, hideAfter: hideAfter, protectFor: 0)
    }

    func showTransient(_ mode: SuggestionDisplayMode, at caretRect: CGRect, host: HostTextStyle,
                       protectFor: TimeInterval) {
        showTransient(mode, at: caretRect, host: host, hideAfter: 1.8, protectFor: protectFor)
    }

    func hide() { hide(force: false) }
}

extension SuggestionWindow: SuggestionOverlay {}
