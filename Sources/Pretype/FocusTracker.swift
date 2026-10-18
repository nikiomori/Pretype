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

    /// The accessibility calls a focus refresh and a re-latch make of the
    /// tracked app. `live` in the app; a test hands in its own and drives the
    /// real dedupe and re-latch with no AX tree (FocusTrackerTests).
    struct AXCalls {
        var focusedElement: (_ app: AXUIElement) -> AXUIElement?
        var focusedWindow: (_ app: AXUIElement) -> AXUIElement?
        var title: (_ window: AXUIElement) -> String?
        /// `AXText.editableTextLabel`: nil when not an editable text field,
        /// `.some(nil)` for one with no label.
        var editableLabel: (AXUIElement) -> String??
        var pageHost: (AXUIElement) -> String?
        /// The bundle ID of the app an element belongs to.
        var bundleID: (_ app: AXUIElement) -> String?
        var isDead: (AXUIElement) -> Bool
        /// See `wakeAccessibility`.
        var wake: (_ app: AXUIElement) -> Void
        /// Have the observer post `notification` for `element`, or stop.
        var register: (_ observer: AXObserver, _ element: AXUIElement, _ notification: String,
                       _ refcon: UnsafeMutableRawPointer) -> Void
        var unregister: (_ observer: AXObserver, _ element: AXUIElement, _ notification: String) -> Void

        static let live = AXCalls(
            focusedElement: { AXText.element($0, kAXFocusedUIElementAttribute) },
            focusedWindow: { AXText.element($0, kAXFocusedWindowAttribute) },
            title: { AXText.attribute($0, kAXTitleAttribute) },
            editableLabel: { AXText.editableTextLabel($0) },
            pageHost: { AXText.pageHost(for: $0) },
            bundleID: { app in
                var pid: pid_t = 0
                guard AXUIElementGetPid(app, &pid) == .success else { return nil }
                return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            },
            isDead: { AXText.isDead($0) },
            wake: { AXUIElementSetAttributeValue($0, "AXManualAccessibility" as CFString, kCFBooleanTrue) },
            register: { AXObserverAddNotification($0, $1, $2 as CFString, $3) },
            unregister: { AXObserverRemoveNotification($0, $1, $2 as CFString) })
    }

    private let ax: AXCalls

    init(ax: AXCalls = .live) {
        self.ax = ax
    }

    private(set) var focusedTextElement: AXUIElement?
    private var observedApp: NSRunningApplication?
    private var typingContext = TypingContext()
    /// The focus as `onFocusChange` last reported it. Apps fire the focus
    /// notification in duplicate bursts: the same context on the same element
    /// is no change, so a report compares the two when it runs and is dropped
    /// when they match. A quiet re-latch (`relatchIfDead`) moves the element
    /// along with the handle, so the swap reads as the same field.
    private(set) var reportedContext = TypingContext()
    private var reportedElement: AXUIElement?

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
            reportFocusChange()
            return
        }

        observedApp = app
        follow(AXUIElementCreateApplication(pid), observer: obs)
    }

    /// Follow the focus inside `appEl` from here on. `attach` passes the
    /// observer whose notifications drive the refreshes; without one (a test)
    /// they are delivered by hand through `handleNotification`.
    func follow(_ appEl: AXUIElement, observer obs: AXObserver?) {
        appElement = appEl
        var pid: pid_t = 0
        observedPID = AXUIElementGetPid(appEl, &pid) == .success ? pid : 0
        // Per-element timeout too (the global default doesn't always propagate to
        // freshly created app elements on every macOS version).
        AXUIElementSetMessagingTimeout(appEl, Self.axMessagingTimeout)
        wakeAccessibility()

        observer = obs
        if let obs {
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            ax.register(obs, appEl, kAXFocusedUIElementChangedNotification, refcon)
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }

        refreshFocusedElement()
    }

    /// Wakes up the accessibility tree in Electron/Chromium apps — which then
    /// keep it up, at their own CPU cost, for as long as they run. Not in a
    /// password manager (Pretype never reads one) nor while paused: resuming
    /// calls this again for the app in front.
    func wakeAccessibility() {
        guard let appEl = appElement, Settings.enabled,
              !AppPolicy.isCredentialApp(ax.bundleID(appEl)) else { return }
        ax.wake(appEl)
    }

    private func detach() {
        if let obs = observer {
            // Unregister everything we added before releasing the observer, so a
            // torn-down observer never carries stale notifications.
            if let appEl = appElement {
                ax.unregister(obs, appEl, kAXFocusedUIElementChangedNotification)
            }
            unobserveFocusedElement()
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

    func handleNotification(_ name: String, element: AXUIElement) {
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

    /// The app destroyed the node behind the tracked `element` — web and
    /// Electron apps replace the focused node under the caret, with no focus
    /// notification — so swap in the field now holding focus. The same field
    /// (same label, same window title) is swapped in quietly: a focus change
    /// would tear down what the pipeline holds for it (the settle window, a
    /// ⌘Z decline, the screen capture) and offer a reply in a chat box
    /// re-mounted on send. Anything else — an unlabeled field included, since
    /// nothing then says it is the same one — is reported as a focus change.
    /// Returns whether the handle was dead. One AX round trip when it isn't.
    func relatchIfDead(_ element: AXUIElement) -> Bool {
        guard ax.isDead(element) else { return false }
        guard let appEl = appElement, let focused = ax.focusedElement(appEl) else {
            refreshFocusedElement()
            return true
        }
        AXUIElementSetMessagingTimeout(focused, Self.axMessagingTimeout)
        let title = ax.focusedWindow(appEl).flatMap(ax.title)
        guard let label = ax.editableLabel(focused), label != nil, label == typingContext.fieldLabel,
              title == typingContext.windowTitle else {
            refreshFocusedElement()
            return true
        }
        observe(focused)
        reportedElement = focused
        return true
    }

    private func refreshFocusedElement() {
        guard let appEl = appElement else { return }
        unobserveFocusedElement()
        focusedTextElement = nil

        var fieldLabel: String?
        if let element = ax.focusedElement(appEl) {
            AXUIElementSetMessagingTimeout(element, Self.axMessagingTimeout)
            if let label = ax.editableLabel(element) {
                fieldLabel = label
                observe(element)
            }
        }
        let window = ax.focusedWindow(appEl)
        observeWindow(window)
        typingContext = TypingContext(
            appName: observedApp?.localizedName,
            bundleID: ax.bundleID(appEl),
            windowTitle: window.flatMap(ax.title),
            fieldLabel: fieldLabel,
            site: focusedTextElement.flatMap(ax.pageHost)
        )
        reportFocusChange()
    }

    /// Report once the notification burst has landed — compared then, not
    /// now, so a burst that ends where it started reports nothing.
    private func reportFocusChange() {
        Task { @MainActor in
            guard typingContext != reportedContext || focusedTextElement != reportedElement else { return }
            reportedContext = typingContext
            reportedElement = focusedTextElement
            onFocusChange?()
        }
    }

    /// Track `element` as the focused field: its value and selection changes.
    private func observe(_ element: AXUIElement) {
        unobserveFocusedElement()
        focusedTextElement = element
        guard let obs = observer else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        ax.register(obs, element, kAXValueChangedNotification, refcon)
        ax.register(obs, element, kAXSelectedTextChangedNotification, refcon)
    }

    /// Unregister the value/selection notifications on the focused field.
    private func unobserveFocusedElement() {
        guard let obs = observer, let focused = focusedTextElement else { return }
        ax.unregister(obs, focused, kAXValueChangedNotification)
        ax.unregister(obs, focused, kAXSelectedTextChangedNotification)
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
            ax.unregister(obs, old, kAXWindowMovedNotification)
            ax.unregister(obs, old, kAXWindowResizedNotification)
        }
        observedWindow = window
        guard let window else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        ax.register(obs, window, kAXWindowMovedNotification, refcon)
        ax.register(obs, window, kAXWindowResizedNotification, refcon)
    }
}
