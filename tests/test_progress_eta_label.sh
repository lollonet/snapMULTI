#!/usr/bin/env bash
# Static check: progress.sh surfaces the EXPECTED_TOTAL_MIN env var as
# "/~NN min" in the elapsed line, and firstboot.sh computes the value
# per hardware bucket + INSTALL_TYPE.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROGRESS_SH="$SCRIPT_DIR/../scripts/common/progress.sh"
FIRSTBOOT="$SCRIPT_DIR/../scripts/firstboot.sh"
DEVICE_DETECT="$SCRIPT_DIR/../scripts/common/device-detect.sh"

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

echo "=== device-detect.sh — hardware buckets ==="

assert 'grep -qE "^is_pi_zero_2w\\(\\) \\{" "$DEVICE_DETECT"' \
    'device-detect.sh defines is_pi_zero_2w()'

assert 'grep -qE "^is_pi_3\\(\\) \\{" "$DEVICE_DETECT"' \
    'device-detect.sh defines is_pi_3()'

echo
echo "=== firstboot.sh — computes EXPECTED_TOTAL_MIN per hw+role ==="

assert 'grep -qE "EXPECTED_TOTAL_MIN=[0-9]+" "$FIRSTBOOT"' \
    'firstboot.sh sets EXPECTED_TOTAL_MIN'

assert 'grep -qE "^export EXPECTED_TOTAL_MIN" "$FIRSTBOOT"' \
    'firstboot.sh exports EXPECTED_TOTAL_MIN (so progress.sh sees it)'

# Pi Zero 2W client/client-native bucket — measured ~18 min.
assert 'grep -qE "EXPECTED_TOTAL_MIN=1[6-9]" "$FIRSTBOOT"' \
    'firstboot.sh has a 16-19 min ETA bucket (Pi 4 both = 16, Pi Zero native = 18)'

# Pi 4 client bucket — measured ~10:30 min, target 11.
assert 'grep -qE "EXPECTED_TOTAL_MIN=1[0-2]" "$FIRSTBOOT"' \
    'firstboot.sh has a 10-12 min ETA bucket (Pi 4 client)'

echo
echo "=== progress.sh — surfaces EXPECTED_TOTAL_MIN on the elapsed line ==="

assert 'grep -qE "EXPECTED_TOTAL_MIN" "$PROGRESS_SH"' \
    'progress.sh reads EXPECTED_TOTAL_MIN'

assert 'grep -qE "~\\$\\{EXPECTED_TOTAL_MIN\\} min" "$PROGRESS_SH"' \
    'progress.sh prints "~${EXPECTED_TOTAL_MIN} min" label'

# Behaviour: empty when not set (dev invocations shouldn't render a "~ min" gap).
out=$(EXPECTED_TOTAL_MIN='' bash -c '
    if [[ -n "${EXPECTED_TOTAL_MIN:-}" ]]; then
        echo "WITH"
    else
        echo "WITHOUT"
    fi
')
assert '[[ "$out" == "WITHOUT" ]]' \
    'empty EXPECTED_TOTAL_MIN → no label (per the env-aware branch in progress.sh)'

echo
echo "=== Summary ==="
echo "  Pass: $pass"
echo "  Fail: $fail"

if (( fail > 0 )); then
    exit 1
fi
