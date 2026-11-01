#!/bin/bash
# Build Slive.app from the Swift package and assemble a proper macOS app bundle.
# Usage: ./build.sh            (build + bundle)
#        ./build.sh run        (build + bundle + launch from build/)
#        ./build.sh install    (build + bundle + copy to /Applications, or ~/Applications for non-admins + launch)
set -euo pipefail

cd "$(dirname "$0")"
FRONTEND_DIR="$(pwd)"
REPO_DIR="$(cd .. && pwd)"
CONFIG="release"

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
# The commit, "-dirty" when tracked files differ from it (so a local hack never
# passes for that commit in a bug report), and the commit's date.
BUILD_SHA="$(git -C "$REPO_DIR" rev-parse --short HEAD)"
git -C "$REPO_DIR" diff --quiet HEAD -- || BUILD_SHA="$BUILD_SHA-dirty"
BUILD_DATE="$(git -C "$REPO_DIR" log -1 --format=%cI)"
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
# Values land as XML text via sed replacements — escape for both, so a repo
# path holding &, <, | or \ can't corrupt the plist or the sed command.
plist_value() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/[\\&|]/\\&/g'
}
sed -e "s|__BACKEND_DIR__|$(plist_value "$BACKEND_DIR")|g" \
    -e "s|__PROMPTS_DIR__|$(plist_value "$PROMPTS_DIR")|g" \
    -e "s|__VERSION__|$(plist_value "$VERSION")|g" \
    -e "s|__EDITION__|$(plist_value "$EDITION")|g" \
    -e "s|__BUNDLED__|$(plist_value "$BUNDLED")|g" \
    -e "s|__BUILD_DATE__|$(plist_value "$BUILD_DATE")|g" \
    -e "s|__BUILD__|$(plist_value "$BUILD_SHA")|g" \
    Resources/Info.plist.template > "$CONTENTS/Info.plist"

# The problem reporter: its own little app inside Slive, so a frozen or
# crashed Slive can still offer a GitHub issue (Sources/SliveReporter).
REPORTER="$CONTENTS/Helpers/SliveReporter.app/Contents"
mkdir -p "$REPORTER/MacOS"
cp ".build/$CONFIG/SliveReporter" "$REPORTER/MacOS/SliveReporter"
cat > "$REPORTER/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Slive Reporter</string>
    <key>CFBundleIdentifier</key><string>com.slive.app.reporter</string>
    <key>CFBundleExecutable</key><string>SliveReporter</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$(plist_value "$VERSION")</string>
    <key>CFBundleVersion</key><string>$(plist_value "$VERSION")</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

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
# A bad signature means macOS may silence the mic or re-ask for every
# permission, so codesign's complaints are shown, not swallowed.
verify_signature() {
    local out
    out="$(codesign --verify --strict "$1" 2>&1)" && return 0
    printf '%s\n' "$out" | sed 's/^/  /'
    echo "⚠ $1 didn't pass codesign --verify — macOS may block the mic or re-ask for permissions. Run ./setup-signing.sh and build again."
}
sign_app() {
    local out
    out="$(codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" "${SIGN_ARGS[@]}" "$1" 2>&1)" \
        || printf '%s\n' "$out" | sed 's/^/  /'
    verify_signature "$1"
}
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
    codesign --force --options runtime --sign - "$CONTENTS/Helpers/SliveReporter.app"
    codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign - "$APP"
    verify_signature "$APP"
else
    sign_app "$APP"
fi

echo "✓ Built: $APP"

LAUNCH_TARGET="$APP"

if [[ "${1:-}" == "install" ]]; then
    # /Applications when this account may write there; a standard (non-admin)
    # account gets ~/Applications, which needs no password.
    APPS_DIR="/Applications"
    if [[ ! -w "$APPS_DIR" ]]; then
        APPS_DIR="$HOME/Applications"
        mkdir -p "$APPS_DIR"
        echo "▸ /Applications needs an admin account — installing to ~/Applications instead."
    fi
    DEST="$APPS_DIR/Slive.app"
    # Copy in beside the installed app, then swap: a copy that fails (full
    # disk, Ctrl-C) leaves the working Slive untouched. The temp names don't
    # end in .app, so LaunchServices never lists them as a second Slive.
    NEW="$DEST.new"; OLD="$DEST.old"
    echo "▸ Installing to $DEST …"
    rm -rf "$NEW" "$OLD"
    cp -R "$APP" "$NEW" || {
        rm -rf "$NEW"
        echo "✗ Couldn't copy Slive into $APPS_DIR — the installed app is untouched." >&2
        exit 1
    }
    pkill -x Slive 2>/dev/null || true
    sleep 0.3
    if [[ -e "$DEST" ]] && ! mv "$DEST" "$OLD"; then
        rm -rf "$NEW"
        echo "✗ Couldn't replace $DEST — the installed app is untouched." >&2
        exit 1
    fi
    if ! mv "$NEW" "$DEST"; then
        [[ -e "$OLD" ]] && mv "$OLD" "$DEST"
        rm -rf "$NEW"
        echo "✗ Couldn't move the new Slive into place — the installed app is untouched." >&2
        exit 1
    fi
    rm -rf "$OLD"
    # Re-sign the installed copy with the same identity + runtime + entitlements.
    sign_app "$DEST"
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
    # Time-boxed by a watchdog (macOS has no `timeout`), and never fatal: if
    # it fails or hangs, the app still works and compiles on first launch.
    PREP_LIMIT=600
    PREP_LOG="${TMPDIR:-/tmp}/slive-prepare.log"
    PREP_OUT="$(mktemp -t slive-prepare)"
    PREP_START=$(date +%s)
    "$LAUNCH_TARGET/Contents/MacOS/Slive" --prepare-models >"$PREP_OUT" 2>"$PREP_LOG" &
    PREP_PID=$!
    ( for (( i = 0; i < PREP_LIMIT; i++ )); do
          sleep 1; kill -0 "$PREP_PID" 2>/dev/null || exit 0
      done
      kill "$PREP_PID" 2>/dev/null ) &
    WATCHDOG=$!
    disown "$WATCHDOG" 2>/dev/null || true   # no "Terminated" line when it's stopped below
    PREP_STATUS=0; wait "$PREP_PID" || PREP_STATUS=$?
    kill "$WATCHDOG" 2>/dev/null || true
    PREP_SECS=$(( $(date +%s) - PREP_START ))
    grep -E "^  " "$PREP_OUT" || true
    rm -f "$PREP_OUT"
    if (( PREP_STATUS == 0 )); then
        rm -f "$PREP_LOG"
        echo "✓ Model ready in ${PREP_SECS}s — the first dictation will be instant."
    elif (( PREP_SECS >= PREP_LIMIT )); then
        echo "⚠ Model prep passed 10 min and was stopped — Slive compiles it on first launch instead (log: $PREP_LOG)."
    else
        tail -n 5 "$PREP_LOG" | sed 's/^/  /'
        echo "⚠ Model prep failed (exit $PREP_STATUS) — Slive still works and compiles it on first launch (log: $PREP_LOG)."
    fi
fi

if [[ "${1:-}" == "run" || "${1:-}" == "install" ]]; then
    echo "▸ Launching…"
    pkill -x Slive 2>/dev/null || true
    sleep 0.3
    open "$LAUNCH_TARGET"
    echo "✓ Slive is running in your menu bar. Open Settings to pick your key & grant permissions."
fi
