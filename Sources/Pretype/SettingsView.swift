import AppKit
import AVFoundation
import Carbon
import SwiftUI

// MARK: - Effect badges

/// A compact measured-effect chip: what a setting does to speed, quality or
/// memory. The tooltip carries the actual measurement and its source — every
/// number here comes from an eval run, never an estimate.
struct EffectBadge: View {
    enum Tone { case quality, speed, memory, caution, neutral }
    let icon: String
    let text: String
    var tone = Tone.neutral
    var source: String?

    var body: some View {
        // The capsule and the symbol carry the tone; 11pt text in the tone color
        // sits at 1.8–2.3:1 on a light form. Primary ink keeps it readable in
        // both appearances without losing the color language.
        Label { Text(text) } icon: {
            // Tone stays on the symbol (the leaf modifier wins over the outer
            // .primary), so the badge keeps the shared metric color language
            // while the 11pt text gets readable contrast.
            Image(systemName: icon).foregroundStyle(color)
        }
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(.primary)
            .background(color.opacity(0.18), in: Capsule())
            .help(source ?? text)
    }

    private var color: Color {
        switch tone {
        case .quality: return .green
        case .speed: return .blue
        case .memory: return .teal
        case .caution: return .orange
        case .neutral: return Color.gray
        }
    }
}

/// How much evidence stands behind a figure, as a strength scale rather than a
/// row of arithmetic. "n = 280" tells most people nothing — sampling error
/// shrinks with the square root of the sample, so the number is not readable at
/// a glance — while two bars against four is instantly comparable, and the
/// tolerance beside it is the part that actually changes a decision. Exact rows
/// stay one hover away.
struct SampleBadge: View {
    let samples: Int
    let marginPP: Int

    /// Bars filled, by tolerance rather than raw rows: what matters is how wide
    /// the interval is, and that depends on the rate as well as the count (a 1%
    /// cell is far tighter than a 25% one at the same size).
    private var level: Double {
        switch marginPP {
        case ...1: return 1.0
        case 2...3: return 0.72
        case 4...5: return 0.45
        default: return 0.18
        }
    }

    var body: some View {
        Label {
            Text("±\(marginPP) pp")
        } icon: {
            Image(systemName: "cellularbars", variableValue: level)
                .foregroundStyle(.secondary)
        }
        .font(.caption2.weight(.medium))
        .lineLimit(1)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(.primary)
        .background(Color.gray.opacity(0.18), in: Capsule())
        .help("\(samples) held-out samples behind this figure — the 95% interval is ±\(marginPP) points, "
            + "so two models closer than that are a tie, not a ranking.")
        .accessibilityElement()
        .accessibilityLabel("Confidence: \(samples) samples, give or take \(marginPP) points")
    }
}

