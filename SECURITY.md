# Security & Privacy Policy

## Privacy model

Pretype is a local-first macOS utility. Because it reads text system-wide, its
trust model matters — here is exactly what it does:

- **All inference is on device.** Completions run locally, either via MLX
  (Gemma 4, Qwen and the rest of the catalog, in-process) or Apple's on-device
  Foundation Models. Your typed text, selections, and any screen context are
  **never** sent to a server.
- **Network traffic is limited to downloads and one version check** — none of
  it carries your text (full list in [docs/privacy.md](docs/privacy.md)):
  - model weights from Hugging Face on first use, cached in
    `~/.cache/huggingface` — plus, on models that need it, an instruct sibling
    the first time you use ⌥Tab (or dictate with tidy-up on), and on the Gemma
    tiers a ~150 MB speculative-decoding drafter, fetched in the background
    when it's missing (tried once per launch);
  - once, in the background, the current build of a model an older install
    downloaded (the slimmer Gemma re-packs, Qwen3.5's Base build) — only on an
    unmetered network (never cellular, hotspot or Low Data Mode), with the old
    build serving until the replacement is in place;
  - a once-a-day version check against the GitHub Releases API that sends
    nothing about you (off in **Settings → General**);
  - Apple's on-device speech model for your dictation language, downloaded by
    macOS itself when you turn dictation on or switch dictation language;
  - only if you opt into Parakeet dictation, its ~610 MB model from Hugging
    Face (`FluidInference/parakeet-ultra-coreml`; installs that opted in
    before it replace their `parakeet-tdt-0.6b-v3-coreml` once, in the
    background, on an unmetered network).

  Once the models are on disk, completions, fixes and dictation work fully
  offline.
- **Password and secure fields are never read.** Secure text fields are
  skipped, and macOS blocks Accessibility access to them regardless.
- **Screen context (OCR) is opt-in and local.** It's off by default, requires a
  separate Screen Recording permission, captures only the focused window, runs
  Vision OCR locally, and is cleared on every focus change. It's disabled
  entirely in terminals, password managers and code editors.
- **No telemetry, analytics, or crash reporting.** The usage stats in the menu
  are stored locally and never leave your Mac. You can inspect exactly what the
  model received at any time via **Diagnostics → Show Last Prompt…**.

Permissions used: **Accessibility** (reading the focused field, the event tap,
and keystroke injection), and — only when you enable them — **Screen
Recording** (OCR) and **Microphone** (dictation, only while a capture runs).

## Supported versions

Only the latest release is supported. Security fixes land on `main` and ship
in the next release; there are no long-term support branches.

## Reporting a vulnerability

Please report security issues **privately** — do not open a public GitHub issue.

Email **nikiomori.x@gmail.com** with:

- a description of the issue and its impact,
- steps to reproduce (or a proof of concept), and
- the version / commit you tested.

You can expect an acknowledgement within a few days. Once a fix is available,
we're happy to credit you in the release notes unless you'd rather stay
anonymous.
