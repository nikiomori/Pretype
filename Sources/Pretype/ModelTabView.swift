import AppKit
import SwiftUI

/// The Model tab: one card per goal picks a model and its settings in a
/// click; the precision cards show the confidence gate's trade as dots; the
/// ranked list compares every model — accuracy, speed and memory as
/// at-a-glance bars (longer = better) with the measured numbers beside them.
/// Under Advanced: style tuning, memory and the map. Every figure is a real
/// eval run (see `ModelMetrics`).
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
    /// languages, "core" = EN+RU, or one language) — one store-persisted
    /// selection, so cards, map and ranking always tell the same story.
    private var axis: String { store.effectiveAxis }

    /// Priority cards for the current axis with duplicates collapsed: when two
    /// goals land on the same model (Balanced == Quick & accurate on EN/RU,
    /// where the default is picked to be the fastest at parity) the first in
    /// order wins — so no two cards ever render byte-identical.
    private var distinctPriorities: [ModelPriority] {
        var seen = Set<String>()
        return ModelPriority.allCases.filter { seen.insert($0.pick(axis: axis)).inserted }
    }

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
            Section {
                HStack(spacing: 10) {
                    ForEach(distinctPriorities, id: \.self) { priority in
                        let pick = priority.pick(axis: axis)
                        PriorityCard(priority: priority, pick: pick,
                                     acc: ModelMetrics.axisAccuracy(for: pick, axis: axis),
                                     isActive: store.priorityIsActive(priority),
                                     apply: { store.applyPriority(priority) },
                                     hover: { store.setHover(.preset(pick), $0) },
                                     pleFromDisk: store.pleFromDisk)
                    }
                }
                // Ideal height of the tallest card, which the others then fill.
                .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("What matters most")
            }

            // The gate reads the base model's own confidence: Instruct and
            // Apple Intelligence have none to read, so the choice leaves
            // with them.
            if store.logprobGateUsable, !store.isAppleIntelligence {
                Section {
                    HStack(spacing: 12) {
                        GateCard(store: store, on: false)
                        GateCard(store: store, on: true)
                    }
                } header: {
                    Text("How often to suggest")
                } footer: {
                    let right = Text(verbatim: "●").foregroundStyle(Color.green)
                    let wrong = Text(verbatim: "●").foregroundStyle(Color.secondary.opacity(0.6))
                    let none = Text(verbatim: "○").foregroundStyle(.secondary)
                    Text("Each dot is one pause in your typing: \(right) right, \(wrong) wrong, \(none) nothing shown.")
                }
            }

            Section("All models") {
                Picker("Accuracy in", selection: $store.accuracyAxis) {
                    Text("All languages").tag("*")
                    Divider()
                    ForEach(ModelMetrics.evalLanguages, id: \.self) { code in
                        Text(ModelMetrics.axisDisplayName(code)).tag(code)
                    }
                }
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

            AdvancedRow()
            if showAdvanced {
                advanced
            }
        }
        .formStyle(.grouped)
        .onAppear { store.refreshModelDiskUsage() }
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

    /// Style tuning, memory and the map: the cards and the list above pick a
    /// model and its settings in one click.
    @ViewBuilder private var advanced: some View {
        TuningSection(store: store)

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
                if idleUnloadMinutes > 0, let gb = store.projection.ramGB, gb > 0 {
                    Text("Frees about \(oneDecimal(gb)) GB while unused.")
                }
            }
            .help("The next keystroke reloads the model from disk; switching to a text field pre-warms it.")
            if let savingGB = HostPLE.savingGB(for: store.committedConfig.primaryModelID) {
                Toggle(isOn: $store.pleFromDisk) {
                    Text("Reduce memory use")
                    Text("Frees about \(oneDecimal(savingGB)) GB; suggestions come a few milliseconds later.")
                }
                .help("Reads one of the model's tables from disk instead of keeping it in memory. Suggestions stay exactly the same. On by default on Macs with 16 GB of memory or less.")
            }
        }

        Section {
            // The two chord tasks run on a different, smaller set of
            // models (the instruct siblings), so they are a lens on the
            // map rather than extra bubbles — same axes, different task.
            HoverSegments(title: String(localized: "Map task"), options: [
                (MapLens.completion, String(localized: "Completions")),
                (MapLens.fix, String(localized: "Fix")),
                (MapLens.reply, String(localized: "Reply")),
            ], selection: mapLens, select: { mapLens = $0 })
            ModelMapView(store: store, lens: mapLens)
            // Not disabled while the map is on: picking a language turns the
            // map off (see SettingsStore.accuracyAxis), so the control the
            // user reaches for is the one that answers.
            Toggle(isOn: $store.settingsMapMode) {
                Text("Show settings on the map")
                if store.settingsMapMode {
                    Text("Measured on English and Russian.")
                }
            }
            .help("Plots this model's other settings on the map. They were measured on English and Russian together, so the whole tab switches to that sample.")
        } header: {
            Text("Model map")
        }
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
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
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
                                .foregroundStyle(hovering && !deleteDisabled
                                    ? Color.secondary : Color(nsColor: .tertiaryLabelColor))
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
                    HStack(spacing: 16) {
                        if let la = langAccuracy {
                            MetricBar(label: String(localized: "Accuracy"), fraction: la.max > 0 ? Double(la.pct) / Double(la.max) : 0,
                                      text: String(localized: "\(la.pct)%"),
                                      color: .green,
                                      help: String(localized: "First word right, staying silent counted as a miss: \(la.pct)% — matched-register cells, ≈280 samples per language (±5 pp), eval-real 2026-07-16. Compare models within this view, not languages against each other."))
                        } else {
                            MetricBar(label: String(localized: "Accuracy"), fraction: Bounds.accuracy(m), text: String(localized: "\(m.firstWordPct)%"),
                                      color: .green,
                                      help: String(localized: "First-word accuracy of shown suggestions: \(m.firstWordPct)% [\(m.ci.lowerBound)–\(m.ci.upperBound)], coverage \(m.coveragePct)% — \(ModelMetrics.evalSource). English and Russian are pooled here; pick either as the axis to see it alone."))
                        }
                        MetricBar(label: String(localized: "Speed"), fraction: Bounds.speed(m), text: String(localized: "\(m.p50Ms) ms"),
                                  color: .blue,
                                  help: String(localized: "Median time per suggestion: \(m.p50Ms) ms, warm — longer bar = faster."))
                        MetricBar(label: String(localized: "Memory"), fraction: Bounds.lightness(gb),
                                  text: gbLabel(gb),
                                  color: .teal,
                                  help: gb > 0
                                    ? String(localized: "Resident weights: \(oneDecimal(gb)) GB — longer bar = lighter.")
                                    : String(localized: "System model — no download, no app memory."))
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
        VStack(alignment: .leading, spacing: 3) {
            Text("Fix · Reply").font(.caption2).foregroundStyle(.secondary)
            if let chord {
                let fixText = Text("\(chord.m.fixPct)%").foregroundStyle(Color.orange.legible)
                let dotText = Text(" · ").foregroundStyle(Color.secondary)
                let replyText = Text("\(chord.m.replyPct)%").foregroundStyle(Color.purple.legible)
                Text("\(fixText)\(dotText)\(replyText)")
                    .font(.caption2.monospacedDigit())
            } else {
                Text("—").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 68, alignment: .leading)
        .help(chordHelp(chord))
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

// MARK: - Precision cards

/// One side of the confidence gate: what it does to twenty pauses in your
/// typing — how many get a suggestion, and how many of those are right —
/// drawn as dots, from the same projection the Live Impact rail reads.
private struct GateCard: View {
    @Bindable var store: SettingsStore
    let on: Bool
    /// Local hover for the card highlight, kept off the observed store.
    @State private var hovering = false

    private static let dots = 20

    private enum Dot { case right, wrong, none }

    private func dot(_ kind: Dot) -> some View {
        Circle()
            .fill(kind == .right ? Color.green : kind == .wrong ? Color.secondary.opacity(0.45) : Color.clear)
            .overlay(Circle().strokeBorder(kind == .none ? Color.secondary.opacity(0.45) : Color.clear, lineWidth: 1))
            .frame(width: 9, height: 9)
    }

    var body: some View {
        var config = store.committedConfig
        config.logprobGate = on
        let p = ConfigProjection.project(config)
        let shown = Int((Double(p.coveragePct ?? 0) / 100 * Double(Self.dots)).rounded())
        let right = Int((Double(shown) * Double(p.accuracyPct ?? 0) / 100).rounded())
        let isSelected = store.logprobGate == on
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) { store.logprobGate = on }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                // Two plain rows of ten: a lazy grid inside a form row laid
                // itself out again on every pass and stalled the pane.
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(0..<2, id: \.self) { row in
                        HStack(spacing: 5) {
                            ForEach(row * 10..<row * 10 + 10, id: \.self) { i in
                                dot(i < right ? .right : i < shown ? .wrong : .none)
                            }
                        }
                    }
                }
                HStack {
                    (on ? Text("Only when sure") : Text("More often"))
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                    }
                }
                if let cov = p.coveragePct, let acc = p.accuracyPct {
                    Text("Suggests \(cov)% of the time · \(acc)% right")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor.opacity(0.08)
                      : (hovering ? Color.primary.opacity(0.04) : Color.clear)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.accentColor
                        : (hovering ? Color.primary.opacity(0.22) : Color(nsColor: .separatorColor)),
                        lineWidth: isSelected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(on ? Text("Only when sure") : Text("More often"))
        .accessibilityValue(Text("Suggests \(p.coveragePct ?? 0)% of the time · \(p.accuracyPct ?? 0)% right"))
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
                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                if let m = ModelMetrics.metrics(for: pick) {
                    Text(m.shortName)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    // Metric colors match every other surface (rail meters,
                    // ranked bars, map info card) — green accuracy, blue
                    // speed, teal memory — so the triple scans, not reads.
                    let accText = Text("\(acc ?? m.firstWordPct)%").foregroundStyle(Color.green.legible)
                    let dot = Text(" · ").foregroundStyle(.tertiary)
                    let msText = Text("\(m.p50Ms) ms").foregroundStyle(Color.blue.legible)
                    let gbText = Text(gbLabel(HostPLE.residentGB(m.ramGB, of: pick, pleFromDisk: pleFromDisk)))
                        .foregroundStyle(Color.teal.legible)
                    // One line where it fits; at the 1020 pt minimum width four
                    // cards leave ~96 pt for a ~113 pt triple, so memory takes
                    // a second line instead of the whole triple shrinking to 8 pt.
                    ViewThatFits(in: .horizontal) {
                        Text("\(accText)\(dot)\(msText)\(dot)\(gbText)").lineLimit(1)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(accText)\(dot)\(msText)").lineLimit(1)
                            gbText
                        }
                    }
                    // Semibold, not a color change: tone-colored ink at 10pt
                    // is thin on a light form, but the metric color coding is
                    // deliberate and shared with the rail and ranked bars.
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                }
            }
            .padding(8)
            // Full height of the row: a card whose title or figures wrapped
            // must not stand taller than its neighbours.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(isActive ? Color.accentColor.opacity(0.08)
                          : Color.primary.opacity(hovering ? 0.06 : 0.03)))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(isActive ? Color.accentColor
                            : Color.primary.opacity(hovering ? 0.22 : 0.09),
                            lineWidth: isActive ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
        .help(priority.goal)
        .onHover { hovering = $0; hover($0) }
        .animation(.easeOut(duration: 0.12), value: hovering)
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

// MARK: - Model map

/// What the map plots: the completion catalog, or one of the two chord tasks
/// measured on the instruct siblings.
enum MapLens {
    case completion, fix, reply
}

/// The catalog as a scatter map: accuracy up, speed right (log scale), bubble
/// size = memory. A dashed envelope marks everything the selected model can
/// reach through settings; a solid marker shows where the committed
/// configuration sits and a dashed ghost previews the hovered change. Same
/// `ConfigProjection` figures as the rail — one truth, two views.
/// The fix/reply lenses swap the data source to the five measured siblings
/// (`ModelMetrics.tasks`): task % up, task latency right, sibling memory as
/// bubble size — the settings machinery (envelope, dots, projected ring) is
/// completion-only and hides.
struct ModelMapView: View {
    @Bindable var store: SettingsStore
    let lens: MapLens
    /// Hovered sibling bubble on the chord lenses. Local @State: sibling ids
    /// aren't models the Live Impact rail can preview, so they never touch
    /// the shared hover store.
    @State private var hoveredSibling: String?

    /// Bubbles, envelope and ring translate across ~300pt when the axis or the
    /// model changes — exactly the travel Reduce Motion exists to suppress. A
    /// short curve keeps the change legible without moving anything far.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var mapCurve: Animation? { reduceMotion ? nil : .easeOut(duration: 0.3) }

    /// The tab's accuracy axis. Off the "core" axis the settings machinery
    /// (dots, envelope, config-projected ring) hides: config effects are
    /// measured on the EN+RU sample only, and drawing them against a
    /// different scale would fabricate numbers.
    private var axis: String { store.effectiveAxis }

    /// Where a model's bubble sits on the current axis.
    private func bubbleCenter(for id: String, _ plot: PlotFrame) -> CGPoint {
        guard let m = ModelMetrics.metrics(for: id) else {
            return CGPoint(x: plot.x(ms: 100), y: plot.y(acc: 2))
        }
        let acc = Double(ModelMetrics.axisAccuracy(for: id, axis: axis) ?? m.firstWordPct)
        return CGPoint(x: plot.x(ms: Double(m.p50Ms)), y: plot.y(acc: max(acc, 2)))
    }

    /// Model highlighted by the current preview, whichever surface set it
    /// (bubble, ranked row, preset card or settings dot) — the single hover
    /// source; the map keeps no local hover state of its own.
    private var previewedModelID: String? {
        switch store.preview {
        case .model(let id), .preset(let id): return id
        case .config(let config): return config.modelID
        default: return nil
        }
    }

    private static let height: CGFloat = 300
    private typealias Scale = ConfigProjection.Scale

    /// Accuracy span of the y axis. The core axis keeps the fixed scale that
    /// fits the gated config projections (up to ~67%); on any other axis the
    /// models span a much narrower band (all-language averages sit at 9–23%),
    /// and the fixed scale squeezed every bubble into the bottom fifth — so
    /// the scale fits the plotted data instead, rounded to 5s. The chord
    /// lenses always fit their own values (fix spans 4–69%).
    private var accBounds: (lo: Double, hi: Double) {
        let values: [Double]
        switch lens {
        case .completion:
            guard axis != "core" else { return (Scale.accMin, Scale.accMax) }
            values = ModelMetrics.all.map {
                Double(ModelMetrics.axisAccuracy(for: $0.id, axis: axis) ?? $0.firstWordPct)
            }
        case .fix, .reply:
            values = chordStats.map { Double($0.pct) }
        }
        guard let minV = values.min(), let maxV = values.max() else {
            return (Scale.accMin, Scale.accMax)
        }
        return (max(0, ((minV - 3) / 5).rounded(.down) * 5),
                ((maxV + 4) / 5).rounded(.up) * 5)
    }

    /// Round gridline values for the current span — the coarsest step that
    /// still yields a few lines.
    private func gridValues(lo: Double, hi: Double) -> [Int] {
        let step = [2.0, 5, 10, 20].first { (hi - lo) / $0 <= 4 } ?? 20
        var v = (lo / step).rounded(.up) * step
        var out: [Int] = []
        while v <= hi { out.append(Int(v)); v += step }
        return out
    }

    var body: some View {
        GeometryReader { geo in
            let bounds = accBounds
            let plot = PlotFrame(size: geo.size, accLo: bounds.lo, accHi: bounds.hi,
                                 msRange: lens == .completion ? Scale.msRange : Self.chordMsRange)
            ZStack(alignment: .topLeading) {
                gridAndAxes(plot)
                if lens == .completion {
                    envelope(plot)
                    bubbles(plot)
                    configDots(plot)
                    markers(plot)
                    infoCard
                        .padding(.leading, plot.minX + 6)
                        .padding(.top, 2)
                } else {
                    chordBubbles(plot)
                    chordMarker(plot)
                    // Top-RIGHT, unlike the completion card: both chord
                    // lenses put their best model top-left (accurate = slow
                    // there), exactly where the completion card sits.
                    chordInfoCard
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 12)
                        .padding(.top, 2)
                }
            }
            // Markers and the envelope already glided; the bubbles, labels and
            // gridlines jump-cut around them when the axis rescales. Move the
            // whole chart as one system, on the curve the parts already use.
            .animation(mapCurve, value: store.effectiveAxis)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: store.modelID)
        }
        .frame(height: Self.height)
        // Every element here is a bare Circle with .onTapGesture — no button, no
        // focus, nothing to announce. The ranked list below is the accessible
        // equivalent, so describe the chart and point VoiceOver at the list.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(lens == .completion
            ? Text("Model map — accuracy, speed and memory of every model. Use the ranked list above to choose a model, and the Suggestions section for the style, length and confidence settings the map previews.")
            : lens == .fix
            ? Text("Task map — how well each instruct sibling handles the fix chord, with speed and memory. The Fix and Reply figures in the ranked list below carry the same numbers per model.")
            : Text("Task map — how well each instruct sibling handles the reply chord, with speed and memory. The Fix and Reply figures in the ranked list below carry the same numbers per model."))
    }

    /// Latency span of the chord lenses: fixes and replies run 33–409 ms warm
    /// across the measured siblings (2026-10-15) — on the completion scale
    /// they would bunch into its slow half.
    private static let chordMsRange = 25.0...600.0

    /// Chart coordinates: x = log-speed (faster → right), y = accuracy on the
    /// axis-dependent span.
    private struct PlotFrame {
        let size: CGSize
        let accLo: Double
        let accHi: Double
        var msRange = ConfigProjection.Scale.msRange
        var minX: CGFloat { 38 }
        var maxX: CGFloat { size.width - 12 }
        var minY: CGFloat { 8 }
        var maxY: CGFloat { size.height - 24 }

        func x(ms: Double) -> CGFloat {
            let f = ConfigProjection.Scale.logFraction(ms, in: msRange)
            return minX + (1 - f) * (maxX - minX)
        }
        func y(acc: Double) -> CGFloat {
            let clamped = min(max(acc, accLo), accHi)
            let f = (clamped - accLo) / (accHi - accLo)
            return minY + (1 - f) * (maxY - minY)
        }
    }

    private func radius(_ gb: Double) -> CGFloat {
        gb <= 0 ? 7 : 8 + min(1, gb / Scale.gbMax) * 15
    }

    private func gridAndAxes(_ plot: PlotFrame) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(gridValues(lo: plot.accLo, hi: plot.accHi), id: \.self) { acc in
                let y = plot.y(acc: Double(acc))
                Path { p in
                    p.move(to: CGPoint(x: plot.minX, y: y))
                    p.addLine(to: CGPoint(x: plot.maxX, y: y))
                }
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                Text("\(acc)%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .position(x: plot.minX - 18, y: y)
            }
            Text("◀ slower")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .position(x: plot.minX + 26, y: plot.maxY + 12)
            Text("faster ▶")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.blue.opacity(0.8))
                .position(x: plot.maxX - 26, y: plot.maxY + 12)
            Text(legend)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .position(x: (plot.minX + plot.maxX) / 2, y: plot.maxY + 12)
        }
    }

    /// What up and bubble size mean on this lens — the map's whole legend,
    /// where a paragraph under it used to be. The chord lenses are catalog
    /// totals, so they say they ignore the language picker.
    private var legend: String {
        switch lens {
        case .completion: return String(localized: "↑ accuracy · bubble = memory")
        case .fix: return String(localized: "↑ exact fixes, all languages · bubble = memory")
        case .reply: return String(localized: "↑ replies on topic, all languages · bubble = memory")
        }
    }

    /// One reachable configuration of the selected model — a clickable
    /// settings dot on the map.
    private struct ReachableConfig: Identifiable {
        let label: String
        let config: ProjectionConfig
        var id: String { label }
    }

    /// The settings positions worth plotting for a model: plain base, the
    /// confident-only gate, instruct where usable. Length variants stay off
    /// the map on purpose — they move only on an axis the map doesn't plot
    /// (how far one suggestion runs) and would render as strictly-worse dots
    /// (same accuracy, 2–3.5× slower); the Length control carries that
    /// trade-off with its own one-line footer instead.
    private func reachableConfigs(for id: String) -> [ReachableConfig] {
        guard ModelMetrics.metrics(for: id) != nil else { return [] }
        func cfg(_ style: CompletionStyle, _ length: CompletionLength,
                 logprob: Bool = false) -> ProjectionConfig {
            ProjectionConfig(modelID: id, style: style, length: length,
                             logprobGate: logprob,
                             useRecommended: false)
        }
        if id == ModelCatalog.appleIntelligenceID {
            return [ReachableConfig(label: String(localized: "Short"), config: cfg(.instruct, .short))]
        }
        var out = [ReachableConfig(label: String(localized: "Short"), config: cfg(.base, .short)),
                   ReachableConfig(label: String(localized: "Confident-only"), config: cfg(.base, .short, logprob: true))]
        if ModelCatalog.instructCompletes(id) {
            out.append(ReachableConfig(label: String(localized: "Instruct"), config: cfg(.instruct, .short)))
        }
        return out
    }

    /// Bounding box of the model's canonical configs, stretched to also cover
    /// `including` — the marker for the actual (possibly exotic: gate × long,
    /// explicitly-broken) configuration must never sit outside its own zone.
    private func reachableEnvelope(for id: String, _ plot: PlotFrame,
                                   including extra: CGPoint? = nil) -> CGRect? {
        var points = reachableConfigs(for: id).map { chartPoint(for: $0.config, plot: plot) }
        if let extra { points.append(extra) }
        guard let first = points.first else { return nil }
        var rect = CGRect(origin: first, size: .zero)
        for p in points.dropFirst() { rect = rect.union(CGRect(origin: p, size: .zero)) }
        return rect.insetBy(dx: -14, dy: -14)
    }

    /// Where a configuration lands on the map. Unmeasured latency falls back
    /// to the base model's figure; a broken combination pins to the floor.
    private func chartPoint(for config: ProjectionConfig, plot: PlotFrame) -> CGPoint {
        let projection = ConfigProjection.project(config)
        let fallbackMs = ModelMetrics.metrics(for: config.modelID)?.p50Ms ?? 100
        let acc = Double(projection.accuracyPct ?? 0)
        let ms = Double(projection.p50Ms ?? fallbackMs)
        return CGPoint(x: plot.x(ms: ms), y: plot.y(acc: max(acc, 2)))
    }

    @ViewBuilder private func envelope(_ plot: PlotFrame) -> some View {
        // A single-config model (system model) has no spread — no zone to show.
        if axis == "core",
           let rect = reachableEnvelope(for: store.modelID, plot,
                                        including: chartPoint(for: store.committedConfig, plot: plot)),
           max(rect.width, rect.height) > 60 {
            zone(rect, .primary, lineWidth: 1, dash: [4, 3], opacity: 0.35)
                .animation(mapCurve, value: rect)
            Text("reachable with settings")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.9),
                            in: Capsule())
                // Clamp into the plot: a narrow zone hugging the right edge
                // (Short + gate share one x) must not clip its own label.
                .position(x: min(rect.minX + 62, plot.maxX - 66), y: rect.minY)
                .allowsHitTesting(false)
        }
        // Hovering another model (bubble, ranked row or preset card) ghosts
        // ITS settings zone, so zones compare before committing. Told apart
        // from the current zone by weight, not accent: under Graphite the
        // accent is grey too, and the two zones read as one.
        if axis == "core",
           let previewed = store.previewedConfig, previewed.modelID != store.modelID,
           let rect = reachableEnvelope(for: previewed.modelID, plot,
                                        including: chartPoint(for: previewed, plot: plot)),
           max(rect.width, rect.height) > 60 {
            zone(rect, .primary, lineWidth: 2.5, dash: [5, 3], opacity: 0.7)
        }
    }

    /// A model's settings zone: a dashed, faintly filled box around `rect`.
    private func zone(_ rect: CGRect, _ tint: Color, lineWidth: CGFloat, dash: [CGFloat],
                      opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: 18)
            .strokeBorder(style: StrokeStyle(lineWidth: lineWidth, dash: dash))
            .foregroundStyle(tint.opacity(opacity))
            .background(tint.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
    }

    /// Where a mark's name goes: `offset` below it, flipped above near the
    /// floor and clamped into the plot horizontally — edge marks must not push
    /// their name into the axis labels or out of frame.
    private func labelPosition(_ mark: CGPoint, offset: CGFloat, inset: CGFloat = 34,
                               _ plot: PlotFrame) -> CGPoint {
        let below = mark.y + offset
        return CGPoint(x: min(max(mark.x, plot.minX + inset), plot.maxX - inset),
                       y: below > plot.maxY - 3 ? mark.y - offset : below)
    }

    private func bubbles(_ plot: PlotFrame) -> some View {
        ForEach(ModelMetrics.all, id: \.id) { m in
            let selected = m.id == store.modelID
            let r = radius(HostPLE.residentGB(m.ramGB, of: m.id, pleFromDisk: store.pleFromDisk))
            let center = bubbleCenter(for: m.id, plot)
            // Hover and tap attach BEFORE .position: onHover tracks the
            // view's FRAME, and a positioned wrapper fills the whole plot —
            // eleven overlapping full-plot hover areas, the last one winning.
            ZStack {
                Circle()
                    .fill(selected ? Color.primary : Color.secondary.opacity(0.45))
                // Window-colored, not white: a white rim glared around every
                // bubble in Dark mode.
                Circle()
                    .strokeBorder(selected ? Color.primary : Color(nsColor: .windowBackgroundColor),
                                  style: m.id == ModelCatalog.appleIntelligenceID && !selected
                                      ? StrokeStyle(lineWidth: 1.5, dash: [3, 2])
                                      : StrokeStyle(lineWidth: 1.5))
            }
            .frame(width: 2 * r, height: 2 * r)
            .shadow(color: .black.opacity(selected ? 0.35 : 0.12),
                    radius: selected ? 5 : 2, y: 1)
            .contentShape(Circle())
            // Hovering fed the info card and the rail 500pt away but left the
            // bubble itself unchanged — same 0.12s curve as the rows and cards.
            .scaleEffect(previewedModelID == m.id ? 1.12 : 1)
            .animation(.easeOut(duration: 0.12), value: previewedModelID)
            .onTapGesture { store.selectModel(m.id) }
            .onHover { store.setHover(.model(m.id), $0) }
            .position(center)
            if selected || previewedModelID == m.id {
                Text(m.shortName)
                    .font(.caption2.weight(selected ? .bold : .medium))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .position(labelPosition(center, offset: r + 9, plot))
                    .allowsHitTesting(false)
            }
        }
    }

    /// The other configurations the selected model can be switched into,
    /// right on the map: hover previews, click applies. Accent-tinted hollow
    /// dots — a different species from the gray model bubbles.
    @ViewBuilder private func configDots(_ plot: PlotFrame) -> some View {
        let committed = store.committedConfig
        ForEach(reachableConfigs(for: axis == "core" ? store.modelID : "")) { reachable in
            if !reachable.config.sameRuntime(as: committed) {
                let point = chartPoint(for: reachable.config, plot: plot)
                // Interactivity before .position — see the bubbles comment.
                Circle()
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1.5))
                    .frame(width: 10, height: 10)
                    .contentShape(Circle().inset(by: -4))
                    .help("\(reachable.label) — click to switch this model's settings here")
                    .onTapGesture { store.applyConfig(reachable.config) }
                    .onHover { store.setHover(.config(reachable.config), $0) }
                    .position(point)
                    .zIndex(5)
                if store.preview == .config(reachable.config) {
                    Text(reachable.label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 4)
                        .background(Color(nsColor: .windowBackgroundColor).opacity(0.9),
                                    in: Capsule())
                        .position(labelPosition(point, offset: 13, plot))
                        .zIndex(6)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    /// Where the committed configuration sits: a crosshair ring in primary ink
    /// like the selected bubble (accent alone is grey under Graphite) — a
    /// different species from both the model bubbles and the settings dots.
    @ViewBuilder private func markers(_ plot: PlotFrame) -> some View {
        // Off the core axis the ring can't be config-projected — it marks the
        // selected model's bubble instead (still "you are here", by model).
        let committed = axis == "core"
            ? chartPoint(for: store.committedConfig, plot: plot)
            : bubbleCenter(for: store.modelID, plot)
        ring(at: committed)
            .animation(mapCurve, value: committed)
        if let previewed = store.previewedConfig {
            let ghost = axis == "core"
                ? chartPoint(for: previewed, plot: plot)
                : bubbleCenter(for: previewed.modelID, plot)
            if abs(ghost.x - committed.x) > 2 || abs(ghost.y - committed.y) > 2 {
                Circle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 18, height: 18)
                    .position(ghost)
                    .zIndex(7)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder private var infoCard: some View {
        let m = previewedModelID.flatMap { ModelMetrics.metrics(for: $0) }
            ?? ModelMetrics.metrics(for: store.modelID)
        if let m {
            VStack(alignment: .leading, spacing: 4) {
                Text(m.shortName).font(.caption.weight(.bold))
                HStack(spacing: 10) {
                    stat(String(localized: "ACC"), String(localized: "\(ModelMetrics.axisAccuracy(for: m.id, axis: axis) ?? m.firstWordPct)%"), .green)
                    stat(String(localized: "SPEED"), latencyLabel(ms: m.p50Ms), .blue)
                    stat(String(localized: "MEM"), gbLabel(HostPLE.residentGB(m.ramGB, of: m.id, pleFromDisk: store.pleFromDisk)), .teal)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: .rect(cornerRadius: 8))
            .allowsHitTesting(false)
        }
    }

    private func stat(_ label: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.caption2.monospacedDigit().weight(.semibold)).foregroundStyle(tint.legible)
        }
    }

    // MARK: Chord lenses

    /// One measured sibling on a chord lens, with the lens's task figures.
    private struct ChordStat: Identifiable {
        let id: String
        let name: String
        let pct: Int
        let ci: ClosedRange<Int>
        let p50Ms: Int
        let ramGB: Double
    }

    private var chordStats: [ChordStat] {
        ModelMetrics.tasks.map { id, t in
            ChordStat(id: id, name: ModelMetrics.taskModelNames[id] ?? id,
                      pct: lens == .fix ? t.fixPct : t.replyPct,
                      ci: lens == .fix ? t.fixCI : t.replyCI,
                      p50Ms: lens == .fix ? t.fixP50Ms : t.replyP50Ms,
                      ramGB: HostPLE.residentGB(ModelMetrics.taskRamGB(for: id) ?? 1, of: id, pleFromDisk: store.pleFromDisk))
        }.sorted { $0.pct > $1.pct }
    }

    /// The task colors, shared with the ranked rows' Fix · Reply figures.
    private var chordTint: Color { lens == .fix ? .orange : .purple }

    /// The sibling the current pick actually loads for the chords.
    private var currentSiblingID: String? {
        ModelMetrics.taskMetrics(for: store.modelID, style: store.style)?.measuredID
    }

    private func chordCenter(_ s: ChordStat, _ plot: PlotFrame) -> CGPoint {
        CGPoint(x: plot.x(ms: Double(s.p50Ms)), y: plot.y(acc: Double(s.pct)))
    }

    private func chordBubbles(_ plot: PlotFrame) -> some View {
        ForEach(chordStats) { s in
            let mine = s.id == currentSiblingID
            let r = radius(s.ramGB)
            let center = chordCenter(s, plot)
            // The catalog pick a click switches to: the first (quality-ordered)
            // entry whose chords land on this sibling at recommended settings.
            let target = ModelMetrics.taskUserIDs(of: s.id).first
            // Interactivity before .position — see the bubbles comment.
            ZStack {
                Circle().fill(chordTint.opacity(mine ? 0.8 : 0.42))
                Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5)
            }
            .frame(width: 2 * r, height: 2 * r)
            .shadow(color: .black.opacity(mine ? 0.3 : 0.12), radius: mine ? 4 : 2, y: 1)
            .contentShape(Circle())
            .scaleEffect(hoveredSibling == s.id ? 1.12 : 1)
            .animation(.easeOut(duration: 0.12), value: hoveredSibling)
            .help(chordBubbleHelp(s))
            .onTapGesture {
                if let target { store.selectModel(target) }
            }
            .onHover { inside in
                if inside {
                    hoveredSibling = s.id
                } else if hoveredSibling == s.id {
                    hoveredSibling = nil
                }
                // The rail previews the pick a click would land on — same
                // hover contract as the completion bubbles and ranked rows.
                if let target { store.setHover(.model(target), inside) }
            }
            .position(center)
            // Always labeled: a handful of bubbles doesn't crowd, and unlike
            // the completion lens there is no ranked list of siblings below
            // to name them.
            Text(s.name)
                .font(.caption2.weight(mine ? .bold : .medium))
                .foregroundStyle(mine ? Color.primary : Color.secondary)
                .position(labelPosition(center, offset: r + 9, inset: 44, plot))
                .allowsHitTesting(false)
        }
    }

    /// "You are here" on a chord lens: the same ring as the completion
    /// marker, on the sibling the current pick loads. No ghost — settings
    /// previews don't move the chord routing.
    @ViewBuilder private func chordMarker(_ plot: PlotFrame) -> some View {
        if let s = chordStats.first(where: { $0.id == currentSiblingID }) {
            ring(at: chordCenter(s, plot))
        }
    }

    /// The "you are here" ring, shared by the completion and chord lenses.
    private func ring(at point: CGPoint) -> some View {
        ZStack {
            Circle()
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.75))
            Circle()
                .strokeBorder(Color.primary, lineWidth: 2.5)
            Circle()
                .fill(Color.primary)
                .frame(width: 5, height: 5)
        }
        .frame(width: 18, height: 18)
        .shadow(color: .black.opacity(0.35), radius: 5)
        .position(point)
        .zIndex(7)
        .allowsHitTesting(false)
    }

    private func chordBubbleHelp(_ s: ChordStat) -> String {
        let users = ModelMetrics.taskUsers(of: s.id)
        guard let first = users.first else {
            return String(localized: "\(s.name) — no catalog pick routes its chords here.")
        }
        return users.count > 1
            ? String(localized: "Runs the chords for \(users.joined(separator: ", ")). Click to switch to \(first).")
            : String(localized: "Runs the chords for \(first). Click to switch to \(first).")
    }

    @ViewBuilder private var chordInfoCard: some View {
        let id = hoveredSibling ?? currentSiblingID ?? chordStats.first?.id
        if let s = chordStats.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 4) {
                Text(s.name).font(.caption.weight(.bold))
                HStack(spacing: 10) {
                    stat(lens == .fix ? String(localized: "EXACT FIX") : String(localized: "ON TOPIC"),
                         "\(s.pct)% [\(s.ci.lowerBound)–\(s.ci.upperBound)]", chordTint)
                    stat(String(localized: "SPEED"), latencyLabel(ms: s.p50Ms), .blue)
                    stat(String(localized: "MEM"), gbLabel(s.ramGB), .teal)
                }
                if lens == .fix, let t = ModelMetrics.tasks[s.id] {
                    Text("touches \(t.falseFixPct)% of clean lines")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                let users = ModelMetrics.taskUsers(of: s.id)
                if !users.isEmpty {
                    Text("runs the chords for \(users.joined(separator: " · "))")
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: 250, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: .rect(cornerRadius: 8))
            .allowsHitTesting(false)
        }
    }
}

/// A labeled mini-bar: name left, measured value right, fill = "how good"
/// relative to the best model in the catalog on that axis.
private struct MetricBar: View {
    let label: String
    let fraction: Double
    let text: String
    let color: Color
    let help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(text).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            // Drawn, not a ProgressView: each of those is an AppKit progress
            // indicator, and 33 of them made opening the list stall.
            // Floored so the slowest model still shows a sliver of bar.
            Capsule().fill(color.opacity(0.15))
                .overlay {
                    Capsule().fill(color).scaleEffect(x: max(0.03, fraction), anchor: .leading)
                }
                .frame(height: 5)
        }
        .frame(maxWidth: .infinity)
        .help(help)
    }
}
