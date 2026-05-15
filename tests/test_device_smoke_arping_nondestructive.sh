#!/usr/bin/env bash
# Tests for _net_check_arping in scripts/device-smoke.sh.
#
# Earlier versions invoked `arping -D` (RFC 5227 Duplicate Address
# Detection). On hosts where NetworkManager adopts Docker bridges as
# "externally connected" — the default in both/client mode — the DAD
# probe's address-state flicker on eth0 cascades into an avahi-daemon
# host name conflict and renames the host to <hostname>-2. This test
# asserts that the destructive `arping -D` form has been replaced with
# a non-DAD probe and that the reply-MAC parsing logic correctly
# distinguishes our own MAC from a foreign one.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SMOKE="$SCRIPT_DIR/../scripts/device-smoke.sh"

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

echo "== device-smoke.sh: _net_check_arping non-destructive =="

body=$(awk '/^_net_check_arping\(\) \{/,/^}/' "$SMOKE")

# Hard regression guard: no occurrence of `arping -D` in this function
# body. (`-D` is RFC 5227 DAD; that's the destructive form.)
if echo "$body" | grep -qE 'arping[[:space:]]+-D\b'; then
    echo "  FAIL: _net_check_arping still uses 'arping -D' (RFC 5227 DAD, destructive on NM-tracked Docker bridges)"
    fail=$((fail + 1))
else
    echo "  PASS: _net_check_arping no longer uses 'arping -D' (non-DAD probe in place)"
    pass=$((pass + 1))
fi

assert 'echo "$body" | grep -qE "arping -c 3 -w 5"' \
       'function uses regular ARP request with -c 3 -w 5'

assert 'echo "$body" | grep -qF "own_mac"' \
       'function reads own MAC for foreign-reply detection'

assert 'echo "$body" | grep -qF "foreign MAC"' \
       'conflict signature is "reply from foreign MAC"'

# Healthy-LAN semantics: managed switches / Wi-Fi APs do not reflect
# broadcasts, so a non-DAD arping for our own IP usually returns rc=1
# with no replies on a healthy network. That MUST be `pass` (no foreign
# claim), not `warn`. Reserve `warn` for genuine probe errors.
assert 'echo "$body" | grep -qF "No IP conflict on"' \
       'no-reply branch emits pass "No IP conflict on ..."'

assert 'echo "$body" | grep -qF "arping probe failed"' \
       'genuine probe errors emit warn "arping probe failed"'

if echo "$body" | grep -qF "probe inconclusive"; then
    echo "  FAIL: function still emits 'probe inconclusive' on healthy networks (warn-vs-pass regression)"
    fail=$((fail + 1))
else
    echo "  PASS: no 'probe inconclusive' branch (healthy-LAN no-reply is treated as pass)"
    pass=$((pass + 1))
fi

# Reply-MAC parsing logic — replicate in Python and assert that
# replies from our own MAC do NOT count as conflict, replies from a
# different MAC DO.
python3 - <<'PY'
import re, sys
def parse_foreign(output, own_mac):
    own = own_mac.lower()
    for m in re.findall(r'\[([0-9a-fA-F:]+)\]', output):
        if m.lower() != own:
            return m.lower()
    return None

cases = [
    # No conflict: only our own MAC replies
    ("Unicast reply from 192.168.63.4 [dc:a6:32:b4:c6:16] 0.745ms",
     "dc:a6:32:b4:c6:16", None, "own MAC reply is not a conflict"),
    # Conflict: another host replies with different MAC
    ("Unicast reply from 192.168.63.4 [f8:17:2d:11:22:33] 0.812ms",
     "dc:a6:32:b4:c6:16", "f8:17:2d:11:22:33", "foreign MAC reply IS a conflict"),
    # Mixed: our own MAC + a foreign MAC — foreign wins (real conflict)
    ("Unicast reply from 192.168.63.4 [dc:a6:32:b4:c6:16] 0.5ms\n"
     "Unicast reply from 192.168.63.4 [aa:bb:cc:dd:ee:ff] 0.6ms",
     "dc:a6:32:b4:c6:16", "aa:bb:cc:dd:ee:ff", "foreign reply alongside own reply still flags conflict"),
    # Empty output (no replies): not a conflict, just inconclusive
    ("",
     "dc:a6:32:b4:c6:16", None, "no replies is not a conflict"),
    # Case-insensitive MAC comparison
    ("Unicast reply from 192.168.63.4 [DC:A6:32:B4:C6:16] 0.5ms",
     "dc:a6:32:b4:c6:16", None, "case-insensitive MAC match (uppercase reply, lowercase own)"),
]
fail = 0
for output, own, expected, desc in cases:
    got = parse_foreign(output, own)
    if got == expected:
        print(f"  PASS: {desc}")
    else:
        print(f"  FAIL: {desc} (got {got!r}, expected {expected!r})")
        fail += 1
sys.exit(fail)
PY
rc=$?
# Guard: the Python block exits with the count of failed subtests (0..5).
# Any rc > 5 means the heredoc itself crashed (syntax error, missing
# interpreter, etc.); credit zero passes in that case so a green
# summary cannot mask a broken test runner.
if (( rc > 5 )); then
    echo "  FAIL: Python helper crashed (rc=$rc) — all 5 subtests counted as failed"
    fail=$((fail + 5))
elif (( rc == 0 )); then
    pass=$((pass + 5))
else
    fail=$((fail + rc))
    pass=$((pass + 5 - rc))
fi

# Bash 3.2 dev gate: no use of `${var,,}` lowercase expansion (Bash 4.0+).
if echo "$body" | grep -qE '\$\{[A-Za-z_][A-Za-z_0-9]*,,\}'; then
    echo "  FAIL: function uses \${var,,} lowercase expansion (Bash 4.0+, breaks macOS Bash 3.2)"
    fail=$((fail + 1))
else
    echo "  PASS: no \${var,,} lowercase expansion (Bash 3.2 compatible)"
    pass=$((pass + 1))
fi

echo
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
