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

    # 0. Release identity. Surface SNAPMULTI_RELEASE + SNAPMULTI_IMAGE_SET
    # from the deployed .env so an operator running `device-smoke.sh`
    # on a freshly-flashed device can confirm at a glance which
    # release / image-set is actually live (catches stale .env after
    # a partial upgrade or a custom-staged tree). Falls through
    # silently when the keys are absent — legacy installs predating
    # the release-manifest still pass this check, just without the
    # info line.
    local _env_file=""
    for _candidate in /opt/snapmulti/.env /opt/snapclient/.env; do
        [[ -f "$_candidate" ]] && { _env_file="$_candidate"; break; }
    done
    if [[ -n "$_env_file" ]]; then
        local _release _image_set
        _release=$(grep -m1 '^SNAPMULTI_RELEASE=' "$_env_file" 2>/dev/null | cut -d= -f2- || true)
        _image_set=$(grep -m1 '^SNAPMULTI_IMAGE_SET=' "$_env_file" 2>/dev/null | cut -d= -f2- || true)
        if [[ -n "$_release" && -n "$_image_set" ]]; then
            info "Release $_release (images $_image_set)"
        elif [[ -n "$_release" ]]; then
            info "Release $_release (image_set unknown)"
        elif [[ -n "$_image_set" ]]; then
            info "Image set $_image_set (release unknown)"
        fi

        # Update available? metadata-service /version endpoint already
        # compares local release-manifest against the latest GitHub
        # tag (cached locally). Surface it here so the status page
        # tells the operator at a glance whether a reflash brings a
        # newer release.
        if command -v curl >/dev/null 2>&1; then
            local _ver_json _current _latest _update_avail
            _ver_json=$(curl -sS --max-time 3 http://127.0.0.1:8083/version 2>/dev/null || true)
            if [[ -n "$_ver_json" ]] && command -v jq >/dev/null 2>&1; then
                _current=$(jq -r '.current // empty' <<<"$_ver_json" 2>/dev/null || true)
                _latest=$(jq -r '.latest // empty' <<<"$_ver_json" 2>/dev/null || true)
                _update_avail=$(jq -r '.update_available // false' <<<"$_ver_json" 2>/dev/null || true)
                if [[ "$_update_avail" == "true" && -n "$_current" && -n "$_latest" ]]; then
                    info "Update available: ${_current} -> ${_latest} (reflash to apply)"
                elif [[ "$_update_avail" == "false" && -n "$_current" ]]; then
                    pass_check "Up to date with upstream (${_current} is latest)"
                fi
            fi
        fi
    fi

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
            #
            # Native client install (Pi Zero 2W) has no Docker, so a missing
            # memory cgroup is fine — there are no container memory limits
            # to enforce. Downgrade fail → info so the smoke stays green.
            if [[ "${INSTALL_TYPE_NATIVE_CLIENT:-false}" == "true" ]]; then
                info "Cgroup memory not enabled — fine on native client (no Docker memory limits to enforce)"
            elif grep -qE '(^| )(cgroup_memory=1|cgroup_enable=memory)( |$)' /proc/cmdline; then
                fail_check "Cgroup memory in cmdline but kernel did not enable it — Docker memory limits will not enforce"
            else
                fail_check "Cgroup memory NOT enabled (no /sys hierarchy AND no cmdline opt-in) — Docker memory limits will not enforce, host OOM possible"
            fi
            ;;
    esac

    # 3. Tmpfs /run sizing. PR #221 makes it dynamic ~25% RAM but the
    # actual floor depends on total RAM:
    #   ≥4 GB  → expect ≥1 GB (fail < 800 MB, warn < 1 GB)
    #   ≥1 GB  → expect ≥200 MB (fail < 150 MB, warn < 200 MB)
    #   <1 GB  → expect ≥80 MB  (fail < 60 MB, warn < 80 MB)
    # Below the warn band containerd may false-ENOSPC under apt install;
    # below the fail band the self-heal triggers repeatedly. The previous
    # absolute floor of 200/256 MB was correct for Pi 4+ but a false
    # negative on Pi Zero 2W (512 MB → 25 % = 128 MB) and Pi 3 1 GB
    # (25 % = 256 MB but actual was 191 MB on a freshly-reflashed device,
    # within design budget).
    #
    # /proc/mounts row for /run looks like:
    #   tmpfs /run tmpfs rw,nosuid,nodev,noexec,relatime,size=1565700k,mode=755 0 0
    # The size= token's suffix (k/m/g) and absence of suffix (= bytes)
    # all need uniform handling — do it in one awk pass.
    local run_kb run_mb total_kb total_mb
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

    total_kb=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)
    total_mb=$(( total_kb / 1024 ))

    local floor_warn floor_fail expected_class
    if (( total_mb >= 3500 )); then
        floor_warn=1024; floor_fail=800;  expected_class="≥4 GB Pi"
    elif (( total_mb >= 900 )); then
        # Pi 3B+ 1 GB on a clean reflash gets 191 MB (~20% of 955 MB MemTotal);
        # boot-tune.sh does not remount /run (only the overlayroot tmpfs) and
        # systemd-default has been observed adequate for the containerd
        # self-heal pattern. 180 MB lets the systemd default pass cleanly
        # while still catching genuine misconfiguration (<150 MB = fail).
        floor_warn=180;  floor_fail=150;  expected_class="1-2 GB Pi"
    else
        floor_warn=80;   floor_fail=60;   expected_class="<1 GB Pi (Zero/Zero 2W)"
    fi

    if (( run_mb >= floor_warn )); then
        pass_check "/run tmpfs size: ${run_mb} MB on ${total_mb} MB RAM ($expected_class floor ≥${floor_warn} MB)"
    elif (( run_mb >= floor_fail )); then
        warn "/run tmpfs size: ${run_mb} MB on ${total_mb} MB RAM (below ${floor_warn} MB warn floor for $expected_class — containerd may false-ENOSPC under apt install)"
    else
        fail_check "/run tmpfs size: ${run_mb} MB on ${total_mb} MB RAM (below ${floor_fail} MB fail floor for $expected_class — containerd self-heal will trigger repeatedly)"
    fi

    # Memory headroom. mympd OOM-kill in v0.7.8.16 (#516) was caught
    # via journal review hours late — surface it on the status page.
    local avail_kb avail_mb mem_used_pct
    avail_kb=$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)
    avail_mb=$(( avail_kb / 1024 ))
    if (( total_kb > 0 )); then
        mem_used_pct=$(( 100 * (total_kb - avail_kb) / total_kb ))
        if (( mem_used_pct >= 92 )); then
            fail_check "Memory ${mem_used_pct}% used (${avail_mb} MB available of ${total_mb} MB) — imminent OOM-kill risk for the smallest cgroup-limited container"
        elif (( mem_used_pct >= 80 )); then
            warn "Memory ${mem_used_pct}% used (${avail_mb} MB available of ${total_mb} MB) — running tight, audit container limits if it persists"
        else
            pass_check "Memory ${mem_used_pct}% used (${avail_mb} MB available of ${total_mb} MB)"
        fi
    fi

    # Swap pressure. On Pi Zero 2W zram is masked (would fill overlay
    # tmpfs); on bigger Pi there's typically a small dphys-swapfile.
    # Significant swap usage in steady-state means under-provisioned
    # memory limits — degrades audio.
    local swap_total_kb swap_free_kb swap_used_kb swap_pct
    swap_total_kb=$(awk '/^SwapTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)
    swap_free_kb=$(awk '/^SwapFree:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)
    if (( swap_total_kb > 0 )); then
        swap_used_kb=$(( swap_total_kb - swap_free_kb ))
        swap_pct=$(( 100 * swap_used_kb / swap_total_kb ))
        if (( swap_pct >= 50 )); then
            warn "Swap ${swap_pct}% used ($(( swap_used_kb / 1024 ))/$(( swap_total_kb / 1024 )) MB) — heavy swapping degrades audio path latency"
        elif (( swap_pct > 0 )); then
            info "Swap ${swap_pct}% used ($(( swap_used_kb / 1024 ))/$(( swap_total_kb / 1024 )) MB)"
        fi
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

    # 5. Overlayroot tmpfs usage. The root overlay's writable layer is
    # on tmpfs (overlayroot=tmpfs in cmdline); when it fills, Docker
    # silently fails to write to /var/lib/docker scratch and the system
    # becomes unbootable on next restart (read-only root + full tmpfs =
    # no recovery short of reflash). boot-tune.sh logs WARN at 70 % and
    # CRIT at 90 % but only in journald — surface it in smoke so the
    # fleet-smoke aggregator sees it. Skip on writable-root systems.
    if mount | grep -q ' on / type overlay'; then
        local root_pcent root_used root_total
        root_pcent=$(df / --output=pcent 2>/dev/null | tail -1 | tr -cd '0-9')
        root_used=$(df -m / --output=used 2>/dev/null | tail -1 | tr -cd '0-9')
        root_total=$(df -m / --output=size 2>/dev/null | tail -1 | tr -cd '0-9')
        if [[ -n "$root_pcent" ]] && [[ -n "$root_used" ]] && [[ -n "$root_total" ]]; then
            if (( root_pcent >= 90 )); then
                fail_check "Overlay tmpfs ${root_pcent}% full (${root_used}/${root_total} MB) — system will fail next boot. Run: sudo ro-mode disable && sudo reboot"
            elif (( root_pcent >= 70 )); then
                warn "Overlay tmpfs ${root_pcent}% full (${root_used}/${root_total} MB) — approaching limit (90% = unbootable)"
            else
                pass_check "Overlay tmpfs ${root_pcent}% full (${root_used}/${root_total} MB)"
            fi
        fi
    fi

    # 6. Throttle / under-voltage history. vcgencmd get_throttled
    # returns a hex bitmask:
    #   0x1     currently under-voltage detected
    #   0x2     ARM frequency currently capped
    #   0x4     currently throttled
    #   0x8     soft temp limit active now
    #   0x10000 under-voltage has occurred since boot
    #   0x20000 ARM frequency cap has occurred since boot
    #   0x40000 throttling has occurred since boot
    #   0x80000 soft temp limit has occurred since boot
    # 0x0 = clean. Anything in the low nibble = currently in trouble
    # (fail). Anything only in the high nibble = transient in the past
    # (warn — could be a brownout, power-on inrush, or a load spike).
    if command -v vcgencmd >/dev/null 2>&1; then
        local throttled_raw throttled_int
        throttled_raw=$(vcgencmd get_throttled 2>/dev/null | sed -n 's/^throttled=//p')
        if [[ -n "$throttled_raw" ]]; then
            # Convert hex to decimal in a portable way.
            throttled_int=$(( throttled_raw ))
            if (( throttled_int == 0 )); then
                pass_check "No throttling or under-voltage history ($throttled_raw)"
            else
                local now_bits=$(( throttled_int & 0xF ))
                local past_bits=$(( (throttled_int >> 16) & 0xF ))
                local now_msgs=() past_msgs=()
                (( now_bits & 0x1 )) && now_msgs+=("under-voltage NOW")
                (( now_bits & 0x2 )) && now_msgs+=("ARM freq capped NOW")
                (( now_bits & 0x4 )) && now_msgs+=("throttled NOW")
                (( now_bits & 0x8 )) && now_msgs+=("soft temp limit NOW")
                (( past_bits & 0x1 )) && past_msgs+=("under-voltage occurred")
                (( past_bits & 0x2 )) && past_msgs+=("ARM freq capping occurred")
                (( past_bits & 0x4 )) && past_msgs+=("throttling occurred")
                (( past_bits & 0x8 )) && past_msgs+=("soft temp limit occurred")
                if (( ${#now_msgs[@]} > 0 )); then
                    local joined
                    printf -v joined "%s, " "${now_msgs[@]}"; joined="${joined%, }"
                    fail_check "Pi is currently degraded ($throttled_raw): $joined — check PSU current rating"
                elif (( ${#past_msgs[@]} > 0 )); then
                    local joined
                    printf -v joined "%s, " "${past_msgs[@]}"; joined="${joined%, }"
                    warn "Pi degraded earlier this boot ($throttled_raw): $joined — may indicate brownout or PSU undersized"
                fi
            fi
        fi
    fi

    # 7. WiFi rekey / disconnect rate. Warn-only metric.
    #
    # Counts CTRL-EVENT-DISCONNECTED / key addition failed / Failed to
    # set GTK in wpa_supplicant journal over the last hour. The events
    # are caused by GTK rotation timeouts in the Broadcom firmware
    # (brcmfmac43430b0-sdio.bin on Pi Zero 2W is the prime example);
    # they're independent of WiFi power_save (system-tune.sh already
    # disables that at firstboot via NetworkManager dispatcher hook).
    #
    # Each event is a ~1-2s WiFi blip — snapclient TCP recovers,
    # multiroom audio resyncs. So this check is for *operator
    # visibility*, not for gating: a high count points at either a
    # mesh network with aggressive rekey schedule or a firmware bug
    # the operator can't fix from the smoke. Never fail — fail would
    # block release-gate on hardware/network conditions outside our
    # control.
    #
    # Thresholds:
    #   0           → pass
    #   1-3         → info (normal residential mesh)
    #   4-10        → warn (noisy mesh / aggressive AP rekey)
    #   >10         → warn (sustained — points at BCM43430 + mesh,
    #                       consider pinning bssid in wpa_supplicant.conf)
    if [[ "$wlan_state" == "up" ]] && command -v journalctl >/dev/null 2>&1; then
        local disconnect_count
        disconnect_count=$(journalctl -u wpa_supplicant.service \
            --since "1 hour ago" --no-pager -q 2>/dev/null \
            | grep -cE "CTRL-EVENT-DISCONNECTED|key addition failed|Failed to set GTK" || true)
        disconnect_count=${disconnect_count:-0}
        if (( disconnect_count == 0 )); then
            pass_check "WiFi stable: 0 rekey/disconnect events in last hour"
        elif (( disconnect_count <= 3 )); then
            info "WiFi: $disconnect_count rekey/disconnect events in last hour (normal range)"
        elif (( disconnect_count <= 10 )); then
            warn "WiFi: $disconnect_count rekey/disconnect events in last hour — noisy mesh or aggressive AP rekey (snapclient brief blips, TCP recovers)"
        else
            warn "WiFi: $disconnect_count rekey/disconnect events in last hour — sustained (likely BCM43430 firmware + mesh roaming; consider pinning bssid in wpa_supplicant.conf)"
        fi
    fi
}
