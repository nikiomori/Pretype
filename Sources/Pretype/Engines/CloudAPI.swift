import Foundation
import Security

// MARK: - Providers

/// A hosted (or local-server) model reached over HTTP — the opt-in alternative
/// to the on-device engines, for text and for dictation separately. Two wire
/// formats cover every preset: OpenAI's chat-completions and
/// audio-transcriptions shape, which nearly every provider and local server
/// speaks, and Anthropic's own Messages API.
///
/// Presets checked against each provider's docs on 2026-10-12. Most current
/// models reason before they answer, and by default: GPT-6 Luna at `medium`,
/// DeepSeek Flash at `high`. For a few words of autocomplete that is seconds
/// of latency, so each preset turns it off (or down) in `textExtras`.
struct APIProvider: Identifiable {
    enum Wire { case openAI, anthropic }

    let id: String
    let name: String
    let baseURL: String
    var wire = Wire.openAI
    /// Suggested models. nil — the provider has no endpoint of that kind.
    var textModel: String?
    var audioModel: String?
    /// Local servers take no key.
    var needsKey = true
    /// Where to create a key.
    var keyPage: String?
    /// OpenAI's reasoning models reject `max_tokens`; everyone else reads it.
    var tokenField = "max_tokens"
    /// Merged into every chat request: the provider's own switch for "answer
    /// now, don't reason first". A model that refuses them (the user typed a
    /// different one) gets the request again without them — see `APIClient`.
    var textExtras: [String: Any] = [:]

    static let all: [APIProvider] = [
        APIProvider(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1",
                    textModel: "gpt-6-luna", audioModel: "gpt-transcribe",
                    keyPage: "https://platform.openai.com/api-keys", tokenField: "max_completion_tokens",
                    textExtras: ["reasoning_effort": "none"]),
        // Effort, not disabled thinking: Anthropic's guidance for Haiku 5.5 —
        // at `low` it skips thinking on a request this simple.
        APIProvider(id: "anthropic", name: "Anthropic", baseURL: "https://api.anthropic.com/v1",
                    wire: .anthropic, textModel: "claude-haiku-5-5",
                    keyPage: "https://platform.claude.com/settings/keys",
                    textExtras: ["output_config": ["effort": "low"]]),
        // Gemini 3.x can't switch thinking off; Flash-Lite already defaults
        // to its lowest level (minimal), so there is nothing to send.
        APIProvider(id: "gemini", name: "Google Gemini",
                    baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
                    textModel: "gemini-3.5-flash-lite", keyPage: "https://aistudio.google.com/apikey"),
        APIProvider(id: "groq", name: "Groq", baseURL: "https://api.groq.com/openai/v1",
                    textModel: "llama-3.1-8b-instant", audioModel: "whisper-large-v3-turbo",
                    keyPage: "https://console.groq.com/keys"),
        // mistral-small-latest is Small 4, a hybrid reasoning model.
        APIProvider(id: "mistral", name: "Mistral", baseURL: "https://api.mistral.ai/v1",
                    textModel: "mistral-small-latest", audioModel: "voxtral-mini-latest",
                    keyPage: "https://console.mistral.ai/api-keys",
                    textExtras: ["reasoning_effort": "none"]),
        // Gemma 4, the family Pretype runs on device: the 26B MoE has 4B
        // active parameters — fast, and the cheapest model on the list.
        APIProvider(id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1",
                    textModel: "google/gemma-4-26b-a4b-it", keyPage: "https://openrouter.ai/keys",
                    textExtras: ["reasoning": ["effort": "none"]]),
        APIProvider(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com",
                    textModel: "deepseek-flash", keyPage: "https://platform.deepseek.com/api_keys",
                    textExtras: ["thinking": ["type": "disabled"]]),
        // The local servers default to Gemma 4 E4B, the instruct tier that
        // Pretype's own fix and reply run on.
        APIProvider(id: "ollama", name: String(localized: "Ollama (local)"), baseURL: "http://localhost:11434/v1",
                    textModel: "gemma4:e4b", needsKey: false,
                    textExtras: ["reasoning_effort": "none"]),
        APIProvider(id: "lmstudio", name: String(localized: "LM Studio (local)"), baseURL: "http://localhost:1234/v1",
                    textModel: "google/gemma-4-e4b", needsKey: false),
        // Refrain, the speech engine shared by every app on this Mac (github.com/nikiomori/Refrain):
        // dictation only, and it picks Apple's model or Parakeet by language, so any model name does.
        APIProvider(id: "refrain", name: String(localized: "Refrain (this Mac)"), baseURL: "http://127.0.0.1:8178/v1",
                    audioModel: "auto", needsKey: false),
        custom,
    ]

