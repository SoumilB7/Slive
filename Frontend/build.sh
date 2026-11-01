#!/bin/bash
# Build Slive.app from the Swift package and assemble a proper macOS app bundle.
# Usage: ./build.sh            (build + bundle)
#        ./build.sh run        (build + bundle + launch from build/)
#        ./build.sh install    (build + bundle + copy to /Applications + launch)
set -euo pipefail

cd "$(dirname "$0")"
FRONTEND_DIR="$(pwd)"
REPO_DIR="$(cd .. && pwd)"
CONFIG="release"

# SDK pin (Command Line Tools only — no Xcode). From the macOS 27 SDK on,
# SwiftUI's @State/@Observable are compiler MACROS whose plugin
# (SwiftUIMacros) ships only with Xcode, so the default CLT SDK can't build
# this app ("plugin for module 'SwiftUIMacros' not found"). When the plugin
# is missing, build against the newest installed SDK older than 27.
# Override with SLIVE_SDKROOT=/path/to/MacOSX…sdk.
if [[ -n "${SLIVE_SDKROOT:-}" ]]; then
    export SDKROOT="$SLIVE_SDKROOT"
elif [[ -z "${SDKROOT:-}" ]]; then
    TOOLCHAIN_PLUGINS="$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins"
    SDK_MAJOR="$(xcrun --show-sdk-version | cut -d. -f1)"
    if (( SDK_MAJOR >= 27 )) && ! ls "$TOOLCHAIN_PLUGINS" 2>/dev/null | grep -q SwiftUIMacros; then
        SDK_DIR="$(dirname "$(xcrun --show-sdk-path)")"
        PINNED="$(ls -d "$SDK_DIR"/MacOSX[0-9]*.[0-9]*.sdk 2>/dev/null \
            | sed -E 's|.*/MacOSX([0-9]+)\.([0-9]+)\.sdk$|\1 \2 &|' \
            | awk '$1 < 27' | sort -k1,1n -k2,2n | tail -1 | cut -d' ' -f3)"
        if [[ -n "$PINNED" ]]; then
            export SDKROOT="$PINNED"
            echo "▸ SDK $SDK_MAJOR needs Xcode's SwiftUI macros — building against $(basename "$PINNED")"
        else
            echo "✗ No pre-27 macOS SDK found and SwiftUIMacros is missing — install Xcode or an older CLT SDK." >&2
            exit 1
        fi
    fi
fi

echo "▸ Compiling (swift build -c $CONFIG)…"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/Slive"
APP="build/Slive.app"
CONTENTS="$APP/Contents"

echo "▸ Assembling app bundle…"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/Slive"

# Bake absolute paths into Info.plist: the Backend/ dir whose .venv runs the
# transcription server (auto-launched by the app), and the prompts folder.
# Release builds (`./build.sh release lite|full`, used by scripts/make-dmg.sh)
# carry everything inside the app — no paths into this repo. Dev builds keep
# using the repo's Backend/.venv and prompts.
VERSION="$(<"$REPO_DIR/VERSION")"
BUILD_SHA="$(git -C "$REPO_DIR" rev-parse --short HEAD)"
EDITION="${SLIVE_EDITION:-full}"; BUNDLED="0"   # SLIVE_EDITION=lite: no Python features
BACKEND_DIR="$REPO_DIR/Backend"
PROMPTS_DIR="$REPO_DIR/Backend/prompts"
if [[ "${1:-}" == "release" ]]; then
    EDITION="${2:?usage: build.sh release lite|full}"
    [[ "$EDITION" == lite || "$EDITION" == full ]] || { echo "✗ edition must be lite or full" >&2; exit 1; }
    [[ "$EDITION" == full ]] && BUNDLED="1"
    BACKEND_DIR=""; PROMPTS_DIR=""
else
    mkdir -p "$PROMPTS_DIR"
fi
sed -e "s|__BACKEND_DIR__|$BACKEND_DIR|g" \
    -e "s|__PROMPTS_DIR__|$PROMPTS_DIR|g" \
    -e "s|__VERSION__|$VERSION|g" \
    -e "s|__EDITION__|$EDITION|g" \
    -e "s|__BUNDLED__|$BUNDLED|g" \
    -e "s|__BUILD__|$BUILD_SHA|g" \
    Resources/Info.plist.template > "$CONTENTS/Info.plist"

