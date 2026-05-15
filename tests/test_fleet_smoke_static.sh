#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET_SH="$SCRIPT_DIR/../scripts/fleet-smoke.sh"

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

assert_not_contains() {
    local haystack="$1" needle="$2" desc="$3"
    if grep -qF -- "$needle" <<<"$haystack"; then
        echo "  FAIL: $desc (found '$needle')"
        fail=$((fail + 1))
    else
        echo "  PASS: $desc"
        pass=$((pass + 1))
    fi
}

# Read the whole file: there is no reason for a portability guard to
# skip lines, and the 1,340 window left a regression window in the
# final exit block (claude-review PR #400).
src="$(cat "$FLEET_SH")"

echo "Testing fleet-smoke.sh static portability and rendering guards..."

assert_not_contains "$src" "mapfile" "does not require Bash 4 mapfile (macOS /bin/bash safe)"
assert_contains "$src" "non_snapmulti" "tracks reachable non-snapMULTI peers explicitly"
assert_contains "$src" '"SKIP"' "renders non-snapMULTI peers as SKIP, not PASS"
assert_contains "$src" "version drift vs" "surfaces version drift in fleet table"
assert_contains "$src" "baseline_version" "computes a server baseline version for drift detection"
assert_contains "$src" "DISCONNECTED_CLIENTS_JSON" "tracks disconnected paired clients separately"
assert_contains "$src" "disconnected_clients" "exposes disconnected paired clients in JSON output"
assert_contains "$src" "Disconnected paired clients:" "lists disconnected paired clients in text output"
assert_contains "$src" "CONNECTED_NON_SNAPMULTI_JSON" "tracks connected non-snapMULTI Snapcast clients separately"
assert_contains "$src" "connected_non_snapmulti_clients" "exposes connected non-snapMULTI clients in JSON output"
assert_contains "$src" "Connected non-snapMULTI clients:" "lists connected non-snapMULTI clients in text output"
assert_contains "$src" "trap - EXIT" "parallel probe workers do not inherit tmpdir cleanup trap"

# Regression guard against the historic "device-smoke exit 1 + valid
# JSON" concat bug. The previous `|| echo "{}"` form appended a second
# JSON document on failure, so a host with real failures got reported
# as having an empty smoke object (the python json.loads parser raised
# JSONDecodeError and fell back to {}). Two indicators of the fix.
assert_not_contains "$src" '|| echo "{}")' \
    'no `|| echo "{}"` concat on smoke JSON capture (would mask failures)'
assert_contains "$src" "raw_decode" \
    "python parser uses raw_decode (belt-and-suspenders against trailing garbage)"

# Functional: replay the exact parse logic against synthetic inputs.
python3 - <<'PY'
import json, sys

def parse(raw):
    raw = (raw or "").strip()
    if not raw:
        return {}
    try:
        smoke, _ = json.JSONDecoder().raw_decode(raw)
        return smoke
    except json.JSONDecodeError:
        return {}

cases = [
    # The exact historic bug: device-smoke exit 1 + valid JSON appended with {}
    ('{"records":[{"status":"fail","name":"snapserver"}]}\n{}',
     {"records":[{"status":"fail","name":"snapserver"}]},
     "concatenated JSON keeps the first (real) document"),
    # Normal pass
    ('{"records":[{"status":"pass","name":"x"}]}',
     {"records":[{"status":"pass","name":"x"}]},
     "valid single-document parse"),
    # Empty input
    ('', {}, "empty input -> {}"),
    # Garbage prefix -> {}
    ('not-json-at-all', {}, "non-JSON garbage -> {}"),
    # Whitespace before JSON
    ('   {"a":1}\n', {"a":1}, "leading whitespace tolerated"),
]
failed = 0
for raw, expected, desc in cases:
    got = parse(raw)
    if got == expected:
        print(f"  PASS: {desc}")
    else:
        print(f"  FAIL: {desc} (got {got!r}, expected {expected!r})")
        failed += 1
sys.exit(failed)
PY
rc=$?
if (( rc > 5 )); then
    echo "  FAIL: python helper crashed (rc=$rc) — all 5 subtests counted as failed"
    fail=$((fail + 5))
elif (( rc == 0 )); then
    pass=$((pass + 5))
else
    fail=$((fail + rc))
    pass=$((pass + 5 - rc))
fi

echo ""
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
