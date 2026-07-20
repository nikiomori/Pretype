# Architecture

How Pretype is put together, for people reading the code. The user-facing
summary is in the [README](../README.md#how-it-works).

## Inference engines

Two backends implement the `CompletionEngine` protocol
(`Sources/Pretype/Engines/CompletionEngine.swift`):

* **In-process MLX** *(default)* — runs the selected model locally through
  Apple's `mlx-swift-lm`. Weights are downloaded from Hugging Face on first
  launch and cached under `~/.cache/huggingface`.
* **Apple Intelligence** *(macOS 26+)* — runs the OS-provided system model on
  the Neural Engine via the `FoundationModels` framework. No download, no app
  memory. It exposes no logprobs, so the confidence gate below can't run on it.

`FoundationModelsEngine.swift` is the compact reference implementation if you
want to add a third.

## Model catalog

The out-of-the-box pick is resolved once from your enabled keyboard layouts
([why](../README.md#choosing-a-model)); both defaults fit an 8 GB Mac.
Everything else is a manual pick in **Settings → Model**:

| Model | Size | Why you'd pick it |
|---|---|---|
| **MiniCPM5 1B** | ≈2.2 GB | *Default for EN/RU keyboards* — fastest in the catalog at 49 ms |
| **Qwen3.5 2B 4-bit** | ≈1.6 GB | *Default for every other keyboard* — best sub-2 GB pick multilingually (p<0.001) |
| Gemma 4 E4B 8-bit | ≈8.6 GB | Best measured quality; holds up across all 17 eval languages |
| Gemma 4 E4B 6-bit | ≈6.8 GB | Ties E4B 8-bit (p=0.052) at 1.8 GB less |
| Gemma 4 E2B 8-bit | ≈5.7 GB | ~1 pp behind E4B at roughly twice the speed |
| Gemma 4 E2B 4-bit | ≈3.5 GB | The mildest 4-bit cost in the field |
| Ternary Bonsai 4B | ≈1.1 GB | A 4B in about a gigabyte |
| Qwen2.5 0.5B | ≈1.0 GB | Smallest footprint in the catalog |

Quantization is not a free axis, and it isn't uniform across families:
**E4B below 6-bit collapses** — E4B 4-bit was delisted after measuring as a
statistical tie with the floor of the field — while the same step on E2B is the
mildest 4-bit cost measured, identical to 8-bit on EN/RU and about two points
behind it across 17 languages (p<0.001). Reduce footprint by stepping down
model size rather than bit width.

On the Gemma builds the **Instruct** completion style swaps in an instruct
sibling sized to that entry's RAM class, so no pick ever loads weights your Mac
can't comfortably hold.

Measured figures live in `Sources/Pretype/Engines/ModelMetrics.swift`; the
protocol, datasets and significance tests behind them are in `Eval/BASELINE.md`.

## Latency

* **KV-cache reuse** — each keystroke prefills only the newly typed tokens and
  reuses the existing cache, which is what keeps warm completions inside the
  49–145 ms band the catalog measures (`ModelMetrics.p50Ms`; Apple Intelligence
  is the outlier at 430 ms).
* **Debounced and cancellable** — fast typing supersedes in-flight work instead
  of queueing it.
* **Idle unload** — after `Settings.idleUnloadMinutes` (5 by default) the engine
  releases the weights and gives the RAM back, reloading on the next keystroke.
  Memory pressure from macOS unloads it early.

## Knowing when to stay quiet

On real held-out text, an ungated autocomplete measures *net-negative*: the cost
of reading wrong suggestions exceeds the keystrokes saved. So Pretype ships an
**opt-in confidence gate** (**Settings → Suggestions**, off by default, base
style only): the first word's log-probability decides whether a suggestion is
shown at all, against a threshold calibrated per model — chosen on one half of
the eval set and verified on the untouched half. Suggestions repaired by token
healing (mid-word completions) bypass it, since a fragment match is already a
sufficient filter.

What runs by default is confidence *trim*, which cuts the low-confidence tail
off a suggestion rather than abstaining from it entirely.

Details and the measured swing are in `Eval/BASELINE.md`.

## Typo corrections and rewrites

* **Inline typo fix** — the macOS system spell-checker, in whichever language
  `NLLanguageRecognizer` detects from the preceding context.
* **Fix selection (`⌥Tab`)** — the local model rewrites the selection in place.
  Corrections need instruction-following, so the first `⌥Tab` triggers a
  one-time download of a small instruct sibling of your completion model (shown
  as *preparing…* in the menu bar).

## Context

* **App awareness** — prompt style adapts to the active app (short completions
  in chat apps, disabled entirely in terminals and password managers), and all
  reading stops while macOS reports secure input.
* **Screen context** — optional, off by default. Runs Apple's Vision OCR on the
  focused window to pull in nearby text, such as the email thread you're
  replying to. Requires Screen Recording. OCR'd text never enters the debug
  log; exported logs carry a size-only placeholder in its place.