/// A wrapping row of effect badges under a control.
struct BadgeRow: View {
    let badges: [EffectBadge]
    var body: some View {
        // Stacks instead of truncating when the window is narrow: several rows
        // measure 480–620 pt against a ~480 pt form at the minimum width, and
        // an ellipsized badge loses exactly the number it exists to show.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                ForEach(Array(badges.enumerated()), id: \.offset) { $0.element }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(badges.enumerated()), id: \.offset) { $0.element }
            }
        }
    }
}

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
    var fixTitle: String?
    var fix: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: met ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(met ? Color.green : Color.orange)
                .font(.caption)
                // Not just symbol + color: VoiceOver read the row the same either way.
                .accessibilityLabel(met ? "Done" : "Missing")
            Text(text)
                .font(.caption)
                .foregroundStyle(met ? Color.secondary : Color.primary)
            if !met, let fixTitle, let fix {
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

// MARK: - Root

enum SettingsTab: String, CaseIterable {
    case general = "General"
    case suggestions = "Suggestions"
    case model = "Model"
    case personalization = "Personalization"
    case api = "API"

    /// Sidebar icon.
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .suggestions: return "character.cursor.ibeam"
        case .model: return "cpu"
        case .personalization: return "person.crop.circle"
        case .api: return "cloud"
        }
    }

    /// One-line pane subtitle under the pane title.
    var subtitle: String {
        switch self {
        case .general: return "How suggestions look and where they run."
        case .suggestions: return "Tune quality, speed and precision — hover any control to preview its effect."
        case .model: return "Pick the on-device model. Everything is measured on real text."
        case .personalization: return "Teach Pretype your voice — all on your Mac."
        case .api: return "Optional: run text or dictation on a hosted model. Off by default — everything stays on your Mac."
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
                .inspector(isPresented: .constant(true)) {
                    ImpactRailView(store: store, hover: store.hoverState)
                        .inspectorColumnWidth(min: 250, ideal: 280, max: 340)
                }
        }
        .frame(minWidth: 1020, minHeight: 620)
        // On the root, not a tab: rows, cards and the map ask from Model, the
        // Style picker and "Use recommended settings" from Suggestions.
        .confirmationDialog(store.pendingDownload.map { "Download \($0.name)?" } ?? "",
                            isPresented: Binding(get: { store.pendingDownload != nil },
                                                 set: { if !$0 { store.pendingDownload = nil } }),
                            presenting: store.pendingDownload) { pending in
            Button("Download") {
                store.pendingDownload = nil
                pending.commit()
            }
            Button("Cancel", role: .cancel) { store.pendingDownload = nil }
        } message: { pending in
            Text((pending.sizeGB > 0 ? String(format: "About %.1f GB. ", pending.sizeGB) : "")
                + "Suggestions pause until it's ready.")
        }
    }

    private var sidebar: some View {
        List(selection: $store.activeTab) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                Label(tab.rawValue, systemImage: tab.symbol)
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
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("Pretype").font(.headline)
                        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                            Text("v\(v)").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    Text("System-wide AI autocomplete")
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .safeAreaInset(edge: .bottom) {
            EngineStatusFooter(controller: store.controller)
        }
    }

    private var detail: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.activeTab.rawValue)
                    .font(.title2.weight(.bold))
                Text(store.activeTab.subtitle)
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.top, 12)
            .padding(.bottom, 8)
            Group {
                switch store.activeTab {
                case .general: GeneralTab(store: store)
                case .suggestions: SuggestionsTab(store: store)
                case .model: ModelTab(store: store)
                case .personalization: PersonalTab(store: store)
                case .api: APITab(store: store)
                }
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

/// Liquid Glass. For small
/// floating layers only (chart info card and the like) — content sections
/// stay on standard backgrounds.
extension View {
    func glassCard(cornerRadius: CGFloat = 10) -> some View {
        glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
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
                    hovered = over ? option.value : (hovered == option.value ? nil : hovered)
                    hover?(option.value, over)
                }
            }
        }
        .padding(2)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
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
    @AppStorage("replyGesture") private var replyGesture = ReplyGesture.option
    @AppStorage("ghostOpacity") private var ghostOpacity = 0.7
    @AppStorage("dictationGesture") private var dictationGesture = DictationGesture.option
    @AppStorage("dictationLatch") private var dictationLatch = DictationLatch.controlOptionD  // = the registered default
    /// Silence budget for a hands-free capture, in seconds; 0 is off.
    @AppStorage("dictationSilence") private var dictationSilence = 5.0
    @AppStorage("dictationPolish") private var dictationPolish = true
    @AppStorage("dictationCommands") private var dictationCommands = false
    @AppStorage("automaticUpdateCheck") private var automaticUpdateCheck = true
    @AppStorage("clipboardContext") private var clipboardContext = false

    /// Floored like `Settings.ghostOpacity`: a value stored under the old 0.1
    /// floor must not preview fainter than the ghost actually draws.
    private var ghost: Double { max(0.4, ghostOpacity) }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    // Animate at the mutation site: the Ghost-visibility row
                    // below inserts/removes on this change, and a row cannot
                    // animate its own insertion from a Section modifier.
                    PresentationCard(mode: .panel, title: "Panel",
                                     isSelected: store.presentation == .panel,
                                     hotkeyLabel: store.hotkeyStyle.label) {
                        withAnimation(.easeInOut(duration: 0.18)) { store.presentation = .panel }
                    }
                    PresentationCard(mode: .inline, title: "Inline", badge: "Unstable",
                                     isSelected: store.presentation == .inline,
                                     hotkeyLabel: store.hotkeyStyle.label) {
                        withAnimation(.easeInOut(duration: 0.18)) { store.presentation = .inline }
                    }
                }
            } header: {
                Text("Suggestion display")
            } footer: {
                Text(store.presentation == .inline
                    ? "Ghost text continues your line right at the cursor, same size and baseline. \(store.hotkeyStyle.label) accepts. Unstable: it can leave drawing glitches in some apps — switch to Panel if you see them."
                    : "A small floating box beside the cursor shows the suggestion with a \(store.hotkeyStyle.label) hint. Never overlaps your text, and forgiving when the cursor can only be estimated.")
            }

            Section {
                Picker("Accept hotkey", selection: $store.hotkeyStyle) {
                    ForEach(HotkeyStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                // Pretype takes the fix chord on every press and the accept key
                // whenever a suggestion is up — say so where the pick is made,
                // not after the user's input-source switch stops working.
                switch store.hotkeyStyle {
                case .ctrlSpace:
                    Caption("⚠︎ ⌃Space and ⌃⌥Space are macOS's input-source switches. Pretype takes \(store.hotkeyStyle.correctionLabel) on every press and ⌃Space while a suggestion shows — pick another hotkey if you switch keyboard layouts with them.")
                case .cmdSpace:
                    Caption("⚠︎ ⌘Space is Spotlight and ⌥⌘Space a Finder search. Pretype takes \(store.hotkeyStyle.correctionLabel) on every press and ⌘Space while a suggestion shows.")
                default:
                    EmptyView()
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
                                .accessibilityValue("\(Int(ghost * 100)) percent")
                            Text("Bold").font(.caption).foregroundStyle(.secondary)
                            Text("\(Int(ghost * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 36, alignment: .trailing)
                        }
                        .frame(width: 320)
                        .help("How strongly the ghost text stands out from your own. 70% measured most readable over real app backgrounds — 45% was near-invisible.")
                    }
                }
                OverlayPreview(presentation: store.presentation,
                               opacity: ghost,
                               hotkey: store.hotkeyStyle)
            } footer: {
                Text(store.presentation == .inline
                    ? "Live preview. The ghost uses the field's own font and ink; with the cursor mid-line or near the edge it moves above the line. New users see the \(store.hotkeyStyle.label) key beside it for their first 20 accepts."
                    : "Live preview — the floating panel is a fully opaque HUD, legible on any background. It picks dark or light rendering from behind the cursor (with Screen Recording; otherwise it follows the system theme).")
            }

            Section {
                Picker(selection: $replyGesture) {
                    ForEach(ReplyGesture.allCases, id: \.self) { Text($0.label).tag($0) }
                } label: {
                    Text("Write a reply")
                    Text("Reads the conversation on screen and drafts your next message as ghost text — \(store.hotkeyStyle.label) takes a word, \(store.hotkeyStyle.shiftLabel) all of it. Tap the chosen modifier twice, or press \(store.hotkeyStyle.replyLabel).")
                }
                // Reply is on by default but reads the screen, which is off by
                // default and needs a permission — the checklist says what's
                // missing and fixes it in place, instead of the chord flashing
                // a notice at the caret.
                RequirementRow(met: store.screenContext, text: "Screen context on",
                               fixTitle: "Turn On") { store.screenContext = true }
                RequirementRow(met: ScreenContext.hasPermission,
                               text: "Screen Recording allowed (then relaunch Pretype)",
                               fixTitle: "Open System Settings…") { SettingsUI.openScreenRecordingPane() }
            }

            // Right under the reply checklist that asks for it, not on the
            // Model tab among memory settings it has nothing to do with.
            Section("Context") {
                Toggle("Use screen context (OCR)", isOn: $store.screenContext)
                BadgeRow(badges: [
                    EffectBadge(icon: "eye", text: "on-device window OCR", tone: .neutral,
                                source: "OCR of the focused app's window (the conversation above a chat box, the email being replied to) — captured locally, never leaves the Mac, never written to the journal."),
                    EffectBadge(icon: "circle.lefthalf.filled", text: "adapts to app background", tone: .neutral,
                                source: "With Screen Recording granted, the suggestion overlay samples the background under the cursor and switches to dark or light text to stay readable on any page."),
                    EffectBadge(icon: "flask", text: "accuracy gain unmeasured", tone: .neutral,
                                source: "Honest status: no eval isolates the OCR context's effect on suggestion accuracy yet."),
                ])

                Toggle("Use clipboard context", isOn: $clipboardContext)
                BadgeRow(badges: [
                    EffectBadge(icon: "doc.on.clipboard", text: "helps when replying to copied text", tone: .neutral,
                                source: "The current clipboard text (capped at 600 chars) is fed to the model as extra context — the thing being replied to is often just-copied. Read only when the clipboard changes; concealed clipboards from password managers are never read; never written to the journal or debug log."),
                    EffectBadge(icon: "flask", text: "accuracy gain unmeasured", tone: .neutral,
                                source: "Honest status: no eval isolates the clipboard context's effect on suggestion accuracy yet."),
                ])
            }

            Section("Dictation") {
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
                        Text("Talk instead of typing")
                        Text("Hold a key and say the sentence, or press a chord and say the "
                            + "paragraph — either way it is typed into the field you're already in. "
                            + "macOS transcribes it on this Mac: no audio is written to disk, nothing "
                            + "is sent anywhere, and nothing records unless you asked it to.")
                    }
                    if store.dictation {
                        Picker(selection: $dictationGesture) {
                            ForEach(DictationGesture.allCases, id: \.self) { gesture in
                                Text(gesture.label).tag(gesture)
                            }
                        } label: {
                            Text("Push-to-talk key")
                            if dictationGesture != .off {
                                Text("A hold, not a tap"
                                    + (replyGesture == .off ? "" : ", so it never collides with “\(replyGesture.label)” for a reply")
                                    + ". Recording starts after about half a second of quiet hold; any other "
                                    + "key, click or scroll before that cancels it, and esc discards one already running.")
                            }
                        }
                        if dictationGesture == .off, dictationLatch == .off {
                            Caption("⚠︎ Dictation is on but no key is assigned, so nothing can "
                                + "start a capture. Pick a key above or a hands-free chord below, "
                                + "or switch the feature off.")
                        }
                        Picker(selection: $dictationLatch) {
                            ForEach(DictationLatch.allCases, id: \.self) { latch in
                                Text(latch.label).tag(latch)
                            }
                        } label: {
                            Text("Hands-free chord")
                            if dictationLatch != .off {
                                Text("Press it once to start, once more to stop — nothing to hold, so "
                                    + "you can scroll, click and think mid-sentence without losing the "
                                    + "capture. It also starts recording on the keypress itself rather "
                                    + "than half a second later, because nothing else on the system means "
                                    + "this chord. ⎋ still throws the capture away, and moving to another "
                                    + "field ends it.")
                            }
                        }
                        if dictationLatch != .off {
                            if dictationLatch.collidesWithFixChord {
                                Caption("⚠︎ \(dictationLatch.label) is already the \(store.hotkeyStyle.correctionLabel) fix's chord "
                                    + "under your “\(store.hotkeyStyle.label)” hotkey, and the fix wins. "
                                    + "Pick the other chord, or change the accept hotkey above.")
                            }
                            Picker(selection: $dictationSilence) {
                                Text("Never").tag(0.0)
                                Text("3 seconds").tag(3.0)
                                Text("5 seconds").tag(5.0)
                                Text("10 seconds").tag(10.0)
                            } label: {
                                Text("Stop after silence")
                                Text(dictationSilence == 0
                                    ? "A hands-free capture runs until you press the chord again — or for "
                                        + "ten minutes, whichever comes first."
                                    : "A hands-free capture that hears nothing for this long types what it "
                                        + "has and stops, so a forgotten chord isn't an open microphone. "
                                        + "The clock only starts once you've said something: pausing before "
                                        + "the first word gives you half a minute.")
                            }
                        }
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
                                ? "Automatic keeps wireless earbuds out of call mode. A headset carries "
                                    + "either good playback or a two-way call, never both — so the moment "
                                    + "anything opens its microphone, whatever you're listening to drops "
                                    + "to mono and goes quiet. When your default input and output are the "
                                    + "same headset, dictation records from the built-in microphone "
                                    + "instead and your audio never changes."
                                : "Dictation records from this device. Note that recording from a "
                                    + "wireless headset switches it into call mode for the length of the "
                                    + "capture, which makes anything playing sound flat and quiet.")
                        }
                        if let note = store.dictationInputNote {
                            Caption("✓ \(note)")
                        }
                        Picker(selection: $store.dictationLanguage) {
                            Text("Follow keyboard").tag("auto")
                            Divider()
                            ForEach(store.dictationLocales, id: \.identifier) { locale in
                                Text(Locale.current.localizedString(forIdentifier: locale.identifier)
                                    ?? locale.identifier)
                                    .tag(locale.identifier)
                            }
                        } label: {
                            Text("Language")
                            Text(store.dictationLanguage == "auto"
                                ? "Whichever keyboard layout is active when you press the key — right now "
                                    + "that resolves to \(store.dictationLanguageName). Switching keyboard "
                                    + "switches dictation language, which is a thing you already do to type."
                                : "Pinned. Dictation always listens for this language, whatever the keyboard "
                                    + "is set to.")
                        }
                        // Which model — and, for the languages macOS simply
                        // cannot dictate, saying so HERE instead of letting the
                        // user find out by holding a key and getting nothing.
                        switch store.dictationSupport {
                        case .preferred:
                            Caption("\(store.dictationLanguageName): uses Apple's newer speech model — "
                                + "the more accurate of the two, with its own punctuation. macOS "
                                + "downloads it the first time you speak this language.")
                        case .fallback:
                            Caption("\(store.dictationLanguageName): Apple's newer speech model covers only "
                                + "30 locales and this isn't one of them, so dictation uses the system "
                                + "dictation model instead — the same one macOS's own dictation key uses. "
                                + "It is a little rougher, which is what “Tidy up” below is for.")
                        case .parakeet:
                            Caption("\(store.dictationLanguageName): dictated with Parakeet, on this Mac's "
                                + "Neural Engine.")
                        case .api:
                            Caption("Dictated by \(store.apiAudio.preset.name) (\(store.apiAudio.model)) — "
                                + "see Settings → API.")
                        case .unsupported:
                            Caption("⚠︎ macOS has no speech model for \(store.dictationLanguageName) at all. "
                                + "Pick a language it can dictate, or switch keyboard layout before "
                                + "holding the key.")
                        case nil:
                            EmptyView()
                        }
                        if [.fallback, .parakeet].contains(store.dictationSupport),
                           Parakeet.covers(Settings.resolvedDictationLocale) {
                            Toggle(isOn: $store.dictationParakeet) {
                                Text("Use Parakeet for \(store.dictationLanguageName)")
                                Text("NVIDIA's open speech model, run locally, for the languages Apple's "
                                    + "newer model skips. On Russian it makes under half the word errors of the "
                                    + "system model and writes its own punctuation (F1 0.87 against 0.02), "
                                    + "three times faster. A one-time ~610 MB download.")
                            }
                            if let note = store.parakeetNote {
                                Caption(note)
                            }
                        }
                        Toggle(isOn: $dictationPolish) {
                            Text("Tidy up with the model")
                            Text("Runs the transcript through the same minimal-edit fix \(store.hotkeyStyle.correctionLabel) uses on a "
                                + "selection — capitalization, punctuation, obvious mishearings — and "
                                + "rejects the result outright if the model starts rephrasing instead. "
                                + "Costs one short generation before the text lands; off types exactly "
                                + "what was heard. On models that fix with a separate instruct sibling, "
                                + "the first use downloads it — dictations land as heard rather than "
                                + "waiting for that, and the tidy-up starts once it has finished.")
                        }
                        Toggle(isOn: $dictationCommands) {
                            Text("Voice commands on selected text")
                            Text("With text selected, what you say is an instruction for it instead of "
                                + "words to type — \u{201C}make this shorter\u{201D}, \u{201C}more formal\u{201D}, "
                                + "\u{201C}translate to English\u{201D}. The rewrite is previewed like a "
                                + "\(store.hotkeyStyle.correctionLabel) fix: ⏎ applies it over the selection, "
                                + "⎋ keeps the original. Off, dictating over a selection replaces it.")
                        }
                    }
                }
            }
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
            // Under "Follow keyboard" both the caption's "right now that
            // resolves to X" and the speech-model badge depend on the layout
            // that is selected system-wide — and the user switches it from the
            // menu bar or ⌃Space, outside our process, so no state we own
            // changes. Carbon's distributed notification is the only signal
            // that crosses the process boundary; re-resolving on it keeps both
            // lines honest while the pane stays open. It is scoped to the
            // section, so it costs nothing on the other tabs.
            .onReceive(DistributedNotificationCenter.default().publisher(
                for: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String))) { _ in
                store.refreshDictationLanguage()
            }

            Section {
                if store.blacklist.isEmpty {
                    Caption("Suggestions currently run everywhere except password managers, which are always excluded, and terminals, where they run only in an AI agent's prompt. Add apps where Pretype should stay silent.")
                }
                ForEach(store.blacklist, id: \.self) { entry in
                    BlacklistRow(entry: entry) { store.removeBlacklistEntry(entry) }
                }
                HStack(spacing: 10) {
                    Button {
                        store.addBlacklistApp()
                    } label: {
                        Label("Add App…", systemImage: "plus")
                    }
                    .controlSize(.small)
                    TextField("", text: $blacklistDraft,
                              prompt: Text("or part of a bundle ID (e.g. slack) — ⏎ adds"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .onSubmit {
                            store.addBlacklistEntry(blacklistDraft)
                            blacklistDraft = ""
                        }
                }
            } header: {
                Text("Turned off in these apps")
            } footer: {
                Text("Matched against the app's bundle ID, so a fragment like “slack” covers Slack everywhere.")
            }

            Section("Startup") {
                // Bound to launchd, not to a stored bool: the same switch lives
                // in System Settings → Login Items, and mirroring it in
                // UserDefaults would eventually show a state that isn't real.
                Toggle(isOn: Binding(
                    get: { LoginItem.isOn(store.loginStatus) },
                    set: { store.setOpenAtLogin($0) }
                )) {
                    Text("Open at login")
                    Text("Pretype starts with your Mac and waits in the menu bar — no Dock icon, no window. "
                        + "macOS owns this switch: it also lives in System Settings → General → Login Items, "
                        + "and flipping it there flips it here.")
                }
                .disabled(!LoginItem.isSupported)
                // The same switch lives in System Settings, and `sync()` only
                // runs when the window is (re)presented — catch the user coming
                // back from flipping it there, or the caption's "flipping it
                // there flips it here" only holds across window reopens.
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification)) { _ in
                    store.loginStatus = LoginItem.status
                }
                if let note = LoginItem.note(store.loginStatus) {
                    Caption(note)
                }
            }

            Section("Updates") {
                Toggle(isOn: $automaticUpdateCheck) {
                    Text("Check for updates automatically")
                    Text("Asks GitHub once a day whether a newer release exists — the only request Pretype makes on its own, and it sends nothing about you. New versions are announced in the menu bar and installed by you; nothing is downloaded or replaced automatically. Off still leaves “Check for Updates…” in the menu.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// One blacklisted app: icon + display name resolved from the stored bundle-ID
/// fragment where possible, with a remove button — the System Settings
/// app-exceptions look instead of a raw comma-separated field.
private struct BlacklistRow: View {
    let entry: String
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
            removeButton("Stop excluding \(resolved.name)", help: "Allow Pretype in this app again", action: remove)
        }
    }
}

/// A list row's trailing minus. The label names the row: .help is a hint, not
/// a name — without it every row's remove button announces identically.
@MainActor private func removeButton(_ label: String, help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
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
        return (host, NSImage(systemSymbolName: "globe", accessibilityDescription: "Website"))
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
                Button { store.shareStyle(bundleID, name: resolved.name) } label: {
                    Image(systemName: "square.and.arrow.up").foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Share the style for \(resolved.name)")
                .help("Share this style with other Pretype users")
            }
            removeButton("Remove instructions for \(resolved.name)", help: "Remove this app's instructions") {
                store.perAppInstructions.removeValue(forKey: bundleID)
            }
        }
    }
}

