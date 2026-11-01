#!/bin/zsh
# Builds a release Slive.app and packs it into a DMG: the app beside a link to
# /Applications, so installing is one drag. Writes the DMG's SHA-256 next to it.
#
#   scripts/make-dmg.sh lite   →  build/Slive-<version>.dmg       (Swift app + on-device speech)
#   scripts/make-dmg.sh full   →  build/Slive-Full-<version>.dmg  (+ the bundled Python server)
#
# The built app stays at build/Slive-<edition>.app for scripts/release.sh's checks.
set -euo pipefail

cd "${0:A:h}/.."
EDITION="${1:?usage: scripts/make-dmg.sh lite|full}"
VERSION="$(<../VERSION)"
case $EDITION in
    lite) NAME="Slive-$VERSION";      VOLUME="Slive $VERSION" ;;
    full) NAME="Slive-Full-$VERSION"; VOLUME="Slive Full $VERSION" ;;
    *) print -u2 "edition must be lite or full"; exit 1 ;;
esac
DMG="build/$NAME.dmg"
STAGE="build/dmg-$EDITION"
APP="build/Slive-$EDITION.app"

./build.sh release "$EDITION"

rm -rf "$STAGE" "$DMG" "$APP"
mkdir -p "$STAGE"
mv build/Slive.app "$STAGE/Slive.app"          # moved, not copied: the Full app is ~1.4 GB
ln -s /Applications "$STAGE/Applications"
cp "$STAGE/Slive.app/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"

# Made writable first: the volume's custom-icon flag only sticks when set on the mounted volume.
RW="build/$NAME-rw.dmg"
hdiutil create -quiet -volname "$VOLUME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW"
mv "$STAGE/Slive.app" "$APP"
rm -rf "$STAGE"
MNT="$(mktemp -d)"
hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$MNT" "$RW"
SetFile -a C "$MNT" 2>/dev/null || true
hdiutil detach -quiet "$MNT"
rmdir "$MNT"
hdiutil convert -quiet "$RW" -format UDZO -o "$DMG"
rm -f "$RW"
codesign --force --sign - "$DMG"

(cd build && shasum -a 256 "$NAME.dmg" > "$NAME.dmg.sha256")
echo "built $DMG"
cat "$DMG.sha256"
