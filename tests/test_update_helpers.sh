#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPDATE_SH="$SCRIPT_DIR/../scripts/update.sh"

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

assert_status() {
    local expected="$1" desc="$2"
    shift 2
    if "$@"; then
        actual=0
    else
        actual=$?
    fi
    if [[ "$actual" == "$expected" ]]; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc (got exit $actual, expected $expected)"
        fail=$((fail + 1))
    fi
}

eval "$(sed -n '/^parse_latest_tag()/,/^}/p' "$UPDATE_SH")"
eval "$(sed -n '/^compare_versions()/,/^}/p' "$UPDATE_SH")"

echo "Testing update.sh helper semantics..."

compact_json='{"tag_name":"v1.2.3","name":"snapMULTI"}'
spaced_json='{"tag_name": "v2.0.1", "name": "snapMULTI"}'

assert_eq "$(parse_latest_tag "$compact_json")" "v1.2.3" "parse_latest_tag handles compact JSON"
assert_eq "$(parse_latest_tag "$spaced_json")" "v2.0.1" "parse_latest_tag handles spaced JSON"

assert_status 1 "compare_versions allows update from unknown local version" compare_versions "unknown" "v1.4.0"
assert_status 0 "compare_versions returns same-version status" compare_versions "v1.4.0" "v1.4.0"

echo ""
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
