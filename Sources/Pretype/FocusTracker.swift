import AppKit
import ApplicationServices

/// Everything we know about where the user is typing. Snapshotted on focus
/// change so the prompt header stays stable across keystrokes (KV-cache).
struct TypingContext: Equatable {
    var appName: String?
    var bundleID: String?
    /// Never prompt input: diagnostics, and part of the focus dedupe — focus
    /// re-fired on the same element under a new title or label is a new field.
    var windowTitle: String?
    var fieldLabel: String?
    /// The web page's host when the field is in one (`AXText.pageHost`) — so
    /// per-app rules can be per-site in a browser, where Gmail and Slack share
    /// one bundle ID.
    var site: String? = nil
}

private let axObserverCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let tracker = Unmanaged<FocusTracker>.fromOpaque(refcon).takeUnretainedValue()
    tracker.handleNotification(notification as String, element: element)
}

/// Follows the frontmost application and its focused text element via the
/// Accessibility API, reporting focus and text changes through its handlers.
final class FocusTracker {
    var onFocusChange: (@MainActor () -> Void)?
    /// `valueChanged`: the text itself changed, not just the selection.
    var onTextChange: (@MainActor (_ valueChanged: Bool) -> Void)?
    /// The app being typed in just stopped being frontmost. Fires even when the
    /// next app reports no AX focus change (same-process window switch, Spaces,
    /// Electron without notifications) — so a left-behind overlay can be dropped.
    var onResignActiveApp: (@MainActor () -> Void)?
    /// The window holding the caret moved or resized: the line is no longer
    /// where the overlay was placed, and a resize reflows the text on top of it.
    var onViewportChange: (@MainActor () -> Void)?

    /// Hard ceiling on any single synchronous AX query. Every `AXText` read runs
    /// on the main thread (the event tap dispatches there), so a target app that
    /// hangs would otherwise block the main run loop for the multi-second AX
    /// default — stalling keystrokes system-wide and getting the tap disabled by
    /// `kCGEventTapDisabledByTimeout`. Typical reads finish in <10 ms, so 0.1 s
    /// is generous headroom while bounding the worst case to a recoverable hiccup.
    static let axMessagingTimeout: Float = 0.1

    private(set) var focusedTextElement: AXUIElement?
    private var observedApp: NSRunningApplication?
    private(set) var typingContext = TypingContext()

    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private(set) var observedPID: pid_t = 0
    private var observedWindow: AXUIElement?
    private var activationToken: NSObjectProtocol?
    private var deactivationToken: NSObjectProtocol?

