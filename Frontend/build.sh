#!/bin/bash
# Build Flowy.app from the Swift package and assemble a proper macOS app bundle.
# Usage: ./build.sh          (build + bundle)
#        ./build.sh run      (build + bundle + launch)
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

# Ad-hoc code signing gives the bundle a stable identity so macOS TCC
# (Microphone / Accessibility permissions) remembers the grant across launches.
echo "▸ Signing (ad-hoc)…"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || {
    echo "  (codesign warning ignored — ad-hoc signing is best-effort)"
}

echo "✓ Built: $APP"
echo "  Audios → $AUDIOS_DIR"

if [[ "${1:-}" == "run" ]]; then
    echo "▸ Launching…"
    # Kill any prior instance, then open fresh.
    pkill -x Flowy 2>/dev/null || true
    sleep 0.3
    open "$APP"
    echo "✓ Flowy is running in the menu bar. Hold the fn (🌐) key to talk."
fi
