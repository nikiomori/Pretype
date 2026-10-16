# Security & Privacy Policy

## Privacy model

Pretype is a local-first macOS utility. It reads text in all apps, thus its trust model is important. This section tells exactly what Pretype does.

<div align="center">
<img src="docs/diagram-privacy.svg" width="720" alt="Data-flow diagram. On your Mac: the text field sends the text at the caret to Pretype, and Pretype sends the suggestion back. Pretype exchanges data with the local model (MLX or Apple Intelligence) and writes to a local journal file. With optional dictation, the microphone sends audio, in memory only, to the on-device speech model, which sends the transcript to Pretype. From the internet, only downloads come in: model weights from Hugging Face, the speech model from Apple servers, and the latest version number from the GitHub Releases API. By default, your text is not sent to the internet. A dashed arrow goes to an API provider: text or audio goes there only if you turn it on in Settings → API." />
</div>

### By default, all inference occurs on the device

By default, completions run locally. They use MLX (Gemma 4, Qwen, and the other models of the catalog, in the app process) or Apple's on-device Foundation Models. In this configuration, Pretype **never** sends your typed text, your selections, or the screen context to a server.

The one exception is opt-in. In **Settings → API**, you can turn on a hosted model for text, for dictation, or for both. Each one is off by default. When it is on, Pretype sends the text or the audio to the provider that you selected. The key stays in the login keychain. [docs/privacy.md](docs/privacy.md#api-providers) lists exactly what goes to the provider.

### Network connections

By default, Pretype connects to the network only for these purposes:

* to download models, from Hugging Face and Apple servers,
* to keep the selected model current, in the background (it checks at launch and then one time each hour),
* to check for a new version, one time each day,
* for a request that you start yourself, for example **Download Refrain**.

None of these connections carry your text. An API provider that you turn on is the one exception. [docs/privacy.md → Network requests](docs/privacy.md#network-requests) is the full list. It gives the source of each request and when it occurs.

When the models are on the disk, completions, fixes, and dictation operate fully offline. This is not true while an API provider is on, unless it is a local server such as Ollama.

### Other protections

* **Pretype never reads password fields.** Pretype skips secure text fields. Also, macOS blocks Accessibility access to them.
* **Screen context (OCR) is opt-in and local.** It is off by default, and it needs a separate Screen Recording permission. It captures only the focused window and runs Vision OCR locally. Pretype clears it at each focus change. It is disabled in terminals, password managers, and code editors.
* **Screen Recording also gives a brightness sample.** When the permission is granted, Pretype captures a small strip to the right of the caret when it shows text there. It reduces the capture to 8 × 4 pixels and then to one brightness value, to select dark or light text. It keeps no image.
* **Clipboard context is opt-in.** It is off by default. When it is on, Pretype reads up to 600 characters of copied text into the prompt. It does not read copies that password managers mark as concealed or transient. The journal and the debug log never contain it.
* **No telemetry, no analytics, no crash reports.** The usage statistics in the menu stay on your Mac. To see exactly what the model received, use **Diagnostics → Show Last Prompt…**.

### Permissions

| Permission | Use | When |
|---|---|---|
| **Accessibility** | Reads the focused field, runs the event tap, and injects keystrokes | Always |
| **Screen Recording** | OCR, and the brightness beside the caret | Only if you enable it |
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
