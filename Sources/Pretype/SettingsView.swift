import AppKit
import SwiftUI

// MARK: - Store

/// Hover previews change many times a second as the pointer moves. They live
/// on their own observable so that hovering re-renders only the surfaces that
/// draw previews (map, rail, delta strips) — never the scrolling Form around
/// them: any @Published set on the store invalidates every tab observing it,
/// which visibly hitches wheel/trackpad scrolling over the model list.
@MainActor
final class HoverState: ObservableObject {
    @Published var preview: ProjectionConfig.Change?
}

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
    @Published var logprobGate = false {
        didSet { guard !syncing, oldValue != logprobGate else { return }
            controller?.setLogprobGate(logprobGate)
            resync() }
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
            Settings.suggestionJournalEnabled = journalEnabled
            // Off means forget: keeping a file of typed-text snippets around
            // after the user opted out would betray what the toggle promises.
            if !journalEnabled { clearJournal() } }
    }
    @Published var instructions = "" {
        didSet { guard !syncing, oldValue != instructions else { return }
            controller?.setCustomInstructions(instructions) }
    }
    /// Per-app persona additions (exact lowercased bundle ID → text). Read by
    /// the engines at generation time, so writes apply live — no rebuild.
    @Published var perAppInstructions: [String: String] = [:] {
        didSet { guard !syncing, oldValue != perAppInstructions else { return }
            Settings.perAppInstructions = perAppInstructions }
    }
    @Published var idleUnloadMinutes = 5 {
        didSet { guard !syncing else { return }
            Settings.idleUnloadMinutes = idleUnloadMinutes }
    }
    @Published var screenContext = false {
        didSet { guard !syncing, oldValue != screenContext else { return }
            SettingsUI.setScreenContext(screenContext) }
    }
    @Published var clipboardContext = false {
        didSet { guard !syncing, oldValue != clipboardContext else { return }
            Settings.clipboardContextEnabled = clipboardContext }
    }
    @Published var automaticUpdateCheck = true {
        didSet { guard !syncing, oldValue != automaticUpdateCheck else { return }
            Settings.automaticUpdateCheck = automaticUpdateCheck }
    }
    /// Login-item state, re-read from launchd on every `sync()` — there is no
    /// stored mirror to keep in step (see `LoginItem`). Writes go through
    /// `setOpenAtLogin`, so no didSet here.
    @Published var loginStatus = LoginItem.status

    /// Selection flows through `selectModel`, not a binding didSet.
    @Published var modelID = ModelCatalog.defaultID

    /// Accuracy axis for the whole Model tab ("*" = all languages, "core" =
    /// EN+RU, or a language code). Presentation-only — re-renders the tab,
    /// never touches the pipeline.
    @Published var accuracyAxis = Settings.accuracyAxis {
        didSet { guard !syncing, oldValue != accuracyAxis else { return }
            Settings.accuracyAxis = accuracyAxis }
    }

    /// Pane selected in the sidebar.
    @Published var activeTab = SettingsTab.general {
        didSet { preview = nil }
    }

    /// Control being hovered right now — the Live Impact rail, the delta
    /// strips and the model map preview its effect before anything commits.
    /// On `HoverState`, not the store, so hovering never re-renders the Form.
    let hoverState = HoverState()
    var preview: ProjectionConfig.Change? {
        get { hoverState.preview }
        set { hoverState.preview = newValue }
    }

    func setHover(_ change: ProjectionConfig.Change, _ hovering: Bool) {
        if hovering {
            if preview != change { preview = change }
        } else if preview == change {
            preview = nil
        }
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
    /// Bytes on disk per catalog id — what deleting that entry would free.
    /// Refreshed when the Model tab appears, never on the 1 s timer: it is a
    /// few hundred `stat`s against a possibly-cold cache.
    @Published var modelDiskBytes: [String: Int64] = [:]
    /// One-line result of the last journal import, shown under the Journal
    /// section. nil until the user imports something.
    @Published var importStatus: String?
    /// An import is running — disables the button so a double-click can't run
    /// two concurrent imports, each with its own 500-row budget.
    @Published var importing = false

    // MARK: Derived

    var recommendation: ModelCatalog.Recommendation { ModelCatalog.recommended(for: modelID) }
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
                         logprobGate: logprobGate, confidenceGate: false,
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

    /// "MiniCPM5 1B · Base · Short · Confident-only" — what is running now.
    var setupLine: String {
        var parts = [ModelMetrics.metrics(for: modelID)?.shortName ?? selectedModelName]
        if !isAppleIntelligence { parts.append(style == .instruct ? "Instruct" : "Base") }
        parts.append(length.rawValue.capitalized)
        if logprobGate { parts.append("Confident-only") }
        return parts.joined(separator: " · ")
    }

    // MARK: Actions

    func selectModel(_ id: String) {
        guard id != modelID else { return }
        modelID = id
        controller?.setModel(id)
        resync()
        // The protected repo set moves with the selection: the model just left
        // becomes deletable, the one just picked stops being.
        refreshModelDiskUsage()
    }

    /// Commit an exact configuration in one shot (presets and map dots land
    /// here): one coordinator call, one engine rebuild — replaying it through
    /// the per-field didSets would rebuild the engine per field.
    func applyConfig(_ target: ProjectionConfig) {
        guard target != committedConfig else { return }
        controller?.applyConfig(target)
        resync()
    }

    /// One-click priority preset: the measured-best model for the goal ON
    /// the selected accuracy axis, in the exact configuration its card
    /// figures come from (Base · Short), keeping the precision gates where
    /// the model supports them.
    func applyPriority(_ priority: ModelPriority) {
        applyConfig(committedConfig.applying(.preset(priority.pick(axis: accuracyAxis))))
    }

    /// A preset reads as active when the pipeline sits exactly where clicking
    /// it would land (gates are preserved by presets, so they don't count).
    func priorityIsActive(_ priority: ModelPriority) -> Bool {
        modelID == priority.pick(axis: accuracyAxis) && style == .base && length == .short
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

    /// Both editors re-seed from the live defaults first: the menu bar's
    /// "Disable in <app>" writes `Settings.userBlacklist` directly, so a Settings
    /// window that has been open since before that click holds a stale mirror —
    /// and mutating the stale array writes it straight back, silently undoing
    /// the menu toggle for an app that isn't even on screen.
    func addBlacklistEntry(_ raw: String) {
        let entry = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var live = Settings.userBlacklist
        guard !entry.isEmpty, !live.contains(entry) else { return }
        live.append(entry)
        blacklist = live
    }

    func removeBlacklistEntry(_ entry: String) {
        blacklist = Settings.userBlacklist.filter { $0 != entry }
    }

    /// Add an app for a per-app persona line via the standard app-picker
    /// panel; keys by exact lowercased bundle ID (the engines match exactly —
    /// unlike the blacklist's substring markers, instructions shouldn't leak
    /// into look-alike apps).
    func addPerAppInstructionApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add Instructions"
        panel.message = "Choose applications that get their own style instructions."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier?.lowercased() else { continue }
            // Prefill with the ready-made template for the app's kind (email /
            // work chat / casual chat / notes) so the user edits, not writes.
            if perAppInstructions[id] == nil {
                perAppInstructions[id] = PerAppPresets.template(for: id) ?? ""
            }
        }
    }

    /// Preset apps installed on this Mac and not configured yet.
    var perAppSuggestions: [(bundleID: String, text: String)] {
        PerAppPresets.installedSuggestions(excluding: Set(perAppInstructions.keys))
    }

    /// One click: add every installed preset app with its ready-made style.
    func addSuggestedPerAppInstructions() {
        for suggestion in perAppSuggestions {
            perAppInstructions[suggestion.bundleID] = suggestion.text
        }
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
        importStatus = nil
    }

    /// Seed the journal from the user's own writing. Personalization measured
    /// underpowered (n=54) for one reason: the journal only ever grew from live
    /// typing. Imported rows are ordinary journal rows — retrieval and the
    /// n-gram read them like typed ones, and Clear forgets them like typed ones.
    /// Nothing is copied anywhere but the journal; the picked files are only read.
    func importTextFiles() {
        guard !importing else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        // .md and .txt both conform to public.plain-text.
        panel.allowedContentTypes = [.plainText]
        panel.prompt = "Import"
        panel.message = "Choose plain-text or Markdown files you wrote — Pretype learns your phrasing from them."
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        importing = true
        importStatus = "Importing…"
        Task.detached {
            var rows = 0
            var files = 0
            for url in urls {
                // Re-checked per file, not just on the button: the window stays
                // live during the import, and "off means forget" has to hold
                // even if the user changes their mind halfway through.
                guard Settings.suggestionJournalEnabled else { break }
                // ONE 500-row budget across the whole import, not per file:
                // `loadPhrasesLocked` keeps the LAST 2000 phrases, so four
                // uncapped files would evict every live accepted phrase from
                // the retrieval corpus — the exact failure the cap exists for.
                guard rows < 500 else { break }
                guard let text = Self.readCapped(url) else { continue }
                let entries = SuggestionJournal.importEntries(
                    from: Self.stripMarkdown(text), source: url.lastPathComponent,
                    phraseLimit: 500 - rows)
                guard !entries.isEmpty else { continue }
                SuggestionJournal.shared.ingest(entries)
                rows += entries.count
                files += 1
            }
            // The n-gram can't fold a bulk import in incrementally — `observe` is
            // a per-app delta cursor gated on a finished build. Rebuild from the
            // file, exactly as a fresh launch would.
            PersonalNgram.shared.reset()
            PersonalNgram.shared.prepareIfNeeded()
            // prepareIfNeeded only *dispatches* the replay, and reset() has
            // already zeroed the tables — refreshing now would tell the user the
            // import wiped their learned words. Wait for the rebuild instead.
            // ponytail: bounded poll (5 s) rather than a completion handler on
            // PersonalNgram; the stats also re-read on the next window activation.
            for _ in 0..<100 where !PersonalNgram.shared.isPrepared {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            let summary = rows == 0
                ? "Nothing to import — the files were empty, or not UTF-8 text."
                : "Imported \(rows) passages from \(files) file\(files == 1 ? "" : "s")."
            await MainActor.run {
                self.importing = false
                self.importStatus = summary
                self.refreshJournalStats()
            }
        }
    }

    /// The head of a picked file, decoded as UTF-8. Bounded on purpose: the
    /// picker accepts any .txt, including a multi-GB export, and materialising
    /// that as a String next to a loaded MLX model is how a Mac jetsams the app
    /// mid-import. 4 MB of bytes covers the 2 MB of characters the importer
    /// looks at. nil for anything that isn't UTF-8 text — a renamed binary.
    nonisolated private static func readCapped(_ url: URL, bytes: Int = 4 << 20) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let head = data.prefix(bytes)
        // Cutting at a byte offset can split a multi-byte character, which fails
        // the strict decode; back off up to three bytes to a character boundary.
        for drop in 0...3 {
            if let text = String(data: head.dropLast(drop), encoding: .utf8) { return text }
        }
        return nil
    }

    /// Markdown scaffolding the model must never learn to imitate: fenced code
    /// blocks, and the leading heading/list/quote markers. Everything else is
    /// the user's prose and stays exactly as written.
    /// ponytail: line-level only — tables and inline `code` still get through.
    /// `nonisolated` so the import's detached task can call it: everything else
    /// on this store is main-actor bound.
    nonisolated private static func stripMarkdown(_ text: String) -> String {
        var inFence = false
        return text.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            if line.hasPrefix("```") {
                inFence.toggle()
                return false
            }
            return !inFence
        }
        .map { $0.drop { "#>*-+ ".contains($0) } }
        .joined(separator: "\n")
    }

    /// Bytes on disk for every catalog model the user could delete. Off the main
    /// actor: it stats a few hundred blobs in a cache that may be cold.
    func refreshModelDiskUsage() {
        let selected = modelID
        let ids = ModelCatalog.options.map(\.id)
        Task.detached {
            var sizes: [String: Int64] = [:]
            for id in ids {
                let bytes = ModelStorage.deletableRepos(for: id, selected: selected)
                    .compactMap(ModelStorage.directory(for:))
                    .reduce(Int64(0)) { $0 + ModelStorage.bytes(at: $1) }
                if bytes > 0 { sizes[id] = bytes }
            }
            let measured = sizes
            await MainActor.run {
                if self.modelDiskBytes != measured { self.modelDiskBytes = measured }
            }
        }
    }

    func deleteDownload(_ id: String) {
        for repo in ModelStorage.deletableRepos(for: id, selected: modelID) {
            try? ModelStorage.delete(repo)
        }
        refreshModelDiskUsage()
    }

    /// A load or download is in flight — deleting now would race the writer.
    /// Keyed on `isLoading`, not `state`: the idle-unloaded resting state also
    /// reports `.preparing`, and gating on that would disable deletion exactly
    /// when it is safest (nothing loaded, nothing writing).
    var engineBusy: Bool { controller?.engine.isLoading ?? false }

    func setOpenAtLogin(_ on: Bool) {
        LoginItem.set(on)
        // launchd is the truth, not the click: a refused or held registration
        // snaps the switch back instead of showing a state that isn't real.
        loginStatus = LoginItem.status
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
        // Mask inapplicable persisted flags: a gate restored from a state the
        // coordinator's hygiene never saw must not render as
        // on-but-doing-nothing.
        logprobGate = Settings.logprobGate && style == .base
        personalization = Settings.personalizationLevel
        journalEnabled = Settings.suggestionJournalEnabled
        instructions = Settings.customInstructions
        perAppInstructions = Settings.perAppInstructions
        idleUnloadMinutes = Settings.idleUnloadMinutes
        screenContext = Settings.screenContextEnabled
        clipboardContext = Settings.clipboardContextEnabled
        automaticUpdateCheck = Settings.automaticUpdateCheck
        loginStatus = LoginItem.status  // the user may have flipped it in System Settings
        accuracyAxis = Settings.accuracyAxis
        // Journal stats deliberately NOT read here: sync() runs on every ⌘, and
        // after every model/style/gate change, and `fileSize` is a flush barrier
        // that can queue behind a whole-file n-gram replay. PersonalTab refreshes
        // them itself; anything destructive re-reads live via `journalHasData`.
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
        let text: String
        let color: Color
        if let engine = controller?.engine {
            switch engine.state {
            case .ready:
                text = "\(engine.name) — ready"
                color = .green
            case .preparing(let detail):
                text = "\(engine.name) — \(detail)"
                color = .orange
            case .failed(let detail):
                text = "\(engine.name) — \(detail)"
                color = .red
            }
        } else {
            text = ""
            color = .secondary
        }
        // Assign only on change: this runs on a 1 s timer, and a no-op
        // @Published set still invalidates every observing view — enough to
        // hitch an in-flight scroll.
        if statusText != text { statusText = text }
        if statusColor != color { statusColor = color }
    }

    /// Journal stats are display-only and grow slowly, so they refresh when the
    /// Personalization tab appears rather than on the 1 s status timer:
    /// `fileSize` is a flush barrier on the journal queue, and a per-second hop
    /// can land behind a whole-file n-gram replay and stall the main actor.
    /// Anything destructive re-reads them live — see `journalHasData`.
    func refreshJournalStats() {
        // Off the main actor: `fileSize` is a queue.sync flush barrier and can
        // land behind a whole-file replay. Neither read touches the main actor,
        // so there is no re-entrancy risk in hopping off and back.
        Task.detached {
            let bytes = SuggestionJournal.shared.fileSize
            let words = PersonalNgram.shared.wordCount
            await MainActor.run {
                if self.journalBytes != bytes { self.journalBytes = bytes }
                if self.learnedWords != words { self.learnedWords = words }
            }
        }
    }

    /// Live read: the clear-confirmation guard asks "is there anything to lose",
    /// and a stale zero would delete the journal without ever asking.
    var journalHasData: Bool {
        SuggestionJournal.shared.fileSize > 0 || PersonalNgram.shared.wordCount > 0
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
                    ImpactRailView(store: store, hover: store.hoverState)
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
            HStack(alignment: .top, spacing: 7) {
                // Orange == .preparing: a download, a model load or a warm-up.
                // An indeterminate spinner is honest for all three, and the
                // detail wraps instead of truncating away in a 176pt column.
                Group {
                    if store.statusColor == .orange && !store.statusText.isEmpty {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                    } else {
                        Circle().fill(store.statusText.isEmpty ? Color.secondary : store.statusColor)
                    }
                }
                .frame(width: 8, height: 8)
                .padding(.top, 3)   // align with the caption's first baseline
                Text(store.statusText.isEmpty ? "Engine idle" : store.statusText)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .help(store.statusText)
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
/// segments (matchedGeometryEffect + spring), rendered as an elevated control
/// surface so the selection is unmistakable in both light and dark.
struct HoverSegments<T: Hashable>: View {
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
                // Selection is conveyed only by weight + thumb; without the trait
                // VoiceOver reads every segment identically.
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
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
    @ObservedObject var store: SettingsStore
    @State private var blacklistDraft = ""

    var body: some View {
        Form {
            Section("Suggestion display") {
                HStack(spacing: 12) {
                    PresentationCard(mode: .inline, title: "Inline",
                                     isSelected: store.presentation == .inline,
                                     hotkeyLabel: store.hotkeyStyle.label) {
                        // Animate at the mutation site: the Ghost-visibility row
                        // below inserts/removes on this change, and a row cannot
                        // animate its own insertion from a Section modifier.
                        withAnimation(.easeInOut(duration: 0.18)) { store.presentation = .inline }
                    }
                    PresentationCard(mode: .panel, title: "Panel",
                                     isSelected: store.presentation == .panel,
                                     hotkeyLabel: store.hotkeyStyle.label) {
                        withAnimation(.easeInOut(duration: 0.18)) { store.presentation = .panel }
                    }
                }
                Caption(store.presentation == .inline
                    ? "Ghost text continues your line right at the cursor — same size and baseline, seamless in native and Chromium/Electron apps. \(store.hotkeyStyle.label) accepts."
                    : "A small floating box beside the cursor shows the suggestion with a \(store.hotkeyStyle.label) hint. Never overlaps your text, and forgiving when the cursor can only be estimated.")
            }

            Section {
                Picker("Accept hotkey", selection: $store.hotkeyStyle) {
                    ForEach(HotkeyStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                // Ghost opacity dims inline ghost text only; the panel is an
                // opaque HUD by design (SuggestionWindow), so the slider is
                // inline-only — a control that moved the preview but never the
                // real panel pill was misleading.
                if store.presentation == .inline {
                    LabeledContent("Ghost visibility") {
                        HStack(spacing: 8) {
                            Text("Faint").font(.caption).foregroundStyle(.tertiary)
                            Slider(value: $store.ghostOpacity, in: 0.1...1)
                                .accessibilityLabel("Ghost visibility")
                            Text("Bold").font(.caption).foregroundStyle(.tertiary)
                            Text("\(Int(store.ghostOpacity * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 36, alignment: .trailing)
                        }
                        .frame(width: 320)
                        .help("How strongly the ghost text stands out from your own. 70% measured most readable over real app backgrounds — 45% was near-invisible.")
                    }
                }
                OverlayPreview(presentation: store.presentation,
                               opacity: store.ghostOpacity,
                               hotkey: store.hotkeyStyle)
                Caption(store.presentation == .inline
                    ? "Live preview — drag the slider and watch it update. The overlay picks dark or light rendering from the app background under the cursor (with Screen Recording; otherwise it follows the system theme)."
                    : "Live preview — the floating panel is a fully opaque HUD, legible on any background. It picks dark or light rendering from behind the cursor (with Screen Recording; otherwise it follows the system theme).")
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

            Section("Startup") {
                // Bound to launchd, not to a stored bool: the same switch lives
                // in System Settings → Login Items, and mirroring it in
                // UserDefaults would eventually show a state that isn't real.
                Toggle("Open at login", isOn: Binding(
                    get: { LoginItem.isOn(store.loginStatus) },
                    set: { store.setOpenAtLogin($0) }
                ))
                .disabled(!LoginItem.isSupported)
                // The same switch lives in System Settings, and `sync()` only
                // runs when the window is (re)presented — catch the user coming
                // back from flipping it there, or the caption's "flipping it
                // there flips it here" only holds across window reopens.
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification)) { _ in
                    store.loginStatus = LoginItem.status
                }
                Caption("Pretype starts with your Mac and waits in the menu bar — no Dock icon, no window. "
                    + "macOS owns this switch: it also lives in System Settings → General → Login Items, "
                    + "and flipping it there flips it here.")
                if let note = LoginItem.note(store.loginStatus) {
                    Caption(note)
                }
            }

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $store.automaticUpdateCheck)
                Caption("Asks GitHub once a day whether a newer release exists — the only request Pretype makes on its own, and it sends nothing about you. New versions are announced in the menu bar and installed by you; nothing is downloaded or replaced automatically. Off still leaves “Check for Updates…” in the menu.")
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
            Button {
                remove()
            } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // .help is a hint, not a name — without this every row's remove
            // button announces identically.
            .accessibilityLabel("Stop excluding \(resolved.name)")
            .help("Allow Pretype in this app again")
        }
    }
}

/// Exact bundle IDs resolve to the installed app's real icon and name;
/// fuzzy fragments ("slack") stay as typed with a generic glyph.
private func resolveApp(_ entry: String) -> (name: String, icon: NSImage?) {
    guard entry.contains("."),
          let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry)
    else { return (entry, nil) }
    return (FileManager.default.displayName(atPath: url.path),
            NSWorkspace.shared.icon(forFile: url.path))
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
    @ObservedObject var store: SettingsStore

    var body: some View {
        let resolved = resolveApp(bundleID)
        HStack(spacing: 8) {
            AppIcon(icon: resolved.icon)
            Text(resolved.name)
                .frame(width: 110, alignment: .leading)
                .lineLimit(1).truncationMode(.tail)
                .help(bundleID)
            TextField("", text: Binding(
                get: { store.perAppInstructions[bundleID] ?? "" },
                set: { store.perAppInstructions[bundleID] = $0 }
            ), prompt: Text("e.g. formal tone, no emoji"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            Button {
                store.perAppInstructions.removeValue(forKey: bundleID)
            } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove instructions for \(resolved.name)")
            .help("Remove this app's instructions")
        }
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
        // The slider dims inline ghost text; the panel pill is an opaque HUD and
        // stays full-strength, so the preview must not move it either — else it
        // promises an effect the real panel never applies.
        let effective = presentation == .inline ? opacity : 1.0
        let head = ink.opacity(0.75 * effective)
        let tail = ink.opacity(0.5 * effective)
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
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .frame(maxWidth: .infinity)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
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
                    Text(hotkeyLabel).font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
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
                                       fixTitle: "Switch to Base") { withAnimation(.easeInOut(duration: 0.18)) { store.style = .base } }
                    } else {
                        BadgeRow(badges: [
                            EffectBadge(icon: "scope", text: "62–67% first-word on what it shows", tone: .quality,
                                        source: "Out-of-sample split-half calibration, τ≈−0.9: 62–67% first-word accuracy at ~30% of suggestions offered — eval-real, n=870, 2026-07-15."),
                            EffectBadge(icon: "hand.raised", text: "offers ~30% of the time (vs 81%)", tone: .caution,
                                        source: "The other side of the trade: roughly two of three suggestions are withheld as not-confident-enough — coverage ~30% vs 81% ungated on the default model (eval-real, n=870, 2026-07-15)."),
                        ])
                        BadgeRow(badges: [
                            EffectBadge(icon: "bolt", text: "no added latency", tone: .speed,
                                        source: "Reads the first-word log-probability the decoder already produced — zero extra generation."),
                            EffectBadge(icon: "keyboard", text: "net keystrokes: −5% → +11%", tone: .quality,
                                        source: "Typing simulation (λ=2, E2B-8bit, verified on the held-out half): ungated suggestions cost −5% net keystrokes; gated save +11% — eval-real, 2026-07-15."),
                        ])
                    }
                    Caption("Trades coverage for precision: far fewer suggestions, far more of them right — read straight off the decoder, so it costs nothing. Off means more (but less certain) suggestions.")
                }
            }  // end on-device-only tuning sections (hidden for Apple Intelligence)

            Section("Length") {
                HoverSegments(options: [(CompletionLength.short, "Short"),
                                        (CompletionLength.medium, "Medium"),
                                        (CompletionLength.long, "Long")],
                              selection: store.length,
                              select: { store.length = $0 },
                              hover: { length, hovering in
                                  store.setHover(.length(length), hovering)
                              })
                BadgeRow(badges: lengthBadges)
                Caption("\(store.hotkeyStyle.label) still accepts one word at a time; length caps how far a single suggestion runs ahead. Low-confidence endings are trimmed automatically, so this is a maximum, not a promise.")
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
        // Length sweep (eval-real, 2026-07-13): p50 157 / 291 / 550 ms on the
        // sweep model; first-word length-independent, word-F1 drops. Figures
        // shown are the sweep's ×1.85/×3.5 ratios applied to the SELECTED
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
        let sweepSource = "Measured length sweep (eval-real, 2026-07-13): 157 · 291 · 550 ms p50 on the sweep model — "
            + (baseMs != nil
                ? "the ×1.85/×3.5 ratios here are applied to \(store.selectedModelName)'s measured base latency."
                : "no measured base latency for this model, so only the ratios are shown.")
        let reach: EffectBadge
        let speed: EffectBadge
        switch store.length {
        case .short, .word:
            reach = EffectBadge(icon: "text.word.spacing", text: "runs 2–3 words ahead", tone: .neutral,
                                source: "How far one suggestion runs. Short is the sweep's best net-value point for inline ghost text — same accuracy as longer settings at a fraction of the wait.")
            speed = EffectBadge(icon: "bolt",
                                text: baseMs != nil ? "fastest — p50 ~\(ms(.short))" : "fastest",
                                tone: .speed, source: sweepSource)
        case .medium:
            reach = EffectBadge(icon: "text.word.spacing", text: "runs up to ~6 words ahead", tone: .neutral,
                                source: "What longer buys: more words per suggestion (+1–2 pp completeness in the sweep). Per-word accuracy does not improve — you pay only in wait time.")
            speed = EffectBadge(icon: "bolt",
                                text: baseMs != nil ? "p50 ~\(ms(.medium)) (≈2× short)" : "≈2× slower than short",
                                tone: .caution, source: sweepSource)
        case .long:
            reach = EffectBadge(icon: "text.word.spacing", text: "runs up to a sentence ahead", tone: .neutral,
                                source: "What longer buys: more words per suggestion (+1–2 pp completeness in the sweep). Per-word accuracy does not improve, and weak tails are trimmed automatically.")
            speed = EffectBadge(icon: "tortoise",
                                text: baseMs != nil ? "p50 ~\(ms(.long)) (≈3.5× short)" : "≈3.5× slower than short",
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
    @ObservedObject var store: SettingsStore
    /// Both journal paths destroy the learned n-gram model irreversibly, so
    /// they route through one confirmation instead of firing on a single click.
    @State private var confirmingClear = false
    @State private var clearDisablesJournal = false

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
                    Caption(store.isAppleIntelligence
                        ? "Auto-filled from your account name and keyboard languages — the primary voice control for Apple Intelligence, passed as its system instructions. It stays on your Mac."
                        : "Auto-filled from your account name and keyboard languages — steers Instruct style only. It stays on your Mac.")
                    Spacer()
                    Button("Reset to System") { store.resetInstructions() }
                        .controlSize(.small)
                }
                if !store.isAppleIntelligence {
                    BadgeRow(badges: [
                        EffectBadge(icon: "scope", text: "66% → 85–88% first-word (Instruct)", tone: .quality,
                                    source: "Measured on eval-v2: Instruct without a persona 66% first-word; with the auto-persona 85%; with a hand-tuned one 88%."),
                    ])
                }
            }

            Section("Per-app style") {
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
                }
                if !suggestions.isEmpty {
                    Caption("Suggested fills in ready-made styles for the apps found on this Mac — "
                        + suggestions.map { resolveApp($0.bundleID).name }.joined(separator: ", ")
                        + ". Every line stays editable: tweak or remove whatever doesn't fit.")
                }
                Caption(store.isAppleIntelligence
                    ? "Appended to your persona while typing in that app — steers the system model's voice, like the persona itself."
                    : "Appended to your persona while typing in that app — steers Instruct style only, like the persona itself.")
            }

            // The n-gram boost never reaches Apple Intelligence (FoundationModelsEngine
            // takes the no-op updatePersonalization — it has no logits to boost), so
            // learning would collect words it can never apply. On-device models only.
            if !store.isAppleIntelligence {
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
                        EffectBadge(icon: "info.circle", text: "now feeds Base style too — unmeasured", tone: .neutral,
                                    source: "Base used to ignore examples (confirmed no-op A/B). Since 2026-07-16 they are prefixed to the Base prompt as a label-free block (the screen-context format) — the instruct win motivated the port; the Base-path effect itself is not measured yet."),
                    ])
                    Caption("A measured win at no latency cost, so there's no switch to lose. Clear the journal above to forget the phrases.")
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
