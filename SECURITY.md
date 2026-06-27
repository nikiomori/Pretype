# Security & Privacy Policy

## Privacy model

Pretype is a local-first macOS utility. Because it reads text system-wide, its
trust model matters — here is exactly what it does:

- **All inference is on device.** Completions run locally, either via MLX
  (Gemma 4, in-process) or Apple's on-device Foundation Models. Your typed
  text, selections, and any screen context are **never** sent to a server.
- **The only network egress** is the one-time download of model weights from
  Hugging Face on first use (cached in `~/.cache/huggingface`). After that the
  app works fully offline.
- **Password and secure fields are never read.** Secure text fields are
  skipped, and macOS blocks Accessibility access to them regardless.
- **Screen context (OCR) is opt-in and local.** It's off by default, requires a
  separate Screen Recording permission, captures only the focused window, runs
  Vision OCR locally, and is cleared on every focus change. It's disabled
  entirely in terminals and code editors.
- **No telemetry, analytics, or crash reporting.** The usage stats in the menu
  are stored locally and never leave your Mac. You can inspect exactly what the
  model received at any time via **Context → Show Last Prompt…**.

Permissions used: **Accessibility** (reading the focused field, the event tap,
and keystroke injection) and — only when you enable OCR — **Screen Recording**.

## Supported versions

Pretype is pre-1.0 and under active development. Security fixes are applied to
the latest `main`; there are no long-term support branches yet.

## Reporting a vulnerability

Please report security issues **privately** — do not open a public GitHub issue.

Email **nikiomori.x@gmail.com** with:

- a description of the issue and its impact,
- steps to reproduce (or a proof of concept), and
- the version / commit you tested.

You can expect an acknowledgement within a few days. Once a fix is available,
we're happy to credit you in the release notes unless you'd rather stay
anonymous.
