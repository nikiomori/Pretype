#!/bin/sh
# Renders every docs/diagrams/<name>.mmd to docs/diagram-<name>.svg.
# The SVGs sit flat in docs/ because the pretype.app docs build copies only
# top-level files. Needs Node and Google Chrome. With an argument, renders
# only that one diagram (e.g. `./render.sh privacy`).
set -eu
cd "$(dirname "$0")"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
PP="$(mktemp)"
trap 'rm -f "$PP"' EXIT
printf '{"executablePath":"%s"}' "$CHROME" > "$PP"
if [ $# -gt 0 ]; then set -- "$1.mmd"; else set -- *.mmd; fi
for src in "$@"; do
  name="${src%.mmd}"
  PUPPETEER_SKIP_DOWNLOAD=1 npx -y @mermaid-js/mermaid-cli@11.4.2 -q \
    -p "$PP" -c mermaid.json -b white -i "$src" -o "../diagram-$name.svg"
  echo "docs/diagram-$name.svg"
done
