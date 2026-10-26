import AppKit
import AVFoundation
import Carbon
import SwiftUI

// MARK: - Dictation tab

struct DictationTab: View {
    @Bindable var store: SettingsStore
    @AppStorage("replyGesture") private var replyGesture = Settings.replyGesture
    @AppStorage("dictationGesture") private var dictationGesture = Settings.dictationGesture
    @AppStorage("dictationLatch") private var dictationLatch = Settings.dictationLatch
    /// Silence budget for a hands-free capture, in seconds; 0 is off.
    @AppStorage("dictationSilence") private var dictationSilence = Settings.dictationSilence
    @AppStorage("dictationPolish") private var dictationPolish = Settings.dictationPolish
    @AppStorage("dictationCommands") private var dictationCommands = Settings.dictationCommands
    @AppStorage("showAdvancedSettings") private var showAdvanced = false

    /// The speech model the dictation language resolves to, for the Language
    /// row's subtitle.
    private var speechModel: String? {
        switch store.dictationSupport {
        case .preferred: return String(localized: "Apple's newer speech model")
        case .fallback: return String(localized: "System dictation model")
        case .parakeet: return "Parakeet"
        case .api: return store.apiAudio.preset.name
        case .unsupported, nil: return nil
        }
    }

    /// The Language row's tooltip: what the pick does, plus a note when the
    /// language falls back to the rougher system model.
    private var languageHelp: String {
        let pick = store.dictationLanguage == "auto"
            ? String(localized: "Follows the keyboard layout that's active when you start — switch layouts to switch dictation language.")
            : String(localized: "Always listens for this language, whatever the keyboard is set to.")
        guard store.dictationSupport == .fallback else { return pick }
        return pick + " " + String(localized: "Apple's newer speech model doesn't cover \(store.dictationLanguageName), so this uses the one macOS's own dictation key uses — a little rougher, which “Tidy up” helps with.")
    }