    /// Any other OpenAI-compatible server — vLLM, llama.cpp, a whisper
    /// server, a company proxy. The key is optional.
    static let custom = APIProvider(id: "custom", name: String(localized: "Custom (OpenAI-compatible)"), baseURL: "",
                                    textModel: "", audioModel: "", needsKey: false)

    static func named(_ id: String) -> APIProvider { all.first { $0.id == id } ?? custom }

    static func offering(_ kind: APIKind) -> [APIProvider] {
        all.filter { (kind == .text ? $0.textModel : $0.audioModel) != nil }
    }
}

enum APIKind { case text, audio }

/// One persisted API choice (Settings.apiText / apiAudio). The key is not
/// here: it lives in the Keychain, per provider (`APIKeychain`).
struct APIConfig: Codable, Equatable {
    var enabled = false
    var provider: String
    var baseURL: String
    var model: String

    init(provider: APIProvider, kind: APIKind, enabled: Bool = false) {
        self.enabled = enabled
        self.provider = provider.id
        baseURL = provider.baseURL
        model = (kind == .text ? provider.textModel : provider.audioModel) ?? ""
    }

    var preset: APIProvider { APIProvider.named(provider) }

    /// A server on this Mac: nothing leaves it, and a request costs nothing.
    var isLocal: Bool {
        let host = URL(string: baseURL.trimmingCharacters(in: .whitespaces))?.host ?? ""
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    /// Everything a request needs, or the reason it can't be made — the
    /// reason is shown verbatim in Settings and at the caret.
    func endpoint() throws -> APIEndpoint {
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed),
              ["http", "https"].contains(url.scheme ?? ""), url.host != nil
        else { throw APIError.setup(String(localized: "enter the server's base URL")) }
        let model = model.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { throw APIError.setup(String(localized: "enter a model name")) }
        let key = APIKeychain.key(for: provider)
        if preset.needsKey, key == nil { throw APIError.setup(String(localized: "add an API key in Settings → API")) }
        return APIEndpoint(provider: preset, baseURL: url, model: model, key: key)
    }
}

struct APIEndpoint {
    let provider: APIProvider
    let baseURL: URL
    let model: String
    let key: String?

    var host: String { baseURL.host ?? baseURL.absoluteString }
}

enum APIError: LocalizedError {
    /// Missing configuration — nothing was sent.
    case setup(String)
    /// The server answered with an error.
    case http(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .setup(let why): return why
        case .http(let status, let message):
            if status == 401 || status == 403 { return String(localized: "the API key was rejected (\(status))") }
            return "HTTP \(status)" + (message.isEmpty ? "" : ": \(message)")
        }
    }

    var isAuth: Bool {
        if case .http(let status, _) = self { return status == 401 || status == 403 }
        return false
    }
}

// MARK: - Keychain

/// API keys, one per provider, in the login keychain — never in defaults,
/// never in the log.
enum APIKeychain {
    private static let service = "app.pretype.api-key"

    private static func query(_ provider: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: provider]
    }

    static func key(for provider: String) -> String? {
        var q = query(provider)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8),
              !key.isEmpty else { return nil }
        return key
    }

    /// Empty or nil deletes the key.
    static func set(_ key: String?, for provider: String) {
        let key = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        SecItemDelete(query(provider) as CFDictionary)
        guard !key.isEmpty else { return }
        var q = query(provider)
        q[kSecValueData as String] = Data(key.utf8)
        let status = SecItemAdd(q as CFDictionary, nil)
        if status != errSecSuccess { DebugLog.shared.log("API", "keychain write failed (\(status))") }
    }
}

// MARK: - HTTP

/// The two calls Pretype makes: one chat turn, one transcription. No
/// streaming: a suggestion is a few words, and a transcript arrives whole.
/// Cancelling the calling task cancels the request (latest keystroke wins).
enum APIClient {
    static func chat(_ endpoint: APIEndpoint, system: String, user: String,
                     maxTokens: Int, timeout: TimeInterval) async throws -> String {
        let key = "\(endpoint.baseURL.absoluteString) \(endpoint.model)"
        let extras = plain.get().contains(key) ? [:] : endpoint.provider.textExtras
        do {
            return try await chat(endpoint, system: system, user: user, maxTokens: maxTokens,
                                  extras: extras, timeout: timeout)
        } catch APIError.http(status: 400, _) where !extras.isEmpty {
            // The preset's switches fit the preset's model; one the user typed
            // in may not have them. Plain from now on — for this launch — but
            // only once plain is accepted: a 400 for the text itself (a content
            // filter) would fail plain too, and must not cost the switches.
            let text = try await chat(endpoint, system: system, user: user, maxTokens: maxTokens,
                                      extras: [:], timeout: timeout)
            plain.mutate { _ = $0.insert(key) }
            DebugLog.shared.log("API", "\(endpoint.model) refused the preset's speed settings — sending without them")
            return text
        }
    }

