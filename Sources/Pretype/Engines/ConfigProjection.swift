import Foundation

/// A completion configuration as the user can express it in Settings — the
/// input to `ConfigProjection`. Pure value type so previews ("what would
/// hovering this control change?") share the exact cascade rules the live
/// pipeline applies, without touching it.
struct ProjectionConfig: Equatable {
    var modelID: String
    var style: CompletionStyle
    var length: CompletionLength
    var logprobGate: Bool
    var useRecommended: Bool

    /// The model the engine loads as the primary: Instruct style runs the
    /// entry's instruct sibling.
    var primaryModelID: String {
        style == .instruct ? ModelCatalog.option(for: modelID)?.instructModelID ?? modelID : modelID
    }

    /// One user gesture on one control.
    enum Change: Equatable {
        case model(String)
        case style(CompletionStyle)
        case length(CompletionLength)
        case logprobGate(Bool)
        case useRecommended(Bool)
        /// A priority preset: this model in its measured-protocol config
        /// (Base · Short — the exact figures the preset card advertises),
        /// keeping the user's precision gate.
        case preset(String)
        /// Jump to an exact configuration — a settings dot on the model map.
        case config(ProjectionConfig)
    }

    /// Same runtime state, ignoring the auto-mode flag — what the map's
    /// marker and settings dots compare by.
    func sameRuntime(as other: ProjectionConfig) -> Bool {
        modelID == other.modelID && style == other.style && length == other.length
            && logprobGate == other.logprobGate
    }

    /// The same dependency cascades the pipeline applies on commit:
    /// recommended mode snaps style/length and clears the gate; instruct has no
    /// gate path.
    func applying(_ change: Change) -> ProjectionConfig {
        var c = self
        switch change {
        case .model(let id):
            c.modelID = id
            if c.useRecommended {
                c.style = ModelCatalog.recommended(for: id).style
                c.length = .short
                c.logprobGate = false
            }
            // A switch to a base-only model never keeps the measured-broken
            // Instruct style; and if the landing style is still Instruct
            // (stale persisted state), the Base-only gate cannot survive.
            if !ModelCatalog.instructCompletes(id), c.style == .instruct { c.style = .base }
            if c.style != .base { c.logprobGate = false }
        case .style(let s):
            c.style = s
            c.useRecommended = false
            if s == .instruct { c.logprobGate = false }
        case .length(let l):
            c.length = l
            c.useRecommended = false
        case .logprobGate(let on):
            c.logprobGate = on
        case .useRecommended(let on):
            c.useRecommended = on
            if on {
                c.style = ModelCatalog.recommended(for: c.modelID).style
                c.length = .short
                c.logprobGate = false
            }
        case .preset(let id):
            c.modelID = id
            // Land on the measured protocol the card's figures come from;
            // auto mode stays only where the recommendation IS this landing
            // state (every MLX model since 2026-10-15).
            c.style = .base
            c.length = .short
            c.useRecommended = ModelCatalog.recommended(for: id).style == .base
        case .config(let target):
            c = target
        }
        return c
    }
}

/// "What matters most" presets: each resolves to the measured-best model for
/// one goal and lands on that model's recommended settings. Picks are
/// dominance rules over the measured catalog (best on the prioritized axis,
/// measured ties broken by the next axis) — no invented weighting.
enum ModelPriority: String, CaseIterable {
    case lightest, quick, accurate, balanced

    var title: String {
        switch self {
        case .lightest: return String(localized: "Lightest")
        case .quick: return String(localized: "Quick & accurate")
        case .accurate: return String(localized: "Most accurate")
        case .balanced: return String(localized: "Balanced")
        }
    }

    var symbol: String {
        switch self {
        case .lightest: return "leaf"
        case .quick: return "hare"
        case .accurate: return "scope"
        case .balanced: return "dial.medium"
        }
    }

    var goal: String {
        switch self {
        case .lightest: return String(localized: "Smallest footprint — for Macs with little free memory.")
        case .quick: return String(localized: "Fastest of the models within 2 pp of the best accuracy.")
        case .accurate: return String(localized: "Best measured accuracy; first-word ties break on reference scoring.")
        case .balanced: return String(localized: "The out-of-the-box pick: the best tier that stays within about a quarter of this Mac's memory, working fix/reply chords included.")
        }
    }

