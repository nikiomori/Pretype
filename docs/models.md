# Choosing a model

We measure every model in the catalog on the same held-out eval. The Apple Intelligence system model is in the eval too. The eval measures first-word accuracy on real human text. If a model stays silent, the eval counts a miss.

<div align="center">
<img src="chart-models.svg" width="720" alt="Dumbbell chart: on English all nine models score 24-28% first-word accuracy, a tie; averaged over 16 other languages they fan out from 22.6% (Gemma 4 E4B) down to 8.5% (Apple Intelligence)" />
</div>

## Which model to use

For most people, the correct answer is the default. Pretype selects the default from the memory of your Mac. Change it only for the cases in the diagram and the table below.

<div align="center">
<img src="diagram-models-choose.svg" width="720" alt="Decision diagram. Which language do you type? English only: if speed is most important, use MiniCPM5 1B (49 ms, the fastest); if least memory is most important, use Qwen2.5 0.5B (about 1 GB); if the best fix and reply chords are most important, keep the default. Any other language, Russian included: keep the default. The default follows the memory of your Mac: 8 GB gives Qwen3.5 2B (Base), 16 to 18 GB gives Gemma 4 E2B 4-bit, 24 GB gives Gemma 4 E2B 8-bit, 32 GB and up gives Gemma 4 E4B 6-bit." />
</div>

