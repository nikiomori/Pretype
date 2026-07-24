import AppKit
import CoreGraphics

/// CGEvent tap on key-down events. The handler returns `true` to swallow
/// the event (used to consume Tab while a suggestion is visible).
final class KeyTap {
    var handler: ((CGEvent) -> Bool)?
    /// Modifier presses/releases, observed only — never swallowed. Feeds the
    /// double-⌥ gesture; a modifier the user pressed must always reach the app.
    var flagsHandler: ((CGEvent) -> Void)?

    private var tapPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var isActive: Bool { tapPort != nil }

    func start() {
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
            // Down. Already holding another modifier means a chord is being built.
            let others = CGEventFlags([.maskCommand, .maskControl, .maskAlternate, .maskShift])
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
