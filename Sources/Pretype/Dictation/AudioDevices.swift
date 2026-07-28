import CoreAudio
import Foundation

/// The input devices a capture can open, and which one it should.
///
/// This exists for one measured reason: **opening a Bluetooth headset's
/// microphone takes its speakers down with it.** A headset can carry either
/// high-quality playback or a two-way call, never both, so the moment anything
/// opens the AirPods microphone macOS switches the whole device into hands-free
/// mode — mono, narrow-band, audibly quieter — and switches back a second after
/// the microphone closes. Reported from real use as "the music goes dull while
/// I dictate", and it is not something the capture can hold off: it is the
/// price of using that microphone at all.
///
/// So don't use it. When the default input and the default output are the same
/// headset, dictation opens the built-in microphone instead and the headset
/// never leaves music mode. Nothing else about the capture changes — the
/// transcriber gets the same resampled buffers from whichever device fed them.
enum AudioDevices {
    struct Device: Equatable {
        var id: AudioDeviceID
        var uid: String
        var name: String
        var transport: UInt32

        var isBluetooth: Bool {
            transport == kAudioDeviceTransportTypeBluetooth
                || transport == kAudioDeviceTransportTypeBluetoothLE
        }
        var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }

        /// The physical device behind this endpoint. macOS publishes a headset
        /// as two separate audio objects whose UIDs differ only in a trailing
        /// direction suffix — `F8-D3-F0-79-64-02:input` and `…:output` are one
        /// pair of AirPods — which is the only honest way to tell "the thing I
        /// would be recording from is the thing that is playing". Only that
        /// known suffix comes off: USB UIDs carry colons of their own
        /// (`AppleUSBAudioEngine:vendor:product:serial`), so cutting at the
        /// first colon made every USB device read as the same hardware.
        var hardwareUID: String {
            for suffix in [":input", ":output"] where uid.hasSuffix(suffix) {
                return String(uid.dropLast(suffix.count))
            }
            return uid
        }
    }

    /// What the user picked in Settings. Stored as a string so an unplugged
    /// device's identifier survives in the preference until it comes back.
    enum Preference: Equatable {
        /// Keep a Bluetooth headset out of call mode; otherwise the system default.
        case automatic
        /// Whatever macOS calls the default input, always.
        case systemDefault
        case device(uid: String)

        init(stored: String) {
            switch stored {
            case "", "auto": self = .automatic
            case "system": self = .systemDefault
            default: self = .device(uid: stored)
            }
        }

        var stored: String {
            switch self {
            case .automatic: return "auto"
            case .systemDefault: return "system"
            case .device(let uid): return uid
            }
        }
    }

    /// Which device a capture should open, or nil to accept whatever the engine
    /// defaults to. Pure, so the rule is a unit test rather than a thing you
    /// discover by pairing a headset.
    static func resolve(preference: Preference, inputs: [Device],
                        defaultInput: Device?, defaultOutput: Device?) -> Device? {
        switch preference {
        case .systemDefault:
            return defaultInput
        case .device(let uid):
            // A pinned device that is currently unplugged falls back rather
            // than refusing to record: the preference stays, this capture uses
            // whatever is here.
            return inputs.first { $0.uid == uid } ?? defaultInput
        case .automatic:
            guard let defaultInput, defaultInput.isBluetooth,
                  let defaultOutput, defaultOutput.hardwareUID == defaultInput.hardwareUID,
                  let builtIn = inputs.first(where: \.isBuiltIn) else { return defaultInput }
            return builtIn
        }
    }

    /// Why the automatic rule chose what it chose — one line for the Settings
    /// caption and the Diagnostics menu, so the substitution is never a
    /// surprise ("I picked AirPods in System Settings, why is it recording from
    /// the laptop").
    static func automaticExplanation(defaultInput: Device?, defaultOutput: Device?,
                                     chosen: Device?) -> String? {
        guard let defaultInput, let chosen, chosen.uid != defaultInput.uid else { return nil }
        _ = defaultOutput
        return "\(defaultInput.name) is playing your audio too — recording from it would drop "
            + "it into call quality, so dictation uses \(chosen.name)."
    }

    // MARK: - CoreAudio

    static func inputs() -> [Device] {
        all().filter { channels(of: $0.id, scope: kAudioObjectPropertyScopeInput) > 0 }
    }

    static func defaultInput() -> Device? {
        device(id: defaultDeviceID(kAudioHardwarePropertyDefaultInputDevice))
    }

    static func defaultOutput() -> Device? {
        device(id: defaultDeviceID(kAudioHardwarePropertyDefaultOutputDevice))
    }

    /// The device a capture should open right now, resolved from the setting.
    static func current(preference: Preference) -> Device? {
        resolve(preference: preference, inputs: inputs(),
                defaultInput: defaultInput(), defaultOutput: defaultOutput())
    }

    /// Human-readable name for a device the engine reports back — used to say,
    /// in the log, which microphone a capture ACTUALLY opened.
    static func name(of id: AudioDeviceID) -> String {
        device(id: id).map(\.name) ?? "unknown(\(id))"
    }

    /// One line about what the user is listening through: device, volume, and
    /// whether anything is driving it. Logged on both sides of a capture, so
    /// "the sound changed and stayed changed" is a pair of numbers in the log
    /// rather than a thing the user has to catch in the act. Numbers and a
    /// device name only — no audio, nothing private.
    static func outputStateLine() -> String {
        let id = defaultDeviceID(kAudioHardwarePropertyDefaultOutputDevice)
        guard id != kAudioObjectUnknown else { return "no default output" }
        let volume = outputVolume(of: id)
        return "\(name(of: id)) vol="
            + (volume < 0 ? "n/a" : String(format: "%.3f", volume))
            + " running=\(isRunning(id) ? "yes" : "no")"
    }

    /// Scalar output volume, per-channel aware.
    ///
    /// The size argument MUST be reset before each attempt: a failed read
    /// clobbers it, so a fallback reusing it fails for the wrong reason. That
    /// exact bug (in a throwaway probe, not here) produced a confident and
    /// completely wrong reading of "this device has no volume control at all".
    static func outputVolume(of id: AudioDeviceID) -> Float {
        for element in [kAudioObjectPropertyElementMain, UInt32(1), UInt32(2)] {
            var address = property(kAudioDevicePropertyVolumeScalar,
                                   scope: kAudioObjectPropertyScopeOutput)
            address.mElement = element
            var value: Float32 = -1
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr {
                return value
            }
        }
        return -1
    }

    static func isRunning(_ id: AudioDeviceID) -> Bool {
        var address = property(kAudioDevicePropertyDeviceIsRunningSomewhere)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return value != 0
    }

    private static func all() -> [Device] {
        var address = property(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard !ids.isEmpty, AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { device(id: $0) }
    }

    private static func device(id: AudioDeviceID) -> Device? {
        guard id != kAudioObjectUnknown,
              let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        return Device(id: id, uid: uid,
                      name: string(id, kAudioObjectPropertyName) ?? uid,
                      transport: uint32(id, kAudioDevicePropertyTransportType))
    }

    private static func property(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultDeviceID(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var address = property(selector)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                   &address, 0, nil, &size, &id)
        return id
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = property(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func uint32(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = property(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return value
    }

    /// Channel count in one scope — how an input device is told from an output
    /// one, since a device object exists for both directions either way.
    private static func channels(of id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = property(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
