#!/bin/bash
# Install or update Slive — dictation with on-device speech, no Python:
#   curl -fsSL https://raw.githubusercontent.com/SoumilB7/Slive/main/install.sh | bash
# With the Python server (Ask, local models, training): install-full.sh.
# A version: … | bash -s -- 0.2.3     Re-run to update.
#
# Builds Slive on this Mac and signs it with a stable local identity, so the
# Accessibility / Input Monitoring grants survive every update, and compiles
# the speech model before launch, so it opens ready.
set -euo pipefail

EDITION="${SLIVE_EDITION:-lite}"
VERSION="${1:-}"
REPO="https://github.com/SoumilB7/Slive.git"
DIR="${SLIVE_DIR:-$HOME/.slive/Slive}"

step() { printf "\n▸ %s\n" "$1"; }
fail() { printf "\n✗ %s\n" "$1" >&2; exit 1; }

[[ "$EDITION" == lite || "$EDITION" == full ]] || fail "SLIVE_EDITION must be lite or full"
[[ "$(uname -m)" == arm64 ]] || fail "Slive needs an Apple silicon Mac."
(( $(sw_vers -productVersion | cut -d. -f1) >= 14 )) || fail "Slive needs macOS 14 or later."

if ! xcode-select -p >/dev/null 2>&1; then
    step "Installing Apple's Command Line Tools — accept the dialog (one time, ~10 min)…"
    xcode-select --install >/dev/null 2>&1 || true
    until xcode-select -p >/dev/null 2>&1; do sleep 10; done
fi

if [[ -d "$DIR/.git" ]]; then
    step "Updating Slive…"
    git -C "$DIR" fetch --quiet --tags origin
    git -C "$DIR" checkout --quiet main
    git -C "$DIR" pull --quiet --ff-only origin main
else
    step "Downloading Slive…"
    mkdir -p "$(dirname "$DIR")"
    git clone --quiet "$REPO" "$DIR"
fi
if [[ -n "$VERSION" ]]; then
    git -C "$DIR" checkout --quiet "v${VERSION#v}" || fail "No version ${VERSION#v}."
fi

if [[ "$EDITION" == full ]]; then
    if ! command -v uv >/dev/null 2>&1; then
        step "Installing uv (Python manager)…"
        curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null
        export PATH="$HOME/.local/bin:$PATH"
    fi
    step "Setting up the Python server (one time, ~1.2 GB)…"
    ( cd "$DIR/Backend" && uv sync --quiet --extra training )
fi

if ! security find-certificate -c "Slive Local Signing" >/dev/null 2>&1; then
    step "Creating a signing identity, so permissions survive updates (one time)…"
    ( cd "$DIR/Frontend" && ./setup-signing.sh >/dev/null ) \
        || echo "  (couldn't create it — Slive still works, but re-grant permissions after updates)"
fi

step "Building and installing Slive (first time ~5–10 min)…"
( cd "$DIR/Frontend" && SLIVE_EDITION="$EDITION" ./build.sh install )

cat <<DONE

✅ Slive ($EDITION) is installed in /Applications and running.
   Grant Microphone, Input Monitoring and Accessibility in its window when asked.
   Update any time by running the same command again.
DONE
