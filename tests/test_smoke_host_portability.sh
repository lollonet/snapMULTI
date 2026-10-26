#!/usr/bin/env bash
# Smoke checks read systemd state and network interfaces correctly, also on
# hosts that are not a Raspberry Pi.
#
#   1. `systemctl is-enabled` prints the state (not-found, disabled) AND exits
#      non-zero, so `$(systemctl is-enabled u || echo missing)` held two
#      lines and a missing timer was reported as a garbled warning instead
#      of "NOT installed". check_timers / check_mounts must classify them.
#   2. Boot-partition timers are N/A where /boot/firmware does not exist.
#   3. WiFi exclusivity on a host with neither eth0 nor wlan0 checks the
#      default-route interface instead of failing.
#   4. check_system still runs to the end under `set -u` after the split.
#   5. No script captures a systemctl state with `|| echo`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK_TIMERS="$REPO_ROOT/scripts/smoke/check_timers.sh"
CHECK_SYSTEM="$REPO_ROOT/scripts/smoke/check_system.sh"

pass=0
fail=0

check() {
    local desc="$1"; shift
    if "$@"; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc"
        fail=$((fail + 1))
    fi
}

has()  { grep -qF -- "$2" <<< "$1"; }
lacks() { ! grep -qF -- "$2" <<< "$1"; }

SBX=$(mktemp -d)
trap 'rm -rf "${SBX:?}"' EXIT
mkdir -p "$SBX/bin" "$SBX/units" "$SBX/boot" "$SBX/net"

# systemctl stub with real exit codes: a unit's enable state is the content
# of $SBX/units/<unit> (missing file = not-found); is-active reads
# $SBX/units/<unit>.active.
cat > "$SBX/bin/systemctl" <<EOF
#!/usr/bin/env bash
unit="\$2"
case "\$1" in
    is-enabled)
        if [[ ! -f "$SBX/units/\$unit" ]]; then echo not-found; exit 4; fi
        state=\$(cat "$SBX/units/\$unit"); echo "\$state"
        [[ "\$state" == enabled || "\$state" == static ]] ;;
    is-active)
        if [[ -f "$SBX/units/\$unit.active" ]]; then echo active; exit 0; fi
        echo inactive; exit 3 ;;
esac
EOF
# ip stub: default route through $SBX/defdev.
cat > "$SBX/bin/ip" <<EOF
#!/usr/bin/env bash
[[ -s "$SBX/defdev" ]] && echo "default via 192.0.2.1 dev \$(cat "$SBX/defdev") proto dhcp"
exit 0
EOF
chmod +x "$SBX/bin/systemctl" "$SBX/bin/ip"

helpers='section() { :; }; pass_check() { echo "[OK] $*"; }; fail_check() { echo "[ERROR] $*"; }; warn() { echo "[WARN] $*"; }; info() { echo "[INFO] $*"; }'

# $1 = boot dir to use for _TIMERS_BOOT_FW.
run_timers() {
    PATH="$SBX/bin:$PATH" MODE=server bash -c "$helpers"'
        source "$1"; _TIMERS_BOOT_FW="$2"; check_timers' _ "$CHECK_TIMERS" "$1" 2>&1
}

enable_unit() { echo enabled > "$SBX/units/$1"; touch "$SBX/units/$1.active"; }

echo "## timer states"
rm -f "$SBX/units/"*
enable_unit snapmulti-status.timer
echo disabled > "$SBX/units/snapmulti-backup.timer"
out=$(run_timers "$SBX/boot")
check "enabled + active timer passes" has "$out" "[OK] Timer snapmulti-status.timer enabled and active"
check "missing timer reported as NOT installed" has "$out" "[ERROR] Timer snapmulti-diagnostics.timer NOT installed"
check "disabled timer reported as disabled" has "$out" "[ERROR] Timer snapmulti-backup.timer is 'disabled'"
check "missing path unit reported as NOT installed" has "$out" "[ERROR] Path unit snapmulti-state-backup.path NOT installed"
check "no garbled two-line state" lacks "$out" "unexpected state"

echo "## no boot partition"
out=$(run_timers "$SBX/no-such-boot")
check "boot-partition timers reported N/A" has "$out" "[INFO] Boot-partition timers skipped (N/A on this host"
check "backup timer not checked" lacks "$out" "snapmulti-backup.timer NOT installed"
check "status timer still checked" has "$out" "Timer snapmulti-status.timer enabled and active"

# check_system reads interfaces under /sys/class/net; point it at $SBX/net.
run_net() {
    PATH="$SBX/bin:$PATH" bash -c "$helpers"'
        source "$1"; _SYS_CLASS_NET="$2"; _check_net_exclusivity' _ "$CHECK_SYSTEM" "$SBX/net" 2>&1
}
set_iface() { mkdir -p "$SBX/net/$1"; echo "$2" > "$SBX/net/$1/operstate"; }

echo "## network exclusivity"
rm -rf "$SBX/net/"*; : > "$SBX/defdev"
set_iface eth0 up
check "eth0 up, no wlan0 passes" has "$(run_net)" "[OK] Ethernet carrier UP"

rm -rf "$SBX/net/"*; set_iface br0 up; echo br0 > "$SBX/defdev"
check "no eth0/wlan0, default route on br0 up passes" has "$(run_net)" "[OK] Network UP on br0"

rm -rf "$SBX/net/"*; set_iface br0 down; echo br0 > "$SBX/defdev"
check "default-route interface down fails" has "$(run_net)" "[ERROR] No active network interface"

rm -rf "$SBX/net/"*; : > "$SBX/defdev"
check "no interface and no default route fails" has "$(run_net)" "default route none"

rm -rf "$SBX/net/"*; set_iface eth0 down; set_iface wlan0 down
check "eth0 and wlan0 down still fails" has "$(run_net)" "[ERROR] No active network interface (eth0=down, wlan0=down)"

echo "## check_system runs to the end under set -u"
out=$(LC_ALL=C PATH="$SBX/bin:$PATH" MODE=server bash -c "set -euo pipefail; $helpers"'
    source "$1"; _SYS_CLASS_NET="$2"; check_system; echo CHECK_SYSTEM_DONE' _ "$CHECK_SYSTEM" "$SBX/net" 2>&1 || true)
check "no unbound variable" lacks "$out" "unbound variable"
check "reaches the end" has "$out" "CHECK_SYSTEM_DONE"

echo "## no systemctl state captured with || echo"
hits=$(cd "$REPO_ROOT" && git grep -nE 'systemctl (is-enabled|is-active|is-failed)[^)]*\|\| *echo' -- scripts client ':!*.md' || true)
check "no \$(systemctl is-* || echo) left" test -z "$hits"
[[ -z "$hits" ]] || printf '    %s\n' "$hits"

echo
echo "## Summary"
echo "  Passed: $pass"
echo "  Failed: $fail"
[[ $fail -eq 0 ]]
