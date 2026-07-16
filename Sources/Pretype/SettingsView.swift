import AppKit
import SwiftUI

// MARK: - Store

/// Observable bridge between the SwiftUI settings surface and the live
/// pipeline. Every mutation forwards to the same `SuggestionController` entry
/// points the old AppKit panel used; `sync()` re-reads Settings after any
/// change that cascades (model → recommended style/length → gates).
@MainActor
final class SettingsStore: ObservableObject {
    weak var controller: SuggestionController?
    private var syncing = false
    private var statusTimer: Timer?

    init(controller: SuggestionController?) {
        self.controller = controller
        sync()
    }

    // MARK: Published mirrors of Settings

    @Published var enabled = true {
        didSet { guard !syncing else { return }
            Settings.enabled = enabled
            if !enabled { controller?.dismiss() } }
    }
    @Published var presentation = SuggestionPresentation.inline {
        didSet { guard !syncing, oldValue != presentation else { return }
            controller?.setSuggestionPresentation(presentation) }
    }
    @Published var hotkeyStyle = HotkeyStyle.tab {
        didSet { guard !syncing, oldValue != hotkeyStyle else { return }
            Settings.hotkeyStyle = hotkeyStyle
            controller?.dismiss() }
    }
    @Published var ghostOpacity = 0.7 {
        didSet { guard !syncing else { return }
            Settings.ghostOpacity = ghostOpacity }
    }
    @Published var blacklist: [String] = [] {
        didSet { guard !syncing, oldValue != blacklist else { return }
            Settings.userBlacklist = blacklist
            controller?.dismiss() }
    }
    @Published var useRecommended = true {
        didSet { guard !syncing, oldValue != useRecommended else { return }
            Settings.useRecommendedSettings = useRecommended
            if useRecommended { controller?.applyRecommendedSettings() }
            resync() }
    }
    @Published var style = CompletionStyle.instruct {
        didSet { guard !syncing, oldValue != style else { return }
            unlockManualTuning()
            controller?.setCompletionStyle(style)
            resync() }
    }
    @Published var length = CompletionLength.short {
        didSet { guard !syncing, oldValue != length else { return }
            unlockManualTuning()
            controller?.setCompletionLength(length) }
    }
    @Published var confidenceGate = false {
        didSet { guard !syncing, oldValue != confidenceGate else { return }
            controller?.setConfidenceGate(confidenceGate)
            resync() }
    }
    @Published var logprobGate = false {
        didSet { guard !syncing, oldValue != logprobGate else { return }
            controller?.setLogprobGate(logprobGate)
            resync() }
    }
    @Published var confidenceTrim = true {
        didSet { guard !syncing else { return }
            Settings.confidenceTrim = confidenceTrim }
    }
    @Published var personalization = PersonalizationLevel.off {
        didSet { guard !syncing, oldValue != personalization else { return }
            controller?.setPersonalization(personalization)
            // Enabling mid-session must start the journal build right away —
            // otherwise live learning stays inert until the next keystroke.
            if personalization != .off { PersonalNgram.shared.prepareIfNeeded() }
            learnedWords = PersonalNgram.shared.wordCount }
    }
    @Published var journalEnabled = true {
        didSet { guard !syncing else { return }
            Settings.suggestionJournalEnabled = journalEnabled }
    }
    @Published var examplesEnabled = true {
        didSet { guard !syncing else { return }
            Settings.personalExamplesEnabled = examplesEnabled }
    }
    @Published var instructions = "" {
        didSet { guard !syncing, oldValue != instructions else { return }
            controller?.setCustomInstructions(instructions) }
    }
    @Published var fmVariant = FMPromptVariant.fewshot {
        didSet { guard !syncing, oldValue != fmVariant else { return }
            controller?.setFMPromptVariant(fmVariant) }
    }
    @Published var idleUnloadMinutes = 5 {
        didSet { guard !syncing else { return }
            Settings.idleUnloadMinutes = idleUnloadMinutes }
    }
    @Published var fimEnabled = true {
        didSet { guard !syncing else { return }
            Settings.fimEnabled = fimEnabled }
    }
    @Published var screenContext = false {
        didSet { guard !syncing, oldValue != screenContext else { return }
            SettingsUI.setScreenContext(screenContext) }
    }

