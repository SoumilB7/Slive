#!/bin/zsh
# Publishes v<VERSION> as Slive's ONE GitHub release: no downloads (Slive
# installs by command), just the install commands and this version's
# CHANGELOG.md section. Every other release — and its tag — is deleted, so the
# Releases page only ever shows the latest. Tags HEAD; commit first.
#
#   Frontend/scripts/release.sh
set -euo pipefail

cd "${0:A:h}/../.."
VERSION="$(<VERSION)"
TAG="v$VERSION"
RAW="https://raw.githubusercontent.com/SoumilB7/Slive/main"

[[ -z "$(git status --porcelain)" ]] || { print -u2 "uncommitted changes: commit first"; exit 1; }
git fetch --quiet --tags origin
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { print -u2 "$TAG already exists"; exit 1; }

section=$(awk -v v="$VERSION" '
  /^## \[/ { on = index($0, "[" v "]") > 0; next }
  /^\[[0-9.]+\]:/ { next }
  on' CHANGELOG.md)
[[ -n ${section//[[:space:]]/} ]] || { print -u2 "no CHANGELOG.md section for $VERSION"; exit 1; }

notes="Install or update by pasting one line into Terminal — it builds Slive on your Mac and opens it ready to dictate. Run it again to update.

**Slive** (on-device dictation, no Python):
\`\`\`
curl -fsSL $RAW/install.sh | bash
\`\`\`

**Slive Full** (plus Ask, local models, correct-answer labeling and training):
\`\`\`
curl -fsSL $RAW/install-full.sh | bash
\`\`\`

Needs an Apple silicon Mac on macOS 14+.

## What's new in $VERSION
$section"

# The tag is the repo owner's, whatever the local git identity is, and dated like the commit.
GIT_COMMITTER_NAME=SoumilB7 GIT_COMMITTER_EMAIL=107888098+SoumilB7@users.noreply.github.com \
  GIT_COMMITTER_DATE="$(git log -1 --format=%cI)" git tag -a "$TAG" -m "Slive $VERSION"
git -c credential.helper= -c credential.helper='!gh auth git-credential' push --quiet origin "$TAG"
gh release create "$TAG" --verify-tag --title "Slive $VERSION" --notes "$notes" --latest

# Only the latest stays: delete every other release and its tag (remote + local).
for old in $(gh release list --limit 200 --json tagName --jq '.[].tagName'); do
    [[ "$old" == "$TAG" ]] && continue
    gh release delete "$old" --cleanup-tag --yes
    git tag -d "$old" >/dev/null 2>&1 || true
    echo "removed $old"
done
echo "published $TAG — the only release"