    /// Base URL + model pairs that answered 400 to `textExtras`.
    private static let plain = LockedValue<Set<String>>([])

    private static func chat(_ endpoint: APIEndpoint, system: String, user: String, maxTokens: Int,
                             extras: [String: Any], timeout: TimeInterval) async throws -> String {
        var body = extras
        body["model"] = endpoint.model
        let path: String
        switch endpoint.provider.wire {
        case .openAI:
            path = "chat/completions"
            var messages: [[String: String]] = []
            if !system.isEmpty { messages.append(["role": "system", "content": system]) }
            messages.append(["role": "user", "content": user])
            body["messages"] = messages
            body[endpoint.provider.tokenField] = maxTokens
        case .anthropic:
            path = "messages"
            if !system.isEmpty { body["system"] = system }
            body["messages"] = [["role": "user", "content": user]]
            // Current Claude models may think first, and thinking counts
            // against max_tokens: headroom for it.
            body["max_tokens"] = maxTokens + 1024
        }
        var request = makeRequest(endpoint, path: path, timeout: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let json = try await send(request)
        switch endpoint.provider.wire {
        case .openAI:
            let choice = (json["choices"] as? [[String: Any]])?.first
            return (choice?["message"] as? [String: Any])?["content"] as? String ?? ""
        case .anthropic:
            // A refusal is an empty answer — an abstain, never an error.
            guard json["stop_reason"] as? String != "refusal" else { return "" }
            let blocks = json["content"] as? [[String: Any]] ?? []
            return blocks.filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }.joined()
        }
    }

    /// OpenAI's `audio/transcriptions` shape (OpenAI, Groq, Mistral, local
    /// whisper servers). `language` is ISO 639-1; nil lets the model detect
    /// it. `hints` are names and terms already in the field, for spelling —
    /// sent where the model documents a field for them.
    static func transcribe(_ endpoint: APIEndpoint, wav: Data, language: String?, hints: [String] = [],
                           timeout: TimeInterval) async throws -> String {
        let boundary = "pretype-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", endpoint.model)
        if endpoint.model.hasPrefix("gpt-transcribe") {
            // gpt-transcribe replaced `language` with a list and added keywords.
            if let language { field("languages[]", language) }
            for word in hints.prefix(50) where !word.contains(where: { "<>\r\n".contains($0) }) {
                field("keywords[]", word)
            }
        } else {
            if let language { field("language", language) }
            // Whisper reads the prompt as preceding text — names in it come
            // out spelled that way. 224 tokens at most.
            if sendsHints(model: endpoint.model, provider: endpoint.provider.id), !hints.isEmpty {
                field("prompt", hints.prefix(30).joined(separator: ", "))
            }
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = makeRequest(endpoint, path: "audio/transcriptions", timeout: timeout)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return try await send(request)["text"] as? String ?? ""
    }

    /// Whether `transcribe` sends the field's names along — the settings
    /// pane says so when it does. Refrain hands them to Apple's analyzer as
    /// contextual strings.
    static func sendsHints(model: String, provider: String) -> Bool {
        model.hasPrefix("gpt-transcribe") || model.contains("whisper") || provider == "refrain"
    }

    private static func makeRequest(_ endpoint: APIEndpoint, path: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = "POST"
        if let key = endpoint.key {
            switch endpoint.provider.wire {
            case .openAI: request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            case .anthropic: request.setValue(key, forHTTPHeaderField: "x-api-key")
            }
        }
        if endpoint.provider.wire == .anthropic {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        return request
    }

    private static func send(_ request: URLRequest) async throws -> [String: Any] {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            // Every caller already treats CancellationError as "superseded".
            throw CancellationError()
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            // Both wire formats put it at error.message. Capped: it lands in
            // Settings and the log, and a proxy's HTML error page is not a message.
            let message = ((json["error"] as? [String: Any])?["message"] as? String) ?? ""
            throw APIError.http(status: status, message: String(message.prefix(200)))
        }
        return json
    }
}

// MARK: - Text engine

