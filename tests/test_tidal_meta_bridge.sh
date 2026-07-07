#!/usr/bin/env bash
# Unit tests for scripts/tidal/tidal-meta-bridge.sh extract_field().
#
# speaker_controller_application renders a two-panel curses TUI. tmux
# captures it with the vertical border rendered as literal 'x':
#
#   xNow playing            xxSession info           x
#   xartists: <value>       xxapp_id: tidal          x
#   xalbum name: <value>    xxsession state: ...     x
#
# The left-panel value must be trimmed at the "xx" panel junction. Two
# junction shapes exist:
#   - PADDED: the value is shorter than the panel, so 2+ spaces of column
#     padding sit before "xx".
#   - FULL-WIDTH: a long value (e.g. an album name) fills the whole left
#     panel with no padding and runs flush into "xx<label>:" of the right
#     panel — the bug in this issue ("...Greatestxxapp_id: tidal").
#
# NB: the TUI physically truncates a value to the panel width, so a very
# long album is clipped by the renderer BEFORE the bridge ever sees it —
# extract_field can only strip the junk, not restore the clipped tail.
#
# bash 3.2 compatible.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE="$SCRIPT_DIR/../scripts/tidal/tidal-meta-bridge.sh"

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

# Run extract_field in an isolated subshell so the bridge's `set -euo
# pipefail` + EXIT trap don't leak into the test shell. LIB_ONLY=1 stops
# the script before its blocking capture loop.
ef() {
    local prefix="$1" output="$2"
    TIDAL_META_BRIDGE_LIB_ONLY=1 bash -c '
        source "$0"
        extract_field "$1" "$2"
    ' "$BRIDGE" "$prefix" "$output" 2>/dev/null
}

echo "== extract_field: full-width junction (long album flush into right panel) =="
# Album fills the left panel and runs flush into the right panel's app_id
# field with no padding — the reported garbage.
album_bug="xalbum name: The White Stripes Greatestxxapp_id: tidal                        x"
assert_eq "$(ef 'xalbum name: ' "$album_bug")" \
    "The White Stripes Greatest" \
    "full-width album trimmed at xx<label> junction (no xxapp_id garbage)"

echo "== extract_field: padded junction (unchanged behaviour) =="
album_pad="xalbum name: OK Computer                xxsession state: connected            x"
assert_eq "$(ef 'xalbum name: ' "$album_pad")" \
    "OK Computer" \
    "padded album trimmed at 2-space + xx junction"

title_pad="xtitle: Seven Nation Army               xxsession state: connected            x"
assert_eq "$(ef 'xtitle: ' "$title_pad")" \
    "Seven Nation Army" \
    "padded title trimmed cleanly"

echo "== extract_field: content containing 'xx' is preserved =="
# The artist "Jamie xx" has a single space before "xx" then column padding
# then the real junction. Must NOT be truncated to "Jamie".
artist_xx="xartists: Jamie xx                      xxapp_id: tidal                        x"
assert_eq "$(ef 'xartists: ' "$artist_xx")" \
    "Jamie xx" \
    "artist 'Jamie xx' survives (junction is the padded one, not the content xx)"

echo "== extract_field: no right panel / clean value =="
plain="xtitle: Untitled                        x"
assert_eq "$(ef 'xtitle: ' "$plain")" \
    "Untitled" \
    "value with only the trailing border x is trimmed"

echo "== extract_field: picks the right line out of a full capture =="
capture="lqqqqqqqqqqqqqqqklqqqqqqqqqqqqqqqk
xNow playing         xxSession info         x
xartists: The White Stripes             xxapp_id: tidal                        x
xtitle: Seven Nation Army               xxsession state: connected             x
xalbum name: The White Stripes Greatestxxapp_id: tidal                        x
mqqqqqqqqqqqqqqqjmqqqqqqqqqqqqqqqj"
assert_eq "$(ef 'xartists: ' "$capture")" "The White Stripes" "artists picked from multi-line capture"
assert_eq "$(ef 'xtitle: ' "$capture")"   "Seven Nation Army" "title picked from multi-line capture"
assert_eq "$(ef 'xalbum name: ' "$capture")" "The White Stripes Greatest" "album picked + trimmed from multi-line capture"

echo "== extract_field: missing field yields empty =="
assert_eq "$(ef 'xalbum name: ' "$capture" ; :)" "$(ef 'xalbum name: ' "$capture")" "deterministic on repeat"
no_album="xtitle: Something               xxapp_id: tidal              x"
assert_eq "$(ef 'xalbum name: ' "$no_album")" "" "absent field returns empty string"

echo ""
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
