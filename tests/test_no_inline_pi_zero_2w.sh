#!/usr/bin/env bash
# Anti-drift gate — Bundle B1 step s10.
#
# scripts/common/device-detect.sh is the SINGLE authority for Pi Zero 2W
# detection. Two forms of regression we want to catch:
#
# 1. Inline `[[ "$model" == *"Zero 2 W"* ]]` outside device-detect.sh —
#    bypasses the helper, drifts as device-detect.sh evolves (cache,
#    error handling, alternate model strings).
#
# 2. Direct `tr -d '\0' </proc/device-tree/model` reads outside
#    device-detect.sh — same drift risk, plus no caching.
#
# Both gates allow hits inside:
#   - scripts/common/device-detect.sh (the canonical owner)
#   - tests/ (test fixtures may construct model strings as input)
#   - comments (explanatory text in any file)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

pass=0
fail=0

# Helper: strip lines that are comments (after optional leading whitespace).
# We use awk to inspect the post-colon text of grep output and skip lines
# whose first non-whitespace character is '#'.
strip_comments() {
    awk -F: '{
        # Reassemble everything after the first two colons as the
        # source code line; the first two fields are file + line number.
        code = ""
        for (i = 3; i <= NF; i++) {
            code = (i == 3 ? $i : code ":" $i)
        }
        # Trim leading whitespace.
        sub(/^[ \t]+/, "", code)
        # Skip pure comment lines.
        if (substr(code, 1, 1) == "#") next
        print $0
    }'
}

echo "=== Gate 1: inline [[ ... Zero 2 W ... ]] outside device-detect.sh ==="
violators=$( {
    cd "$REPO_DIR"
    git grep -nE '\[\[.*Zero 2 W' scripts/ client/ 2>/dev/null \
        | grep -v 'scripts/common/device-detect.sh' \
        | grep -v 'tests/' \
        | strip_comments
} || true )
if [[ -z "$violators" ]]; then
    echo "  PASS: no inline [[ ... Zero 2 W ]] checks outside device-detect.sh"
    pass=$((pass + 1))
else
    echo "  FAIL: inline Zero 2 W checks found — route through is_pi_zero_2w():"
    echo "$violators" | sed 's/^/    /'
    fail=$((fail + 1))
fi

echo
echo "=== Gate 2: direct /proc/device-tree/model reads outside device-detect.sh ==="
violators=$( {
    cd "$REPO_DIR"
    git grep -nE '/proc/device-tree/model' scripts/ client/ 2>/dev/null \
        | grep -v 'scripts/common/device-detect.sh' \
        | grep -v 'tests/' \
        | strip_comments
} || true )
if [[ -z "$violators" ]]; then
    echo "  PASS: no direct /proc/device-tree/model reads outside device-detect.sh"
    pass=$((pass + 1))
else
    echo "  FAIL: direct /proc/device-tree/model reads — use device_model():"
    echo "$violators" | sed 's/^/    /'
    fail=$((fail + 1))
fi

echo
echo "Results: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
