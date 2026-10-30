import AppKit
import SwiftUI

/// The Model tab: one card per goal picks a model and its settings in a
/// click; the precision cards show the confidence gate's trade as two bars;
/// every model is one section, as a ranked list (accuracy, speed and memory
/// as bars, longer = better) or as a map. Under Advanced: style tuning and
/// memory. Every figure is a real eval run (see `ModelMetrics`).
struct ModelTab: View {
    @Bindable var store: SettingsStore
    /// Catalog id awaiting delete confirmation. Local @State: it changes on a
    /// click, not on pointer movement, but it still has no business on the store.
    @State private var confirmingDelete: String?
    /// Which task the map plots. Local @State — a lens, not a setting: it
    /// changes on a click and resets to completions with the window.
    @State private var mapLens = MapLens.completion
    @AppStorage("idleUnloadMinutes") private var idleUnloadMinutes = Settings.idleUnloadMinutes
    @AppStorage("showAdvancedSettings") private var showAdvanced = false
    /// The accuracy axis every surface on this tab reads ("*" = all
    /// languages, "core" = EN+RU pooled, or one language) — one
    /// store-persisted selection, so cards, map, ranking and the picker
    /// always tell the same story.
    private var axis: String { store.effectiveAxis }

    var body: some View {
        Form {
            if store.apiText.enabled {
                Section {
                    LabeledContent {
                        Button("Open API Settings") { store.activeTab = .api }
                    } label: {
                        Text("Text runs on \(store.apiText.preset.name)")
                        Text("The model below runs again when the API is off.")
                    }
                }
            }
            // With no suggestion asking it, the model works only for the
            // chords: the pane says so first, and measures it by them.
            if store.chordsOnly, !store.apiText.enabled {
                Section {
                    LabeledContent {
                        Button(store.suggestions ? "Use Sentences" : "Turn On Suggestions") {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                if store.suggestions { store.suggestionMode = .sentences } else { store.suggestions = true }
                            }
                        }
                    } label: {
                        IconLabel(symbol: "textformat.abc.dottedunderline", tint: .pink,
                                  title: Text("No suggestion uses the model"),
                                  subtitle: idleUnloadMinutes > 0
                                      ? Text("It loads for a fix, a reply or a dictation clean-up, and frees its memory after \(idleUnloadMinutes) min idle.")
                                      : Text("It loads for a fix, a reply or a dictation clean-up, and then stays loaded."))
                    }
                }
            }
            Section {
                HStack(spacing: 10) {
                    ForEach(store.shownPriorities, id: \.self) { priority in
                        let pick = store.pick(priority)
                        PriorityCard(priority: priority, pick: pick,
                                     acc: ModelMetrics.axisAccuracy(for: pick, axis: axis),
                                     chords: store.chordsOnly
                                        ? ChordProjection.project(store.committedConfig.applying(.preset(pick)),
                                                                  pleFromDisk: store.pleFromDisk)
                                        : nil,
                                     isActive: store.priorityIsActive(priority),
                                     apply: { store.applyPriority(priority) },
                                     hover: { store.setHover(.preset(pick), $0) },
                                     pleFromDisk: store.pleFromDisk)
                    }
                }
                // Ideal height of the tallest card, which the others then fill.
                .fixedSize(horizontal: false, vertical: true)
            } header: {
                // The axis steers everything under it — these cards, the
                // list and the map — so it heads the first section. The
                // chords have no figures per language.
                HStack {
                    Text("What matters most")
                    Spacer()
                    if !store.chordsOnly {
                        axisPicker
                    }
                }
            }

            // The gate reads the base model's own confidence: Instruct and
            // Apple Intelligence have none to read, so the choice leaves
            // with them — and with the suggestions it gates.
            if !store.chordsOnly, store.logprobGateUsable, !store.isAppleIntelligence {

                Section {
                    HStack(spacing: 12) {
                        GateCard(store: store, on: false)
                        GateCard(store: store, on: true)
                    }
                } header: {
                    Text("How often to suggest")
                }
            }

            // Style and memory tune the pick above; the full catalog, the
            // longest section, goes last so nothing hides under it.
            if showAdvanced {
                advanced
            }

            Section {
                if store.modelsAsMap {
                    map
                } else if store.chordsOnly {
                    fixerList
                } else {
                    list
                }
            } header: {
                HStack {
                    Text("All models")
                    Spacer()
                    // Two views of one choice: the list carries downloads and
                    // deletes, the map shows the trade at a glance. The
                    // segments are AppKit's and announce their image's own
                    // description: an .accessibilityLabel or a Label title
                    // never reaches them, and VoiceOver read "Scatter plot
                    // with dots".
                    Picker("View", selection: $store.modelsAsMap) {
                        Image(nsImage: Self.segmentIcon("list.bullet", String(localized: "List"))).tag(false)
                        Image(nsImage: Self.segmentIcon("chart.dots.scatter", String(localized: "Map"))).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help(store.modelsAsMap ? Text("Map") : Text("List"))
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            store.refreshModelDiskUsage()
            if store.chordsOnly { mapLens = .fix }
        }
        .onChange(of: store.chordsOnly) { mapLens = store.chordsOnly ? .fix : .completion }
        // A download can finish while the window sits in the background; without
        // this the figures read stale the moment the user comes back to them.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshModelDiskUsage()
        }
        .confirmationDialog("Delete the downloaded files for this model?",
                            isPresented: Binding(get: { confirmingDelete != nil },
                                                 set: { if !$0 { confirmingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let id = confirmingDelete { store.deleteDownload(id) }
                confirmingDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmingDelete = nil }
        } message: {
            Text("Frees \(ByteCountFormatter.string(fromByteCount: store.modelDiskBytes[confirmingDelete ?? ""] ?? 0, countStyle: .file)). Picking this model again downloads it over the network.")
        }
    }

    /// "Accuracy in": the language every completion figure is shown for.
    private var axisPicker: some View {
        Picker("Accuracy in", selection: $store.axisSelection) {
            Text("All languages").tag("*")
            // Only while the figures are on it (the settings map).
            if axis == "core" {
                Text(ModelMetrics.axisDisplayName("core")).tag("core")
            }
            Divider()
            ForEach(ModelMetrics.evalLanguages, id: \.self) { code in
                Text(ModelMetrics.axisDisplayName(code)).tag(code)
            }
        }
        .pickerStyle(.menu)
        .fontWeight(.regular)
        .fixedSize()
    }

    /// The list while the model serves only the chords: one row per model
    /// the fixes run on, best fixes first. Catalog entries that share one
    /// are one choice here — the selected one, else the recommended, else
    /// the one of the fixer's own family, else the lightest stands for them.
    @ViewBuilder private var fixerList: some View {
        FixerRow.ColumnHeader()
        ForEach(fixerRows, id: \.id) { row in
            FixerRow(title: row.title, fixer: row.fixer, also: row.also, chords: row.chords,
                     isSelected: row.members.contains(store.modelID),
                     isRecommended: row.members.contains(ModelCatalog.defaultID),
                     downloadGB: store.needsDownload.contains(row.id) ? row.chords.ramGB : nil,
                     select: { store.selectModel(row.id) },
                     hover: { store.setHover(.model(row.id), $0) })
        }
    }

    private var fixerRows: [(id: String, title: String, fixer: String, also: [String], members: [String], chords: ChordProjection)] {
        let entries: [(id: String, title: String)] = ModelCatalog.options.map { ($0.id, $0.title) }
            + [(ModelCatalog.appleIntelligenceID, String(localized: "Apple Intelligence — system model"))]
        // Grouped by the model a click would fix with: the entry's own
        // recommended style, as on the completion list.
        let groups = Dictionary(grouping: entries) { entry in
            ModelMetrics.taskMetrics(for: entry.id, style: ModelCatalog.recommended(for: entry.id).style)?.measuredID ?? entry.id
        }
        let rows = groups.map { fixer, members in
            let ids = members.map(\.id)
            let fixerName = ModelMetrics.taskModelNames[fixer] ?? ""
            let rep = ids.contains(store.modelID) ? store.modelID
                : ids.contains(ModelCatalog.defaultID) ? ModelCatalog.defaultID
                : ids.first { id in ModelMetrics.metrics(for: id).map { fixerName.hasPrefix($0.shortName) } ?? false }
                ?? ids.min { (ModelMetrics.metrics(for: $0)?.ramGB ?? .infinity) < (ModelMetrics.metrics(for: $1)?.ramGB ?? .infinity) } ?? ids[0]
            let chords = ChordProjection.project(store.committedConfig.applying(.model(rep)), pleFromDisk: store.pleFromDisk)
            return (id: rep,
                    title: members.first { $0.id == rep }?.title ?? rep,
                    fixer: chords.fixerName ?? ModelMetrics.taskModelNames[fixer] ?? "",
                    also: members.filter { $0.id != rep }.map { ModelMetrics.metrics(for: $0.id)?.shortName ?? $0.title },
                    members: ids, chords: chords)
        }
        return rows.sorted { a, b in
            switch (a.chords.fixPct, b.chords.fixPct) {
            case let (x?, y?) where x != y: return x > y
            case (.some, .none): return true
            case (.none, .some): return false
            default: return (a.chords.p50Ms ?? .max) < (b.chords.p50Ms ?? .max)
            }
        }
    }

    /// The ranked rows: every model with its bars, download size and trash,
    /// under one header naming the columns.
    @ViewBuilder private var list: some View {
        ModelRow.ColumnHeader()
        ForEach(rankedEntries, id: \.id) { entry in
            ModelRow(id: entry.id, title: entry.title,
                     isSelected: store.modelID == entry.id,
                     select: { store.selectModel(entry.id) },
                     hover: { store.setHover(.model(entry.id), $0) },
                     langAccuracy: langAccuracy(for: entry.id),
                     // Only deletable weights get a figure (the selected
                     // model and its rewrite siblings are excluded at the
                     // source), so the trash can't appear on the row a
                     // click just made undeletable.
                     diskBytes: store.modelDiskBytes[entry.id],
                     delete: { confirmingDelete = entry.id },
                     deleteDisabled: store.engineBusy,
                     downloadGB: downloadGB(for: entry.id),
                     heavyGB: heavyGB(for: entry.id),
                     pleFromDisk: store.pleFromDisk)
        }
    }

    /// The same models as a map: accuracy up, speed right, bubble = memory.
    @ViewBuilder private var map: some View {
        // The two chord tasks run on a different, smaller set of models (the
        // instruct siblings), so they are a lens on the map rather than extra
        // bubbles — same axes, different task.
        HoverSegments(title: String(localized: "Map task"), options: [
            (MapLens.completion, String(localized: "Completions")),
            (MapLens.fix, String(localized: "Fix")),
            (MapLens.reply, String(localized: "Reply")),
        ], selection: mapLens, select: { mapLens = $0 })
        ModelMapView(store: store, lens: mapLens)
        // The language picker stays live: picking a language turns this off
        // (see SettingsStore.axisSelection), so the control the user reaches
        // for is the one that answers. The list ignores it (effectiveAxis).
        // Settings dots are completion settings: none while the model only fixes.
        if !store.chordsOnly {
            settingsOnMap
        }
    }

    private var settingsOnMap: some View {
        Toggle(isOn: $store.settingsMapMode) {
            Text("Show settings on the map")
            if store.settingsMapMode {
                Text("Measured on English and Russian.")
            }
        }
        .help("Plots this model's other settings on the map. They were measured on English and Russian together, so the whole tab switches to that sample.")
    }

    /// Style tuning and memory: the cards and the models above pick a model
    /// and its settings in one click.
    @ViewBuilder private var advanced: some View {
        // Style and length shape suggestions; while none uses the model,
        // the fix model is what stays, picked by the cards and the list.
        if !store.chordsOnly {
            TuningSection(store: store)
        }

        Section("Memory") {
            Picker(selection: $idleUnloadMinutes) {
                Text("Never").tag(0)
                Text("After 1 minute").tag(1)
                Text("After 5 minutes").tag(5)
                Text("After 15 minutes").tag(15)
                Text("After 30 minutes").tag(30)
            } label: {
                Text("Free memory when idle")
                // The rail's Memory figure: less what the table on disk already freed.
                if idleUnloadMinutes > 0, let gb = store.chordsOnly ? store.chordProjection.ramGB : store.projection.ramGB, gb > 0 {
                    Text("Frees about \(oneDecimal(gb)) GB while unused.")
                }
            }
            .help("The next keystroke reloads the model from disk; switching to a text field pre-warms it.")
            if let savingGB = HostPLE.savingGB(for: store.chordsOnly
                ? SettingsStore.chordWeights(modelID: store.modelID, style: store.style)
                : store.committedConfig.primaryModelID) {
                Toggle(isOn: $store.pleFromDisk) {
                    Text("Reduce memory use")
                    Text("Frees about \(oneDecimal(savingGB)) GB; suggestions come a few milliseconds later.")
                }
                .help("Reads one of the model's tables from disk instead of keeping it in memory. Suggestions stay exactly the same. On by default on Macs with 16 GB of memory or less.")
            }
        }
    }

    /// An SF Symbol that names itself to VoiceOver as `name`.
    private static func segmentIcon(_ symbol: String, _ name: String) -> NSImage {
        NSImage(systemSymbolName: symbol, accessibilityDescription: name) ?? NSImage()
    }

    /// Download size of what a click on `id` would load, while it isn't on
    /// this Mac yet — the selected row is already loading whatever it needs.
    private func downloadGB(for id: String) -> Double? {
        guard id != store.modelID, store.needsDownload.contains(id) else { return nil }
        let c = store.committedConfig.applying(.model(id))
        let gb = SettingsStore.weights(modelID: c.modelID, style: c.style).gb
        return gb > 0 ? gb : nil
    }

    /// What a click on `id` keeps resident, when that breaks the fit rule the
    /// auto-pick sizes on (`ModelCatalog.isHeavy`) — same figure the rail's
    /// Memory meter previews on hover.
    private func heavyGB(for id: String) -> Double? {
        guard let gb = ConfigProjection.project(store.committedConfig.applying(.model(id))).ramGB,
              ModelCatalog.isHeavy(residentGB: gb) else { return nil }
        return gb
    }

    /// Axis accuracy for a row, with the axis best for bar normalization —
    /// nil on the core axis (rows show the richer headline bars there) and
    /// for unmeasured models.
    private func langAccuracy(for id: String) -> (pct: Int, max: Int)? {
        guard axis != "core",
              let pct = ModelMetrics.axisAccuracy(for: id, axis: axis) else { return nil }
        return (pct, ModelMetrics.axisBest(axis))
    }

    /// Catalog + system model, measured entries ranked best-first, unmeasured
    /// last — comparison-ready order. With a language picked, that language's
    /// "of all" figure ranks first;
    /// the overall comparator breaks its coarse-% ties.
    private var rankedEntries: [(id: String, title: String)] {
        let entries: [(id: String, title: String)] = ModelCatalog.options.map { ($0.id, $0.title) }
            + [(ModelCatalog.appleIntelligenceID, String(localized: "Apple Intelligence — system model"))]
        return entries.sorted { a, b in
            if axis != "core" {
                let la = ModelMetrics.axisAccuracy(for: a.id, axis: axis)
                let lb = ModelMetrics.axisAccuracy(for: b.id, axis: axis)
                if let la, let lb, la != lb { return la > lb }
                if (la == nil) != (lb == nil) { return la != nil }
            }
            switch (ModelMetrics.metrics(for: a.id), ModelMetrics.metrics(for: b.id)) {
            case let (ma?, mb?):
                if ma.firstWordPct != mb.firstWordPct { return ma.firstWordPct > mb.firstWordPct }
                // Coarse-% ties break on logP/char, the tokenizer-fair
                // quality continuum — same rule as the "Most accurate" preset.
                if let la = ma.logProbPerChar, let lb = mb.logProbPerChar, la != lb { return la > lb }
                return ma.p50Ms < mb.p50Ms
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return a.title < b.title
            }
        }
    }
}

// MARK: - Comparison row

/// One selectable model with its three measured axes as labeled bars.
struct ModelRow: View {
    let id: String
    let title: String
    let isSelected: Bool
    let select: () -> Void
    let hover: (Bool) -> Void
    /// When the list is ranked for one language: that language's "of all"
    /// accuracy and the best catalog value in it (for bar normalization).
    var langAccuracy: (pct: Int, max: Int)?
    /// Deletable bytes this model's weights hold in the local cache; nil (the
    /// selected model, its siblings, nothing downloaded) hides the affordance.
    var diskBytes: Int64?
    let delete: () -> Void
    let deleteDisabled: Bool
    /// GB a click downloads first (nil: already on this Mac).
    var downloadGB: Double?
    /// GB a click keeps resident, when that is heavy for this Mac.
    var heavyGB: Double?
    /// `Settings.pleFromDisk`, read off the store so a flip redraws the row.
    let pleFromDisk: Bool
    /// Local hover for the row highlight — the rail preview (`hover`) lands
    /// 500 px away in the inspector, so a highlight at the pointer confirms
    /// the row is live. Kept off the observed store.
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    // The row's .isSelected trait says it; the glyph's name would not.
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .accessibilityHidden(true)
                    Text(title)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .lineLimit(1).truncationMode(.tail)
                    if id == ModelCatalog.defaultID {
                        // Not accent ink on an accent tint: under Graphite that
                        // is grey on grey, and the list's one emphasis read disabled.
                        Text("Recommended")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .foregroundStyle(.secondary)
                            .background(.quaternary, in: Capsule())
                            .help(ModelCatalog.defaultRationale)
                    }
                    if let heavyGB {
                        Text("Heavy for this Mac")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .foregroundStyle(Color.orange.legible)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                            .help("Keeps ~\(oneDecimal(heavyGB)) GB resident — over a quarter of this Mac's \(String(format: "%.0f", ModelCatalog.machineRamGB)) GB, the line the auto-picked model stays under. Everything else you run gets that much less room.")
                    }
                    Spacer()
                    if let downloadGB {
                        let size = gbLabel(downloadGB)
                        Text("↓ \(size)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .help("Not on this Mac yet — picking it downloads about \(size) first, and suggestions pause until it's ready.")
                            .accessibilityLabel("Not downloaded, \(size)")
                    }
                    if let diskBytes {
                        let size = ByteCountFormatter.string(fromByteCount: diskBytes, countStyle: .file)
                        Text("\(size) on disk")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        // Borderless, so the click stays on the trash instead of
                        // also selecting the row (the classic nested-Button fix).
                        // Busy is handled in the action, NOT via .disabled: a
                        // disabled button drops out of hit-testing, so the click
                        // would fall through to the row and *select* the model —
                        // the exact load the gate exists to avoid racing.
                        Button {
                            if !deleteDisabled { delete() }
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                                .foregroundStyle(hovering && !deleteDisabled ? Color.primary : Color.secondary)
                                .opacity(deleteDisabled ? 0.5 : 1)
                        }
                        .buttonStyle(.borderless)
                        .help(deleteDisabled
                            ? Text("The model is loading — deleting is available once it finishes.")
                            : Text("Delete the downloaded weights (\(size), incl. any \(Settings.hotkeyStyle.correctionLabel) rewrite sibling) — picking this model again re-downloads them."))
                        .accessibilityLabel(deleteDisabled
                            ? Text("Delete downloaded \(title) — unavailable while a model loads")
                            : Text("Delete downloaded \(title), frees \(size)"))
                    }
                }
                if let m = ModelMetrics.metrics(for: id) {
                    let gb = HostPLE.residentGB(m.ramGB, of: id, pleFromDisk: pleFromDisk)
                    // Named once by `ColumnHeader`, not under every row.
                    HStack(spacing: Self.columnSpacing) {
                        if let la = langAccuracy {
                            MetricBar(label: String(localized: "Accuracy"), fraction: la.max > 0 ? Double(la.pct) / Double(la.max) : 0,
                                      text: String(localized: "\(la.pct)%"),
                                      color: .green,
                                      help: String(localized: "First word right, staying silent counted as a miss: \(la.pct)% — matched-register cells, ≈280 samples per language (±5 pp), eval-real 2026-07-16. Compare models within this view, not languages against each other."),
                                      showsLabel: false)
                        } else {
                            MetricBar(label: String(localized: "Accuracy"), fraction: Bounds.accuracy(m), text: String(localized: "\(m.firstWordPct)%"),
                                      color: .green,
                                      help: String(localized: "First-word accuracy of shown suggestions: \(m.firstWordPct)% [\(m.ci.lowerBound)–\(m.ci.upperBound)], coverage \(m.coveragePct)% — \(ModelMetrics.evalSource). English and Russian are pooled here; pick either as the axis to see it alone."),
                                      showsLabel: false)
                        }
                        MetricBar(label: String(localized: "Speed"), fraction: Bounds.speed(m), text: String(localized: "\(m.p50Ms) ms"),
                                  color: .blue,
                                  help: String(localized: "Median time per suggestion: \(m.p50Ms) ms, warm — longer bar = faster."),
                                  showsLabel: false)
                        MetricBar(label: String(localized: "Memory"), fraction: Bounds.lightness(gb),
                                  text: gbLabel(gb),
                                  color: .teal,
                                  help: gb > 0
                                    ? String(localized: "Resident weights: \(oneDecimal(gb)) GB — longer bar = lighter.")
                                    : String(localized: "System model — no download, no app memory."),
                                  showsLabel: false)
                        chordFigures
                    }
                    .padding(.leading, 24)
                } else {
                    Text("not measured")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.leading, 24)
                }
            }
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(hovering && !isSelected ? Color.primary.opacity(0.05) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        // The trash sits in the row's label, so VoiceOver reads the row as one
        // element and never reaches it: its delete is the row's action too.
        .accessibilityActions {
            if let diskBytes, !deleteDisabled {
                let size = ByteCountFormatter.string(fromByteCount: diskBytes, countStyle: .file)
                Button { delete() } label: { Text("Delete downloaded \(title), frees \(size)") }
            }
        }
        .onHover { hovering = $0; hover($0) }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    /// The chord figures beside the bars: fix% · reply%, in the task colors
    /// the map lenses use. Resolved at the model's RECOMMENDED settings (what
    /// a click gives you); the selected-model card below re-resolves against
    /// the live style. "—" = sibling not in the task sweep.
    @ViewBuilder private var chordFigures: some View {
        let chord = ModelMetrics.taskMetrics(
            for: id, style: ModelCatalog.recommended(for: id).style)
        HStack(spacing: Self.chordSpacing) {
            if let chord {
                Text("\(chord.m.fixPct)%").foregroundStyle(Color.pink.legible)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(chord.m.replyPct)%").foregroundStyle(Color.purple.legible)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("—").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.caption2.monospacedDigit())
        .frame(width: Self.chordWidth)
        .help(chordHelp(chord))
        // The column names are in the header, which VoiceOver skips.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chord.map { Text(verbatim: "\(String(localized: "Fix")) \($0.m.fixPct)%, \(String(localized: "Reply")) \($0.m.replyPct)%") }
            ?? Text(verbatim: "\(String(localized: "Fix")), \(String(localized: "Reply")): —"))
    }

    static let columnSpacing: CGFloat = 16
    static let chordWidth: CGFloat = 68
    static let chordSpacing: CGFloat = 6

    /// The list's column names, once over the rows instead of under each
    /// bar of each row — laid out like a row's figures so they line up.
    struct ColumnHeader: View {
        var body: some View {
            HStack(spacing: ModelRow.columnSpacing) {
                Text("Accuracy").frame(maxWidth: .infinity, alignment: .leading)
                Text("Speed").frame(maxWidth: .infinity, alignment: .leading)
                Text("Memory").frame(maxWidth: .infinity, alignment: .leading)
                // Own keys: half of chordWidth fits "Korr." but not "Korrektur".
                HStack(spacing: ModelRow.chordSpacing) {
                    Text(String(localized: "Fix (column)", defaultValue: "Fix",
                                comment: "Model list: header over each model's fix score, about 5 letters wide. Abbreviate."))
                        .foregroundStyle(Color.pink.legible)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(String(localized: "Reply (column)", defaultValue: "Reply",
                                comment: "Model list: header over each model's reply score, about 5 letters wide. Abbreviate."))
                        .foregroundStyle(Color.purple.legible)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: ModelRow.chordWidth)
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.leading, 24)
            .accessibilityHidden(true)  // each row's figures name themselves
        }
    }

    private func chordHelp(
        _ chord: (m: ModelMetrics.TaskMetrics, runsOn: String, measuredID: String)?) -> String {
        guard let c = chord else {
            return String(localized: "The fix and reply chords for this model aren't measured by the task eval yet.")
        }
        return String(localized: "The fix and reply chords run on \(c.runsOn): \(c.m.fixPct)% of noisy lines restored exactly [\(c.m.fixCI.lowerBound)–\(c.m.fixCI.upperBound)] and \(c.m.replyPct)% of reply drafts on topic [\(c.m.replyCI.lowerBound)–\(c.m.replyCI.upperBound)] — totals over 17/19 languages at this model's recommended settings; they don't follow the language picker. \(ModelMetrics.taskSource).")
    }

    /// Normalization bounds across the measured catalog, so bar lengths are
    /// comparable between rows. Longer bar = better on every axis.
    private enum Bounds {
        static let maxAccuracy = Double(ModelMetrics.all.map(\.firstWordPct).max() ?? 100)
        static let minP50 = Double(ModelMetrics.all.map(\.p50Ms).min() ?? 1)
        static let minRam = ModelMetrics.all.map(\.ramGB).filter { $0 > 0 }.min() ?? 1

        static func accuracy(_ m: ModelMetrics) -> Double { Double(m.firstWordPct) / maxAccuracy }
        static func speed(_ m: ModelMetrics) -> Double { minP50 / Double(m.p50Ms) }
        static func lightness(_ gb: Double) -> Double { gb > 0 ? minRam / gb : 1 }
    }
}

// MARK: - Fix model row

/// One model the chords run on, while the model serves only them: the
/// catalog entry a click picks, the fix model behind it — and the other
/// entries sharing that model, which a click there would give the same —
/// with what the chords measure as bars.
struct FixerRow: View {
    let title: String
    let fixer: String
    let also: [String]
    let chords: ChordProjection
    let isSelected: Bool
    let isRecommended: Bool
    /// GB the first fix downloads (nil: already on this Mac).
    var downloadGB: Double?
    let select: () -> Void
    let hover: (Bool) -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .accessibilityHidden(true)
                    Text(title)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .lineLimit(1).truncationMode(.tail)
                    if isRecommended {
                        Text("Recommended")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .foregroundStyle(.secondary)
                            .background(.quaternary, in: Capsule())
                    }
                    Spacer()
                    if let downloadGB {
                        let size = gbLabel(downloadGB)
                        Text("↓ \(size)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .help("Not on this Mac yet — the first fix or reply downloads about \(size).")
                            .accessibilityLabel("Not downloaded, \(size)")
                    }
                }
                if !fixer.isEmpty {
                    (also.isEmpty ? Text("Fixes with \(fixer)")
                                  : Text("Fixes with \(fixer) · also \(also.formatted(.list(type: .and)))"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.leading, 24)
                }
                if chords.fixPct != nil {
                    HStack(spacing: ModelRow.columnSpacing) {
                        MetricBar(label: String(localized: "Fixed right"), fraction: chords.fixFraction ?? 0,
                                  text: chords.fixText, color: .pink,
                                  help: String(localized: "Typo lines restored exactly — \(ModelMetrics.taskSource)."),
                                  showsLabel: false)
                        MetricBar(label: String(localized: "Reply on topic"), fraction: chords.replyFraction ?? 0,
                                  text: chords.replyText, color: .purple,
                                  help: String(localized: "Reply drafts a judge rates on topic — \(ModelMetrics.taskSource)."),
                                  showsLabel: false)
                        MetricBar(label: String(localized: "Speed"), fraction: chords.speedFraction ?? 0,
                                  text: chords.latencyText, color: .blue,
                                  help: String(localized: "Median time per fix, warm — longer bar = faster."),
                                  showsLabel: false)
                        MetricBar(label: String(localized: "Memory"), fraction: chords.memoryFraction ?? 0,
                                  text: chords.memoryText, color: .teal,
                                  help: String(localized: "Held only while it works — longer bar = lighter."),
                                  showsLabel: false)
                    }
                    .padding(.leading, 24)
                } else {
                    Text("not measured")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.leading, 24)
                }
            }
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(hovering && !isSelected ? Color.primary.opacity(0.05) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .onHover { hovering = $0; hover($0) }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    /// The columns, named once over the rows.
    struct ColumnHeader: View {
        var body: some View {
            HStack(spacing: ModelRow.columnSpacing) {
                Text("Fixed right").foregroundStyle(Color.pink.legible).frame(maxWidth: .infinity, alignment: .leading)
                Text("Reply on topic").foregroundStyle(Color.purple.legible).frame(maxWidth: .infinity, alignment: .leading)
                Text("Speed").frame(maxWidth: .infinity, alignment: .leading)
                Text("Memory").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.leading, 24)
            .accessibilityHidden(true)  // each row's figures name themselves
        }
    }
}

// MARK: - Precision cards

/// One side of the confidence gate as two bars — how often a suggestion
/// shows, and how often a shown one is right — from the same projection the
/// Live Impact rail reads. Side by side, the cards show the trade: one long
/// bar swaps for the other.
private struct GateCard: View {
    @Bindable var store: SettingsStore
    let on: Bool
    /// Local hover for the card highlight, kept off the observed store.
    @State private var hovering = false

    var body: some View {
        var config = store.committedConfig
        config.logprobGate = on
        let p = ConfigProjection.project(config)
        let cov = p.coveragePct ?? 0, acc = p.accuracyPct ?? 0
        let isSelected = store.logprobGate == on
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) { store.logprobGate = on }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    (on ? Text("Only when sure") : Text("More often"))
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    SelectionMark(isOn: isSelected)
                }
                MetricBar(label: String(localized: "Suggests"), fraction: Double(cov) / 100,
                          text: String(localized: "\(cov)%"), color: .indigo,
                          help: String(localized: "Suggests \(cov)% of the time · \(acc)% right"))
                MetricBar(label: String(localized: "Right when shown"), fraction: Double(acc) / 100,
                          text: String(localized: "\(acc)%"), color: .green,
                          help: String(localized: "Suggests \(cov)% of the time · \(acc)% right"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .choiceCard(isSelected: isSelected, hovering: hovering)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(on ? Text("Only when sure") : Text("More often"))
        .accessibilityValue(Text("Suggests \(cov)% of the time · \(acc)% right"))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .onHover { hovering = $0; store.setHover(.logprobGate(on), $0) }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Priority presets

/// One "what matters most" card: goal on top, the measured landing spot below
/// (model + its three figures), check ring when the pipeline is already there.
/// `pick`/`acc` come from the tab's accuracy axis, so the card re-resolves
/// when the axis changes — "Most accurate" is per-language.
private struct PriorityCard: View {
    let priority: ModelPriority
    let pick: String
    let acc: Int?
    /// While the model serves only the chords: what they measure on `pick`,
    /// shown instead of the completion figures.
    var chords: ChordProjection?
    let isActive: Bool
    let apply: () -> Void
    let hover: (Bool) -> Void
    let pleFromDisk: Bool
    /// Local hover for the card highlight — kept off the store the Form
    /// observes, unlike the rail-preview `hover` callback below.
    @State private var hovering = false

    var body: some View {
        Button(action: apply) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    SettingsIcon(symbol: priority.symbol, tint: priority.tint)
                    // Wraps rather than shrinking below the caption floor:
                    // "Quick & accurate" overflows a card at the minimum width.
                    Text(priority.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    SelectionMark(isOn: isActive)
                }
                if let chords, let m = ModelMetrics.metrics(for: pick) {
                    Text(m.shortName)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    figures(Text(chords.fixText).foregroundStyle(Color.pink.legible),
                            Text(chords.latencyText).foregroundStyle(Color.blue.legible),
                            Text(chords.memoryText).foregroundStyle(Color.teal.legible))
                        .help(chords.fixerName.map { Text("Fixes and replies run on \($0).") } ?? Text(verbatim: ""))
                } else if let m = ModelMetrics.metrics(for: pick) {
                    Text(m.shortName)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    // Metric colors match every other surface (rail meters,
                    // ranked bars, map info card) — green accuracy, blue
                    // speed, teal memory — so the triple scans, not reads.
                    figures(Text("\(acc ?? m.firstWordPct)%").foregroundStyle(Color.green.legible),
                            Text("\(m.p50Ms) ms").foregroundStyle(Color.blue.legible),
                            Text(gbLabel(HostPLE.residentGB(m.ramGB, of: pick, pleFromDisk: pleFromDisk)))
                                .foregroundStyle(Color.teal.legible))
                }
            }
            // Full height of the row: a card whose title or figures wrapped
            // must not stand taller than its neighbours.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .choiceCard(isSelected: isActive, hovering: hovering)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
        .help(priority.goal)
        .onHover { hovering = $0; hover($0) }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    /// The card's three figures — quality, speed, memory. One line where it
    /// fits; at the 1020 pt minimum width four cards leave ~96 pt for a
    /// ~113 pt triple, so memory takes a second line instead of the whole
    /// triple shrinking to 8 pt.
    private func figures(_ quality: Text, _ speed: Text, _ memory: Text) -> some View {
        let dot = Text(" · ").foregroundStyle(.tertiary)
        return ViewThatFits(in: .horizontal) {
            Text("\(quality)\(dot)\(speed)\(dot)\(memory)").lineLimit(1)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(quality)\(dot)\(speed)").lineLimit(1)
                memory
            }
        }
        // Semibold, not a color change: tone-colored ink at caption size is
        // thin on a light form, but the metric color coding is deliberate
        // and shared with the rail and ranked bars.
        .font(.system(size: 11, weight: .semibold).monospacedDigit())
    }
}

extension ModelPriority {
    /// The card's tile, in the color of the figure the goal maximizes —
    /// the same green, blue and teal as the bars and the rail.
    var tint: Color {
        switch self {
        case .lightest: return .teal
        case .quick: return .blue
        case .accurate: return .green
        case .balanced: return .purple
        }
    }
}
