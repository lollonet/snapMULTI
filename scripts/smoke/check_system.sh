#!/usr/bin/env bash
# scripts/smoke/check_system.sh — kernel/userspace system invariants
#
# Sourced by device-smoke.sh. Relies on helpers from the main script.
#
# What this catches:
#   - Cgroup memory controller missing → Docker silently runs without
#     memory limits enforced (containers OOM-kill the host instead of
#     being capped). PR-#-era investigation showed Pi default cmdline
#     has `cgroup_disable=memory`; deploy.sh adds `cgroup_enable=memory
#     cgroup_memory=1` after it. The kernel applies the LAST value, so
#     the override wins — but a missing override is silent until first
#     OOM.
#   - Quiet-boot cmdline flags (quiet, loglevel=3, systemd.show_status,
#     vt.global_cursor_default, logo.nologo) are required when fb-display
#     is active so the kernel boot messages do not interleave with raw
#     pixel output on the framebuffer. A device with display that lacks
#     these flags shows `[OK] Started ... ` lines on top of fb-display
#     during boot — ugly but not fatal, hence WARN not FAIL.
#   - Tmpfs sizing: /run defaults to 10% RAM; PR #221 makes it dynamic
#     ~25% for snapMULTI to avoid false-ENOSPC during apt installs on
#     Pi Zero 2W. Below the floor → containerd self-heal will trigger
#     repeatedly; above is harmless.
#   - WiFi exclusivity: when ethernet has carrier, WiFi should be DOWN
#     to avoid dual mDNS announcements (one per IP) which confuses
#     clients (snapclient-discover bounces between two routes).
#     boot-tune.sh enforces this; verify the runtime state matches.

# shellcheck disable=SC2154

