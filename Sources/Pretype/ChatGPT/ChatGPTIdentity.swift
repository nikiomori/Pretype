import CryptoKit
import Foundation
import Security

/// Public-client OAuth. No client secret, imported cookies, or CLI credentials.
struct ChatGPTLogin {
    static let issuer = URL(string: "https://auth.openai.com")!
    static let tokenURL = issuer.appendingPathComponent("api/accounts/oauth/token")
    static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    let state: String
    let nonce: String
    let verifier: String
    let redirect: URL
    let existing: ChatGPTProfile?

    init(redirect: URL, existing: ChatGPTProfile?) throws {
        self.redirect = redirect
        self.existing = existing
        state = try Self.random()
        nonce = try Self.random()
        verifier = try Self.random()
    }

    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ChatGPTError.invalidLogin
        }
        return Data(bytes).base64URL
    }

    func authorize(hostID: String) throws -> URL {
        var components = URLComponents(url: Self.issuer.appendingPathComponent("api/accounts/authorize"),
                                       resolvingAgainstBaseURL: false)
        var values = ["client_id": existing?.clientID ?? "dynamic_agent_client", "ext_agent_host_id": hostID,
                      "response_type": "code", "redirect_uri": redirect.absoluteString, "scope": Self.scopes,
                      "resource": "https://api.openai.com/v1", "state": state, "nonce": nonce,
                      "code_challenge_method": "S256", "code_challenge": Data(SHA256.hash(data: Data(verifier.utf8))).base64URL]
        if let existing {
            if let token = existing.tokens?.idToken { values["id_token_hint"] = token }
            if !existing.email.isEmpty { values["login_hint"] = existing.email }
            if existing.tokens?.scopes.contains("chatgpt.tokens.use.direct") == false { values["prompt"] = "consent" }
        } else { values["agent_name_hint"] = "Pretype" }
        components?.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else { throw ChatGPTError.invalidLogin }
        return url
    }

    func callback(_ url: URL) throws -> (code: String, clientID: String) {
        guard url.scheme == redirect.scheme, url.host == "127.0.0.1", url.port == redirect.port,
              url.path == redirect.path, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              Set(items.map(\.name)).count == items.count else { throw ChatGPTError.invalidLogin }
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard values["state"] == state else { throw ChatGPTError.invalidLogin }
        if values["error"] == "access_denied" { throw ChatGPTError.permission }
        guard values["error"] == nil, let code = values["code"], !code.isEmpty,
              let id = values["client_id"] ?? existing?.clientID, !id.isEmpty,
              id != "dynamic_agent_client", existing == nil || id == existing?.clientID else {
            throw ChatGPTError.invalidLogin
        }
        return (code, id)
    }

    func exchange(_ callback: URL, session: URLSession) async throws -> ChatGPTProfile {
        let result = try self.callback(callback)
        let data = try await ChatGPTHTTP.post(Self.tokenURL, fields: ["grant_type": "authorization_code",
            "client_id": result.clientID, "code": result.code, "code_verifier": verifier,
            "redirect_uri": redirect.absoluteString, "resource": "https://api.openai.com/v1"], session: session)
        let tokens = try ChatGPTTokens.decode(data)
        let jwks = try await ChatGPTHTTP.data(URLRequest(url: Self.issuer.appendingPathComponent(".well-known/jwks.json")),
                                             session: session)
        let identity = try ChatGPTIdentity.verify(tokens.idToken, jwks: jwks, clientID: result.clientID, nonce: nonce)
        guard existing == nil || existing?.subject == identity.subject else { throw ChatGPTError.invalidLogin }
        return ChatGPTProfile(clientID: result.clientID, subject: identity.subject, email: identity.email,
                              tokens: tokens, model: existing?.model ?? "")
    }
}

enum ChatGPTIdentity {
    struct Identity { let subject: String; let email: String }

    static func verify(_ token: String, jwks: Data, clientID: String, nonce: String, now: Date = Date()) throws -> Identity {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let headerData = Data(base64URL: parts[0]),
              let claimsData = Data(base64URL: parts[1]), let signature = Data(base64URL: parts[2]),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "RS256", let kid = header["kid"] as? String,
              let keys = (try JSONSerialization.jsonObject(with: jwks) as? [String: Any])?["keys"] as? [[String: Any]],
              let jwk = keys.first(where: { $0["kid"] as? String == kid && $0["kty"] as? String == "RSA" }),
              jwk["use"] == nil || jwk["use"] as? String == "sig",
              jwk["alg"] == nil || jwk["alg"] as? String == "RS256",
              let n = jwk["n"] as? String, let e = jwk["e"] as? String,
              let modulus = Data(base64URL: n), let exponent = Data(base64URL: e),
              !modulus.isEmpty, !exponent.isEmpty else { throw ChatGPTError.invalidLogin }
        let keyData = der(0x30, derInteger(modulus) + derInteger(exponent))
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                       kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        guard let key = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, nil),
              SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256,
                                    Data("\(parts[0]).\(parts[1])".utf8) as CFData, signature as CFData, nil),
              let claims = try JSONSerialization.jsonObject(with: claimsData) as? [String: Any] else {
            throw ChatGPTError.invalidLogin
        }
        let audience = (claims["aud"] as? String).map { [$0] } ?? claims["aud"] as? [String] ?? []
        guard claims["iss"] as? String == ChatGPTLogin.issuer.absoluteString, audience.contains(clientID),
              (audience.count == 1 && claims["azp"] == nil) || claims["azp"] as? String == clientID,
              claims["nonce"] as? String == nonce, let expiry = claims["exp"] as? Double,
              expiry > now.timeIntervalSince1970,
              (claims["nbf"] as? Double ?? 0) <= now.timeIntervalSince1970,
              let subject = claims["sub"] as? String, !subject.isEmpty else { throw ChatGPTError.invalidLogin }
        return Identity(subject: subject, email: claims["email"] as? String ?? subject)
    }

    private static func derInteger(_ bytes: Data) -> Data {
        var value = Data(bytes.drop { $0 == 0 })
        if value.isEmpty { value = Data([0]) }
        if let first = value.first, first & 0x80 != 0 { value.insert(0, at: 0) }
        return der(0x02, value)
    }

    private static func der(_ tag: UInt8, _ content: Data) -> Data {
        var length = content.count
        var bytes: [UInt8] = []
        repeat { bytes.insert(UInt8(length & 255), at: 0); length >>= 8 } while length > 0
        let prefix = content.count < 128 ? [UInt8(content.count)] : [0x80 | UInt8(bytes.count)] + bytes
        return Data([tag] + prefix) + content
    }
}
