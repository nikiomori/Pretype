import AppKit
import ApplicationServices

@MainActor
protocol FocusTrackerDelegate: AnyObject {
    func focusTrackerDidChangeFocus(_ tracker: FocusTracker)
    func focusTrackerTextDidChange(_ tracker: FocusTracker)
    /// The app being typed in just stopped being frontmost. Fires even when the
    /// next app reports no AX focus change (same-process window switch, Spaces,
    /// Electron without notifications) — so a left-behind overlay can be dropped.
    func focusTrackerDidResignActiveApp(_ tracker: FocusTracker)
}

/// Everything we know about where the user is typing. Snapshotted on focus
/// change so the prompt header stays stable across keystrokes (KV-cache).
struct TypingContext: Equatable {
    var appName: String?
    var bundleID: String?
    var windowTitle: String?
    var fieldLabel: String?
}

private let axObserverCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let tracker = Unmanaged<FocusTracker>.fromOpaque(refcon).takeUnretainedValue()
    tracker.handleNotification(notification as String, element: element)
}

/// Follows the frontmost application and its focused text element via the
/// Accessibility API, reporting focus and text changes to its delegate.
final class FocusTracker {
    weak var delegate: FocusTrackerDelegate?

    /// Hard ceiling on any single synchronous AX query. Every `AXText` read runs
    /// on the main thread (the event tap dispatches there), so a target app that
    /// hangs would otherwise block the main run loop for the multi-second AX
    /// default — stalling keystrokes system-wide and getting the tap disabled by
    /// `kCGEventTapDisabledByTimeout`. Typical reads finish in <10 ms, so 0.1 s
    /// is generous headroom while bounding the worst case to a recoverable hiccup.
    static let axMessagingTimeout: Float = 0.1

    private(set) var focusedTextElement: AXUIElement?
    private(set) var observedBundleID: String?
    private(set) var observedAppName: String?
    private(set) var typingContext = TypingContext()

    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private(set) var observedPID: pid_t = 0
    private var elementNotificationsAdded = false
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
                self.delegate?.focusTrackerDidResignActiveApp(self)
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

        observedPID = pid
        observedBundleID = app.bundleIdentifier
        observedAppName = app.localizedName
        let appEl = AXUIElementCreateApplication(pid)
        appElement = appEl
        // Per-element timeout too (the global default doesn't always propagate to
        // freshly created app elements on every macOS version).
        AXUIElementSetMessagingTimeout(appEl, Self.axMessagingTimeout)
        // Wakes up the accessibility tree in Electron/Chromium apps.
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var created: AXObserver?
        guard AXObserverCreate(pid, axObserverCallback, &created) == .success, let obs = created else { return }
        observer = obs
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(obs, appEl, kAXFocusedUIElementChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)

        refreshFocusedElement()
    }

    private func detach() {
        if let obs = observer {
            // Unregister everything we added before releasing the observer, so a
            // torn-down observer never carries stale notifications.
            if let appEl = appElement {
                AXObserverRemoveNotification(obs, appEl, kAXFocusedUIElementChangedNotification as CFString)
            }
            if let focused = focusedTextElement, elementNotificationsAdded {
                AXObserverRemoveNotification(obs, focused, kAXValueChangedNotification as CFString)
                AXObserverRemoveNotification(obs, focused, kAXSelectedTextChangedNotification as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        observer = nil
        appElement = nil
        focusedTextElement = nil
        elementNotificationsAdded = false
        observedPID = 0
        observedBundleID = nil
        observedAppName = nil
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
            if let focused = focusedTextElement, CFEqual(element, focused) {
                Task { @MainActor in
                    delegate?.focusTrackerTextDidChange(self)
                }
            }
        default:
            break
        }
    }

    private func refreshFocusedElement() {
        guard let appEl = appElement, let obs = observer else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        if let old = focusedTextElement, elementNotificationsAdded {
            AXObserverRemoveNotification(obs, old, kAXValueChangedNotification as CFString)
            AXObserverRemoveNotification(obs, old, kAXSelectedTextChangedNotification as CFString)
        }
        focusedTextElement = nil
        elementNotificationsAdded = false

        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
           let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() {
            let element = ref as! AXUIElement
            AXUIElementSetMessagingTimeout(element, Self.axMessagingTimeout)
            if AXText.isEditableTextElement(element) {
                focusedTextElement = element
                AXObserverAddNotification(obs, element, kAXValueChangedNotification as CFString, refcon)
                AXObserverAddNotification(obs, element, kAXSelectedTextChangedNotification as CFString, refcon)
                elementNotificationsAdded = true
            }
        }
        typingContext = TypingContext(
            appName: observedAppName,
            bundleID: observedBundleID,
            windowTitle: focusedWindowTitle(),
            fieldLabel: focusedTextElement.flatMap { AXText.fieldLabel(for: $0) }
        )
        Task { @MainActor in
            delegate?.focusTrackerDidChangeFocus(self)
        }
    }

    private func focusedWindowTitle() -> String? {
        guard let appEl = appElement else { return nil }
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { return nil }
        let window = windowRef as! AXUIElement
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success else { return nil }
        return titleRef as? String
    }
}
