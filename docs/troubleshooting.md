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

**Gatekeeper blocks the first launch** — releases before the Developer ID signing are ad-hoc signed. Clear the quarantine flag with `xattr -dr com.apple.quarantine /Applications/Pretype.app`, or open the app via **System Settings → Privacy & Security → Open Anyway**.

## FAQ

### What happens to <kbd>Tab</kbd> when I actually want a Tab?

It passes straight through. The event tap only swallows the key while a suggestion is on screen; with nothing showing, <kbd>Tab</kbd> indents and moves between fields as usual. If that still collides with your habits, switch the chord to <kbd>⌘Space</kbd>, <kbd>⌥Space</kbd> or <kbd>⌃Space</kbd> in **Settings → General**.

### Suggestions stopped appearing in one app

Deliberate. Once Pretype has offered a few dozen completions in an app and under 2% of them were taken, it stops offering there — a model that is wrong in a particular field is pure interruption, and generating them costs battery. Everything else keeps working: inline typo fixes, emoji shortcodes and <kbd>⌥Tab</kbd> rewrites are unaffected.

Only offers you could actually have taken count toward that. The pipeline re-offers after every keystroke, so a ghost that was replaced by the next one, or that vanished in under 0.4 s, was never a suggestion you declined — and one you typed out yourself, word for word, means the model was right. None of those reach the tally, and neither do they reach the acceptance figure in **Diagnostics**.

It isn't silent about it. The menu-bar item that normally offers *Disable in …* becomes **Resume in Slack** instead, hovering the numbers behind the decision (*"Pretype went quiet here: 2% of 74 suggestions taken."*), and one click clears the record and starts offering again from scratch.

### What does it cost in battery and memory?

The model stays resident while you're typing — that's what makes warm completions fast — holding ≈1.6–2.2 GB for the defaults. After **five idle minutes it unloads itself** and frees that memory, reloading on your next keystroke; it also unloads early if macOS reports memory pressure. It only computes while you're typing in a field it's allowed to read, and suggestions are debounced and cancellable, so fast typing supersedes in-flight work instead of queueing it.

### Which languages work?

Completions are evaluated across 19 languages, each measured on its own rather than averaged with its neighbours — see [Choosing a model](models.md); the default is picked from your keyboard layouts and the Gemma 4 builds have the broadest coverage. In **Settings → Model** you can set the accuracy axis to the language you actually type in, and every figure on that tab is re-measured for it, with its sample size and tolerance printed alongside. Inline typo fixes use the macOS spell-checker in whichever language it detects, so any dictionary macOS has installed works (English and Russian are the most-tested pair).

### Where does my data go?

Nowhere. See [Privacy & permissions](privacy.md) for what is stored locally and how to remove it.

---

Still stuck? [Open an issue](https://github.com/nikiomori/Pretype/issues) with the Diagnostics output — it redacts your text and carries only the pipeline state.
