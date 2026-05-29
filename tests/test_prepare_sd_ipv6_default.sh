#!/usr/bin/env bash
# Pin the ADR-008 default: prepare-sd.sh does NOT add ipv6.disable=1 to
# the cmdline unless DISABLE_IPV6=true is explicitly set.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREPARE_SD="$SCRIPT_DIR/../scripts/prepare-sd.sh"
PREPARE_PS1="$SCRIPT_DIR/../scripts/prepare-sd.ps1"

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

echo "=== prepare-sd.sh default polarity ==="

# Default must be 'false' (opt-IN to disable).
assert 'grep -qE "DISABLE_IPV6:-false" "$PREPARE_SD"' \
    'prepare-sd.sh uses ${DISABLE_IPV6:-false} (default IPv6 enabled)'

# Negative: must NOT default to true.
assert '! grep -qE "DISABLE_IPV6:-true" "$PREPARE_SD"' \
    'prepare-sd.sh does NOT default DISABLE_IPV6 to true'

# Banner messages reflect the new default.
assert 'grep -qE "IPv6 left enabled at kernel \(default" "$PREPARE_SD"' \
    'prepare-sd.sh banner says "IPv6 left enabled at kernel (default…)" on the default path'

assert 'grep -qE "DISABLE_IPV6=true" "$PREPARE_SD"' \
    'prepare-sd.sh banner references DISABLE_IPV6=true opt-in path'

echo
echo "=== prepare-sd.ps1 mirror ==="

assert 'grep -qE "disableIpv6 = .false." "$PREPARE_PS1"' \
    'prepare-sd.ps1 defaults $disableIpv6 to ''false'''

assert 'grep -qE "DISABLE_IPV6=true" "$PREPARE_PS1"' \
    'prepare-sd.ps1 banner references DISABLE_IPV6=true opt-in path'

echo
echo "=== ADR documents ==="

assert 'grep -qE "superseded by ADR-008" "$SCRIPT_DIR/../docs/adr/ADR-007.ipv4-only-lan-appliance.md"' \
    'ADR-007 marked superseded by ADR-008'

assert 'test -f "$SCRIPT_DIR/../docs/adr/ADR-008.ipv6-default-on.md"' \
    'ADR-008 document present'

echo
echo "=== Summary ==="
echo "  Pass: $pass"
echo "  Fail: $fail"

if (( fail > 0 )); then
    exit 1
fi
