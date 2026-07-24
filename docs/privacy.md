# Privacy & permissions

Pretype needs the **Accessibility** permission — the same grant a keylogger would ask for — to read the focused text field, catch the accept key, and type suggestions back. Nothing you type is ever uploaded.

Don't take that on faith. The entire input path is three files worth reading: [`AXText.swift`](../Sources/Pretype/AXText.swift) reads the field, [`KeyTap.swift`](../Sources/Pretype/KeyTap.swift) watches for the accept key, [`TextInjector.swift`](../Sources/Pretype/TextInjector.swift) types back.

| | |
|---|---|
| **Your text** | Never uploaded. Every completion is computed on-device, by a local MLX model or the Apple Intelligence system model. |
| **Network** | Two things only: model weights from Hugging Face (on first launch, plus a small instruct sibling the first time you use <kbd>⌥Tab</kbd>), and a once-a-day GitHub Releases version check that sends nothing about you. Turn the latter off in **Settings → General**. |
| **Accessibility** *(required)* | How Pretype reads the focused field, catches the accept key, and types text back. There is no way to do this without it. |
| **Screen Recording** *(optional, off)* | Only for on-screen OCR context, and only for the focused window. OCR'd text and clipboard contents are redacted from the debug log — an exported log carries a character count in their place, never the text. |
| **Stored locally** | A journal of suggestions and short snippets of surrounding text in `~/Library/Application Support/Pretype`, capped at 50 MB, used for on-device personalization — plus any text you import yourself via **Settings → Personalization → Import Text…**. Turning the journal off deletes all of it, imported passages included. |
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

# 4. Settings and the Accessibility grant
defaults delete app.pretype.Pretype
tccutil reset Accessibility app.pretype.Pretype
```

Installed with Homebrew? `brew uninstall pretype` replaces step 1; steps 2–4 still apply.

Report a security issue privately per [SECURITY.md](../SECURITY.md).
