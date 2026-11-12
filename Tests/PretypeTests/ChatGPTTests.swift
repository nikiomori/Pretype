import CryptoKit
import Security
import XCTest
@testable import Pretype

final class ChatGPTStub: URLProtocol {
    static let handler = LockedValue<((URLRequest) throws -> (Int, Data, String))?>(nil)
    static let calls = LockedValue(0)
    static let holdResponses = LockedValue(false)
    static let onHeld = LockedValue<(() -> Void)?>(nil)
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.calls.mutate { $0 += 1 }
        if Self.holdResponses.get(), request.url?.path == "/v1/responses" {
            Self.onHeld.get()?()
            return
        }
        do {
            let reply = try Self.handler.get()?(request) ?? (500, Data(), "application/json")
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: reply.0, httpVersion: nil,
                                                        headerFields: reply.2.isEmpty ? [:] : ["Content-Type": reply.2]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.1)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChatGPTStub.self]
        return URLSession(configuration: config)
    }
}

final class ChatGPTTests: XCTestCase {
    override func setUp() {
        ChatGPTStub.handler.set(nil)
        ChatGPTStub.calls.set(0)
        ChatGPTStub.holdResponses.set(false)
        ChatGPTStub.onHeld.set(nil)
    }

    private func stream(_ events: [[String: Any]]) throws -> Data {
        try events.reduce(into: Data()) { data, event in
            data.append(Data("data: ".utf8))
            data.append(try JSONSerialization.data(withJSONObject: event))
            data.append(Data("\r\n\r\n".utf8))
        }
    }

    private var completed: [String: Any] { ["type": "response.completed", "response": ["status": "completed"]] }

    func testStreamRequiresSuccessfulTerminalEvent() throws {
        var parser = ChatGPTEventStream()
        let partial = try stream([["type": "response.output_text.delta", "delta": "Hello 世界"]])
        for byte in partial { try parser.append(byte) }
        XCTAssertThrowsError(try parser.result())
        for byte in try stream([completed]) { try parser.append(byte) }
        XCTAssertEqual(try parser.result(), "Hello 世界")
    }

    func testStreamDiscardsPartialOutputOnLimitOrIncomplete() throws {
        for event: [String: Any] in [
            ["type": "response.failed", "response": ["error": ["code": "subscription_sharing_usage_limit_exceeded"]]],
            ["type": "response.incomplete"], ["type": "error", "code": "subscription_sharing_usage_unavailable"]
        ] {
            var parser = ChatGPTEventStream()
            for byte in try stream([["type": "response.output_text.delta", "delta": "partial"]]) { try parser.append(byte) }
            XCTAssertThrowsError(try stream([event]).forEach { try parser.append($0) })
            XCTAssertThrowsError(try parser.result())
        }
    }

    func testMalformedAndOversizedStreamsFailClosed() throws {
        var parser = ChatGPTEventStream()
        XCTAssertThrowsError(try Data("data: not-json\n\n".utf8).forEach { try parser.append($0) })
        var oversized = ChatGPTEventStream()
        XCTAssertThrowsError(try (0...262144).forEach { _ in try oversized.append(65) })
        var empty = ChatGPTEventStream()
        for byte in try stream([completed]) { try empty.append(byte) }
        XCTAssertThrowsError(try empty.result())
    }

