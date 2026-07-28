import AppKit
import CoreGraphics

/// CGEvent tap on key-down events. The handler returns `true` to swallow
/// the event (used to consume Tab while a suggestion is visible).
final class KeyTap {
    var handler: ((CGEvent) -> Bool)?
    /// Modifier presses/releases, observed only — never swallowed. Feeds the
    /// double-⌥ gesture; a modifier the user pressed must always reach the app.
    var flagsHandler: ((CGEvent) -> Void)?
    /// Scroll events, observed only. The overlay is placed in SCREEN coordinates
    /// and AX posts no notification for a scroll, so the line slides out from
    /// under a live ghost and leaves it sitting over unrelated text.
    ///
    /// Delivered by NSEvent monitors, NOT by the tap: the tap is a filtering
    /// one, so every scroll event on the session — momentum frames included —
    /// would have to round-trip through this process's main run loop before any
    /// app saw it, and a main thread busy with an AX read would show up as
    /// system-wide scroll jank (and a tap disabled by timeout). A monitor gets
    /// a copy and gates nothing.
    ///
    /// `isMomentum` marks inertia frames — the coasting tail a trackpad flick
    /// keeps posting for seconds after the finger left. The overlay still wants
    /// them (the view is still moving under the ghost); dictation must ignore
    /// them, or a hold started while a flick is still coasting dies instantly.
    var scrollHandler: ((_ isMomentum: Bool) -> Void)?
    /// Mouse presses, observed only, delivered by a monitor for the same reason
    /// scrolls are. A click during a hold-to-talk capture says the modifier was
    /// held for the click (⌥-click, ⌥-drag) rather than for talking — and it has
    /// just moved the caret out from under the transcript besides.
    var mouseDownHandler: (() -> Void)?

    private var tapPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var scrollMonitor: Any?
    private var mouseMonitor: Any?
    /// Local twins of the two global monitors. A GLOBAL monitor, by definition,
    /// never sees events delivered to our own app — so a click on Pretype's own
    /// status item or Settings window mid-hold would cancel nothing, and the
    /// capture would survive to type its transcript into our own UI. The local
    /// monitors close exactly that hole; both observe and pass the event on.
    private var localScrollMonitor: Any?
    private var localMouseMonitor: Any?

    var isActive: Bool { tapPort != nil }

