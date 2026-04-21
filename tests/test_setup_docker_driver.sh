#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DOCKER_SH="$SCRIPT_DIR/../scripts/common/setup-docker.sh"
CLIENT_SETUP_SH="$SCRIPT_DIR/../client/common/scripts/setup.sh"

pass=0
fail=0

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

assert_not_contains() {
    local haystack="$1" needle="$2" desc="$3"
    if grep -qF -- "$needle" <<<"$haystack"; then
        echo "  FAIL: $desc (unexpected '$needle')"
        fail=$((fail + 1))
    else
        echo "  PASS: $desc"
        pass=$((pass + 1))
    fi
}

setup_docker_body="$(sed -n '/^setup_docker()/,/^}/p' "$SETUP_DOCKER_SH")"
readonly_body="$(sed -n '/^_configure_readonly()/,/^}/p' "$CLIENT_SETUP_SH")"

echo "Testing Docker storage driver selection..."

# setup_docker() should check actual filesystem state, not ENABLE_READONLY
assert_contains "$setup_docker_body" '/proc/mounts' "setup_docker gates on /proc/mounts (actual filesystem)"
# Check that ENABLE_READONLY is not used in executable code (comments are OK)
setup_docker_code=$(echo "$setup_docker_body" | grep -v '^\s*#')
assert_not_contains "$setup_docker_code" 'ENABLE_READONLY' "setup_docker code does not use ENABLE_READONLY flag"

# _configure_readonly() should write config but not wipe Docker
assert_contains "$readonly_body" 'tune_docker_daemon --live-restore --fuse-overlayfs' "readonly config writes fuse-overlayfs to daemon.json"
assert_not_contains "$readonly_body" 'rm -rf /var/lib/docker' "readonly config does not wipe Docker storage"
assert_contains "$readonly_body" 'fuse-overlayfs --version' "readonly config verifies fuse-overlayfs binary"
assert_contains "$readonly_body" 'activates after reboot' "readonly config defers driver switch to reboot"

echo ""
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
