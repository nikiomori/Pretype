import Foundation

/// Measured per-model figures behind the settings UI (the quality/speed/size
/// chart and the model detail card). Every number is a real measurement — no
/// spec-sheet estimates.
///
/// Protocol: `Eval/eval-real.jsonl` (5649 rows / 17 languages), base · greedy ·
/// short, personalization off, confidence-trim pinned off, warm model,
/// Apple-silicon dev machine. The FULL catalog ran on 2026-07-16/17
/// (`Eval/runs-2026-07-16/`, run-all.sh + run-remaining.sh); the headline axis
/// is the **EN+RU core** (n=1449) so rows compare on the languages the app is
/// tuned for — 17-language verdicts (coverage cliffs, McNemar) live in `note`.
/// Booking derivation: `book-enru-core.py` in the runs dir.
/// p50 provenance: MLX models from the clean 2026-07-15 solo runs (the 07-16
/// pass ran with `PRETYPE_EVAL_LOGPROB=1`, which inflates wall-clock); Apple
/// Intelligence from the 07-16 solo run (no logP pass there), EN/RU-weighted.
struct ModelMetrics {
    let id: String
    /// Short name for chart annotations ("E4B 8-bit").
    let shortName: String
    /// First-word accuracy of offered suggestions, % (Wilson 95% CI in `ci`).
    let firstWordPct: Int
    let ci: ClosedRange<Int>
    /// Share of prompts where the model offered a suggestion, %.
    let coveragePct: Int
    /// Reference log-probability per character, EN+RU weighted — the
    /// tokenizer-fair quality continuum (higher = better). nil where the
    /// scoring pass hasn't run.
    let logProbPerChar: Double?
    /// Warm median latency per suggestion, ms, on the dev machine.
    let p50Ms: Int
    /// Resident weights, GB (catalog download size).
    let ramGB: Double
    /// One honest caveat worth surfacing next to the numbers, if any.
    let note: String?

    /// Umbrella citation for surfaces that describe the whole catalog.
    static let evalSource = "eval-real EN+RU core, n=1449, 2026-07-16"

