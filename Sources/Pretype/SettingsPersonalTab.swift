import AppKit
import AVFoundation
import Carbon
import SwiftUI

// MARK: - Personalization tab

struct PersonalTab: View {
    @Bindable var store: SettingsStore
    /// Both journal paths destroy the learned n-gram model irreversibly, so
    /// they route through one confirmation instead of firing on a single click.
    @State private var confirmingClear = false
    @State private var clearDisablesJournal = false
    @AppStorage("clipboardContext") private var clipboardContext = Settings.clipboardContextEnabled
    @AppStorage("showAdvancedSettings") private var showAdvanced = false

    var body: some View {
        Form {
            Section("Persona") {
                TextEditor(text: $store.instructions)
                    .accessibilityLabel("Persona")
                    .font(.system(size: 12))
                    .frame(height: 84)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1))
                HStack {
                    Caption(store.isAppleIntelligence
                        ? String(localized: "Sets the voice of Apple Intelligence. Stays on this Mac.")
                        : String(localized: "Shapes replies, and suggestions in the Instruct style. Stays on this Mac."))
                    Spacer()
                    Button("Restore Default") { store.resetInstructions() }
                        .controlSize(.small)
                        .help("Rebuild it from your account name and keyboard languages")
                }
            }

            Section("Per-app style") {
                if store.perAppInstructions.isEmpty {
                    Caption(String(localized: "Add an app to give it its own style on top of your persona."))
                }
                ForEach(store.perAppInstructions.keys.sorted(), id: \.self) { bundleID in
                    PerAppInstructionRow(bundleID: bundleID, store: store)
                }
                let suggestions = store.perAppSuggestions
                HStack(spacing: 10) {
                    if !suggestions.isEmpty {
                        let names = suggestions.map { resolveApp($0.bundleID).name }.joined(separator: ", ")
                        Button("Fill In Suggested", systemImage: "sparkles") {
                            store.addSuggestedPerAppInstructions()
                        }
                        .help("Ready-made styles for \(names). Every line stays editable.")
                    }
                    Button("Add App…", systemImage: "plus") { store.addPerAppInstructionApp() }
                    Button("Add Website…", systemImage: "globe") { store.addPerSiteInstruction() }
                }
                .controlSize(.small)
            }

            // What Pretype may read besides the text field — next to the
            // persona and styles it feeds.
            Section("Context") {
                Toggle(isOn: $store.screenContext) {
                    IconLabel(symbol: "macwindow", tint: .blue,
                              title: Text("Use screen context"),
                              subtitle: Text("Reads the focused window on this Mac."))
                }
                .help("On-device OCR of the focused window — the conversation above a chat box, the email being replied to. It never leaves the Mac and is never written to the journal. With Screen Recording, the overlay also adapts to the background under the cursor.")
                Toggle(isOn: $clipboardContext) {
                    IconLabel(symbol: "doc.on.clipboard.fill", tint: .orange,
                              title: Text("Use clipboard context"),
                              subtitle: Text("Uses text you just copied."))
                }
                .help("Up to 600 characters, read only when the clipboard changes. Copies from password managers are never read, and nothing is written to the journal or debug log.")
                // Instant n-gram suggestions come from the controller, so learning
                // works the same on every engine, Apple Intelligence included.
                Toggle(isOn: $store.personalization) {
                    IconLabel(symbol: "character.book.closed.fill", tint: .purple,
                              title: Text("Learn my words"),
                              subtitle: store.learnedWords > 0
                                  ? Text("\(store.learnedWords) words learned from your typing.")
                                  : Text("Boosts words you often type."))
                }
                .help("Learned from your suggestion journal, only while on. Clear the journal to forget them.")
            }

            if showAdvanced {
                journal
            }
        }
        .formStyle(.grouped)
        .onAppear { store.refreshJournalStats() }
        // The journal grows while the user is off in another app; without this
        // the Clear button can sit disabled on a journal that has real data.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshJournalStats()
        }
        .confirmationDialog("Delete the suggestion journal?",
                            isPresented: $confirmingClear) {
            Button("Delete", role: .destructive) {
                // Setting the toggle off clears the journal in the store's didSet;
                // the button path clears directly and leaves the toggle alone.
                if clearDisablesJournal { store.journalEnabled = false } else { store.clearJournal() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            store.learnedWords > 0
                ? Text("This also forgets the \(store.learnedWords) words Pretype learned from you. It can't be undone.")
                : Text("This can't be undone.")
        }
    }

    /// The raw data under Learn my words: on by default, so it's here for
    /// clearing and importing, not for setting up.
    private var journal: some View {
        Section("Journal") {
            Toggle(isOn: Binding(
                get: { store.journalEnabled },
                set: { on in
                    // Turning off deletes the journal via the store's didSet;
                    // only ask when there is actually something to lose.
                    if !on && store.journalHasData {
                        clearDisablesJournal = true
                        confirmingClear = true
                    } else {
                        store.journalEnabled = on
                    }
                }
            )) {
                Text("Keep suggestion journal")
                Text("Saves suggestions with nearby text, on this Mac only.")
            }
            .help("The raw data for personalization, capped at 50 MB in Application Support. On-screen text is never written. Turning this off deletes it.")
            LabeledContent("Size") {
                HStack(spacing: 10) {
                    Text(store.journalBytes > 0
                        ? ByteCountFormatter.string(fromByteCount: Int64(store.journalBytes), countStyle: .file)
                        : String(localized: "Empty"))
                        .monospacedDigit()
                    Button("Clear…") {
                        clearDisablesJournal = false
                        confirmingClear = true
                    }
                    .controlSize(.small)
                    .disabled(store.journalBytes == 0)
                }
            }
            LabeledContent {
                Button("Import Text…", systemImage: "text.book.closed") { store.importTextFiles() }
                    .controlSize(.small)
                    .disabled(!store.journalEnabled || store.importing)
            } label: {
                Text("Learn from your writing")
                if store.journalEnabled {
                    Text("Import .txt or .md files you wrote.")
                } else {
                    Text("Turn on the journal first.")
                }
            }
            .help("Pretype learns your words and reuses your sentences as examples. Files are only read; Clear forgets imported text too.")
            if let status = store.importStatus {
                Caption(status)
            }
        }
    }
}