    /// Selection flows through `selectModel`, not a binding didSet.
    @Published var modelID = ModelCatalog.defaultID

    /// Pane selected in the sidebar.
    @Published var activeTab = SettingsTab.general {
        didSet { preview = nil }
    }

    /// Control being hovered right now — the Live Impact rail, the delta
    /// strips and the model map preview its effect before anything commits.
    @Published var preview: ProjectionConfig.Change?

    func setHover(_ change: ProjectionConfig.Change, _ hovering: Bool) {
        if hovering { preview = change }
        else if preview == change { preview = nil }
    }

    /// Adjusting Style or Length by hand takes the pipeline out of "auto" —
    /// the controls stay live instead of reading as broken while auto is on.
    private func unlockManualTuning() {
        guard useRecommended else { return }
        syncing = true
        useRecommended = false
        syncing = false
        Settings.useRecommendedSettings = false
    }

    @Published var statusText = ""
    @Published var statusColor = Color.secondary
    @Published var learnedWords = 0
    @Published var journalBytes = 0

    // MARK: Derived

    var recommendation: ModelCatalog.Recommendation { ModelCatalog.recommended(for: modelID) }
    var confidenceGateUsable: Bool { style == .base && recommendation.gateCapable }
    var logprobGateUsable: Bool { style == .base }
    /// Models whose recommended style is base run instruct as "answer the text"
    /// (~0% first-word measured) — warn if the user forces it.
    var instructUnusable: Bool { recommendation.style == .base }
    var isAppleIntelligence: Bool { modelID == ModelCatalog.appleIntelligenceID }
    var selectedModelName: String {
        ModelCatalog.option(for: modelID)?.title ?? (modelID as NSString).lastPathComponent
    }
    var selectedRamGB: Double {
        ModelMetrics.metrics(for: modelID)?.ramGB
            ?? Double(ModelCatalog.option(for: modelID)?.approxSizeMB ?? 0) / 1000
    }

    // MARK: Live projection — measured expectations for the current configuration

    /// The committed configuration as a pure value, for `ConfigProjection`.
    var committedConfig: ProjectionConfig {
        ProjectionConfig(modelID: modelID, style: style, length: length,
                         logprobGate: logprobGate, confidenceGate: confidenceGate,
                         useRecommended: useRecommended)
    }
    /// What the committed configuration measures to.
    var projection: ConfigProjection { .project(committedConfig) }
    /// The hovered change applied to the committed config, cascades included.
    var previewedConfig: ProjectionConfig? {
        preview.map(committedConfig.applying)
    }
    /// What the hovered change would measure to.
    var previewedProjection: ConfigProjection? {
        previewedConfig.map(ConfigProjection.project)
    }
    /// Differences hovered − committed, for the delta chips.
    var previewDeltas: [ConfigProjection.MetricDelta] {
        guard let target = previewedProjection else { return [] }
        return ConfigProjection.deltas(from: projection, to: target)
    }

    /// "MiniCPM5 1B · Base · Short · Confidence gate" — what is running now.
    var setupLine: String {
        var parts = [ModelMetrics.metrics(for: modelID)?.shortName ?? selectedModelName]
        if !isAppleIntelligence { parts.append(style == .instruct ? "Instruct" : "Base") }
        parts.append(length.rawValue.capitalized)
        if logprobGate { parts.append("Confident-only") }
        if confidenceGate { parts.append("Consensus ×5") }
        return parts.joined(separator: " · ")
    }

    // MARK: Actions

    func selectModel(_ id: String) {
        guard id != modelID else { return }
        modelID = id
        controller?.setModel(id)
        resync()
    }

    /// Commit an exact configuration in one shot (presets and map dots land
    /// here): one coordinator call, one engine rebuild — replaying it through
    /// the per-field didSets would rebuild the engine per field.
    func applyConfig(_ target: ProjectionConfig) {
        guard target != committedConfig else { return }
        controller?.applyConfig(target)
        resync()
    }

