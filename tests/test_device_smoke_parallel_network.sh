#!/usr/bin/env bash
# Static checks for the parallel Network section in device-smoke.sh.
#
# The four network checks (DNS, NTP, mDNS self round-trip, arping IP
# conflict) are independent — each issues an external probe and exits.
# Running them serially makes the section ~30 s wall-clock in the worst
# case (DNS retry path). Parallelising them collapses that to whatever
# the slowest single check takes (still 30 s for DNS, but NTP/mDNS/arping
# no longer serialise behind it).
#
# Subshells (`&`) can't update the parent's FAILURES / JSON_RECORDS, so
# each check writes its TSV result lines to a per-check tmpfile under
# $_NET_RESULTS_DIR. The parent then replays them through pass_check /
# fail_check / warn / info in canonical order.
#
# This test fails if the parallel wiring drifts:
#   - any of the four `_net_check_*` functions disappears
#   - any check is run without `&` (serialises again)
#   - the `wait` after the dispatch goes missing
#   - the per-check tmpfile pattern is replaced by direct pass_check
#     calls inside the background function (would lose results)
#   - the canonical replay order is reshuffled

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

echo "== device-smoke.sh: parallel Network section =="

# 1. The four check functions are defined.
for fn in _net_check_dns _net_check_ntp _net_check_mdns_self _net_check_arping; do
    assert "grep -qE '^${fn}\\(\\) \\{' \"\$SMOKE\"" \
        "function $fn defined"
done

# 2. The result-dispatch helper is defined.
assert 'grep -qE "^_net_emit_results\\(\\) \\{" "$SMOKE"' \
    "function _net_emit_results defined"

# 3. All four checks are invoked WITH `&` (background) — drift to
# serial execution would re-introduce the 30-45 s worst-case latency.
for fn in _net_check_dns _net_check_ntp _net_check_mdns_self _net_check_arping; do
    assert "grep -qE '^${fn} &$' \"\$SMOKE\"" \
        "$fn invoked with & (background)"
done

# 4. `wait` follows the dispatch — without it the parent races past
# the writes and the result tmpfiles may be empty at replay time.
assert 'awk "/^_net_check_arping &$/{f=1; next} f&&/^wait$/{print; exit 0} f&&/^[^[:space:]]/{exit 1}" "$SMOKE" >/dev/null' \
    "wait follows the four background invocations"

# 5. The tmpfile directory is mktemp'd and trap'd for cleanup.
assert 'grep -qE "mktemp -d /tmp/snapmulti-smoke-net" "$SMOKE"' \
    "_NET_RESULTS_DIR is mktemp-allocated"
assert 'grep -qE "trap .+_NET_RESULTS_DIR.+ EXIT" "$SMOKE"' \
    "_NET_RESULTS_DIR cleanup is trapped on EXIT"

# 6. The check functions DO NOT call pass_check / fail_check directly.
# (That would lose the result because background subshells cannot
# mutate FAILURES / JSON_RECORDS in the parent.)
# Extract each function body and grep it. We assume the function
# definition is followed by a single `}` on its own line.
for fn in _net_check_dns _net_check_ntp _net_check_mdns_self _net_check_arping; do
    body=$(awk "/^${fn}\\(\\) \\{/{flag=1; next} flag&&/^\\}$/{flag=0} flag" "$SMOKE")
    if echo "$body" | grep -qE '\b(pass_check|fail_check)\b'; then
        echo "  FAIL: $fn body calls pass_check / fail_check directly (would lose result in subshell)"
        fail=$((fail + 1))
    else
        echo "  PASS: $fn body does not call pass_check / fail_check directly"
        pass=$((pass + 1))
    fi
done

# 7. Replay order matches the canonical declaration order (dns → ntp →
# mdns_self → arping). Drifting this would scramble the human / JSON
# section output relative to the historical layout.
order=$(grep -oE '_net_emit_results [a-z_]+' "$SMOKE" | awk '{print $2}' | tr '\n' ' ')
if [[ "$order" == "dns ntp mdns_self arping " ]]; then
    echo "  PASS: _net_emit_results replay order is dns -> ntp -> mdns_self -> arping"
    pass=$((pass + 1))
else
    echo "  FAIL: _net_emit_results replay order is '$order' (expected 'dns ntp mdns_self arping ')"
    fail=$((fail + 1))
fi

echo
echo "Results: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
