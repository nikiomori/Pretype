import Foundation

struct ModelOption {
    let id: String
    let title: String
    let approxSizeMB: Int
    let extraEOSTokens: Set<String>
    /// Instruct sibling used for fix-selection: corrections need instruction
    /// following (the base model paraphrases), while completion needs a base
    /// model (the instruct one echoes the prompt). Loaded lazily on first use.
    /// Kept at 4-bit — correction is easy and the model loads lazily.
    let correctionModelID: String
    /// Instruct sibling that becomes the *primary* model in instruct
    /// completion style. On the Gemma builds it is sized to the entry's RAM
    /// tier: E4B 6-bit where the tier affords ~6.8 GB (an eval A/B showed
    /// instruct only matches/beats base at 6–8 bit), 4-bit siblings on the
    /// tighter tiers — a handicapped instruct still beats swapping a model the
    /// Mac can't hold. Overridable via PRETYPE_INSTRUCT_MODEL.
    let instructModelID: String
}

enum ModelCatalog {
    /// The default is language-aware (see `defaultID`): MiniCPM5 1B for EN/RU
    /// typists, Qwen3.5 2B for everyone else. The Gemma 4 builds (same family
    /// Cotypist uses) are the manual heavy picks — E4B best-quality, E2B for
    /// smaller machines. The Gemma entries are the BASE (pretrained)
    /// conversions — instruct variants echo the prompt instead of continuing it
    /// when used without a chat template.
    static let options: [ModelOption] = [
        ModelOption(
            id: "mlx-community/gemma-4-e4b-8bit",
            title: "Gemma 4 E4B 8-bit — best quality",
            approxSizeMB: 8580,
            extraEOSTokens: ["<end_of_turn>"],
            correctionModelID: "mlx-community/gemma-4-e4b-it-4bit",
            instructModelID: "mlx-community/gemma-4-e4b-it-6bit"
        ),
        ModelOption(
            id: "mlx-community/gemma-4-e4b-6bit",
            title: "Gemma 4 E4B 6-bit — lighter, near-best",
            approxSizeMB: 6790,
            extraEOSTokens: ["<end_of_turn>"],
            correctionModelID: "mlx-community/gemma-4-e4b-it-4bit",
            instructModelID: "mlx-community/gemma-4-e4b-it-6bit"
        ),
        ModelOption(
            id: "mlx-community/gemma-4-e2b-8bit",
            title: "Gemma 4 E2B 8-bit — small but precise",
            approxSizeMB: 5660,
            extraEOSTokens: ["<end_of_turn>"],
            correctionModelID: "mlx-community/gemma-4-e2b-it-4bit",
            instructModelID: "mlx-community/gemma-4-e4b-it-4bit"  // ~5 GB — fits the 11–16 GB tier
        ),
        // E4B-4bit dropped 2026-07-17: strictly dominated by E2B-4bit on every
        // axis (EN/RU 21 vs 29, 17-lang macro 10 vs 20, p50 151 vs 127 ms,
        // 5.0 vs 3.5 GB) — the 4-bit quantization cliff hits E4B hardest.
        ModelOption(
            id: "mlx-community/gemma-4-e2b-4bit",
            title: "Gemma 4 E2B — for 8–16 GB Macs",
            approxSizeMB: 3450,
            extraEOSTokens: ["<end_of_turn>"],
            correctionModelID: "mlx-community/gemma-4-e2b-it-4bit",
            instructModelID: "mlx-community/gemma-4-e2b-it-4bit"  // ~3.5 GB — the 8 GB tier can't hold more
        ),
        // The former EN/RU default (2026-07-07 → 07-25): base ties E4B-8bit
        // base on the POOLED EN+RU core at a quarter of the RAM and the lowest
        // latency in the catalog (p50 49 ms). Split by language that tie is
        // English-only — against E2B-8bit: English 27 vs 26 (p=0.35), Russian
        // 17 vs 23 (p<0.001). Beyond EN/RU coverage collapses (uk/ro/tr/cs
        // 53–69%) and E2B-8bit wins decisively (p<0.001). It lost the default
        // seat in the 07-25 revision — its instruct build is the catalog's
        // best replier (56%) but as a fixer it is inert (4% vs Qwen3.5's 32%),
        // and its EN edge over Qwen3.5 is a trend only (p=0.014, ru tie
        // p=0.79) — so it stays the MANUAL pick for the lowest latency and
        // the best reply drafts. Runs base-only — its instruct mode ANSWERS
        // the text instead of continuing it (first-word ~0%), so
        // `recommended(for:)` and the fresh-install defaults both pin base
        // style. bf16 straight from the hub; no 8-bit Base conversion is
        // published yet.
        ModelOption(
            id: "openbmb/MiniCPM5-1B-Base",
            title: "MiniCPM5 1B — fastest, English & Russian",
            approxSizeMB: 2200,
            extraEOSTokens: [],
            correctionModelID: "openbmb/MiniCPM5-1B",  // fixes are instruction-following — the RL model handles them
            instructModelID: "openbmb/MiniCPM5-1B"     // manual instruct flip only; completion there is broken (see above)
        ),
        // Lowest-RAM pick (eval-real 2026-07-15, base·greedy·short, n=870): at
        // ~1 GB it STATISTICALLY TIES the 2.2 GB MiniCPM5 and the 5.7 GB
        // E2B-8bit on first-word (McNemar p=0.51 / 0.13, both of-all 24–26%).
        // It's the bottom of the pack on the continuous axes (logP/char
        // −1.069, RU-weak like MiniCPM), so it's the absolute-minimum-memory
        // option, NOT a quality upgrade — the 8 GB default seat belongs to
        // Qwen3.5 (better multilingually p<0.001, stronger chords). Base bf16
        // from the hub; runs base-only (Qwen2.5 instruct echoes the prompt).
        ModelOption(
            id: "mlx-community/Qwen2.5-0.5B-bf16",
            title: "Qwen2.5 0.5B — smallest footprint",
            approxSizeMB: 990,
            extraEOSTokens: [],
            correctionModelID: "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
            instructModelID: "mlx-community/Qwen2.5-0.5B-Instruct-4bit"
        ),
        // The small-RAM default (the sub-12 GB floor of the memory ladder;
        // 17-language eval-real, 2026-07-16/17): best sub-2 GB model on the
        // full set — beats MiniCPM5, Bonsai and Qwen 0.5B (all p<0.001) with
        // the mildest coverage sag, near-ties MiniCPM5 on EN/RU, and its
        // chords work (fix 32% / reply 46%). Base-only like the other smalls;
        // correction/instruct siblings point at the base id itself
        // (guaranteed to load; recommended(for:) pins base so auto never
        // flips to an echoing instruct mode).
        ModelOption(
            id: "mlx-community/Qwen3.5-2B-4bit",
            title: "Qwen3.5 2B — best small multilingual",
            approxSizeMB: 1600,
            extraEOSTokens: [],
            correctionModelID: "mlx-community/Qwen3.5-2B-4bit",
            instructModelID: "mlx-community/Qwen3.5-2B-4bit"
        ),
        ModelOption(
            id: "prism-ml/Ternary-Bonsai-4B-mlx-2bit",
            title: "Ternary Bonsai 4B — 1 GB base",  // ternary QAT of Qwen3-4B; ties MiniCPM5, slower, RU-weak
            approxSizeMB: 1100,
            extraEOSTokens: [],
            correctionModelID: "prism-ml/Ternary-Bonsai-4B-mlx-2bit",
            instructModelID: "prism-ml/Ternary-Bonsai-4B-mlx-2bit"
        ),
        // LFM2.5-1.2B dropped 2026-07-17: strictly dominated by MiniCPM5 at the
        // same 2.2 GB (EN/RU 23 vs 28, macro 11 vs 13, p50 59 vs 49 ms).
    ]

