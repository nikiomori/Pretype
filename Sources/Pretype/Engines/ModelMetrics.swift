import Foundation

/// Measured per-model figures behind the settings UI (the quality/speed/size
/// chart and the model detail card). Every number is a real measurement — no
/// spec-sheet estimates.
///
/// Protocol: `Eval/eval-real.jsonl` — 870 real held-out continuations
/// (Enron + OpenSubtitles under the independence rules), base · greedy · short,
/// personalization off, confidence-trim pinned off, warm model, Apple-silicon
/// dev machine. Sources: `Eval/runs-2026-07-15/*.log` and Eval/BASELINE.md
/// ("Re-run on the independent eval-real", 2026-07-15); gemma-4-e4b-4bit was
/// measured 2026-07-15 with the same harness to complete the catalog.
struct ModelMetrics {
    let id: String
    /// Short name for chart annotations ("E4B 8-bit").
    let shortName: String
    /// First-word accuracy of offered suggestions, % (Wilson 95% CI in `ci`).
    let firstWordPct: Int
    let ci: ClosedRange<Int>
    /// Share of prompts where the model offered a suggestion, %.
    let coveragePct: Int
    /// Reference log-probability per character — the tokenizer-fair quality
    /// continuum (higher = better). nil where the scoring pass hasn't run.
    let logProbPerChar: Double?
    /// Warm median latency per suggestion, ms, on the dev machine.
    let p50Ms: Int
    /// Resident weights, GB (catalog download size).
    let ramGB: Double
    /// One honest caveat worth surfacing next to the numbers, if any.
    let note: String?

    static let evalSource = "eval-real, n=870, 2026-07-15"

    static let all: [ModelMetrics] = [
        ModelMetrics(id: "mlx-community/gemma-4-e4b-8bit", shortName: "E4B 8-bit",
                     firstWordPct: 33, ci: 29...36, coveragePct: 84,
                     logProbPerChar: -0.884, p50Ms: 145, ramGB: 8.6,
                     note: "Best quality; statistically ties E4B 6-bit (p=0.46)."),
        ModelMetrics(id: "mlx-community/gemma-4-e4b-6bit", shortName: "E4B 6-bit",
                     firstWordPct: 33, ci: 29...36, coveragePct: 83,
                     logProbPerChar: -0.896, p50Ms: 129, ramGB: 6.8,
                     note: "Ties E4B 8-bit on every metric at 1.8 GB less."),
        ModelMetrics(id: "mlx-community/gemma-4-e2b-8bit", shortName: "E2B 8-bit",
                     firstWordPct: 31, ci: 27...34, coveragePct: 84,
                     logProbPerChar: -0.906, p50Ms: 75, ramGB: 5.7,
                     note: "At most ~2–3 pp behind E4B (p=0.06) at ~2× the speed."),
        // Measured 2026-07-15 to complete the catalog: the 4-bit cliff on E4B is
        // real on real text — it lands BELOW every smaller pick in the catalog.
        ModelMetrics(id: "mlx-community/gemma-4-e4b-4bit", shortName: "E4B 4-bit",
                     firstWordPct: 21, ci: 18...24, coveragePct: 78,
                     logProbPerChar: -1.247, p50Ms: 151, ramGB: 5.0,
                     note: "4-bit quantization cliff: measured worse than every smaller model here — prefer E2B 8-bit."),
        ModelMetrics(id: "mlx-community/gemma-4-e2b-4bit", shortName: "E2B 4-bit",
                     firstWordPct: 31, ci: 28...34, coveragePct: 86,
                     logProbPerChar: -0.957, p50Ms: 127, ramGB: 3.5,
                     note: "No 4-bit cliff on E2B — ties E2B 8-bit (p=0.33) at 2.2 GB less, though slower."),
        ModelMetrics(id: "openbmb/MiniCPM5-1B-Base", shortName: "MiniCPM5 1B",
                     firstWordPct: 30, ci: 27...33, coveragePct: 83,
                     logProbPerChar: -1.060, p50Ms: 49, ramGB: 2.2,
                     note: "Fastest in the catalog; Russian is measurably weaker than the Gemmas (RU logP/char −1.16 vs their −0.86…−0.95)."),
        ModelMetrics(id: "mlx-community/Qwen2.5-0.5B-bf16", shortName: "Qwen2.5 0.5B",
                     firstWordPct: 28, ci: 25...32, coveragePct: 84,
                     logProbPerChar: -1.069, p50Ms: 79, ramGB: 1.0,
                     note: "Smallest footprint; statistically ties MiniCPM5 (p=0.51) at half its size."),
        ModelMetrics(id: "mlx-community/Qwen3.5-2B-4bit", shortName: "Qwen3.5 2B",
                     firstWordPct: 28, ci: 25...32, coveragePct: 83,
                     logProbPerChar: -1.015, p50Ms: 93, ramGB: 1.6,
                     note: "Mildest Russian deficit of the small non-Gemma picks."),
        ModelMetrics(id: "prism-ml/Ternary-Bonsai-4B-mlx-2bit", shortName: "Bonsai 4B",
                     firstWordPct: 29, ci: 26...32, coveragePct: 83,
                     logProbPerChar: -1.083, p50Ms: 102, ramGB: 1.1,
                     note: "Ternary 4B in 1.1 GB; ties the small pack, weakest Russian per-char of the field."),
        ModelMetrics(id: "LiquidAI/LFM2.5-1.2B-Base", shortName: "LFM2.5 1.2B",
                     firstWordPct: 25, ci: 22...28, coveragePct: 77,
                     logProbPerChar: -1.194, p50Ms: 59, ramGB: 2.2,
                     note: "Fast, but Russian collapses (68% coverage, 13% first-word on RU) — English-focused model."),
        // Measured 2026-07-15 with PRETYPE_TEST_ENGINE=fm on the same set; the
        // FM engine exposes no logprobs, so the /char scoring pass can't run.
        ModelMetrics(id: "system.apple-intelligence", shortName: "Apple Intelligence",
                     firstWordPct: 19, ci: 16...22, coveragePct: 92,
                     logProbPerChar: nil, p50Ms: 460, ramGB: 0,
                     note: "System model on the Neural Engine — no download, no app memory. Russian is its weak spot (12% first-word vs 24% English)."),
    ]

    static func metrics(for id: String) -> ModelMetrics? {
        all.first { $0.id == id }
    }

    /// Download sizes of the instruct siblings, GB — hub sizes, the same
    /// provenance as `ModelOption.approxSizeMB`. Feeds the setup summary's
    /// memory estimate when Instruct style loads a second model.
    private static let instructSizesGB: [String: Double] = [
        "mlx-community/gemma-4-e4b-it-6bit": 6.8,
        "mlx-community/gemma-4-e4b-it-4bit": 5.0,
        "mlx-community/gemma-4-e2b-it-4bit": 3.5,
        "mlx-community/Qwen2.5-0.5B-Instruct-4bit": 0.4,
        "openbmb/MiniCPM5-1B": 2.2,
    ]

    /// Resident size of the model Instruct style would actually run for `baseID`.
    static func instructRamGB(for baseID: String) -> Double? {
        guard let option = ModelCatalog.option(for: baseID) else { return nil }
        return instructSizesGB[option.instructModelID]
            ?? metrics(for: option.instructModelID)?.ramGB
            ?? metrics(for: baseID)?.ramGB
    }
}
