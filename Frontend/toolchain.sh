# Can this Mac build Slive? Sourced by build.sh and by install.sh — which
# runs it BEFORE cloning or `uv sync`, so a missing toolchain fails in seconds,
# not after ten minutes of downloads. One copy, so both always agree.
#
# slive_toolchain_check: returns 0 when the build can go ahead, with
# SLIVE_PINNED_SDK set to the SDK to build against ("" = the default one).
# Returns 1 with SLIVE_TOOLCHAIN_ERROR = one line saying what to install.
#
# SDK pin (Command Line Tools only — no Xcode). From the macOS 27 SDK on,
# SwiftUI's @State/@Observable are compiler MACROS whose plugin
# (SwiftUIMacros) ships only with Xcode, so the default CLT SDK can't build
# this app ("plugin for module 'SwiftUIMacros' not found"). When the plugin
# is missing, build against the newest installed SDK older than 27.
# SLIVE_SDKROOT / SDKROOT, when set, skip the pin (the caller's choice wins).
slive_toolchain_check() {
    SLIVE_PINNED_SDK=""; SLIVE_TOOLCHAIN_ERROR=""
    local swift_bin swift_major sdk_major plugins sdk_dir

    # Package.swift is swift-tools-version 6.0. (`swift --version` splits its
    # output between stdout and stderr depending on the release.)
    swift_major="$(swift --version 2>&1 | sed -nE 's/.*Swift version ([0-9]+)\..*/\1/p' | head -1)"
    if [[ -z "$swift_major" ]] || (( swift_major < 6 )); then
        SLIVE_TOOLCHAIN_ERROR="Slive needs Swift 6 or later${swift_major:+ (found $swift_major)} — update the Command Line Tools in System Settings ▸ General ▸ Software Update, or install Xcode."
        return 1
    fi

    [[ -n "${SLIVE_SDKROOT:-}" || -n "${SDKROOT:-}" ]] && return 0
    swift_bin="$(xcrun --find swift 2>/dev/null)" || {
        SLIVE_TOOLCHAIN_ERROR="xcrun can't find swift — reinstall the Command Line Tools: xcode-select --install"
        return 1
    }
    plugins="$(dirname "$swift_bin")/../lib/swift/host/plugins"
    sdk_major="$(xcrun --show-sdk-version 2>/dev/null | cut -d. -f1)"
    if (( ${sdk_major:-0} >= 27 )) && ! ls "$plugins" 2>/dev/null | grep -q SwiftUIMacros; then
        sdk_dir="$(dirname "$(xcrun --show-sdk-path)")"
        SLIVE_PINNED_SDK="$(ls -d "$sdk_dir"/MacOSX[0-9]*.[0-9]*.sdk 2>/dev/null \
            | sed -E 's|.*/MacOSX([0-9]+)\.([0-9]+)\.sdk$|\1 \2 &|' \
            | awk '$1 < 27' | sort -k1,1n -k2,2n | tail -1 | cut -d' ' -f3)"
        if [[ -z "$SLIVE_PINNED_SDK" ]]; then
            SLIVE_TOOLCHAIN_ERROR="The macOS $sdk_major SDK needs Xcode's SwiftUI macros and no older SDK is installed — install Xcode, or Command Line Tools 26 from developer.apple.com/download/all."
            return 1
        fi
    fi
    return 0
}
