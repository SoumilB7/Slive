# Assemble build/Slive.app from the compiled binaries. Sourced by build.sh,
# which sets FRONTEND_DIR, REPO_DIR, CONFIG, APP and CONTENTS.

# Values land as XML text via sed replacements — escape for both, so a repo
# path holding &, <, | or \ can't corrupt the plist or the sed command.
plist_value() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/[\\&|]/\\&/g'
}

assemble_bundle() {
    local BIN=".build/$CONFIG/Slive"
    echo "▸ Assembling app bundle…"
    rm -rf "$APP"
    mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
    cp "$BIN" "$CONTENTS/MacOS/Slive"

    # Bake absolute paths into Info.plist: the Backend/ dir whose .venv runs the
    # transcription server (auto-launched by the app), and the prompts folder.
    # They point into this checkout's Backend/ and prompts.
    local VERSION BUILD_SHA BUILD_DATE EDITION BUNDLED BACKEND_DIR PROMPTS_DIR
    VERSION="$(<"$REPO_DIR/VERSION")"
    # The commit, "-dirty" when tracked files differ from it (so a local hack never
    # passes for that commit in a bug report), and the commit's date.
    BUILD_SHA="$(git -C "$REPO_DIR" rev-parse --short HEAD)"
    git -C "$REPO_DIR" diff --quiet HEAD -- || BUILD_SHA="$BUILD_SHA-dirty"
    BUILD_DATE="$(git -C "$REPO_DIR" log -1 --format=%cI)"
    # SLIVE_EDITION=lite: no Python features. SliveBundledBackend stays "0":
    # the app never carries its own Python any more.
    EDITION="${SLIVE_EDITION:-full}"; BUNDLED="0"
    BACKEND_DIR="$REPO_DIR/Backend"
    PROMPTS_DIR="$REPO_DIR/Backend/prompts"
    mkdir -p "$PROMPTS_DIR"
    sed -e "s|__BACKEND_DIR__|$(plist_value "$BACKEND_DIR")|g" \
        -e "s|__PROMPTS_DIR__|$(plist_value "$PROMPTS_DIR")|g" \
        -e "s|__VERSION__|$(plist_value "$VERSION")|g" \
        -e "s|__EDITION__|$(plist_value "$EDITION")|g" \
        -e "s|__BUNDLED__|$(plist_value "$BUNDLED")|g" \
        -e "s|__BUILD_DATE__|$(plist_value "$BUILD_DATE")|g" \
        -e "s|__BUILD__|$(plist_value "$BUILD_SHA")|g" \
        Resources/Info.plist.template > "$CONTENTS/Info.plist"

    # The problem reporter: its own little app inside Slive, so a frozen or
    # crashed Slive can still offer a GitHub issue (Sources/SliveReporter).
    local REPORTER="$CONTENTS/Helpers/SliveReporter.app/Contents"
    mkdir -p "$REPORTER/MacOS"
    cp ".build/$CONFIG/SliveReporter" "$REPORTER/MacOS/SliveReporter"
    sed -e "s|__VERSION__|$(plist_value "$VERSION")|g" \
        Resources/Reporter-Info.plist.template > "$REPORTER/Info.plist"

    # App icon.
    if [[ -f Resources/AppIcon.icns ]]; then
        cp Resources/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"
    fi

    # Bundle the default (tiny) transcription model + tokenizer so first launch needs
    # no download and works fully offline.
    # Speech clip for the post-load warm-up (a silent warm-up is a no-op: Whisper
    # skips it in ~10ms, leaving the first real dictation to pay the setup).
    if [[ -f Resources/WarmUp.wav ]]; then
        cp Resources/WarmUp.wav "$CONTENTS/Resources/WarmUp.wav"
    fi

    if [[ -d Resources/BundledModels ]]; then
        cp -R Resources/BundledModels "$CONTENTS/Resources/BundledModels"
    fi
    if [[ -d Resources/BundledTokenizers ]]; then
        cp -R Resources/BundledTokenizers "$CONTENTS/Resources/BundledTokenizers"
    fi
}