    /// The downloadable measured catalog (the system model has no place in a
    /// footprint/speed contest).
    private static var measured: [ModelMetrics] {
        ModelMetrics.all.filter { $0.ramGB > 0 }
    }

    /// The goal cards worth showing on `axis`. One per landing model — when
    /// two goals land on the same one, the first in `allCases` keeps it — and
    /// no "Most accurate" that another card matches on less memory: its lead
    /// is a logP tie-break the card can't show, so beside "Balanced" at the
    /// same 22% for a gigabyte less it read as a promise it didn't keep.
    static func shown(axis: String) -> [ModelPriority] {
        var seen = Set<String>()
        let cards = allCases.filter { seen.insert($0.pick(axis: axis)).inserted }
        guard cards.contains(.accurate),
              let best = ModelMetrics.metrics(for: accurate.pick(axis: axis)) else { return cards }
        let matched = cards.contains { card in
            guard card != .accurate, let m = ModelMetrics.metrics(for: card.pick(axis: axis)) else { return false }
            return accuracy(m, axis: axis) >= accuracy(best, axis: axis) && m.ramGB < best.ramGB
        }
        return matched ? cards.filter { $0 != .accurate } : cards
    }

    /// The catalog's measured models a card may land on, with what their fix
    /// model measures — in Base style, where a card lands (`Change.preset`).
    /// A row booked on a run of its own stays out, as from every ranking.
    private static var chordPool: [(id: String, fixer: String, fix: Int, ms: Int, gb: Double, ownGB: Double)] {
        ModelCatalog.options.compactMap { option in
            guard let t = ModelMetrics.taskMetrics(for: option.id, style: .base), t.m.ownRun == nil,
                  let gb = ModelMetrics.taskRamGB(for: t.measuredID) else { return nil }
            return (option.id, t.measuredID, t.m.fixPct, t.m.fixP50Ms, gb,
                    ModelMetrics.metrics(for: option.id)?.ramGB ?? .infinity)
        }
    }

    /// The goal cards while the model serves only the chords: one per fix
    /// model — two catalog entries sharing one would be the same card.
    static func shownForChords() -> [ModelPriority] {
        let pool = chordPool
        var seen = Set<String>()
        return allCases.filter { card in
            let pick = card.pickForChords()
            return seen.insert(pool.first { $0.id == pick }?.fixer ?? pick).inserted
        }
    }

    /// `pick(axis:)` on the fix chord: what its model restores, how fast, in
    /// how much memory. Ties go to the lighter completion model, kept on
    /// disk for when suggestions come back.
    func pickForChords() -> String {
        let pool = Self.chordPool
        func lighter(_ a: (id: String, fixer: String, fix: Int, ms: Int, gb: Double, ownGB: Double),
                     _ b: (id: String, fixer: String, fix: Int, ms: Int, gb: Double, ownGB: Double)) -> Bool {
            a.ownGB < b.ownGB
        }
        let top = pool.map(\.fix).max() ?? 0
        switch self {
        case .lightest:
            return pool.min { $0.gb != $1.gb ? $0.gb < $1.gb : $0.fix != $1.fix ? $0.fix > $1.fix : lighter($0, $1) }?.id
                ?? ModelCatalog.defaultID
        case .quick:
            return pool.filter { $0.fix >= top - 2 }.min { $0.ms != $1.ms ? $0.ms < $1.ms : lighter($0, $1) }?.id
                ?? ModelCatalog.defaultID
        case .accurate:
            return pool.filter { $0.fix == top }.min { $0.gb != $1.gb ? $0.gb < $1.gb : lighter($0, $1) }?.id
                ?? ModelCatalog.defaultID
        case .balanced:
            return ModelCatalog.defaultID
        }
    }

    /// The figure a card shows for `m` on `axis`.
    static func accuracy(_ m: ModelMetrics, axis: String) -> Int {
        ModelMetrics.axisAccuracy(for: m.id, axis: axis) ?? m.firstWordPct
    }

