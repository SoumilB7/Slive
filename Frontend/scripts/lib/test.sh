# Run the self-tests. Sourced by build.sh (test mode), which sets CONFIG.

# `SliveSelfTest` runs the SliveCore + SliveReport suites alone — proof they
# need nothing from the app (only its failures are echoed). `Slive --self-test`
# then runs every suite, those included, with full output. One summary line;
# non-zero if either run failed.
run_self_tests() {
    local BIN=".build/$CONFIG" CORE_OUT APP_OUT CORE_STATUS=0 APP_STATUS=0 CORE_LINE APP_LINE
    CORE_OUT="$(mktemp -t slive-selftest-core)"
    APP_OUT="$(mktemp -t slive-selftest-app)"
    echo "▸ SliveSelfTest (core suites, standalone)…"
    "$BIN/SliveSelfTest" >"$CORE_OUT" 2>&1 || CORE_STATUS=$?
    grep "❌" "$CORE_OUT" || true
    echo "▸ Slive --self-test (every suite)…"
    "$BIN/Slive" --self-test 2>&1 | tee "$APP_OUT" || APP_STATUS=$?
    CORE_LINE="$(grep -E '^[0-9]+ passed, [0-9]+ failed$' "$CORE_OUT" | tail -n 1)"
    APP_LINE="$(grep -E '^[0-9]+ passed, [0-9]+ failed$' "$APP_OUT" | tail -n 1)"
    rm -f "$CORE_OUT" "$APP_OUT"
    local SUMMARY="all suites ${APP_LINE:-did not finish} (Slive --self-test); core ${CORE_LINE:-did not finish} standalone (SliveSelfTest)"
    if (( CORE_STATUS == 0 && APP_STATUS == 0 )); then
        echo "✓ Self-test: $SUMMARY"
    else
        echo "✗ Self-test: $SUMMARY" >&2
        return 1
    fi
}
