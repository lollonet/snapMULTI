#!/usr/bin/env bash
# Tests for the boot-race tolerance in scripts/smoke/check_qos.sh.
#
# The DSCP EF rules are applied by the NetworkManager dispatcher hook only
# on the first NM up/dhcp event (~60-120s after boot). A smoke run inside
# that window must NOT report a hard ERROR on a correctly-configured device
# — it demotes to INFO until the grace window elapses, after which a
# genuine absence is a real FAIL again.
#
# Layer 1: the pure classifier _cq_dscp_verdict (no I/O).
# Layer 2: check_qos orchestration with mocked ip/tc/iptables + an
#          overridden uptime seam, proving the INFO vs FAIL dispatch.
#
# bash 3.2 compatible.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE="$SCRIPT_DIR/../scripts/smoke/check_qos.sh"

pass=0
fail=0

assert_eq() {
    local actual="$1" expected="$2" desc="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  PASS: $desc"; pass=$((pass + 1))
    else
        echo "  FAIL: $desc (got '$actual', expected '$expected')"; fail=$((fail + 1))
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" desc="$3"
    if grep -qF -- "$needle" <<<"$haystack"; then
        echo "  PASS: $desc"; pass=$((pass + 1))
    else
        echo "  FAIL: $desc (missing '$needle')"; fail=$((fail + 1))
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" desc="$3"
    if grep -qF -- "$needle" <<<"$haystack"; then
        echo "  FAIL: $desc (found '$needle')"; fail=$((fail + 1))
    else
        echo "  PASS: $desc"; pass=$((pass + 1))
    fi
}

# ── Layer 1: pure classifier ─────────────────────────────────────────
# shellcheck source=/dev/null
source "$MODULE"

echo "== _cq_dscp_verdict =="
assert_eq "$(_cq_dscp_verdict 1 5)"    "pass" "rule present -> pass even at 5s uptime"
assert_eq "$(_cq_dscp_verdict 1 99999)" "pass" "rule present -> pass at high uptime"
assert_eq "$(_cq_dscp_verdict 0 30)"   "boot" "rule missing + uptime 30s -> boot (INFO)"
assert_eq "$(_cq_dscp_verdict 0 119)"  "boot" "rule missing + uptime 119s -> boot (just inside window)"
assert_eq "$(_cq_dscp_verdict 0 120)"  "fail" "rule missing + uptime 120s -> fail (window elapsed)"
assert_eq "$(_cq_dscp_verdict 0 3600)" "fail" "rule missing + uptime 1h -> fail (genuine absence)"
assert_eq "$(_cq_dscp_verdict 2 30)"   "pass" "count >=1 (2) -> pass"

# ── Layer 2: orchestration with mocks ────────────────────────────────
MOCK_BIN="$(mktemp -d)"
trap 'rm -rf "$MOCK_BIN"' EXIT

# ip: a default route on eth0 so the egress-iface probe succeeds.
cat > "$MOCK_BIN/ip" <<'MOCK'
#!/usr/bin/env bash
[[ "$1 $2 $3" == "route show default" ]] && { echo "default via 192.0.2.1 dev eth0"; exit 0; }
exit 0
MOCK
# tc: CAKE active (keeps the qdisc leg green, isolates the DSCP assertions).
cat > "$MOCK_BIN/tc" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == "qdisc" ]] && { echo "qdisc cake 8001: root refcnt 2 bandwidth unlimited"; exit 0; }
exit 0
MOCK
# iptables: mangle OUTPUT is EMPTY — the boot-race state (rules not applied yet).
cat > "$MOCK_BIN/iptables" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$MOCK_BIN/ip" "$MOCK_BIN/tc" "$MOCK_BIN/iptables"

run_qos() {
    # $1 = uptime seam override body
    local uptime_body="$1"
    PATH="$MOCK_BIN:$PATH" MODE=server SERVER_DIR="$MOCK_BIN/nonexistent" \
    bash -c "
        section()    { printf 'SECTION %s\\n' \"\$*\"; }
        pass_check() { printf '[OK] %s\\n' \"\$*\"; }
        fail_check() { printf '[ERROR] %s\\n' \"\$*\"; }
        warn()       { printf '[WARN] %s\\n' \"\$*\"; }
        info()       { printf '[INFO] %s\\n' \"\$*\"; }
        source '$MODULE'
        $uptime_body
        check_qos
    "
}

echo "== orchestration: DSCP missing inside boot window -> INFO, not ERROR =="
boot_out="$(run_qos '_cq_uptime_s() { printf 45; }')"
assert_contains "$boot_out" "[INFO] Snapcast streaming priority tag: not applied yet" "streaming tag missing at 45s -> INFO"
assert_contains "$boot_out" "[INFO] Snapcast RPC priority tag: not applied yet" "RPC tag missing at 45s -> INFO"
assert_not_contains "$boot_out" "[ERROR] Snapcast streaming priority tag" "no ERROR for streaming tag inside boot window"
assert_not_contains "$boot_out" "[ERROR] Snapcast RPC priority tag" "no ERROR for RPC tag inside boot window"

echo "== orchestration: DSCP missing after boot window -> ERROR =="
late_out="$(run_qos '_cq_uptime_s() { printf 3600; }')"
assert_contains "$late_out" "[ERROR] Snapcast streaming priority tag: missing on port 1704" "streaming tag missing at 1h -> ERROR"
assert_contains "$late_out" "[ERROR] Snapcast RPC priority tag: missing" "RPC tag missing at 1h -> ERROR"
assert_not_contains "$late_out" "[INFO] Snapcast streaming priority tag: not applied yet" "no INFO demotion after the window"

echo ""
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
