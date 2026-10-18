import AVFoundation
import CoreGraphics
import XCTest
@testable import Pretype

/// A host with a field, no caret and nothing else — all a latch needs to go
/// live. Records what was typed.
@MainActor
private final class FieldHost: DictationHost {
    private(set) var lastEvent = ""
    func report(_ event: String) { lastEvent = event }
    var typingContext = TypingContext()
    var focusGeneration = 0
    var focusIsInLauncher = false
    let isOwnUIFrontmost = false
    let isSecureInputActive = false
    var fallbackCaretRect: CGRect?
    var fallbackHostStyle = HostTextStyle()
    private(set) var inserted: [String] = []

    func dictationFocus() -> DictationFocus { .field }
    func isComposingInFocusedField() -> Bool { false }
    func prepareForDictation() {}
    func dictationAnchor() -> DictationAnchor? { nil }
    func noteCaret(rect: CGRect, host: HostTextStyle) {}
    func showOverlay(_ mode: SuggestionDisplayMode, at rect: CGRect, host: HostTextStyle) {}
    func showTransientOverlay(_ mode: SuggestionDisplayMode, at rect: CGRect, host: HostTextStyle) {}
    func hideOverlay() {}
    func insertDictated(_ text: String) { inserted.append(text) }
    func rescueDictated(_ text: String, because reason: DictationRescue) {}
    func applyVoiceCommand(_ instruction: String, to selection: String) {}
    func tidyDictation(_ text: String) async -> String? { nil }
    func prewarmTidy() {}
    func dictationBusyChanged() {}
}

/// The silence budget is re-read on every tick of a hands-free capture, not
/// remembered from its start: "Never" chosen mid-capture must mean never.
@MainActor
final class HandsFreeSilenceSettingTests: XCTestCase {
    private var saved: (enabled: Bool, dictation: Bool, polish: Bool, commands: Bool, silence: TimeInterval)?

    override func setUp() {
        super.setUp()
        saved = (Settings.enabled, Settings.dictationEnabled, Settings.dictationPolish,
                 Settings.dictationCommands, Settings.dictationSilence)
        Settings.enabled = true
        Settings.dictationEnabled = true
        Settings.dictationPolish = false
        Settings.dictationCommands = false
        Settings.dictationSilence = 5
    }

    override func tearDown() {
        if let saved {
            (Settings.enabled, Settings.dictationEnabled, Settings.dictationPolish,
             Settings.dictationCommands, Settings.dictationSilence) = saved
        }
        super.tearDown()
    }

    func testSilenceSwitchedToNeverMidCaptureNeverEndsIt() async throws {
        let host = FieldHost()
        let controller = DictationController(capture: SilentMicrophone())
        controller.owner = host
        controller.gates.micBundled = { true }
        controller.gates.micStatus = { .authorized }
        controller.gates.transcriptionSupported = { true }
        controller.gates.startSession = { _, _ in EmptySession() }
        let now = LockedValue(Date())
        controller.clock = { now.get() }

        controller.toggleLatch()
        await controller.sessionTask?.value
        XCTAssertEqual(controller.phase, .listening(""))
        let tick = try XCTUnwrap(controller.silenceTimer, "a 5 s budget arms the silence clock")

        Settings.dictationSilence = 0  // "Never", picked while the capture runs
        // Past the mid-sentence budget and the longer opening one alike.
        now.mutate { $0 += controller.openingSilenceSeconds + 60 }
        tick.fire()
        XCTAssertEqual(controller.phase, .listening(""), "\"Never\" must stop the clock, not end the take")
        XCTAssertTrue(host.inserted.isEmpty)
        controller.keyPressed(isEscape: true)
    }
}
