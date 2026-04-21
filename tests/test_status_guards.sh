#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS_SH="$SCRIPT_DIR/../scripts/status.sh"

pass=0
fail=0

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

content="$(cat "$STATUS_SH")"

echo "Testing status.sh safety guards..."

assert_contains "$content" 'if [[ "$TOTAL" -eq 0 ]]; then' "status exits when no snapMULTI containers are found"
assert_contains "$content" 'error "No running snapMULTI containers found"' "status emits explicit no-container error"

echo ""
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