    static let all: [ModelMetrics] = [
        ModelMetrics(id: "mlx-community/gemma-4-e4b-8bit", shortName: "E4B 8-bit",
                     firstWordPct: 31, ci: 28...33, coveragePct: 84,
                     logProbPerChar: -0.853, p50Ms: 145, ramGB: 8.6,
                     note: "Best quality: holds up across all 17 eval languages, and measurably ahead of E2B 8-bit (p=0.001, n=5649)."),
        ModelMetrics(id: "mlx-community/gemma-4-e4b-6bit", shortName: "E4B 6-bit",
                     firstWordPct: 30, ci: 28...33, coveragePct: 82,
                     logProbPerChar: -0.865, p50Ms: 129, ramGB: 6.8,
                     note: "Ties E4B 8-bit on the 17-language set (p=0.052) at 1.8 GB less."),
        ModelMetrics(id: "mlx-community/gemma-4-e2b-8bit", shortName: "E2B 8-bit",
                     firstWordPct: 29, ci: 27...32, coveragePct: 84,
                     logProbPerChar: -0.878, p50Ms: 75, ramGB: 5.7,
                     note: "~1 pp behind E4B (now significant, p=0.001) at ~2× the speed; robust across all 17 eval languages."),
        // E4B-4bit and LFM2.5 delisted 2026-07-17: each strictly dominated by a
        // catalog neighbor on every axis (E2B-4bit and MiniCPM5 respectively).
        ModelMetrics(id: "mlx-community/gemma-4-e2b-4bit", shortName: "E2B 4-bit",
                     firstWordPct: 29, ci: 27...32, coveragePct: 85,
                     logProbPerChar: -0.925, p50Ms: 127, ramGB: 3.5,
                     note: "Mildest 4-bit cost in the field: ties E2B 8-bit on EN/RU, measurably behind it on 17 languages (p<0.001) yet still ahead of every smaller model — at 2.2 GB less, though slower."),
        ModelMetrics(id: "openbmb/MiniCPM5-1B-Base", shortName: "MiniCPM5 1B",
                     firstWordPct: 28, ci: 26...31, coveragePct: 81,
                     logProbPerChar: -1.041, p50Ms: 49, ramGB: 2.2,
                     note: "Fastest in the catalog, but an EN/RU specialist: multilingual coverage collapses (uk/ro/tr/cs 53–69% vs the Gemmas' ≥78%) — E2B 8-bit is decisively better across 17 languages (p<0.001)."),
        ModelMetrics(id: "mlx-community/Qwen2.5-0.5B-bf16", shortName: "Qwen2.5 0.5B",
                     firstWordPct: 26, ci: 23...28, coveragePct: 84,
                     logProbPerChar: -1.051, p50Ms: 79, ramGB: 1.0,
                     note: "Smallest footprint; ties MiniCPM5 on 17 languages (p=0.084), though its bigger sibling Qwen3.5 2B measures clearly better (p<0.001)."),
        ModelMetrics(id: "mlx-community/Qwen3.5-2B-4bit", shortName: "Qwen3.5 2B",
                     firstWordPct: 27, ci: 24...29, coveragePct: 81,
                     logProbPerChar: -0.993, p50Ms: 93, ramGB: 1.6,
                     note: "Best sub-2 GB pick multilingually — beats MiniCPM5, Bonsai and Qwen 0.5B on the 17-language set (all p<0.001) with the mildest coverage sag; near-ties MiniCPM5 on EN/RU."),
        ModelMetrics(id: "prism-ml/Ternary-Bonsai-4B-mlx-2bit", shortName: "Bonsai 4B",
                     firstWordPct: 27, ci: 25...30, coveragePct: 81,
                     logProbPerChar: -1.073, p50Ms: 102, ramGB: 1.1,
                     note: "Ternary 4B in 1.1 GB; ties MiniCPM5 on the 17-language set (p=0.14) with the same coverage sag outside English and Western Europe (uk 61%, cs 62%)."),
        // Apple Intelligence exposes no logprobs, so the /char scoring can't run.
        ModelMetrics(id: "system.apple-intelligence", shortName: "Apple Intelligence",
                     firstWordPct: 18, ci: 16...20, coveragePct: 90,
                     logProbPerChar: nil, p50Ms: 430, ramGB: 0,
                     note: "System model on the Neural Engine — no download, no app memory. Russian is its weak spot (10% first-word vs 24% English), and pl/ro/cs sit outside its supported languages (9–12% coverage)."),
    ]

    static func metrics(for id: String) -> ModelMetrics? {
        all.first { $0.id == id }
    }

    // MARK: - Per-language breakdown

