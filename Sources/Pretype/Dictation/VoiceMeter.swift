import Accelerate
import AVFoundation
import os

/// Voice activity for one capture: written on the audio delivery queue, read
/// from the main actor, which is the whole reason it is a class with a lock
/// rather than a couple of fields on the controller.
///
/// Deliberately not a neural detector. The only question asked of it is "has
/// anything been said in the last few seconds", and it is asked in order to
/// decide whether to KEEP a capture alive — an asymmetric question. A frame
/// wrongly called speech costs a few more seconds of a capture the user can end
/// with the same chord that started it; a frame wrongly called silence cuts
/// somebody off mid-sentence. So the bar sits where speech clears it
/// comfortably, and the floor is learned rather than configured: a fanless
/// laptop in a quiet flat, a desk fan and a café all sit at different levels,
/// and none of them should be a setting the user has to find.
///
/// The floor only ever learns from frames it judged quiet. Averaging speech
/// into it is the classic way these drift — the floor climbs toward the talker,
/// the margin closes, and a long sentence reads as silence right when it
/// matters most.
final class VoiceMeter: Sendable {
    /// How far over the learned floor a frame must sit to count as speech.
    private static let marginDB: Float = 10
    /// An absolute bar under that, so a near-silent digital input — whose floor
    /// would otherwise learn its way down to the noise of the last bit — can't
    /// promote its own dither to speech.
    private static let absoluteDB: Float = -60
    /// How fast the floor follows the room. One buffer is a few tens of
    /// milliseconds, so this settles within about a second of the microphone
    /// opening and still tracks a fan that starts up mid-capture.
    private static let floorRate: Float = 0.05
    /// The floor is held inside this band whatever it is fed. The bottom stops
    /// a device that opens on digital silence (a warming USB microphone, a
    /// hardware-muted headset, the first frames after `startRunning`) from
    /// dragging the floor to −95 on a handful of all-zero buffers, which would
    /// leave ordinary room tone permanently clearing the bar. The top keeps a
    /// recalibration from a very loud room out of the range where speech itself
    /// would fail to clear it.
    private static let floorRange: ClosedRange<Float> = -65 ... -30
    /// A stretch with no quiet frame in it at all is itself a measurement —
    /// see `feed`.
    private static let recalibrateAfter: TimeInterval = 6

    private struct State {
        /// Starts pessimistically high: until the room has been measured, the
        /// margin above it is what keeps a noisy office from reading as speech
        /// on the very first buffer.
        var floorDB: Float = -50
        var lastVoiceAt: Date?
        var openedAt: Date
        /// The quietest thing heard since the last frame judged quiet, and when
        /// that was. Only used by the recalibration below.
        var quietestSinceQuiet: Float = .greatestFiniteMagnitude
        var lastQuietAt: Date
    }

    private let state: OSAllocatedUnfairLock<State>

    init(now: Date = Date()) {
        state = OSAllocatedUnfairLock(initialState: State(openedAt: now, lastQuietAt: now))
    }

    /// One delivered buffer. Runs on the capture's delivery queue.
    func feed(_ buffer: AVAudioPCMBuffer, now: Date = Date()) {
        let db = Self.decibels(buffer)
        state.withLock { state in
            guard db > state.floorDB + Self.marginDB, db > Self.absoluteDB else {
                // Quiet: this is the room, and the only thing the floor learns
                // from. Averaging speech in is how these estimators go deaf —
                // the floor climbs toward the talker, the margin closes, and a
                // long sentence reads as silence exactly when it matters.
                state.floorDB = min(max(state.floorDB + Self.floorRate * (db - state.floorDB),
                                        Self.floorRange.lowerBound),
                                    Self.floorRange.upperBound)
                state.lastQuietAt = now
                state.quietestSinceQuiet = .greatestFiniteMagnitude
                return
            }
            state.lastVoiceAt = now
            state.quietestSinceQuiet = min(state.quietestSinceQuiet, db)
            // ...but a room that is never quiet never gets measured at all. A
            // café, a desk fan, a microphone with the gain wound up: the very
            // first buffer clears the starting floor, so nothing ever takes the
            // branch above, the floor stays where it began, and every frame for
            // the rest of the capture reads as speech — which quietly turns the
            // silence auto-stop off altogether. So a long stretch without a
            // single quiet frame is itself the measurement: the quietest thing
            // in it is the room. Real speech never gets here — the stops
            // between words are quiet frames, and any one of them resets this.
            guard now.timeIntervalSince(state.lastQuietAt) >= Self.recalibrateAfter else { return }
            state.floorDB = min(max(state.quietestSinceQuiet, Self.floorRange.lowerBound),
                                Self.floorRange.upperBound)
            state.lastQuietAt = now
            state.quietestSinceQuiet = .greatestFiniteMagnitude
        }
    }

    /// The transcript grew — the analyzer heard words, whatever the level said.
    func noteVoice(now: Date = Date()) {
        state.withLock { $0.lastVoiceAt = now }
    }

    /// Restamp the clock to the moment the microphone actually opened.
    ///
    /// The meter has to be built before `capture.start` — the delivery closure
    /// captures it — but `begin` can be a whole language-pack download away
    /// from the first buffer, and the pre-first-word silence budget measured
    /// from there is spent on a wait nobody could have spoken into. Long
    /// enough, and the first check after the microphone opened would end the
    /// capture as "nothing heard" before the user got a word in.
    func opened(now: Date) {
        state.withLock { state in
            state.openedAt = now
            state.lastQuietAt = now
        }
    }

    /// Anything at all has been heard since the microphone opened. Splits the
    /// two silence budgets apart — see `DictationController.checkSilence`.
    var heardVoice: Bool { state.withLock { $0.lastVoiceAt != nil } }

    /// How long since the last voiced frame, or since the microphone opened if
    /// there has never been one.
    func quietFor(now: Date = Date()) -> TimeInterval {
        state.withLock { now.timeIntervalSince($0.lastVoiceAt ?? $0.openedAt) }
    }

    /// RMS of one buffer as dBFS.
    ///
    /// An unreadable layout returns 0 dB — full scale, unconditionally voiced.
    /// The failure mode to avoid is a silence clock running blind on a format
    /// it cannot measure and ending captures that were going fine; a capture
    /// that never auto-stops still has its chord and its ceiling.
    nonisolated static func decibels(_ buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return -120 }
        let rms: Float
        if let channel = buffer.floatChannelData?[0] {
            rms = vDSP.rootMeanSquare(UnsafeBufferPointer(start: channel, count: frames))
        } else if let channel = buffer.int16ChannelData?[0] {
            let samples = UnsafeBufferPointer(start: channel, count: frames)
            rms = vDSP.rootMeanSquare(vDSP.integerToFloatingPoint(samples, floatingPointType: Float.self)) / 32768
        } else {
            return 0
        }
        guard rms > 0 else { return -120 }
        return 20 * log10(rms)
    }
}
