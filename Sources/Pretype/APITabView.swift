import SwiftUI

/// Settings → API: hosted models for text and for dictation, each off by
/// default and each saying out loud what leaves the Mac when it is on.
struct APITab: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Form {
            APIEndpointSection(kind: .text, config: $store.apiText, test: store.apiTextTest, store: store)
            APIEndpointSection(kind: .audio, config: $store.apiAudio, test: store.apiAudioTest, store: store)
        }
        .formStyle(.grouped)
    }
}

private struct APIEndpointSection: View {
    let kind: APIKind
    @Binding var config: APIConfig
    let test: String?
    let store: SettingsStore
    /// The field's text. The key itself lives in the Keychain and is written
    /// through on every edit; this only mirrors it.
    @State private var key = ""

    private var provider: APIProvider { config.preset }
    private var host: String { URL(string: config.baseURL)?.host ?? "the server" }

    var body: some View {
        Section {
            Toggle(isOn: $config.enabled) {
                Text(kind == .text ? "Use an API model for text" : "Use an API model for dictation")
                Text(kind == .text
                    ? "Suggestions, \(store.hotkeyStyle.correctionLabel) fix, reply and voice commands run on "
                        + "the model below instead of the on-device model. Off, the on-device model runs again."
                    : "Dictation is transcribed by the model below instead of the speech models on this Mac.")
            }
            Picker("Provider", selection: Binding(
                get: { config.provider },
                // A new provider brings its own URL and suggested model.
                set: { config = APIConfig(provider: .named($0), kind: kind, enabled: config.enabled) })) {
                ForEach(APIProvider.offering(kind)) { Text($0.name).tag($0.id) }
            }
            TextField("Base URL", text: $config.baseURL, prompt: Text("https://example.com/v1"))
            TextField("Model", text: $config.model, prompt: Text("model name"))
            SecureField("API key", text: $key, prompt: Text(provider.needsKey ? "required" : "optional"))
            HStack {
                Button("Test connection") { store.testAPI(kind) }
                    .disabled(test == "Testing…")
                if let page = provider.keyPage, let url = URL(string: page) {
                    Link("Get a key", destination: url)
                }
                Spacer()
            }
            if let test { Caption(test) }
            Caption(privacyNote)
        } header: {
            Text(kind == .text ? "Text" : "Dictation")
        }
        .onAppear(perform: loadKey)
        .onChange(of: config.provider) { loadKey() }
        .onChange(of: store.apiKeyRevision) { loadKey() }
        .onChange(of: key) {
            guard key != (APIKeychain.key(for: config.provider) ?? "") else { return }
            APIKeychain.set(key, for: config.provider)
            store.apiKeyChanged(provider: config.provider)
        }
    }

    private func loadKey() { key = APIKeychain.key(for: config.provider) ?? "" }

    private var privacyNote: String {
        if config.isLocal {
            return "This server runs on your Mac, so nothing leaves it."
        }
        if kind == .text {
            return "When this is on, the text you type goes to \(host) as you type: one request each time "
                + "a suggestion is due. The screen and clipboard context go too when they are on, and so "
                + "does dictated text when “Tidy up” is on. Password fields and blocked apps never send "
                + "anything. The provider charges for each request."
        }
        return "When this is on, each recording goes to \(host) when you stop speaking"
            + (APIClient.sendsHints(model: config.model, provider: config.provider)
                ? ", with the names already in the field as spelling hints. " : ". ")
            + "Pretype keeps the audio in memory only and never writes it to disk."
    }
}
