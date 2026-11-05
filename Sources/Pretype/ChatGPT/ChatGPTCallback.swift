import Foundation
import Network

/// A short-lived IPv4 loopback listener. Never binds a public interface.
final class ChatGPTCallback: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.pretype.chatgpt.callback")
    private let events: AsyncThrowingStream<URL, Error>
    private let continuation: AsyncThrowingStream<URL, Error>.Continuation
    private let ready = LockedValue<CheckedContinuation<UInt16, Error>?>(nil)
    private let connections = LockedValue<[NWConnection]>([])

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: params)
        let stream = AsyncThrowingStream<URL, Error>.makeStream()
        events = stream.stream
        continuation = stream.continuation
    }

    func start() async throws -> URL {
        let port: UInt16 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiting in
                ready.set(waiting)
                if Task.isCancelled { cancel(); return }
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        if let port = self.listener.port?.rawValue { self.ready.exchange(nil)?.resume(returning: port) }
                    case .failed:
                        self.ready.exchange(nil)?.resume(throwing: ChatGPTError.invalidLogin)
                        self.continuation.finish(throwing: ChatGPTError.invalidLogin)
                    case .cancelled:
                        self.ready.exchange(nil)?.resume(throwing: CancellationError())
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self else { connection.cancel(); return }
                    // Bound resource use even if another local process opens connections.
                    let accepted = self.connections.mutate { list -> Bool in
                        guard list.count < 8 else { return false }
                        list.append(connection)
                        return true
                    }
                    guard accepted else { connection.cancel(); return }
                    connection.start(queue: self.queue)
                    self.receive(connection, accumulated: Data())
                }
                listener.start(queue: queue)
            }
        } onCancel: { self.cancel() }
        guard let url = URL(string: "http://127.0.0.1:\(port)/auth/callback") else { throw ChatGPTError.invalidLogin }
        return url
    }

    func callback() async throws -> URL {
        try await withTaskCancellationHandler {
            for try await url in events { return url }
            throw CancellationError()
        } onCancel: { self.cancel() }
    }

    func cancel() {
        ready.exchange(nil)?.resume(throwing: CancellationError())
        continuation.finish(throwing: CancellationError())
        listener.cancel()
        connections.exchange([]).forEach { $0.cancel() }
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            guard let self else { connection.cancel(); return }
            let bytes = accumulated + (data ?? Data())
            guard bytes.count <= 16384, error == nil else { connection.cancel(); return }
            guard let text = String(data: bytes, encoding: .utf8), text.contains("\r\n\r\n") else {
                if done { connection.cancel() } else { self.receive(connection, accumulated: bytes) }
                return
            }
            let line = text.components(separatedBy: "\r\n").first ?? ""
            let parts = line.split(separator: " ")
            guard parts.count == 3, parts[0] == "GET", parts[1].hasPrefix("/auth/callback?"),
                  let port = self.listener.port?.rawValue,
                  let url = URL(string: "http://127.0.0.1:\(port)\(parts[1])") else {
                connection.cancel()
                return
            }
            let body = "Return to Pretype to see the sign-in result."
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            self.continuation.yield(url)
            self.continuation.finish()
        }
    }
}
