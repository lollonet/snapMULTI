#!/usr/bin/env bash
# Static invariants for the WiFi connectivity watchdog.
#
# Why pin these statically:
# - The script is the only line of defence between a wedged brcmfmac
#   firmware and a silently-unreachable LAN that needs a manual
#   reboot. Any future "tidy-up" that drops the soft/hard escalation
#   ladder, the eth0-skip guard, or the failure-counter reset would
#   undo the whole point.
# - Hard-fails are bounded by HARD_FAILURES × INTERVAL — wrong defaults
#   here mean either thrashing (too low) or silent outages (too high).
# - systemd unit hardening is easy to lose during refactors.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../scripts/common/wifi-watchdog.sh"
SERVICE="$SCRIPT_DIR/../scripts/common/snapmulti-wifi-watchdog.service"
FIRSTBOOT="$SCRIPT_DIR/../scripts/firstboot.sh"

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

echo "== wifi-watchdog.sh =="
check "script exists" "[[ -f '$SCRIPT' ]]"
check "uses portable shebang" "head -1 '$SCRIPT' | grep -q '^#!/usr/bin/env bash'"
check "set -euo pipefail" "grep -q '^set -euo pipefail' '$SCRIPT'"

# Behaviour invariants
check "skips on wired-only hosts via IPv4-address probe (carrier alone is too loose)" "grep -qE 'ip -4 addr show eth0' '$SCRIPT'"
check "detects missing wlan interface and exits" "grep -qE 'class/net/.*WIFI_IFACE' '$SCRIPT'"
check "auto-detects gateway from default route" "grep -q 'ip -4 route show default' '$SCRIPT'"
check "ping bound to WiFi interface (-I \$WIFI_IFACE)" "grep -qE 'ping.*-I.*WIFI_IFACE' '$SCRIPT'"
check "ping has -W timeout (5 s)" "grep -qE 'ping[^|]*-W 5' '$SCRIPT'"
check "soft recovery cycles nmcli connection down/up" "grep -q 'nmcli connection down' '$SCRIPT' && grep -q 'nmcli connection up' '$SCRIPT'"
check "soft recovery flagged so it does not fire repeatedly without intervening success" "grep -q 'soft_recovery_attempted=true' '$SCRIPT'"
check "soft_recovery call tolerates non-zero return (set -e cannot kill the watchdog)" "grep -qE 'soft_recovery \\|\\| true' '$SCRIPT'"
check "hard recovery uses systemctl reboot (orderly container stop)" "grep -q 'systemctl reboot' '$SCRIPT'"
check "hard recovery writes a marker on /boot/firmware for next-boot UI" "grep -q '/boot/firmware/snapmulti-wifi-watchdog-reboot.marker' '$SCRIPT'"
check "failure counter resets on successful ping" "grep -qE 'failures=0' '$SCRIPT'"
# CRLF check: inline assertion (same approach as test_mpd_nfs_update_invariants.sh)
if grep -qE "tr -d \\\$'\\\\r'" "$SCRIPT"; then
    echo "  PASS: CRLF-tolerant .env parsing (\\r stripped)"
    pass=$((pass + 1))
else
    echo "  FAIL: CRLF-tolerant .env parsing (\\r stripped)"
    fail=$((fail + 1))
fi

# Configurable knobs — defaults must be sensible
check "default INTERVAL between 30 s and 300 s" "awk -F'\"' '/^INTERVAL=\"/{n=\$2} END{exit !(n>=30 && n<=300)}' '$SCRIPT'"
check "default SOFT_FAILURES between 2 and 5" "awk -F'\"' '/^SOFT_FAILURES=\"/{n=\$2} END{exit !(n>=2 && n<=5)}' '$SCRIPT'"
check "default HARD_FAILURES between 5 and 20" "awk -F'\"' '/^HARD_FAILURES=\"/{n=\$2} END{exit !(n>=5 && n<=20)}' '$SCRIPT'"
check "HARD_FAILURES > SOFT_FAILURES (ladder, not jump)" "awk -F'\"' '/^SOFT_FAILURES=\"/{s=\$2} /^HARD_FAILURES=\"/{h=\$2} END{exit !(h>s)}' '$SCRIPT'"

# .env knob discoverability
for knob in WIFI_WATCHDOG_INTERVAL WIFI_WATCHDOG_SOFT_FAILURES WIFI_WATCHDOG_HARD_FAILURES WIFI_WATCHDOG_TARGET WIFI_WATCHDOG_IFACE; do
    check "reads .env knob $knob" "grep -q '$knob' '$SCRIPT'"
done

echo
echo "== snapmulti-wifi-watchdog.service =="
check "service file exists" "[[ -f '$SERVICE' ]]"
check "Type=simple (long-running, not oneshot)" "grep -q '^Type=simple' '$SERVICE'"
check "Restart=on-failure (graceful no-op exit 0 must not loop)" "grep -q '^Restart=on-failure' '$SERVICE'"
check "RestartSec >= 10 (no tight loop)" "awk -F= '/^RestartSec/{exit !(\$2>=10)}' '$SERVICE'"
check "After=NetworkManager.service (ordering)" "grep -q 'After=.*NetworkManager' '$SERVICE'"
check "MemoryMax cap (leak protection)" "grep -q '^MemoryMax=' '$SERVICE'"
check "NoNewPrivileges=true" "grep -q '^NoNewPrivileges=true' '$SERVICE'"
check "ProtectSystem=strict" "grep -q '^ProtectSystem=strict' '$SERVICE'"
check "/boot/firmware writable for the marker" "grep -q 'ReadWritePaths=/boot/firmware' '$SERVICE'"
check "WantedBy=multi-user.target" "grep -q 'WantedBy=multi-user.target' '$SERVICE'"

echo
echo "== firstboot.sh integration =="
check "firstboot installs the script to /usr/local/bin/snapmulti-wifi-watchdog" "grep -qE 'install -m 755.*WIFI_WD_SCRIPT.*/usr/local/bin/snapmulti-wifi-watchdog' '$FIRSTBOOT'"
check "firstboot install candidates include CLIENT_DIR path (client-only installs)" "grep -qE 'CLIENT_DIR/scripts/common/wifi-watchdog.sh' '$FIRSTBOOT'"
check "firstboot WiFi watchdog comment confirms it covers ALL install types" "grep -qE 'WiFi.*ALL install types|all.*install.*type|client.*client-native|client.*equally vulnerable' '$FIRSTBOOT'"
check "firstboot installs the service unit" "grep -qE 'snapmulti-wifi-watchdog.service.*etc/systemd/system' '$FIRSTBOOT'"
check "firstboot enables (and starts) the service" "grep -qE 'systemctl enable.*snapmulti-wifi-watchdog' '$FIRSTBOOT'"

echo
echo "Results: $pass passed, $fail failed"
exit $fail