/// Live preview of the overlay exactly as configured — the current presentation
/// mode, ghost opacity and hotkey — over a light AND a dark host background,
/// mirroring the background-probe behavior at the caret.
struct OverlayPreview: View {
    let presentation: SuggestionPresentation
    let opacity: Double
    let hotkey: HotkeyStyle

    var body: some View {
        HStack(spacing: 1) {
            half(light: true)
            half(light: false)
        }
        .frame(height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }

    private func half(light: Bool) -> some View {
        ZStack(alignment: .leading) {
            (light ? Color.white : Color(white: 0.09))
            line(light: light).padding(.horizontal, 14)
        }
        // Each half is its own appearance, so the keycaps' semantic colours
        // resolve against the page they sit on, not the Settings window.
        .environment(\.colorScheme, light ? .light : .dark)
    }

    private func line(light: Bool) -> some View {
        let ink: Color = light ? .black : .white
        // The slider dims inline ghost text; the panel pill is an opaque HUD and
        // stays full-strength, so the preview must not move it either — else it
        // promises an effect the real panel never applies.
        let effective = presentation == .inline ? opacity : 1.0
        // Same split the real ghost draws with (SuggestionWindow.suggestionGhost):
        // the ⇥ chunk at full strength, the tail at 0.72 — a preview that dimmed
        // differently promised a look the caret never delivered.
        let head = ink.opacity(1.0 * effective)
        let tail = ink.opacity(0.72 * effective)
        return Group {
            if presentation == .inline {
                // The ghost, then the accept keycap a new user sees beside it.
                HStack(spacing: 6) {
                    Text("\(Text("Write ").foregroundColor(ink))\(Text("a reply").foregroundColor(head))\(Text(" to Anna").foregroundColor(tail))")
                    MenuHintsView.keycap(hotkey.label)
                        .opacity(min(1, effective / 0.7))
                }
            } else {
                // The pill floats just ABOVE the line, starting at the caret —
                // where the real one sits — never beside the typed words.
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 0) {
                        Text("Write ").hidden()
                        HStack(spacing: 6) {
                            Text("\(Text("a reply").foregroundColor(ink))\(Text(" to Anna").foregroundColor(ink.opacity(0.55)))")
                            MenuHintsView.keycap(hotkey.label)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(ink.opacity(0.07), in: Capsule())
                        .overlay(Capsule().stroke(ink.opacity(0.15), lineWidth: 0.5))
                    }
                    Text("Write ").foregroundColor(ink)
                }
            }
        }
        .font(.system(size: 13))
        .lineLimit(1)
        // One description for VoiceOver instead of the sample sentence read
        // word by word (and twice, once per half).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation == .inline
            ? "Preview: grey suggestion text continues the line after the cursor"
            : "Preview: the suggestion floats in a small box above the line")
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
    /// The chosen accept key, shown in the panel mockup's hint pill so it
    /// matches the live overlay instead of a hardcoded ⇥.
    var hotkeyLabel: String = "Tab"
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
                    previewLine.padding(.horizontal, 10)
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

