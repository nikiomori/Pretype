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

The out-of-the-box pick is resolved once per launch from the Mac's physical
memory — `ModelCatalog.defaultID(forRamGB:)`: the best Gemma tier, in quality
order E4B 6-bit → E2B 8-bit → E2B 4-bit, whose resident model in its
recommended configuration (the instruct primary) stays within about a quarter
of RAM, with Qwen3.5 2B as the floor below the smallest one. On the memory
sizes Apple ships that is 8 GB → Qwen3.5 2B, 16–18 GB → E2B 4-bit,
24 GB → E2B 8-bit, 32 GB and up → E4B 6-bit ([why](models.md)). The
thresholds are a fixed table (sized on the pre-slim builds, so the quarter
rule holds with room to spare): the default is live, not stored, so moving a
threshold would move every auto-default install of that size onto another
model — a multi-GB download nobody asked for. Keyboard
layouts no longer pick the model; they still drive the persona and the
per-language menu nudge. Everything else is a manual pick in
**Settings → Model**:

| Model | Download | Why you'd pick it |
|---|---|---|
| Gemma 4 E4B 8-bit | ≈6.0 GB | Best measured quality; holds up across all 19 eval languages. Never the default — it ties 6-bit |
| **Gemma 4 E4B 6-bit** | ≈5.0 GB | *Default from 32 GB* — ties E4B 8-bit (p=0.052) for a smaller download |
| **Gemma 4 E2B 8-bit** | ≈3.4 GB | *Default at 24 GB* — ~1 pp behind E4B at roughly twice the speed |
| **Gemma 4 E2B 4-bit** | ≈2.5 GB | *Default at 16–18 GB* — the mildest 4-bit cost in the field |
| MiniCPM5 1B | ≈2.2 GB | Fastest in the catalog at 49 ms; strong on English, weaker elsewhere |
| Ternary Bonsai 4B | ≈1.1 GB | A 4B in about a gigabyte |
| **Qwen3.5 2B (Base)** | ≈1.0 GB | *Default on 8 GB* — best sub-2 GB pick multilingually (p<0.001) |
| Qwen2.5 0.5B | ≈1.0 GB | Smallest footprint in the catalog |

Sizes are the catalog's download figures (`ModelOption.approxSizeMB`); the
Gemma tiers download slim re-packs (`ModelCatalog.slimRepos`). Qwen3.5
completes on its Base build (our own conversion) while ⌥⇥ and the reply draft
run on the post-trained one.

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

