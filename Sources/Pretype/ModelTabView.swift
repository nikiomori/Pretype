import AppKit
import SwiftUI

/// The Model tab: a ranked, bar-annotated comparison of every model —
/// accuracy, speed and memory as at-a-glance bars (longer = better) with the
/// measured numbers beside them. Every figure is a real eval run
/// (see `ModelMetrics`); no axes to decode, no spec-sheet estimates.
struct ModelTab: View {
    @ObservedObject var store: SettingsStore
    /// The accuracy axis every surface on this tab reads ("*" = all
    /// languages, "core" = EN+RU, or one language) — one store-persisted
    /// selection, so cards, map and ranking always tell the same story.
    private var axis: String { store.accuracyAxis }

    private func langName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code
    }

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
            Section {
                Picker("Accuracy shown for", selection: $store.accuracyAxis) {
                    Text("All \(ModelMetrics.evalLanguages.count) languages — equal-weight average").tag("*")
                    Text("English + Russian — largest sample, full settings map").tag("core")
                    Divider()
                    ForEach(ModelMetrics.evalLanguages, id: \.self) { code in
                        Text(langName(code)).tag(code)
                    }
                }
                axisCaption
            }

            Section("What matters most") {
                HStack(spacing: 10) {
                    ForEach(distinctPriorities, id: \.self) { priority in
                        let pick = priority.pick(axis: axis)
                        PriorityCard(priority: priority, pick: pick,
                                     acc: ModelMetrics.axisAccuracy(for: pick, axis: axis),
                                     isActive: store.priorityIsActive(priority),
                                     apply: { store.applyPriority(priority) },
                                     hover: { store.setHover(.preset(pick), $0) })
                    }
                }
                Caption("One click switches to the measured-best model for that goal on the axis above, in the exact configuration the card's figures come from (Base · Short). Your precision gates stay on where the model supports them — hover to preview.")
            }

            Section("The model map") {
                ModelMapView(store: store, hover: store.hoverState)
                if axis == "core" {
                    Caption("Up = more accurate · right = faster · bubble size = memory (\(ModelMetrics.evalSource)). "
                        + "The ring is your current configuration; the small dots inside the dashed zone are this model's other settings — hover to preview, click to apply.")
                } else {
                    Caption("Up = more accurate for \(ModelMetrics.axisDisplayName(axis)), silence counted as a miss · right = faster · bubble size = memory. "
                        + "Settings dots and the reachable zone are measured on the EN+RU sample only — switch the axis above to explore them.")
                }
            }

            Section("Ranked by measured accuracy") {
                Caption("Longer bars are better: Speed = how fast it answers, Memory = how light it is. "
                    + "Hover a row to preview it in the Live Impact rail; click to switch.")
                ForEach(rankedEntries, id: \.id) { entry in
                    ModelRow(id: entry.id, title: entry.title,
                             isSelected: store.modelID == entry.id,
                             select: { store.selectModel(entry.id) },
                             hover: { store.setHover(.model(entry.id), $0) },
                             langAccuracy: langAccuracy(for: entry.id))
                }
                HStack {
                    Spacer()
                    Button("Choose fine-tuned model…") { store.chooseFineTunedModel() }
                        .controlSize(.small)
                }
            }

            selectedModelSection

            Section("Runtime") {
                Picker("Free memory when idle", selection: $store.idleUnloadMinutes) {
                    Text("Never").tag(0)
                    Text("After 1 minute").tag(1)
                    Text("After 5 minutes").tag(5)
                    Text("After 15 minutes").tag(15)
                    Text("After 30 minutes").tag(30)
                }
                if store.idleUnloadMinutes > 0, store.selectedRamGB > 0 {
                    BadgeRow(badges: [
                        EffectBadge(icon: "memorychip",
                                    text: String(format: "frees ~%.1f GB when unused", store.selectedRamGB),
                                    tone: .memory,
                                    source: "Unloads the resident model after \(store.idleUnloadMinutes) min idle; the next keystroke reloads it from the on-disk cache (a focus change pre-warms it)."),
                    ])
                }

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
        }
        .formStyle(.grouped)
    }

    /// The axis caption: what the numbers on this tab mean and where they
    /// come from — swapped with the axis so the citation is never stale.
    @ViewBuilder private var axisCaption: some View {
        switch axis {
        case "*":
            Caption("Every measured language weighted equally; staying silent counts as a miss. "
                + "An average hides per-language cliffs — pick the language you type in to see the whole tab re-measured for it.")
        case "core":
            Caption("The largest measured sample (\(ModelMetrics.evalSource)) and the only axis settings projections are measured on: "
                + "accuracy here = correct first word of shown suggestions.")
        default:
            Caption("Everything on this tab — cards, map, ranking — is measured for \(langName(axis)): "
                + "first word right with silence counted as a miss (matched text registers, ≈280 samples, ±5 pp). "
                + "Compare models, not languages against each other (Chinese and Japanese score per character).")
        }
    }

    /// Axis accuracy for a row, with the axis best for bar normalization —
    /// nil on the core axis (rows show the richer headline bars there) and
    /// for unmeasured models.
    private func langAccuracy(for id: String) -> (pct: Int, max: Int)? {
        guard axis != "core",
              let pct = ModelMetrics.axisAccuracy(for: id, axis: axis) else { return nil }
        return (pct, ModelMetrics.axisBest(axis))
    }

    /// Catalog + system model (+ the selected fine-tuned path), measured
    /// entries ranked best-first, unmeasured last — comparison-ready order.
    /// With a language picked, that language's "of all" figure ranks first;
    /// the overall comparator breaks its coarse-% ties.
    private var rankedEntries: [(id: String, title: String)] {
        var entries: [(id: String, title: String)] = ModelCatalog.options.map { ($0.id, $0.title) }
        if #available(macOS 26.0, *) {
            entries.append((ModelCatalog.appleIntelligenceID, "Apple Intelligence — system model"))
        }
        if store.modelID.hasPrefix("/") {
            entries.append((store.modelID, store.selectedModelName))
        }
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

    @ViewBuilder private var selectedModelSection: some View {
        Section("Selected: \(store.selectedModelName)") {
            if let m = ModelMetrics.metrics(for: store.modelID) {
                LabeledContent("Offers a suggestion") {
                    Text("\(m.coveragePct)% of the time — stays silent otherwise")
                }
                if axis != "core", let v = ModelMetrics.axisAccuracy(for: store.modelID, axis: axis) {
                    LabeledContent("Accuracy — \(ModelMetrics.axisDisplayName(axis))") {
                        Text("\(v)% first word, silence counted as a miss")
                    }
                }
                // Apple Intelligence is the system model: style is moot (setupLine
                // omits it too) and the "below E4B class" fill-in reasoning is an
                // on-device-tier concept that doesn't apply — so suppress the
                // measured-config row and describe how the system model runs.
                if !store.isAppleIntelligence {
                    LabeledContent("Best measured config") {
                        Text(store.recommendation.summary)
                    }
                }
                LabeledContent("Mid-sentence edits") {
                    Text(store.isAppleIntelligence
                        ? "handled by the system model"
                        : (store.recommendation.fim
                            ? "fill-in — also reads the text after the cursor"
                            : "left context only — fill-in is unreliable below E4B class"))
                }
                .help(store.isAppleIntelligence
                    ? "Apple Intelligence runs on the Neural Engine as the system model — Pretype doesn't set its style or fill-in; those are on-device-model settings."
                    : (store.recommendation.fim
                        ? "Mid-line edits condition on what follows the cursor, so the completion meets the existing text instead of re-typing it."
                        : "Fill-in-the-middle is reliable on E4B-class models only, so it's skipped automatically here — not a setting, just how this model is driven."))
                if let note = m.note {
                    Caption(note)
                }
            } else if store.modelID.hasPrefix("/") {
                Caption("Local fine-tuned model — no eval figures. Run it through the eval harness to compare it against the catalog.")
            } else {
                Caption("No measured figures for this model yet.")
            }
        }
    }
}

