# Install build/Slive.app. Sourced by build.sh, which sets APP; sets LAUNCH_TARGET.

install_app() {
    # /Applications when this account may write there; a standard (non-admin)
    # account gets ~/Applications, which needs no password.
    local APPS_DIR="/Applications"
    if [[ ! -w "$APPS_DIR" ]]; then
        APPS_DIR="$HOME/Applications"
        mkdir -p "$APPS_DIR"
        echo "▸ /Applications needs an admin account — installing to ~/Applications instead."
    fi
    local DEST="$APPS_DIR/Slive.app"
    # Copy in beside the installed app, then swap: a copy that fails (full
    # disk, Ctrl-C) leaves the working Slive untouched. The temp names don't
    # end in .app, so LaunchServices never lists them as a second Slive.
    local NEW="$DEST.new" OLD="$DEST.old"
    echo "▸ Installing to $DEST …"
    rm -rf "$NEW" "$OLD"
    cp -R "$APP" "$NEW" || {
        rm -rf "$NEW"
        echo "✗ Couldn't copy Slive into $APPS_DIR — the installed app is untouched." >&2
        exit 1
    }
    pkill -x Slive 2>/dev/null || true
    sleep 0.3
    if [[ -e "$DEST" ]] && ! mv "$DEST" "$OLD"; then
        rm -rf "$NEW"
        echo "✗ Couldn't replace $DEST — the installed app is untouched." >&2
        exit 1
    fi
    if ! mv "$NEW" "$DEST"; then
        [[ -e "$OLD" ]] && mv "$OLD" "$DEST"
        rm -rf "$NEW"
        echo "✗ Couldn't move the new Slive into place — the installed app is untouched." >&2
        exit 1
    fi
    rm -rf "$OLD"
    # Re-sign the installed copy with the same identity + runtime + entitlements.
    sign_app "$DEST"
    # Remove the throwaway build/ bundle entirely so it can never appear as a
    # duplicate app. (LaunchServices re-discovers any .app bundle on disk, so
    # unregistering isn't enough — the bundle itself must go.)
    local LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
    "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
    rm -rf "$APP"
    LAUNCH_TARGET="$DEST"
    echo "✓ Installed: $DEST (single copy — no duplicates)"
}
