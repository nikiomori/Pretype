import AVFoundation
import Foundation
import Speech

/// One dictation session: audio in, text out.
///
/// A protocol, not a concrete type, so `DictationController` doesn't have to be
/// version-gated: Apple's `SpeechAnalyzer` (macOS 26) is the only implementation
/// today, and a bundled Whisper/Parakeet engine for macOS 14–15 would slot in
/// here without the controller noticing.
protocol TranscriptionSession: AnyObject, Sendable {
    /// The format the session wants its audio in — nil accepts the device's own.
    var audioFormat: AVAudioFormat? { get }
    /// Hand over one buffer of microphone audio. Called from the audio thread.
    func feed(_ buffer: AVAudioPCMBuffer)
    /// Stop, flush, and return the finished transcript.
    func finish() async throws -> String
    /// Abandon the session — nothing is transcribed and nothing is returned.
    func cancel()
}

enum TranscriptionError: LocalizedError {
    /// Below macOS 26 there is no on-device transcriber to talk to.
    case unsupportedSystem
    /// Neither speech model has this language.
    case unsupportedLanguage(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSystem:
            return "dictation needs macOS 26 or later"
        case .unsupportedLanguage(let name):
            return "macOS can't dictate \(name)"
        }
    }
}

/// Entry point to on-device speech recognition, version-gating Apple's Speech
/// framework in one place.
///
/// Nothing here ships a model: both transcribers use the system's own dictation
/// assets, downloaded by macOS on demand and shared with every other app that
/// asks for the same language. That is the whole reason this path beats
/// bundling Whisper — zero bytes in the app, zero bytes in the repo, and the
/// language packs a user already has cost nothing to reuse.
///
/// **Two models, not one.** `SpeechTranscriber` is the new, better one, and it
/// covers exactly 30 locales — English, German, Spanish, French, Italian,
/// Japanese, Korean, Portuguese, Cantonese and Chinese. Everything else,
/// **Russian included**, is served by `DictationTranscriber`: the model behind
/// the system's own dictation key, older but real. Picking between them is this
/// file's main job, and it is why `supportedLocale(equivalentTo:)` is never used
/// as a support test — it canonicalizes an identifier ("ru" → "ru_RU") whether
/// or not the model exists, which reads as support and then fails at load.
enum Transcription {
    /// Whether this Mac can transcribe at all (OS version + hardware support).
    static var isSupported: Bool {
        guard #available(macOS 26.0, *) else { return false }
        return SpeechTranscriber.isAvailable
    }

    /// Every language either model can handle, deduplicated — what the settings
    /// picker offers.
    static func supportedLocales() async -> [Locale] {
        guard #available(macOS 26.0, *) else { return [] }
        var seen = Set<String>()
        var result: [Locale] = []
        for locale in await SpeechTranscriber.supportedLocales
            + DictationTranscriber.supportedLocales where seen.insert(locale.identifier).inserted {
            result.append(locale)
        }
        return result
    }

    /// The transcriber's own identifier for `locale` and which model will serve
    /// it, or nil when neither can. The membership test is the point: a match
    /// here is the only honest answer to "can this Mac dictate Russian".
    @available(macOS 26.0, *)
    static func resolve(_ locale: Locale) async -> (locale: Locale, preferred: Bool)? {
        if let canonical = await SpeechTranscriber.supportedLocale(equivalentTo: locale),
           await SpeechTranscriber.supportedLocales.contains(where: { $0.identifier == canonical.identifier }) {
            return (canonical, true)
        }
        if let canonical = await DictationTranscriber.supportedLocale(equivalentTo: locale),
           await DictationTranscriber.supportedLocales.contains(where: { $0.identifier == canonical.identifier }) {
            return (canonical, false)
        }
        return nil
    }

    /// Which model would serve a language — what the settings surface says out
    /// loud, so nobody discovers "macOS can't dictate this" by holding a key
    /// and getting silence.
    enum LanguageSupport {
        /// The newer, better `SpeechTranscriber` (30 locales).
        case preferred
        /// `DictationTranscriber`, the system dictation model — Russian and
        /// most other languages land here.
        case fallback
        case unsupported
    }

