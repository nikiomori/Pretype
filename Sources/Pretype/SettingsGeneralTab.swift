import AppKit
import SwiftUI

// MARK: - General tab

/// What Pretype does, one switch per feature, then the settings of the ones
/// that are on — a feature turned off takes its section with it — and the
/// app-wide rows.
struct GeneralTab: View {
    @Bindable var store: SettingsStore
    @State private var blacklistDraft = ""
    // An initial value only answers an unset key: reading it from `Settings`
    // keeps each default in one place.
    @AppStorage("replyGesture") private var replyGesture = Settings.replyGesture
    @AppStorage("autoReply") private var autoReply = Settings.autoReply
    @AppStorage("ghostOpacity") private var ghostOpacity = Settings.ghostOpacity
    @AppStorage("automaticUpdateCheck") private var automaticUpdateCheck = Settings.automaticUpdateCheck
    @AppStorage("dictationGesture") private var dictationGesture = Settings.dictationGesture
    @AppStorage("dictationLatch") private var dictationLatch = Settings.dictationLatch
    /// The interface-language override; "" follows the system.
    @State private var language = AppLanguage.override ?? ""

    var body: some View {
        Form {
            Section {
                features
                if !store.suggestions, !store.fixes, !store.replies, !store.dictation {
                    Caption(String(localized: "Everything is off. Pretype waits in the menu bar and reads nothing."))
                }
            } header: {
                Text("What Pretype does")
            }

            if store.suggestions { suggestionsSection }
            if store.fixes { fixesSection }
            if store.replies { repliesSection }

            Section("Turned off in these apps") {
                // The built-in exclusion is a row of the list, not a caption
                // that vanished once the user added an app of their own.
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .accessibilityHidden(true)
                    Text("Always off in password managers.")
                        .foregroundStyle(.secondary)
                }
                .help("Terminals get suggestions only in an AI agent's prompt.")
                ForEach(store.blacklist, id: \.self) { entry in
                    BlacklistRow(entry: entry) { store.removeBlacklistEntry(entry) }
                }
                HStack(spacing: 10) {
                    TextField("", text: $blacklistDraft, prompt: Text("or type part of an app ID, like “slack”"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .help("A fragment like “slack” covers Slack everywhere. ⏎ adds it.")
                        .onSubmit {
                            store.addBlacklistEntry(blacklistDraft)
                            blacklistDraft = ""
                        }
                    Button("Add App…", systemImage: "plus") { store.addBlacklistApp() }
                }
                .controlSize(.small)
            }

            appSection
        }
        .formStyle(.grouped)
    }

    // MARK: Features

    /// Two rows of two: the cards keep their places whether on or off, so a
    /// feature comes back with one click where it was.
    private var features: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                FeatureCard(symbol: "text.cursor", tint: .indigo, title: Text("Suggestions"),
                            subtitle: suggestionsLine, key: store.hotkeyStyle.label,
                            isOn: animated($store.suggestions)) {
                    if store.suggestionMode == .words {
                        Text("\(Text(WordLineMock.typed))\(Text(WordLineMock.rest).foregroundStyle(.tertiary))")
                    } else {
                        Text("\(Text(SuggestionLineMock.typed))\(Text(SuggestionLineMock.chunk + SuggestionLineMock.rest).foregroundStyle(.tertiary))")
                    }
                }
                FeatureCard(symbol: "textformat.abc.dottedunderline", tint: .pink, title: Text("Fixes"),
                            subtitle: Text("Fixes typos and the word you just typed."),
                            key: store.hotkeyStyle.correctionLabel, isOn: animated($store.fixes)) {
                    ShortcutDemo.fix
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                FeatureCard(symbol: "bubble.left.and.text.bubble.right.fill", tint: .green, title: Text("Replies"),
                            subtitle: Text("Drafts a reply to the message on screen."),
                            key: replyGesture == .off ? store.hotkeyStyle.replyLabel : replyGesture.label,
                            isOn: animated($store.replies)) {
                    ShortcutDemo.reply
                }
                FeatureCard(symbol: "mic.fill", tint: .red, title: Text("Dictation"),
                            subtitle: Text("Talk instead of typing."),
                            key: dictationKey, isOn: $store.dictation,
                            options: { store.activeTab = .dictation },
                            demo: {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform").foregroundStyle(.red)
                        ShortcutDemo.arrow
                        Text("see you at seven", comment: "Settings → General → Dictation card: a few spoken words as Pretype types them.")
                    }
                })
                // Turning it on asks for the microphone, and some Macs can't
                // dictate at all: the Dictation pane explains, with the fix.
                .disabled(store.dictationBlocker != nil && !store.dictation)
                .help(store.dictationBlocker.map { Text($0) } ?? Text(verbatim: ""))
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The card's subtitle says what is happening now — and, off, what that
    /// buys: no model held for suggestions.
    private var suggestionsLine: Text {
        guard store.suggestions else { return Text("Off. No model in memory until you fix or reply.") }
        return store.suggestionMode == .words ? Text("Finishes the word you're typing.")
                                              : Text("Continues your sentence as you type.")
    }

    /// Hold-to-talk's key, or the hands-free chord when holding is off.
    private var dictationKey: String? {
        if dictationGesture != .off { return dictationGesture.label }
        return dictationLatch != .off ? dictationLatch.label : nil
    }

    /// A switch that shows or hides a whole section below it, eased.
    private func animated(_ binding: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { binding.wrappedValue },
                set: { value in withAnimation(.easeInOut(duration: 0.18)) { binding.wrappedValue = value } })
    }

