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
enum CloudTranscription {
    /// `previewEvery`, `retryAfter`: see `RecordedTranscription`.
    static func start(_ config: APIConfig, locale: Locale,
                      previewEvery: Duration = .seconds(1), retryAfter: Duration = .seconds(1),
                      onPartial: @escaping @Sendable (String) -> Void) throws -> TranscriptionSession {
        let endpoint = try config.endpoint()
        // "Follow keyboard" only guesses the language, and a wrong guess sends
        // Danish through an English decoder. A speech model hears it, so it
        // gets none. Refrain hears it only on Parakeet (the same FluidAudio
        // cache as ours): without it, no language means the system language.
        let hears = config.provider != "refrain" || Parakeet.isDownloaded && Parakeet.covers(locale)
        let language = Settings.dictationLanguage == "auto" && hears
            ? nil : locale.language.languageCode?.identifier
        // Names and terms from the field — the same spelling hints the
        // on-device analyzer gets.
        let hints = Transcription.contextualWords.get()
        // An upload is not a local finalization: a long take over a slow link
        // legitimately takes longer than the controller's ten seconds. The WAV
        // is 32 KB per audio second, ~0.26 s each over a 1 Mbit/s uplink.
        // Doubled: `finish` retries a failed upload once, so the watchdog
        // spans two full requests and the second's one-second wait. Past
        // both, the take is written down on this Mac instead (`uploads`).
        return RecordedTranscription(preview: config.isLocal, uploads: true, finishDeadline: 2 * 60,
                                     perAudioSecond: 2 * uploadPerSecond, previewEvery: previewEvery,
                                     retryAfter: retryAfter, onPartial: onPartial) { audio, final in
            // Under a tenth of a second is a key tap, not speech — and most
            // servers refuse a clip that short.
            guard audio.count >= 1_600 else { return "" }
            // The request gives up a little before the watchdog does.
            let timeout = final ? 55 + uploadPerSecond * Double(audio.count) / 16_000 : 10
            return try await APIClient.transcribe(endpoint, wav: wav(audio), language: language,
                                                  hints: hints, timeout: timeout)
        }
    }

    private static let uploadPerSecond: TimeInterval = 0.3

    /// 16 kHz 16-bit PCM WAV, mono — the one format every transcription API takes.
    static func wav(_ samples: [Float]) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { data.append(contentsOf: $0) } }
        data.append(Data("RIFF".utf8)); u32(36 + samples.count * 2)
        data.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(16_000); u32(16_000 * 2); u16(2); u16(16)
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
            return String(localized: "✓ Connected — answered in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        } catch {
            return "⚠︎ \(error.localizedDescription)"
        }
    }
}