    /// Measured-best model for the goal ON the given accuracy axis (see
    /// `Settings.accuracyAxis`) — the whole tab re-resolves when the axis
    /// changes, so "Most accurate" means most accurate for YOUR language.
    func pick(axis: String) -> String {
        let pool = Self.measured
        guard !pool.isEmpty else { return ModelCatalog.defaultID }
        func acc(_ m: ModelMetrics) -> Int { Self.accuracy(m, axis: axis) }
        switch self {
        case .lightest:
            return pool.min {
                $0.ramGB != $1.ramGB ? $0.ramGB < $1.ramGB : acc($0) > acc($1)
            }?.id ?? ModelCatalog.defaultID
        case .accurate:
            // Coarse-% ties break on logP/char (the tokenizer-fair quality
            // continuum; booked EN+RU-weighted — per-language logP isn't).
            let top = pool.map(acc).max() ?? 0
            return pool.filter { acc($0) == top }
                .max { ($0.logProbPerChar ?? -.infinity) < ($1.logProbPerChar ?? -.infinity) }?.id
                ?? ModelCatalog.defaultID
        case .quick:
            let top = pool.map(acc).max() ?? 0
            return pool.filter { acc($0) >= top - 2 }.min { $0.p50Ms < $1.p50Ms }?.id
                ?? ModelCatalog.defaultID
        case .balanced:
            // The fresh-install rule verbatim: sized to this Mac's memory
            // (see ModelCatalog.defaultID). Language dropped out of that rule
            // on 2026-07-25 — no per-language gap between the small models
            // survives p<0.01 — so unlike the other cards this one does not
            // move with the axis.
            return ModelCatalog.defaultID
        }
    }
}

/// What the fix and reply chords measure to for a configuration: the model
/// they run on (`ModelMetrics.taskMetrics`), how often a fix restores the
/// line, how often a reply is on topic, a fix's speed and the memory that
/// model holds while it works. The Model pane's figures while no suggestion
/// asks the model (`SettingsStore.chordsOnly`).
struct ChordProjection: Equatable {
    var fixerName: String?
    var fixPct: Int?
    /// Clean words a fix changed anyway.
    var falseFixPct: Int?
    var replyPct: Int?
    var p50Ms: Int?
    var ramGB: Double?

    static func project(_ c: ProjectionConfig, pleFromDisk: Bool = Settings.pleFromDisk) -> ChordProjection {
        guard let t = ModelMetrics.taskMetrics(for: c.modelID, style: c.style) else { return ChordProjection() }
        return ChordProjection(
            fixerName: t.runsOn, fixPct: t.m.fixPct, falseFixPct: t.m.falseFixPct, replyPct: t.m.replyPct,
            p50Ms: t.m.fixP50Ms,
            ramGB: ModelMetrics.taskRamGB(for: t.measuredID).map { HostPLE.residentGB($0, of: t.measuredID, pleFromDisk: pleFromDisk) })
    }

    // Longer bar = better, on the rail's scales.
    var fixFraction: Double? { fixPct.map { max(0.04, Double($0) / 100) } }
    var replyFraction: Double? { replyPct.map { max(0.04, Double($0) / 100) } }
    var speedFraction: Double? {
        p50Ms.map { max(0.04, 1 - ConfigProjection.Scale.logFraction(Double($0), in: ConfigProjection.Scale.msRange)) }
    }
    var memoryFraction: Double? { ramGB.map { max(0.06, 1 - $0 / ConfigProjection.Scale.gbMax) } }

    var fixText: String { fixPct.map { "\($0)%" } ?? "—" }
    var replyText: String { replyPct.map { "\($0)%" } ?? "—" }
    var latencyText: String { p50Ms.map { latencyLabel(ms: $0) } ?? "—" }
    var memoryText: String { ramGB.map(gbLabel) ?? "—" }

    /// The chips beside the meters while a hover previews `tgt`.
    static func deltas(from base: ChordProjection, to tgt: ChordProjection) -> [ConfigProjection.MetricDelta] {
        var out: [ConfigProjection.MetricDelta] = []
        for (label, a, b) in [("Fix", base.fixPct, tgt.fixPct), ("Reply", base.replyPct, tgt.replyPct)] {
            if let a, let b, a != b {
                out.append(.init(label: label, text: b > a ? String(localized: "+\(b - a) pp") : String(localized: "−\(a - b) pp"),
                                 improved: b > a))
            }
        }
        // Speed and memory read exactly as they do on the completion rail.
        let speedAndMemory = ConfigProjection.deltas(
            from: ConfigProjection(p50Ms: base.p50Ms, ramGB: base.ramGB),
            to: ConfigProjection(p50Ms: tgt.p50Ms, ramGB: tgt.ramGB))
        return out + speedAndMemory
    }
}