    static func support(for locale: Locale) async -> LanguageSupport {
        guard #available(macOS 26.0, *), let resolved = await resolve(locale) else {
            return .unsupported
        }
        return resolved.preferred ? .preferred : .fallback
    }

    /// Human-readable name of `locale`, for messages the user reads.
    static func name(of locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier)
            ?? Locale.current.localizedString(forLanguageCode: locale.identifier)
            ?? locale.identifier
    }

    /// Open a session for `locale`, downloading the language pack if macOS
    /// doesn't have it yet (slow exactly once per language).
    static func start(locale: Locale,
                      onPartial: @escaping @Sendable (String) -> Void) async throws -> TranscriptionSession {
        guard #available(macOS 26.0, *) else { throw TranscriptionError.unsupportedSystem }
        guard let resolved = await resolve(locale) else {
            throw TranscriptionError.unsupportedLanguage(name(of: locale))
        }
        if resolved.preferred {
            // `.volatileResults` is what makes the live preview possible: the
            // transcriber re-emits its best guess as you speak and finalizes a
            // span only once it stops changing. Without it nothing appears
            // until the key comes up, which reads as a hang on a long sentence.
            let module = SpeechTranscriber(
                locale: resolved.locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                attributeOptions: [])
            try await install(module, locale: resolved.locale)
            return try await SystemTranscription(
                module: module, text: { String($0.text.characters) }, onPartial: onPartial)
        }
        // The older model writes no punctuation of its own unless asked —
        // and a dictation that arrives as one unbroken clause is exactly what
        // makes speech-to-text feel like a toy.
        let module = DictationTranscriber(
            locale: resolved.locale,
            contentHints: [],
            transcriptionOptions: [.punctuation],
            reportingOptions: [.volatileResults],
            attributeOptions: [])
        try await install(module, locale: resolved.locale)
        return try await SystemTranscription(
            module: module, text: { String($0.text.characters) }, onPartial: onPartial)
    }

    @available(macOS 26.0, *)
    private static func install(_ module: any SpeechModule, locale: Locale) async throws {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            DebugLog.shared.log("DICTATE", "downloading the \(name(of: locale)) speech model…")
            try await request.downloadAndInstall()
        }
        // Installed is not enough: macOS also wants the locale *allocated* to
        // this app before the analyzer will load its model
        // (`assetLocaleNotAllocated`). The pool is small
        // (`maximumReservedLocales`) and reservations OUTLIVE the session — so
        // without the release pass below, "follow keyboard" hands a slot to
        // every language ever dictated until the cap is hit, after which every
        // NEW language fails at load forever. A slot already ours is kept as
        // is; a full pool frees the languages no longer being spoken and asks
        // once more. Still-failing stays logged rather than fatal — the load
        // failure it may cause is reported at the caret with a message the
        // user can act on.
        do {
            let reserved = await AssetInventory.reservedLocales
            guard !reserved.contains(where: { $0.identifier == locale.identifier }) else { return }
            do {
                _ = try await AssetInventory.reserve(locale: locale)
            } catch {
                for stale in reserved {
                    _ = await AssetInventory.release(reservedLocale: stale)
                    DebugLog.shared.log(
                        "DICTATE", "released the \(stale.identifier) speech-model slot to make room")
                }
                _ = try await AssetInventory.reserve(locale: locale)
            }
        } catch {
            DebugLog.shared.log(
                "DICTATE", "could not reserve \(locale.identifier): \(error.localizedDescription)")
        }
    }
}

/// `SpeechAnalyzer` driven as a live session: microphone buffers go in through
/// an `AsyncStream`, results come back on a collector task, and `finish()`
/// closes the stream and waits for the analyzer to finalize what was in flight.
///
/// Generic over the module so the two transcribers — whose `Result` types are
/// unrelated apart from `isFinal` — share one implementation; `text` pulls the
/// words out of whichever one this is.
@available(macOS 26.0, *)
private final class SystemTranscription<Module: SpeechModule>: TranscriptionSession, @unchecked Sendable {
    let audioFormat: AVAudioFormat?

    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let collector: Task<String, Error>

    init(module: Module,
         text: @escaping @Sendable (Module.Result) -> String,
         onPartial: @escaping @Sendable (String) -> Void) async throws {
        analyzer = SpeechAnalyzer(modules: [module])
        // The module's own first choice, falling back to anything it accepts.
        // Handing it the microphone's raw format instead (48 kHz stereo) is how
        // you get `unexpectedAudioFormat` on the first buffer.
        if let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) {
            audioFormat = best
        } else {
            audioFormat = await module.availableCompatibleAudioFormats.first
        }

        // Started BEFORE the analyzer: results that arrive between `start` and
        // the first iteration are buffered by the sequence, but a collector
        // spun up later has no claim on the module and would miss the
        // finalization race on a very short utterance.
        collector = Task {
            var finalized = ""
            for try await result in module.results {
                let words = text(result)
                if result.isFinal {
                    finalized += words
                    // Repaint on finalization too: a span that finalizes emits
                    // no volatile result, so without this the pill sits on the
                    // stale previous guess until the NEXT volatile arrives —
                    // mid-pause, exactly when the speaker looks at it.
                    onPartial(finalized)
                } else {
                    onPartial(finalized + words)
                }
            }
            return finalized
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        input = continuation
        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            continuation.finish()
            collector.cancel()
            throw error
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        input.yield(AnalyzerInput(buffer: buffer))
    }

    func finish() async throws -> String {
        input.finish()
        // Finalizes the tail of the audio already handed over — without it the
        // last word or two never leaves the volatile state and is simply lost.
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collector.value
    }

    func cancel() {
        input.finish()
        collector.cancel()
        let analyzer = analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }
}