    /// Physical memory of this Mac, GiB — the axis the out-of-the-box model
    /// is sized on.
    static let machineRamGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824

    /// The out-of-the-box model, resolved once per launch from the Mac's
    /// physical memory. Keyboard language DROPPED OUT of this rule on
    /// 2026-07-25: no per-language gap between the small models survives the
    /// p<0.01 bar (MiniCPM5's English lead over Qwen3.5 is a trend, p=0.014;
    /// Russian is a tie, p=0.79; Japanese p=0.064 — direct McNemar over the
    /// runs-2026-07-16 dumps), while the task eval splits hard AGAINST the
    /// old EN/RU default — MiniCPM5's instruct build fixes 4% of noisy lines
    /// where Qwen3.5 manages 32% and the Gemma siblings 50–65% — and E2B
    /// 4-bit beats BOTH smalls on Russian outright (p=0.0007 / 0.0012).
    /// Keyboard languages still drive the persona and the per-language menu
    /// nudge; MiniCPM5 stays the manual pick for the lowest latency and the
    /// best reply drafts.
    static let defaultID: String = defaultID(forRamGB: machineRamGB)

    /// The rule behind `defaultID`, memory injected so tests stay
    /// machine-independent: the best Gemma tier whose RECOMMENDED-config
    /// resident model (the instruct primary — what the pick actually keeps
    /// loaded) stays within about a QUARTER of physical memory. Quality order
    /// E4B 6-bit > E2B 8-bit > E2B 4-bit is the 17-language catalog run
    /// (p ≤ 0.001 each step); E4B 8-bit is never the default — it ties 6-bit
    /// (p=0.052) at +1.8 GB, so it stays the manual "best quality" pick.
    /// Below the smallest Gemma tier the floor is Qwen3.5 2B: ties MiniCPM5
    /// on EN/RU completions, beats every other small multilingually
    /// (p<0.001), and corrects with itself — 1.6 GB, no sibling download,
    /// working chords (fix 32% / reply 46% against MiniCPM5's 4% / 56%).
    static func defaultID(forRamGB ram: Double) -> String {
        let gemmaTiers = ["mlx-community/gemma-4-e4b-6bit",
                          "mlx-community/gemma-4-e2b-8bit",
                          "mlx-community/gemma-4-e2b-4bit"]
        for id in gemmaTiers {
            if let resident = ModelMetrics.instructRamGB(for: id), resident * 4 <= ram {
                return id
            }
        }
        return "mlx-community/Qwen3.5-2B-4bit"
    }

