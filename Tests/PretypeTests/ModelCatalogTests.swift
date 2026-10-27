import XCTest
@testable import Pretype

final class ModelCatalogTests: XCTestCase {
    func testEveryGemmaInstructModelHasAnMTPDrafter() {
        for option in ModelCatalog.options {
            for id in [option.correctionModelID, option.instructModelID] where id.contains("gemma-4") {
                XCTAssertNotNil(ModelCatalog.mtpDrafterID(for: id), id)
            }
        }
        // Drafters are trained against the -it models only.
        XCTAssertNil(ModelCatalog.mtpDrafterID(for: "mlx-community/gemma-4-e2b-4bit"))
        XCTAssertNil(ModelCatalog.mtpDrafterID(for: "nikimori/Qwen3.5-2B-Base-6bit"))
    }

    // ConfigProjection powers everything the settings UI claims a setting will
    // do — pin the cascade rules and the eval-backed figures it projects.
    func testConfigProjectionCascades() {
        let e4b6 = "mlx-community/gemma-4-e4b-6bit"
        let mini = "nikimori/MiniCPM5-1B-Base-8bit"
        var c = ProjectionConfig(modelID: e4b6, style: .base, length: .short,
                                 logprobGate: true, useRecommended: false)

        // Instruct has no gate path.
        c = c.applying(.style(.instruct))
        XCTAssertFalse(c.logprobGate)
        XCTAssertFalse(c.useRecommended)

        // Recommended mode snaps style/length to the model's measured best.
        c = c.applying(.useRecommended(true))
        XCTAssertEqual(c.style, ModelCatalog.recommended(for: e4b6).style)

        // A model switch never carries Instruct onto a base-only model where
        // it's measured-broken — style snaps to Base even in manual mode.
        var instructed = ProjectionConfig(modelID: e4b6, style: .instruct, length: .short,
                                          logprobGate: false,
                                          useRecommended: false)
        instructed = instructed.applying(.model(mini))
        XCTAssertEqual(instructed.style, .base)

        // Stale persisted state (gate set alongside Instruct, from before the
        // hygiene existed): a model switch heals it — Base-only gates never
        // survive an Instruct landing. The coordinator commits through this
        // same cascade, so preview and pipeline agree by construction.
        var stale = ProjectionConfig(modelID: e4b6, style: .instruct, length: .short,
                                     logprobGate: true,
                                     useRecommended: false)
        stale = stale.applying(.model("mlx-community/gemma-4-e4b-8bit"))
        XCTAssertEqual(stale.style, .instruct)   // usable here, kept
        XCTAssertFalse(stale.logprobGate)        // but the gate cannot ride along

        // In recommended mode a model switch re-snaps everything.
        var auto = ProjectionConfig(modelID: mini, style: .base, length: .long,
                                    logprobGate: true,
                                    useRecommended: true)
        auto = auto.applying(.model(e4b6))
        XCTAssertEqual(auto.style, .base)  // E4B's measured best since 2026-10-15
        XCTAssertEqual(auto.length, .short)
        XCTAssertFalse(auto.logprobGate)
    }

    // Each gesture's whole effect on the configuration, every field.
    func testEachGesturesWholeEffect() {
        let e4b6 = "mlx-community/gemma-4-e4b-6bit", e4b8 = "mlx-community/gemma-4-e4b-8bit"
        let mini = "nikimori/MiniCPM5-1B-Base-8bit"
        func cfg(_ id: String, _ style: CompletionStyle, _ length: CompletionLength,
                 gate: Bool, auto: Bool) -> ProjectionConfig {
            ProjectionConfig(modelID: id, style: style, length: length, logprobGate: gate, useRecommended: auto)
        }
        // A model switch keeps a manual setup; recommended mode re-snaps it.
        XCTAssertEqual(cfg(e4b6, .base, .medium, gate: true, auto: false).applying(.model(mini)),
                       cfg(mini, .base, .medium, gate: true, auto: false))
        XCTAssertEqual(cfg(mini, .instruct, .long, gate: true, auto: true).applying(.model(e4b8)),
                       cfg(e4b8, .base, .short, gate: false, auto: true))
        // Style and length are manual choices: they leave recommended mode;
        // Instruct drops the Base-only gate, Base keeps it.
        XCTAssertEqual(cfg(e4b6, .base, .short, gate: true, auto: true).applying(.style(.instruct)),
                       cfg(e4b6, .instruct, .short, gate: false, auto: false))
        XCTAssertEqual(cfg(e4b6, .instruct, .short, gate: true, auto: false).applying(.style(.base)),
                       cfg(e4b6, .base, .short, gate: true, auto: false))
        XCTAssertEqual(cfg(e4b6, .base, .short, gate: true, auto: true).applying(.length(.long)),
                       cfg(e4b6, .base, .long, gate: true, auto: false))
        XCTAssertEqual(cfg(e4b6, .base, .short, gate: false, auto: true).applying(.logprobGate(true)),
                       cfg(e4b6, .base, .short, gate: true, auto: true))
        XCTAssertEqual(cfg(e4b6, .instruct, .long, gate: true, auto: false).applying(.useRecommended(true)),
                       cfg(e4b6, .base, .short, gate: false, auto: true))
        XCTAssertEqual(cfg(e4b6, .instruct, .long, gate: true, auto: true).applying(.useRecommended(false)),
                       cfg(e4b6, .instruct, .long, gate: true, auto: false))
        // A preset lands on the measured protocol, keeping the gate.
        XCTAssertEqual(cfg(mini, .instruct, .long, gate: true, auto: false).applying(.preset(e4b6)),
                       cfg(e4b6, .base, .short, gate: true, auto: true))
        XCTAssertEqual(cfg(mini, .base, .long, gate: false, auto: true).applying(.preset(ModelCatalog.appleIntelligenceID)),
                       cfg(ModelCatalog.appleIntelligenceID, .base, .short, gate: false, auto: false))
        let target = cfg(mini, .base, .long, gate: true, auto: false)
        XCTAssertEqual(cfg(e4b6, .instruct, .short, gate: false, auto: true).applying(.config(target)), target)
        // The map's markers compare runtime state, not the auto flag.
        let runtime = cfg(e4b6, .base, .short, gate: true, auto: true)
        XCTAssertTrue(runtime.sameRuntime(as: cfg(e4b6, .base, .short, gate: true, auto: false)))
        for other in [cfg(e4b8, .base, .short, gate: true, auto: true), cfg(e4b6, .instruct, .short, gate: true, auto: true),
                      cfg(e4b6, .base, .long, gate: true, auto: true), cfg(e4b6, .base, .short, gate: false, auto: true)] {
            XCTAssertFalse(runtime.sameRuntime(as: other), "\(other)")
        }
    }

