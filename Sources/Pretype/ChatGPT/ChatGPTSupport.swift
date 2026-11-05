import CryptoKit
import Foundation
import Security

/// Deliberately excludes server messages: they can contain prompts or credentials.
enum ChatGPTError: LocalizedError, Equatable {
    case signIn, permission, invalidLogin, storage, model, interrupted, limit, unavailable, unsupported, http(Int)

    var errorDescription: String? {
        switch self {
        case .signIn: return String(localized: "Reconnect your ChatGPT account in Settings → API.")
        case .permission: return String(localized: "ChatGPT plan usage is not enabled for this account. Reconnect to grant permission.")
        case .invalidLogin: return String(localized: "ChatGPT sign-in could not be verified. Please try again.")
        case .storage: return String(localized: "ChatGPT credentials could not be saved or read from Keychain.")
        case .model: return String(localized: "Refresh ChatGPT models and choose an available model.")
        case .interrupted: return String(localized: "ChatGPT did not finish its response. Please try again.")
        case .limit: return String(localized: "ChatGPT usage is paused. Check your allowance in ChatGPT Settings → Usage, then retry.")
        case .unavailable: return String(localized: "ChatGPT is temporarily unavailable. Please try again later.")
        case .unsupported: return String(localized: "ChatGPT plan usage is unavailable for this account, region, or request.")
        case .http(let status): return String(localized: "ChatGPT request failed (HTTP \(status)).")
        }
    }

    static func response(_ data: Data, status: Int) -> ChatGPTError {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let nested = json?["error"] as? [String: Any]
        let code = nested?["code"] as? String ?? json?["error"] as? String ?? json?["code"] as? String
        switch code {
        case "subscription_sharing_usage_limit_exceeded": return .limit
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable": return .unavailable
        case "subscription_sharing_user_not_eligible", "subscription_sharing_unsupported_capability",
             "subscription_sharing_route_not_supported", "chatpass_v2_scope_not_authorized",
             "chatpass_v2_invalid_authorization_context": return .unsupported
        case "invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
             "refresh_token_invalidated", "refresh_token_reused", "subscription_sharing_invalid_user": return .signIn
        default:
            if status == 429 { return .limit }
            if status == 503 { return .unavailable }
            return .http(status)
        }
    }
}

struct ChatGPTTokens: Codable {
    let accessToken: String
    let refreshToken: String
    let idToken: String
    let expiresAt: Date
    let scopes: Set<String>

    static func decode(_ data: Data, previous: ChatGPTTokens? = nil, now: Date = Date()) throws -> ChatGPTTokens {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let access = json?["access_token"] as? String, !access.isEmpty,
              let refresh = json?["refresh_token"] as? String ?? previous?.refreshToken, !refresh.isEmpty,
              let id = json?["id_token"] as? String ?? previous?.idToken, !id.isEmpty,
              let seconds = json?["expires_in"] as? Double, seconds > 0,
              (json?["token_type"] as? String)?.lowercased() == "bearer" else { throw ChatGPTError.invalidLogin }
        let scopes = (json?["scope"] as? String).map { Set($0.split(separator: " ").map(String.init)) }
            ?? previous?.scopes ?? []
        return ChatGPTTokens(accessToken: access, refreshToken: refresh, idToken: id,
                             expiresAt: now.addingTimeInterval(seconds), scopes: scopes)
    }
}

struct ChatGPTProfile: Codable, Identifiable {
    var id: String { clientID }
    let clientID: String
    let subject: String
    let email: String
    var tokens: ChatGPTTokens?
    var model = ""
    var label: String { "\(email) · \(clientID.suffix(8))" }
}

struct ChatGPTVault: Codable {
    var hostID = "urn:uuid:\(UUID().uuidString.lowercased())"
    var profiles: [ChatGPTProfile] = []
    var selectedID: String?
}

/// A single atomic Keychain update keeps rotating token sets together.
struct ChatGPTStorage {
    var read: () throws -> Data?
    var write: (Data) throws -> Void

    static func memory() -> ChatGPTStorage {
        let data = LockedValue<Data?>(nil)
        return ChatGPTStorage(read: { data.get() }, write: { data.set($0) })
    }

    static var keychain: ChatGPTStorage {
        if Settings.isTestProcess { return memory() }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: "app.pretype.chatgpt",
                                   kSecAttrAccount as String: "accounts"]
        return ChatGPTStorage(read: {
            var lookup = query
            lookup[kSecReturnData as String] = true
            lookup[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(lookup as CFDictionary, &item)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = item as? Data else { throw ChatGPTError.storage }
            return data
        }, write: { data in
            let update = [kSecValueData as String: data]
            let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            if status == errSecItemNotFound {
                var add = query
                add[kSecValueData as String] = data
                add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw ChatGPTError.storage }
            } else if status != errSecSuccess { throw ChatGPTError.storage }
        })
    }
}

/// OAuth and inference never follow redirects carrying credentials to another origin.
final class ChatGPTNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum ChatGPTHTTP {
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config, delegate: ChatGPTNoRedirect(), delegateQueue: nil)
    }

    static func form(_ fields: [String: String]) -> Data {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(fields.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: safe) ?? "")=\($0.value.addingPercentEncoding(withAllowedCharacters: safe) ?? "")"
        }.joined(separator: "&").utf8)
    }

    static func post(_ url: URL, fields: [String: String], session: URLSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(fields)
        return try await data(request, session: session)
    }

    static func data(_ request: URLRequest, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw ChatGPTError.unavailable }
        guard (200..<300).contains(http.statusCode) else { throw ChatGPTError.response(data, status: http.statusCode) }
        return data
    }
}

extension Data {
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }

    init?(base64URL: String) {
        let base = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: base + String(repeating: "=", count: (4 - base.count % 4) % 4))
    }
}
