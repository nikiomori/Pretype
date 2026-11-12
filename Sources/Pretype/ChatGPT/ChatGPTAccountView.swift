import SwiftUI

struct ChatGPTAccountView: View {
    @Binding var config: APIConfig
    let store: SettingsStore
    @State private var accounts = ChatGPTAccounts.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !accounts.vault.profiles.isEmpty {
                Picker("ChatGPT account", selection: Binding(
                    get: { accounts.vault.selectedID ?? "" },
                    set: { id in Task { await accounts.select(id); syncModel() } })) {
                    ForEach(accounts.vault.profiles) { Text(verbatim: $0.label).tag($0.id) }
                }
                .disabled(accounts.signingIn || accounts.busy)
            }
            HStack {
                Button("Continue with ChatGPT") { accounts.signIn() }
                    .disabled(accounts.signingIn || accounts.busy)
                if accounts.selected != nil {
                    Button("Reconnect") { accounts.signIn(reconnect: true) }
                        .disabled(accounts.signingIn || accounts.busy)
                    Button("Sign out") { Task { await accounts.signOut(); syncModel() } }
                        .disabled(accounts.signingIn || accounts.busy || accounts.selected?.tokens == nil)
                }
                if accounts.signingIn {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(Text("Signing in to ChatGPT…"))
                    Button("Cancel") { accounts.cancelSignIn() }
                }
            }
            if accounts.canGenerate {
                Picker("Model", selection: Binding(get: { config.model }, set: { model in
                    accounts.chooseModel(model)
                    syncModel()
                })) {
                    Text("Choose a model").tag("")
                    if !config.model.isEmpty, !accounts.models.contains(where: { $0.id == config.model }) {
                        Text(verbatim: config.model).tag(config.model)
                    }
                    ForEach(accounts.models) { Text(verbatim: $0.displayName).tag($0.id) }
                }
                .disabled(accounts.busy || accounts.signingIn)
                Button("Refresh models / retry") { Task { await accounts.loadModels(retry: true); syncModel() } }
                    .disabled(accounts.busy || accounts.signingIn)
                Toggle(isOn: Binding(get: { store.planSuggestions }, set: { store.planSuggestions = $0 })) {
                    Text("Suggestions on ChatGPT")
                    Text("Each waits about a second and uses your plan. Off, Words completes them on your Mac.")
                }
            }
            if let notice = accounts.notice { Caption(notice) }
            Link("Manage ChatGPT usage", destination: URL(string: "https://chatgpt.com/settings/usage")!)
            Caption(String(localized: "Uses your ChatGPT plan allowance and any credits you allow in ChatGPT settings. Speech transcription uses its separate provider."))
        }
        .task { await accounts.loadModels(); syncModel() }
        .onChange(of: accounts.revision) {
            syncModel()
            store.apiKeyChanged(provider: "chatgpt")
        }
    }

    private func syncModel() { config.model = accounts.selected?.model ?? "" }
}
