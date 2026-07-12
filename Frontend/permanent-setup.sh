#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Run this ONCE to make Slive's permissions permanent.
#
# It (1) creates a stable signing identity, (2) builds + installs the app signed
# with it. After that you grant Microphone + Input Monitoring one time, and they
# persist across every future `./build.sh install` — because the signature never
# changes again.
#
#   cd Frontend && ./permanent-setup.sh
#
# ⚠️  Do NOT delete the "Slive Local Signing" certificate from Keychain Access.
#     That certificate IS the permanent grant — deleting it resets everything.
# ─────────────────────────────────────────────────────────────────────────────
set -e
cd "$(dirname "$0")"

echo "═══════════════════════════════════════════════════════════════════════"
echo " Step 1/2 — create the stable signing identity (one-time)"
echo "═══════════════════════════════════════════════════════════════════════"
./setup-signing.sh

echo ""
echo "═══════════════════════════════════════════════════════════════════════"
echo " Step 2/2 — build + install the signed app"
echo "═══════════════════════════════════════════════════════════════════════"
./build.sh install

echo ""
echo "═══════════════════════════════════════════════════════════════════════"
echo " ✅ Installed and signed. ONE manual step left (do it once):"
echo ""
echo "   In the Slive window that just opened:"
echo "     • Microphone       → Grant → Allow"
echo "     • Input Monitoring → Grant → toggle Slive ON"
echo ""
echo " After that, permissions persist forever. To ship a new build later,"
echo " just run:   ./build.sh install     (no re-signing, no re-granting)"
echo ""
echo " ⚠️  Never delete the 'Slive Local Signing' cert from Keychain Access."
echo "═══════════════════════════════════════════════════════════════════════"
