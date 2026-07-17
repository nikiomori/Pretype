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
    var confidenceGate: Bool
    var useRecommended: Bool

    /// One user gesture on one control.
    enum Change: Equatable {
        case model(String)
        case style(CompletionStyle)
        case length(CompletionLength)
        case logprobGate(Bool)
        case confidenceGate(Bool)
        case useRecommended(Bool)
        /// A priority preset: this model in its measured-protocol config
        /// (Base · Short — the exact figures the preset card advertises),
        /// keeping the user's precision gates where the model supports them.
        case preset(String)
        /// Jump to an exact configuration — a settings dot on the model map.
        case config(ProjectionConfig)
    }

    /// Same runtime state, ignoring the auto-mode flag — what the map's
    /// marker and settings dots compare by.
    func sameRuntime(as other: ProjectionConfig) -> Bool {
        modelID == other.modelID && style == other.style && length == other.length
            && logprobGate == other.logprobGate && confidenceGate == other.confidenceGate
    }

    /// The same dependency cascades the pipeline applies on commit:
    /// recommended mode snaps style/length and clears gates; instruct has no
    /// gate path; the two gates are mutually exclusive; the consensus gate
    /// needs a gate-capable model.
    func applying(_ change: Change) -> ProjectionConfig {
        var c = self
        switch change {
        case .model(let id):
            c.modelID = id
            let rec = ModelCatalog.recommended(for: id)
            if c.useRecommended {
                c.style = rec.style
                c.length = rec.length
                c.logprobGate = false
                c.confidenceGate = false
            }
            // A switch to a base-only model never keeps the measured-broken
            // Instruct style; and if the landing style is still Instruct
            // (stale persisted state), the Base-only gates cannot survive.
            if rec.style == .base, c.style == .instruct { c.style = .base }
            if c.style != .base {
                c.logprobGate = false
                c.confidenceGate = false
            }
            if !rec.gateCapable { c.confidenceGate = false }
        case .style(let s):
            c.style = s
            c.useRecommended = false
            if s == .instruct {
                c.logprobGate = false
                c.confidenceGate = false
            }
        case .length(let l):
            c.length = l
            c.useRecommended = false
        case .logprobGate(let on):
            c.logprobGate = on
            if on { c.confidenceGate = false }
        case .confidenceGate(let on):
            c.confidenceGate = on
            if on { c.logprobGate = false }
        case .useRecommended(let on):
            c.useRecommended = on
            if on {
                let rec = ModelCatalog.recommended(for: c.modelID)
                c.style = rec.style
                c.length = rec.length
                c.logprobGate = false
                c.confidenceGate = false
            }
        case .preset(let id):
            c.modelID = id
            // Land on the measured protocol the card's figures come from —
            // NOT the recommendation, which for Gemma is Instruct and measures
            // very differently (22% real text) than what the card promises.
            c.style = .base
            c.length = .short
            let rec = ModelCatalog.recommended(for: id)
            if !rec.gateCapable { c.confidenceGate = false }
            // Auto mode stays only where the recommendation IS this landing
            // state; otherwise it would immediately re-snap style to Instruct.
            c.useRecommended = rec.style == .base && rec.length == .short
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
        case .lightest: return "Lightest"
        case .quick: return "Quick & accurate"
        case .accurate: return "Most accurate"
        case .balanced: return "Balanced"
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
        case .lightest: return "Smallest footprint — for Macs with little free memory."
        case .quick: return "Fastest of the models within 2 pp of the best accuracy."
        case .accurate: return "Best measured accuracy; first-word ties break on reference scoring."
        case .balanced: return "The out-of-the-box pick: fastest at near-parity on English and Russian; the best small multilingual model on other languages."
        }
    }

    /// The downloadable measured catalog (system model and local fine-tunes
    /// have no place in a footprint/speed contest).
    private static var measured: [ModelMetrics] {
        ModelMetrics.all.filter { $0.ramGB > 0 }
    }

    /// Measured-best model for the goal ON the given accuracy axis (see
    /// `Settings.accuracyAxis`) — the whole tab re-resolves when the axis
    /// changes, so "Most accurate" means most accurate for YOUR language.
    func pick(axis: String) -> String {
        let pool = Self.measured
        guard !pool.isEmpty else { return ModelCatalog.defaultID }
        func acc(_ m: ModelMetrics) -> Int {
            ModelMetrics.axisAccuracy(for: m.id, axis: axis) ?? m.firstWordPct
        }
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
            // Same rule as the fresh-install default, keyed on the axis instead
            // of the keyboards: on EN/RU the fastest model at parity with the
            // big ones; elsewhere the EN/RU specialist gives way to the best
            // small multilingual pick (the Gemmas above it are Accurate/Quick
            // territory).
            return ["core", "en", "ru"].contains(axis)
                ? "openbmb/MiniCPM5-1B-Base" : "mlx-community/Qwen3.5-2B-4bit"
        }
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
    /// Instruct on a model that answers instead of continuing (~0% measured).
    let broken: Bool
    /// Instruct's authored-text figure (85%) alongside the real-text one.
    let authoredPct: Int?

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

    /// Measured length factors from the sweep (short 157 / medium 291 / long
    /// 550 ms p50, eval-real 2026-07-13).
    static func latencyFactor(_ length: CompletionLength) -> Double {
        switch length {
        case .word, .short: return 1.0
        case .medium: return 1.85
        case .long: return 3.5
        }
    }

    /// Decode-token factor, derived from the sampler's actual per-length
    /// budgets so a retune there can't leave a stale mirror here.
    private static func tokenFactor(_ length: CompletionLength) -> Double {
        Double(length.maxTokens) / Double(CompletionLength.short.maxTokens)
    }

    /// Reference for the compute estimate: the default config (MiniCPM5 1B,
    /// base, short, single sample) = 1×.
    private static let computeReferenceGB = 2.2

    static func project(_ c: ProjectionConfig) -> ConfigProjection {
        guard let m = ModelMetrics.metrics(for: c.modelID) else {
            return ConfigProjection(
                accuracyPct: nil, accuracyText: "—",
                accuracySub: "No eval figures — run it through the harness to compare.",
                coveragePct: nil, broken: false, authoredPct: nil,
                p50Ms: nil, latencyIsApprox: false, latencySub: "not measured",
                ramGB: nil, memorySub: "not measured",
                computeRel: nil, computeSub: "not measured")
        }
        let rec = ModelCatalog.recommended(for: c.modelID)
        let isAI = c.modelID == ModelCatalog.appleIntelligenceID
        let lf = latencyFactor(c.length)

        if isAI {
            return ConfigProjection(
                accuracyPct: m.firstWordPct, accuracyText: "\(m.firstWordPct)%",
                accuracySub: "offers \(m.coveragePct)% of the time · \(ModelMetrics.evalSource)",
                coveragePct: m.coveragePct, broken: false, authoredPct: nil,
                p50Ms: m.p50Ms, latencyIsApprox: true,
                latencySub: "median on the Neural Engine — an upper bound",
                ramGB: 0, memorySub: "system model — no app memory",
                computeRel: nil, computeSub: "Neural Engine — low, efficient")
        }

        if c.style == .instruct {
            let usable = rec.style == .instruct
            let gb = ModelMetrics.instructRamGB(for: c.modelID) ?? m.ramGB
            if !usable {
                return ConfigProjection(
                    accuracyPct: 0, accuracyText: "~0%",
                    accuracySub: "broken combination — this model answers the text instead of continuing it",
                    coveragePct: 99, broken: true, authoredPct: nil,
                    p50Ms: m.p50Ms, latencyIsApprox: true, latencySub: "base-model figure — instruct unmeasured here",
                    ramGB: gb, memorySub: "instruct sibling weights (hub size)",
                    computeRel: gb * tokenFactor(c.length) / computeReferenceGB,
                    computeSub: "chip load per keystroke vs default (est.)")
            }
            // Only the it-6bit instruct sibling went through the harness — the
            // measured 129 ms applies exactly to models that RUN that sibling
            // (the E2B tiers run 4-bit siblings, unmeasured). Elsewhere the base
            // figure stands in, marked ≈ and labeled as an estimate.
            let measuredMs: Int? = ModelCatalog.option(for: c.modelID)?.instructModelID
                == "mlx-community/gemma-4-e4b-it-6bit" ? 129 : nil
            return ConfigProjection(
                accuracyPct: 22, accuracyText: "22%",
                accuracySub: "real text · 85% on text you author (eval-v2, with persona)",
                coveragePct: 99, broken: false, authoredPct: 85,
                p50Ms: measuredMs ?? m.p50Ms, latencyIsApprox: measuredMs == nil,
                latencySub: measuredMs != nil ? "instruct sibling, measured (it-6bit)"
                                              : "base-model figure — the instruct sibling on this tier is unmeasured",
                ramGB: gb, memorySub: "instruct sibling weights (hub size)",
                computeRel: gb * tokenFactor(c.length) / computeReferenceGB,
                computeSub: "chip load per keystroke vs default (est.)")
        }

        // Base style. Gates apply only here; callers keep them mutually
        // exclusive, but project defensively in confidence-first order.
        if c.confidenceGate && rec.gateCapable {
            let ms = Int((Double(m.p50Ms) * lf * 5).rounded())
            return ConfigProjection(
                accuracyPct: 39, accuracyText: "≈39%",
                accuracySub: "offers 54% of the time — 5-sample consensus (eval-real 2026-06-26, E4B-8bit)",
                coveragePct: 54, broken: false, authoredPct: nil,
                p50Ms: ms, latencyIsApprox: true, latencySub: "×5 samples per keystroke",
                ramGB: m.ramGB, memorySub: "resident model weights",
                computeRel: m.ramGB * tokenFactor(c.length) * 5 / computeReferenceGB,
                computeSub: "chip load per keystroke vs default (est.)")
        }
        if c.logprobGate {
            let ms = Int((Double(m.p50Ms) * lf).rounded())
            // The calibration (62–67% shown at ~30% offered) was measured on
            // MiniCPM5 only (split-half, eval-real n=870, 2026-07-15) — pinned
            // to that id, NOT to the language-aware defaultID. Other models get
            // the same measured TRADE scaled from their own base figures — the
            // ratios read the calibration model's eval row, so a re-run can't
            // leave a stale divisor here — capped and labeled as scaled, never
            // as measured.
            let calibrationID = "openbmb/MiniCPM5-1B-Base"
            let calibrated = c.modelID == calibrationID
            let ref = ModelMetrics.metrics(for: calibrationID)
            let accLift = 64.0 / Double(ref?.firstWordPct ?? 30)
            let covFactor = 30.0 / Double(ref?.coveragePct ?? 83)
            let acc = calibrated ? 64 : min(72, Int((Double(m.firstWordPct) * accLift).rounded()))
            let cov = calibrated ? 30 : Int((Double(m.coveragePct) * covFactor).rounded())
            return ConfigProjection(
                accuracyPct: acc, accuracyText: calibrated ? "62–67%" : "≈\(acc)%",
                accuracySub: calibrated
                    ? "offers ~30% of the time — split-half calibration (eval-real, n=870, 2026-07-15)"
                    : "offers ~\(cov)% of the time — scaled from the default-model calibration (62–67% measured there), not measured on this model",
                coveragePct: cov, broken: false, authoredPct: nil,
                p50Ms: ms, latencyIsApprox: lf > 1, latencySub: "no added latency over plain Base",
                ramGB: m.ramGB, memorySub: "resident model weights",
                computeRel: m.ramGB * tokenFactor(c.length) / computeReferenceGB,
                computeSub: "chip load per keystroke vs default (est.)")
        }
        let ms = Int((Double(m.p50Ms) * lf).rounded())
        return ConfigProjection(
            accuracyPct: m.firstWordPct,
            accuracyText: "\(m.firstWordPct)%",
            accuracySub: "offers \(m.coveragePct)% of the time · \(ModelMetrics.evalSource)",
            coveragePct: m.coveragePct, broken: false, authoredPct: nil,
            p50Ms: ms, latencyIsApprox: lf > 1,
            latencySub: lf > 1 ? "scaled by the measured length factor" : "median per suggestion, measured",
            ramGB: m.ramGB, memorySub: "resident model weights",
            computeRel: m.ramGB * tokenFactor(c.length) / computeReferenceGB,
            computeSub: "chip load per keystroke vs default (est.)")
    }

    // MARK: Meter fractions (0…1, longer bar = better)

    /// Shared axis bounds so bars and the model map agree. Accuracy tops out
    /// just above the best gated projection; speed/compute are log-scaled like
    /// the map. msMax hugs the reachable envelope (base ×3.5 length, consensus
    /// ×5 at short, the system model) — exotic manual combos clamp at the edge
    /// rather than squeezing every model into the right third of the chart.
    enum Scale {
        static let accMin = 15.0
        static let accMax = 72.0
        static let msRange = 45.0...800.0
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
        guard let ms = p50Ms else { return "—" }
        let base = ms >= 1000 ? String(format: "%.1f s", Double(ms) / 1000) : "\(ms) ms"
        return latencyIsApprox ? "≈" + base : base
    }
    var memoryText: String {
        guard let gb = ramGB else { return "—" }
        return gb <= 0 ? "0 GB" : String(format: "%.1f GB", gb)
    }
    var computeText: String {
        guard let rel = computeRel else { return "ANE" }
        return rel < 10 ? String(format: "%.1f×", rel) : "\(Int(rel.rounded()))×"
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
                                   text: (b > a ? "+" : "−") + "\(abs(b - a)) pp",
                                   improved: b > a))
        }
        if let a = base.p50Ms, let b = tgt.p50Ms, a != b {
            let faster = b < a
            let ratio = faster ? Double(a) / Double(b) : Double(b) / Double(a)
            out.append(MetricDelta(label: "Speed",
                                   text: ratioText(ratio) + (faster ? " faster" : " slower"),
                                   improved: faster))
        }
        if let a = base.ramGB, let b = tgt.ramGB, abs(a - b) >= 0.1 {
            out.append(MetricDelta(label: "Memory",
                                   text: String(format: "%@%.1f GB", b < a ? "−" : "+", abs(b - a)),
                                   improved: b < a))
        }
        if let a = base.computeRel, let b = tgt.computeRel, abs(a - b) >= 0.1 {
            let lighter = b < a
            let ratio = lighter ? a / b : b / a
            if ratio >= 1.1 {
                out.append(MetricDelta(label: "Compute",
                                       text: ratioText(ratio) + (lighter ? " lighter" : " heavier"),
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
