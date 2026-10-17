# Privacy & permissions

Pretype needs the **Accessibility** permission. A keylogger asks for the same permission. Pretype uses it to read the focused text field, catch the accept key, and type suggestions back. Pretype does not upload the text that you type, unless you turn on an API provider. See [API providers](#api-providers).

<div align="center">
<img src="diagram-privacy.svg" width="720" alt="Data-flow diagram. On your Mac: the text field sends the text at the caret to Pretype, and Pretype sends the suggestion back. Pretype exchanges data with the local model (MLX or Apple Intelligence) and writes to a local journal file. With optional dictation, the microphone sends audio, in memory only, to the on-device speech model, which sends the transcript to Pretype. From the internet, only downloads come in: model weights from Hugging Face, the speech model from Apple servers, and the latest version number from the GitHub Releases API. By default, your text is not sent to the internet. A dashed arrow goes to an API provider: text or audio goes there only if you turn it on in Settings → API." />
</div>

## Read the code yourself

Do not trust this page without proof. These files read your input or type text back:

| File | What it does |
|---|---|
| [`AXText.swift`](../Sources/Pretype/AXText.swift) | Reads the text field. |
| [`KeyTap.swift`](../Sources/Pretype/KeyTap.swift) | Watches for the accept key. |
| [`TextInjector.swift`](../Sources/Pretype/TextInjector.swift) | Types the text back. |
| [`ScreenContext.swift`](../Sources/Pretype/ScreenContext.swift) | Optional. Reads the focused window with OCR. |
| [`BackgroundProbe.swift`](../Sources/Pretype/BackgroundProbe.swift) | Only with Screen Recording. Measures the brightness beside the caret. |
| [`SuggestionController.swift`](../Sources/Pretype/SuggestionController.swift) (`currentClipboardContext`) | Optional. Reads the clipboard. |
| [`AudioCapture.swift`](../Sources/Pretype/Dictation/AudioCapture.swift) | Optional. Records the microphone for dictation. |

## What Pretype does with your data

| | |
|---|---|
| **Your text** | By default, Pretype does not upload it. A local MLX model or the Apple Intelligence system model computes every completion on the Mac. If you turn on an API provider for text, your text goes to that provider. See [API providers](#api-providers). |
| **Network** | By default, only downloads and one version check. No request contains your text. See [Network requests](#network-requests). |
| **Accessibility** *(required)* | Pretype uses it to read the focused field, catch the accept key, and type text back. Pretype cannot do this without it. On macOS 27, this permission has the name **Device Control and Data Access**. See [Websites](#websites). |
| **Screen Recording** *(optional, off)* | Pretype uses it for two things:<br>1. On-screen OCR context, only for the focused window, and only if you turn on screen context.<br>2. The brightness beside the caret. When Pretype shows text at the caret, it captures a strip of the screen to the right of the caret. It reduces the capture to 8 × 4 pixels, and then to one brightness value. It uses this value to select dark or light text. It does not capture its own windows. It keeps no image. This occurs when the permission is granted, also with screen context off.<br>The debug log does not contain OCR text or clipboard contents. An exported log shows a character count in their place, never the text. |
| **Clipboard** *(optional, off)* | Only if you turn on **Settings → Personalization → Use clipboard context**. When the clipboard changes, Pretype reads its text and keeps the first 600 characters in memory. It adds them to the prompt. See [Clipboard](#clipboard). |
| **Microphone** *(optional, off)* | Pretype uses it only for dictation, and only while a capture runs. See [Microphone](#microphone). |
| **Stored locally** | A journal for on-device personalization. See [Journal](#journal). |
| **Terminals** | Pretype completes text only in the prompt box of an AI agent, such as Claude Code. See [Terminals](#terminals). |
| **Never runs** | In password managers. In the shell command line of a terminal. While macOS reports secure input. While an input method is in mid-composition (Pinyin, kana, Telex, Hangul). |

To stop Pretype in more apps, add them to the blacklist in **Settings → General**. To stop it in the current app, use the menu bar.

### Network requests

None of these requests contains your text. The optional API providers are different. See [API providers](#api-providers).

| Request | Source | When | Notes |
|---|---|---|---|
| Model weights | Hugging Face | First launch. | Needed for every local model. |
| Current build of your model | Hugging Face | One time, in the background, after an update that changes your model. Pretype checks at launch and then one time each hour. | This is a new build (the smaller Gemma re-pack, Qwen3.5 Base 6-bit, MiniCPM5 8-bit), the weights of a new recommended style, or a new default for the memory of your Mac. Never on a cellular, hotspot or Low Data Mode network. The old model continues to serve until the new one is in place. The menu bar status shows the progress. |
| Instruct sibling | Hugging Face | The first time that you use <kbd>⌥Tab</kbd>, **or dictate with “Tidy up” on**. Only on models that need it. | Both features use the same fix pass. A dictation does not wait for the download. It types what it heard and downloads in the background, on an unmetered network only. On a metered network, the first <kbd>⌥Tab</kbd> downloads it. The tidy-up starts after the download is complete. |
| Speculative-decoding drafter, ~150 MB | Hugging Face | Gemma tiers only. In the background, when the drafter is missing. One attempt for each launch. | It makes the fix and reply chords faster. |
| Version check | GitHub Releases API | One time each day. | It sends no data about you. To stop it, go to **Settings → General**. |
| Speech model for your dictation language | Apple servers | When you turn on dictation, or select a new language. | This is the same system download that the built-in keyboard dictation uses. |
| Parakeet dictation model, ~610 MB (CoreML) | Hugging Face (`FluidInference/parakeet-ultra-coreml`) | One time, only if you opt in (**Settings → Dictation**). | Stored in `~/Library/Application Support/FluidAudio`. An install that opted in before this model replaces its earlier `parakeet-tdt-0.6b-v3-coreml` one time, in the background, on an unmetered network. |
| Share a per-app style | GitHub, in your browser | Only when you click the share button. | GitHub's new-file page opens with that one style. The style text is in the URL of the page. Thus GitHub and your browser history see it when the page opens. GitHub gets nothing more until you submit the page. |
| Refrain download link | GitHub Releases API | Only when you click **Download Refrain** in the menu bar menu. | Pretype asks `api.github.com/repos/nikiomori/Refrain/releases/latest` for the file list of the latest Refrain release. Then your browser opens the zip file of the release and downloads it. The request contains no text and no data about you. Pretype does not install Refrain. You move it to Applications yourself. |

### Clipboard

The clipboard context is off by default. To turn it on, use **Settings → Personalization → Use clipboard context**.

* Pretype reads the clipboard only when its contents change. It keeps the first 600 characters of the text.
* Pretype does not read a copy that a password manager marks as concealed or transient.
* Pretype does not use the clipboard in terminals, code editors, password managers and apps or websites that you switched off. Screen OCR has the same rule.
* Pretype does not use the clipboard if the field already contains the copied text.
* The clipboard text goes into the prompt for the model. With an API provider for text, it goes to that provider. See [API providers](#api-providers).
* The journal and the debug log never contain the clipboard text.

### Websites

In a web page, Pretype reads the host name of the page when the focus changes. For example, it reads `mail.google.com`, never the full address. Per-website settings use this host name.

* Pretype keeps the host name in memory only. It never logs, journals or sends it.
* Pretype remembers only the websites that you add or switch off yourself. It keeps them in Settings, as it does for an app.

### Microphone

A capture runs only in these conditions:

| Gesture | Capture starts | Capture stops |
|---|---|---|
| Hold | You hold the key down. | You release the key, press a different key, or switch apps. |
| Hands-free chord | First press. | Second press, or after a few seconds of silence. |

* Pretype never writes audio to disk. It resamples the audio in memory, gives it to the system's on-device speech models, and then discards it. If you opt in to Parakeet, Parakeet does the transcription on this Mac.
* Pretype sends audio only if you turn on an API provider for dictation. See [API providers](#api-providers).
* Pretype gives the names and terms that are already in the field to the same on-device recognizer. These are spelling hints for that one capture.
* The dictation flow never journals the transcript. The debug log does not contain it, as for OCR and clipboard text. An exported log shows a character count in its place.
* Sometimes Pretype cannot type a transcript, for example when the focus moved to a password field or to a Pretype window. Then Pretype puts the transcript on the clipboard.
  * This clipboard is for this Mac only (no Universal Clipboard).
  * Pretype marks it as transient, so clipboard managers do not keep it in their history.
* After Pretype types the transcript, it is ordinary text in the field. A later suggestion can see it as surrounding context, as it sees text that you type by hand.

### API providers

**Settings → API** can send text, audio or both to a hosted model. Each one is **off** by default. You turn each one on separately.

| | Text | Dictation |
|---|---|---|
| **What goes to the provider** | The text before the caret (up to 1,200 characters), at each suggestion. The selection for the fix chord and voice commands. The conversation for the reply chord. The screen and clipboard context, if you turned them on. A dictated transcript, if “Tidy up” is on. | The audio of each capture, as one WAV file, when the capture stops. With OpenAI `gpt-transcribe` and Whisper models, also the names and terms that are already in the field. These are spelling hints, as for the on-device recognizer. |
| **When** | Each time that a suggestion is due. | One time for each capture. |
| **Never** | Text in password fields, in blacklisted apps, or while macOS reports secure input. | Audio from a capture that you cancel. |

* Pretype keeps each API key in your login keychain. It never writes the key to Settings or to the debug log.
* The debug log never contains the audio or a dictated transcript. For a failed request, it shows the error message from the provider.
* The provider's own privacy policy applies to the data that it gets. Most providers charge for each request.
* A local server, such as Ollama or LM Studio, runs on your Mac. With a local server, the data does not leave the Mac.

### Journal

Pretype keeps a journal in `~/Library/Application Support/Pretype` for on-device personalization.

| | |
|---|---|
| **Contents** | Every suggestion that Pretype showed you, and its result. Each entry has the text around the caret at that time: up to 1,000 characters before it and 192 after it. Plus any text that you import with **Settings → Personalization → Advanced → Import Text…**. |
| **Format** | Plain text. |
| **Maximum size** | 50 MB (years of typing). |
| **Default** | On. |
| **To delete** | Switch it off in **Settings → Personalization → Advanced**. This deletes all of the journal, imported text included. |
| **Never in the journal** | OCR screen text. Clipboard text. Dictation writes no journal entries of its own. Dictated text that is already in the field is ordinary surrounding text (see [Microphone](#microphone)). |

### Terminals

Pretype completes text only in the prompt box of an AI agent, such as Claude Code. This works in Terminal, iTerm2 and the terminal panel of VS Code-based editors.

* To find the prompt box, Pretype reads the terminal text near the cursor.
* Only the text that you typed into the box goes to the model.
* Pretype discards all other text (the shell, the command output) in memory. It never journals or logs this text.
* In Terminal and iTerm2, these features stay off: the fix and reply chords, dictation and screen OCR.

## Uninstall

Pretype keeps its data in the locations below. Remove all of them, and nothing that Pretype wrote stays on the Mac. The speech models that dictation uses belong to macOS. macOS shares them with its own dictation, so they stay.

> **CAUTION:** If you turned on "Open at login", switch it off before you delete the app. Use **Settings → General**, or **System Settings → General → Login Items**. macOS keeps this registration outside the app. If you delete the app first, the registration stays.

1. Delete the app. If you installed Pretype with Homebrew, use `brew uninstall pretype` in place of this command.

   ```bash
   rm -rf /Applications/Pretype.app
   ```

2. Delete the downloaded models (several GB).

   **Settings → Model** shows each model with its size and a Delete button. This button deletes only models from the Pretype catalog. But it does not show the model that you use now. Thus, for a full removal, use the command below.

   > **WARNING:** This command deletes the full `mlx-community`, `openbmb` and `prism-ml` organizations from the shared Hugging Face cache. If a different MLX tool (LM Studio, mlx_lm, …) uses this cache, do not delete those three lines. The `nikimori` organization contains only Pretype's own re-packs (Qwen3.5 2B Base, the default on 8 GB Macs, and the slim Gemma tiers).

   ```bash
   rm -rf ~/.cache/huggingface/hub/models--nikimori--* \
          ~/.cache/huggingface/hub/models--openbmb--* \
          ~/.cache/huggingface/hub/models--mlx-community--* \
          ~/.cache/huggingface/hub/models--prism-ml--*
   ```

3. Delete the Parakeet dictation model (~610 MB). Do this step only if you opted in to Parakeet.

   > **CAUTION:** This folder belongs to the FluidAudio library. If a different app on your Mac also uses it, do not delete it.

   ```bash
   rm -rf ~/Library/Application\ Support/FluidAudio
   ```

4. Delete the local personalization data (the suggestion journal and the learned n-grams).

   ```bash
   rm -rf ~/Library/Application\ Support/Pretype
   ```

5. Delete the API keys. Do this step only if you added a key in **Settings → API**. Do the command one time for each provider (`openai`, `anthropic`, `gemini`, `groq`, `mistral`, `openrouter`, `deepseek`, `custom`).

   ```bash
   security delete-generic-password -s app.pretype.api-key -a openai
   ```

6. Delete the settings and reset the permission grants. If you never turned on screen context or dictation, you do not need the last two commands.

   ```bash
   defaults delete app.pretype.Pretype
   tccutil reset Accessibility app.pretype.Pretype
   tccutil reset ScreenCapture app.pretype.Pretype
   tccutil reset Microphone app.pretype.Pretype
   ```

To report a security problem, use the private procedure in [SECURITY.md](../SECURITY.md).
