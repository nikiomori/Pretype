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
                     note: "Mildest 4-bit cost in the field: ties E2B 8-bit on English (27 vs 26) and on Russian (22 vs 23) alike, measurably behind it on 17 languages (p<0.001) yet still ahead of every smaller model — at 2.2 GB less, though slower."),
        ModelMetrics(id: "openbmb/MiniCPM5-1B-Base", shortName: "MiniCPM5 1B",
                     firstWordPct: 28, ci: 26...31, coveragePct: 81,
                     logProbPerChar: -1.041, p50Ms: 49, ramGB: 2.2,
                     note: "Fastest in the catalog and an English specialist — on English it ties E2B 8-bit outright (27% vs 26%, p=0.35). Russian is a different story: 17% against E2B 8-bit's 23% (p<0.001), still the best of the small models there but not parity. Wider multilingual coverage collapses (uk/ro/tr/cs 53–69% vs the Gemmas' ≥78%), and Hebrew is its floor at 1% — effectively blind."),
        ModelMetrics(id: "mlx-community/Qwen2.5-0.5B-bf16", shortName: "Qwen2.5 0.5B",
                     firstWordPct: 26, ci: 23...28, coveragePct: 84,
                     logProbPerChar: -1.051, p50Ms: 79, ramGB: 1.0,
                     note: "Smallest footprint; ties MiniCPM5 on 17 languages (p=0.084), though its bigger sibling Qwen3.5 2B measures clearly better (p<0.001)."),
        ModelMetrics(id: "mlx-community/Qwen3.5-2B-4bit", shortName: "Qwen3.5 2B",
                     firstWordPct: 27, ci: 24...29, coveragePct: 81,
                     logProbPerChar: -0.993, p50Ms: 93, ramGB: 1.6,
                     note: "Best sub-2 GB pick multilingually — beats MiniCPM5, Bonsai and Qwen 0.5B on the 17-language set (all p<0.001) with the mildest coverage sag; matches MiniCPM5 on English (26 vs 27) and on Russian (17 vs 17) alike. On Arabic and Hebrew its lead over the other small models disappears (ties Qwen 0.5B and Bonsai; only MiniCPM5 is worse) — a Gemma tier roughly doubles it there."),
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
        "openbmb/MiniCPM5-1B-Base":
            ["ar": 5, "cs": 6, "de": 16, "en": 27, "es": 25, "fr": 20, "he": 1, "it": 17, "ja": 6, "ko": 7, "nl": 13, "pl": 10, "pt": 16, "ro": 6, "ru": 17, "sv": 9, "tr": 5, "uk": 5, "zh": 9],
        "mlx-community/Qwen2.5-0.5B-bf16":
            ["ar": 6, "cs": 6, "de": 15, "en": 26, "es": 21, "fr": 19, "he": 9, "it": 15, "ja": 4, "ko": 5, "nl": 14, "pl": 13, "pt": 16, "ro": 9, "ru": 16, "sv": 6, "tr": 6, "uk": 6, "zh": 10],
        "mlx-community/Qwen3.5-2B-4bit":
            ["ar": 6, "cs": 7, "de": 18, "en": 26, "es": 24, "fr": 22, "he": 10, "it": 20, "ja": 2, "ko": 6, "nl": 17, "pl": 14, "pt": 22, "ro": 18, "ru": 17, "sv": 13, "tr": 7, "uk": 15, "zh": 8],
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
        "openbmb/MiniCPM5-1B-Base":
            ["ar": 59, "cs": 60, "de": 89, "en": 86, "es": 88, "fr": 83, "he": 58, "it": 83, "ja": 70, "ko": 55, "nl": 74, "pl": 69, "pt": 88, "ro": 57, "ru": 76, "sv": 78, "tr": 57, "uk": 53, "zh": 51],
        "mlx-community/Qwen2.5-0.5B-bf16":
            ["ar": 68, "cs": 65, "de": 88, "en": 88, "es": 90, "fr": 83, "he": 71, "it": 80, "ja": 72, "ko": 50, "nl": 79, "pl": 73, "pt": 90, "ro": 67, "ru": 80, "sv": 66, "tr": 64, "uk": 67, "zh": 55],
        "mlx-community/Qwen3.5-2B-4bit":
            ["ar": 65, "cs": 64, "de": 87, "en": 86, "es": 84, "fr": 80, "he": 68, "it": 78, "ja": 67, "ko": 57, "nl": 74, "pl": 71, "pt": 86, "ro": 75, "ru": 77, "sv": 76, "tr": 61, "uk": 74, "zh": 53],
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

    // MARK: - Fix & reply tasks

    /// Measured quality of the two instruct-templated tasks — the fix chord
    /// and the reply chord — keyed by the model that RUNS them: the sibling
    /// the engine loads, not the catalog entry, so two catalog rows sharing a
    /// sibling share one measurement and can never fork.
    ///
    /// Protocol: `Eval/eval-correct.jsonl` — 510 single-typo sentences plus
    /// 170 clean controls, 17 languages; fix% = restored EXACTLY to the clean
    /// line, false-fix% = proposed a change on a line with nothing wrong.
    /// `Eval/eval-reply.jsonl` — 570 on-screen conversations, 19 languages;
    /// reply% = drafted something in the conversation's language without
    /// echoing the screen — a floor on usability, not a quality score.
    /// Booked from `Eval/runs-2026-07-25-tasks/` (book-tasks.py): the E4B
    /// sibling from the correct3 rerun — after the turn-marker stop and
    /// run-on trim landed; the earlier pass lost 39% of its rows to same-line
    /// junk — everything else from correct2, where junk was ~0 so those fixes
    /// don't move them. Bonsai (which corrects with itself — no instruct
    /// conversion of the ternary QAT exists) ran the same evening on the
    /// current-code pipeline (run-bonsai.sh, correct3-/reply-bonsai dumps).
    /// Verdicts at the p<0.01 rule: E4B-it is the strongest fixer (vs E2B-it
    /// p=1e-10, paired over the shared 510 rows) and MiniCPM5's instruct
    /// build the strongest replier (vs Qwen3.5 p=5e-4) — each is the other
    /// task's weak model. The fix column is a clean ladder: every adjacent
    /// gap (65 > 50 > 32 > 21 > 11 > 4) is CLAIM-significant, Bonsai slotting
    /// below Qwen3.5 (p=7e-7) and above Qwen0.5B-it (p=2e-6). On replies
    /// Bonsai is last outright — its drafts survive mostly in English (80%)
    /// and Russian (70%) and collapse elsewhere.
    struct TaskMetrics {
        /// % of typo rows restored exactly (n=510; Wilson 95% CI in `fixCI`).
        let fixPct: Int
        let fixCI: ClosedRange<Int>
        /// % of clean control rows it "fixed" anyway (n=170).
        let falseFixPct: Int
        /// Warm median latency of a fix, ms, on the dev machine.
        let fixP50Ms: Int
        /// % of reply rows meeting the contract (n=570; Wilson 95% CI).
        let replyPct: Int
        let replyCI: ClosedRange<Int>
        let replyP50Ms: Int
    }

    static let tasks: [String: TaskMetrics] = [
        "mlx-community/gemma-4-e4b-it-4bit": TaskMetrics(
            fixPct: 65, fixCI: 60...69, falseFixPct: 21, fixP50Ms: 1523,
            replyPct: 33, replyCI: 30...37, replyP50Ms: 532),
        "mlx-community/gemma-4-e2b-it-4bit": TaskMetrics(
            fixPct: 50, fixCI: 45...54, falseFixPct: 29, fixP50Ms: 378,
            replyPct: 32, replyCI: 28...36, replyP50Ms: 356),
        "mlx-community/Qwen3.5-2B-4bit": TaskMetrics(
            fixPct: 32, fixCI: 28...37, falseFixPct: 28, fixP50Ms: 255,
            replyPct: 46, replyCI: 42...50, replyP50Ms: 448),
        "mlx-community/Qwen2.5-0.5B-Instruct-4bit": TaskMetrics(
            fixPct: 11, fixCI: 9...14, falseFixPct: 19, fixP50Ms: 185,
            replyPct: 38, replyCI: 35...42, replyP50Ms: 345),
        "openbmb/MiniCPM5-1B": TaskMetrics(
            fixPct: 4, fixCI: 2...6, falseFixPct: 14, fixP50Ms: 668,
            replyPct: 56, replyCI: 52...61, replyP50Ms: 1801),
        "prism-ml/Ternary-Bonsai-4B-mlx-2bit": TaskMetrics(
            fixPct: 21, fixCI: 18...25, falseFixPct: 14, fixP50Ms: 324,
            replyPct: 21, replyCI: 18...25, replyP50Ms: 324),
    ]

    /// Display names for the measured siblings — they are not catalog
    /// entries, so `metrics(for:)` doesn't know them.
    static let taskModelNames: [String: String] = [
        "mlx-community/gemma-4-e4b-it-4bit": "Gemma E4B-it 4-bit",
        "mlx-community/gemma-4-e2b-it-4bit": "Gemma E2B-it 4-bit",
        "mlx-community/Qwen3.5-2B-4bit": "Qwen3.5 2B",
        "mlx-community/Qwen2.5-0.5B-Instruct-4bit": "Qwen2.5 0.5B-it",
        "openbmb/MiniCPM5-1B": "MiniCPM5 1B-it",
        "prism-ml/Ternary-Bonsai-4B-mlx-2bit": "Bonsai 4B",
    ]

    /// The task figures the current pick would actually produce: resolves the
    /// sibling the engine loads for fix/reply — the instruct primary in
    /// Instruct style, the lazy correction sibling in Base style (mirrors
    /// `MLXEngine.correct`) — and looks it up. `measuredExactly` is false when
    /// the pick runs a sibling the sweep didn't cover and the figures come
    /// from its nearest measured build (E4B-it 6-bit → the 4-bit numbers, a
    /// floor); `measuredID` is the sibling the figures were measured on, so
    /// map/list surfaces can point at the same bubble. nil only for Apple
    /// Intelligence — the system model is not in the task sweep.
    static func taskMetrics(for id: String, style: CompletionStyle)
        -> (m: TaskMetrics, runsOn: String, measuredID: String, measuredExactly: Bool)? {
        guard id != ModelCatalog.appleIntelligenceID,
              let option = ModelCatalog.option(for: id) else { return nil }
        let sibling = style == .instruct ? option.instructModelID : option.correctionModelID
        if let m = tasks[sibling] {
            return (m, taskModelNames[sibling] ?? sibling, sibling, true)
        }
        if sibling == "mlx-community/gemma-4-e4b-it-6bit",
           let m = tasks["mlx-community/gemma-4-e4b-it-4bit"] {
            return (m, "Gemma E4B-it 4-bit", "mlx-community/gemma-4-e4b-it-4bit", false)
        }
        return nil
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
