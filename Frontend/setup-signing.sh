#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# One-time setup: create a stable, self-signed code-signing identity for Flowy.
#
# WHY: macOS privacy (TCC) identifies an app by its code signature. Ad-hoc
# signing produces a NEW signature on every rebuild, so macOS re-asks for
# Microphone / Input Monitoring each time. A stable identity is signed the same
# way every build, so you grant permissions ONCE and they persist forever —
# exactly how a normal installed app behaves.
#
# WHAT THIS DOES:
#   1. Generates a self-signed cert + private key (valid 10 years).
#   2. Imports it into YOUR login keychain as "Flowy Local Signing".
#   3. Scopes key access to /usr/bin/codesign only (no "allow any app").
#
# It is local-only: nothing is uploaded, and it is NOT an Apple Developer cert
# (that costs $99/yr and isn't needed for a personal app). You may be prompted
# once by Keychain to "Always Allow" codesign to use the key.
#
# To undo later:  security delete-identity -c "Flowy Local Signing"
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

CN="Flowy Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CN"; then
    echo "✓ Signing identity '$CN' already exists — nothing to do."
    exit 0
fi

# Prefer Homebrew openssl (3.x, supports -legacy). The -legacy PKCS#12 cipher
# is REQUIRED, or macOS Keychain silently imports a key codesign can't use.
OPENSSL=/opt/homebrew/bin/openssl
[ -x "$OPENSSL" ] || OPENSSL="$(command -v openssl)"

echo "▸ Generating self-signed code-signing certificate…"
"$OPENSSL" req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$TMP/flowy.key" -out "$TMP/flowy.crt" \
    -subj "/CN=$CN" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning"

echo "▸ Packaging (PKCS#12, legacy cipher for Keychain compatibility)…"
if ! "$OPENSSL" pkcs12 -export -legacy -out "$TMP/flowy.p12" \
        -inkey "$TMP/flowy.key" -in "$TMP/flowy.crt" \
        -name "$CN" -passout pass:flowy 2>/dev/null; then
    # LibreSSL / older openssl has no -legacy flag (already uses legacy cipher).
    "$OPENSSL" pkcs12 -export -out "$TMP/flowy.p12" \
        -inkey "$TMP/flowy.key" -in "$TMP/flowy.crt" \
        -name "$CN" -passout pass:flowy
fi

echo "▸ Importing into your login keychain…"
security import "$TMP/flowy.p12" -k "$KEYCHAIN" -P flowy -T /usr/bin/codesign

echo ""
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CN"; then
    echo "✓ Done. '$CN' is ready."
    echo "  Now run:  ./build.sh install"
    echo "  Grant Microphone + Input Monitoring one last time — they'll stick after that."
else
    echo "✗ Something went wrong — the identity isn't listed. Check the output above."
    exit 1
fi
