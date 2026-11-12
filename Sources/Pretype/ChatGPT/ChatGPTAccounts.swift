import AppKit
import Foundation
import Observation

/// One owner for tokens, refreshes, and the active account. MainActor only
/// serializes state: HTTP and the browser callback suspend without blocking UI.
@MainActor @Observable
final class ChatGPTAccounts {
    static let shared = ChatGPTAccounts()
    nonisolated static let generation = LockedValue(UUID())

    private(set) var vault = ChatGPTVault()
    private(set) var models: [ChatGPTModel] = []
    private(set) var revision = UUID()
    private(set) var signingIn = false
    private(set) var busy = false
    private(set) var notice: String?
    private(set) var blocked: ChatGPTError?
    @ObservationIgnored private let storage: ChatGPTStorage
    @ObservationIgnored private let makeSession: () -> URLSession
    @ObservationIgnored private let makeResponses: () -> ChatGPTWebSocket?
    @ObservationIgnored private var responses: ChatGPTWebSocket?
    @ObservationIgnored private var session: URLSession
    @ObservationIgnored private var loginTask: Task<Void, Never>?
    /// One renewal per account. Kept across account switches: a rotated
    /// token that the server already issued must still reach the vault.
    @ObservationIgnored private var refreshes: [String: (id: UUID, task: Task<ChatGPTTokens, Error>)] = [:]
    @ObservationIgnored private var cooldown: (until: Date, error: ChatGPTError)?
    @ObservationIgnored private var storageError: ChatGPTError?
    private var storageFailed: Bool { storageError != nil }
    @ObservationIgnored private var catalogLoaded = false

    var selected: ChatGPTProfile? { vault.profiles.first { $0.id == vault.selectedID } }
    /// Why requests are held, for the status menu: suggestions drop these
    /// failures silently, and only Settings had said so.
    var pausedReason: String? {
        if let storageError { return storageError.localizedDescription }
        if let blocked { return blocked.localizedDescription }
        if let cooldown, cooldown.until > Date() { return cooldown.error.localizedDescription }
        guard let profile = selected else { return String(localized: "Sign in to ChatGPT in Settings → API.") }
        guard let tokens = profile.tokens else { return ChatGPTError.signIn.localizedDescription }
        guard tokens.scopes.contains("chatgpt.tokens.use.direct") else { return ChatGPTError.permission.localizedDescription }
        return profile.model.isEmpty ? ChatGPTError.model.localizedDescription : nil
    }
    var canGenerate: Bool { selected?.tokens?.scopes.contains("chatgpt.tokens.use.direct") == true && !storageFailed }

    init(storage: ChatGPTStorage = .keychain, makeSession: @escaping () -> URLSession = ChatGPTHTTP.session,
         makeResponses: @escaping () -> ChatGPTWebSocket? = { ChatGPTWebSocket() }) {
        self.storage = storage
        self.makeSession = makeSession
        self.makeResponses = makeResponses
        responses = makeResponses()
        session = makeSession()
        do {
            if let data = try storage.read() { vault = try JSONDecoder().decode(ChatGPTVault.self, from: data) } else { try storage.write(JSONEncoder().encode(vault)) }
        } catch {
            storageError = error as? ChatGPTError ?? .storage
            notice = storageError?.localizedDescription
        }
    }

    private func save(_ value: ChatGPTVault) throws {
        do { try storage.write(JSONEncoder().encode(value)) } catch {
            storageError = error as? ChatGPTError == .inUse ? .inUse : .storage
            throw ChatGPTError.storage
        }
        vault = value
        storageError = nil
    }

    /// Cancels active URLSession requests before any identity change. The
    /// generation also rejects a response that finished just before cancel.
    private func invalidate() {
        session.invalidateAndCancel()
        session = makeSession()
        responses = makeResponses()
        revision = UUID()
        Self.generation.set(revision)
        blocked = nil
        cooldown = nil
        models = []
        catalogLoaded = false
    }

    func select(_ id: String) async {
        guard vault.profiles.contains(where: { $0.id == id }), !signingIn, !busy else { return }
        invalidate()
        var next = vault
        next.selectedID = id
        do { try save(next); notice = nil; await loadModels() } catch { notice = ChatGPTError.storage.localizedDescription }
    }

    func chooseModel(_ model: String) {
        guard models.contains(where: { $0.id == model }), let index = vault.profiles.firstIndex(where: { $0.id == vault.selectedID }) else { return }
        var next = vault
        next.profiles[index].model = model
        do {
            try save(next)
            if blocked == .model { blocked = nil }
            cooldown = nil
            notice = nil
        } catch { notice = ChatGPTError.storage.localizedDescription }
    }