// MARK: - Comparison row

/// One selectable model with its three measured axes as labeled bars.
private struct ModelRow: View {
    let id: String
    let title: String
    let isSelected: Bool
    let select: () -> Void
    var hover: ((Bool) -> Void)?
    /// When the list is ranked for one language: that language's "of all"
    /// accuracy and the best catalog value in it (for bar normalization).
    var langAccuracy: (pct: Int, max: Int)?
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
                        .lineLimit(1).truncationMode(.middle)
                    if id == ModelCatalog.defaultID {
                        Text("RECOMMENDED")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .foregroundStyle(Color.accentColor)
                            .background(Color.accentColor.opacity(0.14), in: Capsule())
                            .help(ModelCatalog.defaultRationale)
                    }
                    Spacer()
                }
                if let m = ModelMetrics.metrics(for: id) {
                    HStack(spacing: 16) {
                        if let la = langAccuracy {
                            MetricBar(label: "Accuracy", fraction: la.max > 0 ? Double(la.pct) / Double(la.max) : 0,
                                      text: "\(la.pct)%",
                                      color: .green,
                                      help: "First word right, staying silent counted as a miss: \(la.pct)% — matched-register cells, ≈280 samples per language (±5 pp), eval-real 2026-07-16. Compare models within this view, not languages against each other.")
                        } else {
                            MetricBar(label: "Accuracy", fraction: Bounds.accuracy(m), text: "\(m.firstWordPct)%",
                                      color: .green,
                                      help: "First-word accuracy of shown suggestions: \(m.firstWordPct)% [\(m.ci.lowerBound)–\(m.ci.upperBound)], coverage \(m.coveragePct)% — \(ModelMetrics.evalSource).")
                        }
                        MetricBar(label: "Speed", fraction: Bounds.speed(m), text: "\(m.p50Ms) ms",
                                  color: .blue,
                                  help: "Median time per suggestion: \(m.p50Ms) ms, warm — longer bar = faster.")
                        MetricBar(label: "Memory", fraction: Bounds.lightness(m),
                                  text: m.ramGB > 0 ? String(format: "%.1f GB", m.ramGB) : "0 GB",
                                  color: .teal,
                                  help: m.ramGB > 0
                                    ? String(format: "Resident weights: %.1f GB — longer bar = lighter.", m.ramGB)
                                    : "System model — no download, no app memory.")
                    }
                    .padding(.leading, 24)
                } else {
                    Text("not measured")
                        .font(.caption).foregroundStyle(.tertiary)
                        .padding(.leading, 24)
                }
            }
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(hovering && !isSelected ? Color.primary.opacity(0.05) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0; hover?($0) }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    /// Normalization bounds across the measured catalog, so bar lengths are
    /// comparable between rows. Longer bar = better on every axis.
    private enum Bounds {
        static let maxAccuracy = Double(ModelMetrics.all.map(\.firstWordPct).max() ?? 100)
        static let minP50 = Double(ModelMetrics.all.map(\.p50Ms).min() ?? 1)
        static let minRam = ModelMetrics.all.map(\.ramGB).filter { $0 > 0 }.min() ?? 1

        static func accuracy(_ m: ModelMetrics) -> Double { Double(m.firstWordPct) / maxAccuracy }
        static func speed(_ m: ModelMetrics) -> Double { minP50 / Double(m.p50Ms) }
        static func lightness(_ m: ModelMetrics) -> Double { m.ramGB > 0 ? minRam / m.ramGB : 1 }
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
    var hover: ((Bool) -> Void)?
    /// Local hover for the card highlight — kept off the store the Form
    /// observes, unlike the rail-preview `hover` callback below.
    @State private var hovering = false

    var body: some View {
        Button(action: apply) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: priority.symbol)
                        .font(.caption)
                        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                    Text(priority.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
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
                    (Text("\(acc ?? m.firstWordPct)%").foregroundStyle(.green)
                        + Text(" · ").foregroundStyle(.tertiary)
                        + Text("\(m.p50Ms) ms").foregroundStyle(.blue)
                        + Text(" · ").foregroundStyle(.tertiary)
                        + Text(String(format: "%.1f GB", m.ramGB)).foregroundStyle(.teal))
                        .font(.system(size: 10).monospacedDigit())
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
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
        .help(priority.goal)
        .onHover { hovering = $0; hover?($0) }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Model map

/// The catalog as a scatter map: accuracy up, speed right (log scale), bubble
/// size = memory. A dashed envelope marks everything the selected model can
/// reach through settings; a solid marker shows where the committed
/// configuration sits and a dashed ghost previews the hovered change. Same
/// `ConfigProjection` figures as the rail — one truth, two views.
private struct ModelMapView: View {
    @ObservedObject var store: SettingsStore
    /// Hover previews live on their own observable so pointer movement
    /// re-renders the map and rail — never the scrolling Form around them.
    @ObservedObject var hover: HoverState

    /// The tab's accuracy axis. Off the "core" axis the settings machinery
    /// (dots, envelope, config-projected ring) hides: config effects are
    /// measured on the EN+RU sample only, and drawing them against a
    /// different scale would fabricate numbers.
    private var axis: String { store.accuracyAxis }

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
    /// the scale fits the plotted data instead, rounded to 5s.
    private var accBounds: (lo: Double, hi: Double) {
        guard axis != "core" else { return (Scale.accMin, Scale.accMax) }
        let values = visibleMetrics.map {
            Double(ModelMetrics.axisAccuracy(for: $0.id, axis: axis) ?? $0.firstWordPct)
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
            let plot = PlotFrame(size: geo.size, accLo: bounds.lo, accHi: bounds.hi)
            ZStack(alignment: .topLeading) {
                gridAndAxes(plot)
                envelope(plot)
                bubbles(plot)
                configDots(plot)
                markers(plot)
                infoCard
                    .padding(.leading, plot.minX + 6)
                    .padding(.top, 2)
            }
        }
        .frame(height: Self.height)
    }

    /// Chart coordinates: x = log-speed (faster → right), y = accuracy on the
    /// axis-dependent span.
    private struct PlotFrame {
        let size: CGSize
        let accLo: Double
        let accHi: Double
        var minX: CGFloat { 38 }
        var maxX: CGFloat { size.width - 12 }
        var minY: CGFloat { 8 }
        var maxY: CGFloat { size.height - 24 }

        func x(ms: Double) -> CGFloat {
            let f = ConfigProjection.Scale.logFraction(ms, in: ConfigProjection.Scale.msRange)
            return minX + (1 - f) * (maxX - minX)
        }
        func y(acc: Double) -> CGFloat {
            let clamped = min(max(acc, accLo), accHi)
            let f = (clamped - accLo) / (accHi - accLo)
            return minY + (1 - f) * (maxY - minY)
        }
    }

    /// Every measured model shown on this Mac (the system model needs macOS 26).
    private var visibleMetrics: [ModelMetrics] {
        ModelMetrics.all.filter { m in
            if m.id == ModelCatalog.appleIntelligenceID {
                if #available(macOS 26.0, *) { return true } else { return false }
            }
            return true
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
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .position(x: plot.minX - 18, y: y)
            }
            Text("◀ slower")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .position(x: plot.minX + 26, y: plot.maxY + 12)
            Text("faster ▶")
                .font(.system(size: 9).weight(.semibold))
                .foregroundStyle(Color.blue.opacity(0.8))
                .position(x: plot.maxX - 26, y: plot.maxY + 12)
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
    /// trade-off with its own badges instead.
    private func reachableConfigs(for id: String) -> [ReachableConfig] {
        guard ModelMetrics.metrics(for: id) != nil else { return [] }
        let rec = ModelCatalog.recommended(for: id)
        func cfg(_ style: CompletionStyle, _ length: CompletionLength,
                 logprob: Bool = false) -> ProjectionConfig {
            ProjectionConfig(modelID: id, style: style, length: length,
                             logprobGate: logprob, confidenceGate: false,
                             useRecommended: false)
        }
        if id == ModelCatalog.appleIntelligenceID {
            return [ReachableConfig(label: "Short", config: cfg(.instruct, .short))]
        }
        var out = [ReachableConfig(label: "Short", config: cfg(.base, .short)),
                   ReachableConfig(label: "Confident-only", config: cfg(.base, .short, logprob: true))]
        if rec.style == .instruct {
            out.append(ReachableConfig(label: "Instruct", config: cfg(.instruct, .short)))
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
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(Color.primary.opacity(0.35))
                .background(Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 18))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .animation(.easeOut(duration: 0.3), value: rect)
                .allowsHitTesting(false)
            Text("reachable with settings")
                .font(.system(size: 8.5).weight(.bold))
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
        // ITS settings zone in accent, so zones compare before committing.
        if axis == "core",
           let previewed = store.previewedConfig, previewed.modelID != store.modelID,
           let rect = reachableEnvelope(for: previewed.modelID, plot,
                                        including: chartPoint(for: previewed, plot: plot)),
           max(rect.width, rect.height) > 60 {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                .foregroundStyle(Color.accentColor.opacity(0.75))
                .background(Color.accentColor.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 18))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
        }
    }

    private func bubbles(_ plot: PlotFrame) -> some View {
        ForEach(visibleMetrics, id: \.id) { m in
            let selected = m.id == store.modelID
            let r = radius(m.ramGB)
            let center = bubbleCenter(for: m.id, plot)
            // Hover and tap attach BEFORE .position: onHover tracks the
            // view's FRAME, and a positioned wrapper fills the whole plot —
            // eleven overlapping full-plot hover areas, the last one winning.
            ZStack {
                Circle()
                    .fill(selected ? Color.primary : Color.secondary.opacity(0.45))
                Circle()
                    .strokeBorder(selected ? Color.primary : Color.white.opacity(0.9),
                                  style: m.id == ModelCatalog.appleIntelligenceID && !selected
                                      ? StrokeStyle(lineWidth: 1.5, dash: [3, 2])
                                      : StrokeStyle(lineWidth: 1.5))
            }
            .frame(width: 2 * r, height: 2 * r)
            .shadow(color: .black.opacity(selected ? 0.35 : 0.12),
                    radius: selected ? 5 : 2, y: 1)
            .contentShape(Circle())
            .onTapGesture { store.selectModel(m.id) }
            .onHover { store.setHover(.model(m.id), $0) }
            .position(center)
            if selected || previewedModelID == m.id {
                // Clamp into the plot horizontally and flip above the bubble
                // near the floor — edge bubbles must not push their name into
                // the axis labels or out of frame.
                let below = center.y + r + 9
                Text(m.shortName)
                    .font(.system(size: 9).weight(selected ? .bold : .medium))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .position(x: min(max(center.x, plot.minX + 34), plot.maxX - 34),
                              y: below > plot.maxY - 3 ? center.y - r - 9 : below)
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
                        .font(.system(size: 9).weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 4)
                        .background(Color(nsColor: .windowBackgroundColor).opacity(0.9),
                                    in: Capsule())
                        .position(x: min(max(point.x, plot.minX + 34), plot.maxX - 34),
                                  y: point.y + 13 > plot.maxY - 3 ? point.y - 13 : point.y + 13)
                        .zIndex(6)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    /// Where the committed configuration sits: an accent crosshair ring — a
    /// different species from both the model bubbles and the settings dots.
    @ViewBuilder private func markers(_ plot: PlotFrame) -> some View {
        // Off the core axis the ring can't be config-projected — it marks the
        // selected model's bubble instead (still "you are here", by model).
        let committed = axis == "core"
            ? chartPoint(for: store.committedConfig, plot: plot)
            : bubbleCenter(for: store.modelID, plot)
        ZStack {
            Circle()
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.75))
            Circle()
                .strokeBorder(Color.accentColor, lineWidth: 2.5)
            Circle()
                .fill(Color.accentColor)
                .frame(width: 5, height: 5)
        }
        .frame(width: 18, height: 18)
        .shadow(color: Color.accentColor.opacity(0.55), radius: 5)
        .position(committed)
        .zIndex(7)
        .animation(.easeOut(duration: 0.3), value: committed)
        .allowsHitTesting(false)
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
                    stat("ACC", "\(ModelMetrics.axisAccuracy(for: m.id, axis: axis) ?? m.firstWordPct)%", .green)
                    stat("SPEED", m.p50Ms >= 1000
                        ? String(format: "%.1f s", Double(m.p50Ms) / 1000) : "\(m.p50Ms) ms", .blue)
                    stat("MEM", m.ramGB <= 0 ? "0 GB" : String(format: "%.1f GB", m.ramGB), .teal)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .glassCard(cornerRadius: 8)
            .allowsHitTesting(false)
        }
    }

    private func stat(_ label: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 8).weight(.semibold)).foregroundStyle(.tertiary)
            Text(value).font(.caption2.monospacedDigit().weight(.semibold)).foregroundStyle(tint)
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
                Text(label).font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text(text).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.14))
                    Capsule().fill(color.opacity(0.75))
                        .frame(width: max(5, geo.size.width * fraction))
                }
            }
            .frame(height: 5)
        }
        .frame(maxWidth: .infinity)
        .help(help)
    }
}
