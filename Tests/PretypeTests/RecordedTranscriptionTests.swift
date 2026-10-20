import AVFoundation
import XCTest
@testable import Pretype

/// The preview loop's wait, stepped by hand: each pass parks in `tick` until
/// `step()`, and `parked` counts the waits begun — once it rises, the pass
/// before it has run to the end. A cancelled wait ends, as a sleep would.
private final class PreviewClock: Sendable {
    private let waits = LockedValue<[AsyncStream<Never>.Continuation]>([])
    let parked = LockedValue(0)

    func tick() async {
        let (stream, continuation) = AsyncStream<Never>.makeStream()
        waits.mutate { $0.append(continuation) }
        parked.mutate { $0 += 1 }
        for await _ in stream {}
    }

    func step() { waits.mutate { $0.removeFirst() }.finish() }
}

/// Answers every upload with one transcript, and counts them.
private final class UploadCounter: URLProtocol {
    static let uploads = LockedValue(0)

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.uploads.mutate { $0 += 1 }
        guard let url = request.url,
              let reply = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: reply, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"text":"hi"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Keeps every buffer it is fed, in the format it asks for.
private final class BufferSink: TranscriptionSession, @unchecked Sendable {
    let audioFormat: AVAudioFormat?
    private(set) var buffers: [AVAudioPCMBuffer] = []