    @ViewBuilder private var previewLine: some View {
        if mode == .inline {
            Text("\(Text("Write ").foregroundColor(.primary))\(Text("a reply").foregroundColor(.secondary))")
                .font(.system(size: 13))
        } else {
            // Above the line, from the caret — where the real pill floats.
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 0) {
                    Text("Write ").font(.system(size: 13)).hidden()
                    HStack(spacing: 4) {
                        Text("a reply").font(.system(size: 12))
                        MenuHintsView.keycap(hotkeyLabel)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.14), in: Capsule())
                }
                Text("Write ").font(.system(size: 13))
            }
        }
    }
}

// MARK: - Suggestions tab

struct SuggestionsTab: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Form {
            // Apple Intelligence runs as the macOS system model on the Neural
            // Engine: Style and the precision gate never reach it (EngineCoordinator
            // sends only length + persona), and their badges quote MLX-model figures
            // that are false for it — so those tuning sections are on-device only.
            if store.isAppleIntelligence {
                Section {
                    Caption("Apple Intelligence runs as the macOS system model on the Neural Engine — Style and the precision gate are on-device-model controls that don't apply here. Length below still shapes each suggestion; teach its voice from the Personalization tab.")
                }
            }
            if !store.isAppleIntelligence {
                Section {
                    Toggle(isOn: $store.useRecommended) {
                        Text("Use recommended settings")
                        Text(store.useRecommended
                            ? "Style and Length follow the measured-best configuration for the selected model — now \(store.recommendation.summary). Adjusting either by hand turns this off."
                            : "Style and Length are tuned by hand below. Turn on to snap back to the measured-best configuration (\(store.recommendation.summary)).")
                    }
                    .onHover { store.setHover(.useRecommended(!store.useRecommended), $0) }
                }

                Section {
                    HoverSegments(title: "Style",
                                  options: [(CompletionStyle.base, "Base"),
                                            (CompletionStyle.instruct, "Instruct")],
                                  selection: store.style,
                                  select: { style in
                                      // Base↔Instruct inserts/removes requirement
                                      // rows and swaps badge blocks in two sections.
                                      withAnimation(.easeInOut(duration: 0.18)) { store.style = style }
                                  },
                                  hover: { style, hovering in
                                      store.setHover(.style(style), hovering)
                                  })
                    if store.style == .instruct, store.instructUnusable {
                        RequirementRow(met: false,
                                       text: "Instruct is broken on \(store.selectedModelName) — it answers the text instead of continuing it (~0% first-word measured)",
                                       fixTitle: "Switch to Base") { withAnimation(.easeInOut(duration: 0.18)) { store.style = .base } }
                    }
                    BadgeRow(badges: styleBadges)
                } header: {
                    Text("Style")
                } footer: {
                    Text(store.style == .instruct
                        ? (store.instructUnusable
                            ? "Instruct only works on models with a usable instruct sibling (the Gemma tiers) — pick one in the Model pane, or use Base here."
                            : "Steers an instruct-tuned model with your persona — tone- and length-aware. Strongest on text you compose (email, chat replies).")
                        : "Plain next-word continuation of the selected model — no persona, but it can abstain instead of forcing a guess, and it unlocks the high-precision gates below.")
                }

                Section {
                    Toggle("Show only confident suggestions", isOn: $store.logprobGate)
                        .disabled(!store.logprobGateUsable)
                        .onHover { hovering in
                            guard store.logprobGateUsable else { return }
                            store.setHover(.logprobGate(!store.logprobGate), hovering)
                        }
                    if !store.logprobGateUsable {
                        RequirementRow(met: false,
                                       text: "Needs Base style — Instruct has no confidence score to filter on",
                                       fixTitle: "Switch to Base") { withAnimation(.easeInOut(duration: 0.18)) { store.style = .base } }
                    } else {
                        BadgeRow(badges: gateBadges)
                        BadgeRow(badges: [
                            EffectBadge(icon: "bolt", text: "no added latency", tone: .speed,
                                        source: "Reads the first-word log-probability the decoder already produced — zero extra generation."),
                            EffectBadge(icon: "keyboard", text: "net keystrokes: −5% → +11%", tone: .quality,
                                        source: "Typing simulation (λ=2, E2B-8bit, verified on the held-out half): ungated suggestions cost −5% net keystrokes; gated save +11% — eval-real, 2026-07-15."),
                        ])
                    }
                } header: {
                    Text("High precision")
                } footer: {
                    // A footer, not the toggle's subtitle: the toggle disables
                    // under Instruct, and the subtitle would dim with it.
                    Text("Trades coverage for precision: far fewer suggestions, far more of them right — read straight off the decoder, so it costs nothing. Off means more (but less certain) suggestions.")
                }
            }  // end on-device-only tuning sections (hidden for Apple Intelligence)

