import AppKit
import AVFoundation
import Carbon
import SwiftUI

// MARK: - Store

/// Observable bridge between the SwiftUI settings surface and the live
/// pipeline. Every mutation forwards to the same `SuggestionController` entry
/// points the old AppKit panel used; `sync()` re-reads Settings after any
/// change that cascades (model → recommended style/length → gates).
@MainActor
@Observable
final class SettingsStore {
    @ObservationIgnored weak var controller: SuggestionController?
    @ObservationIgnored private var syncing = false
    @ObservationIgnored private var statusTimer: Timer?

    init(controller: SuggestionController?) {
        self.controller = controller
        sync()
    }

    // MARK: Published mirrors of Settings

    var enabled = true {
        didSet { guard !syncing else { return }
            controller?.setEnabled(enabled) }
    }
    var presentation = SuggestionPresentation.panel {
        didSet { guard !syncing, oldValue != presentation else { return }
            controller?.setSuggestionPresentation(presentation) }
    }
    var hotkeyStyle = HotkeyStyle.tab {
        didSet { guard !syncing, oldValue != hotkeyStyle else { return }
            Settings.hotkeyStyle = hotkeyStyle
            controller?.dismiss() }
    }
    /// Hold-to-talk dictation. The write goes through `setDictation` because
    /// switching it on is what asks for the microphone — and has to report a
    /// refusal, since macOS only ever prompts once.
    var dictation = false {
        didSet { guard !syncing, oldValue != dictation else { return }
            setDictation(dictation) }
    }
    var dictationInput = "auto" {
        didSet { guard !syncing, oldValue != dictationInput else { return }
            Settings.dictationInput = dictationInput
            refreshDictationInput() }
    }
    /// Input devices to offer, and the one a capture would open right now.
    /// nil until the first device list lands (~¼ s, off the main actor): an
    /// empty list would call a pinned microphone unplugged every time the
    /// window opens.
    var dictationInputs: [AudioDevices.Device]?
    var dictationInputNote: String?
    var dictationLanguage = "auto" {
        didSet { guard !syncing, oldValue != dictationLanguage else { return }
            Settings.dictationLanguage = dictationLanguage
            refreshDictationLanguage() }
    }
    /// Which speech model the current language would use — or that macOS has
    /// none for it. Resolved async; nil until the first answer arrives.
    var dictationSupport: Transcription.LanguageSupport?
    var dictationParakeet = false {
        didSet { guard !syncing, oldValue != dictationParakeet else { return }
            Settings.dictationParakeet = dictationParakeet
            refreshDictationLanguage()
            if dictationParakeet { prepareParakeet() } }
    }
    /// The opt-in's download/load progress, or its failure; nil once ready.
    var parakeetNote: String?