    var body: some View {
        Form {
            Section {
                if let blocker = store.dictationBlocker {
                    Caption(blocker)
                    if store.dictationMicDenied {
                        Button("Open Microphone Settings…") {
                            if let url = MicrophoneAccess.settingsURL {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                } else {
                    Toggle(isOn: $store.dictation) {
                        IconLabel(symbol: "mic.fill", tint: .red,
                                  title: Text("Talk instead of typing"),
                                  subtitle: store.apiAudio.enabled && !store.apiAudio.isLocal
                                      ? Text("Hold a key and speak. Transcribed by your API provider.")
                                      : Text("Hold a key and speak. Transcribed on this Mac."))
                    }
                    .help("Hold a key for a sentence, or press a chord for a paragraph — either way it is typed into the field you're in. No audio is written to disk, and nothing records unless you ask.")
                }
            }

            if store.dictationBlocker == nil, store.dictation {
                startSection
                languageSection
                if showAdvanced {
                    advanced
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            store.loadDictationLocales()
            store.refreshDictationInput()
        }
        // Devices come and go while the pane is open — a headset
        // connecting is exactly the event that changes both the list and
        // the "recording from X" note, and it happens outside any state
        // this pane owns. (The notifications fire for cameras too; a
        // spurious refresh costs a device-list read.) The notifications
        // post on an arbitrary thread and the store is main-actor, hence
        // the explicit hop.
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)
            .merge(with: NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification))
            .receive(on: DispatchQueue.main)) { _ in
            store.refreshDictationInput()
        }
        // Under "Follow keyboard" both the "Now X" subtitle and the
        // speech-model caption depend on the layout
        // that is selected system-wide — and the user switches it from the
        // menu bar or ⌃Space, outside our process, so no state we own
        // changes. Carbon's distributed notification is the only signal
        // that crosses the process boundary; re-resolving on it keeps both
        // lines honest while the pane stays open.
        .onReceive(DistributedNotificationCenter.default().publisher(
            for: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String))) { _ in
            store.refreshDictationLanguage()
        }
    }

    /// The keys that start a dictation — and, with the detail shown, when a
    /// hands-free one stops by itself, right under the chord it belongs to.
    private var startSection: some View {
        Section("Start dictation") {
            Picker(selection: $dictationGesture) {
                ForEach(DictationGesture.allCases, id: \.self) { gesture in
                    Text(gesture.label).tag(gesture)
                }
            } label: {
                Text("Push-to-talk key")
                if dictationGesture != .off {
                    Text("Hold to record. Esc discards.")
                }
            }
            .help(replyGesture == .off
                ? Text("A hold, not a tap. Recording starts after about half a second of quiet hold; any other key, click or scroll before that cancels it.")
                : Text("A hold, not a tap, so it never collides with “\(replyGesture.label)” for a reply. Recording starts after about half a second of quiet hold; any other key, click or scroll before that cancels it."))
            if dictationGesture == .off, dictationLatch == .off {
                Caption(String(localized: "⚠︎ Nothing starts dictation. Pick a key or a chord."))
            }
            Picker(selection: $dictationLatch) {
                ForEach(DictationLatch.allCases, id: \.self) { latch in
                    Text(latch.label).tag(latch)
                }
            } label: {
                Text("Hands-free chord")
                if dictationLatch != .off {
                    Text("Press once to start, again to stop.")
                }
            }
            .help("Nothing to hold, so you can scroll, click and think mid-sentence. Recording starts on the keypress itself. ⎋ throws the capture away, and moving to another field ends it.")
            if showAdvanced, dictationLatch != .off {
                Picker("Stop after silence", selection: $dictationSilence) {
                    Text("Never").tag(0.0)
                    Text("3 seconds").tag(3.0)
                    Text("5 seconds").tag(5.0)
                    Text("10 seconds").tag(10.0)
                }
                .help(dictationSilence == 0
                    ? Text("Runs until you press the chord again, or for ten minutes.")
                    : Text("Types what it has and stops, so a forgotten chord isn't an open microphone. Before your first word, it waits 30 seconds."))
            }
        }
    }

    /// What it listens for, and the speech model that lands on.
    private var languageSection: some View {
        Section("Language") {
            Picker(selection: $store.dictationLanguage) {
                Text("Follow keyboard").tag("auto")
                Divider()
                ForEach(store.dictationLocales, id: \.identifier) { locale in
                    Text(Transcription.name(of: locale)).tag(locale.identifier)
                }
            } label: {
                Text("Language")
                // Which speech model it lands on, right where the
                // language is picked.
                let line = [store.dictationLanguage == "auto" ? String(localized: "Now \(store.dictationLanguageName)") : nil,
                            speechModel].compactMap { $0 }
                if !line.isEmpty {
                    Text(line.joined(separator: " · "))
                }
            }
            .help(languageHelp)
            // For the languages macOS simply cannot dictate, say so
            // HERE instead of letting the user find out by holding
            // a key and getting nothing.
            if store.dictationSupport == .unsupported {
                Caption(String(localized: "⚠︎ macOS can't dictate \(store.dictationLanguageName). Pick another language."))
            }
            if [.fallback, .parakeet].contains(store.dictationSupport),
               Parakeet.covers(Settings.resolvedDictationLocale) {
                Toggle(isOn: $store.dictationParakeet) {
                    Text("Use Parakeet for \(store.dictationLanguageName)")
                    Text("Fewer errors and real punctuation. A one-time 610 MB download.")
                }
                .help("NVIDIA's open speech model, run locally. On Russian it makes under half the word errors of the system model, punctuates (F1 0.87 against 0.02) and runs three times faster.")
                if let note = store.parakeetNote {
                    Caption(note)
                }
            }
        }
    }

    /// Microphone, the model's tidy-up, voice commands and the send-after
    /// list: each has a default that holds for most people.
    @ViewBuilder private var advanced: some View {
        Section("Microphone & cleanup") {
            Picker(selection: $store.dictationInput) {
                Text("Automatic").tag("auto")
                Text("System default").tag("system")
                Divider()
                ForEach(store.dictationInputs ?? [], id: \.uid) { device in
                    Text(device.name).tag(device.uid)
                }
                // A pinned microphone that is currently
                // unplugged has no row above, and a Picker
                // whose selection matches no tag renders
                // EMPTY — which reads as "no microphone
                // chosen" while captures still honor the pin
                // the moment it returns. Before the first
                // device list lands it is most likely plugged
                // in, so it isn't called unplugged yet.
                if store.dictationInput != "auto",
                   store.dictationInput != "system",
                   !(store.dictationInputs ?? []).contains(where: { $0.uid == store.dictationInput }) {
                    if store.dictationInputs == nil {
                        Text("Checking…", comment: "Settings → Dictation → Microphone: the chosen microphone for a moment, while the list of microphones loads.")
                            .tag(store.dictationInput)
                    } else {
                        Text("Unplugged microphone").tag(store.dictationInput)
                    }
                }
            } label: {
                Text("Microphone")
                Text(store.dictationInput == "auto"
                    ? store.dictationInputNote ?? String(localized: "Keeps wireless headphones out of call mode.")
                    : String(localized: "Wireless headsets switch to call mode while recording."))
            }
            .help(store.dictationInput == "auto"
                ? Text("A headset carries either good playback or a two-way call, never both. When your default input and output are the same headset, dictation records from the built-in microphone instead, so your audio never changes.")
                : Text("Recording from a wireless headset switches it into call mode for the capture, which makes anything playing sound flat and quiet."))
            Toggle(isOn: $dictationPolish) {
                Text("Tidy up with the model")
                Text("Fixes capitalization, punctuation and mishearings.")
            }
            .help("The same minimal-edit fix \(store.hotkeyStyle.correctionLabel) uses; a result that rephrases is rejected. Costs one short generation before the text lands. Where the fix needs a separate model, its first use downloads it.")
            Toggle(isOn: $dictationCommands) {
                Text("Voice commands on selected text")
                Text("Say an edit like “make this shorter” over a selection.")
            }
            .help("The rewrite is previewed like a fix: ⏎ applies it, ⎋ keeps the original. Off, dictating over a selection replaces it.")
        }
        Section {
            DictationSendList(store: store)
        }
    }
}

/// Where a dictation ends with ⏎. Its own view: inline, it pushed the
/// Dictation section past the type-checker's time limit.
struct DictationSendList: View {
    @Bindable var store: SettingsStore