            Section {
                HoverSegments(title: "Length",
                              options: [(CompletionLength.short, "Short"),
                                        (CompletionLength.medium, "Medium"),
                                        (CompletionLength.long, "Long")],
                              selection: store.length,
                              select: { store.length = $0 },
                              hover: { length, hovering in
                                  store.setHover(.length(length), hovering)
                              })
                BadgeRow(badges: lengthBadges)
            } header: {
                Text("Length")
            } footer: {
                Text("\(store.hotkeyStyle.label) still accepts one word at a time; length caps how far a single suggestion runs ahead. Low-confidence endings are trimmed automatically, so this is a maximum, not a promise.")
            }
        }
        .formStyle(.grouped)
    }

    /// The gate's trade for the SELECTED model, from the projection the Live
    /// Impact rail reads — hard-coded calibration figures contradicted the
    /// rail beside them on every other model.
    private var gateBadges: [EffectBadge] {
        var config = store.committedConfig
        config.logprobGate = true
        let on = ConfigProjection.project(config)
        config.logprobGate = false
        let off = ConfigProjection.project(config)
        let offers = on.coveragePct.map { "offers ~\($0)% of the time" } ?? "offers less often"
        let vs = off.coveragePct.map { " (vs \($0)%)" } ?? ""
        return [
            EffectBadge(icon: "scope", text: on.accuracyPct == nil ? "not measured on this model"
                            : "\(on.accuracyText) first-word on what it shows", tone: .quality,
                        source: on.accuracySub),
            EffectBadge(icon: "hand.raised", text: offers + vs, tone: .caution,
                        source: "The other side of the trade: suggestions below the confidence bar are withheld, not shown — \(on.accuracySub)."),
        ]
    }

    private var styleBadges: [EffectBadge] {
        if store.style == .base {
            return [
                EffectBadge(icon: "checkmark.seal", text: "more accurate on real text", tone: .quality,
                            source: "First-word 33% vs 22% of shown suggestions (Base vs Instruct+persona, same E4B-6bit family), McNemar p≈0.0005 — eval-real, n=870, 2026-07-15."),
                EffectBadge(icon: "memorychip", text: "no second model", tone: .memory,
                            source: "Instruct loads a separate instruct-tuned sibling (up to ~5.6 GB on E4B); Base runs only the selected model."),
                EffectBadge(icon: "hand.raised", text: "can abstain", tone: .neutral,
                            source: "Base offers nothing on ~17% of keystrokes instead of forcing a guess (coverage 83% vs 99% for Instruct) — fewer wrong flashes."),
            ]
        }
        var badges = [
            EffectBadge(icon: "text.quote", text: "85% first-word on authored text", tone: .quality,
                        source: "eval-v2 (40 hand-authored samples) with the auto-persona: 85% first-word (EN 88 / RU 81). On real held-out text Base measures better (33% vs 22%) — pick by what you type."),
            EffectBadge(icon: "person.text.rectangle", text: "persona steering", tone: .neutral,
                        source: "Follows your persona text; the persona lifts Instruct from 66% to 85–88% first-word on eval-v2."),
            EffectBadge(icon: "memorychip", text: "loads an instruct sibling", tone: .memory,
                        source: "Runs the instruct-tuned sibling of the selected model (~5.6 GB it-6bit on the E4B tiers, ~3–4.6 GB on smaller tiers)."),
        ]
        if store.instructUnusable {
            badges.insert(EffectBadge(icon: "exclamationmark.triangle", text: "broken on this model", tone: .caution,
                                      source: "\(store.selectedModelName) answers the text instead of continuing it in Instruct style (~0% first-word measured) — use Base."), at: 0)
        }
        return badges
    }

    private var lengthBadges: [EffectBadge] {
        // Length sweep (eval-real, 2026-07-13): p50 157 / 291 / 550 ms on the
        // sweep model; first-word length-independent, word-F1 drops. Figures
        // shown are the sweep's ratios (`latencyFactor`) applied to the SELECTED
        // model's measured base latency — quoting the sweep model's absolute
        // milliseconds next to a rail that shows this model's contradicts it.
        // The reach badge states what longer BUYS — without it the control
        // reads as pure degradation on the measured axes.
        let baseMs = ModelMetrics.metrics(for: store.modelID)?.p50Ms
        func ms(_ length: CompletionLength) -> String {
            guard let baseMs else { return "" }
            let v = Int((Double(baseMs) * ConfigProjection.latencyFactor(length)).rounded())
            return v >= 1000 ? String(format: "%.1f s", Double(v) / 1000) : "\(v) ms"
        }
        // The ratios come from the projection's own table, so a re-measured
        // sweep can't leave these strings quoting the old one.
        func ratio(_ length: CompletionLength) -> String {
            String(format: "%g", (ConfigProjection.latencyFactor(length) * 10).rounded() / 10)
        }
        let sweepSource = "Measured length sweep (eval-real, 2026-07-13): 157 · 291 · 550 ms p50 on the sweep model — "
            + (baseMs != nil
                ? "the ×\(ratio(.medium))/×\(ratio(.long)) ratios here are applied to \(store.selectedModelName)'s measured base latency."
                : "no measured base latency for this model, so only the ratios are shown.")
        let reach: EffectBadge
        let speed: EffectBadge
        switch store.length {
        case .short:
            reach = EffectBadge(icon: "text.word.spacing", text: "runs 2–3 words ahead", tone: .neutral,
                                source: "How far one suggestion runs. Short is the sweep's best net-value point for inline ghost text — same accuracy as longer settings at a fraction of the wait.")
            speed = EffectBadge(icon: "bolt",
                                text: baseMs != nil ? "fastest — p50 ~\(ms(.short))" : "fastest",
                                tone: .speed, source: sweepSource)
        case .medium:
            reach = EffectBadge(icon: "text.word.spacing", text: "runs up to ~6 words ahead", tone: .neutral,
                                source: "What longer buys: more words per suggestion (+1–2 pp completeness in the sweep). Per-word accuracy does not improve — you pay only in wait time.")
            speed = EffectBadge(icon: "bolt",
                                text: baseMs != nil ? "p50 ~\(ms(.medium)) (≈\(ratio(.medium))× short)" : "≈\(ratio(.medium))× slower than short",
                                tone: .caution, source: sweepSource)
        case .long:
            reach = EffectBadge(icon: "text.word.spacing", text: "runs up to a sentence ahead", tone: .neutral,
                                source: "What longer buys: more words per suggestion (+1–2 pp completeness in the sweep). Per-word accuracy does not improve, and weak tails are trimmed automatically.")
            speed = EffectBadge(icon: "tortoise",
                                text: baseMs != nil ? "p50 ~\(ms(.long)) (≈\(ratio(.long))× short)" : "≈\(ratio(.long))× slower than short",
                                tone: .caution, source: sweepSource)
        }
        return [
            reach,
            speed,
            EffectBadge(icon: "scope", text: "accuracy unchanged", tone: .quality,
                        source: "First-word accuracy is length-independent in the sweep; longer buys ~1–2 pp completeness but loses word-F1 — speed is the real trade-off."),
        ]
    }

}

