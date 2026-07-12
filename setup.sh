#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Flowy — one-command setup. From a fresh clone, run:  ./setup.sh
#
# It installs everything needed, builds + installs the app, and pre-downloads the
# transcription model. The only things it can't do for you are the macOS GUI
# prompts (Command Line Tools install, and granting the three permissions).
#
# Requirements it assumes: an Apple-Silicon Mac + internet. It provides the rest
# (uv even fetches Python for you).
# ─────────────────────────────────────────────────────────────────────────────
set -e
cd "$(dirname "$0")"

step() { printf "\n▸ %s\n" "$1"; }

# 1. Xcode Command Line Tools — provides `swift`.
if ! xcode-select -p >/dev/null 2>&1; then
    step "Installing Xcode Command Line Tools (accept the system dialog)…"
    xcode-select --install || true
    echo "  When that finishes, re-run ./setup.sh"
    exit 1
fi

# 2. uv — Python env manager (also provides Python itself).
if ! command -v uv >/dev/null 2>&1; then
    step "Installing uv…"
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
fi

# 3. Backend virtualenv + dependencies.
step "Setting up the Python backend (uv sync)…"
( cd Backend && uv sync )

# 4. Stable self-signed identity so macOS remembers the permissions.
if ! security find-certificate -c "Flowy Local Signing" >/dev/null 2>&1; then
    step "Creating the signing identity (one time)…"
    ( cd Frontend && ./setup-signing.sh )
fi

# 5. Pre-download the transcription model so the first dictation is instant.
step "Downloading the transcription model (one time, ~75 MB)…"
( cd Backend && .venv/bin/python -c "from flowy.transcribe import load_model; load_model()" )

# 6. Build + install the app (signs with the stable identity).
step "Building and installing Flowy.app…"
( cd Frontend && ./build.sh install )

cat <<'DONE'

✅ Flowy is installed and running (menu bar + Dock).

   ONE manual step left — grant permissions in the Flowy window, then Quit & Reopen:
     • Microphone        — record your voice
     • Input Monitoring  — detect your push-to-talk key
     • Accessibility     — type transcripts into text fields (optional)

   Then hold your key, speak, release. Everything runs locally.
DONE