extension ConfigProjection {
    /// Only latency and memory — for `ChordProjection.deltas`.
    fileprivate init(p50Ms: Int?, ramGB: Double?) {
        self.init(accuracyPct: nil, accuracyText: "", accuracySub: "", coveragePct: nil,
                  p50Ms: p50Ms, latencyIsApprox: false, latencySub: "",
                  ramGB: ramGB, memorySub: "", computeRel: nil, computeSub: "")
    }
}

/// What a configuration measures to — accuracy, coverage, latency, memory and
/// (estimated) compute — derived only from eval-backed figures in
/// `ModelMetrics` plus measured factors (length sweep, gate runs). The single
/// source for the Live Impact rail, the delta strips and the model map, so
/// every surface shows the same truth for the same config.
struct ConfigProjection {
    // Accuracy of shown suggestions, %.
    let accuracyPct: Int?          // nil = not measured
    let accuracyText: String       // "33%", "62–67%", "~0%", "—"
    let accuracySub: String
    let coveragePct: Int?

    // Latency, warm median per suggestion.
    let p50Ms: Int?
    let latencyIsApprox: Bool      // scaled by a measured factor, not a direct run
    let latencySub: String

    // Memory: resident weights of what would actually run.
    let ramGB: Double?
    let memorySub: String

    // Chip load per keystroke relative to the default config — the one
    // estimated (not measured) figure on the rail, labeled "est." in the UI.
    let computeRel: Double?        // nil = system model (Neural Engine)
    let computeSub: String

    // MARK: Projection

    /// Measured length factors (EN+RU core, 2026-10-15). Base has none: the
    /// entropy stop ends a base suggestion near its second word, inside even
    /// Short's budget, so all three lengths decode the same text (E2B 4-bit
    /// and Qwen3.5 2B: identical outputs, 35/35/34 and 33/33/33 ms). Instruct
    /// follows the directive's word hint: 98 / 127 / 163 ms on E4B-it. Base
    /// Medium/Long on the tiers that write long text run untrimmed
    /// (`ModelCatalog.writesLongBase`): 130 / 276 / 380 ms on E4B 6-bit and
    /// 137 / 401 / 440 on 8-bit for the whole suggestion (eval-long, one
    /// interleaved pass, Eval/runs-2026-10-28-issue4/e2e); the first word
    /// streams in as fast as Short's.
    static func latencyFactor(_ length: CompletionLength, style: CompletionStyle, modelID: String) -> Double {
        if style == .base {
            guard ModelCatalog.writesLongBase(modelID) else { return 1.0 }
            switch length {
            case .short: return 1.0
            case .medium: return 2.5
            case .long: return 3.1
            }
        }
        switch length {
        case .short: return 1.0
        case .medium: return 1.3
        case .long: return 1.7
        }
    }

    /// Reference for the compute estimate: MiniCPM5 1B, base, short = 1×.
    /// A fixed yardstick (the default when it was set), not today's default.
    private static let computeReferenceGB = 2.2