    func start() {
        // Before the tap guard: `start()` is retried every 3 s until the tap
        // comes up, and the monitor needs installing exactly once either way.
        if scrollMonitor == nil {
            scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.scrollHandler?(!event.momentumPhase.isEmpty)
            }
        }
        if mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] _ in
                self?.mouseDownHandler?()
            }
        }
        if localScrollMonitor == nil {
            localScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.scrollHandler?(!event.momentumPhase.isEmpty)
                return event
            }
        }
        if localMouseMonitor == nil {
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] event in
                self?.mouseDownHandler?()
                return event
            }
        }
        guard tapPort == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue
            | 1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<KeyTap>.fromOpaque(refcon).takeUnretainedValue()
            switch type {
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                tap.reenable()
                return Unmanaged.passUnretained(event)
            case .keyDown:
                if tap.handler?(event) == true { return nil }
                return Unmanaged.passUnretained(event)
            case .flagsChanged:
                tap.flagsHandler?(event)
                return Unmanaged.passUnretained(event)
            default:
                return Unmanaged.passUnretained(event)
            }
        }
        tapPort = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        guard let tapPort else {
            NSLog("Pretype: failed to create event tap — is Accessibility permission granted?")
            return
        }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tapPort, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tapPort, enable: true)
    }

    fileprivate func reenable() {
        if let tapPort {
            CGEvent.tapEnable(tap: tapPort, enable: true)
        }
    }

    /// Tear the tap down completely: disable it, drop the run-loop source, and
    /// invalidate the mach port. Safe to call when inactive.
    func stop() {
        if let tapPort {
            CGEvent.tapEnable(tap: tapPort, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let tapPort {
            CFMachPortInvalidate(tapPort)
        }
        for monitor in [scrollMonitor, mouseMonitor, localScrollMonitor, localMouseMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        scrollMonitor = nil
        mouseMonitor = nil
        localScrollMonitor = nil
        localMouseMonitor = nil
        runLoopSource = nil
        tapPort = nil
    }

    deinit {
        stop()
    }
}

/// Double-tap a bare modifier — a one-finger trigger for the reply flow, since
/// a four-key chord is awkward to reach mid-typing. A *tap* is the modifier
/// pressed and released with no other key and no other modifier in between (so
/// every chord and every held modifier is excluded), and two taps inside `gap`
/// fire it. WHICH modifier is the user's choice: each one is somebody's global
/// hotkey already.
///
/// Pure and time-injected: the timing rules are the whole feature, so they are
/// testable without an event tap.
struct ModifierDoubleTap {
    var holdLimit: TimeInterval = 0.4
    var gap: TimeInterval = 0.45

    private var downAt: Date?
    private var interrupted = false
    private var lastTapAt: Date?

    /// Any other key while the modifier is down makes it a chord, not a tap.
    mutating func keyPressed() { interrupted = true }

    /// Feed a `.flagsChanged` event. True when this release completes a double tap.
    mutating func modifierChanged(keyCode: Int64, flags: CGEventFlags,
                                  gesture: ReplyGesture, now: Date) -> Bool {
        guard let keys = gesture.keys else { return false }
        guard keys.codes.contains(keyCode) else {
            // Another modifier joined the gesture — not a bare tap any more.
            downAt = nil
            lastTapAt = nil
            return false
        }
        if flags.contains(keys.mask) {
            // Down. Already holding another modifier means a chord is being
            // built. fn counts (fn-⌥ and friends are system shortcuts); caps
            // lock is deliberately absent — its flag is a latched state, not a
            // held key, and caps-lock-on users still get to use the gesture.
            let others = CGEventFlags([.maskCommand, .maskControl, .maskAlternate,
                                       .maskShift, .maskSecondaryFn])
                .subtracting(keys.mask)
            downAt = flags.isDisjoint(with: others) ? now : nil
            interrupted = false
            return false
        }
        let pressedAt = downAt
        downAt = nil
        guard let pressedAt, !interrupted, now.timeIntervalSince(pressedAt) < holdLimit else {
            lastTapAt = nil
            return false
        }
        if let previous = lastTapAt, now.timeIntervalSince(previous) < gap {
            lastTapAt = nil
            return true
        }
        lastTapAt = now
        return false
    }
}

/// Hold a bare modifier to talk — the push-to-talk half of `DictationGesture`.
///
/// The mirror of `ModifierDoubleTap`, and deliberately its complement: the same
/// "bare" rules (no other modifier joined in, no key pressed while it was
/// down), but it fires once the hold PASSES `threshold` instead of on release.
/// That is what lets the two share a modifier — a hold is never a tap, and two
/// taps are never a hold.
///
/// It needs a `tick` because the OS sends no event for "still being held": the
/// only thing that can start a capture is a timer the owner schedules when
/// `isArmed` turns true.
///
/// Pure and time-injected: the timing rules are the whole feature, so they are
/// testable without an event tap or a microphone.
struct ModifierHold {
    enum Event: Equatable {
        /// The hold passed the threshold — start capturing.
        case begin
        /// Released after a `begin` — stop, and use what was captured.
        case end
        /// An in-progress capture was invalidated (another key, another
        /// modifier, focus moved). Throw it away.
        case cancel
    }

    /// Long enough that a modifier brushed on the way to a chord never opens
    /// the microphone; short enough that "press and talk" isn't a wait. Also
    /// past `ModifierDoubleTap.holdLimit`, so a hold can't also register as the
    /// first tap of a double-tap.
    var threshold: TimeInterval = 0.45

    private var downAt: Date?
    private var holding = false

    /// A bare press is in progress — the owner should be running the tick timer.
    var isArmed: Bool { downAt != nil }
    /// Audio should be capturing right now.
    var isActive: Bool { holding }

    /// Feed a `.flagsChanged` event.
    mutating func modifierChanged(keyCode: Int64, flags: CGEventFlags,
                                  gesture: DictationGesture, now: Date) -> Event? {
        guard let keys = gesture.keys else { return interrupt() }
        guard keys.codes.contains(keyCode) else {
            // Another modifier joined or left: this is a chord being built, not
            // someone holding one key to speak.
            return interrupt()
        }
        if flags.contains(keys.mask) {
            // Down. Already holding something else means a chord — don't arm.
            // Same mask as `ModifierDoubleTap`: fn in, caps lock out.
            let others = CGEventFlags([.maskCommand, .maskControl, .maskAlternate,
                                       .maskShift, .maskSecondaryFn])
                .subtracting(keys.mask)
            downAt = flags.isDisjoint(with: others) ? now : nil
            return nil
        }
        // Up.
        downAt = nil
        guard holding else { return nil }
        holding = false
        return .end
    }

    /// Called from the owner's timer once `threshold` should have elapsed.
    mutating func tick(now: Date) -> Event? {
        guard !holding, let downAt, now.timeIntervalSince(downAt) >= threshold else { return nil }
        holding = true
        return .begin
    }

    /// A real keystroke while the modifier is down makes it a chord.
    mutating func keyPressed() -> Event? { interrupt() }

    /// Anything else that invalidates a capture (focus change, app quit).
    mutating func interrupt() -> Event? {
        downAt = nil
        guard holding else { return nil }
        holding = false
        return .cancel
    }
}

enum KeyCode {
    static let tab: Int64 = 48
    static let space: Int64 = 49
    static let escape: Int64 = 53
    static let returnKey: Int64 = 36
    static let keypadEnter: Int64 = 76
    static let z: Int64 = 6
    static let leftOption: Int64 = 58
    static let rightOption: Int64 = 61
    static let leftShift: Int64 = 56
    static let rightShift: Int64 = 60
    static let leftControl: Int64 = 59
    static let rightControl: Int64 = 62
    static let leftCommand: Int64 = 55
    static let rightCommand: Int64 = 54
}
