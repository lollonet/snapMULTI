#!/usr/bin/env bash
# Functional tests for the Audio output menu in prepare-sd.sh:
#
# - top menu (auto | hat | internal) returns the right slugs
# - HAT sub-menu enumerates client/common/audio-hats/*.conf and excludes
#   internal-audio + usb-audio
# - HAT sub-menu choice 0 maps back to "auto" (operator cancellation)
# - built-in sub-menu maps 1→hdmi, 2→jack
# - install.conf writer emits AUDIO_HAT and AUDIO_INTERNAL_OUTPUT lines
#
# We extract the relevant functions from prepare-sd.sh via sed and source
# them in a subshell — that keeps the test independent of the script's
# top-level driver code (which would expect a real SD card to be mounted).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREPARE_SD_SH="$SCRIPT_DIR/../scripts/prepare-sd.sh"
CLIENT_DIR_REAL="$SCRIPT_DIR/../client"

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

# Source the menu functions from prepare-sd.sh into the current shell. We
# pull just the function bodies (everything between `get_music_source()`
# and the next non-function top-level statement) and source them as text —
# the same approach test_avahi_readiness.sh uses for unit-file heredocs.
# CLIENT_DIR must be set for _list_supported_hats; we point it at the real
# client/ tree in this repo so the enumeration is genuine. shellcheck can't
# see the indirect reference inside `_list_supported_hats` (sourced via
# eval after we declare it), so the SC2034 disable below is acknowledged.
# shellcheck disable=SC2034
CLIENT_DIR="$CLIENT_DIR_REAL"
fn_block=$(sed -n '/^show_audio_menu()/,/^get_internal_output() {$/p' "$PREPARE_SD_SH")
# Append the closing 6-line body of get_internal_output (sed range stops at
# the opening brace — we need to include the body and closing brace).
fn_block+=$'\n'$(sed -n '/^get_internal_output() {$/,/^}$/p' "$PREPARE_SD_SH" | tail -n +2)
# shellcheck disable=SC1090
eval "$fn_block"

echo "=== Static checks ==="
for fn in show_audio_menu get_audio_type _list_supported_hats show_hat_menu \
          get_hat_choice show_internal_audio_menu get_internal_output; do
    if declare -F "$fn" >/dev/null; then
        echo "  PASS: $fn defined"
        pass=$((pass + 1))
    else
        echo "  FAIL: $fn not defined after sourcing"
        fail=$((fail + 1))
    fi
done

echo
echo "=== _list_supported_hats: enumeration ==="
hats_output=$(_list_supported_hats)
hat_count=$(printf '%s\n' "$hats_output" | grep -c '|' || true)
# 17 .conf files total, minus internal-audio and usb-audio = 15 HATs.
assert_eq "$hat_count" "15" "enumerates 15 supported HATs (17 confs - 2 reserved)"

# Required HATs that MUST appear in the list — these are real boards in the
# community and removing one is a regression.
for required in hifiberry-dac-std hifiberry-amp2 iqaudio-dac justboom-dac \
                allo-boss waveshare-wm8960 innomaker-dac-pro; do
    assert_contains "$hats_output" "$required|" "list includes $required"
done

# Reserved entries that MUST NOT appear (handled by other menu branches).
for excluded in internal-audio usb-audio; do
    if ! grep -qF "$excluded|" <<<"$hats_output"; then
        echo "  PASS: list excludes $excluded (covered by other menu branches)"
        pass=$((pass + 1))
    else
        echo "  FAIL: list should exclude $excluded"
        fail=$((fail + 1))
    fi
done

echo
echo "=== _list_supported_hats: HAT_NAME quoting ==="
# Friendly names come from HAT_NAME="..." — both single and double quotes
# must be stripped. Sample a known entry.
hifi_line=$(printf '%s\n' "$hats_output" | grep '^hifiberry-dac-std|')
hifi_name=${hifi_line#*|}
assert_eq "$hifi_name" "HiFiBerry DAC+ (Standard/clone)" "hifiberry-dac-std friendly name preserved"

echo
echo "=== get_audio_type: input → slug mapping ==="
# Drive the function with stdin and capture the slug. Trailing newline is
# normal — assert_eq compares exact strings.
result=$(echo "1" | get_audio_type)
assert_eq "$result" "auto" "input '1' → 'auto'"
result=$(echo "2" | get_audio_type)
assert_eq "$result" "hat" "input '2' → 'hat'"
result=$(echo "3" | get_audio_type)
assert_eq "$result" "internal" "input '3' → 'internal'"
# Invalid input keeps prompting; we send an invalid then a valid value.
result=$(printf 'x\n4\n2\n' | get_audio_type)
assert_eq "$result" "hat" "invalid inputs re-prompt until valid"

echo
echo "=== get_hat_choice: numeric input → slug mapping ==="
# 0 always returns auto (cancellation).
result=$(echo "0" | get_hat_choice)
assert_eq "$result" "auto" "input '0' → 'auto' (back/cancel)"
# Choice 1 should map to the first alphabetically-sorted HAT — known to be
# "Allo Boss DAC" (slug: allo-boss) from the static check above.
result=$(echo "1" | get_hat_choice)
assert_eq "$result" "allo-boss" "input '1' → first HAT alphabetically (allo-boss)"
# Choice 15 must map to the last HAT (Waveshare WM8960). If the count
# changes when someone adds/removes a .conf, this assertion will surface
# the change so the test stays calibrated.
result=$(echo "15" | get_hat_choice)
assert_eq "$result" "waveshare-wm8960" "input '15' → last HAT (waveshare-wm8960)"
# Out-of-range input re-prompts until valid.
result=$(printf '99\n0\n' | get_hat_choice)
assert_eq "$result" "auto" "out-of-range re-prompts; final 0 returns auto"

echo
echo "=== get_internal_output ==="
result=$(echo "1" | get_internal_output)
assert_eq "$result" "hdmi" "input '1' → 'hdmi'"
result=$(echo "2" | get_internal_output)
assert_eq "$result" "jack" "input '2' → 'jack'"

echo
echo "=== install.conf heredoc emits new keys ==="
# Source the actual prepare-sd.sh heredoc block (where install.conf is
# written) and check that it includes the two new keys. We grep the
# script text directly because rendering the heredoc would require
# bootstrapping the whole driver.
assert_contains "$(<"$PREPARE_SD_SH")" "AUDIO_HAT=\$AUDIO_HAT" "install.conf heredoc writes AUDIO_HAT"
assert_contains "$(<"$PREPARE_SD_SH")" "AUDIO_INTERNAL_OUTPUT=\$AUDIO_INTERNAL_OUTPUT" "install.conf heredoc writes AUDIO_INTERNAL_OUTPUT"

echo
echo "Results: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