    var body: some View {
        LabeledContent {
            Button("Add App…", systemImage: "plus") { store.addDictationSendApp() }
                .controlSize(.small)
        } label: {
            Text("Press Return after dictation")
            Text("Sends the message in these apps.")
        }
        .help("Add a website from the menu bar while you're on it.")
        ForEach(store.dictationSendApps, id: \.self) { entry in
            BlacklistRow(entry: entry, removeLabel: { String(localized: "Stop pressing Return in \($0)") },
                         removeHelp: String(localized: "Type dictations here without sending them"),
                         remove: { store.removeDictationSendApp(entry) })
        }
    }
}

/// One blacklisted app: icon + display name resolved from the stored bundle-ID
/// fragment where possible, with a remove button — the System Settings
/// app-exceptions look instead of a raw comma-separated field.
struct BlacklistRow: View {
    let entry: String
    /// The remove button's spoken name, given the app's display name.
    var removeLabel: (String) -> String = { String(localized: "Stop excluding \($0)") }
    var removeHelp = String(localized: "Allow Pretype in this app again")
    let remove: () -> Void

    var body: some View {
        let resolved = resolveApp(entry)
        HStack(spacing: 8) {
            AppIcon(icon: resolved.icon)
            Text(resolved.name)
            if resolved.name.lowercased() != entry {
                Text(entry).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            iconButton("minus.circle.fill", label: removeLabel(resolved.name), help: removeHelp, action: remove)
        }
    }
}

/// A list row's trailing icon (remove, share). The label names the row: .help
/// is a hint, not a name — without it every row's button announces identically.
@MainActor func iconButton(_ symbol: String, label: String, help: String,
                           action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: symbol).foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
    .help(help)
}

/// Exact bundle IDs resolve to the installed app's real icon and name;
/// fuzzy fragments ("slack") stay as typed with a generic glyph.
@MainActor func resolveApp(_ entry: String) -> (name: String, icon: NSImage?) {
    if let host = AppPolicy.siteHost(fromEntry: entry) {
        return (host, NSImage(systemSymbolName: "globe", accessibilityDescription: String(localized: "Website")))
    }
    guard entry.contains("."), let app = InstalledApps.lookup(entry) else { return (entry, nil) }
    return (app.name, app.icon)
}

/// The resolved 20 pt app icon, or the dashed-app placeholder.
struct AppIcon: View {
    let icon: NSImage?

