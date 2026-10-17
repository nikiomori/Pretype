import AppKit
import AVFoundation
import Carbon
import SwiftUI

extension Color {
    /// This tint as small TEXT: darkened under the light appearance, where
    /// system green, orange and teal at caption size sit near 2:1 on a light
    /// form. Dark is untouched — there they already clear 4.5:1.
    var legible: Color {
        let base = NSColor(self)
        return Color(nsColor: NSColor(name: nil) { appearance in
            var resolved = base
            appearance.performAsCurrentDrawingAppearance { resolved = base.usingColorSpace(.sRGB) ?? base }
            return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? resolved : (resolved.blended(withFraction: 0.35, of: .black) ?? resolved)
        })
    }
}

/// One requirement of a currently-unavailable feature: a ✓/✗ line with a
/// one-click fix, so "why is this greyed out" is visible and actionable
/// instead of a sentence the user has to decode.
struct RequirementRow: View {
    let met: Bool
    let text: String
    let fixTitle: String
    let fix: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: met ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(met ? Color.green : Color.orange)
                .font(.caption)
                // Not just symbol + color: VoiceOver read the row the same either way.
                .accessibilityLabel(met ? Text("Done") : Text("Missing"))
            Text(text)
                .font(.caption)
                .foregroundStyle(met ? Color.secondary : Color.primary)
            if !met {
                // .mini is a ~14pt target on the one button whose job is
                // rescuing a blocked state — .small is the smallest honest size.
                Button(fixTitle, action: fix)
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 2)
    }
}

/// Secondary explanatory text under a control (System Settings caption style).
struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One decimal in the user's own number format: "1.2" or "1,2".
func oneDecimal(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(1)))
}

/// "640 ms", "1.2 s": past a second, milliseconds read as seconds.
func latencyLabel(ms: Int) -> String {
    ms >= 1000 ? String(localized: "\(oneDecimal(Double(ms) / 1000)) s") : String(localized: "\(ms) ms")
}

/// "1.4 GB" — one decimal, the unit through the catalog; "0 GB" for the
/// system model, which holds no app memory.
func gbLabel(_ gb: Double) -> String {
    gb <= 0 ? String(localized: "0 GB") : String(localized: "\(oneDecimal(gb)) GB")
}

// MARK: - Root

enum SettingsTab: CaseIterable {
    case general, model, dictation, personalization, api

    /// Sidebar icon, drawn as a tile in `tint`.
    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .model: return "cpu.fill"
        case .dictation: return "mic.fill"
        case .personalization: return "person.fill"
        case .api: return "cloud.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: return .gray
        case .model: return .purple
        case .dictation: return .red
        case .personalization: return .blue
        case .api: return .teal
        }
    }

    /// Sidebar label and pane title.
    var title: String {
        switch self {
        case .general: return String(localized: "General")
        case .model: return String(localized: "Model")
        case .dictation: return String(localized: "Dictation")
        case .personalization: return String(localized: "Personalization")
        case .api: return String(localized: "API")
        }
    }
}

/// A System Settings icon tile: a white glyph on a colored rounded square,
/// so a row is found by its picture before its words are read.
struct SettingsIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A row title with its icon tile and an optional one-line subtitle — the
/// label of the main switches.
struct IconLabel: View {
    let symbol: String
    let tint: Color
    let title: Text
    var subtitle: Text?