    /// One-click priority preset: the measured-best model for the goal, in
    /// the exact configuration its card figures come from (Base · Short),
    /// keeping the precision gates where the model supports them.
    func applyPriority(_ priority: ModelPriority) {
        applyConfig(committedConfig.applying(.preset(priority.pick)))
    }

    /// A preset reads as active when the pipeline sits exactly where clicking
    /// it would land (gates are preserved by presets, so they don't count).
    func priorityIsActive(_ priority: ModelPriority) -> Bool {
        modelID == priority.pick && style == .base && length == .short
    }

    /// Add an app to the blacklist via the standard app-picker panel; stores
    /// the lowercased bundle ID (AppPolicy matches by substring of it).
    func addBlacklistApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Disable Pretype Here"
        panel.message = "Choose applications where Pretype should stay silent."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let entry = (Bundle(url: url)?.bundleIdentifier ?? url.deletingPathExtension().lastPathComponent)
                .lowercased()
            addBlacklistEntry(entry)
        }
    }

    func addBlacklistEntry(_ raw: String) {
        let entry = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !entry.isEmpty, !blacklist.contains(entry) else { return }
        blacklist.append(entry)
    }

    func removeBlacklistEntry(_ entry: String) {
        blacklist.removeAll { $0 == entry }
    }

    func chooseFineTunedModel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Model"
        panel.message = "Choose a fused fine-tuned model folder (with config.json + safetensors)."
        if panel.runModal() == .OK, let url = panel.url {
            selectModel(url.path)
        }
    }

    func clearJournal() {
        SuggestionJournal.shared.reset()
        // The n-gram model is derived from the journal — clearing one clears both.
        PersonalNgram.shared.reset()
        journalBytes = 0
        learnedWords = 0
    }

    func resetInstructions() {
        instructions = Settings.defaultInstructions
    }

    // MARK: Sync

    func sync() {
        syncing = true
        // Model first — recommendation-derived masks below read it.
        modelID = Settings.mlxModelID
        enabled = Settings.enabled
        presentation = Settings.suggestionPresentation
        hotkeyStyle = Settings.hotkeyStyle
        ghostOpacity = Settings.ghostOpacity
        blacklist = Settings.userBlacklist
        useRecommended = Settings.useRecommendedSettings
        style = Settings.completionStyle
        length = Settings.completionLength  // .word migrated away in registerDefaults
        // Mask inapplicable persisted flags (same pattern as fimEnabled): a
        // gate restored from a state the coordinator's hygiene never saw must
        // not render as on-but-doing-nothing.
        confidenceGate = Settings.confidenceGate && style == .base && recommendation.gateCapable
        logprobGate = Settings.logprobGate && style == .base
        confidenceTrim = Settings.confidenceTrim
        personalization = Settings.personalizationLevel
        journalEnabled = Settings.suggestionJournalEnabled
        examplesEnabled = Settings.personalExamplesEnabled
        instructions = Settings.customInstructions
        fmVariant = Settings.fmPromptVariant
        idleUnloadMinutes = Settings.idleUnloadMinutes
        fimEnabled = Settings.fimEnabled && recommendation.fim
        screenContext = Settings.screenContextEnabled
        learnedWords = PersonalNgram.shared.wordCount
        journalBytes = SuggestionJournal.shared.fileSize
        syncing = false
        preview = nil  // committed state changed — it is the new baseline
        refreshStatus()
    }

    /// Cascading changes (model → style/length → gates) land in Settings after
    /// the controller call; re-read them outside the current view update.
    private func resync() {
        DispatchQueue.main.async { [weak self] in self?.sync() }
    }

    func startStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
    }

    func stopStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = nil
    }

    private func refreshStatus() {
        guard let engine = controller?.engine else {
            statusText = ""
            return
        }
        switch engine.state {
        case .ready:
            statusText = "\(engine.name) — ready"
            statusColor = .green
        case .preparing(let detail):
            statusText = "\(engine.name) — \(detail)"
            statusColor = .orange
        case .failed(let detail):
            statusText = "\(engine.name) — \(detail)"
            statusColor = .red
        }
    }
}

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
        Label(text, systemImage: icon)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.13), in: Capsule())
            .help(source ?? text)
    }

    private var color: Color {
        switch tone {
        case .quality: return .green
        case .speed: return .blue
        case .memory: return .purple
        case .caution: return .orange
        case .neutral: return Color.gray
        }
    }
}

