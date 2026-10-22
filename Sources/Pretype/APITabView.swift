import SwiftUI

/// Settings → API: hosted models for text and for dictation, each off by
/// default and each saying out loud what leaves the Mac when it is on.
struct APITab: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Form {
            APIEndpointSection(kind: .text, config: $store.apiText, store: store)
            APIEndpointSection(kind: .audio, config: $store.apiAudio, store: store)
        }
        .formStyle(.grouped)
    }
}

private struct APIEndpointSection: View {
    let kind: APIKind
    @Binding var config: APIConfig
    let store: SettingsStore
    /// The field's text. The key itself lives in the Keychain and is written
    /// through on every edit; this only mirrors it.
    @State private var key = ""

    private var provider: APIProvider { config.preset }
    private var test: String? { store.apiTests[kind] }
    private var host: String {
        URL(string: config.baseURL)?.host
            ?? String(localized: "the server", comment: "Stands in for the host name in the API privacy note.")
    }

    var body: some View {
        Section {
            Toggle(isOn: $config.enabled) {
                if kind == .text {
                    IconLabel(symbol: "text.bubble.fill", tint: .teal,
                              title: Text("Use an API model for text"),
                              subtitle: Text("Suggestions, fix, reply and voice commands use this model."))
                } else {
                    IconLabel(symbol: "waveform", tint: .red,
                              title: Text("Use an API model for dictation"),
                              subtitle: Text("Transcribes dictation with this model."))
                }
            }
            // Off, the endpoint is five empty-looking fields nobody needs to
            // read; they come with the switch.
            if config.enabled {
                Picker("Provider", selection: Binding(
                    get: { config.provider },
                    // A new provider brings its own URL and suggested model.
                    set: { config = APIConfig(provider: .named($0), kind: kind, enabled: config.enabled) })) {
                    ForEach(APIProvider.offering(kind)) { Text($0.name).tag($0.id) }
                }
                // A preset brings its own URL: the field is for custom servers
                // and for whoever already changed it.
                if config.provider == APIProvider.custom.id || config.baseURL != provider.baseURL {
                    TextField("Base URL", text: $config.baseURL, prompt: Text(verbatim: "https://example.com/v1"))
                }
                TextField("Model", text: $config.model, prompt: Text("model name"))
                SecureField("API key", text: $key, prompt: provider.needsKey ? Text("required") : Text("optional"))
                // The answer beside the button that asked for it.
                HStack {
                    Button("Test connection") { store.testAPI(kind) }
                        // Same key SettingsStore sets it from, so the match holds in every language.
                        .disabled(test == String(localized: "Testing…"))
                    if let test { Caption(test) }
                    Spacer()
                    if let page = provider.keyPage, let url = URL(string: page) {
                        Link("Get a key", destination: url)
                    }
                }
                Label {
                    Caption(privacyNote)
                } icon: {
                    Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            kind == .text ? Text("Text") : Text("Dictation")
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
            return String(localized: "This server runs on your Mac, so nothing leaves it.")
        }
        // Short, but never vaguer: what leaves the Mac, when, and what doesn't.
        if kind == .text {
            return String(localized: "What you type goes to \(host) with each suggestion, plus screen and clipboard context and dictation to tidy up when those are on. Password fields and turned-off apps send nothing. The provider may charge per request.")
        }
        return APIClient.sendsHints(model: config.model, provider: config.provider)
            ? String(localized: "Each recording goes to \(host) when you stop speaking, with names from the field as spelling hints. Audio is never saved to disk.")
            : String(localized: "Each recording goes to \(host) when you stop speaking. Audio is never saved to disk.")
    }
}
