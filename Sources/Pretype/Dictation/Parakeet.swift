import AVFoundation
import FluidAudio
import Foundation

/// NVIDIA's Parakeet TDT v3 (0.6B, CoreML on the Neural Engine via FluidAudio)
/// for the languages Apple serves only with its older `DictationTranscriber` —
/// Russian, Ukrainian, Polish, Czech and the rest of v3's European set.
///
/// Measured on FLEURS-ru (200 rows, `Eval/asr`): words-only WER 12.6 → 6.6,
/// as-typed WER 30.1 → 14.2, punctuation F1 0.02 → 0.85, median 194 → 59 ms
/// per utterance. On English it only ties `SpeechTranscriber` (WER 6.6 vs 7.8,
/// CIs overlap), so the 30 locales Apple's newer model covers stay on it.
/// Opt-in (`Settings.dictationParakeet`): the model is a one-time ~470 MB
/// download, and turning the setting on is the consent for it.
enum Parakeet {
    /// The 25 languages v3 was trained on.
    static let languages: Set<String> = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
        "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
    ]

    static func covers(_ locale: Locale) -> Bool {
        locale.language.languageCode.map { languages.contains($0.identifier) } ?? false
    }

    static var isDownloaded: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
    }

    /// Download (once) and load (once per launch). Also what the settings
    /// toggle calls, so the first dictation after opting in doesn't wait.
    static func prepare() async throws -> AsrManager {
        try await loader.manager()
    }

    static func start(locale: Locale,
                      onPartial: @escaping @Sendable (String) -> Void) async throws -> TranscriptionSession {
        let manager = try await prepare()
        let language = locale.language.languageCode.flatMap { Language(rawValue: $0.identifier) }
        return ParakeetTranscription(manager: manager, language: language, onPartial: onPartial)
    }

    private static let loader = Loader()

    /// Single-flight: a dictation started while the settings toggle's prefetch
    /// is still downloading joins it instead of starting a second download.
    /// Kept loaded for the app's lifetime — ~70 MB resident (the weights sit on
    /// the Neural Engine side), far less than the LLM next to it.
    private actor Loader {
        private var loading: Task<AsrManager, Error>?

        func manager() async throws -> AsrManager {
            let task = loading ?? Task {
                if !Parakeet.isDownloaded {
                    DebugLog.shared.log("DICTATE", "downloading the Parakeet speech model…")
                    Transcription.isDownloading.set(true)
                    defer { Transcription.isDownloading.set(false) }
                    try await AsrModels.download(version: .v3)
                }
                let models = try await AsrModels.load(from: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                return manager
            }
            loading = task
            do {
                return try await task.value
            } catch {
                loading = nil  // a failed download or load is retried next time
                throw error
            }
        }
    }
}

/// Parakeet is an offline model: audio accumulates, and `finish()` transcribes
/// the whole take in one pass. The live preview re-transcribes everything heard
/// so far about once a second.
/// ponytail: whole-take re-transcription, ~6 ms per audio second on the ANE —
/// a ten-minute latch costs ~4 s a refresh; FluidAudio's SlidingWindowAsrManager
/// if long takes ever matter.
private final class ParakeetTranscription: TranscriptionSession, @unchecked Sendable {
    let audioFormat: AVAudioFormat? = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)

    private let manager: AsrManager
    private let language: Language?
    private let samples = LockedValue<[Float]>([])
    private let preview = LockedValue<Task<Void, Never>?>(nil)

    init(manager: AsrManager, language: Language?, onPartial: @escaping @Sendable (String) -> Void) {
        self.manager = manager
        self.language = language
        preview.set(Task { [samples] in
            var previewed = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let audio = samples.get()
                // Half a second of new audio, or the pill would repaint the same guess.
                guard audio.count >= previewed + 8_000 else { continue }
                previewed = audio.count
                if let text = try? await Self.transcribe(audio, manager: manager, language: language),
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
            await task.value  // one model call at a time
        }
        let audio = samples.get()
        guard !audio.isEmpty else { return "" }
        return try await Self.transcribe(audio, manager: manager, language: language)
    }

    func cancel() {
        preview.exchange(nil)?.cancel()
        samples.set([])
    }

    private static func transcribe(_ audio: [Float], manager: AsrManager,
                                   language: Language?) async throws -> String {
        // The model refuses a clip under its minimum; a one-word "да" padded
        // with silence transcribes fine.
        var audio = audio
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: 16_000)
        if audio.count < minimum { audio += [Float](repeating: 0, count: minimum - audio.count) }
        var state = TdtDecoderState.make()
        return try await manager.transcribe(audio, decoderState: &state, language: language).text
    }
}
