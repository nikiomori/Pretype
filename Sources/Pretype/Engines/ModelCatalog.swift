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
    /// MiniCPM5 1B is the default (see `defaultID`); the Gemma 4 builds (same
    /// family Cotypist uses) are the manual heavy picks — E4B best-quality, E2B
    /// for smaller machines. The Gemma entries are the BASE (pretrained)
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
        ModelOption(
            id: "mlx-community/gemma-4-e4b-4bit",
            title: "Gemma 4 E4B 4-bit",
            approxSizeMB: 5000,
            extraEOSTokens: ["<end_of_turn>"],
            correctionModelID: "mlx-community/gemma-4-e4b-it-4bit",
            instructModelID: "mlx-community/gemma-4-e4b-it-4bit"  // same size class as the base pick
        ),
        ModelOption(
            id: "mlx-community/gemma-4-e2b-4bit",
            title: "Gemma 4 E2B — for 8–16 GB Macs",
            approxSizeMB: 3450,
            extraEOSTokens: ["<end_of_turn>"],
            correctionModelID: "mlx-community/gemma-4-e2b-it-4bit",
            instructModelID: "mlx-community/gemma-4-e2b-it-4bit"  // ~3.5 GB — the 8 GB tier can't hold more
        ),
        // The default (eval 2026-07-07 + live use): base ties E4B-8bit base on
        // eval-v2 (TOTAL 41 vs 40, ru first-word 35 vs 28) at a quarter of the
        // RAM and well under half the latency. Runs base-only — its instruct mode
        // ANSWERS the text instead of continuing it (first-word ~0%), so
        // `recommended(for:)` and the fresh-install defaults both pin base style.
        // bf16 straight from the hub; no 8-bit Base conversion is published yet.
        ModelOption(
            id: "openbmb/MiniCPM5-1B-Base",
            title: "MiniCPM5 1B — tiny & fast",
            approxSizeMB: 2200,
            extraEOSTokens: [],
            correctionModelID: "openbmb/MiniCPM5-1B",  // fixes are instruction-following — the RL model handles them
            instructModelID: "openbmb/MiniCPM5-1B"     // manual instruct flip only; completion there is broken (see above)
        ),
        // Lowest-RAM pick (eval-real 2026-07-15, base·greedy·short, n=870): at
        // ~1 GB it STATISTICALLY TIES the 2.2 GB MiniCPM5 default and the 5.7 GB
        // E2B-8bit on first-word (McNemar p=0.51 / 0.13, both of-all 24–26%) —
        // half the footprint of the default. It's the bottom of the pack on the
        // continuous axes (logP/char −1.069, RU-weak like MiniCPM), so it's the
        // 8 GB-Mac option, NOT a quality upgrade — MiniCPM stays the default
        // (faster p50 49 vs 79 ms, better RU + logP/char). Base bf16 from the
        // hub; runs base-only (Qwen2.5 instruct echoes the prompt).
        ModelOption(
            id: "mlx-community/Qwen2.5-0.5B-bf16",
            title: "Qwen2.5 0.5B — smallest footprint",
            approxSizeMB: 990,
            extraEOSTokens: [],
            correctionModelID: "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
            instructModelID: "mlx-community/Qwen2.5-0.5B-Instruct-4bit"
        ),
        // Additional base-completion picks measured in the 2026-07-15 candidate
        // sweep (eval-real n=870): all load and run base-only, all TIE-or-LOSE
        // the MiniCPM5 default on first-word — offered as manual choices, not
        // auto-selected. correction/instruct siblings point at the base id
        // itself (guaranteed to load; recommended(for:) pins base so auto never
        // flips to the echoing instruct mode). See Eval/BASELINE.md.
        ModelOption(
            id: "mlx-community/Qwen3.5-2B-4bit",
            title: "Qwen3.5 2B — 4-bit base",  // ties default; mildest RU of the small non-Gemma models
            approxSizeMB: 1600,
            extraEOSTokens: [],
            correctionModelID: "mlx-community/Qwen3.5-2B-4bit",
            instructModelID: "mlx-community/Qwen3.5-2B-4bit"
        ),
        ModelOption(
            id: "prism-ml/Ternary-Bonsai-4B-mlx-2bit",
            title: "Ternary Bonsai 4B — 1 GB base",  // ternary QAT of Qwen3-4B; ties default, slower, RU-weak
            approxSizeMB: 1100,
            extraEOSTokens: [],
            correctionModelID: "prism-ml/Ternary-Bonsai-4B-mlx-2bit",
            instructModelID: "prism-ml/Ternary-Bonsai-4B-mlx-2bit"
        ),
        ModelOption(
            id: "LiquidAI/LFM2.5-1.2B-Base",
            title: "LFM2.5 1.2B — fast, English",  // fastest small model (p50 59 ms) but weakest RU (no-RU model card)
            approxSizeMB: 2200,
            extraEOSTokens: [],
            correctionModelID: "LiquidAI/LFM2.5-1.2B-Base",
            instructModelID: "LiquidAI/LFM2.5-1.2B-Base"
        ),
    ]

    /// MiniCPM5 1B is the out-of-the-box model on every Mac: at ~2.2 GB it fits
    /// the tightest RAM tier yet matches Gemma E4B-8bit base on the eval (TOTAL
    /// first-word 41 vs 40, RU 35 vs 28) at a fraction of the latency — so there
    /// is no heavier tier worth an auto step-up. It runs base-only (see the
    /// catalog entry); the fresh-install style default is pinned to match in
    /// `Settings.registerDefaults`. The Gemma builds and Apple Intelligence
    /// remain manual picks in the catalog / settings list.
    static var defaultID: String { "openbmb/MiniCPM5-1B-Base" }

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
            return Recommendation(style: .instruct, length: .short, gateCapable: false, fim: false)
        }
        // MiniCPM5: base continuation only — instruct answers instead of
        // continuing (eval-v2 first-word ~0%), so auto mode must never route
        // style there. Length swept 2026-07-13 (base, eval-v2 + eval-real):
        // first-word is length-independent; longer buys ~1–2 pts completeness
        // but LOSES word-F1 and doubles latency each step (short 157 / medium
        // 291 / long 550 ms p50 on eval-real) — so short wins for inline ghost
        // text. No gate (not E4B-class), no fill-in.
        if id.contains("MiniCPM5") {
            return Recommendation(style: .base, length: .short, gateCapable: false, fim: false)
        }
        // Small base-continuation picks from the 07-15 sweep (Qwen2.5-0.5B,
        // Qwen3.5-2B, ternary Bonsai-4B, LFM2.5-1.2B): base only — instruct
        // echoes; short (first-word is length-independent here); not E4B-class
        // so no self-consistency gate / fill-in. The shipped logprob gate still
        // works (monotone calibration), independent of gateCapable.
        if id.contains("Qwen2.5-0.5B") || id.contains("Qwen3.5-2B")
            || id.contains("Ternary-Bonsai") || id.contains("LFM2.5") {
            return Recommendation(style: .base, length: .short, gateCapable: false, fim: false)
        }
        // Gemma E-series: instruct + short + persona is the validated default
        // (~85% first-word on authored text). Base + gate is the real-text
        // high-precision mode — only meaningful on E4B at ≥6-bit; fill-in is
        // E4B-class only.
        let isE4B = id.contains("e4b")
        let is4bit = id.contains("4bit")
        return Recommendation(style: .instruct, length: .short,
                              gateCapable: isE4B && !is4bit, fim: isE4B)
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
