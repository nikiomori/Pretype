#!/bin/bash
# Package Pretype.app for distribution.
#
# Two modes, picked by what's in the keychain:
#   - "Developer ID Application" certificate present -> hardened-runtime sign,
#     notarize, staple. Recipients just open the app. Notary credentials come
#     from the keychain profile "pretype" (one-time local setup:
#       xcrun notarytool store-credentials pretype
#     ).
#   - no such certificate -> ad-hoc signature; recipients clear Gatekeeper
#     once (see the printed steps).
#
# A release sets PRETYPE_VERSION=X.Y.Z (docs/RELEASING.md). Then there is no
# ad-hoc fallback, and this script builds the app itself through make-app.sh,
# whose release guard refuses a dirty tree or a HEAD that isn't tag vX.Y.Z.
#
# Intel Macs are not supported — Pretype needs Apple Silicon (MLX).
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ {print $2; exit}')
if [ -n "${PRETYPE_VERSION:-}" ]; then
    # An ad-hoc release is blocked by Gatekeeper, and its new signature
    # silently voids every user's Accessibility grant. Checked before the build.
    if [ -z "$IDENTITY" ]; then
        echo "Refusing a release: no \"Developer ID Application\" identity in the keychain."
        exit 1
    fi
    # Built here, never taken from whatever build/Pretype.app a dev build left.
    ./Scripts/make-app.sh
fi

test -d build/Pretype.app || { echo "build/Pretype.app not found — run ./Scripts/make-app.sh first."; exit 1; }

DIST=build/dist
rm -rf "$DIST"; mkdir -p "$DIST"
cp -R build/Pretype.app "$DIST/Pretype.app"
rm -f build/Pretype.app.zip

if [ -n "$IDENTITY" ]; then
    # Hardened runtime + secure timestamp are notarization requirements.
    # Single binary + resource-only bundles, so there is no nested code to sign.
    # The entitlements are what let the hardened runtime open the microphone
    # (dictation) — it denies it by default regardless of the TCC grant.
    codesign --force --options runtime --timestamp \
        --entitlements Scripts/Pretype.entitlements --sign "$IDENTITY" "$DIST/Pretype.app"
    codesign --verify --strict "$DIST/Pretype.app"

    ditto -c -k --keepParent "$DIST/Pretype.app" build/Pretype.app.zip
    # On a rejected submission --wait exits non-zero; the printed id feeds
    # `xcrun notarytool log <id>` for the reason.
    xcrun notarytool submit build/Pretype.app.zip --wait --keychain-profile pretype

    # Staple the ticket so Gatekeeper passes offline, then re-zip the stapled app.
    xcrun stapler staple "$DIST/Pretype.app"
    rm build/Pretype.app.zip
    ditto -c -k --keepParent "$DIST/Pretype.app" build/Pretype.app.zip
    spctl -a -t exec -vv "$DIST/Pretype.app"
    echo "Built build/Pretype.app.zip ($(du -h build/Pretype.app.zip | cut -f1), notarized + stapled)."
    exit 0
fi

# No Developer ID certificate: strip the device-locked dev signature, re-sign
# ad-hoc (runs on any Apple Silicon Mac).
codesign --force --deep --sign - "$DIST/Pretype.app"
codesign --verify --deep --strict "$DIST/Pretype.app"

ditto -c -k --keepParent "$DIST/Pretype.app" build/Pretype.app.zip
echo "Built build/Pretype.app.zip ($(du -h build/Pretype.app.zip | cut -f1), ad-hoc signed)."

cat <<'EOF'

Send build/Pretype.app.zip to testers (Apple Silicon, macOS 26+). To open it once:

  xattr -dr com.apple.quarantine /path/to/Pretype.app && open /path/to/Pretype.app

  ...or without Terminal: double-click -> "blocked" -> System Settings ->
  Privacy & Security -> scroll down -> "Open Anyway".

Then grant Accessibility (and optionally Screen Recording) when prompted. The app
is not notarized (that needs a paid Apple Developer account); with a
"Developer ID Application" certificate in the keychain this script notarizes
automatically instead.
EOF
