import Foundation

struct ChatGPTModel: Identifiable, Decodable, Equatable {
    let slug: String
    let displayName: String
    let visibility: String
    var id: String { slug }
    enum CodingKeys: String, CodingKey { case slug, displayName = "display_name", visibility }
}

enum ChatGPTResponses {
    static let baseURL = URL(string: "https://api.openai.com/v1")!

    static func models(token: String, session: URLSession) async throws -> [ChatGPTModel] {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        struct Catalog: Decodable { let models: [ChatGPTModel] }
        let data = try await ChatGPTHTTP.data(request, session: session)
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        var seen = Set<String>()
        return catalog.models.filter { $0.visibility == "list" && !$0.slug.isEmpty && seen.insert($0.slug).inserted }
    }

    static func request(model: String, system: String, user: String, token: String, timeout: TimeInterval) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("responses"), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // This subscription route rejects the chat endpoint's sampling and
        // token-limit fields. Output gates still enforce Pretype's word cap.
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "instructions": system,
            "input": [["role": "user", "content": user]], "store": false, "stream": true])
        return request
    }

    static func generate(model: String, system: String, user: String, token: String,
                         session: URLSession, timeout: TimeInterval) async throws -> String {
        let request = try request(model: model, system: system, user: user, token: token, timeout: timeout)
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await read(request, session: session) }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw ChatGPTError.interrupted
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw ChatGPTError.interrupted }
            return result
        }
    }

    private static func read(_ request: URLRequest, session: URLSession) async throws -> String {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatGPTError.unavailable }
        guard (200..<300).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 65536 else { break }
                data.append(byte)
            }
            throw ChatGPTError.response(data, status: http.statusCode)
        }
        guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("text/event-stream") == true else {
            throw ChatGPTError.interrupted
        }
        var parser = ChatGPTEventStream()
        for try await byte in bytes {
            try Task.checkCancellation()
            try parser.append(byte)
            if parser.completed { return try parser.result() }
        }
        throw ChatGPTError.interrupted
    }
}

/// Byte-oriented SSE parser preserves blank event boundaries and split UTF-8.
/// Nothing escapes this buffer until a successful terminal event arrives.
struct ChatGPTEventStream {
    private var line = Data()
    private var event: [String] = []
    private var output = ""
    private var count = 0
    private(set) var completed = false

    mutating func append(_ byte: UInt8) throws {
        count += 1
        guard count <= 2 * 1024 * 1024, line.count < 256 * 1024 else { throw ChatGPTError.interrupted }
        guard !completed else { return }
        if byte != 10 { line.append(byte); return }
        if line.last == 13 { line.removeLast() }
        guard let text = String(data: line, encoding: .utf8) else { throw ChatGPTError.interrupted }
        line.removeAll(keepingCapacity: true)
        if text.isEmpty {
            try consume()
            event.removeAll(keepingCapacity: true)
        } else if text.hasPrefix("data:") {
            let value = text.dropFirst(5)
            event.append(String(value.first == " " ? value.dropFirst() : value))
        }
    }

    private mutating func consume() throws {
        guard !event.isEmpty else { return }
        guard let json = try JSONSerialization.jsonObject(with: Data(event.joined(separator: "\n").utf8)) as? [String: Any],
              let type = json["type"] as? String else { throw ChatGPTError.interrupted }
        switch type {
        case "response.output_text.delta":
            guard let delta = json["delta"] as? String else { throw ChatGPTError.interrupted }
            output += delta
            guard output.utf8.count <= 256 * 1024 else { throw ChatGPTError.interrupted }
        case "response.completed":
            guard let response = json["response"] as? [String: Any], response["status"] as? String == "completed" else {
                throw ChatGPTError.interrupted
            }
            completed = true
        case "response.failed", "error":
            let details = json["response"] as? [String: Any] ?? json
            throw ChatGPTError.response(try JSONSerialization.data(withJSONObject: details), status: 500)
        case "response.incomplete": throw ChatGPTError.interrupted
        default: break
        }
    }

    func result() throws -> String {
        guard completed, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatGPTError.interrupted }
        return output
    }
}