Measured figures live in `Sources/Pretype/Engines/ModelMetrics.swift`, with
the eval sets, sample sizes and significance tests noted beside them.
The eval harness and datasets themselves are kept out of the public repo (see
*Quality eval* in [CONTRIBUTING](../CONTRIBUTING.md#quality-eval--please-measure-promptmodel-changes)).

## Latency

* **KV-cache reuse** — each keystroke prefills only the newly typed tokens and
  reuses the existing cache, which is what keeps warm completions inside the
  49–145 ms band the catalog measures (`ModelMetrics.p50Ms`; Apple Intelligence
  is the outlier at 430 ms). Caches that can't rewind — Qwen3.5's recurrent
  layers, a Gemma sliding window the prompt has outgrown — are reused from a
  checkpoint taken a few tokens before the prompt's end. Past the context
  window, the prompt starts at a sentence boundary so its first tokens hold
  still while you type.
* **Stop early** — decoding ends at the confidence trim's cut, and a gated
  suggestion is dropped as soon as its first word fails the gate; a gated
  suggestion still streams once that first word passes.
* **Warm in the background** — the screen, clipboard and retrieved-example
  blocks sit at the head of the prompt, so a refresh of any of them voids the
  cache; the new prompt is prefilled when the refresh lands, not on the next
  keystroke.
* **Lighter 6- and 8-bit Gemma** — the tied embedding table, which is also the
  262k-row output projection read on every token, is re-quantized to 4-bit at
  load: 160–320 MB less memory, same suggestion accuracy on the eval set.
* **Speculative fixes and replies** — whenever a Gemma instruct model runs ⌥⇥
  or the reply draft (the instruct primary, or base style's fix model), it
  decodes with Google's multi-token-prediction drafter (~150 MB, fetched in the
  background on first use): 20–40% faster, same output quality. Streamed
  completions skip it — the speculative start costs more than it saves before
  the first word shows.
* **Debounced and cancellable** — a query starts 60 ms after the last
  keystroke, and fast typing supersedes in-flight work instead of queueing it.
* **Fast reloads** — a downloaded model loads straight from its local snapshot
  (no request to Hugging Face to list the repo), and a parsed tokenizer
  survives the idle unload, so the next keystroke waits for the weights alone.
* **Idle unload** — after `Settings.idleUnloadMinutes` (5 by default, 15 on Macs with 32 GB or more) the engine
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

The per-model thresholds are `Recommendation.logprobGateTau` in
`ModelCatalog.recommended(for:)`; the gates themselves live in
`Engines/CompletionGates.swift`.

## Typo corrections and rewrites

* **Inline typo fix** — the macOS system spell-checker, in whichever language
  `NLLanguageRecognizer` detects from the preceding context.
* **Fix selection (`⌥Tab`)** — the local model rewrites the selection in place.
  Corrections need instruction-following, so on most models running Base style
  (Bonsai corrects with itself) the first `⌥Tab` triggers a one-time download of an instruct sibling of your
  completion model (shown as *preparing…* in the menu bar); a Gemma tier in its
  recommended Instruct style fixes with the model it already has loaded.

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
  version-gated; the opt-in Parakeet engine (`Parakeet.swift`, NVIDIA's model
  via FluidAudio, downloaded once into `~/Library/Application Support/FluidAudio`)
  slots in behind the same protocol for the languages Apple serves only with its
  older model. The models are the system's own, downloaded by macOS per language on
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

## Where things live

All app code is in `Sources/Pretype/`:

* **Startup & menu** — `main.swift` (entry point, `--ax-probe`), `AppDelegate`,
  `StatusMenuController` + `MenuHeaderView` (menu bar and Diagnostics),
  `OnboardingWindow`, `Permissions`, `UpdateChecker` (daily release check).
* **Reading the field** — `FocusTracker` (follows the focused element via
  `AXObserver`), `AXText` (text, caret and font reads), `ScreenContext`
  (opt-in OCR), `AppPolicy` (per-app and per-site rules).
* **Input & output** — `KeyTap` (event tap, accept keys, modifier gestures),
  `TextInjector` (synthetic key events), `SuggestionWindow` (ghost text and
  pills), `CaretIndicator`, `BackgroundProbe` (light/dark under the overlay).
* **Pipeline** — `SuggestionController` is the hub: text → engine → overlay →
  accept → inject, plus dictation inserts. `EngineCoordinator` owns the
  engine's lifecycle; `CorrectionController` runs ⌥⇥, last-word and inline
  spell fixes (`SpellChecker`, `EmojiShortcodes`, `InlineCalculator`).
* **Engines** (`Engines/`) — `CompletionEngine` (protocol), `MLXEngine` +
  `MLXEngine+Generation` (load, KV cache, decode loop), `FoundationModelsEngine`,
  `CompletionGates` / `CorrectionGates` (shared output gates), `ModelCatalog`
  (entries, RAM ladder, recommended settings), `ModelMetrics` (measured
  figures), `ModelStorage` (disk, deletes, slim upgrade), `ConfigProjection`.
* **Personalization** — `SuggestionJournal`, `PersonalNgram`, `TypedLanguage`,
  `Stats`.
* **Dictation** (`Dictation/`) — `DictationController` (state machine) behind
  `DictationHost`, `AudioCapture`, `AudioDevices`, `Transcription` (Apple's
  `SpeechAnalyzer`), `Parakeet` (opt-in).
* **Settings UI** — `Settings` (stored defaults), `SettingsWindowController`,
  `SettingsStore` (the observable bridge to the pipeline), `SettingsView` (tabs), `SettingsUI` (presets, sharing, alerts),
  `ModelTabView` (model map and list), `ImpactRailView` (Live Impact meters).
* **Debugging** — `DebugLog` (ring buffer and Debug Console), `ConsoleMetrics`.
