import CoreAudio
import XCTest
@testable import Pretype

final class AudioDevicesTests: XCTestCase {
    /// Which microphone a capture opens. The rule exists because a Bluetooth
    /// headset carries good playback OR a two-way call, never both: opening the
    /// AirPods microphone drops whatever is playing into hands-free quality for
    /// the length of the hold. Reported from real use as "the music goes dull
    /// while I dictate".
    func testAutomaticInputAvoidsTheHeadsetItIsPlayingThrough() {
        // Exactly the shape of the reporting machine: macOS publishes AirPods
        // as two objects whose UIDs share everything before the colon.
        let builtIn = AudioDevices.Device(uid: "BuiltInMicrophoneDevice",
                                          name: "MacBook Pro Microphone",
                                          transport: kAudioDeviceTransportTypeBuiltIn)
        let podsIn = AudioDevices.Device(uid: "F8-D3-F0-79-64-02:input",
                                         name: "AirPods Pro",
                                         transport: kAudioDeviceTransportTypeBluetooth)
        let podsOut = AudioDevices.Device(uid: "F8-D3-F0-79-64-02:output",
                                          name: "AirPods Pro",
                                          transport: kAudioDeviceTransportTypeBluetooth)
        let usbMic = AudioDevices.Device(uid: "USB-Yeti", name: "Yeti",
                                         transport: kAudioDeviceTransportTypeUSB)
        let speakers = AudioDevices.Device(uid: "BuiltInSpeakerDevice",
                                           name: "MacBook Pro Speakers",
                                           transport: kAudioDeviceTransportTypeBuiltIn)
        let inputs = [builtIn, podsIn, usbMic]

        func auto(_ input: AudioDevices.Device?, _ output: AudioDevices.Device?) -> AudioDevices.Device? {
            AudioDevices.resolve(preference: .automatic, inputs: inputs,
                                 defaultInput: input, defaultOutput: output)
        }
        // Listening through the same headset you'd record from: step aside.
        XCTAssertEqual(auto(podsIn, podsOut), builtIn)
        // Same headset for the microphone but sound coming out of the speakers:
        // nothing to protect, record where the user pointed us.
        XCTAssertEqual(auto(podsIn, speakers), podsIn)
        // A wired microphone never had this problem.
        XCTAssertEqual(auto(usbMic, podsOut), usbMic)
        XCTAssertEqual(auto(builtIn, podsOut), builtIn)

        // An explicit pick always wins — including picking the headset back.
        XCTAssertEqual(
            AudioDevices.resolve(preference: .device(uid: podsIn.uid), inputs: inputs,
                                 defaultInput: podsIn, defaultOutput: podsOut),
            podsIn)
        XCTAssertEqual(
            AudioDevices.resolve(preference: .systemDefault, inputs: inputs,
                                 defaultInput: podsIn, defaultOutput: podsOut),
            podsIn)
        // A pinned device that is unplugged right now falls back rather than
        // refusing to record.
        XCTAssertEqual(
            AudioDevices.resolve(preference: .device(uid: "gone"), inputs: inputs,
                                 defaultInput: podsIn, defaultOutput: podsOut),
            podsIn)
        // The stored form parses, and an empty default reads as automatic.
        XCTAssertEqual(AudioDevices.Preference(stored: ""), .automatic)
        XCTAssertEqual(AudioDevices.Preference(stored: "auto"), .automatic)
        XCTAssertEqual(AudioDevices.Preference(stored: podsIn.uid), .device(uid: podsIn.uid))
    }
}
