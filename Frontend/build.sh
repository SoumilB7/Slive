#!/bin/bash
# Build Flowy.app from the Swift package and assemble a proper macOS app bundle.
# Usage: ./build.sh            (build + bundle)
#        ./build.sh run        (build + bundle + launch from build/)
#        ./build.sh install    (build + bundle + copy to /Applications + launch)
set -euo pipefail

cd "$(dirname "$0")"
FRONTEND_DIR="$(pwd)"
REPO_DIR="$(cd .. && pwd)"
AUDIOS_DIR="$REPO_DIR/Audios"
CONFIG="release"

echo "▸ Compiling (swift build -c $CONFIG)…"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/Flowy"
APP="build/Flowy.app"
CONTENTS="$APP/Contents"

echo "▸ Assembling app bundle…"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/Flowy"

# Bake the absolute Audios path into Info.plist so the app knows where to save.
mkdir -p "$AUDIOS_DIR"
sed "s|__AUDIOS_DIR__|$AUDIOS_DIR|g" Resources/Info.plist.template > "$CONTENTS/Info.plist"

# App icon.
if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"
fi

# Prefer a stable self-signed identity if the user created one — then macOS TCC
# (Microphone / Input Monitoring) remembers grants across REBUILDS, not just
# relaunches. Falls back to ad-hoc otherwise (grants reset on each rebuild).
# To create the identity, see: Frontend/setup-signing.sh
SIGN_ID="Flowy Local Signing"
ENTITLEMENTS="Flowy.entitlements"   # audio-input entitlement (mic under Hardened Runtime)
# Detect by certificate presence, not `find-identity -p codesigning` — the
# latter hides untrusted self-signed certs even though codesign can use them.
if security find-certificate -c "$SIGN_ID" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1; then
    SIGN_ARGS=(--sign "$SIGN_ID")
    echo "▸ Signing with stable identity: $SIGN_ID"
else
    SIGN_ARGS=(--sign -)
    echo "▸ Signing (ad-hoc — grants reset on rebuild; run setup-signing.sh for persistence)"
fi
# --options runtime = Hardened Runtime (blocks code injection). The entitlements
# file grants microphone access under that runtime — without it the mic is silent.
codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" "${SIGN_ARGS[@]}" "$APP" >/dev/null 2>&1 || {
    echo "  (codesign warning ignored)"
}

echo "✓ Built: $APP"
echo "  Audios → $AUDIOS_DIR"

LAUNCH_TARGET="$APP"

if [[ "${1:-}" == "install" ]]; then
    DEST="/Applications/Flowy.app"
    echo "▸ Installing to $DEST …"
    pkill -x Flowy 2>/dev/null || true
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

if [[ "${1:-}" == "run" || "${1:-}" == "install" ]]; then
    echo "▸ Launching…"
    pkill -x Flowy 2>/dev/null || true
    sleep 0.3
    open "$LAUNCH_TARGET"
    echo "✓ Flowy is running in your menu bar. Open Settings to pick your key & grant permissions."
fi
