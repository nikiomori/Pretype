import AppKit
import SwiftUI

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
        // focus, nothing to announce. The section's list view is the accessible
        // equivalent, so describe the chart and point VoiceOver at the list.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(lens == .completion
            ? Text("Model map — accuracy, speed and memory of every model. Switch to the list view to choose a model by name.")
            : lens == .fix
            ? Text("Task map — how well each instruct sibling handles the fix chord, with speed and memory. The list view shows the same Fix and Reply figures per model.")
            : Text("Task map — how well each instruct sibling handles the reply chord, with speed and memory. The list view shows the same Fix and Reply figures per model."))
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
struct MetricBar: View {
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
