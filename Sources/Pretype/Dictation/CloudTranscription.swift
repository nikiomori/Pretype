import AVFoundation
import Foundation

/// Dictation on a hosted speech model (Settings → API): audio accumulates in
/// memory, and `finish()` uploads the whole take as one WAV. A hosted model
/// gets no live preview — re-sending the take every second would bill it over
/// and over. A server on this Mac (Refrain, a whisper server) costs nothing per
/// request, so it gets the preview the on-device Parakeet has: the take so
/// far, re-sent about once a second.
/// ponytail: one upload per take; 16 kHz 16-bit mono is ~1.9 MB a minute, so
/// a take past ~13 minutes hits OpenAI's 25 MB limit (the latch ceiling is 10).
/// The local preview re-sends the whole take, as Parakeet's does: ~2 MB a
/// refresh at the 10-minute latch, still well under a second on loopback.
final class CloudTranscription: TranscriptionSession, @unchecked Sendable {
    let audioFormat: AVAudioFormat? = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)

    private let endpoint: APIEndpoint
    private let language: String?
    /// Names and terms from the field — the same spelling hints the
    /// on-device analyzer gets.
    private let hints = Transcription.contextualWords.get()
    private let samples = LockedValue<[Float]>([])
    private let preview = LockedValue<Task<Void, Never>?>(nil)

    init(_ config: APIConfig, locale: Locale, onPartial: @escaping @Sendable (String) -> Void) throws {
        endpoint = try config.endpoint()
        language = locale.language.languageCode?.identifier
        guard config.isLocal else { return }
        preview.set(Task { [samples, endpoint, language, hints] in
            var previewed = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let audio = samples.get()
                // Half a second of new audio, or the pill would repaint the same guess.
                guard audio.count >= previewed + 8_000 else { continue }
                previewed = audio.count
                if let text = try? await APIClient.transcribe(endpoint, wav: Self.wav(audio), language: language,
                                                              hints: hints, timeout: 10),
                   !Task.isCancelled {
                    onPartial(text)
                }
            }
        })
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let chunk = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        samples.mutate { $0.append(contentsOf: chunk) }
    }

    func finish() async throws -> String {
        if let task = preview.exchange(nil) {
            task.cancel()
            await task.value  // a preview in flight is cancelled with it, not waited out
        }
        let audio = samples.exchange([])
        // Under a tenth of a second is a key tap, not speech — and most
        // servers refuse a clip that short.
        guard audio.count >= 1_600 else { return "" }
        return try await APIClient.transcribe(endpoint, wav: Self.wav(audio), language: language,
                                              hints: hints, timeout: 55)
    }

    func cancel() {
        preview.exchange(nil)?.cancel()
        samples.set([])
    }

    /// 16-bit PCM WAV, mono — the one format every transcription API takes.
    static func wav(_ samples: [Float], sampleRate: Int = 16_000) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { data.append(contentsOf: $0) } }
        data.append(Data("RIFF".utf8)); u32(36 + samples.count * 2)
        data.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        data.append(Data("data".utf8)); u32(samples.count * 2)
        let pcm = samples.map { Int16(max(-1, min(1, $0)) * 32767).littleEndian }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    /// The Settings "Test" button: half a second of silence, timed. Any
    /// answer at all — an empty transcript included — proves key, URL and model.
    static func test(_ config: APIConfig) async -> String {
        let start = Date()
        do {
            _ = try await APIClient.transcribe(try config.endpoint(), wav: wav([Float](repeating: 0, count: 8_000)),
                                               language: nil, timeout: 30)
            return "✓ Connected — answered in \(Int(Date().timeIntervalSince(start) * 1000)) ms"
        } catch {
            return "⚠︎ \(error.localizedDescription)"
        }
    }
}