    var body: some View {
        HStack(spacing: 10) {
            SettingsIcon(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                title
                if let subtitle {
                    subtitle.font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The last row of a pane: shows or hides the pane's detailed settings
/// under it. One switch for every pane — whoever wants them once wants them
/// everywhere.
struct AdvancedRow: View {
    @AppStorage("showAdvancedSettings") private var shown = false

    var body: some View {
        Section {
            // Only the chevron animates: rows sliding into a grouped Form
            // re-laid out the whole pane on every frame of the slide.
            Button {
                shown.toggle()
            } label: {
                HStack {
                    Text("Advanced")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(shown ? 90 : 0))
                        .animation(.easeInOut(duration: 0.2), value: shown)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(shown ? Text("Expanded") : Text("Collapsed"))
        }
    }
}

/// Sidebar + pane + Live Impact inspector — the System Settings shape of the
/// new macOS: navigation and the rail render on system Liquid Glass, content
/// stays on standard grouped-form backgrounds (per the HIG, glass is for the
/// floating layer, never the content itself).
struct SettingsRootView: View {
    @Bindable var store: SettingsStore

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .frame(minWidth: 1020, minHeight: 620)
        // On the root, not a tab: rows, cards and the map ask from Model, the
        // Style picker and "Use recommended settings" from Suggestions.
        .confirmationDialog(store.pendingDownload.map { String(localized: "Download \($0.name)?") } ?? "",
                            isPresented: Binding(get: { store.pendingDownload != nil },
                                                 set: { if !$0 { store.pendingDownload = nil } }),
                            presenting: store.pendingDownload) { pending in
            Button("Download") {
                store.pendingDownload = nil
                pending.commit()
            }
            Button("Cancel", role: .cancel) { store.pendingDownload = nil }
        } message: { pending in
            pending.sizeGB > 0
                ? Text("About \(oneDecimal(pending.sizeGB)) GB. Suggestions pause until it's ready.")
                : Text("Suggestions pause until it's ready.")
        }
    }

    private var sidebar: some View {
        List(selection: $store.activeTab) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                Label { Text(tab.title) } icon: { SettingsIcon(symbol: tab.symbol, tint: tab.tint) }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 176, ideal: 200, max: 240)
        .safeAreaInset(edge: .top) {
            HStack(spacing: 9) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: "Pretype").font(.headline)
                    Text("v\(UpdateChecker.currentVersion)").font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                // The master switch, on every pane: fix, reply and dictation
                // stop with it, same as Pause Pretype in the menu bar.
                Toggle("Pretype", isOn: $store.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Off pauses suggestions, fix, reply and dictation — same as Pause Pretype in the menu bar")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .safeAreaInset(edge: .bottom) {
            EngineStatusFooter(controller: store.controller)
        }
    }

    private var detail: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                // Over the form's own column: a grouped Form stops growing at
                // ~704 pt and centers, and a title left at the pane's edge stood
                // apart from it on every pane without the rail.
                Text(store.activeTab.title)
                    .font(.title2.weight(.bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(maxWidth: 704)
                .padding(.horizontal, 22)
                .padding(.top, 12)
                .padding(.bottom, 8)
                Group {
                    switch store.activeTab {
                    case .general: GeneralTab(store: store)
                    case .model: ModelTab(store: store)
                    case .dictation: DictationTab(store: store)
                    case .personalization: PersonalTab(store: store)
                    case .api: APITab(store: store)
                    }
                }
            }
            // The rail measures model settings, so it stands beside the Model
            // pane only. A plain column, not an .inspector: an inspector shown
            // per pane made the split view animate its columns, and the
            // sidebar collapsed and sprang back on every visit to Model.
            if store.activeTab == .model {
                Divider()
                ImpactRailView(store: store)
                    .frame(width: 280)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The sidebar's engine line: the menu's own status, on its own 1 s clock. A
/// download's byte counts change every tick, and published on the store they
/// re-rendered every tab's Form with them.
private struct EngineStatusFooter: View {
    let controller: SuggestionController?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let status = StatusMenuController.status(of: controller)
            HStack(alignment: .top, spacing: 7) {
                // A download, a load or a warm-up — never the idle-unloaded
                // resting state, which the menu (and this) calls ready.
                // The detail wraps instead of truncating in a 176pt column.
                Group {
                    if status.color == .systemOrange, controller?.engine.isLoading == true {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                    } else {
                        Circle().fill(Color(nsColor: status.color))
                    }
                }
                .frame(width: 8, height: 8)
                .padding(.top, 3)   // align with the caption's first baseline
                Text(status.text)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .help(status.text)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}

/// Segmented control with per-option hover callbacks (the native Picker
/// exposes none). The selection thumb is a single view that SLIDES between
/// segments (matchedGeometryEffect + spring), rendered as an elevated control
/// surface so the selection is unmistakable in both light and dark.
struct HoverSegments<T: Hashable>: View {
    /// Spoken name — the control is one native segmented picker to VoiceOver.
    let title: String
    let options: [(value: T, label: String)]
    let selection: T
    let select: (T) -> Void
    var hover: ((T, Bool) -> Void)?

    @Namespace private var thumbSpace
    @State private var hovered: T?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let isOn = option.value == selection
                Button { select(option.value) } label: {
                    Text(option.label)
                        .font(.callout.weight(isOn ? .semibold : .regular))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .focusable(false)   // one Tab stop for the whole control, below
                .background {
                    if isOn {
                        thumb.matchedGeometryEffect(id: "thumb", in: thumbSpace)
                    } else if hovered == option.value {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.quaternary.opacity(0.4))
                    }
                }
                .onHover { over in
                    guard isEnabled else { return }
                    hovered = over ? option.value : (hovered == option.value ? nil : hovered)
                    hover?(option.value, over)
                }
            }
        }
        .padding(2)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .opacity(isEnabled ? 1 : 0.5)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85), value: selection)
        .animation(.easeOut(duration: 0.12), value: hovered)
        // Like the native control: one Tab stop, arrows move the selection,
        // and VoiceOver reads a segmented picker ("Base, 1 of 2") rather than
        // a row of loose buttons.
        .focusable(interactions: .activate)
        .onMoveCommand { direction in
            guard let i = options.firstIndex(where: { $0.value == selection }) else { return }
            let j = direction == .left ? i - 1 : direction == .right ? i + 1 : i
            if j != i, options.indices.contains(j) { select(options[j].value) }
        }
        .accessibilityRepresentation {
            Picker(title, selection: Binding(get: { selection }, set: select)) {
                ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
            }
            .pickerStyle(.segmented)
        }
    }

    /// The sliding selection thumb — an elevated surface that reads clearly in
    /// both themes. macOS 26's `Color.clear.glassEffect` rendered as frosted-
    /// clear over the translucent track: on a light form it matched the
    /// background, so only the bold label marked the selection. A solid control
    /// surface + soft shadow is the native segmented-picker look and is
    /// unmistakable in either appearance.
    private var thumb: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color(nsColor: .controlColor))
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
    }
}

// MARK: - General tab

struct GeneralTab: View {
    @Bindable var store: SettingsStore
    @State private var blacklistDraft = ""
    // An initial value only answers an unset key: reading it from `Settings`
    // keeps each default in one place.
    @AppStorage("replyGesture") private var replyGesture = Settings.replyGesture
    @AppStorage("autoReply") private var autoReply = Settings.autoReply
    @AppStorage("ghostOpacity") private var ghostOpacity = Settings.ghostOpacity
    @AppStorage("automaticUpdateCheck") private var automaticUpdateCheck = Settings.automaticUpdateCheck
    /// The interface-language override; "" follows the system.
    @State private var language = AppLanguage.override ?? ""

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    // Animate at the mutation site: the Ghost-visibility row
                    // below inserts/removes on this change, and a row cannot
                    // animate its own insertion from a Section modifier.
                    PresentationCard(mode: .panel, title: String(localized: "Panel"),
                                     isSelected: store.presentation == .panel,
                                     hotkeyLabel: store.hotkeyStyle.label, ghost: ghostOpacity) {
                        withAnimation(.easeInOut(duration: 0.18)) { store.presentation = .panel }
                    }
                    PresentationCard(mode: .inline, title: String(localized: "Inline"), badge: String(localized: "Unstable"),
                                     isSelected: store.presentation == .inline,
                                     hotkeyLabel: store.hotkeyStyle.label, ghost: ghostOpacity) {
                        withAnimation(.easeInOut(duration: 0.18)) { store.presentation = .inline }
                    }
                }
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
            } header: {
                Text("Suggestion display")
            } footer: {
                store.presentation == .inline
                    ? Text("Ghost text right at the cursor. It can leave drawing glitches in some apps.")
                    : Text("A small box above the line. It never covers your text.")
            }

            // Every key Pretype answers to, each with a picture of what it does.
            Section("Shortcuts") {
                Picker(selection: $store.hotkeyStyle) {
                    ForEach(HotkeyStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                } label: {
                    ShortcutLabel(title: Text("Accept hotkey")) { ShortcutDemo.accept }
                }
                // Pretype takes the fix chord on every press and the accept key
                // whenever a suggestion is up — say so where the pick is made,
                // not after the user's input-source switch stops working.
                switch store.hotkeyStyle {
                case .ctrlSpace:
                    Caption(String(localized: "⚠︎ ⌃Space and \(store.hotkeyStyle.correctionLabel) also switch keyboard layouts in macOS."))
                case .cmdSpace:
                    Caption(String(localized: "⚠︎ ⌘Space opens Spotlight and \(store.hotkeyStyle.correctionLabel) a Finder search."))
                default:
                    EmptyView()
                }
                LabeledContent {
                    MenuHintsView.keycap(store.hotkeyStyle.correctionLabel)
                } label: {
                    ShortcutLabel(title: Text("Fix last word / selection")) { ShortcutDemo.fix }
                }
                Picker(selection: $replyGesture) {
                    ForEach(ReplyGesture.allCases, id: \.self) { Text($0.label).tag($0) }
                } label: {
                    ShortcutLabel(title: Text("Write a reply")) { ShortcutDemo.reply }
                }
                .help("\(store.hotkeyStyle.label) takes a word, \(store.hotkeyStyle.shiftLabel) all of it. Tap the chosen modifier twice, or press \(store.hotkeyStyle.replyLabel).")
            }

            Section {
                Toggle(isOn: $autoReply) {
                    IconLabel(symbol: "bubble.left.and.text.bubble.right.fill", tint: .green,
                              title: Text("Offer replies in chats"),
                              subtitle: Text("Drafts a reply when you click into an empty message box."))
                }
                .help("In Messages, Telegram, WhatsApp, Slack, Discord and other messengers. Typing anything drops the reply. It starts once the reply model is downloaded — the chord's first use downloads it.")
                // Replies read the screen, which is off by default and needs a
                // permission — what's missing is listed with its fix, and
                // nothing is listed once it's all in place.
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

            Section("Turned off in these apps") {
                if store.blacklist.isEmpty {
                    Caption(String(localized: "Always off in password managers."))
                        .help("Terminals get suggestions only in an AI agent's prompt.")
                }
                ForEach(store.blacklist, id: \.self) { entry in
                    BlacklistRow(entry: entry) { store.removeBlacklistEntry(entry) }
                }
                HStack(spacing: 10) {
                    Button("Add App…", systemImage: "plus") { store.addBlacklistApp() }
                    TextField("", text: $blacklistDraft, prompt: Text("or type part of a bundle ID"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .help("A fragment like “slack” covers Slack everywhere. ⏎ adds it.")
                        .onSubmit {
                            store.addBlacklistEntry(blacklistDraft)
                            blacklistDraft = ""
                        }
                }
                .controlSize(.small)
            }

            Section {
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
            }
        }
        .formStyle(.grouped)
    }
}

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
                Section {
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

                AdvancedRow()
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

    /// Microphone, silence stop, the model's tidy-up, voice commands and the
    /// send-after list: each has a default that holds for most people.
    @ViewBuilder private var advanced: some View {
        Section {
            Picker(selection: $store.dictationInput) {
                Text("Automatic").tag("auto")
                Text("System default").tag("system")
                Divider()
                ForEach(store.dictationInputs, id: \.uid) { device in
                    Text(device.name).tag(device.uid)
                }
                // A pinned microphone that is currently
                // unplugged has no row above, and a Picker
                // whose selection matches no tag renders
                // EMPTY — which reads as "no microphone
                // chosen" while captures still honor the pin
                // the moment it returns.
                if store.dictationInput != "auto",
                   store.dictationInput != "system",
                   !store.dictationInputs.contains(where: { $0.uid == store.dictationInput }) {
                    Text("Unplugged microphone").tag(store.dictationInput)
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
            if dictationLatch != .off {
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
private struct DictationSendList: View {
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
private struct BlacklistRow: View {
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
                Text(entry).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            iconButton("minus.circle.fill", label: removeLabel(resolved.name), help: removeHelp, action: remove)
        }
    }
}

/// A list row's trailing icon (remove, share). The label names the row: .help
/// is a hint, not a name — without it every row's button announces identically.
@MainActor private func iconButton(_ symbol: String, label: String, help: String,
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
@MainActor private func resolveApp(_ entry: String) -> (name: String, icon: NSImage?) {
    if let host = AppPolicy.siteHost(fromEntry: entry) {
        return (host, NSImage(systemSymbolName: "globe", accessibilityDescription: String(localized: "Website")))
    }
    guard entry.contains("."), let app = InstalledApps.lookup(entry) else { return (entry, nil) }
    return (app.name, app.icon)
}

/// The resolved 20 pt app icon, or the dashed-app placeholder.
private struct AppIcon: View {
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
private struct PerAppInstructionRow: View {
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
private struct ShortcutLabel<Demo: View>: View {
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
private enum ShortcutDemo {
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
struct SuggestionLineMock: View {
    static let typed = String(localized: "Write ", comment: "Settings overlay preview: the sample sentence “Write a reply to Anna” is drawn in three parts. This is part 1, the text typed before the caret. Keep the trailing space.")
    static let chunk = String(localized: "a reply", comment: "Settings overlay preview: the sample sentence “Write a reply to Anna” is drawn in three parts. This is part 2, the suggestion's first chunk right after the caret.")
    static let rest = String(localized: " to Anna", comment: "Settings overlay preview: the sample sentence “Write a reply to Anna” is drawn in three parts. This is part 3, the rest of the suggestion up to its end. Keep the leading space.")

    let presentation: SuggestionPresentation
    let opacity: Double
    let hotkey: String
    private let ink = Color.primary

    var body: some View {
        // The slider dims inline ghost text; the panel pill is an opaque HUD and
        // stays full-strength, so the preview must not move it either — else it
        // promises an effect the real panel never applies.
        let effective = presentation == .inline ? opacity : 1.0
        // Same split the real ghost draws with (SuggestionWindow.suggestionGhost):
        // the ⇥ chunk at full strength, the tail at 0.72 — a preview that dimmed
        // differently promised a look the caret never delivered.
        let head = ink.opacity(1.0 * effective)
        let tail = ink.opacity(0.72 * effective)
        let (typed, chunk, rest) = (Self.typed, Self.chunk, Self.rest)
        return Group {
            if presentation == .inline {
                // The ghost, then the accept keycap a new user sees beside it.
                HStack(spacing: 6) {
                    Text("\(Text(typed).foregroundColor(ink))\(Text(chunk).foregroundColor(head))\(Text(rest).foregroundColor(tail))")
                    MenuHintsView.keycap(hotkey)
                        .opacity(min(1, effective / 0.7))
                }
            } else {
                // The pill floats just ABOVE the line, starting at the caret —
                // where the real one sits — never beside the typed words.
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 0) {
                        Text(typed).hidden()
                        HStack(spacing: 6) {
                            Text("\(Text(chunk).foregroundColor(ink))\(Text(rest).foregroundColor(ink.opacity(0.55)))")
                            MenuHintsView.keycap(hotkey)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(ink.opacity(0.07), in: Capsule())
                        .overlay(Capsule().stroke(ink.opacity(0.15), lineWidth: 0.5))
                    }
                    Text(typed).foregroundColor(ink)
                }
            }
        }
        .font(.system(size: 13))
        .lineLimit(1)
        // One description for VoiceOver instead of the sample sentence read
        // word by word.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation == .inline
            ? Text("Preview: grey suggestion text continues the line after the cursor")
            : Text("Preview: the suggestion floats in a small box above the line"))
    }
}

/// Selectable preview card rendering a miniature of how that mode looks at the
/// caret, so the choice is visual, not abstract.
private struct PresentationCard: View {
    let mode: SuggestionPresentation
    let title: String
    /// Short status tag beside the title (e.g. "Unstable").
    var badge: String? = nil
    let isSelected: Bool
    /// The chosen accept key, shown in the mockup so it matches the live
    /// overlay instead of a hardcoded ⇥.
    let hotkeyLabel: String
    /// The configured ghost opacity, so the inline mockup dims like the caret.
    let ghost: Double
    let action: () -> Void
    /// Local hover only — a card highlight, never published to the store the
    /// Form observes (that path hitches list scrolling).
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor))
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
                    SuggestionLineMock(presentation: mode, opacity: ghost, hotkey: hotkeyLabel)
                        .padding(.horizontal, 10)
                }
                .frame(height: 44)
                HStack {
                    Text(title).font(.subheadline.weight(.semibold))
                    if let badge {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.15)))
                    }
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentColor.opacity(0.08)
                          : (hovering ? Color.primary.opacity(0.04) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor
                            : (hovering ? Color.primary.opacity(0.22) : Color(nsColor: .separatorColor)),
                            lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(badge.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .frame(maxWidth: .infinity)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Suggestion tuning

/// Style and length: the Model pane's advanced section. "Use recommended
/// settings" sets both per model, and most people never leave it.
struct TuningSection: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Section("Suggestions") {
            // Apple Intelligence runs as the macOS system model on the Neural
            // Engine: Style and the precision gate never reach it
            // (EngineCoordinator sends only length + persona).
            if store.isAppleIntelligence {
                Caption(String(localized: "Style and precision don't apply to Apple Intelligence."))
            } else {
                Toggle(isOn: $store.useRecommended) {
                    Text("Use recommended settings")
                    if store.useRecommended {
                        Text("Now \(store.recommendation.summary). Changing Style or Length turns this off.")
                    } else {
                        Text("Best for this model: \(store.recommendation.summary).")
                    }
                }
                .onHover { store.setHover(.useRecommended(!store.useRecommended), $0) }
                LabeledContent {
                    HoverSegments(title: String(localized: "Style"),
                                  options: CompletionStyle.allCases.map { ($0, $0.label) },
                                  selection: store.style,
                                  select: { style in
                                      // Base↔Instruct inserts/removes the
                                      // length row and the precision cards.
                                      withAnimation(.easeInOut(duration: 0.18)) { store.style = style }
                                  },
                                  hover: { style, hovering in
                                      store.setHover(.style(style), hovering)
                                  })
                        .frame(width: 220)
                } label: {
                    Text("Style")
                    if store.style == .instruct {
                        Text("Follows your persona. Loads a second model.")
                    } else {
                        Text("Continues your text. Most accurate on everyday typing.")
                    }
                }
                if store.style == .instruct, store.instructUnusable {
                    RequirementRow(met: false,
                                   text: String(localized: "Instruct doesn't work on \(store.selectedModelName)"),
                                   fixTitle: String(localized: "Switch to Base")) { withAnimation(.easeInOut(duration: 0.18)) { store.style = .base } }
                        .help("It answers the text instead of continuing it. Instruct needs a Gemma E4B model.")
                }
            }
            // Base style's entropy stop ends a suggestion inside even Short's
            // budget (identical output at all three lengths, 2026-10-15), so
            // the control only shows where it does something. Apple
            // Intelligence reads length whatever the style says.
            if store.style != .base || store.isAppleIntelligence {
                LabeledContent {
                    HoverSegments(title: String(localized: "Length"),
                                  options: CompletionLength.allCases.map { ($0, $0.label) },
                                  selection: store.length,
                                  select: { store.length = $0 },
                                  hover: { length, hovering in
                                      store.setHover(.length(length), hovering)
                                  })
                        .frame(width: 260)
                } label: {
                    Text("Length")
                    Text(lengthLine)
                }
            }
        }
    }

    /// How far one suggestion runs and what it costs, from the projection
    /// the rail reads (measured on the EN+RU core, 2026-10-15).
    private var lengthLine: String {
        // One whole sentence per case, with and without the latency.
        let each = ConfigProjection.project(store.committedConfig).p50Ms.map { latencyLabel(ms: $0) }
        switch store.length {
        case .short:
            return each.map { String(localized: "2–3 words ahead, about \($0) each.") }
                ?? String(localized: "2–3 words ahead.")
        case .medium:
            return each.map { String(localized: "Up to ~6 words ahead, about \($0) each.") }
                ?? String(localized: "Up to ~6 words ahead.")
        case .long:
            return each.map { String(localized: "Up to a sentence ahead, about \($0) each.") }
                ?? String(localized: "Up to a sentence ahead.")
        }
    }
}

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
                        : String(localized: "Shapes replies and Instruct suggestions. Stays on this Mac."))
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

            AdvancedRow()
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
