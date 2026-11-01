#!/bin/zsh
# Publishes a DMG from scripts/make-dmg.sh as a GitHub release, with that
# version's CHANGELOG.md section as its notes. Tags HEAD, then deletes the
# local DMG and built app (build/ only) once the release is up.
#
#   scripts/release.sh lite   →  v<version>       "Slive <version>"
#   scripts/release.sh full   →  v<version>-full  "Slive <version> Full"
#   (add --draft to create a draft)
set -euo pipefail

cd "${0:A:h}/.."
EDITION="${1:?usage: scripts/release.sh lite|full [--draft]}"
VERSION="$(<../VERSION)"
case $EDITION in
    lite) TAG="v$VERSION";      TITLE="Slive $VERSION";      NAME="Slive-$VERSION"
          ABOUT="The Slive app with on-device speech (WhisperKit and Parakeet) — dictation and live typing, no Python. The assistant, AI providers, local models, correct-answer labeling and training need the Python server: get **Slive Full** for those." ;;
    full) TAG="v$VERSION-full"; TITLE="Slive $VERSION Full"; NAME="Slive-Full-$VERSION"
          ABOUT="Everything in Slive plus its Python server, bundled (Python 3.13, PyTorch): the assistant, AI providers, local models, correct-answer labeling and training. A larger download; nothing else to install." ;;
    *) print -u2 "edition must be lite or full"; exit 1 ;;
esac
DMG="build/$NAME.dmg"
APP="build/Slive-$EDITION.app"

[[ -f $DMG && -f $DMG.sha256 ]] || { print -u2 "no $DMG: run scripts/make-dmg.sh $EDITION"; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { print -u2 "uncommitted changes: commit first"; exit 1; }
built=$(/usr/libexec/PlistBuddy -c 'Print :SliveBuild' "$APP/Contents/Info.plist")
[[ $built == $(git rev-parse --short HEAD) ]] || { print -u2 "$DMG is from $built, not HEAD: rebuild"; exit 1; }
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { print -u2 "$TAG already exists"; exit 1; }

# The notes: what this download is, this version's section, how to install.
section=$(awk -v v="$VERSION" '
  /^## \[/ { on = index($0, "[" v "]") > 0; next }
  /^\[[0-9.]+\]:/ { next }
  on' ../CHANGELOG.md)
[[ -n ${section//[[:space:]]/} ]] || { print -u2 "no CHANGELOG.md section for $VERSION"; exit 1; }
notes="$ABOUT

$section

### Install
Open the DMG and drag Slive to Applications. On first launch, allow it under System Settings → Privacy & Security, then grant Microphone, Accessibility and Input Monitoring when Slive asks. Needs an Apple silicon Mac on macOS 14+.

SHA-256: \`$(cut -d' ' -f1 "$DMG.sha256")\`"

# The tag is the repo owner's, whatever the local git identity is, and dated like the commit.
GIT_COMMITTER_NAME=SoumilB7 GIT_COMMITTER_EMAIL=107888098+SoumilB7@users.noreply.github.com \
  GIT_COMMITTER_DATE="$(git log -1 --format=%cI)" git tag -a "$TAG" -m "$TITLE"
git -c credential.helper= -c credential.helper='!gh auth git-credential' push origin "$TAG"
latest=$([[ $EDITION == lite ]] && echo true || echo false)
gh release create "$TAG" "$DMG" "$DMG.sha256" --verify-tag --title "$TITLE" \
  --notes "$notes" --latest="$latest" ${2:+"$2"}

# Published: the DMG lives on GitHub now, so free the disk (~0.1–1.8 GB per
# edition). Only build/ output — the installed /Applications/Slive.app is untouched.
rm -rf "$DMG" "$DMG.sha256" "$APP"
echo "removed $DMG and $APP (the release has them)"
