#!/bin/bash
# Build Slive.app from the Swift package and assemble a proper macOS app bundle.
# Usage: ./build.sh [build]    (build + bundle; the default)
#        ./build.sh run        (build + bundle + launch from build/)
#        ./build.sh install    (build + bundle + copy to /Applications, or ~/Applications for non-admins + launch)
#        ./build.sh test       (build + run SliveSelfTest and Slive --self-test, no bundle)
#        ./build.sh check [--burst N] [--seed S] [--only F] [...]
#                              the Gauntlet gate, in order: static guards (before compiling) →
#                              release build → `Slive --gauntlet [flags]` → Backend
#                              `pytest -m gauntlet` (skipped with a note until a test carries the
#                              marker). Flags after `check` go to `Slive --gauntlet`; see its --help
#                              text: --burst N fans N seeds over every core, --seed S replays one
#                              seed, --only F runs one family. Exits non-zero on the first failure.
#        ./build.sh install    runs `check` first (any flags too) and installs only if it passes.
#                              SLIVE_SKIP_CHECK=1 skips that (hotfix builds).
# The steps live in scripts/lib/: bundle.sh, sign.sh, install.sh, prepare.sh, test.sh, check.sh.
set -euo pipefail

cd "$(dirname "$0")"
FRONTEND_DIR="$(pwd)"
REPO_DIR="$(cd .. && pwd)"
CONFIG="release"
MODE="${1:-build}"
case "$MODE" in
    build|run|install|test|check) ;;
    *) echo "usage: ./build.sh [build|run|install|test|check [gauntlet flags]]" >&2; exit 1 ;;
esac
if [[ $# -gt 0 ]]; then shift; fi
# What follows the mode goes to `Slive --gauntlet` (check, and install's check).
CHECK_ARGS=("$@")

RUN_CHECK=0
if [[ "$MODE" == "check" || ( "$MODE" == "install" && "${SLIVE_SKIP_CHECK:-}" != "1" ) ]]; then
    RUN_CHECK=1
fi

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

source "$FRONTEND_DIR/scripts/lib/check.sh"
if (( RUN_CHECK )); then run_guards || exit 1; fi

echo "▸ Compiling (swift build -c $CONFIG)…"
swift build -c "$CONFIG"

if (( RUN_CHECK )); then
    run_gauntlet ${CHECK_ARGS[@]+"${CHECK_ARGS[@]}"} || exit 1
    run_backend_gauntlet || exit 1
    if [[ "$MODE" == "check" ]]; then echo "✓ check passed"; exit 0; fi
fi

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
