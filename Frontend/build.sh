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

# Ad-hoc code signing gives the bundle a stable identity so macOS TCC
# (Microphone / Accessibility permissions) remembers the grant across launches.
echo "▸ Signing (ad-hoc)…"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || {
    echo "  (codesign warning ignored — ad-hoc signing is best-effort)"
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
    # Re-sign in place so the installed copy has a valid signature.
    codesign --force --deep --sign - "$DEST" >/dev/null 2>&1 || true
    LAUNCH_TARGET="$DEST"
    echo "✓ Installed: $DEST"
fi

if [[ "${1:-}" == "run" || "${1:-}" == "install" ]]; then
    echo "▸ Launching…"
    pkill -x Flowy 2>/dev/null || true
    sleep 0.3
    open "$LAUNCH_TARGET"
    echo "✓ Flowy is running in your menu bar. Open Settings to pick your key & grant permissions."
fi
