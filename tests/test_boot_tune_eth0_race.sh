#!/usr/bin/env bash
# Static invariants on the eth0-DHCP wait in boot-tune.sh.
#
# Why pin these statically:
# - The race between boot-tune.service start and NetworkManager
#   eth0-DHCP-activated is exactly the kind of timing bug that
#   silently passes CI (no network in the test environment) but
#   breaks production. Observed on snapvideo 2026-05-31: both
#   eth0+wlan0 active, dual-mDNS risk, `conflict detected for
#   192.168.63.4 with host DC:A6:32:B4:C6:16` in NetworkManager
#   logs (the eth0 MAC of the same Pi).
# - A future refactor that "simplifies" the wait loop back to the
#   one-shot IP probe would re-introduce the bug. Lock it in.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../scripts/boot-tune.sh"

pass=0
fail=0

check() {
    local desc="$1" condition="$2"
    if eval "$condition" >/dev/null 2>&1; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc"
        fail=$((fail + 1))
    fi
}

echo "== boot-tune.sh eth0-DHCP race guard =="
check "script exists" "[[ -f '$SCRIPT' ]]"
check "checks /sys/class/net/eth0/carrier before probing IP" "grep -q '/sys/class/net/eth0/carrier' '$SCRIPT'"
check "skips IP probe when carrier is missing/zero (WiFi-only host short-circuit)" "awk '/eth_carrier=0/{a=1} a && /\\[\\[ \"\\\$eth_carrier\" == \"1\" \\]\\]/{b=1; exit} END{exit !b}' '$SCRIPT'"
check "uses a loop with bounded retries (DHCP completion wait)" "grep -qE 'for .* in \\\$\\(seq 1 [0-9]+\\)' '$SCRIPT'"
check "loop bound is at least 10 s (DHCP timeout headroom)" "grep -oE 'seq 1 [0-9]+' '$SCRIPT' | awk '{n=\$3; exit !(n>=10)}'"
check "loop exits on first IP found (break)" "awk '/for .* in \\\$\\(seq 1/{f=1} f && /break/{ok=1; exit} END{exit !ok}' '$SCRIPT'"
check "sleeps 1 s per iteration (loop bound = max wait in seconds)" "awk '/for .* in \\\$\\(seq 1/{f=1} f && /sleep 1$/{ok=1; exit} END{exit !ok}' '$SCRIPT'"
check "nmcli radio wifi off still fires when IP found" "grep -q 'nmcli radio wifi off' '$SCRIPT'"
check "nmcli radio wifi on still fires on the else branch" "grep -q 'nmcli radio wifi on' '$SCRIPT'"
check "logger trace mentions 'single mDNS' (observability for the dual-iface fix)" "grep -q 'single mDNS' '$SCRIPT'"

echo
echo "Results: $pass passed, $fail failed"
exit $fail