    init(format: AVAudioFormat?) { audioFormat = format }
    func feed(_ buffer: AVAudioPCMBuffer) { buffers.append(buffer) }
    func finish() async throws -> String { "" }
    func cancel() {}
}

/// The whole-take session behind Parakeet and the speech APIs: what it sends,
/// when it sends it again, and when it must not. Every wait is stepped or
/// zeroed — nothing here races a clock.
final class RecordedTranscriptionTests: XCTestCase {
    /// `count` samples of 16 kHz mono silence — only the length matters here.
    private func audio(_ count: Int) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
        guard let format, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
            preconditionFailure("a mono float buffer always builds")
        }
        buffer.frameLength = buffer.frameCapacity
        return buffer
    }

    private func until(_ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(10)
        while !condition(), Date() < end { await Task.yield() }
    }

    /// A rate limit is the provider asking for the take a moment later, not a
    /// refusal of it: minutes of speech get the same one retry a 5xx does.
    func testARateLimitedTakeIsRetriedOnce() async throws {
        let uploads = LockedValue(0)
        let session = RecordedTranscription(preview: false, finishDeadline: 10, perAudioSecond: 0,
                                            retryAfter: .zero, onPartial: { _ in }, transcribe: { _, _ in
            guard uploads.mutate({ $0 += 1; return $0 }) > 1 else {
                throw APIError.http(status: 429, message: "slow down")
            }
            return "hi"
        })
        session.feed(audio(16_000))
        let text = try await session.finish()
        XCTAssertEqual(text, "hi")
        XCTAssertEqual(uploads.get(), 2)
    }

    /// ⎋ (or a focus change) while the failed upload waits for its retry:
    /// the take was thrown away, and its audio must not go out a second time.
    func testACancelBeforeTheRetrySendsNothingMore() async {
        let uploads = LockedValue(0)
        let current = LockedValue<RecordedTranscription?>(nil)
        let session = RecordedTranscription(preview: false, finishDeadline: 10, perAudioSecond: 0,
                                            retryAfter: .zero, onPartial: { _ in }, transcribe: { _, _ in
            uploads.mutate { $0 += 1 }
            // Cancelled as the first upload fails: the wait that follows is
            // spent discarded, and only the check after it stands between the
            // discard and a second upload.
            current.get()?.cancel()
            throw URLError(.networkConnectionLost)
        })
        current.set(session)
        defer { current.set(nil) }
        session.feed(audio(16_000))
        do {
            _ = try await session.finish()
            XCTFail("a discarded take returns nothing")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(uploads.get(), 1, "nothing is sent after the discard")
    }

    /// A take its speech API failed stays in memory for the controller to
    /// write down on this Mac — until a pass lands, or the take is thrown
    /// away. An on-device session has nothing to hand over.
    func testAFailedUploadKeepsItsAudioUntilItLands() async {
        let rejected = LockedValue(true)
        let session = RecordedTranscription(preview: false, uploads: true, finishDeadline: 10, perAudioSecond: 0,
                                            retryAfter: .zero, onPartial: { _ in }, transcribe: { _, _ in
            if rejected.get() { throw APIError.http(status: 401, message: "expired") }
            return "hi"
        })
        session.feed(audio(16_000))
        _ = try? await session.finish()
        XCTAssertEqual(session.unsentAudio?.count, 16_000)
        rejected.set(false)
        _ = try? await session.finish()
        XCTAssertEqual(session.unsentAudio, [], "landed: nothing left to fall back on")
        session.feed(audio(16_000))
        session.cancel()
        XCTAssertEqual(session.unsentAudio, [], "a discarded take keeps nothing")

        let onDevice = RecordedTranscription(preview: false, finishDeadline: 10, perAudioSecond: 0,
                                             onPartial: { _ in }, transcribe: { _, _ in "hi" })
        onDevice.feed(audio(16_000))
        XCTAssertNil(onDevice.unsentAudio)
    }

    /// The fallback hands Apple's model the kept take the way a live capture
    /// would: a second at a time, in the format the model asked for.
    func testAKeptTakeIsFedInTheSessionsOwnFormat() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)
        let sink = BufferSink(format: format)
        try Transcription.feed([Float](repeating: 0.5, count: 24_000), to: sink)
        XCTAssertEqual(sink.buffers.map(\.frameLength), [16_000, 8_000])
        XCTAssertEqual(sink.buffers.first?.format.commonFormat, .pcmFormatInt16)
        let first = try XCTUnwrap(sink.buffers.first?.int16ChannelData?[0][0])
        XCTAssertEqual(Double(first), 16_384, accuracy: 2)
    }

    /// The live preview re-transcribes only once half a second of new audio
    /// has arrived. Without the throttle it re-runs the model on every tick
    /// for the same audio, and repaints the pill with the same guess.
    func testThePreviewWaitsForHalfASecondOfNewAudio() async {
        let clock = PreviewClock()
        let passes = LockedValue<[Int]>([])
        let session = RecordedTranscription(preview: true, finishDeadline: 10, perAudioSecond: 0,
                                            previewTick: { await clock.tick() }, onPartial: { _ in },
                                            transcribe: { audio, final in
            if !final { passes.mutate { $0.append(audio.count) } }
            return "words"
        })
        defer { session.cancel() }
        // One step per pass; `parked` rising means that pass has run.
        func pass(feeding count: Int) async {
            if count > 0 { session.feed(audio(count)) }
            let parked = clock.parked.get()
            clock.step()
            await until { clock.parked.get() > parked }
        }
        await until { clock.parked.get() == 1 }
        await pass(feeding: 16_000)
        XCTAssertEqual(passes.get(), [16_000])
        await pass(feeding: 0)
        XCTAssertEqual(passes.get(), [16_000], "no new audio, no new pass")
        await pass(feeding: 7_999)
        XCTAssertEqual(passes.get(), [16_000], "under half a second of new audio")
        await pass(feeding: 1)
        XCTAssertEqual(passes.get(), [16_000, 24_000])
    }

    /// Under a tenth of a second is a key tap, not speech — and most servers
    /// refuse a clip that short. It never leaves the Mac; a tenth does.
    func testAKeyTapIsNeverUploaded() async throws {
        URLProtocol.registerClass(UploadCounter.self)
        defer { URLProtocol.unregisterClass(UploadCounter.self) }
        UploadCounter.uploads.set(0)
        var config = APIConfig(provider: .custom, kind: .audio)
        config.baseURL = "https://speech.example.com/v1"
        config.model = "whisper-1"

        let tap = try CloudTranscription.start(config, locale: Locale(identifier: "en")) { _ in }
        tap.feed(audio(1_599))
        let heard = try await tap.finish()
        XCTAssertEqual(heard, "")
        XCTAssertEqual(UploadCounter.uploads.get(), 0, "a key tap was uploaded")

        let word = try CloudTranscription.start(config, locale: Locale(identifier: "en")) { _ in }
        word.feed(audio(1_600))
        let said = try await word.finish()
        XCTAssertEqual(said, "hi")
        XCTAssertEqual(UploadCounter.uploads.get(), 1)
    }
}
