# docs / assets

The README's visual assets, plus the GitHub social preview. Three kinds live
here, and each refreshes differently.

## Rendered art — `demo*.gif`, `hero.png`, `shot-modes.png`

Drawn programmatically by the `PretypeHeroArt` generator in the git-ignored
`dev-tools/` tree. Core Graphics only, no app code, deterministic 2×, so a
fresh clone always produces byte-identical output. Regenerate everything:

```sh
cd dev-tools/HeroArt
swift run PretypeHeroArt --all ../../docs
```

Individual pieces (`--gif` takes a storyboard name — `demo`, `typo` or `fix`):

```sh
swift run PretypeHeroArt --hero ../../docs/hero.png
swift run PretypeHeroArt --shot-modes ../../docs/shot-modes.png
swift run PretypeHeroArt --gif typo ../../docs/demo-typo.gif   # needs `magick`
swift run PretypeHeroArt --gif-frames fix /tmp/frames          # PNG storyboard only
```

| File | What |
|---|---|
| `demo.gif` | Typing → the model answers → `Tab` per word, `⇧Tab` for the rest |
| `demo-typo.gif` | Inline typo fix: the diff pill appears, `Tab` applies it |
| `demo-fix.gif` | Fix selection: `⌥Tab` → decode beat → rewrite → `⏎` |
| `shot-modes.png` | Inline ghost text vs the floating panel, side by side |
| `hero.png` | A single completion line — the GitHub **Social preview**, not used in the README |
| `pretype-logo.png`, `pretype-logo-dark.png` | The mark in the README header; hand-authored, not generated |

GIFs are assembled with ImageMagick using one undithered 128-colour palette and
a 3% frame-diff tolerance — dithering sprays noise that defeats the frame diff
and costs ~5× the file size on flat dark UI for no visible gain.

## Real captures — `shot-settings.png`, `shot-models.png`, `shot-personal.png`

Live screenshots of the app's Settings window. **These need a GUI and cannot be
regenerated headlessly** — re-shoot them by hand whenever the settings UI
changes, or the README ships a picture of an app that no longer exists.

The suggestion overlay is a borderless agent (`LSUIElement`) window, so `⌘⇧4`
and most capture apps filter it out. The system tool with an explicit region
gets it:

```bash
# x,y,w,h in points (top-left origin); outputs 2× on Retina
screencapture -x -R 95,170,1400,200 /tmp/shot.png
```

Then crop with `sips --cropOffset <top> <left> -c <h> <w>`. Other handy forms:
`screencapture -T 5 docs/menu.png` (5 s timer, for open menus) and
`screencapture -iW docs/console.png` (pick a window).

## `chart-models.svg` — the model chart

Generated from the shipping catalog, so it can't drift from the app:

```sh
python3 dev-tools/gen-readme-chart.py
```

It reads `Sources/Pretype/Engines/ModelMetrics.swift` directly — both
`ModelMetrics.all` (latency, RAM) and `perLangOfAll` (the per-language cells it
averages). Re-run it after any metrics rebooking. The script asserts its own
premise — that English is a tie and the multilingual column is not — so a
rebooking that inverts the finding fails the run instead of shipping a chart
whose headline no longer matches its data.
