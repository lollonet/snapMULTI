#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PS1_FILE="$SCRIPT_DIR/../scripts/prepare-sd.ps1"

pass=0
fail=0

assert_contains() {
    local haystack="$1" needle="$2" desc="$3"
    if grep -qF "$needle" <<<"$haystack"; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc (missing '$needle')"
        fail=$((fail + 1))
    fi
}

content="$(cat "$PS1_FILE")"

echo "Testing prepare-sd.ps1 parity guards..."

assert_contains "$content" 'function Update-UserDataRuncmd' "user-data patch helper exists"
assert_contains "$content" "common/unified-log.sh" "unified-log is verified"
assert_contains "$content" "common/install-deps.sh" "install-deps is verified"
assert_contains "$content" "common/setup-docker.sh" "setup-docker is verified"
assert_contains "$content" "common/wait-network.sh" "wait-network is verified"
assert_contains "$content" "common/mount-music.sh" "mount-music is verified"
assert_contains "$content" "WriteAllText((Join-Path \$Dest 'server/.version'), \$gitVersion, \$Utf8NoBom)" "server version uses UTF-8 without BOM"
assert_contains "$content" "WriteAllText((Join-Path \$Dest 'client/VERSION'), \$gitVersion, \$Utf8NoBom)" "client version uses UTF-8 without BOM"
assert_contains "$content" 'Assert-PreparedSdCard -Dest $Dest -Boot $Boot -InstallType $InstallType' "verification runs before eject"
assert_contains "$content" "runcmd:\\s*(\\[\\]|null|~)?" "inline/empty runcmd cases handled"

echo ""
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