    /// Why the current `defaultID` was picked — keyed to the resolved default
    /// so the RECOMMENDED tooltip never tells the wrong tier's story.
    static var defaultRationale: String {
        switch defaultID {
        case "mlx-community/gemma-4-e4b-6bit":
            return "Auto-picked for this Mac's memory: the best-quality tier that stays within about a quarter of it (~6.8 GB resident, freed again after idle). Measurably ahead of the E2B tiers across the evaluated languages (p=0.001), statistically tied with E4B 8-bit at 1.8 GB less, and its fix sibling restores 65% of noisy lines exactly. Smaller tiers are one click below if you'd rather spend less memory."
        case "mlx-community/gemma-4-e2b-8bit":
            return "Auto-picked for this Mac's memory (~5 GB resident in its recommended configuration, freed again after idle): robust across all 19 evaluated languages and measurably ahead of every small model, with its fix and reply chords riding the best-measured fixer (65% exact restores). E4B is the upgrade if this Mac gains memory; the small models spend less."
        case "mlx-community/gemma-4-e2b-4bit":
            return "Auto-picked for this Mac's memory (~3.5 GB resident, freed again after idle): the lightest Gemma tier — measurably better Russian than any small model (direct McNemar p<0.001), ahead of every small across 17 languages, and it fixes half of noisy lines exactly where the small models manage 4–32%."
        case "mlx-community/Qwen3.5-2B-4bit":
            return "Auto-picked for this Mac's memory: the strongest model that fits comfortably — 1.6 GB, no separate rewrite sibling. It ties the fastest small models on English and Russian completions, beats every other sub-2 GB model on the wider language set (p<0.001), and keeps the fix and reply chords working (32% / 46%). A Gemma tier is the accuracy upgrade on a Mac with more memory."
        default:
            return "Auto-picked for this Mac."
        }
    }

    /// Pseudo-model id for the system Apple Intelligence model (macOS 26+):
    /// zero download, zero app memory, runs on the Neural Engine.
    static let appleIntelligenceID = "system.apple-intelligence"

