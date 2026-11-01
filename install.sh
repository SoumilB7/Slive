#!/bin/bash
# Install or update Slive — dictation with on-device speech, no Python:
#   curl -fsSL https://raw.githubusercontent.com/SoumilB7/Slive/main/install.sh | bash
# With the Python server (Ask, local models, training): install-full.sh.
# Always the latest version. Re-run to update.
#
# Builds Slive on this Mac and signs it with a stable local identity, so the
# Accessibility / Input Monitoring grants survive every update, and compiles
# the speech model before launch, so it opens ready.
set -euo pipefail

EDITION="${SLIVE_EDITION:-lite}"
REPO="https://github.com/SoumilB7/Slive.git"
RAW="https://raw.githubusercontent.com/SoumilB7/Slive/main"
DIR="${SLIVE_DIR:-$HOME/.slive/Slive}"

step() { printf "\n▸ %s\n" "$1"; }
fail() { printf "\n✗ %s\n" "$1" >&2; exit 1; }

[[ "$EDITION" == lite || "$EDITION" == full ]] || fail "SLIVE_EDITION must be lite or full"
[[ "$(uname -m)" == arm64 ]] || fail "Slive needs an Apple silicon Mac."
(( $(sw_vers -productVersion | cut -d. -f1) >= 14 )) || fail "Slive needs macOS 14 or later."
# Older versions can't be installed: release.sh deletes every older tag.
(( $# == 0 )) || echo "  (only the latest version is kept — installing that)"

if ! xcode-select -p >/dev/null 2>&1; then
    step "Installing Apple's Command Line Tools — accept the dialog (one time, ~10 min)…"
    xcode-select --install >/dev/null 2>&1 || true
    waited=0
    until xcode-select -p >/dev/null 2>&1; do
        (( waited < 1800 )) || fail "The Command Line Tools still aren't installed after 30 min. Run: xcode-select --install — then this command again."
        sleep 10; waited=$((waited + 10))
        (( waited % 60 != 0 )) || echo "  …waiting for the Command Line Tools ($((waited / 60)) min)"
    done
fi

# Can this Mac build Slive? Asked before any download, with the very check
# build.sh runs (Frontend/toolchain.sh: from this checkout, or from GitHub
# when piped from curl).
src="${BASH_SOURCE[0]:-}"
if [[ -n "$src" && -f "$(dirname "$src")/Frontend/toolchain.sh" ]]; then
    source "$(dirname "$src")/Frontend/toolchain.sh"
else
    toolchain="$(curl -fsSL "$RAW/Frontend/toolchain.sh")" \
        || fail "Couldn't reach GitHub — check your connection and try again."
    eval "$toolchain"
fi
slive_toolchain_check || fail "$SLIVE_TOOLCHAIN_ERROR"

need_gb=1
[[ "$EDITION" == lite ]] || need_gb=3
free_kb="$(df -Pk "$HOME" | awk 'NR == 2 { print $4 }')"
(( free_kb >= need_gb * 1024 * 1024 )) \
    || fail "Slive needs about $need_gb GB free; this Mac has $(( free_kb / 1024 / 1024 )) GB."

# The clone in ~/.slive/Slive is managed by this script, not a working copy:
# an update fetches, then hard-resets to origin/main (checkout --force -B =
# reset --hard, which also re-attaches a HEAD left detached by an old version
# pin), dropping any local edits. Untracked build caches (.build, .venv) stay.
# A broken or half-made clone (no commit, or fetch fails) is moved aside and
# cloned fresh — and put back if the fresh clone fails too.
aside=""
[[ ! -d "$DIR/.git" ]] || step "Updating Slive…"
if [[ -d "$DIR/.git" ]] && git -C "$DIR" rev-parse -q --verify HEAD >/dev/null 2>&1 \
   && git -C "$DIR" fetch --quiet origin 2>/dev/null; then
    git -C "$DIR" checkout --quiet --force -B main origin/main
else
    if [[ -e "$DIR" ]]; then
        aside="$DIR.old-$(date +%Y%m%d-%H%M%S)"
        mv "$DIR" "$aside"
        echo "  (the copy in $DIR looked incomplete — moved to $aside)"
    fi
    step "Downloading Slive…"
    mkdir -p "$(dirname "$DIR")"
    if ! git clone --quiet "$REPO" "$DIR"; then
        rm -rf "$DIR"
        [[ -z "$aside" ]] || mv "$aside" "$DIR"
        fail "Couldn't download Slive — check your connection and try again."
    fi
fi

if [[ "$EDITION" == full ]]; then
    if ! command -v uv >/dev/null 2>&1; then
        step "Installing uv (Python manager)…"
        # UV_NO_MODIFY_PATH: leave the shell profile alone — this script and
        # the app both find uv in ~/.local/bin on their own.
        curl -LsSf https://astral.sh/uv/install.sh | UV_NO_MODIFY_PATH=1 sh >/dev/null \
            || fail "Couldn't install uv — check your connection and try again."
        export PATH="$HOME/.local/bin:$PATH"
    fi
    step "Setting up the Python server (one time, ~1.2 GB)…"
    ( cd "$DIR/Backend" && uv sync --extra training ) \
        || fail "Couldn't set up the Python server (see uv's error above). Check your connection and free space, then run the command again."
fi

if ! security find-certificate -c "Slive Local Signing" >/dev/null 2>&1; then
    step "Creating a signing identity, so permissions survive updates (one time)…"
    if ! signing_log="$(cd "$DIR/Frontend" && ./setup-signing.sh 2>&1)"; then
        printf '%s\n' "$signing_log" | sed 's/^/  /'
        echo "  (couldn't create it — Slive still works, but re-grant permissions after updates)"
    fi
fi

step "Building and installing Slive (first time ~5–10 min)…"
( cd "$DIR/Frontend" && SLIVE_EDITION="$EDITION" ./build.sh install )

cat <<DONE

✅ Slive ($EDITION) is installed and running.
   Grant Microphone, Input Monitoring and Accessibility in its window when asked.
   Update any time by running the same command again.
DONE