    /// First-word accuracy with abstentions counted as misses ("of all"), % —
    /// model id → language → value. Matched register cells only (subtitles/
    /// tatoeba/leipzig weighted 100/90/90, the identical design every language
    /// shares; enron excluded), so models compare fairly WITHIN a language.
    /// Absolute numbers are NOT comparable across languages (zh/ja are
    /// char-masked, agglutinative languages pack more per word) — only rank
    /// models inside one language. n≈280/language (en 560, ru 689) → ±5 pp.
    /// Booked from the 2026-07-16 catalog dumps: book-per-lang.py in the runs dir.
    static let perLangOfAll: [String: [String: Int]] = [
        "mlx-community/gemma-4-e4b-8bit":
            ["cs": 23, "de": 28, "en": 27, "es": 28, "fr": 28, "it": 26, "ja": 6, "ko": 12, "nl": 26, "pl": 28, "pt": 24, "ro": 30, "ru": 24, "sv": 23, "tr": 18, "uk": 24, "zh": 13],
        "mlx-community/gemma-4-e4b-6bit":
            ["cs": 22, "de": 28, "en": 27, "es": 29, "fr": 26, "it": 26, "ja": 5, "ko": 10, "nl": 26, "pl": 26, "pt": 24, "ro": 30, "ru": 22, "sv": 25, "tr": 16, "uk": 24, "zh": 13],
        "mlx-community/gemma-4-e2b-8bit":
            ["cs": 21, "de": 25, "en": 26, "es": 29, "fr": 25, "it": 26, "ja": 5, "ko": 11, "nl": 24, "pl": 28, "pt": 21, "ro": 31, "ru": 23, "sv": 22, "tr": 17, "uk": 19, "zh": 14],
        "mlx-community/gemma-4-e2b-4bit":
            ["cs": 17, "de": 21, "en": 27, "es": 28, "fr": 26, "it": 24, "ja": 3, "ko": 9, "nl": 22, "pl": 24, "pt": 23, "ro": 27, "ru": 22, "sv": 20, "tr": 13, "uk": 18, "zh": 11],
        "openbmb/MiniCPM5-1B-Base":
            ["cs": 6, "de": 16, "en": 27, "es": 25, "fr": 20, "it": 17, "ja": 6, "ko": 7, "nl": 13, "pl": 10, "pt": 16, "ro": 6, "ru": 17, "sv": 9, "tr": 5, "uk": 5, "zh": 9],
        "mlx-community/Qwen2.5-0.5B-bf16":
            ["cs": 6, "de": 15, "en": 26, "es": 21, "fr": 19, "it": 15, "ja": 4, "ko": 5, "nl": 14, "pl": 13, "pt": 16, "ro": 9, "ru": 16, "sv": 6, "tr": 6, "uk": 6, "zh": 10],
        "mlx-community/Qwen3.5-2B-4bit":
            ["cs": 7, "de": 18, "en": 26, "es": 24, "fr": 22, "it": 20, "ja": 2, "ko": 6, "nl": 17, "pl": 14, "pt": 22, "ro": 18, "ru": 17, "sv": 13, "tr": 7, "uk": 15, "zh": 8],
        "prism-ml/Ternary-Bonsai-4B-mlx-2bit":
            ["cs": 5, "de": 16, "en": 28, "es": 21, "fr": 21, "it": 12, "ja": 4, "ko": 3, "nl": 12, "pl": 10, "pt": 16, "ro": 13, "ru": 15, "sv": 9, "tr": 6, "uk": 9, "zh": 5],
        "system.apple-intelligence":
            ["cs": 0, "de": 11, "en": 24, "es": 26, "fr": 19, "it": 12, "ja": 2, "ko": 2, "nl": 15, "pl": 1, "pt": 10, "ro": 0, "ru": 7, "sv": 14, "tr": 6, "uk": 5, "zh": 6],
    ]

    /// The languages the eval set measures, alphabetical.
    static let evalLanguages: [String] =
        Set(perLangOfAll.values.flatMap(\.keys)).sorted()

    /// Accuracy figure on one axis: "core" = the headline EN+RU first-word %
    /// (of shown suggestions — pairs with `coveragePct`), "*" = equal-weight
    /// mean of the per-language values, else one language's cell (the last
    /// two are "of all": staying silent counts as a miss).
    static func axisAccuracy(for id: String, axis: String) -> Int? {
        switch axis {
        case "core": return metrics(for: id)?.firstWordPct
        case "*":
            guard let t = perLangOfAll[id], !t.isEmpty else { return nil }
            return Int((Double(t.values.reduce(0, +)) / Double(t.count)).rounded())
        default: return perLangOfAll[id]?[axis]
        }
    }

    /// Best catalog value on an axis — bar/position normalization.
    static func axisBest(_ axis: String) -> Int {
        all.compactMap { axisAccuracy(for: $0.id, axis: axis) }.max() ?? 1
    }

    /// Human name of an axis, for the picker and captions.
    static func axisDisplayName(_ axis: String) -> String {
        switch axis {
        case "core": return "English + Russian"
        case "*": return "all \(evalLanguages.count) languages"
        default: return Locale.current.localizedString(forLanguageCode: axis)?.capitalized ?? axis
        }
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