| Situation | Model | Evidence |
|---|---|---|
| You type in English | Any model. For speed, MiniCPM5 1B. | No model is measurably better than another. All nine score between 24% and 28%. That is inside the ±5 pp of a single-language cell. MiniCPM5 1B is the fastest model in the catalog: 49 ms. |
| You type in English and have little free memory | Qwen2.5 0.5B | It runs in ≈1 GB. On English, its accuracy is equal to the other models. |
| You type in another language | The default | Outside English, the tie stops. The Gemma 4 tiers lose 4–8 points. MiniCPM5, Bonsai and Qwen 0.5B lose more than half of their English score. |
| You type in another language on an 8 GB Mac | Qwen3.5 2B (Base), the default | Of the small models, Qwen3.5 2B loses the least. It is the best model below 2 GB. It is better than Bonsai, Qwen 0.5B and the larger MiniCPM5 (all p<0.001). |
| You type in Russian | The default. A Gemma tier from 16 GB. | See [English and Russian are different](#english-and-russian-are-different). |
| You type in Arabic or Hebrew | The default. Do not use MiniCPM5 for Hebrew. | See [Arabic and Hebrew](#arabic-and-hebrew). |
| You want no download and no app memory | Apple Intelligence (macOS 26+) | It is last on accuracy and on speed: 430 ms, against 49–145 ms. It has the largest drop outside English in the chart. It does not support Polish, Romanian or Czech. |
| You want the best quality and have the memory | Gemma 4 E4B 8-bit | It ties E4B 6-bit (p=0.052), and it uses ≈1 GB more. You must select it manually. |

### English and Russian are different

We do not average English and Russian into one figure. Every small model is stronger in English than in Russian.

* MiniCPM5 ties Gemma E2B 8-bit on English: 27% against 26% (p=0.35).
* On Russian, MiniCPM5 loses 6 points: 17% against 23% (p<0.001).
* In the small class, no model is better than MiniCPM5 on Russian. Qwen3.5 2B ties it (p=0.79).
* The lightest Gemma tier, E2B 4-bit, is better than every small model on Russian (direct McNemar p<0.01).

Thus the memory ladder gives Russian typists a Gemma tier when the Mac has sufficient memory. On English, the tiers tie. There, the larger model gives better fix and reply chords, not better completions.

### Arabic and Hebrew

We measured these two languages separately: 560 held-out rows, 2026-07-25. They are the most difficult languages in the catalog.

| Model | Result |
|---|---|
| Every small model | 4–10%. The small models are statistically tied, so no model below 2 GB is better. |
| Gemma E2B 8-bit | 11% Arabic, 18% Hebrew. This is approximately two times the small models. Use a Gemma tier if your Mac has the memory. |
| MiniCPM5 | 1% on Hebrew. Do not use it for Hebrew. |
| Apple Intelligence | It shows a suggestion more frequently than any downloadable model (86% of the time). But only 4–6% of the suggestions are correct. |

Inline typo fixes do not work in these two languages. macOS lists them as spell-check languages, but it has no dictionary for them.

### Qwen3.5 2B uses its Base build

Since 2026-10-11, Qwen3.5 2B completes text with its Base build. This build is our own MLX conversion: [nikimori/Qwen3.5-2B-Base-4bit](https://huggingface.co/nikimori/Qwen3.5-2B-Base-4bit).

* Accuracy: 17.1% of all rows, against 16.1% for the post-trained build (p=0.005).
* Size: 1.1 GB, against 1.6 GB.

## The default follows the memory of your Mac

Since 2026-07-25, Pretype selects the default from the memory of your Mac. Before that date, your keyboard layouts selected it. The default is the strongest tier whose resident model uses about a quarter of physical memory or less.

| Mac memory | Default | Resident (recommended config) |
|---|---|--:|
| 8 GB | Qwen3.5 2B (Base) | ≈1.1 GB |
| 16–18 GB | Gemma E2B 4-bit | ≈3.0 GB |
| 24 GB | Gemma E2B 8-bit | ≈4.6 GB |
| 32 GB and up | Gemma E4B 6-bit | ≈5.6 GB |

The rule does not use language, for two reasons:

1. No per-language gap between the small models is statistically significant. MiniCPM5's English lead over Qwen3.5 is only a trend (p=0.014). Russian is a tie (p=0.79). Japanese is p=0.064.
2. The chord measurements are strongly against the old English/Russian default. MiniCPM5's fix works on only 4% of rows.

Two models stay as manual selections:

* MiniCPM5 1B, for the lowest latency (49 ms).
* Gemma 4 E4B 8-bit, for the best quality. It ties 6-bit (p=0.052) and uses ≈1 GB more.

Your keyboard languages continue to set the persona and the per-language menu suggestion. To change the model, use **Settings → Model**. Each entry has its own recommended settings from the eval. The catalog ranks the models again for each of the 19 evaluated languages.

<div align="center">
<img src="shot-models.png" width="720" alt="Model tab: eval-backed presets and an interactive speed by accuracy map of the catalog" />
<p><sub><i>The app shows the same data: a speed × accuracy map, presets you can apply with one click, and an accuracy axis for each language.</i></sub></p>
</div>

<sub>**Chart method.**
The chart uses an equal-weight mean over `cs de es fr it ja ko nl pl pt ro ru sv tr uk zh`. It uses only matched register cells.
We measured Arabic and Hebrew later, on their own set. They are not in the chart.
Do not compare absolute values *between* languages: zh and ja are character-masked. Thus the mean shows the spread across languages, not the skill in one language.
Each language cell has 280 held-out rows. English has 560 and Russian has 689. This gives ±5 pp near 20%, and ±3 pp at the size of the Russian cell. A smaller gap is not a result.
The app shows the same tolerance and sample size next to each figure. You can also select one language as the axis, in place of the average.</sub>

## Fixing and replying

The two chords are: fix the selection (<kbd>⌥Tab</kbd>) and write a reply from the screen (<kbd>⌥⇧Tab</kbd>). They do not run on the model that you select. They run on its **instruct sibling**. Thus the important numbers are the numbers of the sibling.

We measured the chords on 2026-10-11, each on its own held-out set:

* **Fix:** 510 sentences with one typo each, plus 170 clean controls, in 17 languages. The test used the full app pipeline, with the gates.
* **Reply:** 380 on-screen conversations in 19 languages.

| Runs the chords | Loaded by (recommended settings) | Exact fix | Touches clean text | Fix p50 | Usable replies | Reply p50 |
|---|---|--:|--:|--:|--:|--:|
| Gemma E4B-it 6-bit | Gemma E4B 8-bit and 6-bit | **69%** [65–73] | 18% | 0.26 s | **97%** [94–98] | 0.33 s |
| Gemma E4B-it 4-bit | Gemma E2B 8-bit | 65% [61–69] | 21% | 0.21 s | 95% [92–97] | 0.25 s |
| Gemma E2B-it 4-bit | Gemma E2B 4-bit | 50% [45–54] | 29% | 0.08 s | 96% [93–97] | 0.09 s |
| Qwen3.5 2B (post-trained) | Qwen3.5 2B Base — the 8 GB default | 33% [29–37] | 28% | 0.14 s | 76% [72–80] | 0.15 s |
| Bonsai 4B (itself) | Ternary Bonsai 4B | 19% [16–23] | 12% | 0.21 s | 39% [34–44] | 0.21 s |
| Qwen2.5 0.5B-it | Qwen2.5 0.5B | 11% [9–14] | 19% | 0.03 s | 52% [47–57] | 0.07 s |
| MiniCPM5 1B-it | MiniCPM5 1B | 4% [2–6] | 14% | 0.05 s | 35% [31–40] | 0.21 s |

Read these notes before you use the table as a ranking:

* **The Gemma siblings are the best on both chords.**
  * Fix: the column is a clean ladder. Every adjacent gap is significant at p<0.001. The 6-bit E4B sibling is better than its 4-bit build (p=9×10⁻⁴).
  * Reply: the three Gemma siblings tie at 95–97% (p≥0.45). They are much better than Qwen3.5 (p<10⁻¹⁶).
  * The reply drafts of the small models usually repeat the conversation and do not answer it. The app now discards these drafts. Thus the reply column of the small models is low.
* **"Exact fix" is a strict measure. "Usable reply" is a lenient measure.**
  * A correct fix with different words from the original counts as a miss. Thus real usefulness is higher than the fix column.
  * A usable reply is a draft in the language of the conversation that does not repeat the screen. This does not measure the quality of the reply.
* **"Touches clean text" is the cost of the fix chord.** If you select a line that is already correct, the sibling can still propose a change. This occurs on 12–29% of clean lines across the catalog. The figures include the app's minimal-edit gate. Press <kbd>Esc</kbd> to keep your original text.

<sub>**Method.**</sub>

* <sub>Totals over 510 and 380 rows have a tolerance of ±4–5 pp. Per-language cells have 20–30 rows. We use them only to show direction, never for claims.</sub>
* <sub>Conditions: release build, no persona, warm medians on an M4 Max.</sub>
* <sub>These figures replace the 2026-07-25 measurement. That measurement had three errors. It counted a reply that joined the lines of the conversation again as a new reply. It added draft rows (where the draft already gives the language) to the denominator. It used the developer's own English persona. With these errors, MiniCPM5 was the best replier and every Gemma sibling was at ~33%.</sub>
* <sub>Two product fixes came with the new measurement:</sub>
  * <sub>Gemma 4 now stops at its turn marker. Fix p50 on E4B-it went from 1.5 s to 0.24 s. The 07-25 runs also used a debug build.</sub>
  * <sub>The reply prompt now gives the name of the language of the conversation. Before, it said "its language", and an English persona changed the language. E4B-it with a persona went from 6% to 93% usable.</sub>
* <sub>Fix latency then decreased again. A fix usually types its input again, so the decoder now makes drafts from the selection (prompt lookup). The output is the same. E2B-it went from 109 ms to 78 ms. The small models were 1.2–2.7× faster in same-session pairs. The fix p50 column applies these ratios (`Eval/runs-2026-10-11-lookup`).</sub>
* <sub>Ukrainian is the one weak cell (≈50–70%). A third of the "Ukrainian" dialogues in the set are in Russian. The model correctly answers them in Russian.</sub>
* <sub>Sets: `eval-correct` has one real typo per sentence, in the Tatoeba register. `eval-reply` has conversations in screen format. A reply must use the correct language and must not repeat the screen.</sub>

## What a model costs you

Disk use and memory use increase together.

| Cost | Range |
|---|---|
| Memory of the default model, while you type | ≈1.1–5.6 GB. This is about a quarter of the memory of the Mac (see the ladder above). |
| Smallest model in the catalog | ≈1 GB |
| Largest download | Gemma 4 E4B 8-bit, ≈6 GB |
| Warm completion time, local models | 49–145 ms |
| Apple Intelligence | 430 ms. No download and no app memory. |

### Slim Gemma re-packs

The Gemma tiers download slim re-packs of the mlx-community builds ([nikimori/*-slim](https://huggingface.co/nikimori)). The re-packs have two changes:

1. They do not contain the audio and vision encoders, because the app does not use them. The instruct siblings keep vision, because their speculative-decoding load needs it.
2. Both Gemma embedding tables are 4-bit. These are the shared input/output table and the much larger per-layer table. A table is only a lookup, so this has no speed cost. First-word accuracy does not change (paired p≥0.72 on all three tiers).

The outputs are the same as the originals, row for row. The downloads are 13–39% smaller:

| Model | Original | Re-pack | Measured model memory |
|---|--:|--:|--:|
| Gemma 4 E2B 8-bit | 5.9 GB | 3.6 GB | 3.4 GB |
| Gemma 4 E4B 6-bit | 7.1 GB | 5.3 GB | 5.0 GB |
| Gemma 4 E4B 8-bit | 9.0 GB | 6.3 GB | 6.0 GB |

If your install downloaded an original build before the re-packs, Pretype moves it to the re-pack automatically. It never does this on a cellular, hotspot or Low Data Mode network. After the change, a reload after an idle pause is about two times faster (E4B 6-bit: 0.8–1.9 s → 0.4–0.5 s).

<div align="center">
<img src="diagram-models-slim-upgrade.svg" width="440" alt="Flow diagram. Pretype starts. Is the model in use an original build? No: nothing to do. Yes: is the free disk space more than the original size plus 2 GB? No: try again at the next launch. Yes: is the network unmetered (no cellular, hotspot or Low Data Mode)? No: try again at the next launch. Yes: download the re-pack in the background while the original serves. Did the re-pack load on this Mac? Yes: delete the original. Not yet: try again at the next launch." />
</div>

### Memory is used only while you type

The resident figure is the memory that a model uses *while you type*. The model does not stay in memory all day:

* After five idle minutes, the model unloads. On Macs with 32 GB or more, this time is fifteen minutes.
* The model loads again at your next keystroke.
* If macOS reports memory pressure, the model unloads earlier.

### The fix chord can add a download

On some models, the first <kbd>⌥Tab</kbd> downloads an instruct sibling one time:

| Model | Instruct sibling download |
|---|---|
| MiniCPM5 | ≈2.2 GB |
| Qwen3.5 | ≈1.6 GB (its post-trained build) |
| A Gemma tier in Base style | up to ≈5 GB |
| Bonsai | None. Bonsai corrects with itself. |
| A Gemma tier in its recommended Instruct style | None. The loaded model is already the instruct build. |

## Hosted models (API)

You can use a hosted model in place of the local model. You can also use a local server, such as Ollama. Text and dictation have separate settings. Both are off by default.

1. Open **Settings → API**.
2. Turn on **Use an API model for text**, or **Use an API model for dictation**, or both.
3. Select a provider. Pretype fills in the base URL and a model.
4. Paste your API key. Click **Get a key** if you do not have one.
5. Click **Test connection**. A ✓ and the round-trip time show that the key, the URL and the model are correct.

> **CAUTION:** With API text on, the text that you type goes to the provider at each suggestion. With API dictation on, each recording goes to the provider. See [Privacy → API providers](privacy.md#api-providers).

We checked these presets against the documentation of each provider on 2026-10-12. You can type a different model.

| Provider | Text model | Dictation model | Reasoning setting that Pretype sends |
|---|---|---|---|
| OpenAI | `gpt-6-luna` | `gpt-transcribe` | `reasoning_effort: none` |
| Anthropic | `claude-haiku-5-5` | — | `effort: low` |
| Google Gemini | `gemini-3.5-flash-lite` | — | None. Gemini 3 models always reason, and this model starts at its lowest level. |
| Groq | `llama-3.1-8b-instant` | `whisper-large-v3-turbo` | None. This model does not reason. |
| Mistral | `mistral-small-latest` (Small 4) | `voxtral-mini-latest` | `reasoning_effort: none` |
| OpenRouter | `google/gemma-4-26b-a4b-it` | — | `reasoning.effort: none` |
| DeepSeek | `deepseek-flash` | — | `thinking: disabled` |
| Ollama *(local)* | `gemma4:e4b` | — | `reasoning_effort: none` |
| LM Studio *(local)* | `google/gemma-4-e4b` | — | None |
| Custom | You type it. | You type it. | None |

* **Reasoning.** Most current models reason before they answer, by default. For autocomplete, this adds seconds to each suggestion. Thus Pretype turns it off where the provider permits it.
* **No measured figures.** The eval on this page does not include hosted models. The Live Impact meters do not show figures while API text is on.
* **Latency.** The network adds to each suggestion. **Test connection** shows the round trip from your Mac.
* **Cost.** Each suggestion is one request. The provider charges for each request.
* **Local servers.** Ollama and LM Studio run on your Mac and need no key. The data does not leave the Mac. Pretype can connect to `http://localhost`.

For quantization tiers, the engine split and the confidence gate, see [Architecture](ARCHITECTURE.md).
