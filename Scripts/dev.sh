#!/bin/bash
# Dev loop: `swift build` + run, with the MLX metallib copied next to the
# binary (SwiftPM cannot compile Metal shaders itself). Requires one prior
# ./Scripts/make-app.sh run to produce the metallib via xcodebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build

# Ask SwiftPM: newer toolchains build into .build/out/Products/Debug, and a
# hardcoded arch path would silently run a stale binary from an older build.
BIN_DIR=$(swift build --show-bin-path)
if [ ! -f "$BIN_DIR/mlx.metallib" ]; then
    METALLIB=$(find .build/xcode/Build/Products -name "default.metallib" -path "*Cmlx*" 2>/dev/null | head -1)
    if [ -n "$METALLIB" ]; then
        cp "$METALLIB" "$BIN_DIR/mlx.metallib"
        echo "Copied mlx.metallib next to the dev binary."
    else
        echo "warning: mlx.metallib not found — MLX engine will be disabled."
        echo "Run ./Scripts/make-app.sh once to build the Metal shaders."
    fi
fi

# Community per-app styles, where Bundle.main looks for them on a bare binary.
rm -rf "$BIN_DIR/AppStyles" && cp -R AppStyles "$BIN_DIR/AppStyles"

exec "$BIN_DIR/Pretype" "$@"
