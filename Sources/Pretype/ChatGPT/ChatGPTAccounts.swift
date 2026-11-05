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
    @ObservationIgnored private var session: URLSession
    @ObservationIgnored private var loginTask: Task<Void, Never>?
    @ObservationIgnored private var refresh: (id: UUID, task: Task<ChatGPTTokens, Error>)?
    @ObservationIgnored private var unavailableUntil: Date?
    @ObservationIgnored private var storageFailed = false

    var selected: ChatGPTProfile? { vault.profiles.first { $0.id == vault.selectedID } }
    var canGenerate: Bool { selected?.tokens?.scopes.contains("chatgpt.tokens.use.direct") == true && !storageFailed }

    init(storage: ChatGPTStorage = .keychain, makeSession: @escaping () -> URLSession = ChatGPTHTTP.session) {
        self.storage = storage
        self.makeSession = makeSession
        session = makeSession()
        do {
            if let data = try storage.read() { vault = try JSONDecoder().decode(ChatGPTVault.self, from: data) }
            else { try storage.write(JSONEncoder().encode(vault)) }
        } catch {
            storageFailed = true
            notice = ChatGPTError.storage.localizedDescription
        }
    }

    private func save(_ value: ChatGPTVault) throws {
        do { try storage.write(JSONEncoder().encode(value)) } catch {
            storageFailed = true
            throw ChatGPTError.storage
        }
        vault = value
        storageFailed = false
    }

    /// Cancels active URLSession requests before any identity change. The
    /// generation also rejects a response that finished just before cancel.
    private func invalidate() {
        session.invalidateAndCancel()
        session = makeSession()
        refresh?.task.cancel()
        refresh = nil
        revision = UUID()
        Self.generation.set(revision)
        blocked = nil
        unavailableUntil = nil
        models = []
    }

    func select(_ id: String) async {
        guard vault.profiles.contains(where: { $0.id == id }), !signingIn, !busy else { return }
        invalidate()
        var next = vault
        next.selectedID = id
        do { try save(next); notice = nil; await loadModels() }
        catch { notice = ChatGPTError.storage.localizedDescription }
    }

    func chooseModel(_ model: String) {
        guard models.contains(where: { $0.id == model }), let index = vault.profiles.firstIndex(where: { $0.id == vault.selectedID }) else { return }
        var next = vault
        next.profiles[index].model = model
        do { try save(next) } catch { notice = ChatGPTError.storage.localizedDescription }
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
                        let url = try await callback.callback()
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
                try self.install(profile)
                await self.loadModels()
            } catch is CancellationError { self.notice = nil }
            catch { self.notice = (error as? ChatGPTError ?? .invalidLogin).localizedDescription }
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
        guard let profile = selected, !busy, !signingIn else { return }
        busy = true
        invalidate()
        // Stop inference immediately even while remote revocation is pending.
        blocked = .signIn
        defer { busy = false }
        var revoked = profile.tokens == nil
        if let token = profile.tokens?.refreshToken {
            let revocationSession = makeSession()
            defer { revocationSession.invalidateAndCancel() }
            do {
                let discovery = try await ChatGPTHTTP.data(URLRequest(url: ChatGPTLogin.issuer.appendingPathComponent(".well-known/openid-configuration")), session: revocationSession)
                let json = try JSONSerialization.jsonObject(with: discovery) as? [String: Any]
                guard let endpoint = json?["revocation_endpoint"] as? String, let url = URL(string: endpoint),
                      url.scheme == "https", url.host == "auth.openai.com", url.port == nil,
                      url.user == nil, url.password == nil else { throw ChatGPTError.invalidLogin }
                _ = try await ChatGPTHTTP.post(url, fields: ["token": token, "token_type_hint": "refresh_token",
                    "client_id": profile.clientID], session: revocationSession)
                revoked = true
            } catch { revoked = false }
        }
        var next = vault
        if let index = next.profiles.firstIndex(where: { $0.id == profile.id }) { next.profiles[index].tokens = nil }
        do {
            try save(next)
            notice = revoked ? nil : String(localized: "Signed out locally. Remote revocation was not confirmed; disconnect Pretype in ChatGPT Settings.")
        } catch {
            // Never keep using tokens whose removal from disk failed.
            vault = next
            notice = ChatGPTError.storage.localizedDescription
        }
    }

    func check(_ generation: UUID) throws {
        try Task.checkCancellation()
        guard generation == Self.generation.get() else { throw CancellationError() }
        guard !storageFailed else { throw ChatGPTError.storage }
        if let blocked { throw blocked }
        if let until = unavailableUntil, until > Date() { throw ChatGPTError.unavailable }
    }

    func credentials(generation: UUID) async throws -> (String, URLSession) {
        try check(generation)
        guard let profile = selected, let tokens = profile.tokens else { throw ChatGPTError.signIn }
        guard tokens.scopes.contains("chatgpt.tokens.use.direct") else { throw ChatGPTError.permission }
        if tokens.expiresAt > Date().addingTimeInterval(60) { return (tokens.accessToken, session) }
        let job: (id: UUID, task: Task<ChatGPTTokens, Error>)
        if let refresh { job = refresh } else {
            let currentSession = session
            job = (UUID(), Task {
                let data = try await ChatGPTHTTP.post(ChatGPTLogin.tokenURL, fields: ["grant_type": "refresh_token",
                    "client_id": profile.clientID, "refresh_token": tokens.refreshToken,
                    "resource": "https://api.openai.com/v1"], session: currentSession)
                return try ChatGPTTokens.decode(data, previous: tokens)
            })
            refresh = job
        }
        do {
            let renewed = try await job.task.value
            try check(generation)
            if refresh?.id == job.id {
                var next = vault
                guard let index = next.profiles.firstIndex(where: { $0.id == profile.id }) else { throw CancellationError() }
                next.profiles[index].tokens = renewed
                try save(next)
                refresh = nil
            }
            guard renewed.scopes.contains("chatgpt.tokens.use.direct") else { throw ChatGPTError.permission }
            return (renewed.accessToken, session)
        } catch {
            if generation == Self.generation.get(), refresh?.id == job.id {
                refresh = nil
                if error as? ChatGPTError == .signIn {
                    var next = vault
                    if let index = next.profiles.firstIndex(where: { $0.id == profile.id }) { next.profiles[index].tokens = nil }
                    do { try save(next) } catch { storageFailed = true }
                    blocked = .signIn
                }
            }
            throw error
        }
    }

    func record(_ error: Error, generation: UUID) {
        guard generation == Self.generation.get(), !(error is CancellationError) else { return }
        let failure = error as? ChatGPTError ?? .unavailable
        notice = failure.localizedDescription
        switch failure {
        case .limit, .signIn, .permission, .unsupported, .storage, .model: blocked = failure
        case .http(401), .http(403): blocked = failure
        case .unavailable: unavailableUntil = Date().addingTimeInterval(30)
        default: break
        }
    }

    func loadModels(retry: Bool = false) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        if retry { blocked = nil; unavailableUntil = nil; notice = nil }
        let generation = Self.generation.get()
        do {
            let (token, session) = try await credentials(generation: generation)
            let list = try await ChatGPTResponses.models(token: token, session: session)
            try check(generation)
            models = list
            if let model = selected?.model, !model.isEmpty, !list.contains(where: { $0.id == model }) {
                notice = ChatGPTError.model.localizedDescription
            } else { notice = nil }
        } catch { record(error, generation: generation) }
    }

    func generate(model: String, system: String, user: String, timeout: TimeInterval, generation: UUID) async throws -> String {
        do {
            let (token, session) = try await credentials(generation: generation)
            guard !model.isEmpty, selected?.model == model else { throw ChatGPTError.model }
            let result = try await ChatGPTResponses.generate(model: model, system: system, user: user,
                token: token, session: session, timeout: timeout)
            try check(generation)
            return result
        } catch {
            record(error, generation: generation)
            throw error
        }
    }
}
