import AVFoundation
import XCTest
@testable import Pretype

/// Answers every request with a canned body and keeps the last request, so
/// the two wire formats are checked end to end without a network.
private final class StubProtocol: URLProtocol {
    /// Served in order; the last one repeats.
    nonisolated(unsafe) static var responses: [(status: Int, body: Data)] = []
    nonisolated(unsafe) static var bodies: [Data] = []
    nonisolated(unsafe) static var hosts: [String] = []
    /// Requests get no answer: the caller waits until it gives up.
    nonisolated(unsafe) static var holds = false
    nonisolated(unsafe) static var lastRequest: URLRequest?
    static var lastBody: Data { bodies.last ?? Data() }
    static var response: (status: Int, body: Data) {
        get { responses.first ?? (200, Data()) }
        set { responses = [newValue]; bodies = []; hosts = []; holds = false }
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.hosts.append(request.url?.host ?? "")
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
        if Self.holds { return }
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

    /// A request called off — a newer keystroke superseded it — reaches the
    /// caller as a cancellation, never as a failure that would latch the
    /// engine off or blame the key.
    func testACalledOffRequestIsACancellation() async throws {
        StubProtocol.response = (200, Data())
        StubProtocol.holds = true
        defer { StubProtocol.holds = false }
        let request = Task {
            try await APIClient.chat(endpoint("groq"), system: "", user: "u", maxTokens: 8, timeout: 30)
        }
        let deadline = Date() + 10
        while StubProtocol.hosts.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertFalse(StubProtocol.hosts.isEmpty, "the request never went out")
        request.cancel()
        let result = await request.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
    }

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
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
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
        XCTAssertEqual(sentJSON["max_tokens"] as? Int, 64 + 1024, "headroom for thinking")
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

    /// A 400 with no speed switches to drop is the server's answer to the
    /// text itself: there is nothing to retry plain.
    func testA400WithoutSpeedSettingsIsNotRetried() async {
        StubProtocol.responses = [
            (400, Data(#"{"error":{"message":"Invalid prompt"}}"#.utf8)),
            (200, Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8)),
        ]
        StubProtocol.bodies = []
        do {
            _ = try await APIClient.chat(endpoint("groq"), system: "", user: "u", maxTokens: 8, timeout: 5)
            XCTFail("the 400 stands")
        } catch {}
        XCTAssertEqual(StubProtocol.bodies.count, 1)
    }

    /// A hosted provider's engine needs its key: without one it is failed
    /// with the reason, sends nothing, and says so on an explicit request.
    func testAHostedProviderWithoutItsKeyIsNotSetUp() async throws {
        APIKeychain.set(nil, for: "groq")
        let config = APIConfig(provider: .named("groq"), kind: .text, enabled: true)
        XCTAssertThrowsError(try config.endpoint()) {
            guard case APIError.setup = $0 else { return XCTFail("\($0)") }
        }
        StubProtocol.response = (200, Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8))
        let engine = CloudEngine(config)
        guard case .failed = engine.state else { return XCTFail("\(engine.state)") }
        let none = try await engine.complete(CompletionRequest(textBeforeCaret: "See you at the ", endsOnCompleteWord: false))
        XCTAssertNil(none)
        do {
            _ = try await engine.correct(selection: "teh")
            XCTFail("a fix with no API set up must say so")
        } catch {
            XCTAssertTrue(error is EngineNotReady, "\(error)")
        }
        XCTAssertTrue(StubProtocol.bodies.isEmpty, "nothing sent")

        APIKeychain.set("sk-groq", for: "groq")
        defer { APIKeychain.set(nil, for: "groq") }
        XCTAssertEqual(try config.endpoint().key, "sk-groq")
        XCTAssertEqual(CloudEngine(config).state, .ready)
    }

    /// A server on this Mac or a company proxy: no key needed.
    private var customEngine: CloudEngine {
        var config = APIConfig(provider: .custom, kind: .text, enabled: true)
        config.baseURL = "https://llm.example.com/v1"
        config.model = "m"
        return CloudEngine(config)
    }

    private static func answer(_ text: String) -> (status: Int, body: Data) {
        let json = ["choices": [["message": ["content": text]]]]
        return (200, (try? JSONSerialization.data(withJSONObject: json)) ?? Data())
    }

    /// Typing never surfaces a failed request: every error abstains. Only a
    /// rejected key (401) stops the engine for the session — a 403 is often
    /// moderation or a region, and the next keystroke may well pass.
    func testOnlyARejectedKeyStopsSuggestions() async throws {
        let engine = customEngine
        let request = CompletionRequest(textBeforeCaret: "See you at the ", endsOnCompleteWord: false)
        StubProtocol.response = (403, Data(#"{"error":{"message":"flagged"}}"#.utf8))
        let flagged = try await engine.complete(request)
        XCTAssertNil(flagged)
        XCTAssertEqual(engine.state, .ready)
        StubProtocol.response = (500, Data())
        let broken = try await engine.complete(request)
        XCTAssertNil(broken)
        XCTAssertEqual(engine.state, .ready)

        StubProtocol.response = (401, Data(#"{"error":{"message":"Incorrect API key"}}"#.utf8))
        let rejected = try await engine.complete(request)
        XCTAssertNil(rejected)
        XCTAssertEqual(engine.state, .failed(APIError.http(status: 401, message: "").localizedDescription))
        StubProtocol.response = Self.answer("next week")
        let after = try await engine.complete(request)
        XCTAssertNil(after)
        XCTAssertTrue(StubProtocol.bodies.isEmpty, "a rejected key is not tried again")
    }

    /// A suggestion is the typed tail's next words: the last 1200 characters
    /// go out (none below the context floor), with the length hint, a
    /// 128-token budget and 10 s to answer; the answer is cut at the
    /// length's word cap and gated like any instruct answer.
    func testASuggestionRequestAndItsAnswer() async throws {
        let engine = customEngine
        engine.updateCompletion(length: .short, instructions: "")
        StubProtocol.response = Self.answer("\"and then we can talk later today\"")
        let typed = "HEAD " + String(repeating: "We should meet ", count: 90)
        let short = try await engine.complete(CompletionRequest(textBeforeCaret: typed, endsOnCompleteWord: false))
        XCTAssertEqual(short, "and then we can")
        let messages = try XCTUnwrap(sentJSON["messages"] as? [[String: String]])
        XCTAssertTrue(messages.first?["content"]?.hasSuffix("Length: \(CompletionLength.short.wordsHint).") ?? false)
        let user = try XCTUnwrap(messages.last?["content"])
        XCTAssertTrue(user.contains("Existing text: \"\(typed.suffix(1200).dropLast())\""), "the last 1200 characters")
        XCTAssertEqual(sentJSON["max_tokens"] as? Int, 128)
        XCTAssertEqual(StubProtocol.lastRequest?.timeoutInterval, 10)

        let words = "and then we can talk about the plan for the next week over lunch with the whole team at the cafe on Monday"
        StubProtocol.response = Self.answer(words)
        for (length, cap) in [(CompletionLength.medium, 8), (.long, 20)] {
            engine.updateCompletion(length: length, instructions: "Writes tersely.")
            let capped = try await engine.complete(CompletionRequest(textBeforeCaret: "We should meet ", endsOnCompleteWord: false))
            XCTAssertEqual(capped, words.split(separator: " ").prefix(cap).joined(separator: " "))
        }
        let system = try XCTUnwrap((sentJSON["messages"] as? [[String: String]])?.first?["content"])
        XCTAssertTrue(system.contains("Writes tersely."), system)

        // The context floors: 8 characters at a word boundary, 5 mid-word.
        StubProtocol.response = Self.answer("next")
        for (typed, asks) in [("Hi you ", false), ("Hi you, ", true), ("Hell", false), ("Hello", true)] {
            StubProtocol.bodies = []
            _ = try await engine.complete(CompletionRequest(textBeforeCaret: typed, endsOnCompleteWord: false))
            XCTAssertEqual(StubProtocol.bodies.count, asks ? 1 : 0, typed)
        }
    }

    /// Fix, reply and voice command go out as one plain turn with 30 s to
    /// answer — no system message, the shared gates around it.
    func testTheChordsAskOnePlainTurn() async throws {
        let engine = customEngine
        StubProtocol.response = Self.answer("the")
        let fixed = try await engine.correct(selection: "teh")
        XCTAssertEqual(fixed, "the")
        XCTAssertEqual((sentJSON["messages"] as? [[String: String]])?.map { $0["role"] }, ["user"])
        XCTAssertEqual(sentJSON["max_tokens"] as? Int, 64)
        XCTAssertEqual(StubProtocol.lastRequest?.timeoutInterval, 30)
        StubProtocol.response = Self.answer("Good day")
        let rewritten = try await engine.rewrite(selection: "hi", instruction: "formal")
        XCTAssertEqual(rewritten, "Good day")
        StubProtocol.response = Self.answer("Sounds good")
        let reply = try await engine.reply(to: "Ann: lunch?", request: CompletionRequest(textBeforeCaret: ""))
        XCTAssertEqual(reply, "Sounds good")
        XCTAssertEqual(sentJSON["max_tokens"] as? Int, 200)
    }

    /// Built by the coordinator, a hosted engine starts on the saved length
    /// and persona — its own defaults are not the user's.
    @MainActor
    func testTheCoordinatorHandsACloudEngineTheSavedKnobs() async throws {
        let saved = (Settings.apiText, Settings.completionLength, Settings.customInstructions)
        defer { (Settings.apiText, Settings.completionLength, Settings.customInstructions) = saved }
        var api = APIConfig(provider: .custom, kind: .text, enabled: true)
        api.baseURL = "https://llm.example.com/v1"
        api.model = "m"
        (Settings.apiText, Settings.completionLength, Settings.customInstructions) = (api, .long, "Writes tersely.")
        let engine = try XCTUnwrap(EngineCoordinator().engine as? CloudEngine)
        StubProtocol.response = Self.answer("next")
        _ = try await engine.complete(CompletionRequest(textBeforeCaret: "See you at the ", endsOnCompleteWord: false))
        let system = try XCTUnwrap((sentJSON["messages"] as? [[String: String]])?.first?["content"])
        XCTAssertTrue(system.hasSuffix("Length: \(CompletionLength.long.wordsHint)."), system)
        XCTAssertTrue(system.contains("Writes tersely."), system)
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

    /// The take's one upload is retried once on a transient failure — with the
    /// same audio, not the emptied buffer — and never on a rejected key.
    func testTakeUploadRetriesATransientFailureOnce() async throws {
        var config = APIConfig(provider: .custom, kind: .audio)
        config.baseURL = "https://speech.example.com/v1"
        config.model = "whisper-1"
        StubProtocol.responses = [(503, Data()), (200, Data(#"{"text":"hi"}"#.utf8))]
        StubProtocol.bodies = []
        let flaky = try CloudTranscription.start(config, locale: Locale(identifier: "en"), retryAfter: .milliseconds(10)) { _ in }
        flaky.feed(silence(seconds: 1))
        let text = try await flaky.finish()
        XCTAssertEqual(text, "hi")
        XCTAssertEqual(StubProtocol.bodies.count, 2)

        StubProtocol.responses = [(401, Data()), (200, Data(#"{"text":"hi"}"#.utf8))]
        StubProtocol.bodies = []
        let rejected = try CloudTranscription.start(config, locale: Locale(identifier: "en"), retryAfter: .milliseconds(10)) { _ in }
        rejected.feed(silence(seconds: 1))
        do {
            _ = try await rejected.finish()
            XCTFail("a rejected key fails the same way twice")
        } catch {}
        XCTAssertEqual(StubProtocol.bodies.count, 1)
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
        XCTAssertFalse(APIError.setup("enter a model name").isAuth)

        // Only 2xx is an answer; a proxy's long error text is cut to 200.
        StubProtocol.response = (300, Data(#"{"choices":[{"message":{"content":"x"}}]}"#.utf8))
        do {
            _ = try await APIClient.chat(endpoint("groq"), system: "", user: "x", maxTokens: 8, timeout: 5)
            XCTFail("a 300 is no answer")
        } catch {}
        let long = String(repeating: "e", count: 300)
        StubProtocol.response = (500, Data(#"{"error":{"message":"\#(long)"}}"#.utf8))
        do {
            _ = try await APIClient.chat(endpoint("groq"), system: "", user: "x", maxTokens: 8, timeout: 5)
            XCTFail("a 500 is no answer")
        } catch APIError.http(500, let message) {
            XCTAssertEqual(message, String(long.prefix(200)))
        } catch {
            XCTFail("\(error)")
        }
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
        XCTAssertTrue(body.contains("name=\"model\"\r\n\r\ngpt-transcribe\r\n"))
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n"))
        let boundary = try XCTUnwrap(StubProtocol.lastRequest?.value(forHTTPHeaderField: "Content-Type")?
            .components(separatedBy: "multipart/form-data; boundary=").last)
        XCTAssertTrue(body.hasPrefix("--\(boundary)\r\n"))
        XCTAssertTrue(body.hasSuffix("\r\n--\(boundary)--\r\n"))

        // 50 keywords at most.
        let many = (0 ..< 60).map { "term\($0)" }
        _ = try await APIClient.transcribe(endpoint("openai", model: "gpt-transcribe"), wav: wav,
                                           language: nil, hints: many, timeout: 5)
        XCTAssertEqual(multipartText.components(separatedBy: "name=\"keywords[]\"").count - 1, 50)
        XCTAssertFalse(multipartText.contains("languages[]"), "no language: the model detects it")
    }

    /// Hints go only where the model documents a field for them — whisper
    /// takes 30 in its prompt, Voxtral none — and an empty list sends no field.
    func testHintsGoOnlyWhereTheModelReadsThem() async throws {
        StubProtocol.response = (200, Data(#"{"text":"hi"}"#.utf8))
        let hints = (0 ..< 40).map { "w\($0)" }
        _ = try await APIClient.transcribe(endpoint("groq", model: "whisper-large-v3-turbo"),
                                           wav: CloudTranscription.wav([0]), language: nil, hints: hints, timeout: 5)
        XCTAssertTrue(multipartText.contains("name=\"prompt\"\r\n\r\n\(hints.prefix(30).joined(separator: ", "))\r\n"))
        XCTAssertFalse(multipartText.contains("name=\"language\""))
        _ = try await APIClient.transcribe(endpoint("groq", model: "whisper-large-v3-turbo"),
                                           wav: CloudTranscription.wav([0]), language: "en", hints: [], timeout: 5)
        XCTAssertFalse(multipartText.contains("name=\"prompt\""))
        _ = try await APIClient.transcribe(endpoint("mistral", model: "voxtral-mini-latest"),
                                           wav: CloudTranscription.wav([0]), language: "en", hints: hints, timeout: 5)
        XCTAssertFalse(multipartText.contains("name=\"prompt\""))
        XCTAssertTrue(APIClient.sendsHints(model: "gpt-transcribe", provider: "openai"))
        XCTAssertTrue(APIClient.sendsHints(model: "whisper-1", provider: "custom"))
        XCTAssertTrue(APIClient.sendsHints(model: "auto", provider: "refrain"))
        XCTAssertFalse(APIClient.sendsHints(model: "voxtral-mini-latest", provider: "mistral"))
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
                                                   locale: Locale(identifier: "ru"), previewEvery: .milliseconds(20)) { text in
            partials.mutate { $0.append(text) }
        }
        session.feed(silence(seconds: 1))
        // The preview runs on its own clock: wait for it, not for a guess at it.
        let deadline = Date().addingTimeInterval(10)
        while partials.get().isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(partials.get().isEmpty, "a local server must get a live preview")
        XCTAssertTrue(partials.get().allSatisfy { $0 == "привет" }, "\(partials.get())")
        let final = try await session.finish()
        XCTAssertEqual(final, "привет")
    }

    /// A hosted one bills each request: the take goes once, at the end. A
    /// local session started right after it, on the same cadence, is the
    /// clock — once its preview has come back and a few more ticks passed, a
    /// hosted preview would have gone out too.
    func testHostedServerGetsNoPreview() async throws {
        StubProtocol.response = (200, Data(#"{"text":"hi"}"#.utf8))
        var config = APIConfig(provider: .custom, kind: .audio)
        config.baseURL = "https://speech.example.com/v1"
        config.model = "whisper-1"
        XCTAssertFalse(config.isLocal)
        let partials = LockedValue<[String]>([]), localPartials = LockedValue<[String]>([])
        let tick: Duration = .milliseconds(20)
        let hosted = try CloudTranscription.start(config, locale: Locale(identifier: "en"), previewEvery: tick) { text in
            partials.mutate { $0.append(text) }
        }
        let local = try CloudTranscription.start(APIConfig(provider: .named("refrain"), kind: .audio),
                                                 locale: Locale(identifier: "en"), previewEvery: tick) { text in
            localPartials.mutate { $0.append(text) }
        }
        hosted.feed(silence(seconds: 1))
        local.feed(silence(seconds: 1))
        let deadline = Date().addingTimeInterval(10)
        while localPartials.get().isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: tick * 3)
        local.cancel()
        XCTAssertFalse(localPartials.get().isEmpty, "the local clock never ticked")
        XCTAssertTrue(partials.get().isEmpty)
        XCTAssertFalse(StubProtocol.hosts.contains("speech.example.com"), "a preview went to the hosted server")
        let final = try await hosted.finish()
        XCTAssertEqual(final, "hi")
        XCTAssertEqual(StubProtocol.hosts.filter { $0 == "speech.example.com" }.count, 1, "the take goes once")
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
        XCTAssertEqual(CloudEngine.clip("one two  ", words: 2), "one two")
        XCTAssertEqual(CloudEngine.clip("one two", words: 0), "one two")
    }

    func testEndpointValidation() throws {
        var config = APIConfig(provider: .custom, kind: .text)
        XCTAssertThrowsError(try config.endpoint())  // no URL
        config.baseURL = "http://localhost:8080/v1/"
        XCTAssertThrowsError(try config.endpoint())  // no model
        config.model = "qwen"
        let endpoint = try config.endpoint()  // custom needs no key
        XCTAssertEqual(endpoint.baseURL.absoluteString, "http://localhost:8080/v1")
        for url in ["ftp://example.com/v1", "http:/v1"] {
            config.baseURL = url
            XCTAssertThrowsError(try config.endpoint(), url)  // an http(s) server, by host
        }
        // The local servers take no key; nothing they get leaves the Mac.
        for id in ["ollama", "lmstudio", "refrain"] {
            APIKeychain.set(nil, for: id)
            let local = APIConfig(provider: .named(id), kind: id == "refrain" ? .audio : .text)
            XCTAssertNil(try local.endpoint().key, id)
            XCTAssertTrue(local.isLocal, id)
        }
        for (url, local) in [("http://localhost:1/v1", true), ("http://[::1]:1/v1", true),
                             ("http://127.0.0.1:1/v1", true), ("https://api.example.com/v1", false)] {
            config.baseURL = url
            XCTAssertEqual(config.isLocal, local, url)
        }
        XCTAssertTrue(APIConfig(provider: .custom, kind: .text, enabled: true).enabled)
    }

    /// The Settings "Test" button: one tiny turn, timed, or why it failed.
    func testTheTestButton() async throws {
        var config = APIConfig(provider: .custom, kind: .text)
        config.baseURL = "https://llm.example.com/v1"
        config.model = "m"
        StubProtocol.response = Self.answer("OK")
        let passed = await CloudEngine.test(config)
        XCTAssertTrue(passed.hasPrefix("✓"), passed)
        XCTAssertEqual(sentJSON["max_tokens"] as? Int, 16)
        XCTAssertEqual(StubProtocol.lastRequest?.timeoutInterval, 20)
        StubProtocol.response = (500, Data(#"{"error":{"message":"down"}}"#.utf8))
        let failed = await CloudEngine.test(config)
        XCTAssertEqual(failed, "⚠︎ HTTP 500: down")
    }

    // A key pasted with a trailing newline would be sent as is and refused (401).
    func testAPIKeysAreTrimmedAndAnEmptyKeyDeletes() {
        APIKeychain.set("  sk-test\n", for: "trim-test")
        XCTAssertEqual(APIKeychain.key(for: "trim-test"), "sk-test")
        APIKeychain.set(" \n", for: "trim-test")
        XCTAssertNil(APIKeychain.key(for: "trim-test"))
    }
}
