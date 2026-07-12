#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# One-time setup: create a stable, self-signed code-signing identity for Flowy.
#
# WHY: macOS privacy (TCC) identifies an app by its code signature. Ad-hoc
# signing produces a NEW signature on every rebuild, so macOS re-asks for
# Microphone / Input Monitoring each time. A stable identity is signed the same
# way every build, so you grant permissions ONCE and they persist forever.
#
# Local-only: a self-signed cert (NOT an Apple Developer cert), key scoped to
# /usr/bin/codesign, imported into your login keychain. Safe to re-run — it
# removes any previous copies first so duplicates can't pile up.
#
# To undo entirely:  security delete-identity -c "Flowy Local Signing"
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

CN="Flowy Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 0. Remove any existing copies so re-runs don't create duplicates (duplicates
#    make codesign ambiguous and it silently falls back to ad-hoc).
echo "▸ Clearing any existing '$CN' entries…"
guard=0
while security find-certificate -c "$CN" "$KEYCHAIN" >/dev/null 2>&1 && [ $guard -lt 10 ]; do
    security delete-identity -c "$CN" "$KEYCHAIN" >/dev/null 2>&1 || {
        echo "  ⚠️  Could not auto-delete. Open Keychain Access ▸ login, delete every"
        echo "     'Flowy Local Signing' certificate, then re-run this script."
        exit 1
    }
    guard=$((guard + 1))
done

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
    "$OPENSSL" pkcs12 -export -out "$TMP/flowy.p12" \
        -inkey "$TMP/flowy.key" -in "$TMP/flowy.crt" \
        -name "$CN" -passout pass:flowy
fi

echo "▸ Importing into your login keychain…"
security import "$TMP/flowy.p12" -k "$KEYCHAIN" -P flowy -T /usr/bin/codesign

# Verify by ACTUALLY signing a throwaway binary. (find-identity -p codesigning
# hides untrusted self-signed certs, so testing real signing is the honest check.)
echo "▸ Verifying the identity can sign…"
cp /bin/echo "$TMP/echo-test"
if codesign --force --options runtime --sign "$CN" "$TMP/echo-test" >/dev/null 2>&1; then
    echo ""
    echo "✓ Done. '$CN' is ready and can sign."
    echo "  Next:  ./build.sh install   (should say 'Signing with stable identity')"
else
    echo ""
    echo "✗ Imported, but codesign couldn't use it (likely a keychain prompt was"
    echo "  denied, or leftover duplicates). Open Keychain Access ▸ login, delete"
    echo "  every 'Flowy Local Signing' entry, then re-run this script and click"
    echo "  'Always Allow' if prompted."
    exit 1
fi
