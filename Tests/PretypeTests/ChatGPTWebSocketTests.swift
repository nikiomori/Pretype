import Foundation
import XCTest
@testable import Pretype

private final class SocketFixture: @unchecked Sendable {
    let sent = LockedValue<[Data]>([])
    let closes = LockedValue(0)
    let messages: AsyncThrowingStream<Data, Error>
    let continuation: AsyncThrowingStream<Data, Error>.Continuation
    var rejectsUpgrade = false

    init() { (messages, continuation) = AsyncThrowingStream.makeStream() }

    var socket: ChatGPTWebSocket.Socket {
        ChatGPTWebSocket.Socket(send: { [self] data in
            sent.mutate { $0.append(data) }
        }, receive: { [self] in
            var iterator = messages.makeAsyncIterator()
            guard let data = try await iterator.next() else { throw ChatGPTError.interrupted }
            return data
        }, cancel: { [self] in
            closes.mutate { $0 += 1 }
            continuation.finish(throwing: CancellationError())
        }, rejectedUpgrade: { [self] in rejectsUpgrade })
    }

    func emit(_ value: [String: Any]) throws {
        continuation.yield(try JSONSerialization.data(withJSONObject: value))
    }

    func answer(_ text: String) throws {
        try emit(["type": "response.output_text.delta", "delta": text])
        try emit(["type": "response.completed", "response": ["status": "completed"]])
    }
}

final class ChatGPTWebSocketTests: XCTestCase {
    private func request(token: String = "fixture") throws -> URLRequest {
        try ChatGPTResponses.request(model: "m", system: "rules", user: "synthetic", token: token, timeout: 2)
    }