check_system() {
    section "System"

    # 1. Cmdline — quiet boot flags. Only meaningful when display is
    # connected; on headless devices their absence is fine. We grep
    # /proc/cmdline directly inside the loop below — no need to slurp
    # it into a variable here.
    local has_fb0=false
    [[ -c /dev/fb0 ]] && has_fb0=true

    if [[ "$has_fb0" == "true" ]]; then
        local missing_flags=()
        for flag in "quiet" "loglevel=3" "systemd.show_status=false" "vt.global_cursor_default=0" "logo.nologo"; do
            if ! grep -qE "(^| )${flag//./\\.}( |\$)" /proc/cmdline 2>/dev/null; then
                missing_flags+=("$flag")
            fi
        done
        if (( ${#missing_flags[@]} == 0 )); then
            pass_check "Quiet-boot cmdline flags present (display detected)"
        else
            local joined
            joined=$(IFS=','; echo "${missing_flags[*]}")
            warn "Display detected but cmdline is missing flags: $joined (boot text will overlap fb-display)"
        fi
    else
        info "Headless device — quiet-boot cmdline flags not required"
    fi

    # 2. Cgroup memory enabled (Docker requirement). Two layouts to
    # support: cgroup v1 (legacy, /sys/fs/cgroup/memory/) and cgroup
    # v2 unified (Pi OS Bookworm default, single /sys/fs/cgroup/ with
    # memory.* sentinel files). Either layout is fine for Docker; the
    # fail mode is when neither is present.
    local cgroup_layout=""
    if [[ -d /sys/fs/cgroup/memory ]]; then
        cgroup_layout="v1"
    elif [[ -f /sys/fs/cgroup/memory.stat ]] || [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
        # cgroup v2: confirm `memory` is in the controller list.
        if [[ -f /sys/fs/cgroup/cgroup.controllers ]] && grep -qw memory /sys/fs/cgroup/cgroup.controllers; then
            cgroup_layout="v2"
        elif [[ -f /sys/fs/cgroup/memory.stat ]]; then
            cgroup_layout="v2"
        fi
    fi
    case "$cgroup_layout" in
        v1) pass_check "Cgroup memory controller enabled (v1 hierarchy at /sys/fs/cgroup/memory)" ;;
        v2) pass_check "Cgroup memory controller enabled (v2 unified hierarchy)" ;;
        "")
            # As a last-resort cmdline check — useful diagnostic when
            # /sys layout is unfamiliar but we want to flag the boot
            # parameter explicitly.
            if grep -qE '(^| )(cgroup_memory=1|cgroup_enable=memory)( |$)' /proc/cmdline; then
                fail_check "Cgroup memory in cmdline but kernel did not enable it — Docker memory limits will not enforce"
            else
                fail_check "Cgroup memory NOT enabled (no /sys hierarchy AND no cmdline opt-in) — Docker memory limits will not enforce, host OOM possible"
            fi
            ;;
    esac

    # 3. Tmpfs /run sizing. PR #221 makes it dynamic ~25% RAM. The
    # absolute floor is 256 MB — below that containerd Leases work
    # (1 ENOSPC inode hit per pull-image cycle) starts to false-trigger
    # on Pi 4 + 7 containers. Hard fail is < 200 MB; warn is < 256 MB.
    #
    # /proc/mounts row for /run looks like:
    #   tmpfs /run tmpfs rw,nosuid,nodev,noexec,relatime,size=1565700k,mode=755 0 0
    # The size= token's suffix (k/m/g) and absence of suffix (= bytes)
    # all need uniform handling — do it in one awk pass.
    local run_kb run_mb
    run_kb=$(awk '
        $1 == "tmpfs" && $2 == "/run" {
            n = $4
            if (match(n, /size=[0-9]+[kKmMgG]?/)) {
                tok = substr(n, RSTART+5, RLENGTH-5)
                suf = ""
                if (tok ~ /[kKmMgG]$/) {
                    suf = tolower(substr(tok, length(tok)))
                    tok = substr(tok, 1, length(tok)-1)
                }
                if (suf == "k")      print tok
                else if (suf == "m") print tok * 1024
                else if (suf == "g") print tok * 1024 * 1024
                else                 print int(tok / 1024)
                exit
            }
        }
    ' /proc/mounts || true)
    run_kb=${run_kb:-0}
    run_mb=$(( run_kb / 1024 ))
    if (( run_mb >= 256 )); then
        pass_check "/run tmpfs size: ${run_mb} MB (dynamic ~25% RAM, PR #221)"
    elif (( run_mb >= 200 )); then
        warn "/run tmpfs size: ${run_mb} MB (below 256 MB floor — containerd may false-ENOSPC under apt install)"
    else
        fail_check "/run tmpfs size: ${run_mb} MB — too small, containerd self-heal will trigger repeatedly"
    fi

    # 4. WiFi exclusivity. boot-tune.sh disables WiFi when eth0 has
    # carrier, to avoid dual mDNS publication. If both UP, mDNS clients
    # see two routes to the same hostname and snapclient-discover may
    # bounce. INFO-only on small headless devices that are WiFi-only.
    local eth_state wlan_state
    eth_state=$(cat /sys/class/net/eth0/operstate 2>/dev/null || echo "missing")
    wlan_state=$(cat /sys/class/net/wlan0/operstate 2>/dev/null || echo "missing")
    case "$eth_state:$wlan_state" in
        up:up)
            warn "Both eth0 and wlan0 are UP — boot-tune.sh should have disabled WiFi (dual mDNS risk)"
            ;;
        up:down|up:missing)
            pass_check "Ethernet carrier UP, WiFi down (correct exclusivity)"
            ;;
        down:up|missing:up)
            pass_check "WiFi UP, no Ethernet carrier (WiFi-only mode)"
            ;;
        down:down|down:missing|missing:down|missing:missing)
            fail_check "No active network interface (eth0=$eth_state, wlan0=$wlan_state)"
            ;;
        *)
            info "Network state: eth0=$eth_state, wlan0=$wlan_state"
            ;;
    esac
}
