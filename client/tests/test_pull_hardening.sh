#!/usr/bin/env bash
set -euo pipefail

# Test install hardening: disk space check and _pull_one retry logic.
# Uses mocks for docker compose and df to test without real Docker.

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

# ── Disk space check ──────────────────────────────────────────────

echo "Testing disk space pre-flight check..."

# Simulate df -BM --output=avail output and test the parsing + threshold
test_disk_check() {
    local avail_mb="$1" should_fail="$2" desc="$3"

    # The logic from setup.sh:
    #   _avail_mb=$(df -BM --output=avail "$INSTALL_DIR" 2>/dev/null | tail -1 | tr -d ' M')
    #   if [[ -n "$_avail_mb" ]] && [[ "$_avail_mb" -lt 1024 ]]; then exit 1; fi
    local _avail_mb="$avail_mb"
    local result="pass"
    if [[ -n "$_avail_mb" ]] && [[ "$_avail_mb" -lt 1024 ]]; then
        result="fail"
    fi

    assert_eq "$result" "$should_fail" "$desc"
}

test_disk_check "500"  "fail" "500MB free -> should fail"
test_disk_check "1023" "fail" "1023MB free -> should fail"
test_disk_check "1024" "pass" "1024MB free -> should pass"
test_disk_check "2048" "pass" "2048MB free -> should pass"
test_disk_check ""     "pass" "empty (df failed) -> fail-open"

# Test df output parsing (the actual df -BM output format)
echo ""
echo "Testing df output parsing..."

test_df_parse() {
    local df_output="$1" expected="$2" desc="$3"

    local parsed
    parsed=$(echo "$df_output" | tail -1 | tr -d ' M')

    assert_eq "$parsed" "$expected" "$desc"
}

test_df_parse "  Avail
  2048M" "2048" "Standard df -BM output"
test_df_parse "  Avail
    512M" "512" "Padded df output"
test_df_parse "  Avail
 22016M" "22016" "Large disk"

# ── _pull_one retry logic ─────────────────────────────────────────

echo ""
echo "Testing _pull_one retry logic..."

# Create a temp dir for the test
_test_tmp=$(mktemp -d)
trap 'rm -rf "$_test_tmp"' EXIT

# Mock docker compose pull: reads a counter file and fails N times
_mock_pull_counter="$_test_tmp/pull-counter"

# Mock log_progress (no-op in tests)
log_progress() { :; }

# Recreate _pull_one with mocked docker compose
_pull_one_mock() {
    local svc="$1"
    local log="$_test_tmp/pull-$svc"
    local delays=(0 0 0)  # no actual sleep in tests
    for i in 0 1 2; do
        [[ ${delays[$i]} -gt 0 ]] && sleep "${delays[$i]}"
        # Mock: read counter, decrement, fail if > 0
        local count
        count=$(cat "$_mock_pull_counter" 2>/dev/null || echo 0)
        if [[ "$count" -le 0 ]]; then
            echo "pull succeeded" >"$log"
            rm -f "$log"
            return 0
        fi
        echo "pull failed (attempt)" >"$log"
        echo $((count - 1)) > "$_mock_pull_counter"
    done
    tail -5 "$log" 2>/dev/null
    rm -f "$log"
    return 1
}

# Test: succeed on first attempt
echo "0" > "$_mock_pull_counter"
if _pull_one_mock "test-svc"; then
    assert_eq "ok" "ok" "Succeed on first attempt"
else
    assert_eq "fail" "ok" "Succeed on first attempt"
fi

# Test: fail once, succeed on retry
echo "1" > "$_mock_pull_counter"
if _pull_one_mock "test-svc"; then
    assert_eq "ok" "ok" "Fail once, succeed on second attempt"
else
    assert_eq "fail" "ok" "Fail once, succeed on second attempt"
fi

# Test: fail twice, succeed on third
echo "2" > "$_mock_pull_counter"
if _pull_one_mock "test-svc"; then
    assert_eq "ok" "ok" "Fail twice, succeed on third attempt"
else
    assert_eq "fail" "ok" "Fail twice, succeed on third attempt"
fi

# Test: fail all 3 attempts
echo "99" > "$_mock_pull_counter"
if _pull_one_mock "test-svc"; then
    assert_eq "ok" "fail" "Fail all 3 attempts -> should return 1"
else
    assert_eq "fail" "fail" "Fail all 3 attempts -> should return 1"
fi

# Test: temp files cleaned up on success
echo "0" > "$_mock_pull_counter"
_pull_one_mock "cleanup-test" >/dev/null 2>&1
if [[ ! -f "$_test_tmp/pull-cleanup-test" ]]; then
    assert_eq "ok" "ok" "Temp file removed on success"
else
    assert_eq "leaked" "ok" "Temp file removed on success"
fi

# ── Summary ───────────────────────────────────────────────────────

echo ""
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