/// Suggestions, ⌥⇥ fix, reply and voice commands on a hosted model. Prompted
/// like the Apple Intelligence path — an instruct model asked for the next
/// few words — and gated by the same shared output gates.
final class CloudEngine: CompletionEngine {
    let name: String
    private let endpoint: APIEndpoint?
    private let stateBox: LockedValue<EngineState>
    private let lengthBox = LockedValue<CompletionLength>(.short)
    private let instructionsBox = LockedValue<String>("")

    init(_ config: APIConfig) {
        name = "\(config.preset.name) · \(config.model)"
        do {
            endpoint = try config.endpoint()
            stateBox = LockedValue(.ready)
        } catch {
            endpoint = nil
            stateBox = LockedValue(.failed(error.localizedDescription))
        }
    }

    var state: EngineState { stateBox.get() }
    var loadedModelID: String? { endpoint?.model }
    var statusLine: String? {
        switch stateBox.get() {
        case .ready: return "API: \(name) (\(endpoint?.host ?? ""))"
        case .preparing(let detail), .failed(let detail): return "API: \(name) — \(detail)"
        }
    }

    func updateCompletion(length: CompletionLength, instructions: String) {
        lengthBox.set(length)
        instructionsBox.set(instructions)
    }

    func complete(_ request: CompletionRequest) async throws -> String? {
        guard case .ready = stateBox.get(), let endpoint else { return nil }
        guard let prepared = PreparedPrompt(String(request.textBeforeCaret.suffix(1200)), request: request,
                                            midWordFloor: 5, boundaryFloor: 8) else { return nil }
        let length = lengthBox.get()
        let turn = request.continuationTurn(prepared.text, instructions: instructionsBox.get())
        do {
            let raw = try await APIClient.chat(
                endpoint, system: turn.system + "\n\nLength: \(length.wordsHint).", user: turn.user,
                maxTokens: 128, timeout: 10)
            try Task.checkCancellation()
            return prepared.gate(cleanInstruct: true)(Self.clip(raw, words: Self.wordCap(length)))
        } catch let error as APIError {
            // Typing must never surface a network hiccup: abstain and log. A
            // rejected key is the one failure that won't heal by itself.
            if error.isAuth { stateBox.set(.failed(error.localizedDescription)) }
            DebugLog.shared.log("API", "abstain — \(error.localizedDescription)")
            return nil
        } catch let error as URLError {
            DebugLog.shared.log("API", "abstain — \(error.localizedDescription)")
            return nil
        }
    }

    func correct(selection: String, request: CompletionRequest,
                 redactLog: Bool) async throws -> String? {
        try await CorrectionGates.fix(selection, redactLog: redactLog, logTag: "API", generate: try chat())
    }

    func reply(to conversation: String, request: CompletionRequest) async throws -> String? {
        try await CorrectionGates.reply(to: conversation, request: request,
                                        instructions: instructionsBox.get(), generate: try chat())
    }

    func rewrite(selection: String, instruction: String,
                 request: CompletionRequest) async throws -> String? {
        try await CorrectionGates.rewrite(selection, instruction: instruction, generate: try chat())
    }

    /// One system-less turn for fix, reply and rewrite. These are explicit
    /// requests: when the API isn't set up this throws, saying why nothing ran.
    private func chat() throws -> CorrectionGates.Generate {
        guard case .ready = stateBox.get(), let endpoint else {
            throw EngineNotReady(message: String(localized: "API isn't set up — see Settings → API"))
        }
        return { try await APIClient.chat(endpoint, system: "", user: $0, maxTokens: $1, timeout: 30) }
    }

    /// The token budget can't cap a hosted model's length — a thinking model
    /// spends tokens before the first word — so the words hint asks and this
    /// enforces. Generous on purpose: it catches a model that ignores the hint.
    static func wordCap(_ length: CompletionLength) -> Int {
        switch length {
        case .short: return 4
        case .medium: return 8
        case .long: return 20
        }
    }

    /// `text` cut after its `words`-th whitespace-separated word.
    static func clip(_ text: String, words: Int) -> String {
        let runs = text.ranges(of: #/\S+/#)
        guard words > 0, runs.count >= words else { return text }
        return String(text[..<runs[words - 1].upperBound])
    }

    /// The Settings "Test" button: one tiny round trip, timed.
    static func test(_ config: APIConfig) async -> String {
        let start = Date()
        do {
            _ = try await APIClient.chat(try config.endpoint(), system: "Reply with the single word OK.",
                                         user: "ping", maxTokens: 16, timeout: 20)
            return String(localized: "✓ Connected — answered in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        } catch {
            return "⚠︎ \(error.localizedDescription)"
        }
    }
}
