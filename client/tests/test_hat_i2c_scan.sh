#!/usr/bin/env bash
# Unit tests for hat_from_i2c_scan (audio-hat-detect.sh): maps an
# `i2cdetect -y 1` table to a HAT profile for EEPROM-less boards.
#
# Key regression: a PCM5122 at 0x4c (IQaudio DAC+ / Raspberry Pi DAC+
# family) must map to iqaudio-dac — the upstream iqaudio-dacplus overlay
# declares pcm5122@4c, whereas hifiberry-dacplus-std hard-codes
# pcm5122@4d and would never bind a board at 0x4c.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/scripts/audio-hat-detect.sh
source "$SCRIPT_DIR/../common/scripts/audio-hat-detect.sh"

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

# Build an i2cdetect -y table with the given addresses present (lowercase
# hex, e.g. 4c) and optional addresses shown as UU (driver-bound).
scan_table() {
    local present=" $1 " bound=" ${2:-} " row col addr line
    echo "     0  1  2  3  4  5  6  7  8  9  a  b  c  d  e  f"
    for row in 0 1 2 3 4 5 6 7; do
        line="${row}0:"
        for col in 0 1 2 3 4 5 6 7 8 9 a b c d e f; do
            addr="${row}${col}"
            if [[ "$row" == 0 && "$col" =~ ^[0-2]$ ]] || [[ "$row" == 7 && "$col" =~ ^[8-9a-f]$ ]]; then
                line+="   "
            elif [[ "$present" == *" $addr "* ]]; then
                line+=" $addr"
            elif [[ "$bound" == *" $addr "* ]]; then
                line+=" UU"
            else
                line+=" --"
            fi
        done
        echo "$line"
    done
}

result() { hat_from_i2c_scan "$1" 2>/dev/null || echo "none"; }

echo "Testing hat_from_i2c_scan..."
assert_eq "$(result "$(scan_table "4c")")" "iqaudio-dac"       "PCM5122 at 0x4c → iqaudio-dac (iqaudio-dacplus overlay, pcm5122@4c)"
assert_eq "$(result "$(scan_table "4d")")" "hifiberry-dac-std" "PCM5122 at 0x4d → hifiberry-dac-std (pcm5122@4d)"
assert_eq "$(result "$(scan_table "4e")")" "hifiberry-dac-std" "PCM5122 at 0x4e → previous std fallback"
assert_eq "$(result "$(scan_table "4f")")" "hifiberry-dac-std" "PCM5122 at 0x4f → previous std fallback"
assert_eq "$(result "$(scan_table "1a")")" "waveshare-wm8960"  "WM8960 at 0x1a"
assert_eq "$(result "$(scan_table "3b")")" "hifiberry-digi"    "WM8804 at 0x3b"
assert_eq "$(result "$(scan_table "")")"   "none"              "empty bus → no match"
assert_eq "$(result "$(scan_table "" "4c 4d")")" "none"        "UU (driver already bound) → no match"
assert_eq "$(result "$(scan_table "14 c4")")" "none"           "addresses that merely contain 4c/1a digits do not match"
assert_eq "$(result "$(scan_table "1a 4d")")" "hifiberry-dac-std" "PCM5122 wins over WM8960 when both answer"

echo ""
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