    // The rail's meters, chips and labels, at their edges.
    func testTheRailsMetersChipsAndLabels() {
        func proj(acc: Int? = nil, ms: Int? = nil, gb: Double? = nil, compute: Double? = nil) -> ConfigProjection {
            ConfigProjection(accuracyPct: acc, accuracyText: "", accuracySub: "", coveragePct: nil, p50Ms: ms,
                             latencyIsApprox: false, latencySub: "", ramGB: gb, memorySub: "",
                             computeRel: compute, computeSub: "")
        }
        // Bars: clamped into 0.04…1 (memory 0.06…1), longer = better.
        XCTAssertEqual(proj(acc: 0).accuracyFraction, 0.04)
        XCTAssertEqual(proj(acc: 100).accuracyFraction, 1)
        XCTAssertEqual(proj(acc: 36).accuracyFraction ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(proj(ms: 15).speedFraction, 1)
        XCTAssertEqual(proj(ms: 800).speedFraction, 0.04)
        XCTAssertEqual(proj(gb: 0).memoryFraction, 1)
        XCTAssertEqual(proj(gb: 0.5).memoryFraction ?? 0, 1 - 0.5 / 8.6, accuracy: 1e-9)
        XCTAssertEqual(proj(gb: 8.6).memoryFraction, 0.06)
        XCTAssertEqual(proj().computeFraction, 0.95, "the system model: off-chart light")
        XCTAssertEqual(proj(compute: 0.4).computeFraction, 1)
        XCTAssertEqual(proj(compute: 24).computeFraction, 0.04)
        XCTAssertEqual(proj(compute: 3.25).computeText, oneDecimal(3.25) + "×")
        XCTAssertEqual(proj(compute: 10).computeText, "10×")
        XCTAssertEqual(proj(compute: 10.4).computeText, "10×")

        func chips(_ from: ConfigProjection, _ to: ConfigProjection) -> [String] {
            ConfigProjection.deltas(from: from, to: to).map { "\($0.label) \($0.text) \($0.improved)" }
        }
        XCTAssertEqual(chips(proj(acc: 30), proj(acc: 31)), ["Accuracy +1 pp true"])
        XCTAssertEqual(chips(proj(acc: 31), proj(acc: 30)), ["Accuracy −1 pp false"])
        XCTAssertEqual(chips(proj(acc: 30), proj(acc: 30)), [])
        XCTAssertEqual(chips(proj(ms: 346), proj(ms: 100)), ["Speed 3.5× faster true"])
        XCTAssertEqual(chips(proj(ms: 100), proj(ms: 1040)), ["Speed 10× slower false"])
        XCTAssertEqual(chips(proj(ms: 100), proj(ms: 100)), [])
        XCTAssertEqual(chips(proj(gb: 5), proj(gb: 3.4)), ["Memory −\(oneDecimal(1.6)) GB true"])
        XCTAssertEqual(chips(proj(gb: 0.1), proj(gb: 0)), ["Memory −\(oneDecimal(0.1)) GB true"])
        XCTAssertEqual(chips(proj(gb: 3.4), proj(gb: 3.45)), [])
        XCTAssertEqual(chips(proj(compute: 0.2), proj(compute: 0.1)), ["Compute 2× lighter true"])
        XCTAssertEqual(chips(proj(compute: 1), proj(compute: 1.1)), ["Compute 1.1× heavier false"])
        XCTAssertEqual(chips(proj(compute: 10), proj(compute: 10.5)), [], "5% is no chip")
        XCTAssertEqual(chips(proj(compute: 0.5), proj(compute: 0.55)), [], "nor is 0.05")
    }

    func testConfigProjectionFigures() {
        let e4b6 = "mlx-community/gemma-4-e4b-6bit"
        let mini = "nikimori/MiniCPM5-1B-Base-8bit"
        func cfg(_ id: String, _ style: CompletionStyle, _ length: CompletionLength = .short,
                 logprob: Bool = false) -> ConfigProjection {
            ConfigProjection.project(ProjectionConfig(
                modelID: id, style: style, length: length,
                logprobGate: logprob, useRecommended: false))
        }

        // Plain base = the model's own eval row.
        let base = cfg(mini, .base)
        XCTAssertEqual(base.accuracyPct, 29)
        XCTAssertEqual(base.p50Ms, 18)
        XCTAssertEqual(base.ramGB, 1.1)

        // Instruct on a base-only model is truthfully broken, not hidden.
        let broken = cfg(mini, .instruct)
        XCTAssertEqual(broken.accuracyPct, 0)

        // Instruct on E4B: the measured it-6bit sibling, second-model memory.
        let instruct = cfg(e4b6, .instruct)
        XCTAssertEqual(instruct.accuracyPct, 20)
        XCTAssertEqual(instruct.p50Ms, 91)

        // Instruct on E2B is broken like on the smalls; the base speed stands
        // in, marked as an estimate — never a blank speed meter.
        let instructE2B = cfg("mlx-community/gemma-4-e2b-8bit", .instruct)
        XCTAssertEqual(instructE2B.accuracyPct, 0)
        XCTAssertEqual(instructE2B.p50Ms, 46)
        XCTAssertTrue(instructE2B.latencyText.hasPrefix("≈"))

        // Logprob gate: each model's own measured trade, no scaling.
        let gated = cfg(mini, .base, logprob: true)
        XCTAssertEqual(gated.accuracyText, "53%")
        XCTAssertEqual(gated.coveragePct, 19)
        XCTAssertEqual(gated.p50Ms, 18)
        let gatedE4B = cfg(e4b6, .base, logprob: true)
        XCTAssertEqual(gatedE4B.accuracyPct, 56)
        XCTAssertFalse(gatedE4B.accuracyText.hasPrefix("≈"))
        let gatedQwen05 = cfg("mlx-community/Qwen2.5-0.5B-bf16", .base, logprob: true)
        XCTAssertNotEqual(gatedE4B.accuracyPct, gatedQwen05.accuracyPct)
        // Every downloadable model carries its own gate figure.
        for m in ModelMetrics.all where m.ramGB > 0 {
            XCTAssertNotNil(ModelMetrics.gated[m.id], "\(m.id) has no measured gate trade")
        }

        // Length: Base is length-inert (the entropy stop ends suggestions
        // inside Short's budget); Instruct scales by its measured factor.
        XCTAssertEqual(cfg(mini, .base, .long).p50Ms, 18)
        XCTAssertEqual(cfg(e4b6, .instruct, .long).p50Ms, Int((91 * 1.7).rounded()))
        // Measured is shown as measured; only a scaled figure is approximate.
        for measured in [cfg(mini, .base, .long), cfg(mini, .base, logprob: true), instruct, base] {
            XCTAssertFalse(measured.latencyText.hasPrefix("≈"), measured.latencySub)
        }
        XCTAssertEqual(cfg(mini, .base).latencySub, cfg(mini, .base, .long).latencySub)
        XCTAssertNotEqual(instruct.latencySub, cfg(e4b6, .instruct, .long).latencySub)
        XCTAssertTrue(cfg(e4b6, .instruct, .long).latencyText.hasPrefix("≈"))
        XCTAssertTrue(cfg(ModelCatalog.appleIntelligenceID, .instruct).latencyText.hasPrefix("≈"), "an upper bound")

        // System model: no app memory, compute is the Neural Engine.
        let ai = cfg(ModelCatalog.appleIntelligenceID, .instruct)
        XCTAssertEqual(ai.ramGB, 0)
        XCTAssertNil(ai.computeRel)
        XCTAssertEqual(ai.computeText, "ANE")

        // Deltas: switching MiniCPM base → E4B instruct costs memory, buys nothing real.
        let deltas = ConfigProjection.deltas(from: base, to: instruct)
        XCTAssertTrue(deltas.contains { $0.label == "Memory" && !$0.improved })
    }

    /// `revision(for:)` falls back to "main" without a word, which would hand
    /// that one download whatever was pushed last — so every repo the catalog
    /// can fetch, or still loads from an older install, must be pinned.
    func testEveryDownloadableRepoIsPinned() throws {
        let models = ModelCatalog.options.flatMap { [$0.id, $0.correctionModelID, $0.instructModelID] }
        var repos = Set(models).union(ModelCatalog.slimRepos.values).union(ModelCatalog.previousBuilds.keys)
            .union(models.compactMap(ModelCatalog.mtpDrafterID(for:)))
        try withScratchHub {
            for option in ModelCatalog.options { repos.formUnion(ModelStorage.repos(for: option.id)) }
        }
        for repo in repos { XCTAssertNotNil(ModelCatalog.pinnedRevisions[repo], repo) }
    }

    /// The "Reduce memory use" toggle moves every memory figure together: the
    /// rail's meter and the idle-unload line both read the projection, which
    /// reads `HostPLE.residentGB` — and compute does not move with it.
    func testResidentMemoryFollowsThePLEToggle() {
        let served = { (_: String) in true }
        let e4b6 = ProjectionConfig(modelID: "mlx-community/gemma-4-e4b-6bit", style: .base, length: .short,
                                    logprobGate: false, useRecommended: false)
        let off = ConfigProjection.project(e4b6, pleFromDisk: false, servesTable: served)
        let on = ConfigProjection.project(e4b6, pleFromDisk: true, servesTable: served)
        XCTAssertEqual(off.ramGB ?? 0, 5.03, accuracy: 0.001)
        XCTAssertEqual(on.ramGB ?? 0, 5.03 - 1.6, accuracy: 0.001)
        XCTAssertEqual(on.computeRel, off.computeRel)
        // Instruct runs the sibling, and the saving is the sibling's table.
        let e2bInstruct = ProjectionConfig(modelID: "mlx-community/gemma-4-e2b-8bit", style: .instruct, length: .short,
                                           logprobGate: false, useRecommended: false)
        XCTAssertEqual(ConfigProjection.project(e2bInstruct, pleFromDisk: true, servesTable: served).ramGB ?? 0, 4.57 - 1.6, accuracy: 0.001)
        // Off an internal disk, or after `install` declined: no saving claimed.
        XCTAssertEqual(ConfigProjection.project(e4b6, pleFromDisk: true, servesTable: { _ in false }).ramGB ?? 0, 5.03, accuracy: 0.001)
        // No per-layer table, nothing to subtract.
        XCTAssertEqual(HostPLE.residentGB(1.5, of: "nikimori/Qwen3.5-2B-Base-6bit", pleFromDisk: true), 1.5)
    }

    // The settings download gate asks about the weights a switch actually
    // loads — the instruct sibling in Instruct style — and names and sizes
    // that, not the base row the user clicked.
    @MainActor
    func testDownloadGateWeights() {
        let base = SettingsStore.weights(modelID: "mlx-community/gemma-4-e4b-8bit", style: .base)
        XCTAssertEqual(base.id, "mlx-community/gemma-4-e4b-8bit")
        XCTAssertEqual(base.name, "Gemma 4 E4B 8-bit")
        XCTAssertEqual(base.gb, 5.98, accuracy: 0.01)  // the slim download
        let instruct = SettingsStore.weights(modelID: "mlx-community/gemma-4-e4b-8bit", style: .instruct)
        XCTAssertEqual(instruct.id, "mlx-community/gemma-4-e4b-it-6bit")
        XCTAssertEqual(instruct.name, "Gemma 4 E4B 8-bit Instruct")
        XCTAssertEqual(instruct.gb, 5.56, accuracy: 0.01)  // its slim re-pack
        // One set of weights for both styles: nothing separate to fetch.
        XCTAssertEqual(SettingsStore.weights(modelID: "prism-ml/Ternary-Bonsai-4B-mlx-2bit", style: .instruct).id,
                       "prism-ml/Ternary-Bonsai-4B-mlx-2bit")
        // Qwen3.5 completes on its Base build; instruct runs the post-trained one.
        XCTAssertEqual(SettingsStore.weights(modelID: "nikimori/Qwen3.5-2B-Base-6bit", style: .instruct).id,
                       "mlx-community/Qwen3.5-2B-4bit")
        // The system model never downloads.
        XCTAssertTrue(ModelStorage.isFetched(
            SettingsStore.weights(modelID: ModelCatalog.appleIntelligenceID, style: .instruct).id))
        // The row caution reuses the auto-pick's quarter-of-memory rule.
        XCTAssertTrue(ModelCatalog.isHeavy(residentGB: 8.6, ramGB: 16))
        XCTAssertFalse(ModelCatalog.isHeavy(residentGB: 4, ramGB: 16))
    }

    // Priority presets resolve by dominance rules over the measured catalog,
    // per accuracy axis — pin the current answers so a catalog edit that
    // flips them is noticed.
    /// The goal cards never repeat a model, and never show "Most accurate"
    /// beside a card that matches its figure on less memory — on any axis.
    func testShownGoalCardsAreDistinctAndUndominated() {
        for axis in ["*", "core"] + ModelMetrics.evalLanguages {
            let cards = ModelPriority.shown(axis: axis)
            let picks = cards.map { $0.pick(axis: axis) }
            XCTAssertEqual(Set(picks).count, picks.count, axis)
            XCTAssertEqual(cards.first, .lightest, axis)
            guard cards.contains(.accurate),
                  let best = ModelMetrics.metrics(for: ModelPriority.accurate.pick(axis: axis)) else { continue }
            for card in cards where card != .accurate {
                guard let m = ModelMetrics.metrics(for: card.pick(axis: axis)) else { continue }
                XCTAssertFalse(ModelPriority.accuracy(m, axis: axis) >= ModelPriority.accuracy(best, axis: axis)
                               && m.ramGB < best.ramGB, "\(axis): \(card) matches Most accurate on less memory")
            }
        }
    }

    /// While the model only fixes, a card per fix model — two catalog
    /// entries sharing one would be the same card — and "Most accurate"
    /// lands on the best fixer, on the lighter of the entries that share it.
    func testChordGoalCardsOneFixModelEach() {
        let cards = ModelPriority.shownForChords()
        let fixers = cards.map { ModelMetrics.taskMetrics(for: $0.pickForChords(), style: .base)?.measuredID }
        XCTAssertEqual(Set(fixers).count, fixers.count)
        XCTAssertEqual(cards.first, .lightest)
        let best = ModelMetrics.taskMetrics(for: ModelPriority.accurate.pickForChords(), style: .base)?.m.fixPct
        XCTAssertEqual(best, ModelMetrics.tasks.values.filter { $0.ownRun == nil }.map(\.fixPct).max())
        XCTAssertEqual(ModelPriority.accurate.pickForChords(), "mlx-community/gemma-4-e4b-6bit")   // E4B-it 6-bit, under 8-bit's own weights
    }

    func testModelPriorityPicks() {
        XCTAssertEqual(ModelPriority.lightest.pick(axis: "core"), "mlx-community/Qwen2.5-0.5B-bf16")   // 1.0 GB
        XCTAssertEqual(ModelPriority.accurate.pick(axis: "core"), "mlx-community/gemma-4-e4b-6bit")    // 32% vs E4B 8-bit's 31
        XCTAssertEqual(ModelPriority.quick.pick(axis: "core"), "nikimori/Qwen3.5-2B-Base-6bit")        // ≥30% at 32 ms
        XCTAssertEqual(ModelPriority.balanced.pick(axis: "core"), ModelCatalog.defaultID)

        // Axis-dependence is the feature: on the all-languages average E4B
        // 8-bit wins the 22% tie on logP/char, but on Russian E2B 8-bit
        // measures BEST outright (25 vs E4B's 23) — the cards must re-resolve
        // per language.
        XCTAssertEqual(ModelPriority.accurate.pick(axis: "*"), "mlx-community/gemma-4-e4b-8bit")
        XCTAssertEqual(ModelPriority.quick.pick(axis: "*"), "mlx-community/gemma-4-e2b-8bit")
        XCTAssertEqual(ModelPriority.accurate.pick(axis: "ru"), "mlx-community/gemma-4-e2b-8bit")
        // A tie on speed goes to the catalog's earlier entry: on Portuguese
        // Qwen3.5 2B and its M40 merge are both in reach at 32 ms.
        XCTAssertEqual(ModelPriority.quick.pick(axis: "pt"), "nikimori/Qwen3.5-2B-Base-6bit")
        // Balanced is the fresh-install rule — sized to THIS Mac's memory,
        // not to the axis (language dropped out of the default on 2026-07-25;
        // no per-language gap between the small models survives p<0.01).
        XCTAssertEqual(ModelPriority.balanced.pick(axis: "ru"), ModelCatalog.defaultID)
        XCTAssertEqual(ModelPriority.balanced.pick(axis: "*"), ModelCatalog.defaultID)
        // The RAM ladder: the best Gemma tier whose recommended-config
        // resident model stays within about a quarter of physical memory;
        // Qwen3.5 2B M40 is the floor below the smallest Gemma tier: one model
        // for the chords an 8 GB Mac's Words suggestions leave it.
        XCTAssertEqual(ModelCatalog.defaultID(forRamGB: 8),
                       "nikimori/Qwen3.5-2B-M40-6bit")
        XCTAssertEqual(ModelCatalog.defaultID(forRamGB: 16),
                       "mlx-community/gemma-4-e2b-4bit")
        XCTAssertEqual(ModelCatalog.defaultID(forRamGB: 18),
                       "mlx-community/gemma-4-e2b-4bit")
        XCTAssertEqual(ModelCatalog.defaultID(forRamGB: 24),
                       "mlx-community/gemma-4-e2b-8bit")
        XCTAssertEqual(ModelCatalog.defaultID(forRamGB: 32),
                       "mlx-community/gemma-4-e4b-6bit")
        XCTAssertEqual(ModelCatalog.defaultID(forRamGB: 64),
                       "mlx-community/gemma-4-e4b-6bit")
        // The quarter-of-memory invariant holds at every tier Apple ships:
        // what the default actually keeps resident (instruct primary on the
        // Gemma tiers) never exceeds ram/4.
        for ram in [8.0, 16, 18, 24, 32, 36, 48, 64] {
            let id = ModelCatalog.defaultID(forRamGB: ram)
            let resident = ModelMetrics.instructRamGB(for: id)
                ?? ModelMetrics.metrics(for: id)?.ramGB ?? 0
            XCTAssertLessThanOrEqual(resident * 4, ram,
                                     "default at \(ram) GB holds \(resident) GB resident")
        }

        // The axis figures themselves: core = of-answered headline, "*" =
        // equal-weight mean of the booked per-language of-all cells.
        XCTAssertEqual(ModelMetrics.axisAccuracy(for: "mlx-community/gemma-4-e4b-8bit", axis: "core"), 31)
        // 22, not the pre-RTL 23: adding ar (15) and he (16) — both below this
        // model's 17-language mean — pulls the equal-weight average down. The
        // ranking is unchanged; only the absolute figure moved.
        XCTAssertEqual(ModelMetrics.axisAccuracy(for: "mlx-community/gemma-4-e4b-8bit", axis: "*"), 22)
        XCTAssertEqual(ModelMetrics.axisAccuracy(for: "mlx-community/gemma-4-e4b-8bit", axis: "cs"), 23)
        XCTAssertNil(ModelMetrics.axisAccuracy(for: "no-such-model", axis: "*"))
        XCTAssertEqual(ModelMetrics.axisBest("uk"), 25)  // Gemma E4B 6-bit
        // RTL: the small models tie each other, so the axis best is a Gemma.
        XCTAssertEqual(ModelMetrics.axisBest("he"), 18)  // Gemma E2B 8-bit
        XCTAssertEqual(ModelMetrics.axisAccuracy(for: "nikimori/MiniCPM5-1B-Base-8bit", axis: "he"), 3)
        XCTAssertEqual(ModelMetrics.evalLanguages.count, 19)

        // A preset lands on the measured protocol its card advertises
        // (Base · Short) and preserves compatible gates.
        let custom = ProjectionConfig(modelID: ModelCatalog.defaultID, style: .instruct,
                                      length: .long, logprobGate: true, useRecommended: false)
        let landed = custom.applying(.preset(ModelPriority.accurate.pick(axis: "core")))
        XCTAssertEqual(landed.modelID, ModelPriority.accurate.pick(axis: "core"))
        XCTAssertEqual(landed.style, .base)
        XCTAssertEqual(landed.length, .short)
        XCTAssertTrue(landed.logprobGate)        // user's gate survives
        // Every MLX model recommends Base · Short since 2026-10-15, so auto
        // mode stays on.
        XCTAssertTrue(landed.useRecommended)
        XCTAssertTrue(custom.applying(.preset("nikimori/Qwen3.5-2B-Base-6bit")).useRecommended)
        XCTAssertTrue(custom.applying(.preset("mlx-community/gemma-4-e2b-4bit")).useRecommended)
        XCTAssertEqual(ModelCatalog.recommended(for: "mlx-community/gemma-4-e4b-6bit").style, .base)
        // Instruct stays a working manual pick on E4B only; a switch to any
        // other model leaves it.
        XCTAssertTrue(ModelCatalog.instructCompletes("mlx-community/gemma-4-e4b-6bit"))
        XCTAssertFalse(ModelCatalog.instructCompletes("mlx-community/gemma-4-e2b-8bit"))
        let manualInstruct = ProjectionConfig(modelID: "mlx-community/gemma-4-e4b-8bit", style: .instruct,
                                              length: .short, logprobGate: false, useRecommended: false)
        XCTAssertEqual(manualInstruct.applying(.model("mlx-community/gemma-4-e4b-6bit")).style, .instruct)
        XCTAssertEqual(manualInstruct.applying(.model("nikimori/Qwen3.5-2B-Base-6bit")).style, .base)

        // A map settings-dot jumps to its exact configuration, verbatim.
        let dot = ProjectionConfig(modelID: custom.modelID, style: .base, length: .medium,
                                   logprobGate: false,
                                   useRecommended: false)
        XCTAssertEqual(custom.applying(.config(dot)), dot)
        // Runtime equivalence ignores only the auto-mode flag.
        var dotAuto = dot; dotAuto.useRecommended = true
        XCTAssertTrue(dot.sameRuntime(as: dotAuto))
        XCTAssertFalse(dot.sameRuntime(as: custom))
    }

    /// The RECOMMENDED tooltip tells each tier's story in the figures the
    /// rows show: the resident size `HostPLE.residentGB` gives (E2B 4-bit's
    /// "~2.5 GB" stood next to a row reading 1.2 with "Reduce memory use"
    /// on) and the chords as booked — and "the most in the catalog" holds.
    func testLadderRationaleUsesTheRowsFigures() {
        let served = { (_: String) in true }
        for ram in [8.0, 16, 24, 32] {
            let id = ModelCatalog.defaultID(forRamGB: ram)
            let why = ModelCatalog.rationale(for: id, servesTable: served)
            let resident = HostPLE.residentGB(ModelMetrics.metrics(for: id)?.ramGB ?? 0, of: id, servesTable: served)
            XCTAssertTrue(why.contains("~\(gbLabel(resident))") || why.contains("— \(gbLabel(resident))"), why)
            let fix = ModelMetrics.taskMetrics(for: id, style: .base)?.m.fixPct ?? -1
            XCTAssertTrue(why.contains("\(fix)%"), why)
        }
        XCTAssertEqual(ModelCatalog.rationale(for: "mlx-community/gemma-4-e4b-8bit", servesTable: served), "", "not a ladder tier")
        XCTAssertEqual(ModelMetrics.tasks["mlx-community/gemma-4-e4b-it-6bit"]?.fixPct,
                       ModelMetrics.tasks.values.map(\.fixPct).max())
        // The small models' range comes from the table's run: M40's 41% is
        // from its own, never tested against E2B-it's 50%.
        XCTAssertTrue(ModelCatalog.rationale(for: "mlx-community/gemma-4-e2b-4bit", servesTable: served).contains("where the small models manage 11–33%."))
    }

    func testTypedLanguageSignal() {
        TypedLanguage.reset()
        XCTAssertNil(TypedLanguage.dominant)
        for _ in 0..<(TypedLanguage.minObservations - 1) { TypedLanguage.observe("ru") }
        XCTAssertNil(TypedLanguage.dominant, "a thin sample must never decide")
        TypedLanguage.observe("ru")
        XCTAssertEqual(TypedLanguage.dominant, "ru")

        // The ru/uk confusion this guard exists for: a split field is not a
        // verdict, however many observations back it.
        TypedLanguage.reset()
        for _ in 0..<200 { TypedLanguage.observe("ru"); TypedLanguage.observe("uk") }
        XCTAssertNil(TypedLanguage.dominant, "a mixed field must stay undecided")

        // Someone who switches languages has to be able to outvote their own
        // history. The decay makes that cost a few hundred detections — a few
        // paragraphs of typing — rather than being impossible.
        TypedLanguage.reset()
        for _ in 0..<300 { TypedLanguage.observe("en") }
        XCTAssertEqual(TypedLanguage.dominant, "en")
        for _ in 0..<600 { TypedLanguage.observe("he") }
        XCTAssertEqual(TypedLanguage.dominant, "he", "decay must let a switch through")

        // NLLanguageRecognizer reports Chinese as "zh-Hans"/"zh-Hant"; the eval
        // tables key on "zh", and the nudge dies silently on a mismatch.
        TypedLanguage.reset()
        for _ in 0..<TypedLanguage.minObservations { TypedLanguage.observe("zh-Hans") }
        XCTAssertEqual(TypedLanguage.dominant, "zh", "script subtags must not hide a measured language")
        XCTAssertNotNil(ModelMetrics.materiallyBetter(than: "nikimori/MiniCPM5-1B-Base-8bit", on: "zh"),
                        "the zh nudge the normalization exists for must actually fire")
        TypedLanguage.reset()
    }

    /// The nudge's whole risk is crying wolf, so the thresholds are asserted
    /// against the booked table rather than described in a comment.
    func testMateriallyBetterModelForLanguage() {
        let minicpm = "nikimori/MiniCPM5-1B-Base-8bit"
        // Fires where the model is the wrong tool: Hebrew 3% and Turkish 5%.
        let he = ModelMetrics.materiallyBetter(than: minicpm, on: "he")
        XCTAssertEqual(he?.id, "mlx-community/gemma-4-e2b-8bit")
        XCTAssertEqual(he?.current, 3)
        XCTAssertEqual(he?.best, 18)
        XCTAssertEqual(ModelMetrics.materiallyBetter(than: minicpm, on: "tr")?.id,
                       "mlx-community/gemma-4-e4b-6bit")
        // Silent where a better model exists but the current one is still a
        // usable tool in its weight class — Russian 17 vs 25 is a memory
        // trade-off the user already made, not a mistake worth a menu line.
        XCTAssertNil(ModelMetrics.materiallyBetter(than: minicpm, on: "ru"))
        XCTAssertNil(ModelMetrics.materiallyBetter(than: minicpm, on: "en"))
        // Never suggests a model against itself, or on an unmeasured language.
        XCTAssertNil(ModelMetrics.materiallyBetter(than: "mlx-community/gemma-4-e2b-8bit", on: "he"))
        XCTAssertNil(ModelMetrics.materiallyBetter(than: minicpm, on: "xx"))
        XCTAssertNil(ModelMetrics.materiallyBetter(than: "no-such-model", on: "he"))
        // Apple Intelligence trails nearly everywhere, so a nudge for it would
        // be permanent — and it is the one choice whose point is downloading
        // nothing. Silent on every language, including its worst.
        for language in ModelMetrics.evalLanguages {
            XCTAssertNil(ModelMetrics.materiallyBetter(than: ModelCatalog.appleIntelligenceID,
                                                       on: language),
                         "the system model must never be nudged off \(language)")
        }
    }

    /// The "*" axis is a mean over each model's OWN language keys, so a table
    /// where one model carries a language another lacks quietly compares two
    /// different averages — and "*" is the axis the settings UI opens on. Adding
    /// a language to the eval means measuring the WHOLE catalog on it; this is
    /// the guard that says so out loud instead of shipping a skewed ranking.
    func testPerLanguageTableCoversEveryModelEqually() {
        let table = ModelMetrics.perLangOfAll
        XCTAssertFalse(table.isEmpty)
        let languages = Set(ModelMetrics.evalLanguages)
        for (id, cells) in table {
            XCTAssertEqual(Set(cells.keys), languages,
                           "\(id) is measured on a different language set than the rest")
        }
        // Every per-language row belongs to a model the user can actually pick
        // (or the system engine), so no axis can rank a model that isn't there.
        for id in table.keys where id != "system.apple-intelligence" {
            XCTAssertNotNil(ModelCatalog.option(for: id), "\(id) has metrics but no catalog entry")
        }

        // A figure with no sample size behind it can't state its own tolerance.
        for language in ModelMetrics.evalLanguages {
            XCTAssertNotNil(ModelMetrics.sampleSize[language], "\(language) has no booked n")
            XCTAssertGreaterThan(ModelMetrics.axisSampleSize(language), 0)
        }
        XCTAssertEqual(ModelMetrics.axisSampleSize("*"),
                       ModelMetrics.sampleSize.values.reduce(0, +))
    }

    /// The fix/reply figures are keyed by the sibling the engine loads, so the
    /// resolver must follow the same routing as `MLXEngine.correct`: instruct
    /// primary in Instruct style, correction sibling in Base style.
    func testTaskMetricsResolution() {
        // Every measured sibling id must be resolvable FROM some catalog entry,
        // or the row is dead data no card can ever show.
        for sibling in ModelMetrics.tasks.keys {
            let reachable = ModelCatalog.options.contains {
                $0.correctionModelID == sibling || $0.instructModelID == sibling
            }
            XCTAssertTrue(reachable, "\(sibling) has task metrics but no catalog entry routes to it")
            XCTAssertNotNil(ModelMetrics.taskModelNames[sibling], "\(sibling) has no display name")
        }
        // The map's task lenses need a bubble size and a "used by" line for
        // every measured sibling — a miss renders as a default-sized anonymous
        // bubble no catalog row points at.
        for sibling in ModelMetrics.tasks.keys {
            XCTAssertNotNil(ModelMetrics.taskRamGB(for: sibling), "\(sibling) has no bubble size")
            XCTAssertFalse(ModelMetrics.taskUsers(of: sibling).isEmpty,
                           "\(sibling) is measured but no catalog pick routes to it at recommended settings")
        }
        // Clicking a sibling bubble on the map switches to the FIRST catalog
        // user — catalog order is quality order, so the shared E4B-it 6-bit
        // bubble must land on the top Gemma tier.
        XCTAssertEqual(ModelMetrics.taskUserIDs(of: "mlx-community/gemma-4-e4b-it-6bit"),
                       ["mlx-community/gemma-4-e4b-8bit", "mlx-community/gemma-4-e4b-6bit"])
        XCTAssertEqual(ModelMetrics.taskUserIDs(of: "mlx-community/gemma-4-e4b-it-4bit"),
                       ["mlx-community/gemma-4-e2b-8bit"])
        XCTAssertEqual(ModelMetrics.taskUserIDs(of: "mlx-community/Qwen3.5-2B-4bit"),
                       ["nikimori/MiniCPM5-1B-Base-8bit", "nikimori/Qwen3.5-2B-Base-6bit"])
        // Instruct style on E2B 8-bit runs the E4B-it 4-bit primary — the
        // measured 65% fixer — not E2B's own correction sibling.
        let e2b = ModelMetrics.taskMetrics(for: "mlx-community/gemma-4-e2b-8bit", style: .instruct)
        XCTAssertEqual(e2b?.m.fixPct, 65)
        XCTAssertEqual(e2b?.measuredID, "mlx-community/gemma-4-e4b-it-4bit")
        // The E4B tiers' instruct primary is the 6-bit build, measured on its
        // own since 2026-10-11 (69%, ahead of the 4-bit's 65%, p<0.001).
        let e4b = ModelMetrics.taskMetrics(for: "mlx-community/gemma-4-e4b-8bit", style: .instruct)
        XCTAssertEqual(e4b?.m.fixPct, 69)
        XCTAssertEqual(e4b?.measuredID, "mlx-community/gemma-4-e4b-it-6bit")
        // Base style routes to the lazy correction sibling instead — on E4B
        // the same it-6bit (2026-10-15: old Instruct installs already hold it).
        let e4bBase = ModelMetrics.taskMetrics(for: "mlx-community/gemma-4-e4b-8bit", style: .base)
        XCTAssertEqual(e4bBase?.measuredID, "mlx-community/gemma-4-e4b-it-6bit")
        // MiniCPM5's own RL build fixed 4% and replied 35%, so its chords
        // borrow Qwen3.5's sibling.
        let minicpm = ModelMetrics.taskMetrics(for: "nikimori/MiniCPM5-1B-Base-8bit", style: .base)
        XCTAssertEqual(minicpm?.measuredID, "mlx-community/Qwen3.5-2B-4bit")
        XCTAssertEqual(minicpm?.m.fixPct, 33)
        // Bonsai corrects with itself, through its own chat template.
        let bonsai = ModelMetrics.taskMetrics(for: "prism-ml/Ternary-Bonsai-4B-mlx-2bit", style: .base)
        XCTAssertEqual(bonsai?.m.fixPct, 19)
        XCTAssertEqual(bonsai?.m.replyPct, 22)
        // So does the M40 merge: one pinned download serves completion and
        // both chords, with figures measured on the merge itself.
        let m40ID = "nikimori/Qwen3.5-2B-M40-6bit"
        let m40 = ModelMetrics.taskMetrics(for: m40ID, style: .base)
        XCTAssertEqual(m40?.measuredID, m40ID)
        XCTAssertEqual(m40?.m.fixPct, 41)
        XCTAssertNotNil(ModelCatalog.pinnedRevisions[m40ID])
        // Not measured: only the system model.
        XCTAssertNil(ModelMetrics.taskMetrics(for: ModelCatalog.appleIntelligenceID, style: .instruct))
    }

    /// The table is one run's, its reply column one judge's (GPT-6 Luna). The
    /// chord map ranks every row side by side, so a row booked on a run of
    /// its own — the M40 merge, replies rated by Qwen3.8 — is marked wherever
    /// its name shows and explained, with that run's figure for a sibling the
    /// table holds too, in the source line.
    func testRowsFromAnotherRunAreMarked() {
        for (id, t) in ModelMetrics.tasks {
            XCTAssertEqual(ModelMetrics.taskModelNames[id]?.hasSuffix("¹"), t.ownRun != nil, id)
            if let run = t.ownRun { XCTAssertTrue(ModelMetrics.taskSource.contains(run), id) }
        }
        XCTAssertNotNil(ModelMetrics.tasks["nikimori/Qwen3.5-2B-M40-6bit"]?.ownRun)
        XCTAssertEqual(ModelMetrics.taskMetrics(for: "nikimori/Qwen3.5-2B-M40-6bit", style: .base)?.runsOn, "Qwen3.5 2B M40¹")
    }

    /// The confidence figure is the whole point of showing n, so it has to be
    /// arithmetic rather than decoration.
    func testMarginOfErrorTracksSampleSize() {
        // A single language cell buys ±5 pp near 20%; Russian's larger cell ±3;
        // the whole set ±1. These are the numbers the captions now print.
        XCTAssertEqual(ModelMetrics.marginOfError(pct: 20, n: 280), 5)
        XCTAssertEqual(ModelMetrics.marginOfError(pct: 20, n: 689), 3)
        XCTAssertEqual(ModelMetrics.marginOfError(pct: 20, n: ModelMetrics.axisSampleSize("*")), 1)
        // Tighter at the extremes, and monotone in n — a 1% cell is far better
        // pinned down than a 25% one at the same sample size.
        XCTAssertLessThan(ModelMetrics.marginOfError(pct: 1, n: 280),
                          ModelMetrics.marginOfError(pct: 25, n: 280))
        XCTAssertLessThan(ModelMetrics.marginOfError(pct: 20, n: 5000),
                          ModelMetrics.marginOfError(pct: 20, n: 280))
        XCTAssertEqual(ModelMetrics.marginOfError(pct: 20, n: 0), 0)
        // The Hebrew cliff must stay a real gap and not a noise artifact:
        // 1% and 18% at n=280 don't come close to touching.
        let minicpm = ModelMetrics.axisAccuracy(for: "nikimori/MiniCPM5-1B-Base-8bit", axis: "he")!
        let gemma = ModelMetrics.axisAccuracy(for: "mlx-community/gemma-4-e2b-8bit", axis: "he")!
        let n = ModelMetrics.axisSampleSize("he")
        XCTAssertGreaterThan(gemma - ModelMetrics.marginOfError(pct: gemma, n: n),
                             minicpm + ModelMetrics.marginOfError(pct: minicpm, n: n))
    }

    // Per-model gate τ (live-scale split-half Q4 edges, runs-2026-10-15-rebook) — pin the values
    // so a catalog refactor can't silently unify them back to one global τ.
    func testPerModelGateTau() {
        func tau(_ id: String) -> Double? { ModelCatalog.recommended(for: id).logprobGateTau }
        XCTAssertEqual(tau("mlx-community/gemma-4-e4b-8bit"), -0.94)
        XCTAssertEqual(tau("mlx-community/gemma-4-e4b-6bit"), -0.94)
        XCTAssertEqual(tau("mlx-community/gemma-4-e2b-8bit"), -0.96)
        XCTAssertEqual(tau("mlx-community/gemma-4-e2b-4bit"), -1.07)
        XCTAssertEqual(tau("nikimori/MiniCPM5-1B-Base-8bit"), -1.21)
        XCTAssertEqual(tau("nikimori/Qwen3.5-2B-Base-6bit"), -1.18)
        XCTAssertEqual(tau("mlx-community/Qwen2.5-0.5B-bf16"), -1.34)
        XCTAssertEqual(tau("prism-ml/Ternary-Bonsai-4B-mlx-2bit"), -1.15)
        XCTAssertNil(tau(ModelCatalog.appleIntelligenceID))   // no logprob to gate on
    }

    // The same cases script-tau.py asserts on its Python copy — the table was
    // calibrated on that copy, so the two must agree.
    func testGateScriptDetector() {
        XCTAssertNil(GateScript.of("Hello world "))
        XCTAssertNil(GateScript.of("Привет, "))
        XCTAssertNil(GateScript.of(""))
        XCTAssertEqual(GateScript.of("今日は天気が"), .kana)      // kana folds the Han in
        XCTAssertEqual(GateScript.of("今天天气很"), .han)
        XCTAssertEqual(GateScript.of("안녕하세요 "), .hangul)
        XCTAssertEqual(GateScript.of("مرحبا "), .arabic)
        XCTAssertEqual(GateScript.of("שלום "), .hebrew)
        XCTAssertNil(GateScript.of("Meeting notes for 今日は"))   // dominant class wins
        XCTAssertEqual(GateScript.of(String(repeating: "a", count: 100)
                                     + String(repeating: "今日は天気が良いですね。", count: 6)), .kana) // last 64 only
    }

    // Per-script τ (runs-2026-10-16-gate/script-tau.py): Japanese is never
    // worth a suggestion on any measured model; the rest are model-specific.
    func testPerScriptGateTau() {
        let mlx = ["mlx-community/gemma-4-e4b-8bit", "mlx-community/gemma-4-e4b-6bit",
                   "mlx-community/gemma-4-e2b-8bit", "mlx-community/gemma-4-e2b-4bit",
                   "nikimori/MiniCPM5-1B-Base-8bit", "nikimori/Qwen3.5-2B-Base-6bit",
                   "mlx-community/Qwen2.5-0.5B-bf16", "prism-ml/Ternary-Bonsai-4B-mlx-2bit"]
        for id in mlx {
            XCTAssertEqual(ModelCatalog.recommended(for: id).scriptGateTau[.kana], .infinity, id)
        }
        let minicpm = ModelCatalog.recommended(for: "nikimori/MiniCPM5-1B-Base-8bit").scriptGateTau
        XCTAssertEqual(minicpm[.arabic], -0.38)
        XCTAssertEqual(minicpm[.hebrew], -0.77)
        XCTAssertNil(ModelCatalog.recommended(for: "mlx-community/gemma-4-e4b-8bit").scriptGateTau[.han])
        // Japanese is silent everywhere, gate or not; Apple Intelligence also
        // in Chinese and Korean (no logprob to gate them on).
        for id in mlx {
            XCTAssertEqual(ModelCatalog.silentScripts(for: id), [.kana], id)
        }
        XCTAssertEqual(ModelCatalog.silentScripts(for: ModelCatalog.appleIntelligenceID), [.kana, .han, .hangul])
        // Chinese and Korean keep a τ with the gate off: the script's, else the model's.
        let qwen = ModelCatalog.alwaysOnGateTau(for: "nikimori/Qwen3.5-2B-Base-6bit")
        XCTAssertEqual(qwen, [.han: -1.18, .hangul: -0.57])
        XCTAssertEqual(ModelCatalog.alwaysOnGateTau(for: "mlx-community/gemma-4-e2b-4bit"), [.han: -0.75, .hangul: -1.07])
        XCTAssertEqual(ModelCatalog.alwaysOnGateTau(for: ModelCatalog.appleIntelligenceID), [:])
        // gate off → the floor; hand-tuned looser τ → raised to it; stricter stays.
        let floor: [GateScript: Double] = [.han: -0.94]
        XCTAssertEqual(MLXEngine.gateTau(base: nil, script: .han, scriptTau: [:], floor: floor), -0.94)
        XCTAssertNil(MLXEngine.gateTau(base: nil, script: nil, scriptTau: [:], floor: floor))
        XCTAssertEqual(MLXEngine.gateTau(base: -1.5, script: .han, scriptTau: [:], floor: floor), -0.94)
        XCTAssertEqual(MLXEngine.gateTau(base: -1.5, script: nil, scriptTau: [:], floor: floor), -1.5)
        XCTAssertEqual(MLXEngine.gateTau(base: -0.94, script: .han, scriptTau: [.han: -0.5], floor: floor), -0.5)
        // Stricter only: no override may loosen the model's own τ.
        for id in mlx {
            let r = ModelCatalog.recommended(for: id)
            for (_, t) in r.scriptGateTau { XCTAssertGreaterThan(t, r.logprobGateTau!, id) }
        }
    }
}
