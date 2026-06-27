#!/bin/bash
# Dev loop: `swift build` + run, with the MLX metallib copied next to the
# binary (SwiftPM cannot compile Metal shaders itself). Requires one prior
# ./Scripts/make-app.sh run to produce the metallib via xcodebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build

BIN_DIR=.build/arm64-apple-macosx/debug
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

exec "$BIN_DIR/Pretype" "$@"