// MARK: - Personalization tab

struct PersonalTab: View {
    @Bindable var store: SettingsStore
    /// Both journal paths destroy the learned n-gram model irreversibly, so
    /// they route through one confirmation instead of firing on a single click.
    @State private var confirmingClear = false
    @State private var clearDisablesJournal = false

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
                        ? "Auto-filled from your account name and keyboard languages — the primary voice control for Apple Intelligence, passed as its system instructions. It stays on your Mac."
                        : "Auto-filled from your account name and keyboard languages — shapes reply drafts always, completions in Instruct style. It stays on your Mac.")
                    Spacer()
                    Button("Restore Default") { store.resetInstructions() }
                        .controlSize(.small)
                }
                if !store.isAppleIntelligence {
                    BadgeRow(badges: [
                        EffectBadge(icon: "scope", text: "66% → 85–88% first-word (Instruct)", tone: .quality,
                                    source: "Measured on eval-v2: Instruct without a persona 66% first-word; with the auto-persona 85%; with a hand-tuned one 88%."),
                    ])
                }
            }

            Section {
                if store.perAppInstructions.isEmpty {
                    Caption("The persona above applies everywhere. Add an app to append extra style lines only there — formal in Mail, casual and short in Slack.")
                }
                ForEach(store.perAppInstructions.keys.sorted(), id: \.self) { bundleID in
                    PerAppInstructionRow(bundleID: bundleID, store: store)
                }
                let suggestions = store.perAppSuggestions
                HStack(spacing: 10) {
                    if !suggestions.isEmpty {
                        Button {
                            store.addSuggestedPerAppInstructions()
                        } label: {
                            Label("Fill In Suggested", systemImage: "sparkles")
                        }
                        .controlSize(.small)
                    }
                    Button {
                        store.addPerAppInstructionApp()
                    } label: {
                        Label("Add App…", systemImage: "plus")
                    }
                    .controlSize(.small)
                    Button {
                        store.addPerSiteInstruction()
                    } label: {
                        Label("Add Website…", systemImage: "globe")
                    }
                    .controlSize(.small)
                }
                if !suggestions.isEmpty {
                    Caption("Suggested fills in ready-made styles for the apps found on this Mac — "
                        + suggestions.map { resolveApp($0.bundleID).name }.joined(separator: ", ")
                        + ". Every line stays editable: tweak or remove whatever doesn't fit.")
                }
            } header: {
                Text("Per-app style")
            } footer: {
                Text(store.isAppleIntelligence
                    ? "Appended to your persona while typing in that app — steers the system model's voice, like the persona itself."
                    : "Appended to your persona while typing in that app — shapes reply drafts always, completions in Instruct style.")
            }

            // The n-gram boost never reaches Apple Intelligence (FoundationModelsEngine
            // takes the no-op updatePersonalization — it has no logits to boost), so
            // learning would collect words it can never apply. On-device models only.
            if !store.isAppleIntelligence {
                Section("Learning") {
                    Picker("Learn my words", selection: $store.personalization) {
                        ForEach(PersonalizationLevel.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    BadgeRow(badges: [
                        EffectBadge(icon: "flask", text: "no measured gain yet", tone: .neutral,
                                    source: "Boost = level × ln(1 + times you typed this word after this context, capped), applied to the first token. A first time-split replay leaned its way (3/0, p=0.25, n=54); the 2026-07-20 re-measure on a larger replay (n=64, β 0.6 and 1.2) found zero changed outcomes — the bias only fires at clean word boundaries. The old context-free favored-word bias measured null (p=1.0) and was removed. Collected only while on; nothing leaves your Mac."),
                    ])
                    HStack {
                        Caption("Boosts the words you habitually type next — learned from your suggestion journal. Clear the journal to forget them.")
                        Spacer()
                        Text(store.learnedWords > 0 ? "\(store.learnedWords) words" : "nothing learned yet")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }  // end Learning (hidden for Apple Intelligence)

            Section("Journal") {
                Toggle("Keep suggestion journal", isOn: Binding(
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
                ))
                HStack {
                    Caption("Records each suggestion with a snippet of the surrounding text you typed — the raw data for personalization and quality tuning. Stays on this Mac in Application Support (capped at 50 MB); on-screen OCR text is never written. Turning this off also deletes the stored journal.")
                    Spacer()
                    Button(store.journalBytes > 0
                        ? "Clear (\(ByteCountFormatter.string(fromByteCount: Int64(store.journalBytes), countStyle: .file)))"
                        : "Empty") {
                        clearDisablesJournal = false
                        confirmingClear = true
                    }
                    .controlSize(.small)
                    .disabled(store.journalBytes == 0)
                }
                HStack {
                    Caption(store.journalEnabled
                        ? "The journal only grows while you type, which is why personalization is still thin. Import .txt or .md files you wrote and Pretype learns your words and reuses your own sentences as prompt examples — the files are only read, and Clear above forgets imported text too."
                        : "Importing writes into the journal — turn “Keep suggestion journal” on first.")
                    Spacer()
                    Button {
                        store.importTextFiles()
                    } label: {
                        Label("Import Text…", systemImage: "text.book.closed")
                    }
                    .controlSize(.small)
                    .disabled(!store.journalEnabled || store.importing)
                }
                if let status = store.importStatus {
                    Caption(status)
                }
                // The journal itself still records (retention is the toggle above),
                // but its few-shot reuse never reaches Apple Intelligence — FM's
                // complete() ignores personalExamples — so the "reused as examples"
                // rows and the measured-win badges are on-device-only.
                if !store.isAppleIntelligence {
                    LabeledContent("Accepted phrases") {
                        Text("reused as prompt examples — automatic")
                    }
                    BadgeRow(badges: [
                        EffectBadge(icon: "checkmark.seal", text: "measured win on Instruct style", tone: .quality,
                                    source: "Few-shot from your own accepted phrases: first-word 4% → 10% on the journal replay, all 7 discordant samples in its favor, exact p=0.016 (Instruct path)."),
                        EffectBadge(icon: "checkmark.seal", text: "measured win on Base style", tone: .quality,
                                    source: "Journal replay (n=158, base, gates off): first-word of all 25% → 49% on MiniCPM5-1B and 37% → 51% on Gemma E2B 8-bit, both p<0.001. Replay rewards your own repetitiveness, so expect a smaller live win."),
                        EffectBadge(icon: "clock", text: "+20–190 ms to the first suggestion", tone: .caution,
                                    source: "The examples lengthen the prompt: p50 93 → 115 ms on MiniCPM5-1B, 207 → 399 ms on Gemma E2B (the few-shot block about doubles its prefill)."),
                    ])
                    Caption("A measured win on both styles, so it's always on. Clear the journal above to forget the phrases.")
                }  // end few-shot rows (hidden for Apple Intelligence)
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
            Text(store.learnedWords > 0
                 ? "This also forgets the \(store.learnedWords) words Pretype learned from you. It can't be undone."
                 : "This can't be undone.")
        }
    }
}
