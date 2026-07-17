# docs / assets

The README's visual assets live here.

## Screenshots — real captures

`hero.png`, `shot-typo.png`, `shot-fix.png` and `shot-modes.png` are **live captures**
of Pretype running in TextEdit. The overlay is a borderless agent (`LSUIElement`)
window, so the `⌘⇧4` shortcut and most capture apps filter it out — the system
`screencapture` tool with an explicit region grabs it:

```bash
# x,y,w,h in points (top-left origin); outputs 2× on Retina
screencapture -x -R 95,170,1400,200 /tmp/shot.png
```

To refresh one: trigger the overlay in a text field (type for a completion, mistype a
word for the typo fix, or select a line and press ⌥Tab for the rewrite), capture its
region, then crop with `sips --cropOffset <top> <left> -c <h> <w>`.

| File | What |
|---|---|
| `hero.png` | A completion in the floating panel (also the GitHub **Social preview**) |
| `shot-typo.png` | Inline typo fix — the diff pill above a misspelled word |
| `shot-fix.png` | Fix selection (`⌥Tab`) — a line rewritten in place |
| `shot-modes.png` | A completion shown as a floating panel above the line |

The git-ignored `dev-tools/HeroArt` package can still render clean *mockups* of these
(`--hero` / `--shot-typo` / `--shot-fix` / `--shot-modes`) if you ever want a synthetic
stand-in.

## demo.gif — rendered animation

`demo.gif` is drawn programmatically by the `PretypeHeroArt` generator in the
git-ignored `dev-tools/` tree — a clean illustration of the inline ghost-text flow.
The generator emits the frames; `ffmpeg` assembles them:

```bash
cd dev-tools/HeroArt
mkdir -p /tmp/f && swift run PretypeHeroArt --gif-frames /tmp/f
ffmpeg -y -framerate 12.5 -i /tmp/f/frame-%03d.png \
  -vf "scale=860:-1:flags=lanczos,palettegen=max_colors=200:stats_mode=full" /tmp/pal.png
ffmpeg -y -framerate 12.5 -i /tmp/f/frame-%03d.png -i /tmp/pal.png \
  -lavfi "scale=860:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=4" -loop 0 ../../docs/demo.gif
```

A real ~10 s screen recording of typing → ghost text → `Tab` is the single most
convincing asset if you can grab one (QuickTime → `.mov`); convert it with the `ffmpeg`
recipe above (or [Gifski](https://gif.ski)).

## More captures (menu bar, console, model picker)

Drop additional PNGs here and wire them into the README. On macOS:

- **A window** — `⌘⇧4` then `Space`, click the window; hold `⌥` while clicking to drop the shadow.
- **An open menu** — `screencapture -T 5 docs/menu.png` gives a 5 s timer.
- **A specific window from the terminal** — `screencapture -iW docs/console.png`.