    func start() {
        // Global default for all AX messaging that doesn't set its own timeout —
        // bounds every synchronous read so a hung app can't freeze the main thread.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), Self.axMessagingTimeout)
        activationToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.attach(to: app)
        }
        // The app we were typing in losing frontmost status is the most reliable
        // "the caret left" signal: it fires for every app switch, including ones
        // that post no AX focus change, so a lingering overlay can be dropped.
        deactivationToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier == self.observedPID else { return }
            Task { @MainActor in
                self.onResignActiveApp?()
            }
        }
        if let app = NSWorkspace.shared.frontmostApplication {
            attach(to: app)
        }
    }

    private func attach(to app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid > 0,
              pid != ProcessInfo.processInfo.processIdentifier,
              pid != observedPID else { return }
        detach()

        var created: AXObserver?
        guard AXObserverCreate(pid, axObserverCallback, &created) == .success, let obs = created else {
            // Can't track this app, but the owner must not keep the previous
            // app's context (blacklist/persona would evaluate the wrong bundle).
            // Nothing was committed above, so observedPID stays 0 and
            // re-activating the app retries.
            typingContext = TypingContext(appName: app.localizedName, bundleID: app.bundleIdentifier,
                                          windowTitle: nil, fieldLabel: nil)
            Task { @MainActor in
                onFocusChange?()
            }
            return
        }

        observedPID = pid
        observedApp = app
        let appEl = AXUIElementCreateApplication(pid)
        appElement = appEl
        // Per-element timeout too (the global default doesn't always propagate to
        // freshly created app elements on every macOS version).
        AXUIElementSetMessagingTimeout(appEl, Self.axMessagingTimeout)
        wakeAccessibility()

        observer = obs
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(obs, appEl, kAXFocusedUIElementChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)

        refreshFocusedElement()
    }

    /// Wakes up the accessibility tree in Electron/Chromium apps — which then
    /// keep it up, at their own CPU cost, for as long as they run. Not in a
    /// password manager (Pretype never reads one) nor while paused: resuming
    /// calls this again for the app in front.
    func wakeAccessibility() {
        guard let appEl = appElement, Settings.enabled,
              !AppPolicy.isCredentialApp(observedApp?.bundleIdentifier) else { return }
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private func detach() {
        if let obs = observer {
            // Unregister everything we added before releasing the observer, so a
            // torn-down observer never carries stale notifications.
            if let appEl = appElement {
                AXObserverRemoveNotification(obs, appEl, kAXFocusedUIElementChangedNotification as CFString)
            }
            unobserveFocusedElement(obs)
            observeWindow(nil)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        observer = nil
        appElement = nil
        focusedTextElement = nil
        observedPID = 0
        observedApp = nil
    }

    deinit {
        detach()
        let center = NSWorkspace.shared.notificationCenter
        if let token = activationToken { center.removeObserver(token) }
        if let token = deactivationToken { center.removeObserver(token) }
    }

    fileprivate func handleNotification(_ name: String, element: AXUIElement) {
        switch name {
        case kAXFocusedUIElementChangedNotification:
            refreshFocusedElement()
        case kAXValueChangedNotification, kAXSelectedTextChangedNotification:
            if element == focusedTextElement {
                let valueChanged = name == kAXValueChangedNotification
                Task { @MainActor in
                    onTextChange?(valueChanged)
                }
            }
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            Task { @MainActor in
                onViewportChange?()
            }
        default:
            break
        }
    }

    /// Swaps a tracked handle that died for the field now holding focus — a
    /// node web and Electron apps replaced under the caret, with no focus
    /// notification. The same field (same label, same window title) is
    /// swapped in quietly, and true returned: a focus change would tear down
    /// what the pipeline holds for it (the settle window, a ⌘Z decline, the
    /// screen capture) and offer a reply in a chat box re-mounted on send.
    /// Anything else — an unlabeled field included, since nothing then says
    /// it is the same one — is reported as a focus change.
    @discardableResult
    func relatchFocusedElement() -> Bool {
        guard let appEl = appElement, let obs = observer,
              let element = AXText.element(appEl, kAXFocusedUIElementAttribute) else {
            refreshFocusedElement()
            return false
        }
        AXUIElementSetMessagingTimeout(element, Self.axMessagingTimeout)
        let title: String? = AXText.element(appEl, kAXFocusedWindowAttribute).flatMap { AXText.attribute($0, kAXTitleAttribute) }
        guard let label = AXText.editableTextLabel(element), label != nil, label == typingContext.fieldLabel,
              title == typingContext.windowTitle else {
            refreshFocusedElement()
            return false
        }
        observe(element, obs)
        return true
    }

    private func refreshFocusedElement() {
        guard let appEl = appElement, let obs = observer else { return }
        unobserveFocusedElement(obs)
        focusedTextElement = nil

        var fieldLabel: String?
        if let element = AXText.element(appEl, kAXFocusedUIElementAttribute) {
            AXUIElementSetMessagingTimeout(element, Self.axMessagingTimeout)
            if let label = AXText.editableTextLabel(element) {
                fieldLabel = label
                observe(element, obs)
            }
        }
        let window = AXText.element(appEl, kAXFocusedWindowAttribute)
        observeWindow(window)
        typingContext = TypingContext(
            appName: observedApp?.localizedName,
            bundleID: observedApp?.bundleIdentifier,
            windowTitle: window.flatMap { AXText.attribute($0, kAXTitleAttribute) },
            fieldLabel: fieldLabel,
            site: focusedTextElement.flatMap { AXText.pageHost(for: $0) }
        )
        Task { @MainActor in
            onFocusChange?()
        }
    }

    /// Track `element` as the focused field: its value and selection changes.
    private func observe(_ element: AXUIElement, _ obs: AXObserver) {
        unobserveFocusedElement(obs)
        focusedTextElement = element
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(obs, element, kAXValueChangedNotification as CFString, refcon)
        AXObserverAddNotification(obs, element, kAXSelectedTextChangedNotification as CFString, refcon)
    }

    /// Unregister the value/selection notifications on the focused field.
    private func unobserveFocusedElement(_ obs: AXObserver) {
        guard let focused = focusedTextElement else { return }
        AXObserverRemoveNotification(obs, focused, kAXValueChangedNotification as CFString)
        AXObserverRemoveNotification(obs, focused, kAXSelectedTextChangedNotification as CFString)
    }

    /// Watch the window holding the caret for moves and resizes — the overlay is
    /// placed in screen coordinates, so both slide the line out from under it
    /// (a resize also reflows the text) and no other notification reports it.
    /// Re-registered only when the window itself changes: focus moves between
    /// fields of the same window constantly.
    private func observeWindow(_ window: AXUIElement?) {
        guard let obs = observer else { return }
        if let old = observedWindow {
            if old == window { return }
            AXObserverRemoveNotification(obs, old, kAXWindowMovedNotification as CFString)
            AXObserverRemoveNotification(obs, old, kAXWindowResizedNotification as CFString)
        }
        observedWindow = window
        guard let window else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(obs, window, kAXWindowMovedNotification as CFString, refcon)
        AXObserverAddNotification(obs, window, kAXWindowResizedNotification as CFString, refcon)
    }
}
