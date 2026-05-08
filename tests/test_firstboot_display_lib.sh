#!/usr/bin/env bash
# Verify firstboot.sh sources display.sh as the single source of truth
# (HDMI/DSI/DPI/DP/eDP) instead of its previous HDMI-only local function.
#
# Static check only — running firstboot.sh requires Pi hardware.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIRSTBOOT="$SCRIPT_DIR/../scripts/firstboot.sh"
DISPLAY_LIB="$SCRIPT_DIR/../client/common/scripts/display.sh"

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

echo "=== firstboot has_display source-of-truth ==="

# 1. firstboot must source display.sh from at least one staging path
assert 'grep -q "source \"\$_DISPLAY_LIB\"" "$FIRSTBOOT"' \
       "firstboot.sh sources \$_DISPLAY_LIB"

# 2. The fallback (in case display.sh missing) must NOT be the only path —
#    there must be a candidate loop trying the display.sh path first
assert 'grep -q "client/scripts/display.sh\\|common/scripts/display.sh" "$FIRSTBOOT"' \
       "firstboot.sh references the canonical display.sh path"

# 3. display.sh itself must support DSI/DPI/DP/eDP (not regress)
assert 'grep -qE "\\*-DSI-\\*\\|\\*-DPI-\\*" "$DISPLAY_LIB"' \
       "display.sh recognises DSI and DPI connectors"

assert 'grep -qE "\\*-DP-\\*\\|\\*-eDP-\\*" "$DISPLAY_LIB"' \
       "display.sh recognises DP and eDP connectors"

# 4. firstboot must not redefine has_display() unconditionally at top
#    level. The fallback definition lives inside an `else` branch and is
#    therefore indented; an un-indented `has_display()` would mean the
#    pre-PR-#311 duplicate has been re-introduced.
assert '! grep -qE "^has_display\\(\\)" "$FIRSTBOOT"' \
       "has_display() is no longer defined at top-level in firstboot.sh"

echo
if (( fail > 0 )); then
    echo "FAILED: $fail / $((pass + fail))"
    exit 1
fi
echo "All $pass tests passed!"
