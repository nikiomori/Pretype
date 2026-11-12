import Foundation

/// The prompt/gate layer does not know whether text uses API-key billing or
/// a ChatGPT plan. Credentials are resolved at request time, never captured.
struct TextGenerationTransport {
    let endpoint: APIEndpoint

    func generate(system: String, user: String, maxTokens: Int, timeout: TimeInterval,
                  mustAnswer: Bool = false) async throws -> String {
        if endpoint.provider.id == "chatgpt" {
            // Per request: an engine built before a sign-in or switch must still work.
            let generation = ChatGPTAccounts.generation.get()
            do {
                return try await ChatGPTAccounts.shared.generate(model: endpoint.model, system: system, user: user,
                                                                timeout: timeout, generation: generation)
            } catch is CancellationError { throw CancellationError() } catch let error as URLError where error.code == .cancelled { throw CancellationError() } catch { throw error as? ChatGPTError ?? .unavailable }
        }
        return try await APIClient.chat(endpoint, system: system, user: user, maxTokens: maxTokens,
                                        timeout: timeout, mustAnswer: mustAnswer)
    }
}
