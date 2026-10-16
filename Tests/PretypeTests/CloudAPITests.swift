import AVFoundation
import XCTest
@testable import Pretype

/// Answers every request with a canned body and keeps the last request, so
/// the two wire formats are checked end to end without a network.
private final class StubProtocol: URLProtocol {
    /// Served in order; the last one repeats.
    nonisolated(unsafe) static var responses: [(status: Int, body: Data)] = []
    nonisolated(unsafe) static var bodies: [Data] = []
    nonisolated(unsafe) static var lastRequest: URLRequest?
    static var lastBody: Data { bodies.last ?? Data() }
    static var response: (status: Int, body: Data) {
        get { responses.first ?? (200, Data()) }
        set { responses = [newValue]; bodies = [] }
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        // URLSession hands the body over as a stream, never as httpBody.
        var body = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        Self.bodies.append(body)
        let reply = Self.responses.count > 1 ? Self.responses.removeFirst() : Self.responses.first ?? (200, Data())
        let http = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                   httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class CloudAPITests: XCTestCase {
    override func setUp() { URLProtocol.registerClass(StubProtocol.self) }
    override func tearDown() { URLProtocol.unregisterClass(StubProtocol.self) }

    private func endpoint(_ id: String, model: String? = nil, key: String? = "sk-test") -> APIEndpoint {
        let provider = APIProvider.named(id)
        return APIEndpoint(provider: provider, baseURL: URL(string: provider.baseURL)!,
                           model: model ?? provider.textModel ?? "m", key: key)
    }

    /// The multipart body as text. It carries raw WAV bytes, which strict
    /// UTF-8 rejects; Latin-1 maps every byte, and the fields checked are ASCII.
    private var multipartText: String {
        String(bytes: StubProtocol.lastBody, encoding: .isoLatin1) ?? ""
    }

    private var sentJSON: [String: Any] {
        (try? JSONSerialization.jsonObject(with: StubProtocol.lastBody)) as? [String: Any] ?? [:]
    }

    func testOpenAIWire() async throws {
        StubProtocol.response = (200, Data(#"{"choices":[{"message":{"content":"world"}}]}"#.utf8))
        let text = try await APIClient.chat(endpoint("groq"), system: "sys", user: "hello",
                                            maxTokens: 64, timeout: 5)
        XCTAssertEqual(text, "world")
        let request = try XCTUnwrap(StubProtocol.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.groq.com/openai/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertEqual((sentJSON["messages"] as? [[String: String]])?.map { $0["role"] }, ["system", "user"])
        XCTAssertEqual(sentJSON["max_tokens"] as? Int, 64)
        XCTAssertNil(sentJSON["reasoning_effort"])  // Groq's Llama doesn't reason
    }

    func testReasoningSwitchedOffPerProvider() async throws {
        StubProtocol.response = (200, Data(#"{"choices":[{"message":{"content":"x"}}]}"#.utf8))
        _ = try await APIClient.chat(endpoint("openai"), system: "", user: "u", maxTokens: 32, timeout: 5)
        XCTAssertEqual(sentJSON["reasoning_effort"] as? String, "none")
        XCTAssertEqual(sentJSON["max_completion_tokens"] as? Int, 32)
        XCTAssertNil(sentJSON["max_tokens"])
        _ = try await APIClient.chat(endpoint("deepseek"), system: "", user: "u", maxTokens: 32, timeout: 5)
        XCTAssertEqual((sentJSON["thinking"] as? [String: String])?["type"], "disabled")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.absoluteString, "https://api.deepseek.com/chat/completions")
        _ = try await APIClient.chat(endpoint("openrouter"), system: "", user: "u", maxTokens: 32, timeout: 5)
        XCTAssertEqual((sentJSON["reasoning"] as? [String: String])?["effort"], "none")
    }

    func testModelThatRefusesExtrasIsRetriedPlain() async throws {
        StubProtocol.responses = [
            (400, Data(#"{"error":{"message":"Unsupported parameter: 'reasoning_effort'"}}"#.utf8)),
            (200, Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8)),
        ]
        StubProtocol.bodies = []
        let ep = endpoint("openai", model: "some-older-model-\(UUID().uuidString)")
        let text = try await APIClient.chat(ep, system: "", user: "u", maxTokens: 8, timeout: 5)
        XCTAssertEqual(text, "ok")
        XCTAssertEqual(StubProtocol.bodies.count, 2)
        XCTAssertNil(sentJSON["reasoning_effort"])
        // Remembered: the next request goes plain at once.
        _ = try await APIClient.chat(ep, system: "", user: "u", maxTokens: 8, timeout: 5)
        XCTAssertEqual(StubProtocol.bodies.count, 3)
        XCTAssertNil(sentJSON["reasoning_effort"])
    }

    func testAnthropicWire() async throws {
        StubProtocol.response = (200, Data(#"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"world"}],"stop_reason":"end_turn"}"#.utf8))
        let text = try await APIClient.chat(endpoint("anthropic"), system: "sys", user: "hello",
                                            maxTokens: 64, timeout: 5)
        XCTAssertEqual(text, "world")
        let request = try XCTUnwrap(StubProtocol.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(sentJSON["system"] as? String, "sys")
        XCTAssertEqual(sentJSON["model"] as? String, "claude-haiku-5-5")
        XCTAssertEqual((sentJSON["output_config"] as? [String: String])?["effort"], "low")
        XCTAssertEqual((sentJSON["messages"] as? [[String: String]])?.count, 1)

        // A refusal is an abstain, not text.
        StubProtocol.response = (200, Data(#"{"content":[{"type":"text","text":"no"}],"stop_reason":"refusal"}"#.utf8))
        let refused = try await APIClient.chat(endpoint("anthropic"), system: "", user: "x", maxTokens: 8, timeout: 5)
        XCTAssertEqual(refused, "")
    }

    /// A 400 that plain fails too was about the text (a content filter), not
    /// the preset's switches: they stay on for the next request.
    func testA400ForTheTextKeepsTheSpeedSettings() async throws {
        StubProtocol.responses = [
            (400, Data(#"{"error":{"message":"Invalid prompt: flagged"}}"#.utf8)),
            (400, Data(#"{"error":{"message":"Invalid prompt: flagged"}}"#.utf8)),
            (200, Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8)),
        ]
        StubProtocol.bodies = []
        let ep = endpoint("openai", model: "filtered-\(UUID().uuidString)")
        do {
            _ = try await APIClient.chat(ep, system: "", user: "u", maxTokens: 8, timeout: 5)
            XCTFail("both attempts were refused")
        } catch {}
        XCTAssertEqual(StubProtocol.bodies.count, 2)
        _ = try await APIClient.chat(ep, system: "", user: "u", maxTokens: 8, timeout: 5)
        XCTAssertEqual(sentJSON["reasoning_effort"] as? String, "none", "not latched to plain")
    }

    /// The finish watchdog grows with the take: a whole-take pass is
    /// proportional to its audio, and a ten-minute latch must not time out
    /// where a one-minute take would not.
    func testFinishDeadlineGrowsWithTheTake() {
        let session = RecordedTranscription(preview: false, finishDeadline: 10, perAudioSecond: 0.05,
                                            onPartial: { _ in }, transcribe: { _, _ in "" })
        XCTAssertEqual(session.finishDeadline, 10)
        for _ in 0 ..< 60 { session.feed(silence(seconds: 1)) }
        XCTAssertEqual(session.finishDeadline ?? 0, 13, accuracy: 0.001)
    }

    func testHTTPErrorCarriesProviderMessage() async {
        StubProtocol.response = (401, Data(#"{"error":{"message":"Incorrect API key"}}"#.utf8))
        do {
            _ = try await APIClient.chat(endpoint("openai"), system: "", user: "x", maxTokens: 8, timeout: 5)
            XCTFail("expected an error")
        } catch let error as APIError {
            XCTAssertTrue(error.isAuth)
            guard case .http(401, "Incorrect API key") = error else { return XCTFail("\(error)") }
        } catch {
            XCTFail("\(error)")
        }
        let forbidden = APIError.http(status: 403, message: "flagged")
        XCTAssertFalse(forbidden.isAuth, "a 403 is often moderation or region, not the key")
        XCTAssertEqual(forbidden.localizedDescription, "HTTP 403: flagged")
    }

    func testTranscriptionUploadsWAV() async throws {
        StubProtocol.response = (200, Data(#"{"text":"привет","languages":[{"code":"ru"}]}"#.utf8))
        let wav = CloudTranscription.wav([0, 0.5, -2])
        let text = try await APIClient.transcribe(endpoint("openai", model: "gpt-transcribe"), wav: wav,
                                                  language: "ru", hints: ["Dubina", "bad<word"], timeout: 5)
        XCTAssertEqual(text, "привет")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.absoluteString, "https://api.openai.com/v1/audio/transcriptions")
        let body = multipartText
        // gpt-transcribe: a language LIST, never the singular field, plus keywords.
        XCTAssertTrue(body.contains("name=\"languages[]\"\r\n\r\nru\r\n"))
        XCTAssertFalse(body.contains("name=\"language\""))
        XCTAssertTrue(body.contains("name=\"keywords[]\"\r\n\r\nDubina\r\n"))
        XCTAssertFalse(body.contains("bad<word"))
        XCTAssertTrue(StubProtocol.lastBody.range(of: wav) != nil)
    }

    func testWhisperGetsLanguageAndPrompt() async throws {
        StubProtocol.response = (200, Data(#"{"text":"hi"}"#.utf8))
        _ = try await APIClient.transcribe(endpoint("groq", model: "whisper-large-v3-turbo"),
                                           wav: CloudTranscription.wav([0]), language: "en",
                                           hints: ["MLX", "Pretype"], timeout: 5)
        let body = multipartText
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nen\r\n"))
        XCTAssertTrue(body.contains("name=\"prompt\"\r\n\r\nMLX, Pretype\r\n"))
        XCTAssertFalse(body.contains("keywords[]"))
    }

    func testRefrainGetsLanguageAndPrompt() async throws {
        StubProtocol.response = (200, Data(#"{"text":"привет"}"#.utf8))
        _ = try await APIClient.transcribe(endpoint("refrain", model: "auto", key: nil),
                                           wav: CloudTranscription.wav([0]), language: "ru",
                                           hints: ["Dubina", "MLX"], timeout: 5)
        XCTAssertEqual(StubProtocol.lastRequest?.url?.absoluteString, "http://127.0.0.1:8178/v1/audio/transcriptions")
        XCTAssertNil(StubProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"))
        let body = multipartText
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nru\r\n"))
        XCTAssertTrue(body.contains("name=\"prompt\"\r\n\r\nDubina, MLX\r\n"))
    }

    /// A server on this Mac costs nothing per request, so it gets the live preview.
    func testLocalServerGetsLivePreview() async throws {
        StubProtocol.response = (200, Data(#"{"text":"привет"}"#.utf8))
        let partials = LockedValue<[String]>([])
        let session = try CloudTranscription.start(APIConfig(provider: .named("refrain"), kind: .audio),
                                                   locale: Locale(identifier: "ru")) { text in partials.mutate { $0.append(text) } }
        session.feed(silence(seconds: 1))
        // The preview runs on its own clock: wait for it, not for a guess at it.
        let deadline = Date().addingTimeInterval(10)
        while partials.get().isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(partials.get().isEmpty, "a local server must get a live preview")
        XCTAssertTrue(partials.get().allSatisfy { $0 == "привет" }, "\(partials.get())")
        let final = try await session.finish()
        XCTAssertEqual(final, "привет")
    }

    /// A hosted one bills each request: the take goes once, at the end.
    func testHostedServerGetsNoPreview() async throws {
        StubProtocol.response = (200, Data(#"{"text":"hi"}"#.utf8))
        var config = APIConfig(provider: .custom, kind: .audio)
        config.baseURL = "https://speech.example.com/v1"
        config.model = "whisper-1"
        let partials = LockedValue<[String]>([])
        let session = try CloudTranscription.start(config, locale: Locale(identifier: "en")) { text in partials.mutate { $0.append(text) } }
        session.feed(silence(seconds: 1))
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertTrue(partials.get().isEmpty)
        XCTAssertTrue(StubProtocol.bodies.isEmpty)
        session.cancel()
    }

    private func silence(seconds: Int) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(16_000 * seconds))!
        buffer.frameLength = buffer.frameCapacity
        return buffer
    }

    /// The suggested models are what a fresh install sends — pin them, so a
    /// stale id can't slip back in unnoticed.
    func testPresetModels() {
        let text = Dictionary(uniqueKeysWithValues: APIProvider.all.map { ($0.id, $0.textModel) })
        XCTAssertEqual(text["openai"], "gpt-6-luna")
        XCTAssertEqual(text["anthropic"], "claude-haiku-5-5")
        XCTAssertEqual(text["gemini"], "gemini-3.5-flash-lite")
        XCTAssertEqual(text["deepseek"], "deepseek-flash")
        XCTAssertEqual(APIProvider.named("openai").audioModel, "gpt-transcribe")
        XCTAssertEqual(APIProvider.offering(.audio).map(\.id), ["openai", "groq", "mistral", "refrain", "custom"])
        XCTAssertNil(APIProvider.named("refrain").textModel)  // dictation only
    }

    func testWAVHeaderAndClamp() {
        let wav = CloudTranscription.wav([0, 1, -2])
        XCTAssertEqual(wav.count, 44 + 6)
        XCTAssertEqual(String(bytes: wav[0..<4], encoding: .utf8), "RIFF")
        XCTAssertEqual(String(bytes: wav[8..<16], encoding: .utf8), "WAVEfmt ")
        let rate = wav[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        XCTAssertEqual(UInt32(littleEndian: rate), 16_000)
        let last = wav[48..<50].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }
        XCTAssertEqual(Int16(littleEndian: last), -32767)  // -2 clamps to -1
    }

    func testClipKeepsWholeWords() {
        XCTAssertEqual(CloudEngine.clip("one two three four five", words: 3), "one two three")
        XCTAssertEqual(CloudEngine.clip(" one two", words: 1), " one")
        XCTAssertEqual(CloudEngine.clip("one two", words: 4), "one two")
    }

    func testEndpointValidation() throws {
        var config = APIConfig(provider: .custom, kind: .text)
        XCTAssertThrowsError(try config.endpoint())  // no URL
        config.baseURL = "http://localhost:8080/v1/"
        XCTAssertThrowsError(try config.endpoint())  // no model
        config.model = "qwen"
        let endpoint = try config.endpoint()  // custom needs no key
        XCTAssertEqual(endpoint.baseURL.absoluteString, "http://localhost:8080/v1")
    }
}
