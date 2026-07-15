import AppKit
import SwiftUI

/// The Model tab: a ranked, bar-annotated comparison of every model —
/// accuracy, speed and memory as at-a-glance bars (longer = better) with the
/// measured numbers beside them. Every figure is a real eval run
/// (see `ModelMetrics`); no axes to decode, no spec-sheet estimates.
struct ModelTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section("What matters most") {
                HStack(spacing: 10) {
                    ForEach(ModelPriority.allCases, id: \.self) { priority in
                        PriorityCard(priority: priority,
                                     isActive: store.priorityIsActive(priority),
                                     apply: { store.applyPriority(priority) },
                                     hover: { store.setHover(.preset(priority.pick), $0) })
                    }
                }
                Caption("One click switches to the measured-best model for that goal, in the exact configuration the card's figures come from (Base · Short). Your precision gates stay on where the model supports them — hover to preview.")
            }

            Section("The model map") {
                ModelMapView(store: store)
                PreviewDeltaStrip(store: store, section: "model")
                Caption("Up = more accurate · right = faster · bubble size = memory (\(ModelMetrics.evalSource), EN+RU). "
                    + "The ring is your current configuration; the small dots inside the dashed zone are this model's other settings — hover to preview, click to apply.")
            }

            Section("Ranked by measured accuracy") {
                Caption("Longer bars are better: Speed = how fast it answers, Memory = how light it is. "
                    + "Hover a row to preview it in the Live Impact rail; click to switch.")
                ForEach(rankedEntries, id: \.id) { entry in
                    ModelRow(id: entry.id, title: entry.title,
                             isSelected: store.modelID == entry.id,
                             select: { store.selectModel(entry.id) },
                             hover: { store.setHover(.model(entry.id), $0) })
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

                Toggle("Smart mid-sentence completion (fill-in-the-middle)", isOn: $store.fimEnabled)
                    .disabled(!store.recommendation.fim)
                if !store.recommendation.fim {
                    RequirementRow(met: false,
                                   text: "E4B-class model — unreliable on smaller models, so it's skipped for \(ModelMetrics.metrics(for: store.modelID)?.shortName ?? "this model")")
                } else {
                    BadgeRow(badges: [
                        EffectBadge(icon: "arrow.left.and.right.text.vertical",
                                    text: "uses the text after the cursor", tone: .neutral,
                                    source: "Conditions mid-line edits on what follows the cursor, so the completion meets the existing text instead of re-typing it. Reliable on E4B-class models only — auto-skipped elsewhere."),
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

                if store.isAppleIntelligence {
                    Picker("Recipe", selection: $store.fmVariant) {
                        Text("Examples — best quality").tag(FMPromptVariant.fewshot)
                        Text("Terse — lean instructions").tag(FMPromptVariant.terse)
                        Text("Plain — no scaffold").tag(FMPromptVariant.plain)
                        Text("Directive — fastest, full coverage").tag(FMPromptVariant.directive)
                    }
                    Caption("Prompt recipe for the Apple Intelligence engine. Examples measured most accurate on eval-v2; Directive fastest.")
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Catalog + system model (+ the selected fine-tuned path), measured
    /// entries ranked best-first, unmeasured last — comparison-ready order.
    private var rankedEntries: [(id: String, title: String)] {
        var entries: [(id: String, title: String)] = ModelCatalog.options.map { ($0.id, $0.title) }
        if #available(macOS 26.0, *) {
            entries.append((ModelCatalog.appleIntelligenceID, "Apple Intelligence — system model"))
        }
        if store.modelID.hasPrefix("/") {
            entries.append((store.modelID, store.selectedModelName))
        }
        return entries.sorted { a, b in
            switch (ModelMetrics.metrics(for: a.id), ModelMetrics.metrics(for: b.id)) {
            case let (ma?, mb?):
                if ma.firstWordPct != mb.firstWordPct { return ma.firstWordPct > mb.firstWordPct }
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
                LabeledContent("Best measured config") {
                    Text(store.recommendation.summary)
                }
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
                            .help("Auto-picked for this Mac's memory: ties much larger models on measured first-word accuracy at the lowest latency in the catalog.")
                    }
                    Spacer()
                }
                if let m = ModelMetrics.metrics(for: id) {
                    HStack(spacing: 16) {
                        MetricBar(label: "Accuracy", fraction: Bounds.accuracy(m), text: "\(m.firstWordPct)%",
                                  color: .green,
                                  help: "First-word accuracy of shown suggestions: \(m.firstWordPct)% [\(m.ci.lowerBound)–\(m.ci.upperBound)], coverage \(m.coveragePct)% — \(ModelMetrics.evalSource).")
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
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover?($0) }
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
private struct PriorityCard: View {
    let priority: ModelPriority
    let isActive: Bool
    let apply: () -> Void
    var hover: ((Bool) -> Void)?

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
                    Spacer(minLength: 0)
                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                if let m = ModelMetrics.metrics(for: priority.pick) {
                    Text(m.shortName)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text("\(m.firstWordPct)% · \(m.p50Ms) ms · " +
                         String(format: "%.1f GB", m.ramGB))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(isActive ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03)))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(isActive ? Color.accentColor : Color(nsColor: .separatorColor),
                            lineWidth: isActive ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .help(priority.goal)
        .onHover { hover?($0) }
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
    @State private var hoverID: String?
    @State private var hoverConfigLabel: String?

    private static let height: CGFloat = 300
    private typealias Scale = ConfigProjection.Scale

    var body: some View {
        GeometryReader { geo in
            let plot = PlotFrame(size: geo.size)
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
        .onHover { if !$0 { hoverID = nil; hoverConfigLabel = nil } }
    }

    /// Chart coordinates: x = log-speed (faster → right), y = accuracy.
    private struct PlotFrame {
        let size: CGSize
        var minX: CGFloat { 38 }
        var maxX: CGFloat { size.width - 12 }
        var minY: CGFloat { 8 }
        var maxY: CGFloat { size.height - 24 }

        func x(ms: Double) -> CGFloat {
            let f = ConfigProjection.Scale.logFraction(ms, in: ConfigProjection.Scale.msRange)
            return minX + (1 - f) * (maxX - minX)
        }
        func y(acc: Double) -> CGFloat {
            let clamped = min(max(acc, ConfigProjection.Scale.accMin), ConfigProjection.Scale.accMax)
            let f = (clamped - ConfigProjection.Scale.accMin)
                / (ConfigProjection.Scale.accMax - ConfigProjection.Scale.accMin)
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
            ForEach([60, 37, 15], id: \.self) { acc in
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

    /// Everything a model can reach as settings change: base at each length,
    /// the two gates where available, instruct where usable.
    private func reachableConfigs(for id: String) -> [ReachableConfig] {
        guard ModelMetrics.metrics(for: id) != nil else { return [] }
        let rec = ModelCatalog.recommended(for: id)
        func cfg(_ style: CompletionStyle, _ length: CompletionLength,
                 logprob: Bool = false, confidence: Bool = false) -> ProjectionConfig {
            ProjectionConfig(modelID: id, style: style, length: length,
                             logprobGate: logprob, confidenceGate: confidence,
                             useRecommended: false)
        }
        if id == ModelCatalog.appleIntelligenceID {
            return [ReachableConfig(label: "Short", config: cfg(.instruct, .short))]
        }
        var out = [ReachableConfig(label: "Short", config: cfg(.base, .short)),
                   ReachableConfig(label: "Medium", config: cfg(.base, .medium)),
                   ReachableConfig(label: "Long", config: cfg(.base, .long)),
                   ReachableConfig(label: "Confident-only", config: cfg(.base, .short, logprob: true))]
        if rec.gateCapable {
            out.append(ReachableConfig(label: "Consensus ×5", config: cfg(.base, .short, confidence: true)))
        }
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
        if let rect = reachableEnvelope(for: store.modelID, plot,
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
                .position(x: rect.minX + 62, y: rect.minY)
                .allowsHitTesting(false)
        }
        // Hovering another model (bubble, ranked row or preset card) ghosts
        // ITS settings zone in accent, so zones compare before committing.
        if let previewed = store.previewedConfig, previewed.modelID != store.modelID,
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
            let center = CGPoint(x: plot.x(ms: Double(m.p50Ms)),
                                 y: plot.y(acc: Double(m.firstWordPct)))
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
            .onHover { hovering in
                hoverID = hovering ? m.id : (hoverID == m.id ? nil : hoverID)
                store.setHover(.model(m.id), hovering)
            }
            .position(center)
            if selected || hoverID == m.id {
                Text(m.shortName)
                    .font(.system(size: 9).weight(selected ? .bold : .medium))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .position(x: center.x, y: center.y + r + 9)
                    .allowsHitTesting(false)
            }
        }
    }

    /// The other configurations the selected model can be switched into,
    /// right on the map: hover previews, click applies. Accent-tinted hollow
    /// dots — a different species from the gray model bubbles.
    @ViewBuilder private func configDots(_ plot: PlotFrame) -> some View {
        let committed = store.committedConfig
        ForEach(reachableConfigs(for: store.modelID)) { reachable in
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
                    .onHover { hovering in
                        hoverConfigLabel = hovering ? reachable.label
                            : (hoverConfigLabel == reachable.label ? nil : hoverConfigLabel)
                        store.setHover(.config(reachable.config), hovering)
                    }
                    .position(point)
                    .zIndex(5)
                if hoverConfigLabel == reachable.label {
                    Text(reachable.label)
                        .font(.system(size: 9).weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 4)
                        .background(Color(nsColor: .windowBackgroundColor).opacity(0.9),
                                    in: Capsule())
                        .position(x: point.x, y: point.y + 13)
                        .zIndex(6)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    /// Where the committed configuration sits: an accent crosshair ring — a
    /// different species from both the model bubbles and the settings dots.
    @ViewBuilder private func markers(_ plot: PlotFrame) -> some View {
        let committed = chartPoint(for: store.committedConfig, plot: plot)
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
            let ghost = chartPoint(for: previewed, plot: plot)
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
        let m = hoverID.flatMap { ModelMetrics.metrics(for: $0) }
            ?? ModelMetrics.metrics(for: store.modelID)
        if let m {
            VStack(alignment: .leading, spacing: 4) {
                Text(m.shortName).font(.caption.weight(.bold))
                HStack(spacing: 10) {
                    stat("ACC", "\(m.firstWordPct)%", .green)
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
