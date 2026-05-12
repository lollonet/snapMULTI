#!/usr/bin/env bash
# Static + functional checks for the logging.sh → unified-log.sh
# consolidation.
#
# Invariants we guard:
#   1. logging.sh is a thin shim that sources unified-log.sh.
#   2. unified-log.sh exports the full API surface (both legacy
#      info/ok/warn/error/step/debug AND log_info/log_warn/log_error/
#      log_ok/log_and_tty).
#   3. Interactive mode (UNIFIED_LOG unwritable) emits to stderr with
#      no "Permission denied" leak from bash redirect errors.
#   4. Install-chain mode (UNIFIED_LOG writable) writes timestamped
#      lines to the log file and stays silent on stderr.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGGING_SH="$SCRIPT_DIR/../scripts/common/logging.sh"
UNIFIED_LOG_SH="$SCRIPT_DIR/../scripts/common/unified-log.sh"

pass=0
fail=0

assert() {
    local cond="$1" desc="$2"
    if eval "$cond"; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc"
        fail=$((fail + 1))
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" desc="$3"
    if grep -qF -- "$needle" <<<"$haystack"; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc (missing '$needle')"
        fail=$((fail + 1))
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" desc="$3"
    if ! grep -qF -- "$needle" <<<"$haystack"; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc (unexpected '$needle')"
        fail=$((fail + 1))
    fi
}

echo "=== Static checks ==="

assert '[[ -f "$LOGGING_SH" ]]' "logging.sh exists"
assert '[[ -f "$UNIFIED_LOG_SH" ]]' "unified-log.sh exists"
assert 'bash -n "$LOGGING_SH"' "logging.sh: bash -n clean"
assert 'bash -n "$UNIFIED_LOG_SH"' "unified-log.sh: bash -n clean"

# logging.sh must be a thin shim — under 30 LOC and source unified-log.sh.
loc=$(grep -cvE '^\s*(#|$)' "$LOGGING_SH")
if (( loc <= 10 )); then
    echo "  PASS: logging.sh is a thin shim ($loc non-comment lines)"
    pass=$((pass + 1))
else
    echo "  FAIL: logging.sh has $loc non-comment lines (expected <=10 — should be a shim)"
    fail=$((fail + 1))
fi

assert 'grep -qE "source.*unified-log\\.sh" "$LOGGING_SH"' \
       "logging.sh sources unified-log.sh"

# unified-log.sh must define both legacy and log_* APIs.
for fn in info ok warn error step debug log_info log_warn log_error log_ok log_and_tty log_msg; do
    assert "grep -qE '^${fn}\\(\\) \\{|^${fn}\\(\\) +\\{' \"\$UNIFIED_LOG_SH\"" \
           "unified-log.sh defines $fn()"
done

# Redirect-safety: every external redirect to UNIFIED_LOG / PROGRESS_LOG /
# PROGRESS_TTY must be wrapped in `{ ...; } 2>/dev/null` so bash's own
# "Permission denied" message is silenced.
for path in '\\$UNIFIED_LOG' '\\$PROGRESS_LOG' '\\$PROGRESS_TTY'; do
    bare=$(grep -nE ">>? *\"$path\"" "$UNIFIED_LOG_SH" \
        | grep -vE '\\{ .*>>? *"'"$path"'"; \\} 2>/dev/null' \
        | grep -vE '^[[:space:]]*#' \
        | grep -vE 'log_and_tty.*>' || true)
    if [[ -z "$bare" ]]; then
        echo "  PASS: every redirect to $path is wrapped"
        pass=$((pass + 1))
    else
        echo "  FAIL: bare redirect to $path:"
        echo "$bare" | sed 's/^/    /'
        fail=$((fail + 1))
    fi
done

echo
echo "=== Functional: interactive mode (UNIFIED_LOG unwritable) ==="

# Force unwritable UNIFIED_LOG by pointing at a path under /proc (read-only).
out=$(UNIFIED_LOG=/proc/snapmulti-cant-write-here bash -c "
    source '$LOGGING_SH'
    info 'msg-info'
    warn 'msg-warn'
    error 'msg-error'
    ok 'msg-ok'
    DEBUG=1 debug 'msg-debug'
    log_info 'msg-log-info'
" 2>&1)

assert_not_contains "$out" "Permission denied" \
    "no bash-level 'Permission denied' leak in interactive mode"
assert_contains "$out" "[INFO] msg-info" "info() prints to stderr"
assert_contains "$out" "[WARN] msg-warn" "warn() prints to stderr"
assert_contains "$out" "[ERROR] msg-error" "error() prints to stderr"
assert_contains "$out" "[OK] msg-ok" "ok() prints to stderr"
assert_contains "$out" "[DEBUG] msg-debug" "debug() honours DEBUG=1"
assert_contains "$out" "[INFO] msg-log-info" "log_info() prints to stderr (parity with info)"

# debug() must be silent without DEBUG=1.
silent=$(UNIFIED_LOG=/proc/snapmulti-cant-write bash -c "
    source '$LOGGING_SH'
    debug 'should-not-appear'
" 2>&1 || true)
assert_not_contains "$silent" "should-not-appear" \
    "debug() suppressed when DEBUG unset"

echo
echo "=== Functional: install-chain mode (UNIFIED_LOG writable) ==="

tmp_log=$(mktemp /tmp/snapmulti-test-log.XXXXXX)
trap "rm -f '$tmp_log'" EXIT

# Force interactive-detection off by pointing at a writable file. Capture
# stdout+stderr — install-chain mode must NOT emit anything to stderr.
combined=$(UNIFIED_LOG="$tmp_log" PROGRESS_TTY=/dev/null bash -c "
    source '$LOGGING_SH'
    info 'install-info'
    error 'install-error'
    log_and_tty 'install-tty'
" 2>&1)

assert_not_contains "$combined" "install-info" \
    "install-chain mode: info() does NOT leak to stderr"
assert_not_contains "$combined" "install-error" \
    "install-chain mode: error() does NOT leak to stderr (PROGRESS_TTY captures it)"

file_contents=$(cat "$tmp_log")
assert_contains "$file_contents" "[INFO ]" "log file gets [INFO ] tag"
assert_contains "$file_contents" "[ERROR]" "log file gets [ERROR] tag"
assert_contains "$file_contents" "install-info" "log file gets info message body"
assert_contains "$file_contents" "install-error" "log file gets error message body"
assert_contains "$file_contents" "install-tty" "log file gets log_and_tty body"

echo
echo "Results: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