    private func waitForSend(_ fixture: SocketFixture) async throws {
        for _ in 0..<200 {
            if !fixture.sent.get().isEmpty { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("request was not sent")
    }

    func testReusesCompletedConnectionWithoutConversationHistory() async throws {
        let fixture = SocketFixture(), connections = LockedValue(0)
        let transport = ChatGPTWebSocket { _, _ in connections.mutate { $0 += 1 }; return fixture.socket }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for _ in 0..<2 {
            try fixture.answer("next words")
            let answer = try await transport.generate(request(), session: session, timeout: 2)
            XCTAssertEqual(answer, "next words")
        }
        XCTAssertEqual(connections.get(), 1)
        XCTAssertEqual(fixture.closes.get(), 0)
        for data in fixture.sent.get() {
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(body["type"] as? String, "response.create")
            XCTAssertEqual(body["store"] as? Bool, false)
            XCTAssertTrue(body["previous_response_id"] is NSNull)
            XCTAssertNil(body["stream"])
            XCTAssertNil(body["service_tier"])
            XCTAssertEqual((body["input"] as? [[String: String]])?.first?["content"], "synthetic")
        }
    }

    func testCancellationClosesOnlyItsLeaseAndNextRequestWorks() async throws {
        let first = SocketFixture(), second = SocketFixture(), count = LockedValue(0)
        let transport = ChatGPTWebSocket { _, _ in
            count.mutate { $0 += 1; return $0 == 1 ? first.socket : second.socket }
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let request = try request()
        let pending = Task { try await transport.generate(request, session: session, timeout: 2) }
        try await waitForSend(first)
        try first.emit(["type": "response.output_text.delta", "delta": "never offer"])
        pending.cancel()
        do { _ = try await pending.value; XCTFail("cancelled output") } catch {}
        XCTAssertGreaterThan(first.closes.get(), 0)
        try second.answer("fresh")
        let answer = try await transport.generate(request, session: session, timeout: 2)
        pending.cancel() // old cancellation cannot touch the newly idle socket
        XCTAssertEqual(answer, "fresh")
        XCTAssertEqual(second.closes.get(), 0)
    }

    func testParallelRequestsCannotConsumeEachOthersEvents() async throws {
        let first = SocketFixture(), second = SocketFixture(), count = LockedValue(0)
        let transport = ChatGPTWebSocket { _, _ in
            count.mutate { $0 += 1; return $0 == 1 ? first.socket : second.socket }
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let request = try request()
        let one = Task { try await transport.generate(request, session: session, timeout: 2) }
        try await waitForSend(first)
        let two = Task { try await transport.generate(request, session: session, timeout: 2) }
        try await waitForSend(second)
        try second.answer("second")
        let result2 = try await two.value
        try first.answer("first")
        let result1 = try await one.value
        XCTAssertEqual(result1, "first")
        XCTAssertEqual(result2, "second")
        XCTAssertEqual(count.get(), 2)
        XCTAssertEqual(first.closes.get() + second.closes.get(), 1, "keep only one idle connection")
    }

    func testTokenRotationAndSessionChangesRequireNewConnections() async throws {
        let sockets = (0..<3).map { _ in SocketFixture() }, count = LockedValue(0)
        let transport = ChatGPTWebSocket { _, _ in count.mutate { i in defer { i += 1 }; return sockets[i].socket } }
        let first = URLSession(configuration: .ephemeral), second = URLSession(configuration: .ephemeral)
        defer { first.invalidateAndCancel(); second.invalidateAndCancel() }
        for (index, token, session) in [(0, "old", first), (1, "rotated", first), (2, "rotated", second)] {
            try sockets[index].answer("ok")
            _ = try await transport.generate(request(token: token), session: session, timeout: 2)
        }
        XCTAssertEqual(count.get(), 3)
        XCTAssertEqual(sockets[0].closes.get(), 1)
        XCTAssertEqual(sockets[1].closes.get(), 1)
    }

    func testClosedIdleSocketRetriesOnceOnAFreshOne() async throws {
        let first = SocketFixture(), second = SocketFixture(), count = LockedValue(0)
        let transport = ChatGPTWebSocket { _, _ in count.mutate { $0 += 1; return $0 == 1 ? first.socket : second.socket } }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        try first.answer("first")
        _ = try await transport.generate(request(), session: session, timeout: 2)
        first.continuation.finish(throwing: URLError(.cannotConnectToHost)) // the peer closed it while idle
        try second.answer("second")
        let answer = try await transport.generate(request(), session: session, timeout: 2)
        XCTAssertEqual(answer, "second")
        XCTAssertEqual(count.get(), 2)
    }

    func testExpiredIdleSocketIsReplaced() async throws {
        let clock = LockedValue(Date()), count = LockedValue(0)
        let first = SocketFixture(), second = SocketFixture()
        let transport = ChatGPTWebSocket(now: { clock.get() }, connect: { _, _ in
            count.mutate { $0 += 1; return $0 == 1 ? first.socket : second.socket }
        })
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        try first.answer("first")
        _ = try await transport.generate(request(), session: session, timeout: 2)
        clock.mutate { $0 = $0.addingTimeInterval(16) }
        try second.answer("second")
        _ = try await transport.generate(request(), session: session, timeout: 2)
        XCTAssertEqual(count.get(), 2)
        XCTAssertEqual(first.closes.get(), 1)
    }

    @MainActor func testAccountSwitchRejectsOldCompletedSocketOutput() async throws {
        let first = SocketFixture(), second = SocketFixture(), count = LockedValue(0)
        let accounts = ChatGPTAccounts(storage: .memory(), makeSession: ChatGPTStub.session, makeResponses: {
            ChatGPTWebSocket { _, _ in count.mutate { $0 += 1; return $0 == 1 ? first.socket : second.socket } }
        })
        let tokens = ChatGPTTokens(accessToken: "fixture", refreshToken: "fixture", idToken: "fixture",
            expiresAt: Date().addingTimeInterval(3600), scopes: ["chatgpt.tokens.use.direct"])
        let profile = ChatGPTProfile(clientID: "one", subject: "one", email: "fixture@example.test", tokens: tokens, model: "m")
        try accounts.install(profile)
        ChatGPTStub.handler.set { _ in
            (200, Data(#"{"models":[{"slug":"m","display_name":"Model","visibility":"list"}]}"#.utf8), "application/json")
        }
        defer { ChatGPTStub.handler.set(nil) }
        let oldGeneration = ChatGPTAccounts.generation.get()
        let pending = Task { try await accounts.generate(model: "m", system: "", user: "old", timeout: 2, generation: oldGeneration) }
        try await waitForSend(first)
        try accounts.install(ChatGPTProfile(clientID: "two", subject: "two", email: "other@example.test", tokens: tokens, model: "m"))
        try first.answer("stale") // even if a terminal event wins the session cancellation race
        do { _ = try await pending.value; XCTFail("stale account output") } catch { XCTAssertTrue(error is CancellationError) }
        try second.answer("new")
        let answer = try await accounts.generate(model: "m", system: "", user: "new", timeout: 2, generation: ChatGPTAccounts.generation.get())
        XCTAssertEqual(answer, "new")
    }

    func testFailedIncompleteAndInterruptedResultsNeverEscapeOrReuseSocket() async throws {
        let endings: [[String: Any]?] = [
            ["type": "response.failed", "response": ["error": ["code": "subscription_sharing_usage_limit_exceeded"]]],
            ["type": "response.incomplete"], ["type": "error", "code": "subscription_sharing_usage_unavailable"], nil
        ]
        for ending in endings {
            let fixture = SocketFixture()
            let transport = ChatGPTWebSocket { _, _ in fixture.socket }
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            try fixture.emit(["type": "response.output_text.delta", "delta": "partial"])
            if let ending { try fixture.emit(ending) } else { fixture.continuation.finish() }
            do { _ = try await transport.generate(request(), session: session, timeout: 2); XCTFail("partial output") } catch {}
            XCTAssertGreaterThan(fixture.closes.get(), 0)
            XCTAssertEqual(fixture.sent.get().count, 1, "no replay after partial/error output")
        }
    }

    func testDeadlineClosesHungSocket() async throws {
        let fixture = SocketFixture()
        let transport = ChatGPTWebSocket { _, _ in fixture.socket }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let started = Date()
        do { _ = try await transport.generate(request(), session: session, timeout: 0.03); XCTFail("deadline") } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertGreaterThan(fixture.closes.get(), 0)
    }

    func testOnlyRejectedUpgradeFallsBackToHTTPWithinSameRequest() async throws {
        let fixture = SocketFixture()
        fixture.rejectsUpgrade = true
        fixture.continuation.finish(throwing: URLError(.badServerResponse))
        let count = LockedValue(0)
        let transport = ChatGPTWebSocket { _, _ in count.mutate { $0 += 1 }; return fixture.socket }
        ChatGPTStub.handler.set { _ in
            (200, Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"fallback\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n".utf8), "text/event-stream")
        }
        ChatGPTStub.holdResponses.set(false)
        let session = ChatGPTStub.session()
        defer { session.invalidateAndCancel(); ChatGPTStub.handler.set(nil) }
        for _ in 0..<2 {
            let answer = try await transport.generate(request(), session: session, timeout: 2)
            XCTAssertEqual(answer, "fallback")
        }
        XCTAssertEqual(count.get(), 1, "unsupported upgrade isn't tried on every keystroke")
    }
}
