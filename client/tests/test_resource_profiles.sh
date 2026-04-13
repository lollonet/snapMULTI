#!/usr/bin/env bash
# shellcheck disable=SC2034  # Variables assigned in case statement, used via indirect expansion ${!var}
set -euo pipefail

# Test resource profile detection and limits
# Sources detect_resource_profile() and set_resource_limits() from setup.sh
# to catch regressions when thresholds or limits change.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SH="$SCRIPT_DIR/../common/scripts/setup.sh"

# Extract set_resource_limits() from setup.sh (source of truth)
eval "$(sed -n '/^set_resource_limits()/,/^}/p' "$SETUP_SH")"

pass=0
fail=0

echo "Testing detect_resource_profile()..."

# detect_resource_profile() reads /proc/meminfo directly, so we extract it
# and replace the path with our mock file for testability.
test_detect() {
    local mem_mb="$1"
    local expected="$2"
    local desc="$3"
    local mock_meminfo

    mock_meminfo=$(mktemp)
    echo "MemTotal:       $((mem_mb * 1024)) kB" > "$mock_meminfo"
    trap 'rm -f "$mock_meminfo"' RETURN

    # Extract detect_resource_profile from setup.sh, replacing /proc/meminfo
    local fn_body
    fn_body=$(sed -n '/^detect_resource_profile()/,/^}/p' "$SETUP_SH" | sed "s|/proc/meminfo|$mock_meminfo|g")
    local profile
    profile=$(bash -c "$fn_body; detect_resource_profile")

    if [[ "$profile" == "$expected" ]]; then
        echo "  PASS: $desc (${mem_mb}MB -> ${profile})"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc (${mem_mb}MB -> ${profile}, expected ${expected})"
        fail=$((fail + 1))
    fi
}

# Test profile detection
test_detect "512"    "minimal"     "512MB RAM -> minimal"
test_detect "1024"   "minimal"     "1GB RAM -> minimal"
test_detect "2048"   "standard"    "2GB RAM -> standard"
test_detect "4096"   "performance" "4GB RAM -> performance"
test_detect "8192"   "performance" "8GB RAM -> performance"
test_detect "100"    "standard"    "Error case (low) -> standard fallback"

echo ""
echo "Testing set_resource_limits()..."

# set_resource_limits() is sourced directly from setup.sh above
test_limits() {
    local profile="$1"
    local var="$2"
    local expected="$3"
    local desc="$4"

    set_resource_limits "$profile"
    local actual="${!var:-}"

    if [[ "$actual" == "$expected" ]]; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc (${profile}.${var} = ${actual}, expected ${expected})"
        fail=$((fail + 1))
    fi
}

# Test minimal profile
test_limits "minimal" "SNAPCLIENT_MEM_LIMIT"    "64M"  "minimal snapclient memory"
test_limits "minimal" "VISUALIZER_MEM_LIMIT"    "128M" "minimal visualizer memory"
test_limits "minimal" "FBDISPLAY_MEM_LIMIT"     "192M" "minimal fb-display memory"
test_limits "minimal" "SNAPCLIENT_CPU_LIMIT"    "0.5"  "minimal snapclient cpu"

# Test standard profile
test_limits "standard" "SNAPCLIENT_MEM_LIMIT"   "64M"  "standard snapclient memory"
test_limits "standard" "VISUALIZER_MEM_LIMIT"   "128M" "standard visualizer memory"
test_limits "standard" "FBDISPLAY_MEM_LIMIT"    "256M" "standard fb-display memory"
test_limits "standard" "SNAPCLIENT_CPU_LIMIT"   "0.5"  "standard snapclient cpu"

# Test performance profile
test_limits "performance" "SNAPCLIENT_MEM_LIMIT"  "96M"  "performance snapclient memory"
test_limits "performance" "VISUALIZER_MEM_LIMIT"  "192M" "performance visualizer memory"
test_limits "performance" "FBDISPLAY_MEM_LIMIT"   "384M" "performance fb-display memory"
test_limits "performance" "SNAPCLIENT_CPU_LIMIT"  "1.0"  "performance snapclient cpu"

echo ""
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
