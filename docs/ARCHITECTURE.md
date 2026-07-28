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
([why](models.md)); both defaults fit an 8 GB Mac.
Everything else is a manual pick in **Settings → Model**:

| Model | Size | Why you'd pick it |
|---|---|---|
| **MiniCPM5 1B** | ≈2.2 GB | *Default for EN/RU keyboards* — fastest in the catalog at 49 ms |
| **Qwen3.5 2B 4-bit** | ≈1.6 GB | *Default for every other keyboard* — best sub-2 GB pick multilingually (p<0.001) |
| Gemma 4 E4B 8-bit | ≈8.6 GB | Best measured quality; holds up across all 19 eval languages |
| Gemma 4 E4B 6-bit | ≈6.8 GB | Ties E4B 8-bit (p=0.052) at 1.8 GB less |
| Gemma 4 E2B 8-bit | ≈5.7 GB | ~1 pp behind E4B at roughly twice the speed |
| Gemma 4 E2B 4-bit | ≈3.5 GB | The mildest 4-bit cost in the field |
| Ternary Bonsai 4B | ≈1.1 GB | A 4B in about a gigabyte |
| Qwen2.5 0.5B | ≈1.0 GB | Smallest footprint in the catalog |

Quantization is not a free axis, and it isn't uniform across families:
**E4B below 6-bit collapses** — E4B 4-bit was delisted after measuring as a
statistical tie with the floor of the field — while the same step on E2B is the
mildest 4-bit cost measured, level with 8-bit on English (27 vs 26) and on
Russian (22 vs 23) alike, and about two points behind it across 17 languages
(p<0.001). Reduce footprint by stepping down model size rather than bit width.

Figures are quoted per language on purpose. Pooling English and Russian into one
"EN/RU" number hides the split that matters most for the small models: MiniCPM5
ties Gemma E2B 8-bit on English (27 vs 26, p=0.35) and gives up 6 points on
Russian (17 vs 23, p<0.001). Each language cell is 280 rows (English 560,
Russian 689), which is ±5 pp near 20% — the app prints that tolerance next to
every figure, so a two-point gap reads as the tie it usually is.

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

## Dictation

Hold-to-talk, off by default, macOS 26+ (`Sources/Pretype/Dictation/`).

* **The gesture** — `ModifierHold` in `KeyTap.swift`, the complement of the
  reply gesture's `ModifierDoubleTap`: a hold is never a tap and two taps are
  never a hold, which is what lets both live on the same modifier. Pure and
  time-injected, so every rule about what does *not* open the microphone is a
  unit test. The event tap sees only key-down, so a hold gesture is only
  possible on a modifier — that is why it is one.
* **Which microphone** — `AudioDevices`. A Bluetooth headset carries either good
  playback or a two-way call, never both, so opening the AirPods microphone
  drops whatever is playing into hands-free quality for the length of the hold.
  The default setting steps around it: when the default input and the default
  output are the same physical device (macOS publishes a headset as two objects
  whose UIDs share everything before the colon), dictation records from the
  built-in microphone instead and the headset never leaves music mode. Settings
  can pin any input device, or the system default, instead.
* **Audio** — `AudioCapture` opens the chosen input for exactly as long as the
  key is down and resamples each buffer into the format the analyzer asks for.
  It is built on `AVCaptureSession`, not `AVAudioEngine`, and the choice is
  load-bearing: merely instantiating an engine builds an aggregate device
  around the system-default input *and output*, which alone drops a Bluetooth
  headset into hands-free attenuation — music dipped quieter-then-louder
  around every hold. A capture session opens exactly one device, the
  microphone, and has no output side to disturb. The session is built per
  capture and **released** on stop, so nothing stays alive to keep the device
  claimed (or the orange microphone indicator lit) between holds.
  Nothing is buffered, nothing is written to disk. If the device changes
  mid-capture (a headset dying, AirPods taking over the default input), the tap
  restarts on the new device and the session never notices — provided the
  session pinned a format to resample into; one running on the device's raw
  format ends gracefully instead, since a mid-stream format change is exactly
  what the analyzer rejects. With no input left, whatever was already heard is
  finalized and typed instead of discarded.
* **Words** — `Transcription` wraps Apple's `SpeechAnalyzer` behind a
  `TranscriptionSession` protocol, so the controller above it isn't
  version-gated and a bundled Whisper/Parakeet engine for macOS 14–15 could slot
  in later. The models are the system's own, downloaded by macOS per language on
  first use and shared with every other app that asks — zero bytes shipped by us.
  Volatile results drive the live pill at the caret.
* **Two models, picked per language** — `SpeechTranscriber` is the newer and
  better one and covers exactly 30 locales (en, de, es, fr, it, ja, ko, pt, yue,
  zh). Everything else, **Russian included**, is served by
  `DictationTranscriber`: the model behind the system's own dictation key, older
  and punctuation-free. Support is decided by *membership* in
  `supportedLocales`, never by `supportedLocale(equivalentTo:)` — that one
  canonicalizes an identifier ("ru" → "ru_RU") whether or not a model exists,
  which reads as support and then fails at load. Measured on synthesized speech:
  Russian transcribes correctly through the fallback but returns no punctuation
  at all, which is most of what the tidy-up pass restores.
* **Tidy-up** — the transcript goes through `engine.correct`, the same
  minimal-edit pass `⌥Tab` uses, including its divergence guard: a model that
  starts paraphrasing is rejected and the text goes in as heard. On a hard time
  budget, because an idle-unloaded engine starts with a model reload: past a few
  seconds the raw transcript is typed rather than held hostage.
* **The state machine** — `DictationController` talks to the app through the
  `DictationHost` protocol and takes its session, audio capture and environment
  checks as injectable seams, so the whole capture lifecycle (queued holds,
  focus-mismatch drops, device loss, watchdogs) is pinned by unit tests that
  never touch a microphone.
* **Insertion** — `SuggestionController.insertDictated`, which reuses the accept
  path's bookkeeping (cache advance, settle window, `⌘Z` undo) because the
  hazards are identical. Captures serialize: a hold that passes its threshold
  while the previous transcript is still being written down waits for that
  insert to land, instead of invalidating it.
* **Accounting** — dictated characters are booked on their own counter, outside
  the menu's time-saved figure: one spoken sentence would otherwise swamp a
  week of accepted words and silently redefine what that number meant.

## Context

* **App awareness** — prompt style adapts to the active app (short completions
  in chat apps, disabled entirely in terminals and password managers), and all
  reading stops while macOS reports secure input.
* **Screen context** — optional, off by default. Runs Apple's Vision OCR on the
  focused window to pull in nearby text, such as the email thread you're
  replying to. Requires Screen Recording. OCR'd text never enters the debug
  log; exported logs carry a size-only placeholder in its place.
