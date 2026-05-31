#!/usr/bin/env bash
# Static invariants on the Avahi allow-interfaces reconciliation in
# boot-tune.sh.
#
# Why pin these statically:
# - Observed on snapvideo 2026-05-31: firstboot wrote `allow-interfaces=wlan0`
#   while eth0 was DOWN. Two days later user attached Ethernet, manually
#   disabled WiFi → Avahi muto on both interfaces because the only
#   allowed interface (wlan0) was DOWN. mDNS resolution timed out.
# - The fix re-runs tune_avahi_daemon (from system-tune.sh) at every
#   boot. A future refactor that drops the source or the call would
#   silently re-introduce the stale-config bug.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOT_TUNE="$SCRIPT_DIR/../scripts/boot-tune.sh"
SYSTEM_TUNE="$SCRIPT_DIR/../scripts/common/system-tune.sh"

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

echo "== boot-tune.sh Avahi reconcile =="
check "boot-tune.sh exists" "[[ -f '$BOOT_TUNE' ]]"
check "candidate path /opt/snapmulti/scripts/common/system-tune.sh" "grep -q '/opt/snapmulti/scripts/common/system-tune.sh' '$BOOT_TUNE'"
check "candidate path /opt/snapclient/scripts/common/system-tune.sh" "grep -q '/opt/snapclient/scripts/common/system-tune.sh' '$BOOT_TUNE'"
check "candidates iterated in a for loop (server + client install symmetric)" "grep -qE 'for _sysT_candidate in' '$BOOT_TUNE'"
check "sources the first existing candidate" "grep -qE 'source \"\\\$_sysT_candidate\"' '$BOOT_TUNE'"
check "verifies tune_avahi_daemon is defined before calling (declare -F)" "grep -qE 'declare -F tune_avahi_daemon' '$BOOT_TUNE'"
check "calls tune_avahi_daemon with hostname" "grep -qE 'tune_avahi_daemon \"\\\$\\(hostname\\)\"' '$BOOT_TUNE'"
check "call has non-fatal fallback (\\|\\| logger ...)" "awk '/tune_avahi_daemon \"\\\$\\(hostname\\)\"/{found=1} found && /logger.*non-fatal/{ok=1; exit} END{exit !ok}' '$BOOT_TUNE'"
check "break after first matching candidate (no double-source on both installs)" "awk '/for _sysT_candidate in/{in_loop=1} in_loop && /^[[:space:]]*break\$/{ok=1; exit} END{exit !ok}' '$BOOT_TUNE'"
check "Avahi reconcile runs AFTER the WiFi disable/enable block (so carrier is settled)" "awk '/^if command -v nmcli/{nmcli_line=NR} /tune_avahi_daemon/{avahi_line=NR} END{exit !(avahi_line>nmcli_line)}' '$BOOT_TUNE'"
check "shellcheck SC1091 disabled inline (sourced file path not statically checkable)" "grep -qE 'shellcheck disable=SC1091' '$BOOT_TUNE'"

echo
echo "== system-tune.sh: tune_avahi_daemon still defined and self-restarting =="
check "tune_avahi_daemon function defined" "grep -qE '^tune_avahi_daemon\\(\\)' '$SYSTEM_TUNE'"
check "function restarts avahi-daemon when config changes (idempotent path)" "awk '/^tune_avahi_daemon\\(\\)/{f=1} f && /avahi_changed.*true/{a=1} f && /systemctl restart avahi-daemon/{b=1; if(a) exit} END{exit !(a && b)}' '$SYSTEM_TUNE'"
check "function writes allow-interfaces= line" "grep -qE 'allow-interfaces=' '$SYSTEM_TUNE'"
check "wired carrier check (eth*/en*) is the priority branch" "grep -qE '/sys/class/net/(eth|en)' '$SYSTEM_TUNE'"

echo
echo "Results: $pass passed, $fail failed"
exit $fail
