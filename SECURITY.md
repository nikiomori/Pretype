# Security & Privacy Policy

## Privacy model

Pretype is a local-first macOS utility. It reads text in all apps, thus its trust model is important. This section tells exactly what Pretype does.

<div align="center">
<img src="docs/diagram-privacy.svg" width="720" alt="Data-flow diagram. On your Mac: the text field sends the text at the caret to Pretype, and Pretype sends the suggestion back. Pretype exchanges data with the local model (MLX or Apple Intelligence) and writes to a local journal file. With optional dictation, the microphone sends audio, in memory only, to the on-device speech model, which sends the transcript to Pretype. From the internet, only downloads come in: model weights from Hugging Face, the speech model from Apple servers, and the latest version number from the GitHub Releases API. Your text is never sent to the internet." />
</div>

### All inference occurs on the device

Completions run locally. They use MLX (Gemma 4, Qwen, and the other models of the catalog, in the app process) or Apple's on-device Foundation Models. Pretype **never** sends your typed text, your selections, or the screen context to a server.

### Network connections

Pretype connects to the network only for downloads and for one version check. None of these connections carry your text. [docs/privacy.md](docs/privacy.md) gives the full list.

| Source | What Pretype gets | When | Opt-out |
|---|---|---|---|
| Hugging Face | Model weights, cached in `~/.cache/huggingface` | At the first use of a model | — |
| Hugging Face | An instruct sibling, on the models that need it | At the first ⌥Tab, or at the first dictation with tidy-up on | — |
| Hugging Face | A ~150 MB speculative-decoding drafter, on the Gemma tiers | In the background, when it is missing. Pretype tries one time for each launch. | — |
| Hugging Face | The current build of a model that an older install downloaded: the slimmer Gemma re-packs, or the Base build of Qwen3.5 | One time, in the background, only on an unmetered network (not cellular, hotspot, or Low Data Mode). The old build operates until the new build is in place. | — |
| GitHub Releases API | The latest version number. Pretype sends no data about you. | One time each day | Disable it in **Settings → General** |
| Apple servers (macOS downloads it) | The on-device speech model for your dictation language | When you enable dictation or change the dictation language | Keep dictation off |
| Hugging Face | The Parakeet model, ~610 MB (`FluidInference/parakeet-ultra-coreml`). An install that opted in before this model replaces its `parakeet-tdt-0.6b-v3-coreml` one time, in the background, on an unmetered network. | Only if you opt in to Parakeet dictation | Opt-in only |

When the models are on the disk, completions, fixes, and dictation operate fully offline.

### Other protections

* **Pretype never reads password fields.** Pretype skips secure text fields. Also, macOS blocks Accessibility access to them.
* **Screen context (OCR) is opt-in and local.** It is off by default, and it needs a separate Screen Recording permission. It captures only the focused window and runs Vision OCR locally. Pretype clears it at each focus change. It is disabled in terminals, password managers, and code editors.
* **No telemetry, no analytics, no crash reports.** The usage statistics in the menu stay on your Mac. To see exactly what the model received, use **Diagnostics → Show Last Prompt…**.

### Permissions

| Permission | Use | When |
|---|---|---|
| **Accessibility** | Reads the focused field, runs the event tap, and injects keystrokes | Always |
| **Screen Recording** | OCR | Only if you enable it |
| **Microphone** | Dictation | Only if you enable it, and only while a capture runs |

## Supported versions

Pretype supports only the latest release. Security fixes go to `main`, and they ship in the next release. There are no long-term support branches.

## Reporting a vulnerability

Report security issues **privately**. Do not open a public GitHub issue.

Send an email to **nikiomori.x@gmail.com**. Include:

* a description of the issue and its effect,
* the steps to reproduce it, or a proof of concept,
* the version or the commit that you tested.

We send an acknowledgement in a few days. When a fix is available, we can name you in the release notes. If you do not want your name in the notes, tell us.