if [[ "$BUNDLED" == "1" ]]; then
    # The Python server, self-contained: uv's standalone CPython (the one the
    # repo venv is built on), the venv's installed packages, and the server
    # source. The interpreter ships pre-named "Slive Server" (Activity Monitor).
    echo "▸ Bundling the Python server…"
    PY_HOME="$(sed -n 's/^home = //p' "$REPO_DIR/Backend/.venv/pyvenv.cfg")"
    PY_ROOT="$(dirname "$PY_HOME")"
    PY_VER="$(sed -n 's/^version_info = \([0-9]*\.[0-9]*\).*/\1/p' "$REPO_DIR/Backend/.venv/pyvenv.cfg")"
    B="$CONTENTS/Resources/backend"
    mkdir -p "$B/python" "$B/site-packages" "$B/src"
    rsync -a --exclude "include/" --exclude "share/" --exclude "lib/python$PY_VER/test/" \
        --exclude "lib/python$PY_VER/idlelib/" --exclude "lib/python$PY_VER/tkinter/" \
        "$PY_ROOT/" "$B/python/"
    cp "$B/python/bin/python$PY_VER" "$B/python/bin/Slive Server"
    rsync -a --exclude "_editable_impl_flowy.pth" --exclude "_virtualenv.pth" \
        --exclude "pytest*" --exclude "_pytest/" --exclude "ruff*" \
        "$REPO_DIR/Backend/.venv/lib/python$PY_VER/site-packages/" "$B/site-packages/"
    rsync -a --exclude "__pycache__/" "$REPO_DIR/Backend/src/" "$B/src/"
    mkdir -p "$CONTENTS/Resources/prompts"
    cp "$REPO_DIR"/Backend/prompts/*.md "$CONTENTS/Resources/prompts/" 2>/dev/null || true
fi

# App icon.
if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"
fi

# Bundle the default (tiny) transcription model + tokenizer so first launch needs
# no download and works fully offline.
# Speech clip for the post-load warm-up (a silent warm-up is a no-op: Whisper
# skips it in ~10ms, leaving the first real dictation to pay the setup).
if [[ -f Resources/WarmUp.wav ]]; then
    cp Resources/WarmUp.wav "$CONTENTS/Resources/WarmUp.wav"
fi

if [[ -d Resources/BundledModels ]]; then
    cp -R Resources/BundledModels "$CONTENTS/Resources/BundledModels"
fi
if [[ -d Resources/BundledTokenizers ]]; then
    cp -R Resources/BundledTokenizers "$CONTENTS/Resources/BundledTokenizers"
fi

# Prefer a stable self-signed identity if the user created one — then macOS TCC
# (Microphone / Input Monitoring) remembers grants across REBUILDS, not just
# relaunches. Falls back to ad-hoc otherwise (grants reset on each rebuild).
# To create the identity, see: Frontend/setup-signing.sh
SIGN_ID="Slive Local Signing"
[[ "${1:-}" == "release" ]] && SIGN_ID="(ad-hoc for release)"   # never a local identity in a DMG
ENTITLEMENTS="Slive.entitlements"   # audio-input entitlement (mic under Hardened Runtime)
# Detect by certificate presence, not `find-identity -p codesigning` — the
# latter hides untrusted self-signed certs even though codesign can use them.
# Try the default search list AND the login keychain explicitly (more robust).
if security find-certificate -c "$SIGN_ID" >/dev/null 2>&1 \
   || security find-certificate -c "$SIGN_ID" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1; then
    SIGN_ARGS=(--sign "$SIGN_ID")
    echo "▸ Signing with stable identity: $SIGN_ID"
else
    SIGN_ARGS=(--sign -)
    echo "▸ Signing (ad-hoc — grants reset on rebuild; run setup-signing.sh for persistence)"
fi
# --options runtime = Hardened Runtime (blocks code injection). The entitlements
# file grants microphone access under that runtime — without it the mic is silent.
if [[ "${1:-}" == "release" ]]; then
    # Bundled Python first: every Mach-O, ad-hoc and WITHOUT the hardened
    # runtime (library validation would refuse its extension modules), then
    # the app itself, which seals all of it — no --deep, so nested code keeps
    # its own signature.
    if [[ -d "$CONTENTS/Resources/backend" ]]; then
        echo "▸ Signing the bundled Python…"
        find "$CONTENTS/Resources/backend" -type f \( -name "*.so" -o -name "*.dylib" -o -perm -u+x \) -print0 \
            | xargs -0 -n 64 -P 8 codesign --force --sign - >/dev/null 2>&1 || true
    fi
    codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign - "$APP"
else
    codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" "${SIGN_ARGS[@]}" "$APP" >/dev/null 2>&1 || {
        echo "  (codesign warning ignored)"
    }
fi

echo "✓ Built: $APP"

LAUNCH_TARGET="$APP"

if [[ "${1:-}" == "install" ]]; then
    DEST="/Applications/Slive.app"
    echo "▸ Installing to $DEST …"
    pkill -x Slive 2>/dev/null || true
    sleep 0.3
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    # Re-sign the installed copy with the same identity + runtime + entitlements.
    codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" "${SIGN_ARGS[@]}" "$DEST" >/dev/null 2>&1 || true
    # Remove the throwaway build/ bundle entirely so it can never appear as a
    # duplicate app. (LaunchServices re-discovers any .app bundle on disk, so
    # unregistering isn't enough — the bundle itself must go.)
    LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
    "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
    rm -rf "$APP"
    LAUNCH_TARGET="$DEST"
    echo "✓ Installed: $DEST (single copy — no duplicates)"
fi

# Compile the models for THIS binary before launch. macOS keys its compiled
# Neural Engine programs to the exact binary, so the first launch of any new
# build spends ~1–2 min compiling Whisper — and no dictation can run until it
# finishes. Doing it here means the app opens ready. SLIVE_SKIP_PREPARE=1 skips.
if [[ ( "${1:-}" == "run" || "${1:-}" == "install" ) && -z "${SLIVE_SKIP_PREPARE:-}" ]]; then
    echo "▸ Preparing the speech model for this build (Neural Engine compile, ~1–2 min when the code changed)…"
    pkill -x Slive 2>/dev/null || true
    PREP_START=$(date +%s)
    "$LAUNCH_TARGET/Contents/MacOS/Slive" --prepare-models 2>/dev/null | grep -E "^  " || true
    echo "✓ Model ready in $(( $(date +%s) - PREP_START ))s — the first dictation will be instant."
fi

if [[ "${1:-}" == "run" || "${1:-}" == "install" ]]; then
    echo "▸ Launching…"
    pkill -x Slive 2>/dev/null || true
    sleep 0.3
    open "$LAUNCH_TARGET"
    echo "✓ Slive is running in your menu bar. Open Settings to pick your key & grant permissions."
fi