/// A wrapping row of effect badges under a control.
struct BadgeRow: View {
    let badges: [EffectBadge]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(badges.enumerated()), id: \.offset) { $0.element }
            Spacer(minLength: 0)
        }
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
            Text(text)
                .font(.caption)
                .foregroundStyle(met ? Color.secondary : Color.primary)
            if !met, let fixTitle, let fix {
                Button(fixTitle, action: fix)
                    .controlSize(.mini)
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

    /// Sidebar icon.
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .suggestions: return "character.cursor.ibeam"
        case .model: return "cpu"
        case .personalization: return "person.crop.circle"
        }
    }

    /// One-line pane subtitle under the pane title.
    var subtitle: String {
        switch self {
        case .general: return "How suggestions look and where they run."
        case .suggestions: return "Tune quality, speed and precision — hover any control to preview its effect."
        case .model: return "Pick the on-device model. Everything is measured on real text."
        case .personalization: return "Teach Pretype your voice — all on your Mac."
        }
    }
}

/// Sidebar + pane + Live Impact inspector — the System Settings shape of the
/// new macOS: navigation and the rail render on system Liquid Glass, content
/// stays on standard grouped-form backgrounds (per the HIG, glass is for the
/// floating layer, never the content itself).
struct SettingsRootView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .inspector(isPresented: .constant(true)) {
                    ImpactRailView(store: store)
                        .inspectorColumnWidth(min: 250, ideal: 280, max: 340)
                }
        }
        .frame(minWidth: 1020, minHeight: 620)
    }

    private var sidebar: some View {
        List(selection: $store.activeTab) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                Label(tab.rawValue, systemImage: tab.symbol)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 176, ideal: 200, max: 240)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 7) {
                Circle().fill(store.statusText.isEmpty ? Color.secondary : store.statusColor)
                    .frame(width: 8, height: 8)
                Text(store.statusText.isEmpty ? "Engine idle" : store.statusText)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
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
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Liquid Glass where available, material fallback earlier. For small
/// floating layers only (chart info card and the like) — content sections
/// stay on standard backgrounds.
extension View {
    @ViewBuilder func glassCard(cornerRadius: CGFloat = 10) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

/// Segmented control with per-option hover callbacks (the native Picker
/// exposes none). The selection thumb is a single view that SLIDES between
/// segments (matchedGeometryEffect + spring) and renders as Liquid Glass on
/// macOS 26, with the classic control fill as the fallback.
struct HoverSegments<T: Hashable>: View {
    let options: [(value: T, label: String)]
    let selection: T
    let select: (T) -> Void
    var hover: ((T, Bool) -> Void)?

    @Namespace private var thumbSpace
    @State private var hovered: T?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let isOn = option.value == selection
                Button { select(option.value) } label: {
                    Text(option.label)
                        .font(.callout.weight(isOn ? .semibold : .regular))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
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
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: selection)
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    /// The sliding selection thumb.
    @ViewBuilder private var thumb: some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlColor))
                .shadow(color: .black.opacity(0.15), radius: 1.5, y: 0.5)
        }
    }
}

/// Inline "what would this change do" strip under the section being hovered —
/// the same deltas the Live Impact rail shows, anchored where the eyes are.
struct PreviewDeltaStrip: View {
    @ObservedObject var store: SettingsStore
    let section: String

