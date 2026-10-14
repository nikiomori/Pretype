import Foundation

/// Measured per-model figures behind the settings UI (the quality/speed/size
/// chart and the model detail card). No spec-sheet estimates: accuracy and
/// latency come from eval runs (a derived p50 says so where it's booked),
/// `ramGB` is the weights a model loads — the size of what it downloads.
///
/// Protocol: `Eval/eval-real.jsonl` (5649 rows / 17 languages), base · greedy ·
/// short, personalization off, confidence-trim pinned off, warm model,
/// Apple-silicon dev machine. The FULL catalog ran on 2026-07-16/17
/// (`Eval/runs-2026-07-16/`, run-all.sh + run-remaining.sh); the headline axis
/// is the **EN+RU core** (n=1449) so rows compare on the languages the app is
/// tuned for — 17-language verdicts (coverage cliffs, McNemar) live in `note`.
/// Booking derivation: `book-enru-core.py` in the runs dir.
/// Arabic and Hebrew were added 2026-07-25 from `Eval/eval-rtl.jsonl` (560 rows,
/// same three registers, same axis) — a separate file so eval-real and every
/// verdict booked on it stay byte-identical; see `Eval/runs-2026-07-25/`. Only
/// `perLangOfAll` grew; the headline EN+RU figures below are untouched by it.
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
    static let evalSource = "eval-real, English+Russian pooled, n=1449, 2026-07-16"

    static let all: [ModelMetrics] = [
        ModelMetrics(id: "mlx-community/gemma-4-e4b-8bit", shortName: "E4B 8-bit",
                     firstWordPct: 31, ci: 28...33, coveragePct: 84,
                     logProbPerChar: -0.853, p50Ms: 145, ramGB: 5.98,
                     note: "Best quality: holds up across all 17 eval languages, and measurably ahead of E2B 8-bit (p=0.001, n=5649)."),
        ModelMetrics(id: "mlx-community/gemma-4-e4b-6bit", shortName: "E4B 6-bit",
                     firstWordPct: 30, ci: 28...33, coveragePct: 82,
                     logProbPerChar: -0.865, p50Ms: 129, ramGB: 5.03,
                     note: "Ties E4B 8-bit on the 17-language set (p=0.052) at ~1 GB less."),
        ModelMetrics(id: "mlx-community/gemma-4-e2b-8bit", shortName: "E2B 8-bit",
                     firstWordPct: 29, ci: 27...32, coveragePct: 84,
                     logProbPerChar: -0.878, p50Ms: 75, ramGB: 3.41,
                     note: "~1 pp behind E4B (now significant, p=0.001) at ~2× the speed; robust across all 17 eval languages."),
        // E4B-4bit and LFM2.5 delisted 2026-07-17: each strictly dominated by a
        // catalog neighbor on every axis (E2B-4bit and MiniCPM5 respectively).
        ModelMetrics(id: "mlx-community/gemma-4-e2b-4bit", shortName: "E2B 4-bit",
                     firstWordPct: 29, ci: 27...32, coveragePct: 85,
                     logProbPerChar: -0.925, p50Ms: 127, ramGB: 2.51,
                     note: "Mildest 4-bit cost in the field: ties E2B 8-bit on English (27 vs 26) and on Russian (22 vs 23) alike, measurably behind it on 17 languages (p<0.001) yet still ahead of every smaller model — at 0.9 GB less, though slower."),
        // The 8-bit build (2026-10-15) ties the bf16 one this row was booked
        // on — both book 29 [26–32] off the same binary, so the 07-16 figures
        // and per-language cells stand; logP/char is the 8-bit build's own
        // (bf16 −1.041). p50 scaled from bf16's 49 ms by the interleaved
        // same-binary ratio 28/40 ms (Eval/runs-2026-10-14-small).
        ModelMetrics(id: "nikimori/MiniCPM5-1B-Base-8bit", shortName: "MiniCPM5 1B",
                     firstWordPct: 28, ci: 26...31, coveragePct: 81,
                     logProbPerChar: -1.042, p50Ms: 34, ramGB: 1.1,
                     note: "Fastest in the catalog and an English specialist — on English it ties E2B 8-bit outright (27% vs 26%, p=0.35). Russian is a different story: 17% against E2B 8-bit's 23% (p<0.001), still the best of the small models there but not parity. Wider multilingual coverage collapses (uk/ro/tr/cs 53–69% vs the Gemmas' ≥78%), and Hebrew is its floor at 1% — effectively blind."),
        ModelMetrics(id: "mlx-community/Qwen2.5-0.5B-bf16", shortName: "Qwen2.5 0.5B",
                     firstWordPct: 26, ci: 23...28, coveragePct: 84,
                     logProbPerChar: -1.051, p50Ms: 79, ramGB: 1.0,
                     note: "Smallest footprint; ties MiniCPM5 on 17 languages (p=0.084), though its bigger sibling Qwen3.5 2B measures clearly better (p<0.001)."),
        // The Base build at 6-bit, booked 2026-10-14 with book-qwen35base.py's
        // rules (they reproduce the 10-11 4-bit row exactly); p50 scaled from
        // the 4-bit build's 86 ms by the interleaved same-binary ratio 30/22 ms
        // (Eval/runs-2026-10-14-small).
        ModelMetrics(id: "nikimori/Qwen3.5-2B-Base-6bit", shortName: "Qwen3.5 2B",
                     firstWordPct: 30, ci: 27...33, coveragePct: 81,
                     logProbPerChar: -0.942, p50Ms: 116, ramGB: 1.5,
                     note: "Best sub-2 GB pick multilingually — beats MiniCPM5, Bonsai and Qwen 0.5B on the 17-language set (all p<0.001) with the mildest coverage sag; matches MiniCPM5 on English (28 vs 27) and passes it on Russian (21 vs 17). The Base build at 6-bit: ahead of the 4-bit build (p<0.001) and tied with 8-bit, in 1.5 GB. On Arabic and Hebrew its lead over the other small models shrinks — a Gemma tier is still well ahead there."),
        ModelMetrics(id: "prism-ml/Ternary-Bonsai-4B-mlx-2bit", shortName: "Bonsai 4B",
                     firstWordPct: 27, ci: 25...30, coveragePct: 81,
                     logProbPerChar: -1.073, p50Ms: 102, ramGB: 1.1,
                     note: "Ternary 4B in 1.1 GB; ties MiniCPM5 on the 17-language set (p=0.14) with the same coverage sag outside English and Western Europe (uk 61%, cs 62%)."),
        // Apple Intelligence exposes no logprobs, so the /char scoring can't run.
        ModelMetrics(id: "system.apple-intelligence", shortName: "Apple Intelligence",
                     firstWordPct: 18, ci: 16...20, coveragePct: 90,
                     logProbPerChar: nil, p50Ms: 430, ramGB: 0,
                     note: "System model on the Neural Engine — no download, no app memory. Russian is its weak spot (10% first-word vs 24% English), and pl/ro/cs sit outside its supported languages (9–12% coverage). Arabic and Hebrew are the opposite trap: it answers on 86% of them — more than any downloadable model — and is right 4–6% of the time."),
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
    /// ar/he come from `Eval/eval-rtl.jsonl` (2026-07-25, book-rtl.py) — a
    /// separate set on the same axis and the same 100/90/90 register design, so
    /// the cells are drop-in; eval-real stayed frozen for the other 17.
    /// EVERY model carries EVERY language on purpose: `axisAccuracy(axis: "*")`
    /// averages over a model's own keys, so a half-measured language would make
    /// the default axis compare two different means (guarded by a unit test).
    static let perLangOfAll: [String: [String: Int]] = [
        "mlx-community/gemma-4-e4b-8bit":
            ["ar": 15, "cs": 23, "de": 28, "en": 27, "es": 28, "fr": 28, "he": 16, "it": 26, "ja": 6, "ko": 12, "nl": 26, "pl": 28, "pt": 24, "ro": 30, "ru": 24, "sv": 23, "tr": 18, "uk": 24, "zh": 13],
        "mlx-community/gemma-4-e4b-6bit":
            ["ar": 13, "cs": 22, "de": 28, "en": 27, "es": 29, "fr": 26, "he": 17, "it": 26, "ja": 5, "ko": 10, "nl": 26, "pl": 26, "pt": 24, "ro": 30, "ru": 22, "sv": 25, "tr": 16, "uk": 24, "zh": 13],
        "mlx-community/gemma-4-e2b-8bit":
            ["ar": 11, "cs": 21, "de": 25, "en": 26, "es": 29, "fr": 25, "he": 18, "it": 26, "ja": 5, "ko": 11, "nl": 24, "pl": 28, "pt": 21, "ro": 31, "ru": 23, "sv": 22, "tr": 17, "uk": 19, "zh": 14],
        "mlx-community/gemma-4-e2b-4bit":
            ["ar": 8, "cs": 17, "de": 21, "en": 27, "es": 28, "fr": 26, "he": 16, "it": 24, "ja": 3, "ko": 9, "nl": 22, "pl": 24, "pt": 23, "ro": 27, "ru": 22, "sv": 20, "tr": 13, "uk": 18, "zh": 11],
        "nikimori/MiniCPM5-1B-Base-8bit":
            ["ar": 5, "cs": 6, "de": 16, "en": 27, "es": 25, "fr": 20, "he": 1, "it": 17, "ja": 6, "ko": 7, "nl": 13, "pl": 10, "pt": 16, "ro": 6, "ru": 17, "sv": 9, "tr": 5, "uk": 5, "zh": 9],
        "mlx-community/Qwen2.5-0.5B-bf16":
            ["ar": 6, "cs": 6, "de": 15, "en": 26, "es": 21, "fr": 19, "he": 9, "it": 15, "ja": 4, "ko": 5, "nl": 14, "pl": 13, "pt": 16, "ro": 9, "ru": 16, "sv": 6, "tr": 6, "uk": 6, "zh": 10],
        "nikimori/Qwen3.5-2B-Base-6bit":
            ["ar": 8, "cs": 11, "de": 20, "en": 28, "es": 28, "fr": 26, "he": 13, "it": 21, "ja": 3, "ko": 7, "nl": 21, "pl": 19, "pt": 24, "ro": 23, "ru": 21, "sv": 19, "tr": 9, "uk": 17, "zh": 9],
        "prism-ml/Ternary-Bonsai-4B-mlx-2bit":
            ["ar": 4, "cs": 5, "de": 16, "en": 28, "es": 21, "fr": 21, "he": 7, "it": 12, "ja": 4, "ko": 3, "nl": 12, "pl": 10, "pt": 16, "ro": 13, "ru": 15, "sv": 9, "tr": 6, "uk": 9, "zh": 5],
        "system.apple-intelligence":
            ["ar": 4, "cs": 0, "de": 11, "en": 24, "es": 26, "fr": 19, "he": 6, "it": 12, "ja": 2, "ko": 2, "nl": 15, "pl": 1, "pt": 10, "ro": 0, "ru": 7, "sv": 14, "tr": 6, "uk": 5, "zh": 6],
    ]

    /// How often the model offers anything at all, per language, same matched
    /// cells and same booking rule as `perLangOfAll` (book-per-lang-coverage.py).
    /// Split out because coverage moves FURTHER by language than accuracy does —
    /// MiniCPM5 answers 86% of English and 58% of Hebrew, Apple Intelligence 98%
    /// of English and 9% of Polish — so one merged "offers a suggestion X% of the
    /// time" was wrong on every axis but the one it was measured on.
    static let perLangCoverage: [String: [String: Int]] = [
        "mlx-community/gemma-4-e4b-8bit":
            ["ar": 75, "cs": 85, "de": 94, "en": 86, "es": 89, "fr": 85, "he": 83, "it": 85, "ja": 71, "ko": 62, "nl": 88, "pl": 84, "pt": 91, "ro": 83, "ru": 83, "sv": 91, "tr": 83, "uk": 79, "zh": 55],
        "mlx-community/gemma-4-e4b-6bit":
            ["ar": 72, "cs": 86, "de": 93, "en": 84, "es": 89, "fr": 84, "he": 82, "it": 84, "ja": 69, "ko": 59, "nl": 87, "pl": 83, "pt": 88, "ro": 81, "ru": 82, "sv": 89, "tr": 81, "uk": 78, "zh": 54],
        "mlx-community/gemma-4-e2b-8bit":
            ["ar": 71, "cs": 87, "de": 93, "en": 85, "es": 89, "fr": 86, "he": 81, "it": 85, "ja": 71, "ko": 60, "nl": 88, "pl": 82, "pt": 90, "ro": 82, "ru": 84, "sv": 90, "tr": 84, "uk": 78, "zh": 55],
        "mlx-community/gemma-4-e2b-4bit":
            ["ar": 72, "cs": 81, "de": 92, "en": 86, "es": 89, "fr": 88, "he": 82, "it": 86, "ja": 68, "ko": 60, "nl": 89, "pl": 80, "pt": 93, "ro": 81, "ru": 84, "sv": 90, "tr": 82, "uk": 73, "zh": 55],
        "nikimori/MiniCPM5-1B-Base-8bit":
            ["ar": 59, "cs": 60, "de": 89, "en": 86, "es": 88, "fr": 83, "he": 58, "it": 83, "ja": 70, "ko": 55, "nl": 74, "pl": 69, "pt": 88, "ro": 57, "ru": 76, "sv": 78, "tr": 57, "uk": 53, "zh": 51],
        "mlx-community/Qwen2.5-0.5B-bf16":
            ["ar": 68, "cs": 65, "de": 88, "en": 88, "es": 90, "fr": 83, "he": 71, "it": 80, "ja": 72, "ko": 50, "nl": 79, "pl": 73, "pt": 90, "ro": 67, "ru": 80, "sv": 66, "tr": 64, "uk": 67, "zh": 55],
        "nikimori/Qwen3.5-2B-Base-6bit":
            ["ar": 71, "cs": 79, "de": 89, "en": 87, "es": 87, "fr": 85, "he": 75, "it": 85, "ja": 72, "ko": 58, "nl": 85, "pl": 80, "pt": 90, "ro": 79, "ru": 78, "sv": 89, "tr": 76, "uk": 75, "zh": 53],
        "prism-ml/Ternary-Bonsai-4B-mlx-2bit":
            ["ar": 60, "cs": 62, "de": 86, "en": 87, "es": 83, "fr": 80, "he": 66, "it": 80, "ja": 73, "ko": 49, "nl": 76, "pl": 69, "pt": 81, "ro": 71, "ru": 76, "sv": 75, "tr": 66, "uk": 61, "zh": 55],
        "system.apple-intelligence":
            ["ar": 86, "cs": 11, "de": 90, "en": 98, "es": 95, "fr": 94, "he": 86, "it": 92, "ja": 89, "ko": 88, "nl": 94, "pl": 9, "pt": 90, "ro": 12, "ru": 80, "sv": 93, "tr": 85, "uk": 66, "zh": 84],
    ]

    /// Rows behind each language's cell — the denominator both per-language
    /// tables are computed over (matched registers; EN excludes the 200 Enron
    /// rows no other language has). A percentage without this is a number
    /// without a tolerance, which is why the UI now shows both.
    static let sampleSize: [String: Int] = [
        "ar": 280, "cs": 280, "de": 280, "en": 560, "es": 280, "fr": 280, "he": 280,
        "it": 280, "ja": 280, "ko": 280, "nl": 280, "pl": 280, "pt": 280, "ro": 280,
        "ru": 689, "sv": 280, "tr": 280, "uk": 280, "zh": 280,
    ]

    /// Rows behind an axis. "core" is the EN+RU booking, which unlike the
    /// per-language cells keeps every register (Enron included) — a different
    /// convention, so it is not the sum of the two language cells.
    static func axisSampleSize(_ axis: String) -> Int {
        switch axis {
        case "core": return 1449
        case "*": return sampleSize.values.reduce(0, +)
        default: return sampleSize[axis] ?? 0
        }
    }

    /// Wilson 95% half-width in percentage points — how much of a figure is
    /// sampling noise at that sample size. 280 rows buys ±5 pp near 20%; the
    /// whole set buys ±1. Shown next to the figure so a 2-point difference
    /// between two models reads as the tie it usually is.
    static func marginOfError(pct: Int, n: Int) -> Int {
        guard n > 0 else { return 0 }
        let p = Double(pct) / 100, z = 1.96, count = Double(n)
        let denominator = 1 + z * z / count
        let half = z * (p * (1 - p) / count + z * z / (4 * count * count)).squareRoot() / denominator
        return Int((100 * half).rounded())
    }

    /// Coverage on one axis, matching whatever `axisAccuracy` reports there.
    static func axisCoverage(for id: String, axis: String) -> Int? {
        switch axis {
        case "core": return metrics(for: id)?.coveragePct
        case "*":
            guard let t = perLangCoverage[id], !t.isEmpty else { return nil }
            return Int((Double(t.values.reduce(0, +)) / Double(t.count)).rounded())
        default: return perLangCoverage[id]?[axis]
        }
    }

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

    /// A catalog model that measures materially better than `currentID` on
    /// `language` — the basis for the menu's "you are typing X" nudge. nil when
    /// the current model is a reasonable tool for that language.
    ///
    /// Two guards, because "a better model exists" is true for almost every
    /// pairing and would make the nudge noise. A single-language cell carries
    /// ±5 pp, so an absolute gap alone proves nothing; the ratio is what
    /// separates a worthwhile upgrade from the wrong tool. Calibrated against
    /// the booked table: MiniCPM5 on Hebrew (1 vs 18) and on Turkish (5 vs 18)
    /// fire; MiniCPM5 on Russian (17 vs 24) does NOT — there a Gemma is better
    /// but the small model is still the best of its weight class, which is a
    /// memory trade-off the user already made, not a mistake to correct.
    static func materiallyBetter(than currentID: String,
                                 on language: String) -> (id: String, current: Int, best: Int)? {
        // Apple Intelligence is excluded on purpose. It trails on nearly every
        // language, so the nudge would never clear — and its entire value is
        // downloading nothing, which every alternative undoes. Picking it is an
        // informed trade-off (its own card lists the language weaknesses), not
        // the accidental mismatch this exists to catch.
        guard currentID != ModelCatalog.appleIntelligenceID else { return nil }
        guard let mine = axisAccuracy(for: currentID, axis: language) else { return nil }
        let bestID = ModelPriority.accurate.pick(axis: language)
        guard bestID != currentID, let best = axisAccuracy(for: bestID, axis: language),
              best >= mine + 5, Double(best) >= 1.5 * Double(mine)
        else { return nil }
        return (bestID, mine, best)
    }

    /// Human name of an axis, for the picker and captions.
    static func axisDisplayName(_ axis: String) -> String {
        switch axis {
        // "pooled" carries the caveat in the name: the two languages inside it
        // measure differently on every small model, so a label reading
        // "English + Russian" was one number pretending to answer for both.
        case "core": return "English + Russian pooled"
        case "*": return "all \(evalLanguages.count) languages"
        default: return Locale.current.localizedString(forLanguageCode: axis)?.capitalized ?? axis
        }
    }

    /// Download sizes of the instruct siblings, GB — hub sizes of what the
    /// engine fetches (the Gemma ones from their slim re-packs, which keep the
    /// vision tower the MTP path loads, so this is also what they hold
    /// resident). Feeds the setup summary's memory estimate and the download
    /// prompt when Instruct style loads a second model. Not the default
    /// ladder: `ModelCatalog.defaultID(forRamGB:)` is a fixed table.
    private static let instructSizesGB: [String: Double] = [
        "mlx-community/gemma-4-e4b-it-6bit": 5.56,
        "mlx-community/gemma-4-e4b-it-4bit": 4.57,
        "mlx-community/gemma-4-e2b-it-4bit": 2.97,
        "mlx-community/Qwen3.5-2B-4bit": 1.6,  // Qwen3.5 Base's chord sibling
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

    // MARK: - Fix & reply tasks

    /// Measured quality of the two instruct-templated tasks — the fix chord
    /// and the reply chord — keyed by the model that RUNS them: the sibling
    /// the engine loads, not the catalog entry, so two catalog rows sharing a
    /// sibling share one measurement and can never fork.
    ///
    /// Protocol: `Eval/eval-correct.jsonl` — 510 single-typo sentences plus
    /// 170 clean controls, 17 languages; fix% = restored EXACTLY to the clean
    /// line, false-fix% = proposed a change on a line with nothing wrong.
    /// `Eval/eval-reply.jsonl` — the 380 on-screen conversations (19
    /// languages) that carry no draft; reply% = drafted something in the
    /// conversation's language without restating the screen — a floor on
    /// usability, not a quality score. The 190 draft rows are a separate
    /// slice: a draft hands the model its language, so pooling them inflated
    /// every model that got the language wrong on its own (EVAL_REVIEW
    /// 2026-07-29 §2).
    /// Booked from `Eval/runs-2026-10-11/` (book-tasks.py), see `taskSource`.
    /// The 07-25 booking is superseded wholesale: its echo check normalized
    /// only one side (MiniCPM5's "best replier" verdict was its echoes), it
    /// ran with the developer's own persona (which turned every Gemma reply
    /// English), on a debug build, and before Gemma 4 stopped at `<turn|>`.
    /// Verdicts at the p<0.01 rule, paired over the shared rows: the fix
    /// column is a clean ladder — every adjacent gap (69 > 65 > 50 > 33 > 19
    /// > 11 > 4) significant at p<0.001, E4B-it 6-bit ahead of its 4-bit
    /// build (p=9e-4). On replies the three Gemma siblings tie (95–97%,
    /// p≥0.45), then Qwen3.5 > Qwen0.5B-it > Bonsai (p<0.001 each), Bonsai
    /// tying MiniCPM5 (p=0.27) — the small models' drafts mostly restate the
    /// screen, which `cleanReply` now drops. MiniCPM5's own row (fix 4% /
    /// reply 35%) left the table on 2026-10-15 with its chords, which now
    /// ride Qwen3.5's sibling — no pick runs it at recommended settings.
    struct TaskMetrics {
        /// % of typo rows restored exactly (n=510; Wilson 95% CI in `fixCI`).
        let fixPct: Int
        let fixCI: ClosedRange<Int>
        /// % of clean control rows it "fixed" anyway (n=170).
        let falseFixPct: Int
        /// Warm median latency of a fix, ms, on the dev machine (release build).
        let fixP50Ms: Int
        /// % of reply rows meeting the contract — answered, in the
        /// conversation's language, not restating it — over the 380 rows
        /// with no draft (Wilson 95% CI).
        let replyPct: Int
        let replyCI: ClosedRange<Int>
        let replyP50Ms: Int
    }

    /// eval-correct / eval-reply, 2026-10-11 (`Eval/runs-2026-10-11`): release
    /// build, persona pinned empty, Gemma 4 stopping on `<turn|>`, the reply
    /// prompt naming the conversation's language, echoes dropped by
    /// `cleanReply`, draft rows out of the reply denominator. Fix p50 since
    /// re-booked for prompt-lookup drafting (`Eval/runs-2026-10-11-lookup`):
    /// the lookup-off/on ratio of same-session release pairs, applied to the
    /// figures above — the machine was shared that evening, so its absolute
    /// timings ran high. Qwen3.5 (recurrent cache, no lookup) and E4B-it-6bit
    /// (a tie) keep theirs.
    static let taskSource = "eval-correct/eval-reply, 2026-10-11"

    static let tasks: [String: TaskMetrics] = [
        "mlx-community/gemma-4-e4b-it-6bit": TaskMetrics(
            fixPct: 69, fixCI: 65...73, falseFixPct: 18, fixP50Ms: 257,
            replyPct: 97, replyCI: 94...98, replyP50Ms: 331),
        "mlx-community/gemma-4-e4b-it-4bit": TaskMetrics(
            fixPct: 65, fixCI: 61...69, falseFixPct: 21, fixP50Ms: 208,
            replyPct: 95, replyCI: 92...97, replyP50Ms: 249),
        "mlx-community/gemma-4-e2b-it-4bit": TaskMetrics(
            fixPct: 50, fixCI: 45...54, falseFixPct: 29, fixP50Ms: 81,
            replyPct: 96, replyCI: 93...97, replyP50Ms: 89),
        "mlx-community/Qwen3.5-2B-4bit": TaskMetrics(
            fixPct: 33, fixCI: 29...37, falseFixPct: 28, fixP50Ms: 137,
            replyPct: 76, replyCI: 72...80, replyP50Ms: 152),
        "mlx-community/Qwen2.5-0.5B-Instruct-4bit": TaskMetrics(
            fixPct: 11, fixCI: 9...14, falseFixPct: 19, fixP50Ms: 34,
            replyPct: 52, replyCI: 47...57, replyP50Ms: 73),
        "prism-ml/Ternary-Bonsai-4B-mlx-2bit": TaskMetrics(
            fixPct: 19, fixCI: 16...23, falseFixPct: 12, fixP50Ms: 205,
            replyPct: 39, replyCI: 34...44, replyP50Ms: 210),
    ]

    /// Display names for the measured siblings — they are not catalog
    /// entries, so `metrics(for:)` doesn't know them.
    static let taskModelNames: [String: String] = [
        "mlx-community/gemma-4-e4b-it-6bit": "Gemma E4B-it 6-bit",
        "mlx-community/gemma-4-e4b-it-4bit": "Gemma E4B-it 4-bit",
        "mlx-community/gemma-4-e2b-it-4bit": "Gemma E2B-it 4-bit",
        "mlx-community/Qwen3.5-2B-4bit": "Qwen3.5 2B",
        "mlx-community/Qwen2.5-0.5B-Instruct-4bit": "Qwen2.5 0.5B-it",
        "prism-ml/Ternary-Bonsai-4B-mlx-2bit": "Bonsai 4B",
    ]

    /// The task figures the current pick would actually produce: resolves the
    /// sibling the engine loads for fix/reply — the instruct primary in
    /// Instruct style, the lazy correction sibling in Base style (mirrors
    /// `MLXEngine.correct`) — and looks it up. `measuredID` is the sibling the
    /// figures were measured on, so map/list surfaces can point at the same
    /// bubble. nil for Apple Intelligence (not in the task sweep) and for a
    /// sibling nobody measured.
    static func taskMetrics(for id: String, style: CompletionStyle)
        -> (m: TaskMetrics, runsOn: String, measuredID: String)? {
        guard id != ModelCatalog.appleIntelligenceID,
              let option = ModelCatalog.option(for: id) else { return nil }
        let sibling = style == .instruct ? option.instructModelID : option.correctionModelID
        guard let m = tasks[sibling] else { return nil }
        return (m, taskModelNames[sibling] ?? sibling, sibling)
    }

    /// Resident size of a measured task sibling, GB — bubble size on the
    /// map's task lenses. Falls back to catalog metrics for the models that
    /// correct with themselves (their sibling id IS a catalog id).
    static func taskRamGB(for siblingID: String) -> Double? {
        instructSizesGB[siblingID] ?? metrics(for: siblingID)?.ramGB
    }

    /// Catalog entries whose chords land on `siblingID` at their recommended
    /// settings, in catalog (quality) order. Ids feed the map's click-to-
    /// switch; `taskUsers` renders the same list as display names.
    static func taskUserIDs(of siblingID: String) -> [String] {
        ModelCatalog.options.compactMap { option in
            taskMetrics(for: option.id,
                        style: ModelCatalog.recommended(for: option.id).style)?
                .measuredID == siblingID ? option.id : nil
        }
    }

    /// The "used by" line on the task-lens map.
    static func taskUsers(of siblingID: String) -> [String] {
        taskUserIDs(of: siblingID).map { metrics(for: $0)?.shortName ?? $0 }
    }
}
