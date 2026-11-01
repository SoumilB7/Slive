#!/bin/bash
# Build Slive.app from the Swift package and assemble a proper macOS app bundle.
# Usage: ./build.sh [build]    (build + bundle; the default)
#        ./build.sh run        (build + bundle + launch from build/)
#        ./build.sh install    (build + bundle + copy to /Applications, or ~/Applications for non-admins + launch)
#        ./build.sh test       (build + run SliveSelfTest and Slive --self-test, no bundle)
# The steps live in scripts/lib/: bundle.sh, sign.sh, install.sh, prepare.sh, test.sh.
set -euo pipefail

cd "$(dirname "$0")"
FRONTEND_DIR="$(pwd)"
REPO_DIR="$(cd .. && pwd)"
CONFIG="release"
MODE="${1:-build}"
case "$MODE" in
    build|run|install|test) ;;
    *) echo "usage: ./build.sh [build|run|install|test]" >&2; exit 1 ;;
esac

# Swift 6+ and an SDK this app can build against — see toolchain.sh (shared
# with install.sh). Override the SDK with SLIVE_SDKROOT=/path/to/MacOSX…sdk.
source "$FRONTEND_DIR/toolchain.sh"
slive_toolchain_check || { echo "✗ $SLIVE_TOOLCHAIN_ERROR" >&2; exit 1; }
if [[ -n "${SLIVE_SDKROOT:-}" ]]; then
    export SDKROOT="$SLIVE_SDKROOT"
elif [[ -n "$SLIVE_PINNED_SDK" ]]; then
    echo "▸ SDK $(xcrun --show-sdk-version | cut -d. -f1) needs Xcode's SwiftUI macros — building against $(basename "$SLIVE_PINNED_SDK")"
    export SDKROOT="$SLIVE_PINNED_SDK"
fi

echo "▸ Compiling (swift build -c $CONFIG)…"
swift build -c "$CONFIG"

if [[ "$MODE" == "test" ]]; then
    source "$FRONTEND_DIR/scripts/lib/test.sh"
    run_self_tests
    exit
fi

APP="build/Slive.app"
CONTENTS="$APP/Contents"

source "$FRONTEND_DIR/scripts/lib/bundle.sh"
source "$FRONTEND_DIR/scripts/lib/sign.sh"
source "$FRONTEND_DIR/scripts/lib/install.sh"
source "$FRONTEND_DIR/scripts/lib/prepare.sh"

assemble_bundle
detect_signing_identity
sign_app "$APP"
echo "✓ Built: $APP"

LAUNCH_TARGET="$APP"
[[ "$MODE" == "install" ]] && install_app
[[ "$MODE" == "run" || "$MODE" == "install" ]] && prepare_models

if [[ "$MODE" == "run" || "$MODE" == "install" ]]; then
    echo "▸ Launching…"
    pkill -x Slive 2>/dev/null || true
    sleep 0.3
    open "$LAUNCH_TARGET"
    echo "✓ Slive is running in your menu bar. Open Settings to pick your key & grant permissions."
fi