    /// `servesTable`: whether the table is served from disk on a model
    /// (`HostPLE.servesTable`); tests pin it instead of reading this Mac's disk.
    static func project(_ c: ProjectionConfig, pleFromDisk: Bool = Settings.pleFromDisk,
                        servesTable: (String) -> Bool = { HostPLE.servesTable(of: $0) }) -> ConfigProjection {
        guard let m = ModelMetrics.metrics(for: c.modelID) else {
            return ConfigProjection(
                accuracyPct: nil, accuracyText: "—",
                accuracySub: String(localized: "No eval figures — run it through the harness to compare."),
                coveragePct: nil,
                p50Ms: nil, latencyIsApprox: false, latencySub: String(localized: "not measured"),
                ramGB: nil, memorySub: String(localized: "not measured"),
                computeRel: nil, computeSub: String(localized: "not measured"))
        }
        let isAI = c.modelID == ModelCatalog.appleIntelligenceID
        let lf = latencyFactor(c.length, style: c.style, modelID: c.modelID)

        if isAI {
            return ConfigProjection(
                accuracyPct: m.firstWordPct, accuracyText: "\(m.firstWordPct)%",
                accuracySub: String(localized: "offers \(m.coveragePct)% of the time · \(ModelMetrics.evalSource)"),
                coveragePct: m.coveragePct,
                p50Ms: m.p50Ms, latencyIsApprox: true,
                latencySub: String(localized: "median on the Neural Engine — an upper bound"),
                ramGB: 0, memorySub: String(localized: "system model — no app memory"),
                computeRel: nil, computeSub: String(localized: "Neural Engine — low, efficient"))
        }

        if c.style == .instruct {
            let usable = ModelCatalog.instructCompletes(c.modelID)
            let gb = ModelMetrics.instructRamGB(for: c.modelID) ?? m.ramGB
            let resident = HostPLE.residentGB(gb, of: c.primaryModelID, pleFromDisk: pleFromDisk, servesTable: servesTable)
            if !usable {
                return ConfigProjection(
                    accuracyPct: 0, accuracyText: "~0%",
                    accuracySub: String(localized: "broken combination — this model answers the text instead of continuing it"),
                    coveragePct: 99,
                    p50Ms: m.p50Ms, latencyIsApprox: true, latencySub: String(localized: "base-model figure — instruct unmeasured here"),
                    gb: gb, residentGB: resident, memorySub: String(localized: "instruct sibling weights (hub size)"), lengthFactor: lf)
            }
            // Usable means the measured it-6bit sibling (the E4B tiers).
            let it = ModelMetrics.instructCompletion
            let ms = Int((Double(it.p50Ms) * lf).rounded())
            return ConfigProjection(
                accuracyPct: it.firstWordPct, accuracyText: "\(it.firstWordPct)%",
                accuracySub: String(localized: "offers \(it.coveragePct)% of the time on real text, where Base measures \(m.firstWordPct)% · 85% on text you author (eval-v2, with persona)"),
                coveragePct: it.coveragePct,
                p50Ms: ms, latencyIsApprox: lf > 1,
                latencySub: lf > 1 ? String(localized: "instruct sibling, scaled by the measured length factor") : String(localized: "instruct sibling, measured (it-6bit)"),
                gb: gb, residentGB: resident, memorySub: String(localized: "instruct sibling weights (hub size)"), lengthFactor: lf)
        }

        // Base style — the only path the gate applies to.
        let ms = Int((Double(m.p50Ms) * lf).rounded())
        let resident = HostPLE.residentGB(m.ramGB, of: c.modelID, pleFromDisk: pleFromDisk, servesTable: servesTable)
        if c.logprobGate, let g = ModelMetrics.gated[c.modelID] {
            return ConfigProjection(
                accuracyPct: g.firstWordPct, accuracyText: "\(g.firstWordPct)%",
                accuracySub: String(localized: "offers \(g.shownPct)% of the time at this model's own threshold · \(ModelMetrics.evalSource)"),
                coveragePct: g.shownPct,
                p50Ms: ms, latencyIsApprox: lf > 1, latencySub: String(localized: "no added latency over plain Base"),
                gb: m.ramGB, residentGB: resident, lengthFactor: lf)
        }
        return ConfigProjection(
            accuracyPct: m.firstWordPct,
            accuracyText: "\(m.firstWordPct)%",
            accuracySub: String(localized: "offers \(m.coveragePct)% of the time · \(ModelMetrics.evalSource)"),
            coveragePct: m.coveragePct,
            p50Ms: ms, latencyIsApprox: lf > 1,
            latencySub: lf > 1 ? String(localized: "scaled by the measured length factor") : String(localized: "median per suggestion, measured"),
            gb: m.ramGB, residentGB: resident, lengthFactor: lf)
    }

    // MARK: Meter fractions (0…1, longer bar = better)

    /// Shared axis bounds so bars and the model map agree. Accuracy tops out
    /// just above the best gated projection; speed/compute are log-scaled like
    /// the map. The ms range hugs the reachable envelope — the fastest small
    /// model (17 ms) up to the system model — so exotic manual combos clamp
    /// at the edge rather than squeezing every model into one third of the
    /// chart.
    enum Scale {
        static let accMin = 15.0
        static let accMax = 72.0
        static let msRange = 15.0...800.0
        static let computeRange = 0.4...24.0
        static let gbMax = 8.6

        static func logFraction(_ v: Double, in r: ClosedRange<Double>) -> Double {
            let clamped = min(max(v, r.lowerBound), r.upperBound)
            return (log(clamped) - log(r.lowerBound)) / (log(r.upperBound) - log(r.lowerBound))
        }
    }

