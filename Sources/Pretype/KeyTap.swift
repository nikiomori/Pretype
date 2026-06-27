import AppKit
import CoreGraphics

/// CGEvent tap on key-down events. The handler returns `true` to swallow
/// the event (used to consume Tab while a suggestion is visible).
final class KeyTap {
    var handler: ((CGEvent) -> Bool)?

    private var tapPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var isActive: Bool { tapPort != nil }

    func start() {
        guard tapPort == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
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

enum KeyCode {
    static let tab: Int64 = 48
    static let space: Int64 = 49
    static let escape: Int64 = 53
    static let returnKey: Int64 = 36
    static let keypadEnter: Int64 = 76
    static let z: Int64 = 6
}