    /// Fetch and load the model the moment the user opts in, so the first
    /// dictation after it doesn't sit in "preparing" for a 610 MB download.
    func prepareParakeet() {
        parakeetNote = Parakeet.isDownloaded ? nil : String(localized: "Downloading the Parakeet model (~610 MB)…")
        Task { @MainActor [weak self] in
            do {
                _ = try await Parakeet.prepare()
                self?.parakeetNote = nil
            } catch {
                self?.parakeetNote = String(localized: "⚠︎ Download failed: \(error.localizedDescription). The next dictation tries again.")
            }
        }
    }
    /// Hosted models (Settings → API). A text change while it is on — or the
    /// switch itself — rebuilds the engine; the on-device engine is never
    /// rebuilt for an edit that doesn't reach it.
    var apiText = APIConfig(provider: APIProvider.all[0], kind: .text) {
        didSet { guard !syncing, oldValue != apiText else { return }
            Settings.apiText = apiText
            apiTests[.text] = nil
            if apiText.enabled != oldValue.enabled {
                apiRebuild?.cancel()
                controller?.engineCoordinator.rebuild()
            } else if apiText.enabled {
                rebuildAfterTyping()
            } }
    }
    /// The URL, model and key fields write on every character: rebuild the
    /// engine once the typing rests, not once per keystroke.
    @ObservationIgnored private var apiRebuild: Task<Void, Never>?
    /// The controller, not the store: closing Settings inside the pause drops
    /// the store, and the engine would keep the old key or model.
    private func rebuildAfterTyping() {
        apiRebuild?.cancel()
        let controller = controller
        apiRebuild = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            controller?.engineCoordinator.rebuild()
        }
    }
    var apiAudio = APIConfig(provider: APIProvider.all[0], kind: .audio) {
        didSet { guard !syncing, oldValue != apiAudio else { return }
            Settings.apiAudio = apiAudio
            apiTests[.audio] = nil
            refreshDictationLanguage() }
    }
    /// The last "Test" result per kind, or "Testing…"; cleared by any edit.
    var apiTests: [APIKind: String] = [:]

    /// Bumped when a key is saved: both sections mirror the Keychain, and one
    /// provider's key serves both (OpenAI for text AND dictation).
    var apiKeyRevision = 0

    /// A key lives in the Keychain, not in the config, so saving one is not a
    /// config change — the text engine still has to pick it up.
    func apiKeyChanged(provider: String) {
        apiKeyRevision += 1
        if apiText.provider == provider {
            apiTests[.text] = nil
            if apiText.enabled { rebuildAfterTyping() }
        }
        if apiAudio.provider == provider { apiTests[.audio] = nil }
    }

    func testAPI(_ kind: APIKind) {
        let config = kind == .text ? apiText : apiAudio
        apiTests[kind] = String(localized: "Testing…")
        Task { @MainActor [weak self] in
            let result = kind == .text ? await CloudEngine.test(config) : await CloudTranscription.test(config)
            guard let self else { return }
            // An edit made during the round trip already cleared the line.
            if self.apiTests[kind] != nil, (kind == .text ? self.apiText : self.apiAudio) == config {
                self.apiTests[kind] = result
            }
        }
    }

    /// Languages the system transcriber offers, loaded once when the pane
    /// appears (the lookup is async and never changes within a session).
    var dictationLocales: [Locale] = []

    var blacklist: [String] = [] {
        didSet { guard !syncing, oldValue != blacklist else { return }
            Settings.userBlacklist = blacklist
            controller?.dismiss() }
    }
    var dictationSendApps: [String] = [] {
        didSet { guard !syncing, oldValue != dictationSendApps else { return }
            Settings.dictationSendApps = dictationSendApps }
    }
    var useRecommended = true {
        didSet { guard !syncing, oldValue != useRecommended else { return }
            let on = useRecommended
            // Snapping to the recommended style can mean its instruct sibling.
            let now = gateDownload(committedConfig.applying(.useRecommended(on))) { [weak self] in
                Settings.useRecommendedSettings = on
                if on { self?.controller?.engineCoordinator.apply(.useRecommended(true)) }
                self?.resync()
            }
            // Held for the download confirmation: keep showing what runs.
            if !now { quietly { useRecommended = oldValue } } }
    }
    var style = CompletionStyle.instruct {
        didSet { guard !syncing, oldValue != style else { return }
            let picked = style
            // Instruct loads a separate sibling model — 3–7 GB on the Gemma tiers.
            let now = gateDownload(committedConfig.applying(.style(picked))) { [weak self] in
                self?.unlockManualTuning()
                self?.controller?.engineCoordinator.apply(.style(picked))
                self?.resync()
            }
            if !now { quietly { style = oldValue } } }
    }
    var length = CompletionLength.short {
        didSet { guard !syncing, oldValue != length else { return }
            unlockManualTuning()
            controller?.engineCoordinator.setCompletionLength(length)
            // Leaving Recommended re-targets the rows: they keep this style now.
            refreshModelDiskUsage() }
    }
    var logprobGate = false {
        didSet { guard !syncing, oldValue != logprobGate else { return }
            controller?.engineCoordinator.apply(.logprobGate(logprobGate))
            resync() }
    }
    var personalization = false {
        didSet { guard !syncing, oldValue != personalization else { return }
            Settings.personalizationLevel = personalization ? .on : .off
            // Enabling mid-session must start the journal build right away —
            // otherwise live learning stays inert until the next keystroke.
            if personalization { PersonalNgram.shared.prepareIfNeeded() }
            learnedWords = PersonalNgram.shared.wordCount }
    }
    var journalEnabled = true {
        didSet { guard !syncing else { return }
            Settings.suggestionJournalEnabled = journalEnabled
            // Off means forget: keeping a file of typed-text snippets around
            // after the user opted out would betray what the toggle promises.
            if !journalEnabled { clearJournal() } }
    }
    var instructions = "" {
        didSet { guard !syncing, oldValue != instructions else { return }
            controller?.engineCoordinator.setCustomInstructions(instructions) }
    }
    /// Per-app persona additions (exact lowercased bundle ID → text). Read by
    /// the engines at generation time, so writes apply live — no rebuild.
    var perAppInstructions: [String: String] = [:] {
        didSet { guard !syncing, oldValue != perAppInstructions else { return }
            Settings.perAppInstructions = perAppInstructions }
    }
    var screenContext = false {
        didSet { guard !syncing, oldValue != screenContext else { return }
            setScreenContext(screenContext) }
    }
    /// Login-item state, re-read from launchd on every `sync()` — there is no
    /// stored mirror to keep in step (see `LoginItem`). Writes go through
    /// `setOpenAtLogin`, so no didSet here.
    var loginStatus = LoginItem.status

    /// Gemma's per-layer table from disk (`HostPLE`). Read when the engine
    /// loads, so a flip rebuilds it.
    var pleFromDisk = Settings.pleFromDisk {
        didSet { guard !syncing, oldValue != pleFromDisk else { return }
            Settings.pleFromDisk = pleFromDisk
            controller?.engineCoordinator.rebuild() }
    }

    /// Selection flows through `selectModel`, not a binding didSet.
    var modelID = ModelCatalog.defaultID

    /// Language the Model tab's figures are shown for ("*" = all languages, or
    /// a language code — no pooled entry: English and Russian are separate
    /// choices like every other language). Presentation-only — re-renders the
    /// tab, never touches the pipeline.
    var accuracyAxis = Settings.accuracyAxis {
        didSet { guard !syncing, oldValue != accuracyAxis else { return }
            Settings.accuracyAxis = accuracyAxis }
    }

    /// Settings-map mode: the whole tab moves to the pooled English+Russian
    /// sample the config projections are anchored to. Separate from the
    /// language so switching it off returns to the language you had picked.
    var settingsMapMode = Settings.settingsMapMode {
        didSet { guard !syncing, oldValue != settingsMapMode else { return }
            Settings.settingsMapMode = settingsMapMode }
    }

    /// "All models" as the map instead of the ranked list.
    var modelsAsMap = Settings.modelsAsMap {
        didSet { guard !syncing, oldValue != modelsAsMap else { return }
            Settings.modelsAsMap = modelsAsMap }
    }

    /// What the tab actually measures against: the pooled sample while the
    /// settings map shows, the chosen language otherwise. A switch left on
    /// behind the list must not move the list's figures off its language.
    var effectiveAxis: String { modelsAsMap && settingsMapMode ? "core" : accuracyAxis }

    /// The "Accuracy in" picker. It shows the axis the figures are on — the
    /// pooled sample too — so its label and the data never disagree. A pick
    /// is a request to see that language, even the one already stored, so it
    /// ends settings-map mode.
    var axisSelection: String {
        get { effectiveAxis }
        set {
            guard newValue != "core" else { return }
            settingsMapMode = false
            accuracyAxis = newValue
        }
    }

    /// Pane selected in the sidebar.
    var activeTab = SettingsTab.general {
        didSet { preview = nil }
    }

    /// Control being hovered right now — the Live Impact rail, the delta
    /// strips and the model map preview its effect before anything commits.
    /// `@Observable` tracks per property, so a hover re-renders only the views
    /// that read it — never the scrolling Form around them.
    var preview: ProjectionConfig.Change?

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
        quietly { useRecommended = false }
        Settings.useRecommendedSettings = false
    }

    /// Set mirrors without their didSets forwarding the change to the pipeline.
    private func quietly(_ update: () -> Void) {
        syncing = true
        update()
        syncing = false
    }

    var learnedWords = 0
    var journalBytes = 0
    /// Bytes on disk per catalog id — what deleting that entry would free.
    /// Refreshed when the Model tab appears, never on the 1 s timer: it is a
    /// few hundred `stat`s against a possibly-cold cache.
    var modelDiskBytes: [String: Int64] = [:]
    /// One-line result of the last journal import, shown under the Journal
    /// section. nil until the user imports something.
    var importStatus: String?
    /// An import is running — disables the button so a double-click can't run
    /// two concurrent imports, each with its own 500-row budget.
    var importing = false

    // MARK: Derived

    /// Why dictation can't run here, or nil when it can. Shown instead of the
    /// controls: a switch that flips but never works is worse than none.
    var dictationBlocker: String? {
        if !MicrophoneAccess.isBundled {
            return String(localized: "Available in the built app only — this binary is running outside a .app bundle, and macOS grants microphone access by bundle.")
        }
        if !Transcription.isSupported {
            return String(localized: "Not available on this Mac: dictation uses the system's own on-device speech models, and macOS reports none here.")
        }
        if dictationMicDenied {
            return String(localized: "Microphone access is denied for Pretype, and macOS only ever asks once — allow it under Privacy & Security → Microphone, then come back and switch dictation on.")
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
    var dictationLanguageName: String { Transcription.name(of: Settings.resolvedDictationLocale) }

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
    /// Settings; why does it record from the laptop?"). Off the main actor:
    /// the first device discovery in a process takes ~¼ s, and it stalled
    /// the Dictation pane on the way in. Latest request wins.
    func refreshDictationInput() {
        let preference = AudioDevices.Preference(stored: Settings.dictationInput)
        dictationInputTask?.cancel()
        dictationInputTask = Task.detached {
            let inputs = AudioDevices.inputs()
            let defaultInput = AudioDevices.defaultInput()
            let chosen = AudioDevices.resolve(preference: preference, inputs: inputs,
                                              defaultInput: defaultInput,
                                              defaultOutput: AudioDevices.defaultOutput())
            let note = AudioDevices.automaticExplanation(defaultInput: defaultInput, chosen: chosen)
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self.dictationInputs = inputs
                self.dictationInputNote = note
            }
        }
    }
    @ObservationIgnored private var dictationInputTask: Task<Void, Never>?

    /// Re-ask which model serves the language a capture would use right now.
    /// Cheap, and re-run whenever the pane appears — under "Follow keyboard"
    /// the answer changes with the layout.
    func refreshDictationLanguage() {
        // Latest request wins: a slow answer for the language picked a moment
        // ago must not land over the one picked since.
        dictationSupportTask?.cancel()
        dictationSupportTask = Task { @MainActor [weak self] in
            let support = await Transcription.support(for: Settings.resolvedDictationLocale)
            guard !Task.isCancelled else { return }
            self?.dictationSupport = support
        }
    }
    @ObservationIgnored private var dictationSupportTask: Task<Void, Never>?

    var recommendation: ModelCatalog.Recommendation { ModelCatalog.recommended(for: modelID) }
    var logprobGateUsable: Bool { style == .base }
    /// Models whose recommended style is base run instruct as "answer the text"
    /// (~0% first-word measured) — warn if the user forces it.
    var instructUnusable: Bool { !ModelCatalog.instructCompletes(modelID) }
    var isAppleIntelligence: Bool { modelID == ModelCatalog.appleIntelligenceID }
    var selectedModelName: String {
        ModelCatalog.option(for: modelID)?.title ?? (modelID as NSString).lastPathComponent
    }

    // MARK: Live projection — measured expectations for the current configuration

    /// The committed configuration as a pure value, for `ConfigProjection`.
    var committedConfig: ProjectionConfig {
        ProjectionConfig(modelID: modelID, style: style, length: length,
                         logprobGate: logprobGate,
                         useRecommended: useRecommended)
    }
    /// What the committed configuration measures to — the toggle read off
    /// the store, so the rail redraws when it flips.
    var projection: ConfigProjection { .project(committedConfig, pleFromDisk: pleFromDisk) }
    /// The hovered change applied to the committed config, cascades included.
    var previewedConfig: ProjectionConfig? {
        preview.map(committedConfig.applying)
    }

    /// "MiniCPM5 1B · Base · Short · Confident-only" — what is running now.
    var setupLine: String {
        if apiText.enabled { return String(localized: "API · \(apiText.preset.name) · \(apiText.model)") }
        var parts = [ModelMetrics.metrics(for: modelID)?.shortName ?? selectedModelName]
        if !isAppleIntelligence { parts.append(style.label) }
        parts.append(length.label)
        if logprobGate { parts.append(String(localized: "Confident-only")) }
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
    var pendingDownload: PendingDownload?

    /// Catalog rows whose click would download weights first — refreshed with
    /// the disk figures, off the main actor (see `refreshModelDiskUsage`).
    var needsDownload: Set<String> = []

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
    /// anything already here (Apple Intelligence always is) commits at once.
    /// Returns whether `commit` ran now.
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
            controller?.engineCoordinator.apply(.model(id))
            resync()
        }
    }

    /// Commit an exact configuration in one shot (presets and map dots land
    /// here): one coordinator call, one engine rebuild — replaying it through
    /// the per-field didSets would rebuild the engine per field.
    func applyConfig(_ target: ProjectionConfig) {
        guard target != committedConfig else { return }
        gateDownload(target) { [weak self] in
            self?.controller?.engineCoordinator.apply(target)
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
        pickApps(prompt: String(localized: "Disable Pretype Here"),
                 message: String(localized: "Choose applications where Pretype should stay silent.")) { [weak self] urls in
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

    /// Exact bundle IDs, unlike the blacklist's fragments — the menu toggle
    /// matches exactly. Re-seeded from the live list for the same reason.
    func addDictationSendApp() {
        pickApps(prompt: String(localized: "Press Return Here"),
                 message: String(localized: "Choose applications where a dictation ends with Return.")) { [weak self] urls in
            var live = Settings.dictationSendApps
            for id in urls.compactMap({ Bundle(url: $0)?.bundleIdentifier?.lowercased() }) where !live.contains(id) {
                live.append(id)
            }
            self?.dictationSendApps = live
        }
    }

    func removeDictationSendApp(_ entry: String) {
        dictationSendApps = Settings.dictationSendApps.filter { $0 != entry }
    }

    /// Add an app for a per-app persona line via the standard app-picker
    /// panel; keys by exact lowercased bundle ID (the engines match exactly —
    /// unlike the blacklist's substring markers, instructions shouldn't leak
    /// into look-alike apps).
    func addPerAppInstructionApp() {
        pickApps(prompt: String(localized: "Add Instructions"),
                 message: String(localized: "Choose applications that get their own style instructions.")) { [weak self] urls in
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

    /// Add a website with its own style lines (used instead of its browser's
    /// while typing on it): one address field, as a sheet.
    func addPerSiteInstruction() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Add a Website")
        alert.informativeText = String(localized: "Its style lines replace the browser's while you type on it. A domain covers its subdomains — google.com includes mail.google.com.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "mail.google.com"
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Add"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        Self.present(alert) { [weak self] in
            guard let self, let host = Self.host(fromTyped: field.stringValue) else { return }
            let key = AppPolicy.siteEntry(host)
            if perAppInstructions[key] == nil { perAppInstructions[key] = PerAppPresets.template(for: key) ?? "" }
        }
    }

    /// "https://www.Mail.Google.com/inbox" → "mail.google.com"; nil unless it
    /// names a dotted host.
    static func host(fromTyped text: String) -> String? {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !typed.isEmpty,
              var host = URL(string: typed.contains("://") ? typed : "https://" + typed)?.host,
              host.contains(".") else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    /// The standard app picker, opened on /Applications.
    private func pickApps(prompt: String, message: String, picked: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = prompt
        panel.message = message
        Self.run(panel, picked: picked)
    }

    // MARK: Permission flows and sheets

    /// Turn screen-context OCR on or off. Enabling it without permission
    /// explains what is needed first, as a sheet; only on "Open System
    /// Settings" does it register the app with TCC and open the Screen
    /// Recording pane — and it doesn't pull Pretype back in front after,
    /// which raced System Settings for the user's attention.
    private func setScreenContext(_ enable: Bool) {
        Settings.screenContextEnabled = enable
        guard enable, !ScreenContext.hasPermission else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Screen Recording permission")
        alert.informativeText = String(localized: """
        Screen context reads the window you're typing in, on this Mac, and macOS \
        asks for Screen Recording permission for that. Enable Pretype in System \
        Settings → Privacy & Security → Screen Recording, then quit and relaunch \
        Pretype — macOS applies this permission only at app launch.
        """)
        alert.addButton(withTitle: String(localized: "Open System Settings"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        Self.present(alert) { ScreenContext.openScreenRecordingPane() }
    }

    /// Turn hold-to-talk dictation on or off. Enabling asks for the microphone
    /// the first time; a refusal — just now, or earlier, which macOS never asks
    /// about twice — can only be undone in System Settings, so that case snaps
    /// the switch back, says so and offers the pane instead of leaving a switch
    /// that flips and does nothing.
    private func setDictation(_ enable: Bool) {
        guard enable else {
            Settings.dictationEnabled = false
            return
        }
        Task { @MainActor [weak self] in
            let granted = await MicrophoneAccess.request()
            Settings.dictationEnabled = granted
            guard !granted else { return }
            self?.quietly { self?.dictation = false }
            let alert = NSAlert()
            alert.messageText = String(localized: "Pretype needs the microphone")
            // The same split as the toggle's subtitle: "nothing leaves your
            // computer" is false the moment a hosted speech API is on.
            let audio = Settings.apiAudio
            alert.informativeText = audio.enabled && !audio.isLocal
                ? String(localized: """
                Dictation types what you say into the field you're in, transcribed by \
                your API provider. Nothing is recorded to disk.

                Allow Pretype under System Settings → Privacy & Security → Microphone, \
                then switch dictation on again.
                """)
                : String(localized: """
                Dictation transcribes what you say on this Mac and types it into the field \
                you're in. Nothing is recorded to disk and nothing leaves your computer.

                Allow Pretype under System Settings → Privacy & Security → Microphone, \
                then switch dictation on again.
                """)
            alert.addButton(withTitle: String(localized: "Open System Settings"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            Self.present(alert) {
                if let url = MicrophoneAccess.settingsURL { NSWorkspace.shared.open(url) }
            }
        }
    }

    /// The Settings window, for sheets — nil once it has closed.
    private static var settingsWindow: NSWindow? {
        NSApp.windows.first {
            $0.isVisible && $0.contentViewController is NSHostingController<SettingsRootView>
        }
    }

    /// `alert` as a sheet on the Settings window (app-modal only if that is
    /// gone); `confirmed` runs on its first button.
    private static func present(_ alert: NSAlert, confirmed: @escaping () -> Void) {
        guard let window = settingsWindow else {
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { confirmed() }
            return
        }
        alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { confirmed() } }
    }

    /// `panel` as a sheet on the Settings window (app-modal only if that is
    /// gone); `picked` gets the chosen URLs on OK.
    private static func run(_ panel: NSOpenPanel, picked: @escaping ([URL]) -> Void) {
        guard let window = settingsWindow else {
            if panel.runModal() == .OK { picked(panel.urls) }
            return
        }
        panel.beginSheetModal(for: window) { if $0 == .OK { picked(panel.urls) } }
    }

    /// Offer this app's (or site's) style to everyone: explain, then open it
    /// prefilled on GitHub as a new AppStyles file.
    func shareStyle(_ key: String, name: String) {
        guard let text = perAppInstructions[key], let url = PerAppPresets.shareURL(key: key, name: name, text: text)
        else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Share Your Style for \(name)?")
        alert.informativeText = String(localized: "GitHub opens in your browser with this style ready to propose to Pretype. Everyone who uses \(name) can then add it in one click, so check it says nothing personal. Nothing is sent until you submit it there (a free GitHub account is needed).")
        alert.addButton(withTitle: String(localized: "Open GitHub"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        Self.present(alert) { NSWorkspace.shared.open(url) }
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
        panel.prompt = String(localized: "Import")
        panel.message = String(localized: "Choose plain-text or Markdown files you wrote — Pretype learns your phrasing from them.")
        Self.run(panel) { [weak self] urls in self?.importTextFiles(urls) }
    }

    private func importTextFiles(_ urls: [URL]) {
        importing = true
        importStatus = String(localized: "Importing…")
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
                ? String(localized: "Nothing to import — the files were empty, or not UTF-8 text.")
                : files == 1
                ? String(localized: "Imported \(rows) passages from \(files) file.")
                : String(localized: "Imported \(rows) passages from \(files) files.")
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
        // Latest request wins: a delete and the resync after a model switch
        // each start one, and an older scan finishing last would put back
        // figures (and "↓" badges) for a state that has since moved on.
        diskScanSeq += 1
        let seq = diskScanSeq
        Task.detached {
            var sizes: [String: Int64] = [:]
            for id in ids {
                let bytes = ModelStorage.deletableRepos(for: id, selected: selected)
                    .compactMap(ModelStorage.cacheDirectory(repo:))
                    .reduce(Int64(0)) { $0 + ModelStorage.bytes(at: $1) }
                if bytes > 0 { sizes[id] = bytes }
            }
            let measured = sizes
            let missing = Set(targets.filter { !ModelStorage.isFetched($0.1) }.map(\.0))
            await MainActor.run {
                guard self.diskScanSeq == seq else { return }
                if self.modelDiskBytes != measured { self.modelDiskBytes = measured }
                if self.needsDownload != missing { self.needsDownload = missing }
            }
        }
    }
    @ObservationIgnored private var diskScanSeq = 0

    func deleteDownload(_ id: String) {
        for repo in ModelStorage.deletableRepos(for: id, selected: modelID) {
            try? ModelStorage.delete(repo: repo)
        }
        refreshModelDiskUsage()
    }

    /// A load or download is in flight — deleting now would race the writer.
    /// Keyed on `isLoading`, not `state`: the idle-unloaded resting state also
    /// reports `.preparing`, and gating on that would disable deletion exactly
    /// when it is safest (nothing loaded, nothing writing). Polled by the
    /// status timer and published only when it flips.
    private(set) var engineBusy = false

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
        dictationLanguage = Settings.dictationLanguage
        dictationParakeet = Settings.dictationParakeet
        dictationInput = Settings.dictationInput
        apiText = Settings.apiText
        apiAudio = Settings.apiAudio
        blacklist = Settings.userBlacklist
        dictationSendApps = Settings.dictationSendApps
        useRecommended = Settings.useRecommendedSettings
        style = Settings.completionStyle
        length = Settings.completionLength
        // Mask inapplicable persisted flags: a gate restored from a state the
        // coordinator's hygiene never saw must not render as
        // on-but-doing-nothing.
        logprobGate = Settings.logprobGate && style == .base
        personalization = Settings.personalizationLevel == .on
        journalEnabled = Settings.suggestionJournalEnabled
        instructions = Settings.customInstructions
        perAppInstructions = Settings.perAppInstructions
        screenContext = Settings.screenContextEnabled
        loginStatus = LoginItem.status  // the user may have flipped it in System Settings
        accuracyAxis = Settings.accuracyAxis
        settingsMapMode = Settings.settingsMapMode
        modelsAsMap = Settings.modelsAsMap
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

    /// Assign only on change: this runs on a 1 s timer, and an `@Observable`
    /// set notifies its readers even when the value is the same — enough to
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
