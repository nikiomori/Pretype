# Troubleshooting & FAQ

Use **Diagnostics** to find the cause of a problem. To open it, click the menu-bar icon and then click **Diagnostics**.

* *Context* shows what Pretype reads: the app, the window and the text field.
* *Pipeline* shows what occurred with the last suggestion.

## No suggestions appear

Do the checks from left to right. Each check reads one line of **Diagnostics**.

<div align="center">
<img src="diagram-trouble-no-suggestions.svg" width="720" alt="Fault isolation when no suggestions appear. Open Diagnostics. If the line reads 'Accessibility: NOT granted ✗', grant Accessibility to the .app bundle. If 'Text element: none', the app does not show its text fields to Accessibility and there is no remedy. If the Engine line reads 'failed — Metal shaders missing', build with Scripts/make-app.sh. If 'Last:' reads that Pretype is quiet in this app, click 'Resume in ‹app›' in the menu. If 'Last: engine returned no suggestion', type more text. If none of these, open an issue and attach the Diagnostics output." />
</div>

## Common issues

| Symptom | Cause | Remedy |
|---|---|---|
| `Accessibility: NOT granted ✗` | You started the raw binary<br>from a terminal. macOS gave<br>the permission to the terminal. | Grant Accessibility to the terminal, or run the `.app` bundle. |
| `Accessibility: NOT granted ✗`<br>after a local build | The code signature changed. | Reset the grant with `tccutil reset Accessibility app.pretype.Pretype`. Then grant Accessibility again. |
| `Text element: none` | The app does not show its<br>text fields to the<br>Accessibility API. | No remedy is possible from Pretype. |
| `Last: engine returned`<br>`no suggestion` | The context is too short, or<br>the output gates rejected<br>the result of the model. | Type more text. |
| No suggestions in all apps.<br>The MLX engine is missing. | A source build without<br>compiled Metal shaders. | Build with `./Scripts/make-app.sh`. Do not use plain `swift build`. |
| `open build/Pretype.app` fails<br>with `-600`, or Finder shows<br>"the application is not open<br>anymore" (source builds) | An old instance was running<br>when you replaced its bundle.<br>LaunchServices activates the<br>old process, not the new build. | Quit Pretype from the menu bar before you rebuild. Or start the build with `open -n build/Pretype.app`. On a current checkout, `make-app.sh` quits the running instance of that build first. It does not quit a copy in `/Applications`, so you can use that copy while you rebuild. |
| Gatekeeper blocks<br>the first launch | Releases up to 2.4.0 have<br>an ad-hoc signature. | Releases 2.5.0 and later are notarized and open normally. For an older release, remove the quarantine flag with `xattr -dr com.apple.quarantine /Applications/Pretype.app`. Or click **System Settings → Privacy & Security → Open Anyway**. |

### API providers

These lines show in the menu and in **Settings → API → Test connection**.

| Symptom | Cause | Remedy |
|---|---|---|
| `add an API key in Settings → API` | API text or dictation is on, and the provider has no key. | Paste the key in **Settings → API**. Click **Test connection**. |
| `the API key was rejected (401)` or `(403)` | The key is incorrect, expired, or for a different provider. | Make a new key with **Get a key**. Paste it, then click **Test connection**. |
| `HTTP 404` or `HTTP 400` with a model name | The provider does not know the model name. | Type a model name from the list of the provider. Or select the provider again to get the preset model. |
| `Could not connect to the server` with Ollama or LM Studio | The local server does not run. | Start Ollama or the LM Studio server. Make sure that the model is downloaded, for example with `ollama pull gemma4:e4b`. |
| Suggestions come late with API text on | The network, or a model that reasons before it answers. | Use the preset model of the provider, or a provider near you. Or turn off API text to use the local model. |
| Dictation types nothing with API dictation on | The upload failed, or the provider timed out after 60 s. | Click **Test connection** in the Dictation section. For long takes, use a shorter capture. |

## FAQ

### What happens to <kbd>Tab</kbd> when I want a Tab character?

The key goes through to the app. The event tap stops <kbd>Tab</kbd> only while a suggestion is on the screen. When no suggestion shows, <kbd>Tab</kbd> indents and moves between fields as usual.

To use a different accept key, select <kbd>⌘Space</kbd>, <kbd>⌥Space</kbd> or <kbd>⌃Space</kbd> in **Settings → General**.

### Suggestions stopped in one app

This is intentional. Pretype stops suggestions in an app when both conditions are true:

* It showed a few dozen suggestions in that app.
* You accepted less than 2% of them.

A model that is frequently wrong in a field only interrupts you, and it uses battery power. Inline typo fixes, emoji shortcodes and <kbd>⌥Tab</kbd> rewrites continue to work.

Only the suggestions that you were able to accept are counted. These suggestions are not counted, in this rule and in the acceptance figure in **Diagnostics**:

* A suggestion that the next suggestion replaced. Pretype makes a new suggestion after each keystroke.
* A suggestion that disappeared in less than 0.4 s.
* A suggestion that you typed yourself, word for word. In this case, the model was correct.

Pretype tells you when it stops. The menu item *Disable in …* changes to **Resume in ‹app›**, for example **Resume in Slack**. Its tooltip shows the numbers, for example *"Pretype went quiet here: 2% of 74 suggestions taken."* Click the item to clear the record. Pretype then starts to show suggestions again.