    func signIn(reconnect: Bool = false) {
        guard !signingIn, !busy, !storageFailed else { return }
        signingIn = true
        notice = nil
        let existing = reconnect ? selected : nil
        loginTask = Task { [weak self] in
            guard let self else { return }
            defer { self.signingIn = false; self.loginTask = nil }
            do {
                let callback = try ChatGPTCallback()
                defer { callback.cancel() }
                let profile = try await withThrowingTaskGroup(of: ChatGPTProfile.self) { group in
                    group.addTask { @MainActor in
                        let redirect = try await callback.start()
                        let login = try ChatGPTLogin(redirect: redirect, existing: existing)
                        guard NSWorkspace.shared.open(try login.authorize(hostID: self.vault.hostID)) else {
                            throw ChatGPTError.invalidLogin
                        }
                        let url = try await callback.callback(state: login.state)
                        let authSession = self.makeSession()
                        defer { authSession.invalidateAndCancel() }
                        return try await login.exchange(url, session: authSession)
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(180))
                        throw ChatGPTError.invalidLogin
                    }
                    defer { group.cancelAll() }
                    guard let profile = try await group.next() else { throw ChatGPTError.invalidLogin }
                    return profile
                }
                try Task.checkCancellation()
                // ponytail: the replaced refresh token is not revoked: under the same
                // client id a revoke may end the new grant too. Revoke it once a live
                // check shows the server revokes per token.
                try self.install(profile)
                await self.loadModels()
            } catch is CancellationError { self.notice = nil } catch { self.notice = (error as? ChatGPTError ?? .invalidLogin).localizedDescription }
        }
    }

    func cancelSignIn() { loginTask?.cancel() }

    /// Kept separate from the browser flow so storage and identity transitions
    /// can be tested with synthetic credentials, never the user's Keychain.
    func install(_ profile: ChatGPTProfile) throws {
        if let old = vault.profiles.first(where: { $0.id == profile.id }), old.subject != profile.subject {
            throw ChatGPTError.invalidLogin
        }
        var next = vault
        next.profiles.removeAll { $0.id == profile.id }
        next.profiles.append(profile)
        next.selectedID = profile.id
        invalidate()
        try save(next)
        notice = canGenerate ? nil : ChatGPTError.permission.localizedDescription
    }

    func signOut() async {
        guard let id = selected?.id, !busy, !signingIn else { return }
        busy = true
        // Stop inference immediately even while remote revocation is pending.
        blocked = .signIn
        defer { busy = false }
        // A renewal in flight rotates the token: revoke the one it returns.
        if let job = refreshes[id] { _ = try? await job.task.value }
        invalidate()
        blocked = .signIn
        let tokens = vault.profiles.first { $0.id == id }?.tokens
        var revoked = tokens == nil
        if let tokens, let clientID = selected?.clientID { revoked = await revoke(tokens.refreshToken, clientID: clientID) }
        var next = vault
        if let index = next.profiles.firstIndex(where: { $0.id == id }) { next.profiles[index].tokens = nil }
        do {
            try save(next)
            notice = revoked ? nil : String(localized: "Signed out locally. Remote revocation was not confirmed; disconnect Pretype in ChatGPT Settings.")
        } catch {
            // Never keep using tokens whose removal from disk failed.
            vault = next
            notice = ChatGPTError.storage.localizedDescription
        }
    }

    private func revoke(_ token: String, clientID: String) async -> Bool {
        let revocationSession = makeSession()
        defer { revocationSession.invalidateAndCancel() }
        do {
            let discovery = try await ChatGPTHTTP.data(URLRequest(url: ChatGPTLogin.issuer.appendingPathComponent(".well-known/openid-configuration")), session: revocationSession)
            let json = try JSONSerialization.jsonObject(with: discovery) as? [String: Any]
            guard let endpoint = json?["revocation_endpoint"] as? String, let url = URL(string: endpoint),
                  url.scheme == "https", url.host == "auth.openai.com", url.port == nil,
                  url.user == nil, url.password == nil else { throw ChatGPTError.invalidLogin }
            _ = try await ChatGPTHTTP.post(url, fields: ["token": token, "token_type_hint": "refresh_token",
                "client_id": clientID], session: revocationSession)
            return true
        } catch { return false }
    }

    func check(_ generation: UUID) throws {
        try Task.checkCancellation()
        guard generation == Self.generation.get() else { throw CancellationError() }
        if let storageError { throw storageError }
        if let blocked { throw blocked }
        if let cooldown, cooldown.until > Date() { throw cooldown.error }
    }

    func credentials(generation: UUID) async throws -> (String, URLSession) {
        try check(generation)
        guard let profile = selected, let tokens = profile.tokens else { throw ChatGPTError.signIn }
        guard tokens.scopes.contains("chatgpt.tokens.use.direct") else { throw ChatGPTError.permission }
        if tokens.expiresAt > Date().addingTimeInterval(60) { return (tokens.accessToken, session) }
        let job = refreshes[profile.id] ?? renew(profile.id, tokens)
        let renewed = try await job.task.value
        try check(generation)
        guard renewed.scopes.contains("chatgpt.tokens.use.direct") else { throw ChatGPTError.permission }
        return (renewed.accessToken, session)
    }

    /// The job commits by account, not by generation: neither a superseding
    /// keypress nor an account switch may drop a token the server rotated.
    /// It leaves `refreshes` when it ends, so a finished job is never reused.
    private func renew(_ id: String, _ tokens: ChatGPTTokens) -> (id: UUID, task: Task<ChatGPTTokens, Error>) {
        let jobID = UUID()
        let task = Task {
            defer { if self.refreshes[id]?.id == jobID { self.refreshes[id] = nil } }
            // Its own session: identity changes cancel the shared one.
            let refreshSession = self.makeSession()
            defer { refreshSession.invalidateAndCancel() }
            var renewed: ChatGPTTokens?
            do {
                let data = try await ChatGPTHTTP.post(ChatGPTLogin.tokenURL, fields: ["grant_type": "refresh_token",
                    "client_id": id, "refresh_token": tokens.refreshToken,
                    "resource": "https://api.openai.com/v1"], session: refreshSession)
                renewed = try ChatGPTTokens.decode(data, previous: tokens)
            } catch ChatGPTError.signIn {
                renewed = nil
            }
            var next = self.vault
            // Sign-out or a reconnect replaced these tokens meanwhile: keep theirs.
            guard let index = next.profiles.firstIndex(where: { $0.id == id }),
                  next.profiles[index].tokens?.refreshToken == tokens.refreshToken else { throw CancellationError() }
            next.profiles[index].tokens = renewed
            // After the check above: a rejected OLD token must not pause the
            // account that a reconnect has just given new ones.
            if renewed == nil, next.selectedID == id { self.blocked = .signIn }
            do { try self.save(next) } catch where renewed == nil { self.vault = next }
            guard let renewed else { throw ChatGPTError.signIn }
            return renewed
        }
        let job = (id: jobID, task: task)
        refreshes[id] = job
        return job
    }

    func record(_ error: Error, generation: UUID) {
        guard generation == Self.generation.get(), !Task.isCancelled,
              !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
        let failure = error as? ChatGPTError ?? .unavailable
        notice = failure.localizedDescription
        switch failure {
        case .limit, .signIn, .permission, .unsupported, .storage, .inUse, .model: blocked = failure
        case .http(401), .http(403): blocked = failure
        // A server failure waits 30 s rather than repeat per keystroke. A 4xx
        // belongs to its request (a long conversation, one model): the next
        // request and the user's own retries go through.
        case .unavailable, .invalidLogin: cooldown = (Date().addingTimeInterval(30), failure)
        case .http(let code) where code >= 500: cooldown = (Date().addingTimeInterval(30), failure)
        default: break
        }
    }

    func loadModels(retry: Bool = false) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        if retry { blocked = nil; cooldown = nil; notice = nil }
        let generation = Self.generation.get()
        do {
            let (token, session) = try await credentials(generation: generation)
            let list = try await ChatGPTResponses.models(token: token, session: session)
            try check(generation)
            models = list
            catalogLoaded = true
            if let model = selected?.model, !model.isEmpty, !list.contains(where: { $0.id == model }) {
                blocked = .model
                notice = ChatGPTError.model.localizedDescription
            } else { notice = nil }
        } catch { record(error, generation: generation) }
    }

    func generate(model: String, system: String, user: String, timeout: TimeInterval, generation: UUID) async throws -> String {
        do {
            let (token, session) = try await credentials(generation: generation)
            if !catalogLoaded {
                let list = try await ChatGPTResponses.models(token: token, session: session)
                try check(generation)
                models = list
                catalogLoaded = true
            }
            guard !model.isEmpty, selected?.model == model, let catalogModel = models.first(where: { $0.id == model }) else {
                throw ChatGPTError.model
            }
            let result: String
            if let responses {
                let request = try ChatGPTResponses.request(model: model, system: system, user: user,
                    token: token, timeout: timeout, reasoningEffort: catalogModel.textReasoningEffort)
                result = try await responses.generate(request, session: session, timeout: timeout)
            } else {
                result = try await ChatGPTResponses.generate(model: model, system: system, user: user,
                    token: token, session: session, timeout: timeout, reasoningEffort: catalogModel.textReasoningEffort)
            }
            try check(generation)
            return result
        } catch {
            record(error, generation: generation)
            throw error
        }
    }
}
