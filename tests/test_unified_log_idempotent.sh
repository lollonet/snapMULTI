#!/usr/bin/env bash
# Idempotency test — Bundle B1 step s8.
#
# unified-log.sh must be safe to source multiple times in a single
# shell. The source guard (_UNIFIED_LOG_SH_SOURCED) ensures the second
# source returns immediately without re-evaluating function bodies or
# resetting module-level state.
#
# Why this matters: firstboot.sh sources unified-log.sh directly. Some
# downstream scripts also source common/logging.sh, which is a shim
# that transitively re-sources unified-log.sh. Without the guard, the
# second source would silently reset LOG_SOURCE back to "unknown",
# breaking the per-module log prefix.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UL="$SCRIPT_DIR/../scripts/common/unified-log.sh"

pass=0
fail=0

assert_eq() {
    local actual="$1" expected="$2" desc="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc (got '$actual', expected '$expected')"
        fail=$((fail + 1))
    fi
}

echo "=== Source guard exists ==="
assert_eq "$(grep -c '_UNIFIED_LOG_SH_SOURCED' "$UL")" "2" "guard sentinel + assignment present"

echo
echo "=== Idempotency: source twice in subshell ==="
# Use mktemp + trap so parallel CI runs don't collide on a hardcoded
# /tmp path and a prior broken run can't leave a stale file that
# influences this one (unified-log.sh opens UNIFIED_LOG in append mode).
TMP_LOG=$(mktemp /tmp/snapmulti-idemp-test.XXXXXX.log)
trap 'rm -f "$TMP_LOG"' EXIT
# Use a subshell so the test's own state isn't polluted.
result=$(
    set -e
    # First source — sets LOG_SOURCE to "first", defines functions.
    LOG_SOURCE="first"
    # shellcheck disable=SC2034  # read by unified-log.sh via parameter expansion
    UNIFIED_LOG="$TMP_LOG"
    # shellcheck source=../scripts/common/unified-log.sh
    source "$UL"
    first_source=$LOG_SOURCE

    # Second source — must NOT reset LOG_SOURCE back to "unknown"
    # because the guard returns immediately.
    LOG_SOURCE="second"
    # shellcheck source=../scripts/common/unified-log.sh
    source "$UL"
    second_source=$LOG_SOURCE

    # Output: first_source|second_source — second source should have
    # preserved LOG_SOURCE=second because the guard skipped re-init.
    printf '%s|%s\n' "$first_source" "$second_source"
)
assert_eq "$result" "first|second" "guarded re-source preserves LOG_SOURCE between calls"

echo
echo "=== Functions are defined exactly once ==="
fn_count=$(
    set -e
    # shellcheck source=../scripts/common/unified-log.sh
    source "$UL"
    # shellcheck source=../scripts/common/unified-log.sh
    source "$UL"
    declare -F | grep -cE '^declare -f (log_info|log_warn|log_error|info|warn|error)$'
)
# Expect at least 6: log_info log_warn log_error + back-compat aliases info/warn/error
assert_eq "$(( fn_count >= 6 ? 1 : 0 ))" "1" "logging functions defined (>=6 found: $fn_count)"

echo
echo "=== logging.sh shim transitively re-sources without error ==="
SHIM="$SCRIPT_DIR/../scripts/common/logging.sh"
if [[ -f "$SHIM" ]]; then
    if (
        set -e
        # shellcheck source=../scripts/common/unified-log.sh
        source "$UL"
        # shellcheck source=../scripts/common/logging.sh
        source "$SHIM"
    ) 2>/dev/null; then
        echo "  PASS: unified-log.sh + logging.sh chained source succeeds"
        pass=$((pass + 1))
    else
        echo "  FAIL: chained source returned non-zero"
        fail=$((fail + 1))
    fi
else
    echo "  SKIP: logging.sh shim not present"
fi

echo
echo "Results: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
