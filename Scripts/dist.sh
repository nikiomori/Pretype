#!/bin/bash
# Package Pretype.app for testers who DON'T have a paid Apple Developer account.
#
# make-app.sh signs with your "Apple Development" certificate, which is locked to
# your own devices — on someone else's Mac that fails with
#   "…can't be opened because this application is not supported on this Mac".
# This re-signs a COPY ad-hoc (your local build/Pretype.app keeps its dev
# signature, so your own Accessibility / Screen-Recording grants survive) and
# zips it for sharing.
#
# Recipients clear Gatekeeper once (see the printed steps). Intel Macs are not
# supported — Pretype needs Apple Silicon (MLX).
set -euo pipefail
cd "$(dirname "$0")/.."

test -d build/Pretype.app || { echo "build/Pretype.app not found — run ./Scripts/make-app.sh first."; exit 1; }

DIST=build/dist
rm -rf "$DIST"; mkdir -p "$DIST"
cp -R build/Pretype.app "$DIST/Pretype.app"

# Strip the device-locked dev signature, re-sign ad-hoc (runs on any Apple Silicon Mac).
codesign --force --deep --sign - "$DIST/Pretype.app"
codesign --verify --deep --strict "$DIST/Pretype.app"

rm -f build/Pretype.app.zip
ditto -c -k --keepParent "$DIST/Pretype.app" build/Pretype.app.zip
echo "Built build/Pretype.app.zip ($(du -h build/Pretype.app.zip | cut -f1), ad-hoc signed)."

cat <<'EOF'

Send build/Pretype.app.zip to testers (Apple Silicon, macOS 14+). To open it once:

  xattr -dr com.apple.quarantine /path/to/Pretype.app && open /path/to/Pretype.app

  ...or without Terminal: double-click -> "blocked" -> System Settings ->
  Privacy & Security -> scroll down -> "Open Anyway".

Then grant Accessibility (and optionally Screen Recording) when prompted. The app
is not notarized (that needs a paid Apple Developer account), so this one-time
override is expected. For public distribution later, switch to a Developer ID
certificate + notarytool.
EOF