    var body: some View {
        if let icon {
            Image(nsImage: icon).resizable().frame(width: 20, height: 20)
        } else {
            Image(systemName: "app.dashed")
                .frame(width: 20, height: 20)
                .foregroundStyle(.secondary)
        }
    }
}

/// One per-app persona line: icon + app name + an editable instruction field.
struct PerAppInstructionRow: View {
    let bundleID: String
    @Bindable var store: SettingsStore

    var body: some View {
        let resolved = resolveApp(bundleID)
        HStack(spacing: 8) {
            AppIcon(icon: resolved.icon)
            Text(resolved.name)
                .frame(width: 110, alignment: .leading)
                .lineLimit(1).truncationMode(.tail)
                .help(bundleID)
            // Wraps: the presets run 150–170 characters, and a one-line field
            // showed only their first third. The (hidden) label is what
            // VoiceOver reads once a preset has replaced the placeholder.
            TextField("Instructions for \(resolved.name)", text: Binding(
                get: { store.perAppInstructions[bundleID] ?? "" },
                set: { store.perAppInstructions[bundleID] = $0 }
            ), prompt: Text("e.g. formal tone, no emoji"), axis: .vertical)
                .lineLimit(1...4)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            let text = (store.perAppInstructions[bundleID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, text != PerAppPresets.community[bundleID] {
                iconButton("square.and.arrow.up", label: String(localized: "Share the style for \(resolved.name)"),
                           help: String(localized: "Share this style with other Pretype users")) {
                    store.shareStyle(bundleID, name: resolved.name)
                }
            }
            iconButton("minus.circle.fill", label: String(localized: "Remove instructions for \(resolved.name)"),
                       help: String(localized: "Remove this app's instructions")) {
                store.perAppInstructions.removeValue(forKey: bundleID)
            }
        }
    }
}

/// A shortcut row's label: the action's name, and under it a small
/// before → after picture of what the key does.
struct ShortcutLabel<Demo: View>: View {
    let title: Text
    @ViewBuilder let demo: () -> Demo

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            title
            demo()
                .font(.caption)
                .lineLimit(1)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 2)
    }
}

/// The before → after pictures of the Shortcuts rows.
@MainActor
enum ShortcutDemo {
    static var arrow: some View {
        Image(systemName: "arrow.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
    }

    /// The suggestion's next chunk joins the line; the rest stays grey.
    static var accept: some View {
        let (typed, chunk, rest) = (SuggestionLineMock.typed, SuggestionLineMock.chunk, SuggestionLineMock.rest)
        return HStack(spacing: 6) {
            Text("\(Text(typed))\(Text(chunk + rest).foregroundStyle(.tertiary))")
            arrow
            Text("\(Text(typed))\(Text(chunk).foregroundStyle(Color.green.legible).bold())\(Text(rest).foregroundStyle(.tertiary))")
        }
    }

    /// The misspelled word, struck out, and its fix.
    static var fix: some View {
        HStack(spacing: 6) {
            Text("tomorow", comment: "Settings → Shortcuts: a misspelled word the fix chord corrects. Use a common misspelling of the word translated in “tomorrow”.")
                .strikethrough(color: .red)
                .foregroundStyle(.secondary)
            arrow
            Text("tomorrow", comment: "Settings → Shortcuts: the corrected form of the misspelled word in “tomorow”.")
                .foregroundStyle(Color.green.legible)
                .bold()
        }
    }

    /// A typo the spell-checker's pill corrects as you type.
    static var typo: some View {
        HStack(spacing: 6) {
            Text("recieve", comment: "Settings → Fixes: a common misspelling the spell-checker fixes as you type. Use a common misspelling of the word translated in “receive”.")
                .strikethrough(color: .red)
                .foregroundStyle(.secondary)
            arrow
            Text("receive", comment: "Settings → Fixes: the corrected form of the misspelled word in “recieve”.")
                .foregroundStyle(Color.green.legible)
                .bold()
        }
    }

    /// The other person's message, and the reply drafted for it.
    static var reply: some View {
        HStack(spacing: 6) {
            Text("Free tonight?", comment: "Settings → Shortcuts: a sample chat message from someone else.")
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Color.primary.opacity(0.1), in: Capsule())
            arrow
            Text("Yes, see you at 7!", comment: "Settings → Shortcuts: the reply Pretype drafts to “Free tonight?”.")
                .foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Color.blue, in: Capsule())
        }
    }
}

/// The sample line at the caret — the inline ghost, or the panel pill above
/// the line — drawn by the presentation cards.
