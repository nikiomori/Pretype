#!/bin/bash
# Builds Pretype and wraps it into a minimal .app bundle so macOS grants
# Accessibility permission to the app itself (not your terminal).
#
# NOTE: the build goes through xcodebuild, not `swift build` — the MLX engine
# needs Metal shaders compiled into mlx.metallib, which SwiftPM cannot do
# (documented limitation of mlx-swift).
set -euo pipefail
cd "$(dirname "$0")/.."

if ! xcrun metal --version >/dev/null 2>&1; then
    echo "Metal Toolchain is missing (needed to compile MLX shaders)."
    echo "Install it once with: xcodebuild -downloadComponent MetalToolchain"
    exit 1
fi

# -skipMacroValidation: mlx-swift-lm uses Swift macros, which xcodebuild
# refuses to run from the command line without this flag.
xcodebuild -scheme Pretype -configuration Release -destination 'platform=macOS' \
    -derivedDataPath .build/xcode -skipMacroValidation -skipPackagePluginValidation \
    build | grep -E "BUILD|error" || true

PRODUCTS=.build/xcode/Build/Products/Release
test -x "$PRODUCTS/Pretype" || { echo "Build failed: $PRODUCTS/Pretype not found"; exit 1; }

APP=build/Pretype.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Version: PRETYPE_VERSION wins (CI passes the pushed git tag); otherwise derive
# from the latest local tag, else a dev fallback. CFBundleVersion is a monotonic
# build number (CI passes the run number; locally it's the commit count).
VERSION="${PRETYPE_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')}"
VERSION="${VERSION:-0.1.0}"
BUILD="${PRETYPE_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Pretype</string>
    <key>CFBundleIdentifier</key><string>app.pretype.Pretype</string>
    <key>CFBundleName</key><string>Pretype</string>
    <key>CFBundleIconFile</key><string>Pretype</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

cp "$PRODUCTS/Pretype" "$APP/Contents/MacOS/Pretype"

# App icon (Finder + About panel; the app is LSUIElement so there's no Dock icon).
if [ -f Assets/Pretype.icns ]; then
    cp Assets/Pretype.icns "$APP/Contents/Resources/Pretype.icns"
else
    echo "warning: Assets/Pretype.icns not found — app will have no icon"
fi

# MLX finds its compiled shaders (default.metallib) inside
# mlx-swift_Cmlx.bundle via the main bundle's Resources directory.
# The metallib must NOT go into Contents/MacOS — codesign rejects
# non-executable files there.
for bundle in "$PRODUCTS"/*.bundle; do
    [ -d "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done
if ! find "$APP/Contents/Resources/mlx-swift_Cmlx.bundle" -name "default.metallib" | grep -q .; then
    echo "warning: default.metallib not found in Cmlx bundle — MLX engine will not work"
fi

# A stable signing identity keeps the TCC permission grants (Accessibility,
# Screen Recording) valid across rebuilds. Ad-hoc signatures change with
# every build and silently invalidate them.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')
if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" "$APP"
    echo "Signed with: $IDENTITY — permissions survive rebuilds"
else
    codesign --force --sign - "$APP"
    echo "Ad-hoc signed — re-grant Accessibility/Screen Recording after each rebuild"
fi
echo "Built $APP (version ${VERSION}, build ${BUILD})"
