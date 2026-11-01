# Code signing. Sourced by build.sh (needs the Frontend dir as cwd).

ENTITLEMENTS="Slive.entitlements"   # audio-input entitlement (mic under Hardened Runtime)

# Prefer a stable self-signed identity if the user created one — then macOS TCC
# (Microphone / Input Monitoring) remembers grants across REBUILDS, not just
# relaunches. Falls back to ad-hoc otherwise (grants reset on each rebuild).
# To create the identity, see: Frontend/setup-signing.sh
detect_signing_identity() {
    local SIGN_ID="Slive Local Signing"
    # Detect by certificate presence, not `find-identity -p codesigning` — the
    # latter hides untrusted self-signed certs even though codesign can use them.
    # Try the default search list AND the login keychain explicitly (more robust).
    if security find-certificate -c "$SIGN_ID" >/dev/null 2>&1 \
       || security find-certificate -c "$SIGN_ID" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1; then
        SIGN_ARGS=(--sign "$SIGN_ID")
        echo "▸ Signing with stable identity: $SIGN_ID"
    else
        SIGN_ARGS=(--sign -)
        echo "▸ Signing (ad-hoc — grants reset on rebuild; run setup-signing.sh for persistence)"
    fi
}

# A bad signature means macOS may silence the mic or re-ask for every
# permission, so codesign's complaints are shown, not swallowed.
verify_signature() {
    local out
    out="$(codesign --verify --strict "$1" 2>&1)" && return 0
    printf '%s\n' "$out" | sed 's/^/  /'
    echo "⚠ $1 didn't pass codesign --verify — macOS may block the mic or re-ask for permissions. Run ./setup-signing.sh and build again."
}

# --options runtime = Hardened Runtime (blocks code injection). The entitlements
# file grants microphone access under that runtime — without it the mic is silent.
sign_app() {
    local out
    out="$(codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" "${SIGN_ARGS[@]}" "$1" 2>&1)" \
        || printf '%s\n' "$out" | sed 's/^/  /'
    verify_signature "$1"
}
