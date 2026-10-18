import Foundation

/// Measured per-model figures behind the settings UI (the quality/speed/size
/// chart and the model detail card). No spec-sheet estimates: accuracy and
/// latency come from eval runs (a derived p50 says so where it's booked),
/// `ramGB` is the weights a model loads — the size of what it downloads.
///
/// Protocol: `Eval/eval-real.jsonl` (5649 rows / 17 languages) plus
/// `Eval/eval-rtl.jsonl` (560 rows, Arabic and Hebrew, same three registers),
/// base · greedy · short, personalization off, confidence-trim and gates
/// pinned off, warm model, Apple-silicon dev machine (M4 Max). The whole
/// catalog was re-run on 2026-10-15 (`Eval/runs-2026-10-15-rebook/`,
/// run-quality.sh, booked by book.py) on one release build of the shipping
/// engine — own decode loop, slim re-packs, KV reuse, entropy stop. Accuracy
/// held through all of it: every model pairs with its July run
/// (runs-2026-07-16 / -25) at p ≥ 0.08. The headline axis is the **EN+RU
/// core** (n=1449) so rows compare on the languages the app is tuned for —
/// 17-language verdicts (coverage cliffs, McNemar: verdicts.py) live in
/// `note`. p50: run-latency.sh, without the logP pass (it inflates
/// wall-clock) — the faster of two interleaved rounds over the core, since
/// the machine is shared; Apple Intelligence from one round there.
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
    static let evalSource = String(localized: "eval-real, English+Russian pooled, n=1449, 2026-10-15")

    static let all: [ModelMetrics] = [
        ModelMetrics(id: "mlx-community/gemma-4-e4b-8bit", shortName: "E4B 8-bit",
                     firstWordPct: 31, ci: 29...34, coveragePct: 83,
                     logProbPerChar: -0.855, p50Ms: 78, ramGB: 5.98,
                     note: String(localized: "Top of the 17-language set and steady across all of them — but only a trend ahead of E2B 8-bit (p=0.013, n=5649) and tied with E4B 6-bit (p=0.28), for the most memory in the catalog.")),
        ModelMetrics(id: "mlx-community/gemma-4-e4b-6bit", shortName: "E4B 6-bit",
                     firstWordPct: 32, ci: 29...34, coveragePct: 82,
                     logProbPerChar: -0.865, p50Ms: 81, ramGB: 5.03,
                     note: String(localized: "Ties E4B 8-bit on the 17-language set (p=0.28) at ~1 GB less — and E2B 8-bit too (p=0.11).")),
        ModelMetrics(id: "mlx-community/gemma-4-e2b-8bit", shortName: "E2B 8-bit",
                     firstWordPct: 31, ci: 28...34, coveragePct: 83,
                     logProbPerChar: -0.886, p50Ms: 46, ramGB: 3.41,
                     note: String(localized: "Statistically level with both E4B builds on the 17-language set (p=0.013 vs 8-bit, p=0.11 vs 6-bit) in less memory and ~40% less time per suggestion; robust across all 17 eval languages.")),
        // E4B-4bit and LFM2.5 delisted 2026-07-17: each strictly dominated by a
        // catalog neighbor on every axis (E2B-4bit and MiniCPM5 respectively).
        ModelMetrics(id: "mlx-community/gemma-4-e2b-4bit", shortName: "E2B 4-bit",
                     firstWordPct: 30, ci: 28...33, coveragePct: 84,
                     logProbPerChar: -0.925, p50Ms: 34, ramGB: 2.51,
                     note: String(localized: "Mildest 4-bit cost in the field: level with E2B 8-bit on English (28 vs 26) and on Russian (22 vs 25) — neither gap significant — but behind it on 17 languages (p<0.001), and still ahead of every smaller model there (Qwen3.5 2B p<0.001), at 0.9 GB less and a little faster.")),
        // Our 8-bit build since 2026-10-15; it ties the hub's bf16 (paired,
        // Eval/runs-2026-10-14-small), and this row is the 8-bit build's own.
        ModelMetrics(id: "nikimori/MiniCPM5-1B-Base-8bit", shortName: "MiniCPM5 1B",
                     firstWordPct: 29, ci: 26...32, coveragePct: 82,
                     logProbPerChar: -1.042, p50Ms: 18, ramGB: 1.1,
                     note: String(localized: "An English specialist and, with Qwen 0.5B, the fastest model in the catalog — on English it ties E2B 8-bit outright (28% vs 26%, p=0.12). Russian is a different story: 17% against E2B 8-bit's 25% (p<0.001). Wider multilingual coverage collapses (uk/ro/tr/cs 56–62% vs the Gemmas' ≥74%), and Hebrew is its floor at 3% — effectively blind.")),
        ModelMetrics(id: "mlx-community/Qwen2.5-0.5B-bf16", shortName: "Qwen2.5 0.5B",
                     firstWordPct: 27, ci: 25...30, coveragePct: 82,
                     logProbPerChar: -1.051, p50Ms: 17, ramGB: 1.0,
                     note: String(localized: "Smallest footprint; a trend behind MiniCPM5 on 17 languages (p=0.028), and clearly behind its bigger sibling Qwen3.5 2B (p<0.001).")),
        // The Base build at 6-bit; the 10-15 run reproduces its 10-14 booking
        // output for output (Eval/runs-2026-10-14-small).
        ModelMetrics(id: "nikimori/Qwen3.5-2B-Base-6bit", shortName: "Qwen3.5 2B",
                     firstWordPct: 30, ci: 27...33, coveragePct: 81,
                     logProbPerChar: -0.942, p50Ms: 32, ramGB: 1.5,
                     note: String(localized: "Best sub-2 GB pick multilingually — beats MiniCPM5, Bonsai and Qwen 0.5B on the 17-language set (all p<0.001) with the mildest coverage sag; ties MiniCPM5 on English (28 vs 28), leads it on Russian (21 vs 17, a trend: p=0.018), and on Russian is level with the lightest Gemma (21 vs 22, p=0.19). The Base build at 6-bit: ahead of the 4-bit build (p<0.001) and tied with 8-bit, in 1.5 GB. On Arabic and Hebrew its lead over the other small models shrinks — a Gemma tier is still well ahead there.")),
        // The Base↔post-trained merge, booked 2026-10-16 with the 10-15 rules
        // (Eval/runs-2026-10-16-m1/rebook: book.py, calib-live.py); p50 = the
        // Base row's 32 ms × the interleaved same-binary ratio 36/36 ms.
        ModelMetrics(id: "nikimori/Qwen3.5-2B-M40-6bit", shortName: "Qwen3.5 2B M40",
                     firstWordPct: 29, ci: 27...32, coveragePct: 80,
                     logProbPerChar: -0.937, p50Ms: 32, ramGB: 1.5,
                     note: String(localized: "Qwen3.5 2B with part of its post-trained build blended in, so one 1.5 GB model both types and fixes — no second download. Completions tie the Base build (18.5 vs 18.9% on 17 languages, p=0.06). The fix chord restores more typos than the Base pick's sibling (41 vs 33%) and changes clean lines far less often (10 vs 28%), both p<0.001.")),
        ModelMetrics(id: "prism-ml/Ternary-Bonsai-4B-mlx-2bit", shortName: "Bonsai 4B",
                     firstWordPct: 27, ci: 24...29, coveragePct: 82,
                     logProbPerChar: -1.083, p50Ms: 44, ramGB: 1.1,
                     note: String(localized: "Ternary 4B in 1.1 GB; measurably behind MiniCPM5 on the 17-language set (p=0.004), with the same coverage sag outside English and Western Europe (uk 62%, cs 63%).")),
        // Apple Intelligence exposes no logprobs, so the /char scoring can't run.
        ModelMetrics(id: "system.apple-intelligence", shortName: "Apple Intelligence",
                     firstWordPct: 17, ci: 15...19, coveragePct: 97,
                     logProbPerChar: nil, p50Ms: 480, ramGB: 0,
                     note: String(localized: "System model on the Neural Engine — no download, no app memory. The macOS 27 model answers almost every prompt (97% on English and Russian) and now covers Polish, Romanian and Czech too, but it is right less often than any downloadable model: 10% of Russian rows against 22% of English, and next to none in Japanese or Chinese. On Arabic and Hebrew it answers 84–87% and is right 6% of the time.")),
    ]

    static func metrics(for id: String) -> ModelMetrics? {
        all.first { $0.id == id }
    }

    /// Completion in Instruct style on the E4B tiers, the only ones where it
    /// completes: the it-6bit sibling with an English+Russian default persona,
    /// on the headline's rows and pins (runs-2026-10-15-rebook,
    /// e4b-it6-instruct). It answers nearly every prompt and is right less
    /// often — 20% of shown on the core against 32% for E4B 6-bit in Base
    /// style (paired p≈1e-9), 15% vs 23% of all rows on the 17-language set,
    /// so the E4B tiers left it for Base on 2026-10-15. Its case is text you
    /// author, with a persona and fill-in-the-middle (eval-v2, 85%), which
    /// real text doesn't test.
    static let instructCompletion = ModelMetrics(
        id: "mlx-community/gemma-4-e4b-it-6bit", shortName: "E4B-it 6-bit",
        firstWordPct: 20, ci: 18...22, coveragePct: 99,
        logProbPerChar: nil, p50Ms: 91, ramGB: 5.56, note: nil)

    /// The precision gate as it ships — the live first-word logprob against
    /// the model's own τ (`ModelCatalog.recommended(for:).logprobGateTau`) —
    /// on the headline's EN+RU core rows: % of prompts that still get a
    /// suggestion, and first-word accuracy of those. Measured per
    /// model on 2026-10-15 (runs-2026-10-15-rebook, calib-live.py), after τ
    /// moved to the live recorder's scale: the offline-calibrated τ passed
    /// only 15–22% of suggestions where its calibration said 25%. Booked on
    /// the ODD half only (n=724): τ is the even half's Q4 edge, so the even
    /// rows would score the threshold on its own calibration data. The
    /// per-script τ don't touch these rows — en/ru keep the model τ.
    static let gated: [String: (shownPct: Int, firstWordPct: Int)] = [
        "mlx-community/gemma-4-e4b-8bit": (18, 60),
        "mlx-community/gemma-4-e4b-6bit": (18, 56),
        "mlx-community/gemma-4-e2b-8bit": (19, 55),
        "mlx-community/gemma-4-e2b-4bit": (20, 53),
        "nikimori/MiniCPM5-1B-Base-8bit": (19, 53),
        "mlx-community/Qwen2.5-0.5B-bf16": (27, 41),
        "nikimori/Qwen3.5-2B-Base-6bit": (21, 53),
        "nikimori/Qwen3.5-2B-M40-6bit": (23, 49),
        "prism-ml/Ternary-Bonsai-4B-mlx-2bit": (26, 42),
    ]

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
            ["ar": 13, "cs": 23, "de": 29, "en": 28, "es": 31, "fr": 26, "he": 17, "it": 25, "ja": 5, "ko": 12, "nl": 28, "pl": 28, "pt": 23, "ro": 31, "ru": 23, "sv": 26, "tr": 16, "uk": 24, "zh": 14],
        "mlx-community/gemma-4-e4b-6bit":
            ["ar": 11, "cs": 21, "de": 28, "en": 29, "es": 29, "fr": 26, "he": 16, "it": 26, "ja": 5, "ko": 10, "nl": 28, "pl": 26, "pt": 25, "ro": 29, "ru": 22, "sv": 24, "tr": 17, "uk": 25, "zh": 14],
        "mlx-community/gemma-4-e2b-8bit":
            ["ar": 10, "cs": 20, "de": 27, "en": 26, "es": 30, "fr": 27, "he": 18, "it": 26, "ja": 4, "ko": 11, "nl": 24, "pl": 28, "pt": 25, "ro": 28, "ru": 25, "sv": 23, "tr": 16, "uk": 20, "zh": 12],
        "mlx-community/gemma-4-e2b-4bit":
            ["ar": 8, "cs": 17, "de": 22, "en": 28, "es": 27, "fr": 25, "he": 16, "it": 24, "ja": 3, "ko": 9, "nl": 22, "pl": 24, "pt": 22, "ro": 27, "ru": 22, "sv": 20, "tr": 13, "uk": 18, "zh": 11],
        "nikimori/MiniCPM5-1B-Base-8bit":
            ["ar": 6, "cs": 6, "de": 16, "en": 28, "es": 25, "fr": 20, "he": 3, "it": 18, "ja": 6, "ko": 6, "nl": 14, "pl": 9, "pt": 16, "ro": 8, "ru": 17, "sv": 10, "tr": 5, "uk": 6, "zh": 9],
        "mlx-community/Qwen2.5-0.5B-bf16":
            ["ar": 6, "cs": 6, "de": 14, "en": 27, "es": 23, "fr": 19, "he": 9, "it": 15, "ja": 4, "ko": 6, "nl": 12, "pl": 12, "pt": 18, "ro": 10, "ru": 16, "sv": 5, "tr": 6, "uk": 6, "zh": 10],
        "nikimori/Qwen3.5-2B-Base-6bit":
            ["ar": 8, "cs": 11, "de": 20, "en": 28, "es": 28, "fr": 26, "he": 13, "it": 21, "ja": 3, "ko": 7, "nl": 21, "pl": 19, "pt": 24, "ro": 23, "ru": 21, "sv": 19, "tr": 9, "uk": 17, "zh": 9],
        // Booked 2026-10-16 on the same rules (runs-2026-10-16-m1/rebook/book.py).
        "nikimori/Qwen3.5-2B-M40-6bit":
            ["ar": 7, "cs": 12, "de": 20, "en": 27, "es": 26, "fr": 24, "he": 13, "it": 21, "ja": 2, "ko": 8, "nl": 21, "pl": 19, "pt": 24, "ro": 22, "ru": 20, "sv": 19, "tr": 9, "uk": 16, "zh": 9],
        "prism-ml/Ternary-Bonsai-4B-mlx-2bit":
            ["ar": 4, "cs": 5, "de": 16, "en": 27, "es": 23, "fr": 21, "he": 8, "it": 14, "ja": 4, "ko": 3, "nl": 12, "pl": 10, "pt": 16, "ro": 12, "ru": 16, "sv": 9, "tr": 5, "uk": 8, "zh": 5],
        "system.apple-intelligence":
            ["ar": 6, "cs": 3, "de": 10, "en": 22, "es": 14, "fr": 16, "he": 6, "it": 9, "ja": 0, "ko": 2, "nl": 13, "pl": 12, "pt": 9, "ro": 7, "ru": 10, "sv": 10, "tr": 3, "uk": 9, "zh": 1],
    ]

    /// Rows behind each language's cell — the denominator `perLangOfAll` is
    /// computed over (matched registers; EN excludes the 200 Enron rows no
    /// other language has). A percentage without this is a number
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
    /// the booked table: MiniCPM5 on Hebrew (3 vs 18) and on Turkish (5 vs 17)
    /// fire; MiniCPM5 on Russian (17 vs 25) does NOT — there a Gemma is better
    /// but the small model is still a usable tool in its weight class, which
    /// is a memory trade-off the user already made, not a mistake to correct.
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
        case "core": return String(localized: "English + Russian pooled")
        case "*": return String(localized: "all \(evalLanguages.count) languages")
        default: return Locale.current.localizedString(forLanguageCode: axis)?.capitalized ?? axis
        }
    }

    /// Download sizes of the instruct siblings, GB — hub sizes of what the
    /// engine fetches (from the slim re-packs; the Gemma ones keep the
    /// vision tower the MTP path loads, so this is also what they hold
    /// resident). Feeds the setup summary's memory estimate and the download
    /// prompt when Instruct style loads a second model. Not the default
    /// ladder: `ModelCatalog.defaultID(forRamGB:)` is a fixed table.
    private static let instructSizesGB: [String: Double] = [
        "mlx-community/gemma-4-e4b-it-6bit": 5.56,
        "mlx-community/gemma-4-e4b-it-4bit": 4.57,
        "mlx-community/gemma-4-e2b-it-4bit": 2.97,
        "mlx-community/Qwen3.5-2B-4bit": 1.06,  // Qwen3.5 Base's chord sibling
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
    /// languages) that carry no draft; reply% = drafts an independent judge
    /// (GPT-6 Luna, 1–5, pass ≥3 — the threshold fixed on the real-next-line
    /// vs random-line baselines alone) rates as on topic. The earlier
    /// "contract" (right language, no restated screen) was a floor that a
    /// line from ANOTHER conversation passed 94% of the time; it overstated
    /// the small siblings 2–15×. Four judges from four families (Luna,
    /// DeepSeek, Haiku, E4B-it) give the same order of every sibling
    /// (Eval/runs-2026-10-16-judge, BASELINE 2026-10-16 (m)(n)). The 190
    /// draft rows are a separate slice: a draft hands the model its
    /// language, so pooling them inflated every model that got the language
    /// wrong on its own (EVAL_REVIEW 2026-07-29 §2).
    /// Booked from `Eval/runs-2026-10-15-rebook/` (run-tasks.sh's dumps, same
    /// harness and sets as `Eval/runs-2026-10-11/`), see `taskSource`.
    /// The 07-25 booking is superseded wholesale: its echo check normalized
    /// only one side (MiniCPM5's "best replier" verdict was its echoes), it
    /// ran with the developer's own persona (which turned every Gemma reply
    /// English), on a debug build, and before Gemma 4 stopped at `<turn|>`.
    /// Verdicts at the p<0.01 rule, paired over the shared rows: on the
    /// 10-15 run the fix column is a clean ladder — every adjacent gap (69 >
    /// 65 > 50 > 33 > 19 > 11) significant at p<0.001, E4B-it 6-bit ahead of
    /// its 4-bit build (p=9e-4). The M40 merge's 41%, from its own run
    /// (2026-10-16), beats the Qwen3.5 sibling's 33% (p<0.001); its gap to
    /// E2B-it's 50% was never tested. On replies E4B-it 6-bit > E2B-it 4-bit (p=0.002; the
    /// adjacent Gemma gaps n.s.), then a cliff to Qwen3.5 (p=8e-41) > Bonsai
    /// (p=2e-4) > Qwen0.5B-it (p=1e-14). The 10-15 re-run reproduced every
    /// fix output (97–100% identical). MiniCPM5's own row (fix 4% / reply
    /// 34% on topic) left the table on 2026-10-15 with its chords,
    /// which now ride Qwen3.5's sibling — no pick runs it at recommended
    /// settings.
    struct TaskMetrics {
        /// % of typo rows restored exactly (n=510; Wilson 95% CI in `fixCI`).
        let fixPct: Int
        let fixCI: ClosedRange<Int>
        /// % of clean control rows it "fixed" anyway (n=170).
        let falseFixPct: Int
        /// Warm median latency of a fix, ms, on the dev machine (release build).
        let fixP50Ms: Int
        /// % of reply drafts the judge rates on topic, over the 380 rows
        /// with no draft (no draft = a miss; Wilson 95% CI).
        let replyPct: Int
        let replyCI: ClosedRange<Int>
        let replyP50Ms: Int
        /// Set when the row was booked on a run of its own rather than the
        /// table's (`taskSource`): how that run differs, and its figure for
        /// a sibling the table holds too. No gap between it and the table's
        /// rows was tested, so its name carries a ¹ (`taskModelNames`) and
        /// rankings drawn from the table leave it out (`ModelCatalog.rationale`).
        var ownRun: String?
    }

    /// eval-correct / eval-reply, re-run 2026-10-15 on the shipping engine
    /// (`Eval/runs-2026-10-15-rebook`, run-tasks.sh): release build, persona
    /// pinned empty, MTP drafters and prompt-lookup on as shipped, slim
    /// re-packs, draft rows out of the reply denominator; those reply dumps
    /// judged 2026-10-16. p50s are the run's own, measured straight.
    static let taskSource = "eval-correct 2026-10-15 · eval-reply judged by GPT-6 Luna 2026-10-16"
        + tasks.compactMap { id, t in t.ownRun.map { "; ¹ \(siblingNames[id] ?? id): \($0)" } }
            .sorted().joined()

    static let tasks: [String: TaskMetrics] = [
        "mlx-community/gemma-4-e4b-it-6bit": TaskMetrics(
            fixPct: 69, fixCI: 65...73, falseFixPct: 18, fixP50Ms: 168,
            replyPct: 90, replyCI: 86...92, replyP50Ms: 409),
        "mlx-community/gemma-4-e4b-it-4bit": TaskMetrics(
            fixPct: 65, fixCI: 61...69, falseFixPct: 20, fixP50Ms: 243,
            replyPct: 87, replyCI: 83...90, replyP50Ms: 243),
        "mlx-community/gemma-4-e2b-it-4bit": TaskMetrics(
            fixPct: 50, fixCI: 46...54, falseFixPct: 30, fixP50Ms: 96,
            replyPct: 83, replyCI: 79...86, replyP50Ms: 88),
        "mlx-community/Qwen3.5-2B-4bit": TaskMetrics(
            fixPct: 33, fixCI: 29...37, falseFixPct: 28, fixP50Ms: 134,
            replyPct: 35, replyCI: 30...40, replyP50Ms: 137),
        // Its own chords (Eval/runs-2026-10-16-m1, same binary as a re-run of
        // the Qwen3.5 sibling above): replies judged by Qwen3.8 27B, the
        // best-validated judge (AUC 0.825), not Luna — on the 10-15 dumps the
        // two agree within 3 pp on every sibling (Qwen3.5 37 vs 35%), and on
        // this run the sibling scores 37% [32–42] against the merge's 56%
        // (paired p=2.5e-8).
        "nikimori/Qwen3.5-2B-M40-6bit": TaskMetrics(
            fixPct: 41, fixCI: 37...45, falseFixPct: 10, fixP50Ms: 173,
            replyPct: 56, replyCI: 50...60, replyP50Ms: 156,
            ownRun: "booked on its own run (2026-10-16), replies judged by Qwen3.8 27B, which rates the Qwen3.5 2B sibling 37% [32–42] there"),
        "mlx-community/Qwen2.5-0.5B-Instruct-4bit": TaskMetrics(
            fixPct: 11, fixCI: 9...14, falseFixPct: 19, fixP50Ms: 33,
            replyPct: 3, replyCI: 2...6, replyP50Ms: 78),
        "prism-ml/Ternary-Bonsai-4B-mlx-2bit": TaskMetrics(
            fixPct: 19, fixCI: 16...23, falseFixPct: 12, fixP50Ms: 203,
            replyPct: 22, replyCI: 18...27, replyP50Ms: 205),
    ]

    /// Display names for the measured siblings — they are not catalog
    /// entries, so `metrics(for:)` doesn't know them. A row from a run of its
    /// own (`TaskMetrics.ownRun`) is marked ¹, which `taskSource` explains.
    static let taskModelNames: [String: String] = siblingNames.reduce(into: [:]) { names, entry in
        names[entry.key] = entry.value + (tasks[entry.key]?.ownRun == nil ? "" : "¹")
    }

    private static let siblingNames: [String: String] = [
        "mlx-community/gemma-4-e4b-it-6bit": "Gemma E4B-it 6-bit",
        "mlx-community/gemma-4-e4b-it-4bit": "Gemma E4B-it 4-bit",
        "mlx-community/gemma-4-e2b-it-4bit": "Gemma E2B-it 4-bit",
        "mlx-community/Qwen3.5-2B-4bit": "Qwen3.5 2B",
        "nikimori/Qwen3.5-2B-M40-6bit": "Qwen3.5 2B M40",
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
