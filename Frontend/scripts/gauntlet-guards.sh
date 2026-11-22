#!/bin/bash
# Gauntlet G10 — static guards. Seconds, no compiler: grep/awk over the sources.
# Exits 1 with `file:line` for every violation.
#
#   raw-time    DispatchQueue.main.asyncAfter / Task.sleep / Date() in
#               Sources/Slive/{Modes,Paste,Dictation,Overlay}. Wall-clock calls
#               there can't be driven by the virtual clock, so the simulator
#               can't reach them.
#   try-keychain  `try?` on a SecItem/Keychain/credential call with no Log on
#               the same or next line: a locked keychain must leave a trace.
#   sleep-loop  a `while` loop around Task.sleep with no Deadline/deadline/
#               maxWait within 5 lines: a poll with no bound is how a wait
#               hangs forever.
#
# Existing sites live in Fixtures/gauntlet/guard-allow.txt, one per line:
#     <rule> <path relative to Frontend> <trimmed source line>
# so the guards start green and the list only grows on purpose (a new site, or
# an edited line, must be added there in review). Each entry allows one
# occurrence. Entries that no longer match anything are listed as stale.
#
# Usage: scripts/gauntlet-guards.sh [--root <Frontend dir>] [--print-violations]
#   --print-violations  print every violation, allowlisted or not, in allowlist format
#                       (how the allowlist was seeded; review before keeping).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PRINT=0
while (( $# )); do
    case "$1" in
        --root) ROOT="$(cd "$2" && pwd)" || exit 2; shift 2 ;;
        --print-violations) PRINT=1; shift ;;
        *) echo "usage: gauntlet-guards.sh [--root <Frontend dir>] [--print-violations]" >&2; exit 2 ;;
    esac
done
cd "$ROOT" || exit 2

ALLOW="Fixtures/gauntlet/guard-allow.txt"
[[ -f "$ALLOW" ]] || ALLOW=/dev/null
[[ -d Sources ]] || { echo "✗ guards: no Sources/ under $ROOT" >&2; exit 2; }

# Test doubles and the Gauntlet itself may use the real clock.
FILES="$(find Sources -name '*.swift' \
    -not -path '*/SelfTest/*' -not -path '*/Gauntlet/*' -not -path '*/SliveCoreSuites/*' \
    -not -path '*/SliveTestKit/*' -not -path '*/SliveSelfTest/*' | LC_ALL=C sort)"
[[ -n "$FILES" ]] || { echo "✗ guards: no Swift sources found" >&2; exit 2; }

# shellcheck disable=SC2086
awk -v print_mode="$PRINT" -v allow_file="$ALLOW" '
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

# One line with string literals and a trailing // comment removed, so words
# inside them never count. Also reports how many braces it opens and closes.
function scrub(s,    out, i, c, n, instr) {
    out = ""; n = length(s); instr = 0
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (instr) {
            if (c == "\\") { i++; continue }
            if (c == "\"") instr = 0
            continue
        }
        if (c == "\"") { instr = 1; continue }
        if (c == "/" && substr(s, i + 1, 1) == "/") break
        out = out c
    }
    return out
}

function report(rule, path, ln, code, msg,    key) {
    key = rule SUBSEP path SUBSEP code
    if (!print_mode && allow[key] > used[key]) { used[key]++; return }
    violations++
    if (print_mode) print rule " " path " " code
    else printf "%s:%d: [%s] %s\n", path, ln, rule, msg
}

function near(a, b,    i) {            # Deadline-ish word in lines a..b?
    if (a < 1) a = 1
    if (b > n) b = n
    for (i = a; i <= b; i++) if (raw[i] ~ /[Dd]eadline|maxWait/) return 1
    return 0
}

function finish(path,    i, k, d, o, c, ch, s, top, pending, pendLine, inPrefix) {
    if (path == "") return
    inPrefix = (path ~ /^Sources\/Slive\/(Modes|Paste|Dictation|Overlay)\//)
    top = 0; d = 0; pending = 0
    for (i = 1; i <= n; i++) {
        s = code[i]
        if (inPrefix && s ~ /DispatchQueue\.main\.asyncAfter|Task\.sleep|(^|[^A-Za-z0-9_])Date\(\)/)
            report("raw-time", path, i, trim(raw[i]),
                   "wall-clock call (asyncAfter/Task.sleep/Date()) — use the injected clock, or add it to guard-allow.txt on purpose")
        if (s ~ /try\?/ && s ~ /SecItem|[Kk]eychain|CredentialStore|SecretStore/ \
            && raw[i] !~ /Log\.|NSLog|os_log|Logger/ && raw[i + 1] !~ /Log\.|NSLog|os_log|Logger/)
            report("try-keychain", path, i, trim(raw[i]),
                   "try? on a Keychain call with no Log on this or the next line")
        if (s ~ /(^|[^A-Za-z0-9_])while[ \t(]/ && s !~ /\}[ \t]*while/) { pending = 1; pendLine = i }
        if (s ~ /Task\.sleep/)
            for (k = 1; k <= top; k++)
                if (!near(wline[k] - 5, wline[k] + 5) && !near(i - 5, i + 5)) {
                    report("sleep-loop", path, i, trim(raw[i]),
                           "Task.sleep in a while loop (line " wline[k] ") with no Deadline/maxWait within 5 lines")
                    break
                }
        o = length(s)
        for (c = 1; c <= o; c++) {
            ch = substr(s, c, 1)
            if (ch == "{") {
                d++
                if (pending) { top++; wline[top] = pendLine; wdepth[top] = d; pending = 0 }
            } else if (ch == "}") {
                if (top > 0 && wdepth[top] == d) top--
                d--
            }
        }
    }
}

FILENAME == allow_file {              # the allowlist
    line = $0
    if (line ~ /^[ \t]*(#|$)/) next
    rule = line; sub(/[ \t].*$/, "", rule)
    rest = line; sub(/^[^ \t]+[ \t]+/, "", rest)
    path = rest; sub(/[ \t].*$/, "", path)
    src = rest; sub(/^[^ \t]+[ \t]+/, "", src)
    src = trim(src)
    allow[rule SUBSEP path SUBSEP src]++
    allowText[rule SUBSEP path SUBSEP src] = rule " " path " " src
    next
}

FNR == 1 { finish(cur); cur = FILENAME; n = 0; delete raw; delete code }
{ n++; raw[n] = $0; code[n] = scrub($0) }
END {
    finish(cur)
    for (key in allow) if (used[key] < allow[key]) stale[++nstale] = allowText[key]
    if (nstale > 0 && !print_mode) {
        printf "note: %d stale guard-allow.txt entr%s (no longer match any code; remove):\n", nstale, (nstale == 1 ? "y" : "ies")
        for (i = 1; i <= nstale; i++) print "  " stale[i]
    }
    if (print_mode) exit 0
    if (violations > 0) {
        printf "✗ guards: %d violation%s\n", violations, (violations == 1 ? "" : "s")
        exit 1
    }
    print "✓ guards: clean"
}
' "$ALLOW" $FILES
