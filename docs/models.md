# Choosing a model

Every model in the catalog — plus the Apple Intelligence system model — is measured on the same held-out eval: first-word accuracy on real human text, where staying silent counts as a miss.

<div align="center">
<img src="chart-models.svg" width="720" alt="Dumbbell chart: on English all nine models score 24-28% first-word accuracy, a tie; averaged over 16 other languages they fan out from 22.6% (Gemma 4 E4B) down to 8.5% (Apple Intelligence)" />
</div>

* **Typing in English?** No model measurably beats another — all nine land between 24% and 28%, inside the ±5 pp a single-language cell carries. So pick on speed and size: MiniCPM5 1B is the fastest in the catalog at 49 ms.
* **Typing in anything else?** The tie collapses. The Gemma 4 tiers give up 4–8 points; MiniCPM5, Bonsai and Qwen 0.5B give up more than half of what they scored on English. **Qwen3.5 2B** sags least of the small models and is the best sub-2 GB pick — it beats Bonsai, Qwen 0.5B and the larger MiniCPM5 (all p<0.001).
* **Tight on RAM?** Qwen2.5 0.5B runs in ≈1 GB and stays with the pack on English.
* **Tempted by Apple Intelligence?** It's the only option with no download and no app memory (macOS 26+) — but it's last on both axes here: 430 ms against 49–145 ms, and the steepest multilingual drop in the chart. Polish, Romanian and Czech are outside its supported set entirely.

That split is why the default is chosen from your keyboard layouts — **MiniCPM5 1B** for English/Russian typists, **Qwen3.5 2B** for everyone else. Everything else is one click in **Settings → Model**, where each entry ships its own eval-backed recommended settings and the catalog re-ranks for any of the 17 evaluated languages.

<div align="center">
<img src="shot-models.png" width="720" alt="Model tab: an interactive speed by accuracy map of the catalog with eval-backed presets and a ranked list" />
<p><sub><i>The same data live in the app — a speed × accuracy map with one-click presets and a per-language accuracy axis.</i></sub></p>
</div>

<sub>Chart method: equal-weight mean over `cs de es fr it ja ko nl pl pt ro ru sv tr uk zh`, matched register cells only. Absolute values are not comparable *between* languages (zh/ja are character-masked), so the mean measures spread across languages, not skill at any one of them. Single-language cells carry ±5 pp and are not claims on their own.</sub>

## What a model costs you

Disk and memory track each other: the defaults hold **≈1.6–2.2 GB** resident, the catalog goes down to ≈1 GB, and Gemma 4 E4B 8-bit sits at ≈8.6 GB. Warm completions run **49–145 ms** across the local models, against 430 ms for Apple Intelligence, which downloads nothing and holds no app memory at all.

That resident figure is what a model holds *while you type*, not all day: it unloads itself after five idle minutes and reloads on your next keystroke, and unloads early if macOS reports memory pressure. Using <kbd>⌥Tab</kbd> rewrites can add a one-time instruct sibling on some models — ≈2.2 GB on the EN/RU default, up to ≈5 GB on Gemma, none on Qwen3.5 or Bonsai, which correct with themselves.

Quantization tiers, the engine split and the confidence gate are in [Architecture](ARCHITECTURE.md). Training a model on your own writing is in [Fine-tuning](finetuning.md).
