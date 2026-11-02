#!/bin/bash
# Dev loop: `swift build` + run. Swift Build compiles MLX's Metal shaders into
# mlx-swift_Cmlx.bundle next to the binary (with the Metal Toolchain
# component: `xcodebuild -downloadComponent MetalToolchain`). On Xcode 26 the
# default native build system compiles no shaders, hence the flag.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build --build-system swiftbuild

# Ask SwiftPM: newer toolchains build into .build/out/Products/Debug, and a
# hardcoded arch path would silently run a stale binary from an older build.
BIN_DIR=$(swift build --build-system swiftbuild --show-bin-path)

# Community per-app styles, where Bundle.main looks for them on a bare binary.
rm -rf "$BIN_DIR/AppStyles" && cp -R AppStyles "$BIN_DIR/AppStyles"

# UI translations, next to the bare binary for the same reason.
for catalog in Localization/*.xcstrings; do
    xcrun xcstringstool compile "$catalog" --output-directory "$BIN_DIR"
done

exec "$BIN_DIR/Pretype" "$@"
