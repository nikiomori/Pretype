import Foundation

/// One idle connection per account session. Concurrent actions get separate
/// leases rather than mixing responses or queuing behind a slow suggestion.
/// Every turn is independent: no response IDs or document history are reused.
actor ChatGPTWebSocket {
    struct Socket {
        var send: (Data) async throws -> Void
        var receive: () async throws -> Data
        var cancel: () -> Void
        var rejectedUpgrade: () -> Bool

        static func live(_ request: URLRequest, _ session: URLSession) -> Socket {
            var handshake = URLRequest(url: URL(string: "wss://api.openai.com/v1/responses")!)
            handshake.setValue(request.value(forHTTPHeaderField: "Authorization"), forHTTPHeaderField: "Authorization")
            let task = session.webSocketTask(with: handshake)
            task.maximumMessageSize = 256 * 1024
            task.resume()
            return Socket(send: { data in
                do { try await task.send(.data(data)) } catch { throw failure(error, task: task) }
            }, receive: {
                do {
                    switch try await task.receive() {
                    case .data(let data): return data
                    case .string(let text): return Data(text.utf8)
                    @unknown default: throw ChatGPTError.interrupted
                    }
                } catch { throw failure(error, task: task) }
            }, cancel: { task.cancel(with: .goingAway, reason: nil) }, rejectedUpgrade: {
                // Only an explicit unsupported upgrade permits HTTP fallback.
                // Never replay a partial generation, auth failure or quota error.
                guard let response = task.response as? HTTPURLResponse else { return false }
                return [404, 405, 426, 501].contains(response.statusCode)
            })
        }

        private static func failure(_ error: Error, task: URLSessionWebSocketTask) -> Error {
            if let response = task.response as? HTTPURLResponse, response.statusCode != 101 {
                return ChatGPTError.response(Data(), status: response.statusCode)
            }
            // An idle socket can be closed by the peer. Discard it, but don't
            // latch the account into a 30-second outage for the next keystroke.
            if (error as? URLError)?.code == .networkConnectionLost { return ChatGPTError.interrupted }
            return error
        }
    }

    /// A cancelled old caller must never close a connection already handed to
    /// its successor. Finish and cancellation compete under this one lock.
    private final class Lease: @unchecked Sendable {
        let socket: Socket
        private let active = LockedValue(true)
        init(_ socket: Socket) { self.socket = socket }
        func finish() -> Bool { active.exchange(false) }
        func cancel() { if active.exchange(false) { socket.cancel() } }
    }

    typealias Factory = (URLRequest, URLSession) -> Socket
    private let connect: Factory
    private let now: () -> Date
    private var idle: (socket: Socket, authorization: String?, session: URLSession, at: Date)?
    private var httpOnly = false

    init(now: @escaping () -> Date = Date.init, connect: @escaping Factory = Socket.live) {
        self.now = now
        self.connect = connect
    }
    deinit { idle?.socket.cancel() }

    static func message(_ request: URLRequest) throws -> Data {
        guard let data = request.httpBody,
              var body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ChatGPTError.interrupted }
        body.removeValue(forKey: "stream")
        body["type"] = "response.create"
        // Explicitly reset state even on a reused authenticated connection.
        body["previous_response_id"] = NSNull()
        return try JSONSerialization.data(withJSONObject: body)
    }

    func generate(_ request: URLRequest, session: URLSession, timeout: TimeInterval) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                do { return try await self.perform(request, session: session) } catch is StaleSocket {
                    return try await self.perform(request, session: session, fresh: true)
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw ChatGPTError.interrupted
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw ChatGPTError.interrupted }
            try Task.checkCancellation()
            return result
        }
    }

    private struct StaleSocket: Error {}

    private func perform(_ request: URLRequest, session: URLSession, fresh: Bool = false) async throws -> String {
        try Task.checkCancellation()
        if httpOnly { return try await ChatGPTResponses.read(request, session: session) }
        let authorization = request.value(forHTTPHeaderField: "Authorization")
        let socket: Socket
        let reused: Bool
        if !fresh, let old = idle, old.authorization == authorization, old.session === session,
           now().timeIntervalSince(old.at) < 15 {
            socket = old.socket
            reused = true
        } else {
            reused = false
            idle?.socket.cancel()
            socket = connect(request, session)
        }
        idle = nil
        let lease = Lease(socket)
        defer { lease.cancel() }
        let result = try await withTaskCancellationHandler {
            var received = false
            do {
                try Task.checkCancellation()
                try await socket.send(Self.message(request))
                var parser = ChatGPTEventStream()
                while !parser.completed {
                    let data = try await socket.receive()
                    received = true
                    try Task.checkCancellation()
                    try parser.append(message: data)
                }
                return try parser.result()
            } catch {
                try Task.checkCancellation()
                // The peer may have closed an idle socket. Nothing came back, so
                // nothing is replayed: send once more on a fresh connection.
                if reused, !received, (error as? ChatGPTError).map({ $0 == .interrupted }) ?? true { throw StaleSocket() }
                guard socket.rejectedUpgrade() else { throw error }
                socket.cancel()
                httpOnly = true
                return try await ChatGPTResponses.read(request, session: session)
            }
        } onCancel: { lease.cancel() }
        try Task.checkCancellation()
        guard lease.finish() else { throw CancellationError() }
        if !httpOnly, idle == nil {
            idle = (socket, authorization, session, now())
        } else {
            socket.cancel()
        }
        return result
    }
}