    var body: some View {
        if store.preview?.section == section, !store.previewDeltas.isEmpty {
            HStack(spacing: 12) {
                Text("Preview")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                ForEach(store.previewDeltas) { delta in
                    Text("\(delta.label) \(delta.text)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(delta.improved ? Color.green : Color.orange)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
        }
    }
}

// MARK: - General tab

struct GeneralTab: View {
    @ObservedObject var store: SettingsStore
    @State private var blacklistDraft = ""

    var body: some View {
        Form {
            Section("Suggestion display") {
                HStack(spacing: 12) {
                    PresentationCard(mode: .inline, title: "Inline",
                                     isSelected: store.presentation == .inline) {
                        store.presentation = .inline
                    }
                    PresentationCard(mode: .panel, title: "Panel",
                                     isSelected: store.presentation == .panel) {
                        store.presentation = .panel
                    }
                }
                Caption(store.presentation == .inline
                    ? "Ghost text continues your line right at the cursor — same size and baseline, seamless in native and Chromium/Electron apps. Tab accepts."
                    : "A small floating box beside the cursor shows the suggestion with a ⇥ hint. Never overlaps your text, and forgiving when the cursor can only be estimated.")
            }

            Section {
                Picker("Accept hotkey", selection: $store.hotkeyStyle) {
                    ForEach(HotkeyStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                LabeledContent("Ghost visibility") {
                    HStack(spacing: 8) {
                        Text("Faint").font(.caption).foregroundStyle(.tertiary)
                        Slider(value: $store.ghostOpacity, in: 0.1...1)
                        Text("Bold").font(.caption).foregroundStyle(.tertiary)
                        Text("\(Int(store.ghostOpacity * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                    .frame(width: 320)
                    .help("How strongly the ghost text stands out from your own. 70% measured most readable over real app backgrounds — 45% was near-invisible.")
                }
                OverlayPreview(presentation: store.presentation,
                               opacity: store.ghostOpacity,
                               hotkey: store.hotkeyStyle)
                Caption("Live preview — drag the slider and watch it update. The overlay picks dark or light rendering from the app background under the cursor (with Screen Recording; otherwise it follows the system theme).")
            }

            Section("Turned off in these apps") {
                if store.blacklist.isEmpty {
                    Caption("Suggestions currently run everywhere (terminals are always excluded — ghost text next to shell commands is dangerous). Add apps where Pretype should stay silent.")
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
                              prompt: Text("or type a name / bundle ID — press ⏎ to add"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .onSubmit {
                            store.addBlacklistEntry(blacklistDraft)
                            blacklistDraft = ""
                        }
                }
                Caption("Matched against the app's bundle ID, so a fragment like “slack” covers Slack everywhere.")
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
        let resolved = Self.resolve(entry)
        HStack(spacing: 8) {
            if let icon = resolved.icon {
                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
            } else {
                Image(systemName: "app.dashed")
                    .frame(width: 20, height: 20)
                    .foregroundStyle(.secondary)
            }
            Text(resolved.name)
            if resolved.name.lowercased() != entry {
                Text(entry).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                remove()
            } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Allow Pretype in this app again")
        }
    }

    /// Exact bundle IDs resolve to the installed app's real icon and name;
    /// fuzzy fragments ("slack") stay as typed with a generic glyph.
    private static func resolve(_ entry: String) -> (name: String, icon: NSImage?) {
        guard entry.contains("."),
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry)
        else { return (entry, nil) }
        return (FileManager.default.displayName(atPath: url.path),
                NSWorkspace.shared.icon(forFile: url.path))
    }
}

/// Live preview of the overlay exactly as configured — the current presentation
/// mode, ghost opacity and hotkey — over a light AND a dark host background,
/// mirroring the background-probe behavior at the caret.
private struct OverlayPreview: View {
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
    }

    private func line(light: Bool) -> some View {
        let ink: Color = light ? .black : .white
        let head = ink.opacity(0.75 * opacity)
        let tail = ink.opacity(0.5 * opacity)
        return HStack(spacing: 5) {
            if presentation == .inline {
                Text("Write ").foregroundColor(ink)
                    + Text("a reply").foregroundColor(head)
                    + Text(" to Anna").foregroundColor(tail)
            } else {
                Text("Write ").foregroundColor(ink)
                HStack(spacing: 4) {
                    Text("a reply to Anna").foregroundColor(head)
                    Text(hotkey.label)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(tail)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(ink.opacity(0.09), in: Capsule())
                .overlay(Capsule().stroke(ink.opacity(0.15), lineWidth: 1))
            }
        }
        .font(.system(size: 13))
        .lineLimit(1)
    }
}

/// Selectable preview card rendering a miniature of how that mode looks at the
/// caret, so the choice is visual, not abstract.
private struct PresentationCard: View {
    let mode: SuggestionPresentation
    let title: String
    let isSelected: Bool
    let action: () -> Void

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
                    .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                            lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var previewLine: some View {
        if mode == .inline {
            (Text("Write ").foregroundColor(.primary)
                + Text("a reply").foregroundColor(.secondary))
                .font(.system(size: 13))
        } else {
            HStack(spacing: 4) {
                Text("Write ").font(.system(size: 13))
                HStack(spacing: 4) {
                    Text("a reply").font(.system(size: 13)).foregroundStyle(.secondary)
                    Text("⇥").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
            }
        }
    }
}

// MARK: - Suggestions tab

struct SuggestionsTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle("Use recommended settings", isOn: $store.useRecommended)
                    .onHover { store.setHover(.useRecommended(!store.useRecommended), $0) }
                Caption(store.useRecommended
                    ? "Style and Length follow the measured-best configuration for the selected model — now \(store.recommendation.summary). Adjusting either by hand turns this off."
                    : "Style and Length are tuned by hand below. Turn on to snap back to the measured-best configuration (\(store.recommendation.summary)).")
            }

            Section("Style") {
                HoverSegments(options: [(CompletionStyle.base, "Base"),
                                        (CompletionStyle.instruct, "Instruct")],
                              selection: store.style,
                              select: { store.style = $0 },
                              hover: { style, hovering in
                                  store.setHover(.style(style), hovering)
                              })
                PreviewDeltaStrip(store: store, section: "style")
                if store.style == .instruct, store.instructUnusable {
                    RequirementRow(met: false,
                                   text: "Instruct is broken on \(store.selectedModelName) — it answers the text instead of continuing it (~0% first-word measured)",
                                   fixTitle: "Switch to Base") { store.style = .base }
                }
                BadgeRow(badges: styleBadges)
                Caption(store.style == .instruct
                    ? (store.instructUnusable
                        ? "Instruct only works on models with a usable instruct sibling (the Gemma tiers) — pick one in the Model pane, or use Base here."
                        : "Steers an instruct-tuned model with your persona — tone- and length-aware. Strongest on text you compose (email, chat replies).")
                    : "Plain next-word continuation of the selected model — no persona, but it can abstain instead of forcing a guess, and it unlocks the high-precision gates below.")
            }

            Section("High precision") {
                Toggle("Show only confident suggestions", isOn: $store.logprobGate)
                    .disabled(!store.logprobGateUsable)
                    .onHover { hovering in
                        guard store.logprobGateUsable else { return }
                        store.setHover(.logprobGate(!store.logprobGate), hovering)
                    }
                if !store.logprobGateUsable {
                    RequirementRow(met: false,
                                   text: "Base style — it thresholds the base model's own confidence",
                                   fixTitle: "Switch to Base") { store.style = .base }
                } else {
                    BadgeRow(badges: [
                        EffectBadge(icon: "scope", text: "62–67% first-word on what it shows", tone: .quality,
                                    source: "Out-of-sample split-half calibration, τ≈−0.9: 62–67% first-word accuracy at ~30% of suggestions offered — eval-real, n=870, 2026-07-15."),
                        EffectBadge(icon: "bolt", text: "no added latency", tone: .speed,
                                    source: "Reads the first-word log-probability the decoder already produced — zero extra generation."),
                        EffectBadge(icon: "keyboard", text: "net keystrokes: −5% → +11%", tone: .quality,
                                    source: "Typing simulation (λ=2, E2B-8bit, verified on the held-out half): ungated suggestions cost −5% net keystrokes; gated save +11% — eval-real, 2026-07-15."),
                    ])
                }
                Toggle("Verify by consensus (5 samples)", isOn: $store.confidenceGate)
                    .disabled(!store.confidenceGateUsable)
                    .onHover { hovering in
                        guard store.confidenceGateUsable else { return }
                        store.setHover(.confidenceGate(!store.confidenceGate), hovering)
                    }
                if !store.confidenceGateUsable {
                    RequirementRow(met: store.style == .base,
                                   text: "Base style",
                                   fixTitle: "Switch to Base") { store.style = .base }
                    RequirementRow(met: store.recommendation.gateCapable,
                                   text: "E4B model at 6-bit or higher (E4B 8-bit or E4B 6-bit)",
                                   fixTitle: "Open Model pane") { store.activeTab = .model }
                } else {
                    BadgeRow(badges: [
                        EffectBadge(icon: "scope", text: "19% → 39% first-word", tone: .quality,
                                    source: "E4B-8bit Base on eval-real (2026-06-26): 19% ungated → 39% first-word at 54% coverage — suggests only when 5 samples agree."),
                        EffectBadge(icon: "tortoise", text: "~5× generation per keystroke", tone: .caution,
                                    source: "Samples each completion 5 times to check agreement — roughly 5× the decode work of a single pass."),
                    ])
                }
                PreviewDeltaStrip(store: store, section: "precision")
                Caption("The two gates are mutually exclusive — the confidence gate gives the same precision trade at no latency cost.")
            }

            Section("Length") {
                HoverSegments(options: [(CompletionLength.short, "Short"),
                                        (CompletionLength.medium, "Medium"),
                                        (CompletionLength.long, "Long")],
                              selection: store.length,
                              select: { store.length = $0 },
                              hover: { length, hovering in
                                  store.setHover(.length(length), hovering)
                              })
                PreviewDeltaStrip(store: store, section: "length")
                BadgeRow(badges: lengthBadges)
                Caption("Tab still accepts one word at a time; length caps how far a single suggestion runs ahead.")
            }

            Section("Trimming") {
                Toggle("Trim low-confidence endings", isOn: $store.confidenceTrim)
                BadgeRow(badges: [
                    EffectBadge(icon: "scissors", text: "drops the shaky tail", tone: .quality,
                                source: "Cuts the suggestion just before the first word the model isn't sure about (log-probability below −3.0, a conservative threshold) — the fixed-budget tail is a completion's weakest part."),
                    EffectBadge(icon: "bolt", text: "no added latency", tone: .speed,
                                source: "Uses the per-token log-probabilities the decoder already produced."),
                ])
                Caption("Works with every style and model; the Length above becomes a maximum, not a promise.")
            }
        }
        .formStyle(.grouped)
    }

    private var styleBadges: [EffectBadge] {
        if store.style == .base {
            return [
                EffectBadge(icon: "checkmark.seal", text: "more accurate on real text", tone: .quality,
                            source: "First-word 33% vs 22% of shown suggestions (Base vs Instruct+persona, same E4B-6bit family), McNemar p≈0.0005 — eval-real, n=870, 2026-07-15."),
                EffectBadge(icon: "memorychip", text: "no second model", tone: .memory,
                            source: "Instruct loads a separate instruct-tuned sibling (up to ~6.8 GB on E4B); Base runs only the selected model."),
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
                        source: "Runs the instruct-tuned sibling of the selected model (~6.8 GB it-6bit on the E4B tiers, ~3–5 GB on smaller tiers)."),
        ]
        if store.instructUnusable {
            badges.insert(EffectBadge(icon: "exclamationmark.triangle", text: "broken on this model", tone: .caution,
                                      source: "\(store.selectedModelName) answers the text instead of continuing it in Instruct style (~0% first-word measured) — use Base."), at: 0)
        }
        return badges
    }

    private var lengthBadges: [EffectBadge] {
        // Length sweep on the default model (eval-real, 2026-07-13): p50
        // 157 / 291 / 550 ms; first-word length-independent, word-F1 drops.
        let speed: EffectBadge
        switch store.length {
        case .short, .word:
            speed = EffectBadge(icon: "bolt", text: "fastest — p50 ~157 ms", tone: .speed,
                                source: "Length sweep on the default model (eval-real, 2026-07-13): short 157 ms · medium 291 ms · long 550 ms median per suggestion.")
        case .medium:
            speed = EffectBadge(icon: "bolt", text: "p50 ~291 ms (≈2× short)", tone: .caution,
                                source: "Length sweep on the default model (eval-real, 2026-07-13): short 157 ms · medium 291 ms · long 550 ms median per suggestion.")
        case .long:
            speed = EffectBadge(icon: "tortoise", text: "p50 ~550 ms (≈3.5× short)", tone: .caution,
                                source: "Length sweep on the default model (eval-real, 2026-07-13): short 157 ms · medium 291 ms · long 550 ms median per suggestion.")
        }
        return [
            speed,
            EffectBadge(icon: "scope", text: "accuracy unchanged", tone: .quality,
                        source: "First-word accuracy is length-independent in the sweep; longer buys ~1–2 pp completeness but loses word-F1 — speed is the real trade-off."),
        ]
    }

}

// MARK: - Personalization tab

struct PersonalTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section("Persona") {
                TextEditor(text: $store.instructions)
                    .font(.system(size: 12))
                    .frame(height: 84)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1))
                HStack {
                    Caption("Auto-filled from your account name and keyboard languages — steers Instruct style only. It stays on your Mac.")
                    Spacer()
                    Button("Reset to System") { store.resetInstructions() }
                        .controlSize(.small)
                }
                BadgeRow(badges: [
                    EffectBadge(icon: "scope", text: "66% → 85–88% first-word (Instruct)", tone: .quality,
                                source: "Measured on eval-v2: Instruct without a persona 66% first-word; with the auto-persona 85%; with a hand-tuned one 88%."),
                ])
            }

            Section("Learning") {
                Picker("Learn my words", selection: $store.personalization) {
                    Text("Off").tag(PersonalizationLevel.off)
                    Text("Subtle").tag(PersonalizationLevel.subtle)
                    Text("Medium").tag(PersonalizationLevel.medium)
                    Text("Strong").tag(PersonalizationLevel.strong)
                }
                BadgeRow(badges: [
                    EffectBadge(icon: "flask", text: "directionally positive, needs more data", tone: .neutral,
                                source: "Boost = level × ln(1 + times you typed this word after this context, capped), applied to the first token — the n-gram fusion whose time-split replay went 3/0 in its favor (p=0.25, underpowered at n=54; re-measured as your journal grows). The old context-free favored-word bias measured null (p=1.0) and was removed. Collected only while on; nothing leaves your Mac."),
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

            Section("Journal") {
                Toggle("Keep suggestion journal", isOn: $store.journalEnabled)
                HStack {
                    Caption("Records which suggestions you accept, dismiss or type past — the raw data for quality tuning. Stays in Application Support; on-screen OCR text is never written.")
                    Spacer()
                    Button(store.journalBytes > 0
                        ? "Clear (\(ByteCountFormatter.string(fromByteCount: Int64(store.journalBytes), countStyle: .file)))"
                        : "Empty") {
                        store.clearJournal()
                    }
                    .controlSize(.small)
                    .disabled(store.journalBytes == 0)
                }
                Toggle("Reuse my accepted phrases as examples", isOn: $store.examplesEnabled)
                BadgeRow(badges: [
                    EffectBadge(icon: "checkmark.seal", text: "measured win on Instruct style", tone: .quality,
                                source: "Few-shot from your own accepted phrases: first-word 4% → 10% on the journal replay, all 7 discordant samples in its favor, exact p=0.016 (Instruct path)."),
                    EffectBadge(icon: "info.circle", text: "now feeds Base style too — unmeasured", tone: .neutral,
                                source: "Base used to ignore examples (confirmed no-op A/B). Since 2026-07-16 they are prefixed to the Base prompt as a label-free block (the screen-context format) — the instruct win motivated the port; the Base-path effect itself is not measured yet."),
                ])
            }
        }
        .formStyle(.grouped)
    }
}