    func testResponsesUsesOnlySupportedFieldsAndFixedPublicEndpoint() throws {
        let request = try ChatGPTResponses.request(model: "m", system: "sys", user: "input", token: "fixture", timeout: 10)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["model", "instructions", "input", "store", "stream"])
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["instructions"] as? String, "sys")
    }

    func testLiveTransportReadsTerminalAndRejectsBrokenStream() async throws {
        let good = try stream([["type": "response.output_text.delta", "delta": "answer"], completed])
        ChatGPTStub.handler.set { _ in (200, good, "text/event-stream") }
        let session = ChatGPTStub.session()
        defer { session.invalidateAndCancel() }
        let answer = try await ChatGPTResponses.generate(model: "m", system: "", user: "test", token: "fixture",
                                                         session: session, timeout: 2)
        XCTAssertEqual(answer, "answer")
        ChatGPTStub.handler.set { _ in (200, Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n".utf8), "text/event-stream") }
        do {
            _ = try await ChatGPTResponses.generate(model: "m", system: "", user: "test", token: "fixture", session: session, timeout: 2)
            XCTFail("an interrupted response must not reach insertion")
        } catch { XCTAssertEqual(error as? ChatGPTError, .interrupted) }
    }

    func testMissingContentTypeStillRequiresCompletedEventStream() async throws {
        let good = try stream([["type": "response.output_text.delta", "delta": "answer"], completed])
        ChatGPTStub.handler.set { _ in (200, good, "") }
        let session = ChatGPTStub.session()
        defer { session.invalidateAndCancel() }
        let answer = try await ChatGPTResponses.generate(model: "m", system: "", user: "test", token: "fixture",
                                                         session: session, timeout: 2)
        XCTAssertEqual(answer, "answer")
        let partial = try stream([["type": "response.output_text.delta", "delta": "partial"]])
        for body in [partial, Data(#"{"status":"completed","output_text":"not an event stream"}"#.utf8)] {
            ChatGPTStub.handler.set { _ in (200, body, "") }
            do {
                _ = try await ChatGPTResponses.generate(model: "m", system: "", user: "test", token: "fixture",
                                                        session: session, timeout: 2)
                XCTFail("a missing content type must not bypass terminal-event validation")
            } catch { XCTAssertEqual(error as? ChatGPTError, .interrupted) }
        }
        ChatGPTStub.handler.set { _ in (200, good, "application/json") }
        do {
            _ = try await ChatGPTResponses.generate(model: "m", system: "", user: "test", token: "fixture",
                                                    session: session, timeout: 2)
            XCTFail("an explicitly incompatible content type must be rejected")
        } catch { XCTAssertEqual(error as? ChatGPTError, .interrupted) }
    }

    func testModelCatalogIsAccountSpecificAndKeepsServerOrder() async throws {
        ChatGPTStub.handler.set { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer selected-account")
            return (200, Data(#"{"models":[{"slug":"b","display_name":"B","visibility":"list"},{"slug":"a","display_name":"A","visibility":"list"},{"slug":"hidden","display_name":"Hidden","visibility":"hidden"}]}"#.utf8), "application/json")
        }
        let session = ChatGPTStub.session()
        defer { session.invalidateAndCancel() }
        let models = try await ChatGPTResponses.models(token: "selected-account", session: session)
        XCTAssertEqual(models.map(\.id), ["b", "a"])
    }

    func testTextReasoningUsesOnlyFastEffortsAdvertisedByTheAccount() throws {
        let cases: [([String]?, String?)] = [
            (nil, nil), ([], nil), (["future-effort", "high"], nil),
            (["medium", "low"], "low"), (["low", "minimal"], "minimal"),
            (["low", "none"], "none")
        ]
        for (levels, expected) in cases {
            var json: [String: Any] = ["slug": "m", "display_name": "Model", "visibility": "list"]
            if let levels { json["supported_reasoning_levels"] = levels.map { ["effort": $0] } }
            let model = try JSONDecoder().decode(ChatGPTModel.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(model.textReasoningEffort, expected)
        }
    }

    @MainActor func testAccountGenerationSendsAdvertisedLowReasoning() async throws {
        let accounts = ChatGPTAccounts(storage: .memory(), makeSession: ChatGPTStub.session, makeResponses: { nil })
        try accounts.install(fixture())
        let answer = try stream([["type": "response.output_text.delta", "delta": "corrected"], completed])
        ChatGPTStub.handler.set { request in
            if request.url?.path == "/v1/models" {
                return (200, Data(#"{"models":[{"slug":"m","display_name":"Model","visibility":"list","supported_reasoning_levels":[{"effort":"medium"},{"effort":"low"}]}]}"#.utf8), "application/json")
            }
            var data = request.httpBody ?? Data()
            if let input = request.httpBodyStream {
                input.open()
                defer { input.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while input.hasBytesAvailable {
                    let count = input.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(body["reasoning"] as? [String: String], ["effort": "low"])
            XCTAssertEqual(body["store"] as? Bool, false)
            XCTAssertEqual(body["stream"] as? Bool, true)
            XCTAssertNil(body["service_tier"], "do not opt into a paid speed tier")
            return (200, answer, "text/event-stream")
        }
        let result = try await accounts.generate(model: "m", system: "", user: "fixture", timeout: 2,
                                                 generation: ChatGPTAccounts.generation.get())
        XCTAssertEqual(result, "corrected")
    }

    func testOAuthPKCEAndHostIdentityAreBoundToAttempt() throws {
        let redirect = try XCTUnwrap(URL(string: "http://127.0.0.1:1455/auth/callback"))
        let login = try ChatGPTLogin(redirect: redirect, existing: nil)
        let url = try login.authorize(hostID: "urn:uuid:fixture")
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(values["client_id"], "dynamic_agent_client")
        XCTAssertEqual(values["ext_agent_host_id"], "urn:uuid:fixture")
        XCTAssertEqual(values["code_challenge"], Data(SHA256.hash(data: Data(login.verifier.utf8))).base64URL)
        XCTAssertEqual(values["redirect_uri"], redirect.absoluteString)
        XCTAssertNil(values["client_secret"])
        let second = try ChatGPTLogin(redirect: redirect, existing: nil)
        XCTAssertNotEqual(second.state, login.state)
        XCTAssertNotEqual(second.nonce, login.nonce)
    }

    func testOAuthRejectsWrongStateDuplicateParametersAndClientSubstitution() throws {
        let redirect = try XCTUnwrap(URL(string: "http://127.0.0.1:1455/auth/callback"))
        let profile = fixture()
        let login = try ChatGPTLogin(redirect: redirect, existing: profile)
        let valid = "\(redirect)?state=\(login.state)&code=one-use&client_id=\(profile.id)"
        XCTAssertEqual(try login.callback(XCTUnwrap(URL(string: valid))).clientID, profile.id)
        for invalid in [valid + "&state=other", valid.replacingOccurrences(of: login.state, with: "wrong"),
                        valid.replacingOccurrences(of: "client_id=client", with: "client_id=other"),
                        valid.replacingOccurrences(of: "127.0.0.1", with: "localhost")] {
            XCTAssertThrowsError(try login.callback(XCTUnwrap(URL(string: invalid))))
        }
        let denied = try XCTUnwrap(URL(string: "\(redirect)?state=\(login.state)&error=access_denied"))
        XCTAssertThrowsError(try login.callback(denied)) { XCTAssertEqual($0 as? ChatGPTError, .permission) }
    }

    func testNewRegistrationRequiresIssuedClientID() throws {
        let login = try ChatGPTLogin(redirect: XCTUnwrap(URL(string: "http://127.0.0.1:1455/auth/callback")), existing: nil)
        let callback = try XCTUnwrap(URL(string: "\(login.redirect)?state=\(login.state)&code=fixture"))
        XCTAssertThrowsError(try login.callback(callback))
    }

    func testLoopbackCancellationClosesPendingWait() async throws {
        let listener = try ChatGPTCallback()
        let url = try await listener.start()
        XCTAssertEqual(url.host, "127.0.0.1")
        let pending = Task { try await listener.callback(state: "fixture") }
        pending.cancel()
        do { _ = try await pending.value; XCTFail("cancel must stop waiting") } catch { XCTAssertTrue(error is CancellationError) }
    }

    /// Probes and a forged state get an answer but neither ends the wait nor
    /// fills the connection slots; the browser's redirect still gets through.
    func testLoopbackIgnoresProbesAndForeignState() async throws {
        let listener = try ChatGPTCallback()
        defer { listener.cancel() }
        let url = try await listener.start()
        let pending = Task { try await listener.callback(state: "right") }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for state in Array(repeating: "wrong", count: 12) + ["right"] {
            _ = try await session.data(from: XCTUnwrap(URL(string: "\(url)?state=\(state)&code=fixture")))
        }
        let received = try await pending.value
        XCTAssertTrue(received.absoluteString.hasSuffix("state=right&code=fixture"))
    }

    func testRS256IdentityRejectsTamperingAndClaimMismatch() throws {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        let privateKey = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        let exported = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        var offset = 0
        func value() throws -> Data {
            guard offset + 2 <= exported.count else { throw ChatGPTError.invalidLogin }
            offset += 1
            var size = Int(exported[offset]); offset += 1
            if size & 128 != 0 {
                let length = size & 127
                size = 0
                for _ in 0..<length { size = size * 256 + Int(exported[offset]); offset += 1 }
            }
            let result = exported.subdata(in: offset..<offset + size)
            offset += size
            return result
        }
        // Skip the sequence header, then export its two INTEGERs as a JWK.
        offset = 1
        let lengthBytes = Int(exported[offset]) & 127
        offset += Int(exported[offset]) & 128 != 0 ? 1 + lengthBytes : 1
        let n = try value().drop { $0 == 0 }
        let e = try value().drop { $0 == 0 }
        let jwks = try JSONSerialization.data(withJSONObject: ["keys": [["kid": "test", "kty": "RSA", "alg": "RS256",
            "n": Data(n).base64URL, "e": Data(e).base64URL]]])
        func token(_ claims: [String: Any]) throws -> String {
            let header = Data(#"{"alg":"RS256","kid":"test"}"#.utf8).base64URL
            let payload = try JSONSerialization.data(withJSONObject: claims).base64URL
            let body = "\(header).\(payload)"
            let signature = try XCTUnwrap(SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256,
                                                                Data(body.utf8) as CFData, nil)) as Data
            return "\(body).\(signature.base64URL)"
        }
        let claims: [String: Any] = ["iss": "https://auth.openai.com", "aud": "client", "sub": "person",
                                    "nonce": "nonce", "exp": Date().addingTimeInterval(60).timeIntervalSince1970]
        let signed = try token(claims)
        XCTAssertEqual(try ChatGPTIdentity.verify(signed, jwks: jwks, clientID: "client", nonce: "nonce").subject, "person")
        XCTAssertThrowsError(try ChatGPTIdentity.verify(signed, jwks: jwks, clientID: "wrong", nonce: "nonce"))
        XCTAssertThrowsError(try ChatGPTIdentity.verify(signed, jwks: jwks, clientID: "client", nonce: "wrong"))
        XCTAssertThrowsError(try ChatGPTIdentity.verify(signed + "x", jwks: jwks, clientID: "client", nonce: "nonce"))
        var expired = claims; expired["exp"] = 1
        XCTAssertThrowsError(try ChatGPTIdentity.verify(token(expired), jwks: jwks, clientID: "client", nonce: "nonce"))
    }

    private func fixture(id: String = "client", scopes: Set<String> = ["chatgpt.tokens.use.direct"], expired: Bool = false) -> ChatGPTProfile {
        ChatGPTProfile(clientID: id, subject: "person", email: "same@example.test",
            tokens: ChatGPTTokens(accessToken: "access-\(id)", refreshToken: "refresh-\(id)", idToken: "id-\(id)",
                expiresAt: Date().addingTimeInterval(expired ? -1 : 3600), scopes: scopes), model: "m")
    }

    @MainActor func testStorageFailurePreventsInferenceAndDoesNotOverwriteSavedData() async throws {
        let memory = ChatGPTStorage.memory()
        let fail = LockedValue(false)
        let storage = ChatGPTStorage(read: memory.read, write: { data in
            if fail.get() { throw ChatGPTError.storage }
            try memory.write(data)
        })
        let accounts = ChatGPTAccounts(storage: storage, makeSession: ChatGPTStub.session, makeResponses: { nil })
        try accounts.install(fixture())
        let saved = try memory.read()
        fail.set(true)
        XCTAssertThrowsError(try accounts.install(fixture(id: "other")))
        XCTAssertEqual(try memory.read(), saved)
        XCTAssertFalse(accounts.canGenerate)
        do { _ = try await accounts.credentials(generation: ChatGPTAccounts.generation.get()); XCTFail("storage failed") } catch { XCTAssertEqual(error as? ChatGPTError, .storage) }
    }

    @MainActor func testAccountsStaySeparateAndOldGenerationCannotSend() async throws {
        let memory = ChatGPTStorage.memory()
        let accounts = ChatGPTAccounts(storage: memory, makeSession: ChatGPTStub.session, makeResponses: { nil })
        try accounts.install(fixture())
        let old = ChatGPTAccounts.generation.get()
        try accounts.install(fixture(id: "other"))
        XCTAssertEqual(accounts.vault.profiles.count, 2)
        XCTAssertNotEqual(accounts.vault.profiles[0].label, accounts.vault.profiles[1].label)
        do { _ = try await accounts.credentials(generation: old); XCTFail("old account used") } catch { XCTAssertTrue(error is CancellationError) }
        let credentials = try await accounts.credentials(generation: ChatGPTAccounts.generation.get())
        XCTAssertEqual(credentials.0, "access-other")
        let restored = ChatGPTAccounts(storage: memory, makeSession: ChatGPTStub.session, makeResponses: { nil })
        XCTAssertEqual(restored.vault.hostID, accounts.vault.hostID)
        XCTAssertEqual(restored.selected?.id, "other")
    }

    @MainActor func testMissingPlanPermissionSendsNothing() async throws {
        let accounts = ChatGPTAccounts(storage: .memory(), makeSession: ChatGPTStub.session, makeResponses: { nil })
        try accounts.install(fixture(scopes: ["openid"]))
        do { _ = try await accounts.credentials(generation: ChatGPTAccounts.generation.get()); XCTFail("missing permission") } catch { XCTAssertEqual(error as? ChatGPTError, .permission) }
        XCTAssertEqual(ChatGPTStub.calls.get(), 0)
    }

    @MainActor func testConcurrentRefreshRotatesOnceAndPersistsTogether() async throws {
        let memory = ChatGPTStorage.memory()
        let accounts = ChatGPTAccounts(storage: memory, makeSession: ChatGPTStub.session, makeResponses: { nil })
        try accounts.install(fixture(expired: true))
        ChatGPTStub.handler.set { _ in
            (200, Data(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600,"token_type":"Bearer"}"#.utf8), "application/json")
        }
        let generation = ChatGPTAccounts.generation.get()
        async let first = accounts.credentials(generation: generation)
        async let second = accounts.credentials(generation: generation)
        let values = try await (first, second)
        XCTAssertEqual(values.0.0, "new-access")
        XCTAssertEqual(values.1.0, "new-access")
        XCTAssertEqual(ChatGPTStub.calls.get(), 1)
        let restored = ChatGPTAccounts(storage: memory, makeSession: ChatGPTStub.session, makeResponses: { nil })
        XCTAssertEqual(restored.selected?.tokens?.accessToken, "new-access")
        XCTAssertEqual(restored.selected?.tokens?.refreshToken, "new-refresh")
    }

    @MainActor func testCancelledRefreshWaiterStillSavesRotatedCredentials() async throws {
        let memory = ChatGPTStorage.memory()
        let accounts = ChatGPTAccounts(storage: memory, makeSession: ChatGPTStub.session, makeResponses: { nil })
        try accounts.install(fixture(expired: true))
        let entered = expectation(description: "refresh started")
        let release = DispatchSemaphore(value: 0)
        ChatGPTStub.handler.set { _ in
            entered.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return (200, Data(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600,"token_type":"Bearer"}"#.utf8), "application/json")
        }
        let generation = ChatGPTAccounts.generation.get()
        let waiter = Task { try await accounts.credentials(generation: generation) }
        await fulfillment(of: [entered], timeout: 2)
        waiter.cancel()
        release.signal()
        do { _ = try await waiter.value; XCTFail("cancelled waiter") } catch { XCTAssertTrue(error is CancellationError) }
        let restored = ChatGPTAccounts(storage: memory, makeSession: ChatGPTStub.session, makeResponses: { nil })
        XCTAssertEqual(restored.selected?.tokens?.refreshToken, "new-refresh")
    }

    /// A renewal whose only waiter was cancelled must not be served again
    /// when the renewed token expires: that one is stale by then.
    @MainActor func testFinishedRefreshIsNeverReusedAfterACancelledWaiter() async throws {
        let accounts = ChatGPTAccounts(storage: .memory(), makeSession: ChatGPTStub.session, makeResponses: { nil })
        try accounts.install(fixture(expired: true))
        let entered = expectation(description: "refresh started")
        let release = DispatchSemaphore(value: 0)
        ChatGPTStub.handler.set { _ in
            let call = ChatGPTStub.calls.get()
            if call == 1 { entered.fulfill(); _ = release.wait(timeout: .now() + 5) }
            // expires_in 1: already inside the 60-second renewal margin.
            return (200, Data(#"{"access_token":"access-\#(call)","refresh_token":"refresh-\#(call)","expires_in":1,"token_type":"Bearer"}"#.utf8), "application/json")
        }
        let generation = ChatGPTAccounts.generation.get()
        let waiter = Task { try await accounts.credentials(generation: generation) }
        await fulfillment(of: [entered], timeout: 2)
        waiter.cancel()
        release.signal()
        _ = try? await waiter.value
        let next = try await accounts.credentials(generation: generation)
        XCTAssertEqual(next.0, "access-2")
        XCTAssertEqual(ChatGPTStub.calls.get(), 2)
        XCTAssertEqual(accounts.vault.profiles.first?.tokens?.refreshToken, "refresh-2")
    }

    @MainActor func testAccountSwitchDuringRefreshKeepsRotatedTokens() async throws {
        let memory = ChatGPTStorage.memory()
        let accounts = ChatGPTAccounts(storage: memory, makeSession: ChatGPTStub.session, makeResponses: { nil })
        try accounts.install(fixture(expired: true))
        let entered = expectation(description: "refresh started")
        let release = DispatchSemaphore(value: 0)
        ChatGPTStub.handler.set { _ in
            entered.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return (200, Data(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600,"token_type":"Bearer"}"#.utf8), "application/json")
        }
        let generation = ChatGPTAccounts.generation.get()
        let waiter = Task { try await accounts.credentials(generation: generation) }
        await fulfillment(of: [entered], timeout: 2)
        try accounts.install(fixture(id: "other"))
        release.signal()
        do { _ = try await waiter.value; XCTFail("old account used") } catch { XCTAssertTrue(error is CancellationError) }
        let restored = ChatGPTAccounts(storage: memory, makeSession: ChatGPTStub.session, makeResponses: { nil })
        XCTAssertEqual(restored.vault.profiles.first { $0.id == "client" }?.tokens?.refreshToken, "new-refresh")
        XCTAssertEqual(restored.selected?.id, "other")
    }

    /// A reconnect lands while the old token's renewal is on the wire, and
    /// the server then rejects that old token: the new tokens stay in use.
    @MainActor func testRejectedOldTokenDoesNotPauseAReconnectedAccount() async throws {
        let accounts = ChatGPTAccounts(storage: .memory(), makeSession: ChatGPTStub.session, makeResponses: { nil })
        try accounts.install(fixture(expired: true))
        let entered = expectation(description: "refresh started")
        let release = DispatchSemaphore(value: 0)
        ChatGPTStub.handler.set { _ in
            entered.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return (400, Data(#"{"error":"invalid_grant"}"#.utf8), "application/json")
        }
        let waiter = Task { try await accounts.credentials(generation: ChatGPTAccounts.generation.get()) }
        await fulfillment(of: [entered], timeout: 2)
        var reconnected = fixture()
        reconnected.tokens = ChatGPTTokens(accessToken: "access-again", refreshToken: "refresh-again", idToken: "id-again",
                                           expiresAt: Date().addingTimeInterval(3600), scopes: ["chatgpt.tokens.use.direct"])
        try accounts.install(reconnected)
        release.signal()
        _ = try? await waiter.value
        XCTAssertNil(accounts.blocked)
        let token = try await accounts.credentials(generation: ChatGPTAccounts.generation.get()).0
        XCTAssertEqual(token, "access-again")
    }

    /// An engine keeps its transport across sign-ins: the account generation
    /// is read per request, so a later sign-in does not silence the engine.
    @MainActor func testTransportReadsTheAccountGenerationPerRequest() async throws {
        var config = APIConfig(provider: .named("chatgpt"), kind: .text)
        config.model = "m"
        let transport = TextGenerationTransport(endpoint: try config.endpoint())
        ChatGPTAccounts.generation.set(UUID())
        do {
            _ = try await transport.generate(system: "", user: "synthetic", maxTokens: 8, timeout: 1)
            XCTFail("the shared test vault has no account")
        } catch { XCTAssertFalse(error is CancellationError, "a stale build-time generation silences every request") }
    }

    @MainActor func testRepeatingFailureWaitsAndSaysWhy() async throws {
        let accounts = ChatGPTAccounts(storage: .memory(), makeSession: ChatGPTStub.session, makeResponses: { nil })
        XCTAssertNotNil(accounts.pausedReason, "no account: nothing can be sent")
        try accounts.install(fixture())
        XCTAssertNil(accounts.pausedReason)
        ChatGPTStub.handler.set { request in
            if request.url?.path == "/v1/models" {
                return (200, Data(#"{"models":[{"slug":"m","display_name":"Model","visibility":"list"}]}"#.utf8), "application/json")
            }
            return (500, Data(), "application/json")
        }
        let generation = ChatGPTAccounts.generation.get()
        for _ in 0..<2 {
            do { _ = try await accounts.generate(model: "m", system: "", user: "test", timeout: 2, generation: generation); XCTFail("server error") } catch { XCTAssertEqual(error as? ChatGPTError, .http(500)) }
        }
        XCTAssertEqual(ChatGPTStub.calls.get(), 2, "one catalog fetch and one inference; the second waits")
        XCTAssertEqual(accounts.pausedReason, ChatGPTError.http(500).localizedDescription)
    }

    @MainActor func testARejectedRequestDoesNotHoldUpTheNext() async throws {
        let accounts = ChatGPTAccounts(storage: .memory(), makeSession: ChatGPTStub.session, makeResponses: { nil })
        try accounts.install(fixture())
        ChatGPTStub.handler.set { request in
            if request.url?.path == "/v1/models" {
                return (200, Data(#"{"models":[{"slug":"m","display_name":"Model","visibility":"list"}]}"#.utf8), "application/json")
            }
            return (400, Data(), "application/json")
        }
        let generation = ChatGPTAccounts.generation.get()
        for _ in 0..<2 {
            do { _ = try await accounts.generate(model: "m", system: "", user: "test", timeout: 2, generation: generation); XCTFail("rejected") } catch { XCTAssertEqual(error as? ChatGPTError, .http(400)) }
        }
        XCTAssertEqual(ChatGPTStub.calls.get(), 3, "one catalog fetch and two inferences: a 4xx starts no wait")
        XCTAssertNil(accounts.pausedReason)
    }

    @MainActor func testQuotaFailurePausesFurtherRequestsWithoutSwitchingBilling() async throws {
        let accounts = ChatGPTAccounts(storage: .memory(), makeSession: ChatGPTStub.session, makeResponses: { nil })
        try accounts.install(fixture())
        let errorData = try stream([["type": "response.output_text.delta", "delta": "partial"],
            ["type": "response.failed", "response": ["error": ["code": "subscription_sharing_usage_limit_exceeded"]]]])
        ChatGPTStub.handler.set { request in
            if request.url?.path == "/v1/models" {
                return (200, Data(#"{"models":[{"slug":"m","display_name":"Model","visibility":"list"}]}"#.utf8), "application/json")
            }
            return (200, errorData, "text/event-stream")
        }
        let generation = ChatGPTAccounts.generation.get()
        for _ in 0..<2 {
            do { _ = try await accounts.generate(model: "m", system: "", user: "test", timeout: 2, generation: generation); XCTFail("quota") } catch { XCTAssertEqual(error as? ChatGPTError, .limit) }
        }
        XCTAssertEqual(ChatGPTStub.calls.get(), 2, "one catalog fetch and one inference; no automatic retry")
        XCTAssertNotNil(accounts.selected?.tokens)
    }

    @MainActor func testCancelledTypingDoesNotPauseTheNextSuggestion() async throws {
        let accounts = ChatGPTAccounts(storage: .memory(), makeSession: ChatGPTStub.session, makeResponses: { nil })
        try accounts.install(fixture())
        let answer = try stream([["type": "response.output_text.delta", "delta": "next words"], completed])
        ChatGPTStub.handler.set { request in
            if request.url?.path == "/v1/models" {
                return (200, Data(#"{"models":[{"slug":"m","display_name":"Model","visibility":"list"}]}"#.utf8), "application/json")
            }
            return (200, answer, "text/event-stream")
        }
        let held = expectation(description: "request in flight")
        ChatGPTStub.holdResponses.set(true)
        ChatGPTStub.onHeld.set { held.fulfill() }
        let generation = ChatGPTAccounts.generation.get()
        let typing = Task { try await accounts.generate(model: "m", system: "", user: "old", timeout: 2, generation: generation) }
        await fulfillment(of: [held], timeout: 2)
        typing.cancel()
        do { _ = try await typing.value; XCTFail("cancelled typing must not produce text") } catch {}
        XCTAssertNil(accounts.blocked)
        XCTAssertNil(accounts.notice)
        ChatGPTStub.holdResponses.set(false)
        let next = try await accounts.generate(model: "m", system: "", user: "new", timeout: 2, generation: generation)
        XCTAssertEqual(next, "next words", "cancellation must not start the outage cooldown")
    }

    @MainActor func testLogoutClearsTokensButRetainsRegistrationAndHost() async throws {
        let accounts = ChatGPTAccounts(storage: .memory(), makeSession: ChatGPTStub.session, makeResponses: { nil })
        try accounts.install(fixture())
        let host = accounts.vault.hostID
        ChatGPTStub.handler.set { _ in (503, Data(), "application/json") }
        await accounts.signOut()
        XCTAssertNil(accounts.selected?.tokens)
        XCTAssertEqual(accounts.selected?.clientID, "client")
        XCTAssertEqual(accounts.vault.hostID, host)
        XCTAssertNotNil(accounts.notice)
    }

    // The menu retries what a retry can end; the rest is set in Settings → API.
    func testMenuRetriesALimitAndSendsSignInToSettings() {
        let needsSettings = StatusMenuController.chatGPTNeedsSettings
        XCTAssertFalse(needsSettings(.limit, true, true))
        XCTAssertFalse(needsSettings(.http(500), true, true))
        XCTAssertFalse(needsSettings(nil, true, true), "a cooldown")
        XCTAssertTrue(needsSettings(.signIn, true, true))
        XCTAssertTrue(needsSettings(.model, true, true))
        XCTAssertTrue(needsSettings(nil, false, true), "no account, or one signed out")
        XCTAssertTrue(needsSettings(nil, true, false), "no model picked")
    }

    func testSubscriptionCannotUseTheTranscriptionEndpoint() async throws {
        var config = APIConfig(provider: .named("chatgpt"), kind: .text)
        config.model = "m"
        do {
            _ = try await APIClient.transcribe(config.endpoint(), wav: Data(), language: nil, timeout: 1)
            XCTFail("subscription audio is unsupported")
        } catch { XCTAssertEqual(error as? ChatGPTError, .unsupported) }
    }

    func testLegacyConfigurationAndAudioChoicesAreUnchanged() throws {
        let json = Data(#"{"enabled":true,"provider":"openai","baseURL":"https://api.openai.com/v1","model":"existing"}"#.utf8)
        let config = try JSONDecoder().decode(APIConfig.self, from: json)
        XCTAssertEqual(config.provider, "openai")
        XCTAssertEqual(config.model, "existing")
        XCTAssertFalse(APIProvider.offering(.audio).contains { $0.id == "chatgpt" })
        var subscription = APIConfig(provider: .named("chatgpt"), kind: .text)
        XCTAssertFalse(subscription.enabled)
        XCTAssertThrowsError(try subscription.endpoint(), "a model must be chosen")
        subscription.model = "m"
        subscription.baseURL = "https://example.test/v1"
        XCTAssertThrowsError(try subscription.endpoint(), "subscription tokens never go to a custom URL")
    }
}
