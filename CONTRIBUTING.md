# Contributing to Pretype

Thanks for your interest in improving Pretype! It's an early-stage open-source
project, and contributions of all kinds are welcome — bug reports, fixes, new
engines, prompt/quality work, and documentation.

## Ground rules

- Be respectful — this project follows the [Code of Conduct](CODE_OF_CONDUCT.md).
- Security issues go through [SECURITY.md](SECURITY.md), **not** public issues.
- Keep pull requests focused: one logical change per PR, matching the style of
  the surrounding code.

## Development setup

Requirements (same as the README's *Build & run*): macOS 14+, **full Xcode
16.3+** (Swift 6.1 — older toolchains fail compiling the MLX dependencies, and
the MLX engine needs the Metal shader compiler; Command Line Tools alone are
not enough), and Apple Silicon for the MLX engine. On Xcode 26+ install the
Metal toolchain once:

```bash
xcodebuild -downloadComponent MetalToolchain
```

Build a real `.app` bundle (it gets its own Accessibility grant) and run it:

```bash
./Scripts/make-app.sh
open build/Pretype.app
```

For a fast inner loop, `./Scripts/dev.sh` runs `swift build` and copies the MLX
metallib next to the dev binary (requires one prior `make-app.sh` run to
produce the metallib). Plain `swift build` compiles, but MLX can't run from a
SwiftPM binary — Pretype detects the missing shaders and disables the MLX
engine gracefully rather than crashing.

> **Permissions.** Pretype needs Accessibility (always) and Screen Recording
> (only for OCR screen context). `make-app.sh` signs with your *Apple
> Development* certificate when one exists, so grants survive rebuilds;
> otherwise it falls back to ad-hoc signing and you'll need to re-grant after
> each rebuild (`tccutil reset Accessibility app.pretype.Pretype`). See the
> README's *Troubleshooting* section.

## Headless harnesses

Completion-quality work happens through a CLI/eval harness that runs the real
engine without the full UI: `--complete` (one or more completions through the
KV-cache path), `--fix` (fix-selection via the instruct sibling), `--type-sim`
(KV-cache integrity — type a string word-by-word, then compare against a fresh
engine), and `--eval` (the quality regression below). This harness is kept in a
git-ignored `dev-tools/` tree (not shipped in the app); ask a maintainer if you
need it for a change.

Environment variables it reads (they override stored Settings):

- `PRETYPE_TEST_MODEL` — override the model id
- `PRETYPE_TEST_ENGINE=fm` — use the Apple Intelligence engine (macOS 26+)
- `PRETYPE_TEST_APP` — override the app-context header (empty string disables it)
- `PRETYPE_TEST_SCREEN` — inject screen-context text
- `PRETYPE_EVAL_VERBOSE=1` — per-sample eval output

## Quality eval — please measure prompt/model changes

Any change touching prompting, sampling, the output gates, or the model catalog
should be measured before and after. The eval harness lives in a git-ignored
`dev-tools/` tree, so **external contributors can't run it themselves — that's
expected**: open the PR anyway and note that it needs an eval run; a maintainer
will run the before/after numbers (coverage, first-word accuracy, saved chars,
p50 latency) and post them on the PR. The eval is a **comparison** tool —
absolute first-word accuracy understates quality because it rejects valid
paraphrases.

## Code style

- Match the surrounding code: 4-space indentation, no trailing whitespace.
- SwiftLint runs in CI (`swiftlint --strict`, config in `.swiftlint.yml`); a
  `.swiftformat` config covers formatting. Run `swiftlint` locally before
  pushing if you have it installed.
- Comments explain *why*, not *what*; the codebase favors short, high-signal
  comments (see the output-gate comments in `MLXEngine.swift` for the house
  style).
- Don't add dependencies without discussing it first in an issue.

## Adding an engine

Engines conform to the `CompletionEngine` protocol
(`Sources/Pretype/Engines/CompletionEngine.swift`): implement `complete(_:)`
(and optionally `correct(selection:request:)`), reuse the shared output gates
via `CompletionGates.postProcess(...)`, and surface progress through `EngineState` so
the menu and the caret indicator stay accurate. `FoundationModelsEngine.swift`
is a compact reference implementation.

## Pull request checklist

- [ ] `swift build` succeeds.
- [ ] The app launches and the change works against a real text field (TextEdit
      and Notes have the best Accessibility support).
- [ ] For prompt/model/gate changes: eval numbers requested (a maintainer runs
      the harness — see *Quality eval* above).
- [ ] Diff is focused; comments explain non-obvious decisions.