    // MARK: Suggestions

    @ViewBuilder private var suggestionsSection: some View {
        Section {
            HStack(spacing: 12) {
                PreviewCard(title: String(localized: "Words"),
                            subtitle: String(localized: "Finishes the word you're typing, from words you use. Instant, no model."),
                            isSelected: store.suggestionMode == .words,
                            action: { store.suggestionMode = .words },
                            preview: { WordLineMock(hotkey: store.hotkeyStyle.label) })
                PreviewCard(title: String(localized: "Sentences"),
                            subtitle: sentencesLine,
                            isSelected: store.suggestionMode == .sentences,
                            action: { store.suggestionMode = .sentences },
                            preview: { SuggestionLineMock(presentation: .inline, opacity: 0.7, hotkey: store.hotkeyStyle.label) })
            }
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                // Animate at the mutation site: the Ghost-visibility row
                // below inserts/removes on this change, and a row cannot
                // animate its own insertion from a Section modifier.
                PreviewCard(title: String(localized: "Panel"),
                            subtitle: String(localized: "A small box above the line. It never covers your text."),
                            isSelected: store.presentation == .panel,
                            action: { withAnimation(.easeInOut(duration: 0.18)) { store.presentation = .panel } },
                            preview: { SuggestionLineMock(presentation: .panel, opacity: ghostOpacity, hotkey: store.hotkeyStyle.label) })
                PreviewCard(title: String(localized: "Inline"),
                            subtitle: String(localized: "Ghost text right at the cursor. It can leave drawing glitches in some apps."),
                            badge: String(localized: "Unstable"),
                            isSelected: store.presentation == .inline,
                            action: { withAnimation(.easeInOut(duration: 0.18)) { store.presentation = .inline } },
                            preview: { SuggestionLineMock(presentation: .inline, opacity: ghostOpacity, hotkey: store.hotkeyStyle.label) })
            }
            // Ideal height of the taller card, which the other then fills.
            .fixedSize(horizontal: false, vertical: true)
            // Ghost opacity dims inline ghost text only; the panel is an
            // opaque HUD by design (SuggestionWindow), so the slider is
            // inline-only — a control that moved the preview but never the
            // real panel pill was misleading.
            if store.presentation == .inline {
                LabeledContent("Ghost visibility") {
                    HStack(spacing: 8) {
                        Text("Faint").font(.caption).foregroundStyle(.secondary)
                        // Floor at 40%: the help text itself calls 45%
                        // near-invisible, and below that the ghost vanished.
                        Slider(value: $ghostOpacity, in: 0.4...1, step: 0.05)
                            .accessibilityLabel("Ghost visibility")
                            .accessibilityValue("\(Int(ghostOpacity * 100)) percent")
                        Text("Bold").font(.caption).foregroundStyle(.secondary)
                        Text("\(Int(ghostOpacity * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                    .frame(width: 320)
                    .help("How strongly the ghost text stands out from your own. 70% measured most readable over real app backgrounds — 45% was near-invisible.")
                }
            }

            Picker(selection: $store.hotkeyStyle) {
                ForEach(HotkeyStyle.allCases, id: \.self) { Text($0.label).tag($0) }
            } label: {
                ShortcutLabel(title: Text("Accept hotkey")) { ShortcutDemo.accept }
            }
            hotkeyWarning
            Toggle(isOn: $store.agentPromptSuggestions) {
                Text("In AI agents' prompts")
                Text("Claude Code, Codex and others in Terminal, iTerm and VS Code.")
            }
        } header: {
            Text("Suggestions")
        }
    }

    /// The Sentences card names the model it runs — or the hosted one.
    private var sentencesLine: String {
        if store.apiText.enabled {
            return String(localized: "The model continues your sentence. Runs on \(store.apiText.preset.name).")
        }
        let name = ModelMetrics.metrics(for: store.modelID)?.shortName ?? store.selectedModelName
        guard let gb = store.projection.ramGB, gb > 0 else {
            return String(localized: "The model continues your sentence. \(name).")
        }
        return String(localized: "The model continues your sentence. \(name) · \(gbLabel(gb)).")
    }

    /// Pretype takes the fix chord on every press and the accept key whenever
    /// a suggestion is up — said where the pick is made, not after the
    /// user's input-source switch stops working.
    @ViewBuilder private var hotkeyWarning: some View {
        switch store.hotkeyStyle {
        case .ctrlSpace:
            Caption(String(localized: "⚠︎ ⌃Space and \(store.hotkeyStyle.correctionLabel) also switch keyboard layouts in macOS."))
        case .cmdSpace:
            Caption(String(localized: "⚠︎ ⌘Space opens Spotlight and \(store.hotkeyStyle.correctionLabel) a Finder search."))
        default:
            EmptyView()
        }
    }

    // MARK: Fixes

    @ViewBuilder private var fixesSection: some View {
        Section {
            // The fix chord is ⌥ + the accept key. With suggestions off there
            // is no accept key to pick, so the chord is picked here — one row
            // per distinct chord (⌘Space and ⌥Space both fix on ⌥⌘Space).
            if store.suggestions {
                LabeledContent {
                    MenuHintsView.keycap(store.hotkeyStyle.correctionLabel)
                } label: {
                    ShortcutLabel(title: Text("Fix the last word or the selection")) { ShortcutDemo.fix }
                }
                .help("⏎ applies the fix, esc keeps yours. The key follows the accept hotkey.")
            } else {
                Picker(selection: fixChord) {
                    ForEach(Self.fixChords, id: \.self) { Text($0.correctionLabel).tag($0) }
                } label: {
                    ShortcutLabel(title: Text("Fix the last word or the selection")) { ShortcutDemo.fix }
                }
                .help("⏎ applies the fix, esc keeps yours.")
                hotkeyWarning
            }
            Toggle(isOn: $store.fixTypos) {
                ShortcutLabel(title: Text("Typos as you type")) { ShortcutDemo.typo }
            }
            .help("A misspelled word gets its correction over it: \(store.hotkeyStyle.label) takes it, esc keeps yours. Uses the macOS spell-checker.")
            Toggle(isOn: $store.emojiShortcodes) {
                ShortcutLabel(title: Text("Emoji from :codes:")) {
                    HStack(spacing: 6) {
                        Text(verbatim: ":thumbsup:").foregroundStyle(.secondary)
                        ShortcutDemo.arrow
                        Text(verbatim: "👍")
                    }
                }
            }
            .help("A closed :shortcode: becomes its emoji when you press \(store.hotkeyStyle.label).")
            Toggle(isOn: $store.inlineMath) {
                ShortcutLabel(title: Text("Math after =")) {
                    HStack(spacing: 6) {
                        Text(verbatim: "12*4=").foregroundStyle(.secondary)
                        ShortcutDemo.arrow
                        Text(verbatim: "48").foregroundStyle(Color.green.legible).bold()
                    }
                }
            }
            .help("A sum typed with = at the end gets its result; \(store.hotkeyStyle.label) types it.")
        } header: {
            Text("Fixes")
        }
    }

    /// One style per fix chord, in the picker's order.
    private static let fixChords: [HotkeyStyle] = HotkeyStyle.allCases.reduce(into: []) { kept, style in
        if !kept.contains(where: { $0.correctionLabel == style.correctionLabel }) { kept.append(style) }
    }

    /// The stored style, shown as the first one with its chord.
    private var fixChord: Binding<HotkeyStyle> {
        Binding(get: { Self.fixChords.first { $0.correctionLabel == store.hotkeyStyle.correctionLabel } ?? .tab },
                set: { store.hotkeyStyle = $0 })
    }

    // MARK: Replies

    @ViewBuilder private var repliesSection: some View {
        Section {
            Picker(selection: $replyGesture) {
                ForEach(ReplyGesture.allCases, id: \.self) { gesture in
                    gesture == .off ? Text("Only \(store.hotkeyStyle.replyLabel)") : Text(gesture.label)
                }
            } label: {
                ShortcutLabel(title: Text("Write a reply")) { ShortcutDemo.reply }
            }
            .help("\(store.hotkeyStyle.label) takes a word, \(store.hotkeyStyle.shiftLabel) all of it. Tap the chosen modifier twice, or press \(store.hotkeyStyle.replyLabel).")
            Toggle(isOn: $autoReply) {
                Text("Offer replies in chats")
                Text("Drafts a reply when you click into an empty message box.")
            }
            .help("In Messages, Telegram, WhatsApp, Slack, Discord and other messengers. Typing anything drops the reply. It starts once the reply model is downloaded — the chord's first use downloads it.")
            // Replies read the screen, which is off by default and needs a
            // permission — what's missing is listed with its fix, and
            // nothing is listed once it's all in place.
            if autoReply {
                if !store.screenContext {
                    RequirementRow(met: false, text: String(localized: "Screen context on"),
                                   fixTitle: String(localized: "Turn On")) { store.screenContext = true }
                }
                if !ScreenContext.hasPermission {
                    RequirementRow(met: false,
                                   text: String(localized: "Screen Recording allowed (then relaunch Pretype)"),
                                   fixTitle: String(localized: "Open System Settings…")) { ScreenContext.openScreenRecordingPane() }
                }
            }
        } header: {
            Text("Replies")
        }
    }

    // MARK: Pretype

    /// App-wide: login first, the switch people come here for.
    private var appSection: some View {
        Section {
            // Bound to launchd, not to a stored bool: the same switch lives
            // in System Settings → Login Items, and mirroring it in
            // UserDefaults would eventually show a state that isn't real.
            // Only `.enabled` is on: `.requiresApproval` is registered but
            // held by macOS — on, yet doing nothing.
            Toggle(isOn: Binding(
                get: { store.loginStatus == .enabled },
                set: { store.setOpenAtLogin($0) }
            )) {
                IconLabel(symbol: "power", tint: .gray, title: Text("Open at login"))
            }
            .help("Also in System Settings → General → Login Items.")
            .disabled(!LoginItem.isSupported)
            // The same switch lives in System Settings, and `sync()` only
            // runs when the window is (re)presented — catch the user coming
            // back from flipping it there, or this toggle only catches up
            // when the window reopens.
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)) { _ in
                store.loginStatus = LoginItem.status
            }
            if let note = LoginItem.note(store.loginStatus) {
                Caption(note)
            }
            Toggle(isOn: $automaticUpdateCheck) {
                IconLabel(symbol: "arrow.down.circle.fill", tint: .blue,
                          title: Text("Check for updates automatically"),
                          subtitle: Text("Asks GitHub once a day. Sends nothing about you."))
            }
            .help("New versions are announced in the menu bar; nothing is downloaded automatically.")
            Picker(selection: $language) {
                Text("System (\(AppLanguage.nativeName(AppLanguage.systemChoice)))").tag("")
                Divider()
                ForEach(AppLanguage.available, id: \.self) { code in
                    Text(verbatim: AppLanguage.nativeName(code)).tag(code)
                }
            } label: {
                IconLabel(symbol: "globe", tint: .blue, title: Text("Language"))
            }
            .onChange(of: language) { AppLanguage.override = language.isEmpty ? nil : language }
            if (language.isEmpty ? AppLanguage.systemChoice : language) != AppLanguage.running {
                // Only a bundled app can reopen itself; a bare dev binary is restarted by hand.
                if MicrophoneAccess.isBundled {
                    LabeledContent {
                        Button("Relaunch") { AppLanguage.relaunch() }
                    } label: {
                        Text("Relaunch Pretype to switch the language.")
                    }
                } else {
                    Caption(String(localized: "Restart Pretype to switch the language."))
                }
            }
        } header: {
            Text(verbatim: "Pretype")
        }
    }
}

/// One feature of "What Pretype does": its tile, name and one line, its
/// switch, and a before → after picture with the key that does it. Off, the
/// picture greys out and the card stays where it is.
struct FeatureCard<Demo: View>: View {
    let symbol: String
    let tint: Color
    let title: Text
    let subtitle: Text
    let key: String?
    @Binding var isOn: Bool
    /// The feature's own pane, when it has one (Dictation).
    var options: (() -> Void)?
    @ViewBuilder let demo: () -> Demo

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                SettingsIcon(symbol: symbol, tint: isOn ? tint : .gray, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    title.font(.body.weight(.semibold))
                        .foregroundStyle(isOn ? .primary : .secondary)
                    subtitle.font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let options, isOn {
                        Button("Options", action: options)
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
                Spacer(minLength: 4)
                Toggle(isOn: $isOn) { title }
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            HStack(spacing: 7) {
                demo()
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let key { MenuHintsView.keycap(key) }
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1))
            .saturation(isOn ? 1 : 0)
            .opacity(isOn ? 1 : 0.45)
            .accessibilityHidden(true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        .animation(.easeOut(duration: 0.18), value: isOn)
    }
}
