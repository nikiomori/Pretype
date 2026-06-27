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
    /// completion style. Higher-bit than `correctionModelID`: an eval A/B showed
    /// the instruct path only matches/beats base at 6–8 bit (4-bit handicaps it,
    /// esp. Russian). Overridable via PRETYPE_INSTRUCT_MODEL.
    let instructModelID: String
}

enum ModelCatalog {
    /// The project standardizes on Gemma 4 (same family Cotypist uses):
    /// E4B as the main model, E2B for smaller machines. These are the BASE
    /// (pretrained) conversions — instruct variants echo the prompt instead
    /// of continuing it when used without a chat template.
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
            instructModelID: "mlx-community/gemma-4-e4b-it-6bit"
        ),
        ModelOption(
            id: "mlx-community/gemma-4-e4b-4bit",
            title: "Gemma 4 E4B 4-bit",
            approxSizeMB: 5000,
            extraEOSTokens: ["<end_of_turn>"],
            correctionModelID: "mlx-community/gemma-4-e4b-it-4bit",
            instructModelID: "mlx-community/gemma-4-e4b-it-6bit"
        ),
        ModelOption(
            id: "mlx-community/gemma-4-e2b-4bit",
            title: "Gemma 4 E2B — for 8–16 GB Macs",
            approxSizeMB: 3450,
            extraEOSTokens: ["<end_of_turn>"],
            correctionModelID: "mlx-community/gemma-4-e2b-it-4bit",
            instructModelID: "mlx-community/gemma-4-e4b-it-6bit"
        ),
    ]

    /// Auto-select the heaviest model the machine can comfortably hold, stepping
    /// down by **model size, not quant**. 8-bit measurably helps informal/Russian
    /// text, and dropping to 4-bit is a quality cliff (eval: −13…−26 pts, mostly
    /// Russian), so the ladder goes E4B-8bit → E4B-6bit → E2B-8bit and only lands
    /// on a 4-bit build on the tightest machines, where size leaves no choice.
    /// (Apple Intelligence stays a manual pick — it needs macOS 26 + an enabled,
    /// supported device, and trails Gemma badly on Russian.)
    static var defaultID: String {
        let gb = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
        if gb >= 32 { return "mlx-community/gemma-4-e4b-8bit" }  // ~8.6 GB resident
        if gb >= 16 { return "mlx-community/gemma-4-e4b-6bit" }  // ~6.8 GB, near-best
        if gb >= 11 { return "mlx-community/gemma-4-e2b-8bit" }  // ~5.7 GB, small but precise
        return "mlx-community/gemma-4-e2b-4bit"                  // ~3.5 GB, last resort
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
