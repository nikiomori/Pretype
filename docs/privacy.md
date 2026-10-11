# Privacy & permissions

Pretype needs the **Accessibility** permission — the same grant a keylogger would ask for — to read the focused text field, catch the accept key, and type suggestions back. Nothing you type is ever uploaded.

Don't take that on faith. The entire input path is three files worth reading: [`AXText.swift`](../Sources/Pretype/AXText.swift) reads the field, [`KeyTap.swift`](../Sources/Pretype/KeyTap.swift) watches for the accept key, [`TextInjector.swift`](../Sources/Pretype/TextInjector.swift) types back.

| | |
|---|---|
| **Your text** | Never uploaded. Every completion is computed on-device, by a local MLX model or the Apple Intelligence system model. |
| **Network** | Downloads and one version check — none of them carry your text: model weights from Hugging Face (on first launch; once, in the background, the current build of a model an install downloaded before 2026-10-11 — the smaller Gemma re-pack, or Qwen3.5's Base build — skipped on cellular, hotspot and Low Data Mode networks, the old build serving until the replacement is in place; plus — on models that need it — an instruct sibling the first time you use <kbd>⌥Tab</kbd> **or dictate with “Tidy up” on**, since both run the same fix pass — and, on the Gemma tiers, a ~150 MB speculative-decoding drafter that speeds those two up, fetched in the background when it's missing, tried once per launch); a once-a-day GitHub Releases version check that sends nothing about you — turn it off in **Settings → General**; and Apple's on-device speech model for the language you dictate in, fetched from Apple's servers when you turn dictation on or pick a new language — the same system download the built-in keyboard dictation uses. If you opt into Parakeet dictation (Settings → General → Dictation), its ~610 MB CoreML model is fetched once from Hugging Face (`FluidInference/parakeet-ultra-coreml`; an install that opted in before it swaps its earlier `parakeet-tdt-0.6b-v3-coreml` for it once, in the background, on an unmetered network) into `~/Library/Application Support/FluidAudio`. A dictation never waits for the instruct sibling: it types what was heard and fetches in the background — on an unmetered network only; on a metered one the first <kbd>⌥Tab</kbd> fetches it — and the tidy-up starts once the download has finished. Sharing a per-app style with the community opens GitHub's new-file page in your browser, prefilled with that one style — the style text travels in that page's URL, so GitHub and your browser history see it as soon as the page opens; nothing is posted until you submit it there. |
| **Accessibility** *(required)* | How Pretype reads the focused field, catches the accept key, and types text back. There is no way to do this without it. In a web page it also reads the page's host name (`mail.google.com`, never the full address) when the focus changes, so per-website settings can apply; it is held in memory only — never logged, journaled or sent — and only a website you add or switch off yourself is remembered, in Settings, like an app. On macOS 27 this permission is listed as **Device Control and Data Access**. |
| **Screen Recording** *(optional, off)* | Only for on-screen OCR context, and only for the focused window. OCR'd text and clipboard contents are redacted from the debug log — an exported log carries a character count in their place, never the text. |
| **Microphone** *(optional, off)* | Only for dictation, and only while a capture runs: while the key is physically held down — releasing it, pressing any other key, or switching apps stops the capture on the spot — or, with the hands-free chord, between its two presses, ending by itself after a few seconds of silence. Audio is never written to disk and never sent anywhere: it is resampled in memory, handed to the system's own on-device speech models (or, opted in, to Parakeet running on this Mac), and dropped. Names and terms already typed in the field are handed to the same on-device recognizer as spelling hints for that one capture. The dictation flow itself never journals the transcript, and it is redacted from the debug log exactly as OCR'd and clipboard text are — an exported log carries a character count in its place. If a transcript can't be typed (focus moved to a password field or to Pretype's own window), it is put on the clipboard instead of being lost — this Mac's only (no Universal Clipboard), marked transient so clipboard managers leave it out of their history. (Once typed, it is ordinary text in the field: a later suggestion may see it as surrounding context, the same as anything you type by hand.) |
| **Stored locally** | A journal in `~/Library/Application Support/Pretype`, used for on-device personalization: every suggestion you were shown and how it ended, each with the text around the caret at that moment — up to 1,000 characters before it and 192 after — as plain text, capped at 50 MB (years of typing), plus any text you import yourself via **Settings → Personalization → Import Text…**. It is on by default; turning it off (**Settings → Personalization**) deletes all of it, imported passages included. OCR'd screen text is never journaled, and dictation writes no journal entries of its own (dictated text already in the field is ordinary surrounding text, as the Microphone row says). |
| **Terminals** | Completions only inside an AI agent's prompt box (Claude Code) — in Terminal, iTerm2 and the terminal panel of VS Code-based editors. To find that box Pretype reads the terminal's text near the cursor; only what you typed into the box reaches the model, and the rest — the shell, command output — is dropped in memory, never journaled or logged. In Terminal and iTerm2 the fix and reply chords, dictation and screen OCR stay off. |
| **Never runs** | In password managers, in a terminal's shell command line, while macOS reports secure input, and while an input method is mid-composition (Pinyin, kana, Telex, Hangul). Add your own apps to the blacklist in **Settings → General**, or silence the app you're in straight from the menu bar. |

## Uninstall

Pretype keeps everything in the places below — remove them all and nothing Pretype wrote remains (the speech models dictation uses belong to macOS, shared with its own dictation, and stay):

```bash
# 1. The app. If you turned on "Open at login", switch it off FIRST (Settings →
#    General, or System Settings → General → Login Items) — that registration
#    lives in macOS, not in the app, and deleting the bundle leaves it behind.
rm -rf /Applications/Pretype.app

# 2. Downloaded models (several GB). Settings → Model lists each one with its
#    size and a Delete button, which only ever touches Pretype's own catalog —
#    but it never offers the model you're currently using, so for a FULL wipe
#    when uninstalling, use the globs. They are the blunt version: they match
#    the WHOLE mlx-community / openbmb / prism-ml orgs in the shared Hugging
#    Face cache. Skip those three if any other MLX tool (LM Studio, mlx_lm, …)
#    uses it; nikimori holds only Pretype's own re-packs (Qwen3.5 2B Base, the
#    default on 8 GB Macs, and the slim Gemma tiers).
rm -rf ~/.cache/huggingface/hub/models--nikimori--* \
       ~/.cache/huggingface/hub/models--openbmb--* \
       ~/.cache/huggingface/hub/models--mlx-community--* \
       ~/.cache/huggingface/hub/models--prism-ml--*

# 3. The Parakeet dictation model (~610 MB), only if you opted into it. The
#    folder belongs to the FluidAudio library — skip this if another app on
#    your Mac uses it too.
rm -rf ~/Library/Application\ Support/FluidAudio

# 4. Local personalization data (suggestion journal, learned n-grams)
rm -rf ~/Library/Application\ Support/Pretype

# 5. Settings and the permission grants (drop the last two if you never
#    turned on screen context or dictation)
defaults delete app.pretype.Pretype
tccutil reset Accessibility app.pretype.Pretype
tccutil reset ScreenCapture app.pretype.Pretype
tccutil reset Microphone app.pretype.Pretype
```

Installed with Homebrew? `brew uninstall pretype` replaces step 1; steps 2–5 still apply.

Report a security issue privately per [SECURITY.md](../SECURITY.md).
