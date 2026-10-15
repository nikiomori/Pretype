# docs

## Pages

[Architecture](ARCHITECTURE.md) · [Choosing a model](models.md) ·
[Privacy & permissions](privacy.md) · [Troubleshooting & FAQ](troubleshooting.md)

The site [pretype.app/docs](https://pretype.app/docs) publishes each `.md` file
in this folder, but not this file. The landing repo pulls this folder when it
builds, and renders the pages. Write each page for GitHub and for the site:

* Use relative links. A link to a sibling `.md` file becomes a docs route. A
  link that starts with `../` becomes a GitHub link.
* Use Markdown or a plain `<img src="…">` for figures. Then the site publishes
  the image with the page.
* Do not use Mermaid blocks or GitHub alerts (`> [!NOTE]`). The site does not
  render them. Use a rendered diagram (refer to [Diagrams](#diagrams)) and
  `> **NOTE:**` or `> **WARNING:**`.
* On the site, only the last column of a table wraps. Keep the other columns
  short, or break their lines with `<br>`.

## Assets

The other files in this folder are the visual assets of the README, the
diagrams of the pages, and the GitHub social preview. There are four types.
Each type has a different update procedure.

> **NOTE:** The tools for the rendered art, the real captures and the model
> chart are in the `dev-tools/` tree. Git ignores this tree, thus a clone does
> not have it. A maintainer makes these assets again. If your change needs a
> new asset, write this in the pull request. Only the diagram script
> (`docs/diagrams/render.sh`) is in the repository.

## Rendered art — `hero.png`

The `PretypeHeroArt` generator (maintainer only) draws this file with code.
It uses only Core Graphics and no app code. Its output is deterministic at 2×.
Thus each run makes a byte-identical file:

```sh
cd dev-tools/HeroArt
swift run PretypeHeroArt --hero ../../docs/hero.png
```

| File | Content |
|---|---|
| `hero.png` | One completion line. It is the GitHub **Social preview**. The README does not use it |
| `pretype-logo.png`, `pretype-logo-dark.png` | The mark in the README header. A person drew it. The generator does not make it |

## Real captures — `shot-*.png`, `demo*.gif`

These files are real captures of the app. Capture them again each time the
Settings UI or the suggestion overlay changes. If not, the README shows an app
that does not exist anymore.

The script `dev-tools/ui-shots/make-shots.sh` (git-ignored) does all steps:

1. It builds HEAD with a small hook.
2. It opens the windows without an engine, with its own defaults domain and a
   fictional persona:
   * `make-shots.sh` opens the Settings window.
   * `make-shots.sh demos` opens a text window. Then it shows the real
     suggestion overlay over the text, one step at a time.
3. The app captures its own windows. This needs no Screen Recording
   permission.

A window shows on the screen for approximately 15 seconds while the script
runs.

| File | Content |
|---|---|
| `shot-settings.png`, `shot-models.png`, `shot-personal.png` | Panes of the Settings window |
| `demo.gif` | Typing → the panel shows the suggestion → `Tab` for each word, `⇧Tab` for the remaining text |
| `demo-typo.gif` | Inline typo fix: the fix pill shows above the word, and `Tab` applies it |
| `demo-fix.gif` | Fix selection: `⌥Tab` → the model runs → the word diff → `⏎` |
| `shot-modes.png` | Inline ghost text and the floating panel, side by side |

ImageMagick assembles the GIFs. It uses one palette without dithering, and a
2% tolerance for frame differences. Do not use dithering. On a flat dark UI,
dithering adds noise that stops the frame diff, and makes the file
approximately 5× larger. It gives no visible improvement.

The suggestion overlay is a borderless agent window (`LSUIElement`). Thus
`⌘⇧4` and most capture apps do not capture it. The system tool with an explicit
region captures it:

```bash
# x,y,w,h in points (top-left origin); outputs 2× on Retina
screencapture -x -R 95,170,1400,200 /tmp/shot.png
```

Then crop with `sips --cropOffset <top> <left> -c <h> <w>`. Other useful forms:
`screencapture -T 5 docs/menu.png` (5 s timer, for open menus) and
`screencapture -iW docs/console.png` (select a window).

## Diagrams

Each diagram has a Mermaid source and a rendered SVG:

| Item | Location |
|---|---|
| Source | `docs/diagrams/<name>.mmd`. Start the file with a `%%` comment that tells what the diagram shows |
| Output | `docs/diagram-<name>.svg`. The SVGs are in `docs/`, not in `docs/diagrams/`, because the site copies only top-level files |
| Theme | `docs/diagrams/mermaid.json`. It sets plain SVG text labels (no `foreignObject`), so the image shows correctly in an `<img>` tag |

To render the diagrams:

```sh
docs/diagrams/render.sh            # all diagrams
docs/diagrams/render.sh privacy    # one diagram: docs/diagrams/privacy.mmd
```

The script needs Node and Google Chrome. It runs `@mermaid-js/mermaid-cli`
11.4.2 through `npx`, with the installed Chrome. It does not download a
browser. For a different Chrome path, set `CHROME`.

Rules:

* A page in `docs/` shows a diagram as an image:
  `<img src="diagram-<name>.svg" width="720" alt="…" />`.
* The alt text must contain the content of the diagram in words.
* A page that only GitHub shows (the root README, CONTRIBUTING, SECURITY,
  AppStyles/README) can use an inline `` ```mermaid `` block. GitHub renders it
  and changes its colours for dark mode.
* After you change a `.mmd` file, render it again. Commit the `.mmd` file and
  its `.svg` file together.

## `chart-models.svg` — the model chart

A script (maintainer only, git-ignored) makes this chart from the catalog that
the app ships. Thus the chart and the app always agree:

```sh
python3 dev-tools/gen-readme-chart.py
```

The script reads `Sources/Pretype/Engines/ModelMetrics.swift` directly: both
`ModelMetrics.all` (latency, RAM) and `perLangOfAll` (the per-language cells
that it averages). Run it again after each change to the measured metrics.

The script also checks its own premise: English is a tie, and the
multilingual column is not. If new metrics invert this finding, the script
fails. Thus no chart ships with a headline that its data does not support.