### Dictation does nothing when I hold the key (or press the chord)

First, open **Settings → General → Dictation**. That section shows the name of the blocker.

| Symptom | Cause | Remedy |
|---|---|---|
| The section says<br>"built app only" | A raw `swift build` binary<br>has no bundle. macOS gives<br>microphone access by bundle. | Run `./Scripts/make-app.sh`. Then start the `.app`. |
| The section says that<br>the microphone is denied | macOS asks only one time.<br>After a refusal, it does<br>not ask again. | Allow Pretype in **System Settings → Privacy & Security → Microphone**. The button below the notice opens that pane. Then enable dictation again. |
| The language line says that<br>macOS has no model for it | The newer Apple model covers<br>30 locales. Other languages use<br>the system dictation model.<br>Some languages have neither. | Use a language that has a model. The Settings caption shows which model your current language gets. Pretype cannot add a model that macOS does not supply. |
| The first press shows<br>"getting the dictation<br>model ready…" | macOS downloads the model<br>for that language one time. | Wait approximately one minute, then try again. The download continues after you release the key. |
| The pill does not appear | Dictation starts on a hold,<br>not on a tap. Another key or<br>a mouse click cancels it. | Hold the key for approximately half a second before you speak. The modifier key on the left or the right side operates. Do not type while you speak. If this occurs frequently, use the hands-free chord (next row). |
| You cannot speak and use<br>the keyboard at the same time | The hold gesture is strict<br>by design. If not, each<br><kbd>⌥</kbd>-arrow opens the microphone. | Use the hands-free chord: **Settings → General → Dictation → Hands-free chord**, <kbd>⌃⌥D</kbd> by default. Press it one time to start and one time to stop. Typing, clicks and scrolling do not stop it. <kbd>⎋</kbd> discards the capture. A move to a different field stops the capture, because the words go to the field where you started. |
| A hands-free capture<br>stopped by itself | The capture stops after a few<br>seconds of silence. This<br>prevents an open microphone. | Pretype types the words that it heard before the stop. To change the time, or to disable the stop, use **Stop after silence**. Before your first word, the limit is 30 seconds. With the silence stop disabled, a capture stops at 10 minutes. |
| Music becomes flat and quiet<br>while you dictate | The headset changed to call<br>mode. Bluetooth carries good<br>playback or a two-way call,<br>not both at the same time. | Set **Settings → General → Dictation → Microphone** to *Automatic* (the default). Then Pretype records from the built-in microphone when your earbuds also play your audio. If you selected the headset there, this effect is the cost. The sound becomes normal when the capture stops. |
| The headset stopped<br>during a sentence | The microphone of the<br>capture disconnected. | No action is necessary. The capture continues on the default input. It stops if no microphone is available, or if the input changes more than 3 times in 3 seconds. Then Pretype types the words that it heard. A headset that connects during a capture does not replace the microphone of that capture. |
| A long dictation has<br>no punctuation | The tidy-up pass is for one<br>short line. Text longer than<br>500 characters skips it. | Pretype types that text exactly as it heard it. To get punctuation, dictate a long passage in a few shorter parts. |

If dictation still does not operate:

1. Read the `Dictation:` line in **Diagnostics**. It shows the status of dictation in one line.
2. Run the built binary with `--dictation-probe`:

   ```bash
   ./build/Pretype.app/Contents/MacOS/Pretype --dictation-probe
   ```

   The probe prints the environment. Then it prints each change of a modifier key, with the hold state that the change caused. When a hold completes, it prints each condition that the capture checks. Thus a refusal shows its cause.

### What does it cost in battery and memory?

The model stays in memory while you type. This makes suggestions fast. The default model uses approximately 1.5–5 GB, which is approximately one quarter of the memory of your Mac.

* After five minutes without typing, the model unloads and releases its memory. On Macs with 32 GB or more, this time is fifteen minutes. The model loads again at your next keystroke.
* If macOS reports memory pressure, the model unloads earlier.
* The model computes only while you type in a field that Pretype can read.
* Pretype waits for a short pause in your typing before it starts a suggestion. When you type fast, new work replaces old work, and no queue occurs.

### Which languages work?

The eval measures suggestions in 19 languages. Each language has its own result, and no language is averaged with other languages. Refer to [Choosing a model](models.md).

The default model depends on the memory of your Mac:

| Mac memory | Default model |
|---|---|
| 16 GB and more | A Gemma 4 tier, which has the widest language coverage |
| 8 GB | Qwen3.5 2B, which is the strongest small model outside English |

In **Settings → Model**, set the accuracy axis to the language that you type. Each figure on that tab then shows the result for that language, with its sample size and tolerance.

Inline typo fixes use the macOS spell checker, in the language that it detects. All dictionaries that macOS has installed operate. English and Russian have the most tests.

### Where does my data go?

By default, Pretype does not send your data. If you turn on an API provider in **Settings → API**, your text or your audio goes to that provider. [Privacy & permissions](privacy.md) shows what Pretype sends, what it stores on your Mac, and how to remove it.

---

If the problem continues, [open an issue](https://github.com/nikiomori/Pretype/issues) and attach the Diagnostics output. The output does not contain your text. It contains only the pipeline state.
