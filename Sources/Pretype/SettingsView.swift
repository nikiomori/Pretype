import AppKit
import AVFoundation
import Carbon
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
            controller?.setEnabled(enabled) }
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
    @Published var replyGesture = ReplyGesture.option {
        didSet { guard !syncing, oldValue != replyGesture else { return }
            Settings.replyGesture = replyGesture }
    }
    /// Hold-to-talk dictation. The write goes through `SettingsUI` because
    /// switching it on is what asks for the microphone — and has to report a
    /// refusal, since macOS only ever prompts once.
    @Published var dictation = false {
        didSet { guard !syncing, oldValue != dictation else { return }
            SettingsUI.setDictation(dictation) { [weak self] granted in
                guard let self, !granted else { return }
                self.syncing = true
                self.dictation = false
                self.syncing = false
            } }
    }
    @Published var dictationGesture = DictationGesture.option {
        didSet { guard !syncing, oldValue != dictationGesture else { return }
            Settings.dictationGesture = dictationGesture }
    }
    @Published var dictationLatch = DictationLatch.off {
        didSet { guard !syncing, oldValue != dictationLatch else { return }
            Settings.dictationLatch = dictationLatch }
    }
    /// Silence budget for a hands-free capture, in seconds; 0 is off. Stored as
    /// a Double so the picker can offer it directly.
    @Published var dictationSilence = 5.0 {
        didSet { guard !syncing, oldValue != dictationSilence else { return }
            Settings.dictationSilence = dictationSilence }
    }
    @Published var dictationPolish = true {
        didSet { guard !syncing, oldValue != dictationPolish else { return }
            Settings.dictationPolish = dictationPolish }
    }
    @Published var dictationInput = "auto" {
        didSet { guard !syncing, oldValue != dictationInput else { return }
            Settings.dictationInput = dictationInput
            refreshDictationInput() }
    }
    /// Input devices to offer, and the one a capture would open right now.
    @Published var dictationInputs: [AudioDevices.Device] = []
    @Published var dictationInputNote: String?
    @Published var dictationLanguage = "auto" {
        didSet { guard !syncing, oldValue != dictationLanguage else { return }
            Settings.dictationLanguage = dictationLanguage
            refreshDictationLanguage() }
    }
    /// Which speech model the current language would use — or that macOS has
    /// none for it. Resolved async; nil until the first answer arrives.
    @Published var dictationSupport: Transcription.LanguageSupport?
    /// Languages the system transcriber offers, loaded once when the pane
    /// appears (the lookup is async and never changes within a session).
    @Published var dictationLocales: [Locale] = []

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
            let on = useRecommended
            // Snapping to the recommended style can mean its instruct sibling.
            let now = gateDownload(committedConfig.applying(.useRecommended(on))) { [weak self] in
                Settings.useRecommendedSettings = on
                if on { self?.controller?.applyRecommendedSettings() }
                self?.resync()
            }
            // Held for the download confirmation: keep showing what runs.
            if !now { syncing = true; useRecommended = oldValue; syncing = false } }
    }
    @Published var style = CompletionStyle.instruct {
        didSet { guard !syncing, oldValue != style else { return }
            let picked = style
            // Instruct loads a separate sibling model — 3–7 GB on the Gemma tiers.
            let now = gateDownload(committedConfig.applying(.style(picked))) { [weak self] in
                self?.unlockManualTuning()
                self?.controller?.setCompletionStyle(picked)
                self?.resync()
            }
            if !now { syncing = true; style = oldValue; syncing = false } }
    }
    @Published var length = CompletionLength.short {
        didSet { guard !syncing, oldValue != length else { return }
            unlockManualTuning()
            controller?.setCompletionLength(length)
            // Leaving Recommended re-targets the rows: they keep this style now.
            refreshModelDiskUsage() }
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

    /// Language the Model tab's figures are shown for ("*" = all languages, or
    /// a language code — no pooled entry: English and Russian are separate
    /// choices like every other language). Presentation-only — re-renders the
    /// tab, never touches the pipeline.
    @Published var accuracyAxis = Settings.accuracyAxis {
        didSet { guard !syncing, oldValue != accuracyAxis else { return }
            Settings.accuracyAxis = accuracyAxis
            // Picking a language is a request to see that language. Leaving the
            // pooled settings-map sample on would silently override it and show
            // English+Russian figures under a "Russian" selection.
            if settingsMapMode { settingsMapMode = false } }
    }

    /// Settings-map mode: the whole tab moves to the pooled English+Russian
    /// sample the config projections are anchored to. Separate from the
    /// language so switching it off returns to the language you had picked.
    @Published var settingsMapMode = Settings.settingsMapMode {
        didSet { guard !syncing, oldValue != settingsMapMode else { return }
            Settings.settingsMapMode = settingsMapMode }
    }

    /// What the tab actually measures against: the pooled sample while the
    /// settings map is on, the chosen language otherwise.
    var effectiveAxis: String { settingsMapMode ? "core" : accuracyAxis }

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

    /// Why dictation can't run here, or nil when it can. Shown instead of the
    /// controls: a switch that flips but never works is worse than none.
    var dictationBlocker: String? {
        if !MicrophoneAccess.isBundled {
            return "Available in the built app only — this binary is running outside a .app bundle, "
                + "and macOS grants microphone access by bundle."
        }
        if !Transcription.isSupported {
            return "Needs macOS 26 or later: dictation uses the system's own on-device speech models, "
                + "so there is nothing to download from us and nothing to send anywhere."
        }
        if dictationMicDenied {
            return "Microphone access is denied for Pretype, and macOS only ever asks once — "
                + "allow it under Privacy & Security → Microphone, then come back and switch "
                + "dictation on."
        }
        return nil
    }

    /// The one blocker the user can actually reverse — surfaced with a button
    /// that jumps straight to the pane where the refusal is undone.
    var dictationMicDenied: Bool {
        MicrophoneAccess.isBundled && Transcription.isSupported
            && [.denied, .restricted].contains(MicrophoneAccess.status)
    }

    /// The language a capture would open with right now, named — so "Follow
    /// keyboard" can show what it currently resolves to.
    var dictationLanguageName: String {
        let locale = Settings.resolvedDictationLocale
        return Locale.current.localizedString(forIdentifier: locale.identifier)
            ?? Locale.current.localizedString(forLanguageCode: locale.identifier)
            ?? locale.identifier
    }

    /// Load the transcriber's language list once (async, never changes within
    /// a session). Sorted by their names in the user's own locale.
    func loadDictationLocales() {
        refreshDictationLanguage()
        guard dictationLocales.isEmpty else { return }
        Task { @MainActor [weak self] in
            let locales = await Transcription.supportedLocales()
            self?.dictationLocales = locales.sorted {
                Transcription.name(of: $0) < Transcription.name(of: $1)
            }
        }
    }

    /// Re-read the device list and say — out loud — when the automatic rule is
    /// substituting a microphone, because the substitution is otherwise exactly
    /// the kind of surprise that reads as a bug ("I chose AirPods in System
    /// Settings; why does it record from the laptop?").
    func refreshDictationInput() {
        let inputs = AudioDevices.inputs()
        dictationInputs = inputs
        let defaultInput = AudioDevices.defaultInput()
        let chosen = AudioDevices.resolve(
            preference: AudioDevices.Preference(stored: Settings.dictationInput),
            inputs: inputs, defaultInput: defaultInput,
            defaultOutput: AudioDevices.defaultOutput())
        dictationInputNote = AudioDevices.automaticExplanation(defaultInput: defaultInput, chosen: chosen)
    }

    /// Re-ask which model serves the language a capture would use right now.
    /// Cheap, and re-run whenever the pane appears — under "Follow keyboard"
    /// the answer changes with the layout.
    func refreshDictationLanguage() {
        Task { @MainActor [weak self] in
            let support = await Transcription.support(for: Settings.resolvedDictationLocale)
            self?.dictationSupport = support
        }
    }

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

    /// A switch whose weights aren't on this Mac yet, waiting for the user to
    /// confirm the download (see `gateDownload`).
    struct PendingDownload {
        let name: String
        let sizeGB: Double
        let commit: @MainActor () -> Void
    }
    @Published var pendingDownload: PendingDownload?

    /// Catalog rows whose click would download weights first — refreshed with
    /// the disk figures, off the main actor (see `refreshModelDiskUsage`).
    @Published var needsDownload: Set<String> = []

    /// The weights a model + style keeps loaded — the instruct sibling in
    /// Instruct style, resolved the way `MLXEngine.init` picks its primary —
    /// with a name for them and their download size (hub sizes, GB).
    static func weights(modelID: String, style: CompletionStyle)
        -> (id: String, name: String, gb: Double) {
        let option = ModelCatalog.option(for: modelID)
        let name = (option?.title ?? (modelID as NSString).lastPathComponent)
            .components(separatedBy: " — ")[0]
        guard style == .instruct, let sibling = option?.instructModelID, sibling != modelID else {
            return (modelID, name, Double(option?.approxSizeMB ?? 0) / 1000)
        }
        return (sibling, "\(name) Instruct", ModelMetrics.instructRamGB(for: modelID) ?? 0)
    }

    /// Every switch that changes what the engine loads goes through here.
    /// Committing shuts the running engine down on the spot, so weights that
    /// aren't on this Mac yet mean no suggestions for the whole download — up
    /// to 8.6 GB, from one click on a row. Those wait for a confirmation;
    /// anything already here (Apple Intelligence and local fine-tunes always
    /// are) commits at once. Returns whether `commit` ran now.
    @discardableResult
    private func gateDownload(_ target: ProjectionConfig,
                              _ commit: @escaping @MainActor () -> Void) -> Bool {
        let next = Self.weights(modelID: target.modelID, style: target.style)
        let running = Self.weights(modelID: Settings.mlxModelID, style: Settings.completionStyle)
        guard next.id != running.id, !ModelStorage.isFetched(next.id) else {
            commit()
            return true
        }
        pendingDownload = PendingDownload(name: next.name, sizeGB: next.gb, commit: commit)
        return false
    }

    func selectModel(_ id: String) {
        guard id != modelID else { return }
        gateDownload(committedConfig.applying(.model(id))) { [weak self] in
            guard let self else { return }
            modelID = id
            controller?.setModel(id)
            resync()
        }
    }

    /// Commit an exact configuration in one shot (presets and map dots land
    /// here): one coordinator call, one engine rebuild — replaying it through
    /// the per-field didSets would rebuild the engine per field.
    func applyConfig(_ target: ProjectionConfig) {
        guard target != committedConfig else { return }
        gateDownload(target) { [weak self] in
            self?.controller?.applyConfig(target)
            self?.resync()
        }
    }

    /// One-click priority preset: the measured-best model for the goal ON
    /// the selected accuracy axis, in the exact configuration its card
    /// figures come from (Base · Short), keeping the precision gates where
    /// the model supports them.
    func applyPriority(_ priority: ModelPriority) {
        applyConfig(committedConfig.applying(.preset(priority.pick(axis: effectiveAxis))))
    }

    /// A preset reads as active when the pipeline sits exactly where clicking
    /// it would land (gates are preserved by presets, so they don't count).
    func priorityIsActive(_ priority: ModelPriority) -> Bool {
        modelID == priority.pick(axis: effectiveAxis) && style == .base && length == .short
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
        SettingsUI.run(panel) { [weak self] urls in
            for url in urls {
                let entry = (Bundle(url: url)?.bundleIdentifier ?? url.deletingPathExtension().lastPathComponent)
                    .lowercased()
                self?.addBlacklistEntry(entry)
            }
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
        SettingsUI.run(panel) { [weak self] urls in
            guard let self else { return }
            for url in urls {
                guard let id = Bundle(url: url)?.bundleIdentifier?.lowercased() else { continue }
                // Prefill with the ready-made template for the app's kind (email /
                // work chat / casual chat / notes) so the user edits, not writes.
                if perAppInstructions[id] == nil {
                    perAppInstructions[id] = PerAppPresets.template(for: id) ?? ""
                }
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
        SettingsUI.run(panel) { [weak self] urls in
            if let url = urls.first { self?.selectModel(url.path) }
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
        SettingsUI.run(panel) { [weak self] urls in self?.importTextFiles(urls) }
    }

    private func importTextFiles(_ urls: [URL]) {
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
        // What a click on each row would load, cascade included — Recommended
        // lands the Gemma rows on their instruct sibling, not the base weights.
        let targets = ids.map { id -> (String, String) in
            let c = committedConfig.applying(.model(id))
            return (id, Self.weights(modelID: c.modelID, style: c.style).id)
        }
        Task.detached {
            var sizes: [String: Int64] = [:]
            for id in ids {
                let bytes = ModelStorage.deletableRepos(for: id, selected: selected)
                    .compactMap(ModelStorage.directory(for:))
                    .reduce(Int64(0)) { $0 + ModelStorage.bytes(at: $1) }
                if bytes > 0 { sizes[id] = bytes }
            }
            let measured = sizes
            let missing = Set(targets.filter { !ModelStorage.isFetched($0.1) }.map(\.0))
            await MainActor.run {
                if self.modelDiskBytes != measured { self.modelDiskBytes = measured }
                if self.needsDownload != missing { self.needsDownload = missing }
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
    /// when it is safest (nothing loaded, nothing writing). Polled by the
    /// status timer and published only when it flips.
    @Published private(set) var engineBusy = false

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
        replyGesture = Settings.replyGesture
        // Permission can be revoked in System Settings while we're running.
        // Clear the stored flag rather than just the switch: a setting that
        // reads on while the microphone is denied is a feature that silently
        // refuses every time the key is held. Only a REAL refusal though:
        // `.notDetermined` (a TCC reset, an ad-hoc re-sign) keeps the feature —
        // `begin()` answers it by asking on the next hold — and an unbundled
        // `swift run` has no TCC identity to read at all.
        if Settings.dictationEnabled, MicrophoneAccess.isBundled,
           [.denied, .restricted].contains(MicrophoneAccess.status) {
            Settings.dictationEnabled = false
        }
        dictation = Settings.dictationEnabled
        dictationGesture = Settings.dictationGesture
        dictationLatch = Settings.dictationLatch
        dictationSilence = Settings.dictationSilence
        dictationPolish = Settings.dictationPolish
        dictationLanguage = Settings.dictationLanguage
        dictationInput = Settings.dictationInput
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
        settingsMapMode = Settings.settingsMapMode
        // Journal stats deliberately NOT read here: sync() runs on every ⌘, and
        // after every model/style/gate change, and `fileSize` is a flush barrier
        // that can queue behind a whole-file n-gram replay. PersonalTab refreshes
        // them itself; anything destructive re-reads live via `journalHasData`.
        syncing = false
        preview = nil  // committed state changed — it is the new baseline
        refreshEngineBusy()
    }

    /// Cascading changes (model → style/length → gates) land in Settings after
    /// the controller call; re-read them outside the current view update.
    /// The row figures follow the committed config: a new model moves the
    /// protected repo set, and a new model/style/Recommended moves what each
    /// row's click would load — so they refresh after the re-read, not before.
    private func resync() {
        DispatchQueue.main.async { [weak self] in
            self?.sync()
            self?.refreshModelDiskUsage()
        }
    }

    func startStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshEngineBusy() }
        }
    }

    func stopStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = nil
    }

    /// Assign only on change: this runs on a 1 s timer, and a no-op
    /// @Published set still invalidates every observing view — enough to
    /// hitch an in-flight scroll. The status line itself lives in
    /// `EngineStatusFooter`, off the store for the same reason.
    private func refreshEngineBusy() {
        let busy = controller?.engine.isLoading ?? false
        guard engineBusy != busy else { return }
        engineBusy = busy
        // A download just landed: rows sharing its weights stop reading "↓".
        if !busy { refreshModelDiskUsage() }
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
    /// form. Dark is untouched — there they already clear 4.5:1. Same idea as
    /// the menu's `MenuHeaderView.gain`.
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
    @ObservedObject var store: SettingsStore
    @State private var blacklistDraft = ""

    var body: some View {
        Form {
            Section {
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
            } header: {
                Text("Suggestion display")
            } footer: {
                Text(store.presentation == .inline
                    ? "Ghost text continues your line right at the cursor — same size and baseline, seamless in native and Chromium/Electron apps. \(store.hotkeyStyle.label) accepts."
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
                            Slider(value: $store.ghostOpacity, in: 0.4...1, step: 0.05)
                                .accessibilityLabel("Ghost visibility")
                                .accessibilityValue("\(Int(store.ghostOpacity * 100)) percent")
                            Text("Bold").font(.caption).foregroundStyle(.secondary)
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
            } footer: {
                Text(store.presentation == .inline
                    ? "Live preview. The ghost uses the field's own font and ink; with the cursor mid-line or near the edge it moves above the line. New users see the \(store.hotkeyStyle.label) key beside it for their first 20 accepts."
                    : "Live preview — the floating panel is a fully opaque HUD, legible on any background. It picks dark or light rendering from behind the cursor (with Screen Recording; otherwise it follows the system theme).")
            }

            Section {
                Picker(selection: $store.replyGesture) {
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

                Toggle("Use clipboard context", isOn: $store.clipboardContext)
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
                        Picker(selection: $store.dictationGesture) {
                            ForEach(DictationGesture.allCases, id: \.self) { gesture in
                                Text(gesture.label).tag(gesture)
                            }
                        } label: {
                            Text("Push-to-talk key")
                            if store.dictationGesture != .off {
                                Text("A hold, not a tap"
                                    + (store.replyGesture == .off ? "" : ", so it never collides with “\(store.replyGesture.label)” for a reply")
                                    + ". Recording starts after about half a second of quiet hold; any other "
                                    + "key, click or scroll before that cancels it, and esc discards one already running.")
                            }
                        }
                        if store.dictationGesture == .off, store.dictationLatch == .off {
                            Caption("⚠︎ Dictation is on but no key is assigned, so nothing can "
                                + "start a capture. Pick a key above or a hands-free chord below, "
                                + "or switch the feature off.")
                        }
                        Picker(selection: $store.dictationLatch) {
                            ForEach(DictationLatch.allCases, id: \.self) { latch in
                                Text(latch.label).tag(latch)
                            }
                        } label: {
                            Text("Hands-free chord")
                            if store.dictationLatch != .off {
                                Text("Press it once to start, once more to stop — nothing to hold, so "
                                    + "you can scroll, click and think mid-sentence without losing the "
                                    + "capture. It also starts recording on the keypress itself rather "
                                    + "than half a second later, because nothing else on the system means "
                                    + "this chord. ⎋ still throws the capture away, and moving to another "
                                    + "field ends it.")
                            }
                        }
                        if store.dictationLatch != .off {
                            if store.dictationLatch.collidesWithFixChord {
                                Caption("⚠︎ \(store.dictationLatch.label) is already the \(store.hotkeyStyle.correctionLabel) fix's chord "
                                    + "under your “\(store.hotkeyStyle.label)” hotkey, and the fix wins. "
                                    + "Pick the other chord, or change the accept hotkey above.")
                            }
                            Picker(selection: $store.dictationSilence) {
                                Text("Never").tag(0.0)
                                Text("3 seconds").tag(3.0)
                                Text("5 seconds").tag(5.0)
                                Text("10 seconds").tag(10.0)
                            } label: {
                                Text("Stop after silence")
                                Text(store.dictationSilence == 0
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
                        case .unsupported:
                            Caption("⚠︎ macOS has no speech model for \(store.dictationLanguageName) at all. "
                                + "Pick a language it can dictate, or switch keyboard layout before "
                                + "holding the key.")
                        case nil:
                            EmptyView()
                        }
                        Toggle(isOn: $store.dictationPolish) {
                            Text("Tidy up with the model")
                            Text("Runs the transcript through the same minimal-edit fix \(store.hotkeyStyle.correctionLabel) uses on a "
                                + "selection — capitalization, punctuation, obvious mishearings — and "
                                + "rejects the result outright if the model starts rephrasing instead. "
                                + "Costs one short generation before the text lands; off types exactly "
                                + "what was heard. On models that fix with a separate instruct sibling, "
                                + "the first use downloads it — dictations land as heard rather than "
                                + "waiting for that, and the tidy-up starts once it has finished.")
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
            .onReceive(NotificationCenter.default.publisher(
                for: AVCaptureDevice.wasConnectedNotification)
                .receive(on: DispatchQueue.main)) { _ in
                store.refreshDictationInput()
            }
            .onReceive(NotificationCenter.default.publisher(
                for: AVCaptureDevice.wasDisconnectedNotification)
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
                    Caption("Suggestions currently run everywhere except terminals and password managers, which are always excluded. Add apps where Pretype should stay silent.")
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
                Toggle(isOn: $store.automaticUpdateCheck) {
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
                    Text("Write ").foregroundColor(ink)
                        + Text("a reply").foregroundColor(head)
                        + Text(" to Anna").foregroundColor(tail)
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
                            Text("a reply").foregroundColor(ink)
                                + Text(" to Anna").foregroundColor(ink.opacity(0.55))
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
        .accessibilityLabel(title)
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
                        Text("Off").tag(PersonalizationLevel.off)
                        Text("Subtle").tag(PersonalizationLevel.subtle)
                        Text("Medium").tag(PersonalizationLevel.medium)
                        Text("Strong").tag(PersonalizationLevel.strong)
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
