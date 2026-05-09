#!/usr/bin/env bash
# shellcheck disable=SC2016
#
# Static + functional checks for the Tidal position parser fix.
#
# The bug: speaker_controller_application renders the TUI panel border as
# a literal "x" character (the same that prefixes "xartists:" / "xtitle:"
# fields). After strip_escapes (which only handles ANSI/C1 controls) and
# ltrim-spaces, the position line still looks like:
#
#   x  38 / 227                          xx
#
# The previous anchored regex `^[0-9]+' '*/' '*[0-9]+$` could never match
# a line starting with `x`, so POSITION stayed 0 and the Tidal progress
# bar never advanced.
#
# The fix: anchorless regex `([0-9]+)[[:space:]]*/[[:space:]]*([0-9]+)`
# with BASH_REMATCH capture, so the position pattern is found anywhere
# in the line.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE="$SCRIPT_DIR/../scripts/tidal/tidal-meta-bridge.sh"

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

echo "=== Static checks ==="

# The new anchorless regex must be present.
assert 'grep -qE "\\[0-9\\]\\+\\)\\[\\[:space:\\]\\]\\*/\\[\\[:space:\\]\\]\\*\\(\\[0-9\\]\\+" "$BRIDGE"' \
       'tidal-meta-bridge uses anchorless ([0-9]+)[[:space:]]*/[[:space:]]*([0-9]+) regex'

assert 'grep -qE "BASH_REMATCH\\[1\\]" "$BRIDGE"' \
       'POSITION is extracted via BASH_REMATCH[1]'

# The old anchored regex is gone (was the bug).
assert '! grep -qE "\\^\\[0-9\\]\\+. ./.*\\[0-9\\]\\+\\\$" "$BRIDGE"' \
       'old anchored ^[0-9]+...$ regex is removed'

echo
echo "=== Functional: extract POSITION from real-world TUI lines ==="

# Replicate the parser logic and feed it lines as they actually appear
# in tmux captures from speaker_controller_application.
parse_position() {
    local OUTPUT="$1" line POSITION=0
    while IFS= read -r line; do
        if [[ "$line" =~ ([0-9]+)[[:space:]]*/[[:space:]]*([0-9]+) ]]; then
            POSITION="${BASH_REMATCH[1]}"
            break
        fi
    done <<< "$OUTPUT"
    printf '%s' "$POSITION"
}

# Real TUI line with leading panel `x` + padding (the case that was broken).
result=$(parse_position "x  38 / 227                          xx")
assert_eq "$result" "38" "TUI line 'x  38 / 227 ... xx' → POSITION=38"

result=$(parse_position "x42 / 180                            xx")
assert_eq "$result" "42" "TUI line 'x42 / 180 ... xx' (no inner spaces) → POSITION=42"

# Edge: tight spacing (the format that DID work in the old regex).
result=$(parse_position "38 / 227")
assert_eq "$result" "38" "Bare '38 / 227' (legacy) → POSITION=38"

# Multi-line capture — must hit the position line, not artist/duration.
multiline='xartists: Jamie xx                  xx
xduration: 227000                       xx
x  38 / 227                              xx
xPlaybackState::PLAYING                  xx'
result=$(parse_position "$multiline")
assert_eq "$result" "38" "multi-line capture extracts POSITION from the right line"

# Non-position lines must NOT match (no false positive).
result=$(parse_position "xartists: Jamie xx                  xx
xduration: 227000                       xx")
assert_eq "$result" "0" "lines without N/M pattern → POSITION stays at 0"

# Empty / no-match input.
result=$(parse_position "")
assert_eq "$result" "0" "empty input → POSITION=0"

echo
echo "=== Bash syntax ==="
if bash -n "$BRIDGE"; then
    echo "  PASS: bash -n tidal-meta-bridge.sh"
    pass=$((pass + 1))
else
    echo "  FAIL: bash -n tidal-meta-bridge.sh"
    fail=$((fail + 1))
fi

echo
echo "=== Summary ==="
echo "  Pass: $pass"
echo "  Fail: $fail"

[[ "$fail" -eq 0 ]]
