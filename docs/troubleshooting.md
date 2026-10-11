# Troubleshooting & FAQ

Open **Diagnostics** from the menu-bar icon — *Context* shows what Pretype sees (app, window, field) and *Pipeline* shows what the last completion did.

## Common issues

**`Accessibility: NOT granted ✗`** — if you're running the raw binary from a terminal, macOS attributes the permission to the *terminal*, so grant it there or run the `.app` bundle. If you built locally, a changed code signature can confuse macOS:

```bash
tccutil reset Accessibility app.pretype.Pretype
```

then re-grant.

**`Text element: none`** — the app doesn't expose its text fields over the Accessibility API. Nothing to be done from this side.

**`Last: engine returned no suggestion`** — the model had nothing it was willing to guess: too little context, or the output gates rejected what it produced. Keep typing.

**No suggestions anywhere, MLX engine missing** — a source build without compiled Metal shaders. Use `./Scripts/make-app.sh` rather than plain `swift build`.

**`open build/Pretype.app` fails with `-600`, or Finder says "the application is not open anymore"** *(building from source)* — a previous instance was still running when its bundle was replaced, so LaunchServices tries to activate a process whose bundle no longer exists instead of launching the new build. `make-app.sh` now quits the running instance of that build first (a copy installed in /Applications is left alone, so you can keep dogfooding one while rebuilding the other); on an older checkout, quit Pretype from the menu bar before rebuilding, or launch with `open -n build/Pretype.app`.

**Gatekeeper blocks the first launch** — 2.5.0 and later are notarized and open normally; releases up to 2.4.0 are ad-hoc signed. Clear the quarantine flag with `xattr -dr com.apple.quarantine /Applications/Pretype.app`, or open the app via **System Settings → Privacy & Security → Open Anyway**.

## FAQ

### What happens to <kbd>Tab</kbd> when I actually want a Tab?

It passes straight through. The event tap only swallows the key while a suggestion is on screen; with nothing showing, <kbd>Tab</kbd> indents and moves between fields as usual. If that still collides with your habits, switch the chord to <kbd>⌘Space</kbd>, <kbd>⌥Space</kbd> or <kbd>⌃Space</kbd> in **Settings → General**.

### Suggestions stopped appearing in one app

Deliberate. Once Pretype has offered a few dozen completions in an app and under 2% of them were taken, it stops offering there — a model that is wrong in a particular field is pure interruption, and generating them costs battery. Everything else keeps working: inline typo fixes, emoji shortcodes and <kbd>⌥Tab</kbd> rewrites are unaffected.

Only offers you could actually have taken count toward that. The pipeline re-offers after every keystroke, so a ghost that was replaced by the next one, or that vanished in under 0.4 s, was never a suggestion you declined — and one you typed out yourself, word for word, means the model was right. None of those reach the tally, and neither do they reach the acceptance figure in **Diagnostics**.

It isn't silent about it. The menu-bar item that normally offers *Disable in …* becomes **Resume in Slack** instead, hovering the numbers behind the decision (*"Pretype went quiet here: 2% of 74 suggestions taken."*), and one click clears the record and starts offering again from scratch.

### Dictation does nothing when I hold the key (or press the chord)

Work down the list in **Settings → General → Dictation** — it names the blocker itself:

* **The section says it needs macOS 26.** Dictation uses the system's own on-device speech models. On macOS 14–15 those don't exist, and Pretype doesn't bundle a model of its own.
* **The section says "built app only".** A raw `swift build` binary has no bundle, and macOS grants microphone access by bundle. Run `./Scripts/make-app.sh` and launch the `.app`.
* **The section says the microphone is denied.** macOS only ever asks once, so a past refusal never re-prompts. Re-allow Pretype under **System Settings → Privacy & Security → Microphone** — the button under the notice jumps straight to the pane — then switch dictation on again.
* **The language line warns that macOS has no model for it.** Apple's newer speech model covers 30 locales; the rest fall back to the system dictation model, and a few languages have neither. The Settings caption names which one your current language gets — dictation can't invent a model Pretype doesn't ship.
* **The first press only says "getting the dictation model ready…"** — macOS is downloading that language, once. Try again in a minute; the download continues even after you let go.
* **The pill never appears.** It is a *hold*, not a tap: keep the key down for about half a second before speaking. Either side of the modifier works. Any other keypress — or a mouse click — cancels a capture in progress, so don't type while talking. None of that applies to the hands-free chord below, which is what to reach for if this keeps catching you out.
* **I can't talk and use the keyboard at the same time.** That is the hold gesture being strict on purpose — a modifier is only "push to talk" as long as nothing else happens, or every <kbd>⌥</kbd>-arrow would open the microphone. Use the hands-free chord instead (**Settings → General → Dictation → Hands-free chord**, <kbd>⌃⌥D</kbd> by default): press once to start, once to stop, and typing, clicking and scrolling leave it alone. <kbd>⎋</kbd> still throws the capture away, and moving to another field ends it — the words belong to the field you started in.
* **A hands-free capture stopped by itself.** It ends after a few seconds of silence so a forgotten chord isn't an open microphone; what it had heard by then is typed, not thrown away. Change the budget — or turn it off entirely — under **Stop after silence**. Before your first word the budget is half a minute, so thinking before you start is fine. With silence off, a capture still ends at ten minutes.
* **My music goes flat and quiet while I dictate.** That is the headset switching to call mode: Bluetooth carries either good playback or a two-way call, never both. **Settings → General → Dictation → Microphone** is set to *Automatic*, which avoids it by recording from the built-in microphone whenever your earbuds are also playing your audio — if you pinned the headset there instead, this is the cost. The sound comes back once the capture ends and the headset switches back out of call mode.
* **The headset died (or AirPods connected) mid-sentence.** The capture follows the default input: when the device changes it carries on from whatever macOS switched to, and only ends when no microphone is left at all — in which case whatever was already heard is typed rather than thrown away.
* **A long dictation lands unpunctuated.** The tidy-up pass is the same minimal-edit fix <kbd>⌥Tab</kbd> uses, and that one is defined for a single short line: anything past 500 characters skips it and is typed exactly as heard, rather than going in half-corrected. Say a long passage in a few holds if you want the punctuation back.

Still silent? **Diagnostics → `Dictation:`** states the app's own view in one line. For the whole picture, run the built binary with `--dictation-probe`: it prints the environment, then every modifier edge with the hold state it produced, and — when a hold completes — each condition the capture checks, so a refusal names itself.

```bash
./build/Pretype.app/Contents/MacOS/Pretype --dictation-probe
```

### What does it cost in battery and memory?

The model stays resident while you're typing — that's what makes warm completions fast — holding ≈1.1–5.6 GB for the default, which is sized to about a quarter of your Mac's memory. After **five idle minutes (fifteen on Macs with 32 GB or more) it unloads itself** and frees that memory, reloading on your next keystroke; it also unloads early if macOS reports memory pressure. It only computes while you're typing in a field it's allowed to read, and suggestions are debounced and cancellable, so fast typing supersedes in-flight work instead of queueing it.

### Which languages work?

Completions are evaluated across 19 languages, each measured on its own rather than averaged with its neighbours — see [Choosing a model](models.md); the default is sized to your Mac's memory: a Gemma 4 tier (the broadest language coverage) from 16 GB up, Qwen3.5 2B (the strongest small model outside English) on 8 GB. In **Settings → Model** you can set the accuracy axis to the language you actually type in, and every figure on that tab is re-measured for it, with its sample size and tolerance printed alongside. Inline typo fixes use the macOS spell-checker in whichever language it detects, so any dictionary macOS has installed works (English and Russian are the most-tested pair).

### Where does my data go?

Nowhere. See [Privacy & permissions](privacy.md) for what is stored locally and how to remove it.

---

Still stuck? [Open an issue](https://github.com/nikiomori/Pretype/issues) with the Diagnostics output — it redacts your text and carries only the pipeline state.
