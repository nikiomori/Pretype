#!/bin/bash
# Package Pretype.app for distribution: hardened-runtime sign, notarize,
# staple. Recipients just open the app. It needs a "Developer ID Application"
# certificate in the keychain; notary credentials come from the keychain
# profile "pretype" (one-time local setup:
#   xcrun notarytool store-credentials pretype
# ).
#
# Run it as PRETYPE_VERSION=X.Y.Z ./Scripts/dist.sh (docs/RELEASING.md). It
# builds the app itself through make-app.sh, whose release guard refuses a
# dirty tree or a HEAD that isn't tag vX.Y.Z. There is no path that signs an
# existing build/Pretype.app: a dev build left there would ship notarized.
#
# Intel Macs are not supported — Pretype needs Apple Silicon (MLX).
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${PRETYPE_VERSION:-}" ]; then
    echo "Refusing to package: set PRETYPE_VERSION=X.Y.Z. dist.sh signs only what it builds from tag vX.Y.Z (docs/RELEASING.md)."
    exit 1
fi
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ {print $2; exit}')
# An ad-hoc zip is blocked by Gatekeeper, and its new signature silently
# voids every user's Accessibility grant. Checked before the build.
if [ -z "$IDENTITY" ]; then
    echo "Refusing to package: no \"Developer ID Application\" identity in the keychain."
    exit 1
fi
# Built here, under make-app.sh's release guard — never taken from whatever
# build/Pretype.app a dev build left.
./Scripts/make-app.sh

DIST=build/dist
rm -rf "$DIST"; mkdir -p "$DIST"
cp -R build/Pretype.app "$DIST/Pretype.app"
rm -f build/Pretype.app.zip

# Hardened runtime + secure timestamp are notarization requirements.
# Single binary + resource-only bundles, so there is no nested code to sign.
# The entitlements are what let the hardened runtime open the microphone
# (dictation) — it denies it by default regardless of the TCC grant.
codesign --force --options runtime --timestamp \
    --entitlements Scripts/Pretype.entitlements --sign "$IDENTITY" "$DIST/Pretype.app"
codesign --verify --strict "$DIST/Pretype.app"

ditto -c -k --keepParent "$DIST/Pretype.app" build/Pretype.app.zip
# On a rejected submission --wait exits non-zero; the printed id feeds
# `xcrun notarytool log <id>` for the reason. A dropped --wait leaves the
# submission running on the server: docs/RELEASING.md has the recovery.
xcrun notarytool submit build/Pretype.app.zip --wait --keychain-profile pretype

# Staple the ticket so Gatekeeper passes offline, then re-zip the stapled app.
xcrun stapler staple "$DIST/Pretype.app"
rm build/Pretype.app.zip
ditto -c -k --keepParent "$DIST/Pretype.app" build/Pretype.app.zip
spctl -a -t exec -vv "$DIST/Pretype.app"
echo "Built build/Pretype.app.zip ($(du -h build/Pretype.app.zip | cut -f1), notarized + stapled)."
