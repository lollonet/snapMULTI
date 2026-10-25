#!/usr/bin/env bash
# Behavioural test for the WiFi watchdog escalation ladder
# (scripts/common/wifi-watchdog.sh), run tick by tick with PATH stubs for
# ip / ping / nmcli / systemctl / logger / sleep.
#
# Regression: the only health signal was an ICMP ping to the default
# gateway and "no default gateway" also counted as a failure, with no
# requirement that the gateway had ever answered. A router that drops
# ICMP, or an AP switched off overnight, rebooted the Pi every ~10 min
# forever. Now:
#   - hard reboot is armed only after the gateway answered once this boot
#   - an ARP-REACHABLE gateway counts as healthy when ICMP is dropped
#   - soft recovery (nmcli down/up) still runs, and is retried while the
#     hard reboot is disarmed
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHDOG="$SCRIPT_DIR/../scripts/common/wifi-watchdog.sh"

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

SBX="$(mktemp -d)"
trap 'rm -rf "$SBX"' EXIT
mkdir -p "$SBX/bin"

cat > "$SBX/bin/ip" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *"route show default"*) cat "$STUB/route" 2>/dev/null ;;
    *"neigh show"*) state=$(cat "$STUB/neigh" 2>/dev/null); [[ -n "$state" ]] && echo "10.0.0.1 lladdr aa:bb:cc:dd:ee:ff $state" ;;
esac
exit 0
EOF
cat > "$SBX/bin/ping" <<'EOF'
#!/usr/bin/env bash
# ping_script: one exit code per call; the last line repeats.
n=$(( $(cat "$STUB/ping_calls" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$STUB/ping_calls"
rc=$(sed -n "${n}p" "$STUB/ping_script")
[[ -n "$rc" ]] || rc=$(tail -1 "$STUB/ping_script")
exit "$rc"
EOF
cat > "$SBX/bin/nmcli" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *"connection show --active"*) echo "HomeWiFi:wlan0" ;;
    *"connection down"*) echo down >> "$STUB/nmcli.log" ;;
    *"connection up"*) echo up >> "$STUB/nmcli.log" ;;
esac
exit 0
EOF
cat > "$SBX/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$STUB/systemctl.log"
EOF
cat > "$SBX/bin/logger" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$STUB/logger.log"
EOF
printf '#!/bin/sh\nexit 0\n' > "$SBX/bin/sleep"
chmod +x "$SBX/bin/"*

# run_ticks <n>: fresh watchdog process state, n iterations. Runs in a
# subshell because hard_recovery ends the process (exit 0).
run_ticks() {
    local n="$1"
    rm -f "$SBX"/*.log "$SBX/ping_calls"
    (
        export STUB="$SBX" PATH="$SBX/bin:$PATH"
        # shellcheck source=../scripts/common/wifi-watchdog.sh
        source "$WATCHDOG"
        # Pin the ladder (a dev box with /opt/snapmulti/.env may override it).
        SOFT_FAILURES=3
        HARD_FAILURES=10
        # Never write the real reboot marker when run on a Pi.
        if [[ -d /boot/firmware ]]; then
            hard_recovery() { systemctl reboot; exit 0; }
        fi
        for (( i = 0; i < n; i++ )); do
            watchdog_tick
        done
    ) || true
}

reboots() { local c; c=$(grep -c '^reboot' "$SBX/systemctl.log" 2>/dev/null) || true; echo "${c:-0}"; }
bounces() { local c; c=$(grep -c '^down' "$SBX/nmcli.log" 2>/dev/null) || true; echo "${c:-0}"; }

echo "## Sourcing defines functions without running the loop"
out=$(STUB="$SBX" PATH="$SBX/bin:$PATH" timeout 10 bash -c "source '$WATCHDOG'; declare -F watchdog_tick main preflight" 2>&1 || true)
assert "[[ \"\$out\" == *watchdog_tick* && \"\$out\" == *preflight* ]]" "source returns with watchdog_tick/main/preflight defined"

echo
echo "## Gateway never answers (router drops ICMP + ARP, AP off at boot)"
echo "default via 10.0.0.1 dev wlan0" > "$SBX/route"
echo "FAILED" > "$SBX/neigh"
echo 1 > "$SBX/ping_script"
run_ticks 25
assert "[[ \"\$(reboots)\" == 0 ]]" "no reboot when the gateway was never reachable this boot"
assert "(( \$(bounces) >= 2 ))" "soft recovery ran and was retried while disarmed ($(bounces) bounces)"
assert "grep -q 'hard recovery disarmed' '$SBX/logger.log'" "disarmed state logged"

echo
echo "## No default gateway at boot"
: > "$SBX/route"
run_ticks 25
assert "[[ \"\$(reboots)\" == 0 ]]" "no reboot without a default route since boot"
assert "grep -q 'no default gateway' '$SBX/logger.log'" "missing gateway logged as a failure"

echo
echo "## Gateway answered once, then the radio wedges"
echo "default via 10.0.0.1 dev wlan0" > "$SBX/route"
printf '0\n1\n' > "$SBX/ping_script"
run_ticks 12
assert "grep -q 'escalation armed' '$SBX/logger.log'" "escalation armed after the first answer"
assert "[[ \"\$(reboots)\" == 1 ]]" "hard recovery reboots after HARD_FAILURES consecutive failures"
assert "(( \$(bounces) == 1 ))" "soft recovery tried once before the reboot"

echo
echo "## ICMP dropped but gateway ARP-reachable"
echo 1 > "$SBX/ping_script"
echo "REACHABLE" > "$SBX/neigh"
run_ticks 15
assert "[[ \"\$(reboots)\" == 0 ]]" "no reboot"
assert "[[ \"\$(bounces)\" == 0 ]]" "no soft recovery either (link is healthy)"
assert "! grep -q 'probe fail' '$SBX/logger.log'" "ARP-reachable gateway is not counted as a failure"
assert "grep -q 'ARP-reachable' '$SBX/logger.log'" "ICMP fallback logged"
assert "grep -q 'escalation armed' '$SBX/logger.log'" "ARP reachability also arms escalation"

echo
echo "## Summary"
echo "  Passed: $pass"
echo "  Failed: $fail"
[[ $fail -eq 0 ]]
