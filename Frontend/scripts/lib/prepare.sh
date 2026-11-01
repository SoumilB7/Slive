# Pre-compile the speech models for the binary at $LAUNCH_TARGET. Sourced by build.sh.

# Compile the models for THIS binary before launch. macOS keys its compiled
# Neural Engine programs to the exact binary, so the first launch of any new
# build spends ~1–2 min compiling Whisper — and no dictation can run until it
# finishes. Doing it here means the app opens ready. SLIVE_SKIP_PREPARE=1 skips.
prepare_models() {
    [[ -z "${SLIVE_SKIP_PREPARE:-}" ]] || return 0
    echo "▸ Preparing the speech model for this build (Neural Engine compile, ~1–2 min when the code changed)…"
    pkill -x Slive 2>/dev/null || true
    # Time-boxed by a watchdog (macOS has no `timeout`), and never fatal: if
    # it fails or hangs, the app still works and compiles on first launch.
    local PREP_LIMIT=600
    local PREP_LOG="${TMPDIR:-/tmp}/slive-prepare.log"
    local PREP_OUT PREP_START PREP_PID WATCHDOG PREP_STATUS PREP_SECS i
    PREP_OUT="$(mktemp -t slive-prepare)"
    PREP_START=$(date +%s)
    "$LAUNCH_TARGET/Contents/MacOS/Slive" --prepare-models >"$PREP_OUT" 2>"$PREP_LOG" &
    PREP_PID=$!
    ( for (( i = 0; i < PREP_LIMIT; i++ )); do
          sleep 1; kill -0 "$PREP_PID" 2>/dev/null || exit 0
      done
      kill "$PREP_PID" 2>/dev/null ) &
    WATCHDOG=$!
    disown "$WATCHDOG" 2>/dev/null || true   # no "Terminated" line when it's stopped below
    PREP_STATUS=0; wait "$PREP_PID" || PREP_STATUS=$?
    kill "$WATCHDOG" 2>/dev/null || true
    PREP_SECS=$(( $(date +%s) - PREP_START ))
    grep -E "^  " "$PREP_OUT" || true
    rm -f "$PREP_OUT"
    if (( PREP_STATUS == 0 )); then
        rm -f "$PREP_LOG"
        echo "✓ Model ready in ${PREP_SECS}s — the first dictation will be instant."
    elif (( PREP_SECS >= PREP_LIMIT )); then
        echo "⚠ Model prep passed 10 min and was stopped — Slive compiles it on first launch instead (log: $PREP_LOG)."
    else
        tail -n 5 "$PREP_LOG" | sed 's/^/  /'
        echo "⚠ Model prep failed (exit $PREP_STATUS) — Slive still works and compiles it on first launch (log: $PREP_LOG)."
    fi
}