    static func option(for id: String) -> ModelOption? {
        if id == appleIntelligenceID {
            return ModelOption(
                id: appleIntelligenceID,
                title: "Apple Intelligence — system model",
                approxSizeMB: 0,
                extraEOSTokens: [],
                correctionModelID: appleIntelligenceID,
                instructModelID: appleIntelligenceID
            )
        }
        if let option = options.first(where: { $0.id == id }) { return option }
        // A fine-tuned model: a local directory the user pointed us at. Treat it
        // as a Gemma base; fix-selection/instruct fall back to the standard
        // instruct siblings. Recognizing it here keeps it from being cleared as
        // a stale pick on launch.
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: id, isDirectory: &isDir), isDir.boolValue {
            return ModelOption(
                id: id,
                title: "Fine-tuned: \((id as NSString).lastPathComponent) (local)",
                approxSizeMB: 0,
                extraEOSTokens: ["<end_of_turn>"],
                correctionModelID: options[0].correctionModelID,
                instructModelID: options[0].instructModelID
            )
        }
        return nil
    }

    /// Eval-backed completion settings recommended for a given model, so each
    /// model runs in the configuration it measured best in (see Eval/BASELINE.md).
    struct Recommendation {
        let style: CompletionStyle
        let length: CompletionLength
        /// Whether the self-consistency confidence gate is worth offering: it
        /// needs a competent BASE path — E4B at ≥6-bit. On 4-bit / E2B / instruct
        /// / Apple Intelligence there's nothing reliable for agreement to gate on.
        let gateCapable: Bool
        /// Mid-line fill-in is reliable only on E4B-class models.
        let fim: Bool
        /// Logprob-gate τ calibrated PER MODEL: the same mean first-word logprob
        /// means different confidence on different tokenizers/models — split-half
        /// Q4 edges span −0.75 (E4B-8bit) … −1.12 (Qwen0.5B) across the catalog
        /// (runs-2026-07-16 logs, τ from the even half, precision verified on the
        /// odd). One global τ is therefore too strict for small models and too lax
        /// for big Gemma. nil = no logprob available (Apple Intelligence).
        let logprobGateTau: Double?
        /// One-line human summary for the settings UI, e.g.
        /// "Instruct · Short · High-precision available · Fill-in".
        var summary: String {
            var parts = [style == .instruct ? "Instruct" : "Base",
                         length.rawValue.capitalized]
            if gateCapable { parts.append("High-precision available") }
            if fim { parts.append("Fill-in") }
            return parts.joined(separator: " · ")
        }
    }

    static func recommended(for id: String) -> Recommendation {
        if id == appleIntelligenceID {
            // System model: short is its sweet spot (weak on long / Russian
            // tails); style is moot; no base path for the gate, no fill-in.
            return Recommendation(style: .instruct, length: .short, gateCapable: false, fim: false,
                                  logprobGateTau: nil)
        }
        // MiniCPM5: base continuation only — instruct answers instead of
        // continuing (eval-v2 first-word ~0%), so auto mode must never route
        // style there. Length swept 2026-07-13 (base, eval-v2 + eval-real):
        // first-word is length-independent; longer buys ~1–2 pts completeness
        // but LOSES word-F1 and doubles latency each step (short 157 / medium
        // 291 / long 550 ms p50 on eval-real) — so short wins for inline ghost
        // text. No gate (not E4B-class), no fill-in.
        if id.contains("MiniCPM5") {
            return Recommendation(style: .base, length: .short, gateCapable: false, fim: false,
                                  logprobGateTau: -1.00)
        }
        // Small base-continuation picks from the 07-15 sweep (Qwen2.5-0.5B,
        // Qwen3.5-2B, ternary Bonsai-4B): base only — instruct echoes; short
        // (first-word is length-independent here); not E4B-class so no
        // self-consistency gate / fill-in. The shipped logprob gate still
        // works (monotone calibration), independent of gateCapable.
        if id.contains("Qwen2.5-0.5B") || id.contains("Qwen3.5-2B")
            || id.contains("Ternary-Bonsai") {
            let tau = id.contains("Qwen2.5-0.5B") ? -1.12 : id.contains("Ternary-Bonsai") ? -0.95 : -1.00
            return Recommendation(style: .base, length: .short, gateCapable: false, fim: false,
                                  logprobGateTau: tau)
        }
        // Gemma E-series: instruct + short + persona is the validated default
        // (~85% first-word on authored text). Base + gate is the real-text
        // high-precision mode — only meaningful on E4B at ≥6-bit; fill-in is
        // E4B-class only.
        let isE4B = id.contains("e4b")
        let is4bit = id.contains("4bit")
        let tau: Double = isE4B
            ? (is4bit ? -1.00 : id.contains("6bit") ? -0.79 : -0.75)
            : (is4bit ? -0.94 : -0.88)
        return Recommendation(style: .instruct, length: .short,
                              gateCapable: isE4B && !is4bit, fim: isE4B,
                              logprobGateTau: tau)
    }
}

enum MLXSupport {
    /// MLX needs its compiled Metal shaders at runtime. `swift build` cannot
    /// produce them (xcodebuild only), so a plain SwiftPM dev binary would
    /// crash deep in C++ on first use — detect the situation up front.
    /// Mirrors the lookup order in mlx's device.cpp.
    static var isAvailable: Bool {
        let fm = FileManager.default
        let executableDir = Bundle.main.executableURL?.deletingLastPathComponent()
        let candidates: [URL?] = [
            executableDir?.appendingPathComponent("mlx.metallib"),
            executableDir?.appendingPathComponent("Resources/mlx.metallib"),
            Bundle.main.resourceURL?.appendingPathComponent("mlx-swift_Cmlx.bundle"),
            Bundle.main.bundleURL.appendingPathComponent("mlx-swift_Cmlx.bundle"),
        ]
        return candidates.compactMap { $0 }.contains { fm.fileExists(atPath: $0.path) }
    }
}
