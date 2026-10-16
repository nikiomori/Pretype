import Foundation

struct ModelOption {
    let id: String
    let title: String
    /// Download size, MB: the booked `ModelMetrics.ramGB` (0 without a row).
    var approxSizeMB: Int { Int(((ModelMetrics.metrics(for: id)?.ramGB ?? 0) * 1000).rounded()) }
    /// Instruct sibling used for fix-selection: corrections need instruction
    /// following (the base model paraphrases), while completion needs a base
    /// model (the instruct one echoes the prompt). Loaded lazily on first use.
    /// Base style runs BOTH chords (fix and reply) on it.
    let correctionModelID: String
    /// Instruct sibling that becomes the *primary* model in instruct
    /// completion style. On the Gemma builds it is sized to the entry's RAM
    /// tier: E4B 6-bit where the tier affords ~5.6 GB (an eval A/B showed
    /// instruct only matches/beats base at 6–8 bit), 4-bit siblings on the
    /// tighter tiers — a handicapped instruct still beats swapping a model the
    /// Mac can't hold. Overridable via PRETYPE_INSTRUCT_MODEL.
    let instructModelID: String
}

enum ModelCatalog {
    /// The out-of-the-box pick is sized on the Mac's memory (see `defaultID`):
    /// the best Gemma 4 tier that fits, Qwen3.5 2B below them. The Gemma entries
    /// are the BASE (pretrained)
    /// conversions — instruct variants echo the prompt instead of continuing it
    /// when used without a chat template.
    static let options: [ModelOption] = [
        ModelOption(
            id: "mlx-community/gemma-4-e4b-8bit",
            title: String(localized: "Gemma 4 E4B 8-bit — best quality"),
            correctionModelID: "mlx-community/gemma-4-e4b-it-6bit",
            instructModelID: "mlx-community/gemma-4-e4b-it-6bit"
        ),
        ModelOption(
            id: "mlx-community/gemma-4-e4b-6bit",
            title: String(localized: "Gemma 4 E4B 6-bit — lighter, near-best"),
            // it-6bit, not 4-bit: it fixes 69% of noisy lines against 65%
            // (p<0.001), and the installs that ran it as their Instruct
            // primary before 2026-10-15 already hold it.
            correctionModelID: "mlx-community/gemma-4-e4b-it-6bit",
            instructModelID: "mlx-community/gemma-4-e4b-it-6bit"
        ),
        ModelOption(
            id: "mlx-community/gemma-4-e2b-8bit",
            title: String(localized: "Gemma 4 E2B 8-bit — small but precise"),
            // E4B-it, not E2B-it: its chords fix 65% of noisy lines against 50%,
            // and the installs that ran it as their Instruct primary before
            // 2026-10-14 already hold it.
            correctionModelID: "mlx-community/gemma-4-e4b-it-4bit",
            instructModelID: "mlx-community/gemma-4-e4b-it-4bit"  // ~5 GB — fits the 11–16 GB tier
        ),
        // E4B-4bit dropped 2026-07-17: strictly dominated by E2B-4bit on every
        // axis (EN/RU 21 vs 29, 17-lang macro 10 vs 20, p50 151 vs 127 ms,
        // 5.0 vs 3.5 GB) — the 4-bit quantization cliff hits E4B hardest.
        ModelOption(
            id: "mlx-community/gemma-4-e2b-4bit",
            title: String(localized: "Gemma 4 E2B — for 8–16 GB Macs"),
            correctionModelID: "mlx-community/gemma-4-e2b-it-4bit",
            instructModelID: "mlx-community/gemma-4-e2b-it-4bit"  // ~3.5 GB — the 8 GB tier can't hold more
        ),
        // The former EN/RU default (2026-07-07 → 07-25): base ties E4B-8bit
        // base on the POOLED EN+RU core at a quarter of the RAM and, with
        // Qwen2.5 0.5B, the lowest latency in the catalog (p50 18 ms,
        // 2026-10-15). Split by language that tie is English-only — against
        // E2B-8bit: English 28 vs 26 (p=0.12), Russian 17 vs 25 (p<0.001).
        // Beyond EN/RU coverage collapses (uk/ro/tr/cs 56–62%) and E2B-8bit
        // wins decisively (p<0.001). It lost the default seat in the 07-25
        // revision — as a fixer its instruct build is inert (4% vs Qwen3.5's
        // 33%), its reply drafts mostly restate the screen (35% usable,
        // 2026-10-11), and against Qwen3.5 2B Base it ties on English (p=0.65)
        // and trails on Russian (a trend, p=0.018) — so it stays the MANUAL
        // pick for the lowest completion latency. Runs base-only — its instruct mode ANSWERS
        // the text instead of continuing it (first-word ~0%), so
        // `recommended(for:)` and the fresh-install defaults both pin base
        // style. Our own 8-bit conversion since 2026-10-15: it ties the hub's
        // bf16 (15% of all rows each on the 17-language set, 14 vs 21
        // discordant) at 1.1 GB instead of 2.0 and ~30% less time per
        // suggestion; 6-bit trends down, 4-bit loses (p<0.001). The chords
        // ride Qwen3.5's post-trained build (fix 33% / reply 72%) — MiniCPM5's
        // own RL build fixes 4% and replies 35%, in 2.2 GB
        // (Eval/runs-2026-10-14-small).
        ModelOption(
            id: "nikimori/MiniCPM5-1B-Base-8bit",
            title: String(localized: "MiniCPM5 1B — fastest, English & Russian"),
            correctionModelID: "mlx-community/Qwen3.5-2B-4bit",
            instructModelID: "openbmb/MiniCPM5-1B"  // manual instruct flip only; completion there is broken (see above)
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
            title: String(localized: "Qwen2.5 0.5B — smallest footprint"),
            correctionModelID: "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
            instructModelID: "mlx-community/Qwen2.5-0.5B-Instruct-4bit"
        ),
        // The small-RAM default (the sub-12 GB floor of the memory ladder;
        // 17-language eval-real, 2026-07-16/17): best sub-2 GB model on the
        // full set — beats MiniCPM5, Bonsai and Qwen 0.5B (all p<0.001) with
        // the mildest coverage sag, near-ties MiniCPM5 on EN/RU. Completions run
        // on the Base (pretrained) build since 2026-10-11 — 17.1 vs 16.1% of
        // all rows on the 17-language set (paired p=0.005), better logP/char,
        // and no vision weights; nobody publishes it for MLX, hence our own
        // conversion. 6-bit since 2026-10-14: 19 vs 17% of all against 4-bit
        // (paired p<0.001), tied with 8-bit (1.9 GB) at 1.5 GB — and 8-bit on
        // the tied embedding table alone bought nothing, so the 4-bit cost sits
        // in the body (Eval/runs-2026-10-14-small). The chords stay on the
        // post-trained build (fix 33% / reply 72%), fetched on first ⌥⇥ like
        // the Gemma siblings. Base-only like the other smalls
        // (recommended(for:) pins base so auto never flips to an echoing
        // instruct mode).
        ModelOption(
            id: "nikimori/Qwen3.5-2B-Base-6bit",
            title: String(localized: "Qwen3.5 2B — best small multilingual"),
            correctionModelID: "mlx-community/Qwen3.5-2B-4bit",
            instructModelID: "mlx-community/Qwen3.5-2B-4bit"
        ),
        ModelOption(
            id: "prism-ml/Ternary-Bonsai-4B-mlx-2bit",
            title: String(localized: "Ternary Bonsai 4B — 1 GB base"),  // ternary QAT of Qwen3-4B; ties MiniCPM5, slower, RU-weak
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
    /// p<0.01 bar (MiniCPM5 vs Qwen3.5 2B Base: English p=0.65, Russian
    /// p=0.018, Japanese p=0.19 — direct McNemar over the 2026-10-15 rebook
    /// dumps), while the task eval splits hard AGAINST the
    /// old EN/RU default — MiniCPM5's instruct build fixes 4% of noisy lines
    /// where Qwen3.5 manages 33% and the Gemma siblings 50–69% (its chords
    /// moved to Qwen3.5's sibling on 2026-10-15) — and E2B 4-bit beats
    /// MiniCPM5 on Russian outright (p=0.001; Qwen3.5 Base ties it, p=0.19).
    /// Keyboard languages still drive the persona and the per-language menu
    /// nudge; MiniCPM5 stays the manual pick for the lowest latency.
    static let defaultID: String = defaultID(forRamGB: machineRamGB)

    /// The rule behind `defaultID`, memory injected so tests stay
    /// machine-independent: the best Gemma tier whose RECOMMENDED-config
    /// resident model (what the pick actually keeps loaded: the base build)
    /// stays within about a QUARTER of
    /// physical memory. Quality order on the 17-language catalog run
    /// (2026-10-15): E4B 6-bit ≥ E2B 8-bit > E2B 4-bit — the first step a
    /// tie on completions (p=0.11), carried by E4B's fix sibling (69 vs 65%,
    /// p<0.001), the second p<0.001; E4B 8-bit is never the default — it
    /// ties 6-bit (p=0.28) for more memory, so it stays the manual pick.
    /// Below the smallest Gemma tier the floor is Qwen3.5 2B: ties MiniCPM5
    /// on EN/RU completions, beats every other small multilingually
    /// (p<0.001) — 1.5 GB, plus its 1.6 GB post-trained sibling once the
    /// chords are used (fix 33% / reply 72%, the sibling MiniCPM5 borrows).
    ///
    /// A fixed table, not derived from the size tables: the thresholds are 4×
    /// each tier's resident size as booked on 2026-07-25 (6.8 / 5.0 / 3.5 GB);
    /// the slim re-packs and the Gemma tiers' move to base style (2026-10-14
    /// and -15) only made every tier lighter (5.0 / 3.4 / 2.5), so the quarter rule
    /// still holds. Moving a threshold moves every install that follows the
    /// ladder (`Settings.autoModelID`) onto another model — fetched quietly
    /// while the old one keeps serving, so a re-tier costs a background
    /// download, not a dead engine. Re-tier on purpose (24 GB now fits E4B
    /// 6-bit) and on the evals.
    static func defaultID(forRamGB ram: Double) -> String {
        switch ram {
        case 27.2...: return "mlx-community/gemma-4-e4b-6bit"
        case 20...: return "mlx-community/gemma-4-e2b-8bit"
        case 14...: return "mlx-community/gemma-4-e2b-4bit"
        default: return "nikimori/Qwen3.5-2B-Base-6bit"
        }
    }

    /// The fit rule `defaultID` sizes on, for any resident size: past about a
    /// quarter of physical memory the model crowds out what else the Mac runs.
    static func isHeavy(residentGB: Double, ramGB: Double = machineRamGB) -> Bool {
        residentGB * 4 > ramGB
    }

    /// Why the current `defaultID` was picked — keyed to the resolved default
    /// so the RECOMMENDED tooltip never tells the wrong tier's story.
    static var defaultRationale: String {
        switch defaultID {
        case "mlx-community/gemma-4-e4b-6bit":
            return String(localized: "Auto-picked for this Mac's memory: the best-quality tier that stays within about a quarter of it (~5 GB resident, freed again after idle). Ahead of E2B 4-bit across the evaluated languages (p<0.001), level with E2B 8-bit and E4B 8-bit on completions, and its fix sibling restores 69% of noisy lines exactly — the most in the catalog. Smaller tiers are one click below if you'd rather spend less memory.")
        case "mlx-community/gemma-4-e2b-8bit":
            return String(localized: "Auto-picked for this Mac's memory (~3.4 GB resident, freed again after idle): robust across all 17 evaluated languages and measurably ahead of every small model, with its fix and reply chords riding E4B-it, loaded on first use (65% exact restores, 95% usable reply drafts). E4B is the upgrade if this Mac gains memory; the small models spend less.")
        case "mlx-community/gemma-4-e2b-4bit":
            return String(localized: "Auto-picked for this Mac's memory (~2.5 GB resident, freed again after idle): the lightest Gemma tier — ahead of every small model across 17 languages (p<0.001), measurably better Russian than MiniCPM5 (p=0.001), and its fix sibling, loaded on first use, restores half of noisy lines exactly where the small models manage 11–33%.")
        case "nikimori/Qwen3.5-2B-Base-6bit":
            return String(localized: "Auto-picked for this Mac's memory: the strongest model that fits comfortably — 1.5 GB. It ties the fastest small models on English and Russian completions, beats every other sub-2 GB model on the wider language set (p<0.001), and keeps the fix and reply chords working (33% / 72%) through its post-trained sibling, a one-time 1.6 GB download on first use. A Gemma tier is the accuracy upgrade on a Mac with more memory.")
        default:
            return String(localized: "Auto-picked for this Mac.")
        }
    }

    /// Google's multi-token-prediction drafter for a Gemma 4 instruct model
    /// (~150 MB, bf16): speculative decoding for fix (⌥⇥) and reply, whose
    /// results show only once complete — on the instruct primary or on base
    /// style's -it fix sibling. Drafters exist only for the -it builds.
    /// eval-correct p50: E2B-it 366/301 → 207/186 ms, E4B-it (fix sibling of
    /// E4B-8bit) 2031/1601 → 1395/1286 ms; fixed rate unchanged (51%, 64%).
    static func mtpDrafterID(for primaryID: String) -> String? {
        let id = primaryID.lowercased()
        if id.contains("gemma-4-e2b-it") { return "mlx-community/gemma-4-E2B-it-assistant-bf16" }
        if id.contains("gemma-4-e4b-it") { return "mlx-community/gemma-4-E4B-it-assistant-bf16" }
        return nil
    }

    /// Slimmer re-packs of the Gemma downloads: the towers the engine never
    /// runs are gone (audio everywhere, vision too on the base builds, which
    /// load text-only — the -it builds keep it for the MTP path's VLM load),
    /// and both embedding tables ship at the 4-bit the app used to re-quantize
    /// them to at every load. The same weights the app already ran, 13–39%
    /// less to download (E2B 8-bit 5.9 → 3.6 GB); Eval/runs-2026-10-11 slim-*.
    static let slimRepos: [String: String] = Dictionary(uniqueKeysWithValues: [
        "gemma-4-e4b-8bit", "gemma-4-e4b-6bit", "gemma-4-e2b-8bit", "gemma-4-e2b-4bit",
        "gemma-4-e4b-it-6bit", "gemma-4-e4b-it-4bit", "gemma-4-e2b-it-4bit",
    ].map { ("mlx-community/\($0)", "nikimori/\($0)-slim") })

    /// Entries whose completion build changed under the same pick: the builds
    /// an older install may already hold, newest first, which keep serving
    /// until `ModelStorage.upgradeToSlim` has fetched the new one in the
    /// background — so an update never turns into a forced download (or a
    /// dead engine offline). One still serving as any entry's ⌥⇥ sibling is
    /// never deleted; any other goes once the new build has loaded, like a
    /// slim original.
    static let previousBuilds: [String: [String]] = [
        "nikimori/Qwen3.5-2B-Base-6bit": ["nikimori/Qwen3.5-2B-Base-4bit", "mlx-community/Qwen3.5-2B-4bit"],
        "nikimori/MiniCPM5-1B-Base-8bit": ["openbmb/MiniCPM5-1B-Base"],
    ]

    /// The Hub repo `id`'s weights come from: its slim re-pack (or its new
    /// build), unless only the original is on disk — an install from before
    /// keeps loading that until `ModelStorage.upgradeToSlim` has fetched the
    /// replacement. A replacement that failed to load this launch counts as
    /// absent, so the retry falls back to the build that worked.
    static func repo(
        for id: String,
        isFetched: (String) -> Bool = {
            !ModelStorage.loadFailed(repo: $0)
                && (ModelStorage.cacheDirectory(repo: $0).map(ModelStorage.isFetched(at:)) ?? false)
        }
    ) -> String {
        if let slim = slimRepos[id] { return isFetched(id) && !isFetched(slim) ? id : slim }
        if !isFetched(id), let previous = previousBuilds[id]?.first(where: isFetched) { return previous }
        return id
    }

    /// The commit every Hub download is pinned to — the revision the evals
    /// measured. "main" would hand every fresh install whatever was pushed
    /// last, by anyone holding the publishing account (one personal account
    /// serves the 8 GB default and every slim Gemma tier), unseen by any
    /// review. A new upload ships with the app update that pins it. Already
    /// downloaded revisions keep loading from disk (`ModelStorage.localSnapshot`).
    static let pinnedRevisions: [String: String] = [
        "mlx-community/Qwen2.5-0.5B-Instruct-4bit": "a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3",
        "mlx-community/Qwen2.5-0.5B-bf16": "ef6b6957374b0c7e10ebe6e8497480bbaf71ba4c",
        "mlx-community/Qwen3.5-2B-4bit": "674aaa7240b91e8012fcad5d791b7dfe5ba90207",
        "mlx-community/gemma-4-E2B-it-assistant-bf16": "a7770799b560135ebdbfae8b7f468947415003bc",
        "mlx-community/gemma-4-E4B-it-assistant-bf16": "844e008e06ef5562bdb89428d851d0634d119dcd",
        "mlx-community/gemma-4-e2b-4bit": "a280baf4aece348bd0f561ca43b9d47cc66d8498",
        "mlx-community/gemma-4-e2b-8bit": "23be803ce95a14eed6e1664843b1d56170d3b6f9",
        "mlx-community/gemma-4-e2b-it-4bit": "238767527555cb75a05732a84dff5d6ba0dd6809",
        "mlx-community/gemma-4-e4b-6bit": "c19feba0dd6cc2486fa0d7ae108e34bc55c370af",
        "mlx-community/gemma-4-e4b-8bit": "ddd5748af7babe0706bd334de7e32b9a91ee394b",
        "mlx-community/gemma-4-e4b-it-4bit": "475b9088d29754a3379866cf5aeb6b41acd313c2",
        "mlx-community/gemma-4-e4b-it-6bit": "7b781e6489f260b3a24ff38aebb6313b2db516d7",
        "nikimori/MiniCPM5-1B-Base-8bit": "5ccc5190f40e2a2d23caf12283d949d581f6fb16",
        "nikimori/Qwen3.5-2B-Base-4bit": "9254a84e0f65f6d4cd97e70cd0957bf66d59a663",
        "nikimori/Qwen3.5-2B-Base-6bit": "03abc6421ac277c0a4ea27aa2d594db5143a168b",
        "nikimori/gemma-4-e2b-4bit-slim": "305acaa7d45feb640158ea6344cee719578e989f",
        "nikimori/gemma-4-e2b-8bit-slim": "ab7d6c423cd7bdd54354d0715ac5f2dfe94dd78a",
        "nikimori/gemma-4-e2b-it-4bit-slim": "151cd44c28f88c48f00ac698c28e7acd78352c36",
        "nikimori/gemma-4-e4b-6bit-slim": "f105370ab6b7e767b84c90ce591db59afc1fc9d2",
        "nikimori/gemma-4-e4b-8bit-slim": "4448b728fb952a84b5cde35e20cfb46666c988e4",
        "nikimori/gemma-4-e4b-it-4bit-slim": "4a222e14c9a980d5b47ffb24c77b2896c9bd39de",
        "nikimori/gemma-4-e4b-it-6bit-slim": "9e1179844f08bcc78dcf368d804ae1877194f804",
        "openbmb/MiniCPM5-1B": "87179e5c1f455ef22e6223592d2d61351b525bfc",
        "openbmb/MiniCPM5-1B-Base": "156170697656c48f69915b33a2fb44110242187c",
        "prism-ml/Ternary-Bonsai-4B-mlx-2bit": "e1374ad6bf9b1b56afd743936b8faa33c409a75f",
    ]

    /// What to ask the Hub for: the pinned commit, or "main" for a repo the
    /// catalog doesn't know (a `PRETYPE_*_MODEL` override).
    static func revision(for repo: String) -> String { pinnedRevisions[repo] ?? "main" }

    /// Pseudo-model id for the system Apple Intelligence model (macOS 26+):
    /// zero download, zero app memory, runs on the Neural Engine.
    static let appleIntelligenceID = "system.apple-intelligence"

    static func option(for id: String) -> ModelOption? {
        if id == appleIntelligenceID {
            return ModelOption(
                id: appleIntelligenceID,
                title: String(localized: "Apple Intelligence — system model"),
                correctionModelID: appleIntelligenceID,
                instructModelID: appleIntelligenceID
            )
        }
        return options.first { $0.id == id }
    }

    /// Eval-backed completion settings recommended for a given model, so each
    /// model runs in the configuration it measured best in (see Eval/BASELINE.md).
    struct Recommendation {
        let style: CompletionStyle
        let length: CompletionLength
        /// Logprob-gate τ calibrated PER MODEL: the same mean first-word logprob
        /// means different confidence on different tokenizers/models — split-half
        /// Q4 edges span −0.94 (E4B) … −1.34 (Qwen0.5B) across the catalog, so one
        /// global τ is too strict for small models and too lax for big Gemma.
        /// Taken on the live recorder's scale, the one `MLXEngine` compares
        /// against (runs-2026-10-15-rebook/calib-live.py: τ from the even half,
        /// 24–26% of the odd half's suggestions pass); the offline re-forward τ
        /// before it passed 15–22%. nil = no logprob available (Apple Intelligence).
        let logprobGateTau: Double?
        /// Stricter τ for the scripts where `logprobGateTau` still shows
        /// suggestions that cost more than they save — Net-KSS per prompt at the
        /// journal's λ=1.25, a cell adopted only when 2-fold cross-fitting holds
        /// at p<0.01 and it does not lose with IME-priced CJK chars or λ=0.4
        /// (runs-2026-10-16-gate/script-tau.py). Japanese pays on no model
        /// (first word right 6–18% of shown) → `.infinity`, never suggest —
        /// with the gate off too (`silentScripts(for:)`).
        var scriptGateTau: [GateScript: Double] = [:]
        /// One-line human summary for the settings UI, e.g. "Instruct · Short".
        var summary: String {
            [style.label, length.label].joined(separator: " · ")
        }
    }

    static func recommended(for id: String) -> Recommendation {
        if id == appleIntelligenceID {
            // System model: short is its sweet spot (weak on long / Russian
            // tails); style is moot; no base path for the gate.
            // Japanese: 0 of 229 shown suggestions had the right first word
            // (runs-2026-10-15-rebook fm-real) — never suggest there.
            return Recommendation(style: .instruct, length: .short, logprobGateTau: nil,
                                  scriptGateTau: [.kana: .infinity])
        }
        // MiniCPM5: base continuation only — instruct answers instead of
        // continuing (eval-v2 first-word ~0%), so auto mode must never route
        // style there. Length swept 2026-07-13 (base, eval-v2 + eval-real):
        // first-word is length-independent; longer buys ~1–2 pts completeness
        // but LOSES word-F1 and doubles latency each step (short 157 / medium
        // 291 / long 550 ms p50 on eval-real) — so short wins for inline ghost
        // text. Its gate τ is the calibration run's own.
        if id.contains("MiniCPM5") {
            // Its byte-level scores run high on Arabic/Hebrew: τ −1.21 showed
            // 46–48% of prompts at 7–12% first-word right there.
            return Recommendation(style: .base, length: .short, logprobGateTau: -1.21,
                                  scriptGateTau: [.kana: .infinity, .hangul: -0.48, .arabic: -0.38, .hebrew: -0.77])
        }
        // Small base-continuation picks from the 07-15 sweep (Qwen2.5-0.5B,
        // Qwen3.5-2B, ternary Bonsai-4B): base only — instruct echoes; short
        // (first-word is length-independent here). The logprob gate still
        // works (monotone calibration).
        if id.contains("Qwen2.5-0.5B") {
            return Recommendation(style: .base, length: .short, logprobGateTau: -1.34,
                                  scriptGateTau: [.kana: .infinity, .hangul: -0.65, .arabic: -0.85])
        }
        if id.contains("Ternary-Bonsai") {
            return Recommendation(style: .base, length: .short, logprobGateTau: -1.15,
                                  scriptGateTau: [.han: -0.56, .kana: .infinity, .hangul: -0.42])
        }
        if id.contains("Qwen3.5-2B") {
            return Recommendation(style: .base, length: .short, logprobGateTau: -1.18,
                                  scriptGateTau: [.kana: .infinity, .hangul: -0.57])
        }
        // Gemma E-series: base, short. Instruct + persona wins on text you
        // author (~85% first-word, eval-v2) but loses on real text: E2B since
        // 2026-10-14 (5% vs 21% of all rows, runs-2026-10-14-small), E4B since
        // 2026-10-15 (it-6bit 15% vs 23% of all rows on 17 languages, p=5e-53;
        // en 21 vs 29, ru 16 vs 24 — runs-2026-10-15-rebook).
        if !id.contains("e4b"), id.contains("4bit") {
            return Recommendation(style: .base, length: .short, logprobGateTau: -1.07,
                                  scriptGateTau: [.han: -0.75, .kana: .infinity])
        }
        return Recommendation(style: .base, length: .short, logprobGateTau: id.contains("e4b") ? -0.94 : -0.96,
                              scriptGateTau: [.kana: .infinity])
    }

    /// Scripts `id` never suggests in, gate or no gate: its `scriptGateTau`
    /// entries at `.infinity` — a suggestion there costs more than it saves on
    /// every measured model, so the opt-in gate is not what should stop it.
    /// Empty under a PRETYPE_LOGPROB_GATE pin, so ranking evals still score
    /// those rows.
    static func silentScripts(for id: String) -> Set<GateScript> {
        let pin = ProcessInfo.processInfo.environment["PRETYPE_LOGPROB_GATE"]
        guard pin == nil || pin == "recommended" else { return [] }
        return Set(recommended(for: id).scriptGateTau.filter { $0.value.isInfinite }.keys)
    }

    /// Whether Instruct style continues the text on `id`. Elsewhere the
    /// instruct build answers the text instead (first-word ~0%), so the UI
    /// marks the combination broken and a model switch leaves it. The E4B
    /// tiers' it-6bit sibling completes (20% on the core, 99% offered —
    /// `ModelMetrics.instructCompletion`), just below Base.
    static func instructCompletes(_ id: String) -> Bool {
        id == appleIntelligenceID
            || option(for: id)?.instructModelID == ModelMetrics.instructCompletion.id
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
