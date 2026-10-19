import AppKit
import AVFoundation
import Carbon
import SwiftUI

extension Color {
    /// This tint as small TEXT, at 4.5:1 or better on a grouped form in both
    /// appearances. Light: system green, orange and teal at caption size sit
    /// near 2:1, and a 35% darkening still left them at 3.7:1 — 45% clears
    /// it. Dark: purple and blue sat at 3.7:1 untouched; a fifth of white
    /// lifts them.
    var legible: Color {
        let base = NSColor(self)
        return Color(nsColor: NSColor(name: nil) { appearance in
            var resolved = base
            appearance.performAsCurrentDrawingAppearance { resolved = base.usingColorSpace(.sRGB) ?? base }
            return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? (resolved.blended(withFraction: 0.2, of: .white) ?? resolved)
                : (resolved.blended(withFraction: 0.45, of: .black) ?? resolved)
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
                        .accessibilityHidden(true)  // the value below says it
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
