#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034  # assert() conditions are eval'd, single quotes intentional.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP="$SCRIPT_DIR/../client/common/scripts/setup.sh"

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

line_no() {
    local pattern="$1"
    grep -n "$pattern" "$SETUP" | head -1 | cut -d: -f1
}

echo "Testing setup.sh test-tone ordering..."

tone_def=$(line_no '^_play_test_tone()')
apply_def=$(line_no '^_apply_boot_config()')
apply_call=$(line_no '^_apply_boot_config$')
tone_call=$(line_no '^_play_test_tone$')
dtoverlay_line=$(line_no 'sudo dtoverlay "$HAT_OVERLAY"')

assert '[[ -n "$tone_def" ]]' "test tone is wrapped in _play_test_tone()"
assert '[[ -n "$apply_call" && -n "$tone_call" && "$tone_call" -gt "$apply_call" ]]' \
       "test tone runs after _apply_boot_config"
assert '[[ -n "$dtoverlay_line" && "$tone_call" -gt "$dtoverlay_line" ]]' \
       "test tone runs after runtime dtoverlay attempt"
assert '[[ "$tone_def" -lt "$apply_def" ]]' \
       "_play_test_tone is defined before boot-config function"
assert 'grep -qF "aplay -l" "$SETUP"' \
       "test tone checks ALSA card visibility before speaker-test"
assert 'grep -qF "not visible yet" "$SETUP"' \
       "missing runtime ALSA card is skipped, not warned as playback failure"

echo ""
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
