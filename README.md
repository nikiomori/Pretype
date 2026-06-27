<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/pretype-logo-dark.png" />
  <img src="docs/pretype-logo.png" alt="Pretype logo" width="120" height="120" />
</picture>

# Pretype

**System-wide AI autocomplete for macOS.**<br/>
Copilot-style suggestions in every text field — completely offline, private, and on-device.

[![Website](https://img.shields.io/badge/website-pretype.app-6E56CF.svg)](https://pretype.app)
[![CI](https://github.com/nikiomori/Pretype/actions/workflows/ci.yml/badge.svg)](https://github.com/nikiomori/Pretype/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey.svg)](#-requirements)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-required-black.svg?logo=apple)](#-requirements)
[![Swift](https://img.shields.io/badge/Swift-F05138.svg?logo=swift&logoColor=white)](Package.swift)

<p>
  <a href="https://pretype.app"><b>Website</b></a> ·
  <a href="#-quick-start"><b>Quick Start</b></a> ·
  <a href="#-why-pretype"><b>Why Pretype</b></a> ·
  <a href="#-features"><b>Features</b></a> ·
  <a href="#-how-it-works"><b>How it Works</b></a> ·
  <a href="#-roadmap"><b>Roadmap</b></a> ·
  <a href="#-requirements"><b>Requirements</b></a>
</p>

<img src="docs/demo.gif" alt="Pretype in action — gray ghost text appears at the caret, Tab accepts it" width="720" style="border-radius: 10px;" />

<sub>*Type anywhere → gray ghost text appears at the caret → press <kbd>Tab</kbd> to accept a word, or <kbd>⇧Tab</kbd> for the rest.*</sub>

</div>

---

> [!NOTE]
> **Pretype runs entirely on your Mac.** It uses Apple Silicon MLX with Gemma 4 or the Apple Intelligence system model. Your keystrokes never leave your machine — no subscriptions, no cloud, no tracking.

---

## ⚡ Why Pretype?

Most autocomplete solutions live inside a single code editor and ship your text to remote servers. Pretype runs globally across macOS and processes everything locally.

| Feature | **Pretype** | Cloud Autocomplete |
| :--- | :---: | :---: |
| 🛡️ **Privacy** | **100% On-Device** (keystrokes never leave your Mac) | Sent to a remote server |
| 🌐 **Scope** | **System-Wide** (works in Mail, Slack, Notes, Safari, etc.) | Usually locked to a single IDE / editor |
| 💸 **Cost** | **Free & Open-Source** (MIT License) | Subscription fees or API token costs |
| ⚡ **Offline** | **Fully Functional** without internet | Requires active internet connection |
| ⚙️ **Setup** | One-click local model download | Account registration + API key setup |

> *Pretype is an open-source reimplementation of the concept behind [Cotypist](https://cotypist.app) (closed-source, freemium). Not affiliated with Cotypist.*

---

## 📸 Screenshots

<div align="center">

### 🔤 Inline Typo Fix
<img src="docs/shot-typo.png" width="720" alt="Inline typo fix: a misspelled word shows its correction in a pill above it" style="border-radius: 10px;" />
<p><sub><i>Misspelled words automatically show corrections in a pill above the caret. Press <kbd>Tab</kbd> to apply, or <kbd>Esc</kbd> to dismiss.</i></sub></p>

<br/>

### 🪄 Fix Selection (`⌥Tab`)
<img src="docs/shot-fix.png" width="720" alt="Fix selection: a typo-ridden line rewritten into clean text in place" style="border-radius: 10px;" />
<p><sub><i>Select any typo-ridden line or phrase and press <kbd>⌥Tab</kbd>. The local LLM rewrites the selection in place while preserving your original tone.</i></sub></p>

<br/>

### 🎨 Presentation Modes
<img src="docs/shot-modes.png" width="720" alt="Two presentation modes — seamless inline ghost text on the line, or a floating panel above it" style="border-radius: 10px;" />
<p><sub><i>Choose between seamless inline ghost text (pixel-accurate even in Electron) or a clean floating capsule panel above the caret.</i></sub></p>

</div>

---

## ✨ Features

*   🌐 **Works Everywhere** — Integrates with any macOS text field: native AppKit/SwiftUI apps, Electron apps (VS Code, Slack, Claude Desktop), and web views.
*   ✨ **Pixel-Perfect Ghost Text** — completion text is baseline-matched and sized dynamically to match your editor's font.
*   ⌨️ **Smart Keystrokes** — Press <kbd>Tab</kbd> to accept the next word, <kbd>⇧Tab</kbd> to accept the rest of the suggestion, or simply type over it to reject.
*   🔤 **Inline Typo Fixes** — Misspelled words show an instant correction pill above the word; press <kbd>Tab</kbd> to apply (uses native system spell-check, supports English & Russian).
*   🪄 **Smart Rewrites (`⌥Tab`)** — Select any text and let the local LLM fix grammar, typos, and phrasing in place while preserving your original tone.
*   🤖 **Local Inference Engines** — Standardized on **Gemma 4** via Apple's MLX framework, or **Apple Intelligence** system models on macOS 26+.
*   ⚡ **Zero-Lag completion** — Reuses Key-Value (KV) cache to deliver completions in **0.05–0.2 seconds**.
*   👀 **Context Aware & OCR** — Intelligently adjusts behavior per app (disabled in terminals). Optional on-screen OCR reads surrounding window context.

---

## 🚦 Quick Start

> [!IMPORTANT]
> Requires **macOS 14+ on Apple Silicon** with **full Xcode** (the MLX engine needs the Metal compiler).

```bash
# Xcode 26+ only: install the Metal toolchain once
xcodebuild -downloadComponent MetalToolchain

# Clone the repository
git clone https://github.com/nikiomori/Pretype.git && cd Pretype

# Build and run the app bundle
./Scripts/make-app.sh        # builds build/Pretype.app
open build/Pretype.app
```

> [!TIP]
> Grant **Accessibility** when prompted. This permission is how Pretype reads active text fields, catches the <kbd>Tab</kbd> key, and types suggestions back. If you grant it after launching, please restart the app.

<details>
<summary><b>🛠️ Dev Loop, Headless Testing & SwiftPM Caveats</b></summary>

For a fast dev loop:
```bash
./Scripts/dev.sh   # swift build + auto-copies the metallib next to the binary
```
*(Requires one prior `./Scripts/make-app.sh` run to produce the initial `metallib`)*.

> [!WARNING]
> **Swift Build Caveat:** Plain `swift build` / `swift run` compiles, but MLX will not work out of the box because SwiftPM cannot compile Metal shaders directly (`Failed to load the default metallib`). The build scripts handle this by compiling shaders through `xcodebuild`. If shaders are missing, Pretype disables the MLX engine gracefully rather than crashing.

When running the raw binary from a terminal, macOS attributes the Accessibility permission to your terminal app. Make sure to grant it to the terminal, or run the `.app` bundle instead.

</details>

---

## 🧩 How It Works

Pretype hooks into macOS accessibility APIs to provide a system-wide overlay:

```mermaid
flowchart LR
    App[Focused App\nAny text field] -->|AX API Text| FocusTracker
    FocusTracker -->|Prompt| MLX[MLX Engine\nGemma 4]
    MLX -->|Suggestion| Window[Suggestion Overlay]
    Window -->|Ghost Text| App
    App -->|Keystrokes| EventTap
    EventTap -->|Tab Caught| Injector[Text Injector]
    Injector -->|Simulated Keys| App
```

1.  **FocusTracker** tracks the focused text element via `AXObserver` and reads the text surrounding the caret on each keystroke.
2.  The **CompletionEngine** (MLX / Gemma 4, debounced and cancellable) evaluates the context and returns a short continuation.
3.  **SuggestionWindow** renders the gray ghost text size- and baseline-matched to the caret.
4.  A **CGEventTap** catches completion keys (<kbd>Tab</kbd> / <kbd>⇧Tab</kbd>). If accepted, the text is typed back into the active application as synthetic key events.

---

## 🔧 Under the Hood

<details>
<summary><b>🤖 Engines & Models</b></summary>

### Inference Engines
Two backends implement the `CompletionEngine` protocol:
*   **In-Process MLX Inference** (Default): Runs Gemma 4 locally using Apple's `mlx-swift-lm` framework. Models are downloaded directly from Hugging Face on first launch.
*   **Apple Intelligence** (macOS 26+): Runs the OS-provided system model on the Neural Engine via Apple's Foundation Models framework. Zero RAM footprint.

### MLX Model Catalog
Variants are automatically selected on startup based on your Mac's installed RAM:
*   **Gemma 4 E4B 8-bit** (≈8.6 GB) — Best quality, default for Macs with ≥32 GB RAM.
*   **Gemma 4 E4B 6-bit** (≈6.8 GB) — Near-best quality, default for 16-32 GB RAM.
*   **Gemma 4 E2B 8-bit** (≈5.7 GB) — Small and precise.
*   **Gemma 4 E4B 4-bit** (≈5 GB) — Compact.
*   **Gemma 4 E2B 4-bit** (≈3.4 GB) — Light footprint, default for Macs under 16 GB RAM.

</details>

<details>
<summary><b>🪄 Typo Corrections & Selection Rewrites</b></summary>

*   **Inline Typo Fix:** Instantly displays the correction in a pill above the misspelled word as you type. Uses the macOS system spell-checker (English + Russian).
*   **Fix Selection (`⌥Tab`):** Highlight any text and press `⌥Tab`. The local LLM rewrites the line in place, preserving tone and punctuation.

</details>

<details>
<summary><b>⚡ Latency & Cache Optimization</b></summary>

*   **KV-Cache Reuse:** Prefills only the newly typed tokens and reuses the existing Key-Value cache.
*   **Performance:** Prefill speed of **400–750 tokens/sec** and decode speed of **~90–105 tokens/sec** on M-series chips, delivering hot completion latency of **0.05–0.2s**.

</details>

<details>
<summary><b>👀 Context & Vision OCR</b></summary>

*   **App Awareness:** Adapts prompt style based on the active application (e.g., short completions in chats, disabled in terminal emulators).
*   **Screen Context:** Runs Apple's local Vision OCR framework on the focused application's window to pull nearby text (like reading the email thread you are replying to). *Requires Screen Recording permission; disabled by default.*

</details>

---

## 🩺 Troubleshooting

If you don't see any autocomplete suggestions, check the **Diagnostics** panel by clicking the menu bar icon.

<details>
<summary><b>Common Issues & Fixes</b></summary>

1.  **`Accessibility: NOT granted ✗`**: If running from a terminal, verify that the terminal has accessibility permissions. If you built the app locally, binary signature changes may confuse macOS permissions. Reset them by running `tccutil reset Accessibility app.pretype.Pretype` and re-grant permissions.
2.  **`Text element: none`**: The active app does not expose its text boxes via the macOS Accessibility API.
3.  **`Last: engine returned no suggestion`**: The model chose to remain silent to avoid suggesting irrelevant text. Keep typing.

</details>

---

## 🗺️ Roadmap

*   [ ] Emoji completion (`:shrug:` → 🤷)
*   [ ] Multi-language support overrides
*   [ ] Per-app compatibility DB and blacklist/whitelist settings
*   [ ] Sparkle auto-updates, notarized Homebrew builds

---

## 💻 Requirements

*   **OS**: macOS 14+ (macOS 26+ for Apple Intelligence system model)
*   **Hardware**: Apple Silicon Mac (M1/M2/M3/M4 or newer)
*   **Software**: Full Xcode installation (Metal toolchain)
*   **Storage**: 3.4–8.6 GB for the local MLX model

---

## 📄 License

Pretype is licensed under the [MIT License](LICENSE).

<div align="center">
<br/>
<sub>Built with Swift, MLX, and Gemma — entirely on-device. ⌨️</sub>
</div>
