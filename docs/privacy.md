# Privacy & permissions

Pretype needs the **Accessibility** permission — the same grant a keylogger would ask for — to read the focused text field, catch the accept key, and type suggestions back. Nothing you type is ever uploaded.

Don't take that on faith. The entire input path is three files worth reading: [`AXText.swift`](../Sources/Pretype/AXText.swift) reads the field, [`KeyTap.swift`](../Sources/Pretype/KeyTap.swift) watches for the accept key, [`TextInjector.swift`](../Sources/Pretype/TextInjector.swift) types back.

| | |
|---|---|
| **Your text** | Never uploaded. Every completion is computed on-device, by a local MLX model or the Apple Intelligence system model. |
| **Network** | Three things only: model weights from Hugging Face (on first launch; once, in the background, the smaller re-pack of a Gemma model downloaded before 2026-10-11 — skipped on cellular, hotspot and Low Data Mode networks; plus — on models that need it — an instruct sibling the first time you use <kbd>⌥Tab</kbd> **or dictate with “Tidy up” on**, since both run the same fix pass); a once-a-day GitHub Releases version check that sends nothing about you — turn it off in **Settings → General**; and Apple's on-device speech model for the language you dictate in, fetched from Apple's servers when you turn dictation on or pick a new language — the same system download the built-in keyboard dictation uses. If you opt into Parakeet dictation (Settings → General → Dictation), its ~470 MB CoreML model is fetched once from Hugging Face (`FluidInference/parakeet-tdt-0.6b-v3-coreml`) into `~/Library/Application Support/FluidAudio`. A dictation never waits for the instruct sibling: it types what was heard and fetches in the background, and the tidy-up starts once the download has finished. Sharing a per-app style with the community opens GitHub in your browser with that one style filled in; nothing is sent unless you submit it there. |
| **Accessibility** *(required)* | How Pretype reads the focused field, catches the accept key, and types text back. There is no way to do this without it. In a web page it also reads the page's host name (`mail.google.com`, never the full address) when the focus changes, so per-website settings can apply; it is held in memory only — never logged, journaled or sent — and only a website you add or switch off yourself is remembered, in Settings, like an app. On macOS 27 this permission is listed as **Device Control and Data Access**. |
| **Screen Recording** *(optional, off)* | Only for on-screen OCR context, and only for the focused window. OCR'd text and clipboard contents are redacted from the debug log — an exported log carries a character count in their place, never the text. |
| **Microphone** *(optional, off)* | Only for hold-to-talk dictation, and only while the key is physically held down — releasing it, pressing any other key, or switching apps stops the capture on the spot. Audio is never written to disk and never sent anywhere: it is resampled in memory, handed to the system's own on-device speech models (or, opted in, to Parakeet running on this Mac), and dropped. Names and terms already typed in the field are handed to the same on-device recognizer as spelling hints for that one capture. The dictation flow itself never journals the transcript, and it is redacted from the debug log exactly as OCR'd and clipboard text are — an exported log carries a character count in its place. If a transcript can't be typed (focus moved to a password field or to Pretype's own window), it is put on the clipboard instead of being lost — this Mac's only (no Universal Clipboard), marked transient so clipboard managers leave it out of their history. (Once typed, it is ordinary text in the field: a later suggestion may see it as surrounding context, the same as anything you type by hand.) |
| **Stored locally** | A journal in `~/Library/Application Support/Pretype`, used for on-device personalization: every suggestion you were shown and how it ended, each with the text around the caret at that moment — up to 1,000 characters before it and 192 after — as plain text, capped at 50 MB (years of typing), plus any text you import yourself via **Settings → Personalization → Import Text…**. It is on by default; turning it off (**Settings → Personalization**) deletes all of it, imported passages included. OCR'd screen text is never journaled, and dictation writes no journal entries of its own (dictated text already in the field is ordinary surrounding text, as the Microphone row says). |
| **Never runs** | In terminals and password managers, while macOS reports secure input, and while an input method is mid-composition (Pinyin, kana, Telex, Hangul). Add your own apps to the blacklist in **Settings → General**, or silence the app you're in straight from the menu bar. |

## Uninstall

Pretype keeps everything in four places — remove them all and no trace remains:

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
#    Face cache. Skip this step if any other MLX tool (LM Studio, mlx_lm, …)
#    uses it.
rm -rf ~/.cache/huggingface/hub/models--openbmb--* \
       ~/.cache/huggingface/hub/models--mlx-community--* \
       ~/.cache/huggingface/hub/models--prism-ml--*

# 3. Local personalization data (suggestion journal, learned n-grams)
rm -rf ~/Library/Application\ Support/Pretype

# 4. Settings and the permission grants (drop the last two if you never
#    turned on screen context or dictation)
defaults delete app.pretype.Pretype
tccutil reset Accessibility app.pretype.Pretype
tccutil reset ScreenCapture app.pretype.Pretype
tccutil reset Microphone app.pretype.Pretype
```

Installed with Homebrew? `brew uninstall pretype` replaces step 1; steps 2–4 still apply.

Report a security issue privately per [SECURITY.md](../SECURITY.md).