    var accuracyFraction: Double? {
        accuracyPct.map { max(0.04, min(1, Double($0) / Scale.accMax)) }
    }
    var speedFraction: Double? {
        p50Ms.map { max(0.04, 1 - Scale.logFraction(Double($0), in: Scale.msRange)) }
    }
    var memoryFraction: Double? {
        guard let gb = ramGB else { return nil }
        return gb <= 0 ? 1 : max(0.06, 1 - gb / Scale.gbMax)
    }
    var computeFraction: Double? {
        guard let rel = computeRel else { return 0.95 }  // system model: off-chart light
        return max(0.04, 1 - Scale.logFraction(rel, in: Scale.computeRange))
    }

    // MARK: Formatting

    var latencyText: String {
        p50Ms.map { (latencyIsApprox ? "≈" : "") + latencyLabel(ms: $0) } ?? "—"
    }
    var memoryText: String { ramGB.map(gbLabel) ?? "—" }
    var computeText: String {
        guard let rel = computeRel else { return "ANE" }
        return rel < 10 ? "\(oneDecimal(rel))×" : "\(Int(rel.rounded()))×"
    }

    // MARK: Deltas

    /// One metric's change between two projections, for delta chips.
    struct MetricDelta: Identifiable {
        let label: String     // "Accuracy"
        let text: String      // "+25 pp", "3× slower"
        let improved: Bool
        var id: String { label }
    }

    /// Human-readable differences target − base, omitting negligible ones.
    static func deltas(from base: ConfigProjection, to tgt: ConfigProjection) -> [MetricDelta] {
        var out: [MetricDelta] = []
        if let a = base.accuracyPct, let b = tgt.accuracyPct, abs(a - b) >= 1 {
            out.append(MetricDelta(label: "Accuracy",
                                   text: b > a ? String(localized: "+\(abs(b - a)) pp") : String(localized: "−\(abs(b - a)) pp"),
                                   improved: b > a))
        }
        if let a = base.p50Ms, let b = tgt.p50Ms, a != b {
            let faster = b < a
            let ratio = faster ? Double(a) / Double(b) : Double(b) / Double(a)
            out.append(MetricDelta(label: "Speed",
                                   text: faster ? String(localized: "\(ratioText(ratio)) faster")
                                                : String(localized: "\(ratioText(ratio)) slower"),
                                   improved: faster))
        }
        if let a = base.ramGB, let b = tgt.ramGB, abs(a - b) >= 0.1 {
            out.append(MetricDelta(label: "Memory",
                                   text: String(localized: "\(b < a ? "−" : "+")\(oneDecimal(abs(b - a))) GB"),
                                   improved: b < a))
        }
        if let a = base.computeRel, let b = tgt.computeRel, abs(a - b) >= 0.1 {
            let lighter = b < a
            let ratio = lighter ? a / b : b / a
            if ratio >= 1.1 {
                out.append(MetricDelta(label: "Compute",
                                       text: lighter ? String(localized: "\(ratioText(ratio)) lighter")
                                                     : String(localized: "\(ratioText(ratio)) heavier"),
                                       improved: lighter))
            }
        }
        return out
    }

    /// "3.5×", "4×", "12×" — one decimal below 10 (rounding 3.5 up to "4×"
    /// next to the exact target value read as a contradiction), whole above.
    private static func ratioText(_ ratio: Double) -> String {
        ratio >= 10 ? "\(Int(ratio.rounded()))×"
                    : String(format: "%g×", (ratio * 10).rounded() / 10)
    }
}

extension ConfigProjection {
    /// A config that runs `gb` of MLX weights, `residentGB` of them in memory
    /// (`HostPLE.residentGB`). The compute estimate follows all the weights
    /// (that much read per decoded token, times the measured length factor):
    /// a table served from disk saves memory, not work.
    init(accuracyPct: Int, accuracyText: String, accuracySub: String, coveragePct: Int,
         p50Ms: Int, latencyIsApprox: Bool, latencySub: String,
         gb: Double, residentGB: Double, memorySub: String = String(localized: "resident model weights"), lengthFactor: Double) {
        self.init(accuracyPct: accuracyPct, accuracyText: accuracyText, accuracySub: accuracySub,
                  coveragePct: coveragePct, p50Ms: p50Ms, latencyIsApprox: latencyIsApprox,
                  latencySub: latencySub, ramGB: residentGB, memorySub: memorySub,
                  computeRel: gb * lengthFactor / Self.computeReferenceGB,
                  computeSub: String(localized: "chip load per keystroke vs default (est.)"))
    }
}
