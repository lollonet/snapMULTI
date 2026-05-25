#!/usr/bin/env bash
# Shared system tuning for snapMULTI (server + client)
#
# Provides idempotent functions for CPU governor, USB autosuspend,
# WiFi power save, and Docker daemon configuration. Sourced by both
# deploy.sh (server) and setup.sh (client) to avoid configuration drift.
#
# Requires: scripts/common/logging.sh (info, warn, ok, error)

# Guard: source logging.sh + cmdline-manager.sh if not already loaded
if ! command -v info &>/dev/null; then
    TUNE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=logging.sh
    source "$TUNE_DIR/logging.sh"
fi
if ! command -v cmdline_path &>/dev/null; then
    TUNE_DIR="${TUNE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
    # shellcheck source=cmdline-manager.sh
    source "$TUNE_DIR/cmdline-manager.sh"
fi
if ! command -v is_pi_zero_2w &>/dev/null; then
    TUNE_DIR="${TUNE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
    # shellcheck source=device-detect.sh
    source "$TUNE_DIR/device-detect.sh"
fi

# ── Overlayroot detection ─────────────────────────────────────────
is_overlayroot() {
    mount 2>/dev/null | grep -q " on / type overlay"
}

# Backwards-compat alias — historical name, kept so external callers
# (operator scripts, ad-hoc debugging snippets) don't break. New code
# should call cmdline_path() directly.
overlayroot_cmdline_file() {
    cmdline_path
}

persist_overlayroot_enabled() {
    if ! cmdline_ensure_overlayroot; then
        warn "overlayroot: failed to patch cmdline.txt (missing file or sed failed)"
        return 1
    fi

    # recurse=0: overlay only `/`, leave NFS/USB fstab entries untouched (prevents systemd ordering cycles)
    if ! cat > /etc/overlayroot.local.conf <<'OREOF'
overlayroot="tmpfs:recurse=0"
overlayroot_cfgdisk="disabled"
OREOF
    then
        warn "overlayroot: failed to write /etc/overlayroot.local.conf"
        return 1
    fi

    ok "overlayroot persisted for next boot"
}

persist_overlayroot_disabled() {
    if ! cmdline_remove_overlayroot; then
        warn "overlayroot: failed to unpatch cmdline.txt (missing file or sed failed)"
        return 1
    fi

    rm -f /etc/overlayroot.local.conf
    ok "overlayroot disabled for next boot"
}

# ── CPU governor ──────────────────────────────────────────────────
# Sets all CPUs to 'performance' and persists via cpufrequtils.
# Audio playback needs consistent CPU speed — ramp-up latency
# from ondemand/schedutil causes buffer underruns.
tune_cpu_governor() {
    [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]] || return 0

    local set_count=0
    for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo performance > "$gov" 2>/dev/null && (( set_count++ )) || true
    done

    if [[ -d /etc/default ]]; then
        if ! echo 'GOVERNOR="performance"' > /etc/default/cpufrequtils 2>/dev/null; then
            is_overlayroot && warn "CPU governor: /etc write skipped (overlayroot)"
        fi
    fi

    if (( set_count > 0 )); then
        ok "CPU governor set to performance ($set_count CPUs)"
    else
        warn "CPU governor: no cpufreq paths writable, skipped"
    fi
}

# ── USB autosuspend ───────────────────────────────────────────────
# Disables USB autosuspend to prevent DAC/audio device sleep.
# Sets runtime parameter and creates persistent udev rule.
tune_usb_autosuspend() {
    [[ -f /sys/module/usbcore/parameters/autosuspend ]] || return 0

    if echo -1 > /sys/module/usbcore/parameters/autosuspend 2>/dev/null; then
        if mkdir -p /etc/udev/rules.d 2>/dev/null; then
            if ! echo 'ACTION=="add", SUBSYSTEM=="usb", DEVTYPE=="usb_device", TEST=="power/autosuspend", ATTR{power/autosuspend}="-1"' \
                > /etc/udev/rules.d/50-usb-no-autosuspend.rules 2>/dev/null; then
                is_overlayroot && warn "USB autosuspend: udev rule skipped (overlayroot)"
            fi
        fi
        ok "USB autosuspend disabled"
    else
        warn "USB autosuspend: not writable, skipped"
    fi
}

# ── BCM43430 firmware workaround (Pi Zero 2W) ─────────────────────
# Disables firmware-side 4-way handshake offload on BCM43430. The
# proprietary firmware blob brcmfmac43430b0-sdio.bin (Broadcom, last
# updated Mar 2022) has a known bug: GTK rotation messages from the
# AP fail with `wsec_key error -52` (ETIMEDOUT) when the driver tries
# to push the new key via send_key_to_dongle. On mesh WPA2 networks
# (multiple BSSIDs with the same SSID) this fires every ~15 min,
# causing 1-2 s WiFi blips that snapclient sees as brief reconnects.
#
# Issue: https://github.com/RPi-Distro/firmware-nonfree/issues/23
# (BCM43430/2 lacks 4WAY_HANDSHAKE_STA_PSK, 4WAY_HANDSHAKE_STA_1X,
# SAE_OFFLOAD — firmware doesn't actually support the offload it
# claims to support to the driver)
#
# Fix: feature_disable=0x80000 clears BRCMF_FEAT_FWSUP at module
# load, forcing wpa_supplicant userspace 4-way handshake instead.
# Validated on 2026-05-12: 0 wsec_key -52 in 28+ min vs ~12/h
# baseline pre-fix.
#
# Detection: check /proc/device-tree/model for "Zero 2 W". Other Pi
# models use BCM43455 / CYW43455 which have working firmware
# supplicant; applying feature_disable=0x80000 to them would disable
# a working feature (regression). Pi Zero 2W only.
tune_bcm43430_firmware_workaround() {
    is_pi_zero_2w || return 0  # not BCM43430 — fix would disable a working feature

    local conf=/etc/modprobe.d/snapmulti-brcmfmac.conf
    local expected_payload='options brcmfmac roamoff=1 feature_disable=0x80000'

    # Idempotent: only write if missing or content drifted.
    if [[ -f "$conf" ]] && grep -qF "$expected_payload" "$conf"; then
        ok "BCM43430 firmware workaround already configured ($conf)"
        return 0
    fi

    if ! cat > "$conf" <<'BCMEOF'
# Workaround for BCM43430/2 firmware GTK rekey timeout (wsec_key error -52)
# Disables firmware-side 4-way handshake offload — forces wpa_supplicant
# userspace handshake which works correctly on Pi Zero 2W.
# See: https://github.com/RPi-Distro/firmware-nonfree/issues/23
# Applied by snapMULTI system-tune.sh on Pi Zero 2W only.
options brcmfmac roamoff=1 feature_disable=0x80000
BCMEOF
    then
        # Best-effort write — common failure is overlayroot post-install
        # re-runs where /etc is read-only. Return 0 so the caller (run
        # under `set -e`) doesn't abort: a missing workaround is a
        # warn-level issue, not a fatal one, and the warn above is
        # surfaced through the normal logging chain.
        is_overlayroot && warn "BCM43430 workaround: $conf not writable (overlayroot — write before ro-mode enable)"
        return 0
    fi

    ok "BCM43430 firmware workaround installed at $conf (effective on next module reload)"
    # Note: deliberately NOT reloading brcmfmac here — that would tear
    # down WiFi mid-install. Effective on the next reboot, which
    # firstboot already schedules at the end of setup.
}

# ── Appliance swap safety ────────────────────────────────────────
# Pi OS Bookworm ships rpi-swap/zram helpers that can create /var/swap.
# Under overlayroot=tmpfs, /var lives in the volatile upper layer: a
# swap file there allocates RAM-backed tmpfs pages to provide "swap",
# which is self-defeating and can trigger ENOSPC/containerd recovery.
# snapMULTI is an appliance with memory-limited containers and a
# reflash-first update policy, so swap is disabled on every install.
#
# Observed live:
#   - pi-zero: /var/swap filled the 256 MB overlay tmpfs → reboot loop
#   - pi3-1gb: rpi-resize-swap-file repeatedly tried 580 MB in tmpfs
#   - pi-server: rpi-resize-swap-file peaked at 4 GB while making swap
#
# Fix: disable the generator path, mask the generated/helper units, and
# remove any pre-existing /var/swap.
tune_appliance_swap_safety() {
    # Authoritative kill switch for Pi OS Bookworm's rpi-swap package:
    # /lib/systemd/system-generators/rpi-swap-generator reads
    # /etc/rpi/swap.conf at every boot and regenerates dev-zram0.swap
    # + the writeback timer in /run/systemd/generator/. systemctl mask
    # symlinks under /etc/systemd/system/ should outrank /run/... but
    # were observed live on pi-zero to leave /dev/zram0 attached as
    # swap after reboot. Replacing /etc/rpi/swap.conf with a config
    # that has neither a [File] nor a [Zram] section makes the
    # generator emit zero swap units — the root-cause fix. systemctl
    # mask is kept as a defense-in-depth measure for kernels and
    # distros that bypass the rpi-swap generator entirely.
    local swap_conf=/etc/rpi/swap.conf
    local swap_conf_payload='# snapMULTI appliance mode: zram and file swap disabled.
# See tune_appliance_swap_safety
# in scripts/common/system-tune.sh). Re-add [File] / [Zram]
# sections to re-enable.'

    local units=(
        rpi-resize-swap-file.service
        rpi-setup-loop@var-swap.service
        dev-zram0.swap
        systemd-zram-setup@zram0.service
        rpi-zram-writeback.service
        rpi-zram-writeback.timer
    )

    local all_masked=1 u
    for u in "${units[@]}"; do
        if ! systemctl list-unit-files "$u" --no-legend 2>/dev/null | grep -q masked; then
            all_masked=0
            break
        fi
    done
    local conf_ok=0
    if [[ -f "$swap_conf" ]] && grep -qF "snapMULTI appliance mode" "$swap_conf"; then
        conf_ok=1
    elif [[ ! -d /etc/rpi ]]; then
        # rpi-swap package not installed at all — nothing to neutralise.
        # Note: an absent swap.conf with /etc/rpi/ still present means the
        # generator runs with package defaults and would emit a zram unit,
        # so we must still write the override in that case.
        conf_ok=1
    fi
    if (( all_masked == 1 )) && (( conf_ok == 1 )) && [[ ! -f /var/swap ]]; then
        ok "Appliance swap safety already configured"
        return 0
    fi

    for u in "${units[@]}"; do
        systemctl mask "$u" >/dev/null 2>&1 || true
    done
    if [[ -d /etc/rpi ]]; then
        if ! printf '%s\n' "$swap_conf_payload" > "$swap_conf" 2>/dev/null; then
            is_overlayroot && warn "rpi-swap-generator config not writable (overlayroot — write before ro-mode enable)"
        fi
    fi
    # rpi-swap can activate before cloud-init runs firstboot. Masking
    # prevents future activations; swapoff makes the current boot match
    # the appliance policy immediately.
    if [[ -s /proc/swaps ]] && awk 'NR > 1 { found=1 } END { exit found ? 0 : 1 }' /proc/swaps; then
        /sbin/swapoff -a 2>/dev/null || /usr/sbin/swapoff -a 2>/dev/null || true
    fi
    rm -f /var/swap 2>/dev/null || true

    if systemctl list-unit-files rpi-resize-swap-file.service --no-legend 2>/dev/null | grep -q masked; then
        ok "Appliance swap safety applied (swap units masked, swap.conf cleared, /var/swap removed)"
        return 0
    fi

    if is_overlayroot; then
        warn "zram mask not persisted: overlayroot already active (firstboot ordering bug?)"
    else
        warn "zram mask failed despite writable /etc; firstboot retry may resolve"
    fi
    return 0  # best-effort: never abort firstboot
}

# Backward-compatible wrapper retained for tests/docs that still refer
# to the original Pi-Zero-specific guard. New firstboot code calls the
# broader appliance guard for every install.
tune_pi_zero_2w_swap_safety() {
    is_pi_zero_2w || return 0
    tune_appliance_swap_safety
}

# ── WiFi power save ───────────────────────────────────────────────
# Disables WiFi power management to prevent connection drops.
# Uses NetworkManager dispatcher script for persistence — this
# survives overlayroot because it runs `iw` on every interface-up
# event rather than relying on a static config file.
tune_wifi_powersave() {
    # Disable immediately on any active WiFi interface
    local iface
    iface=$(ip -o link show 2>/dev/null | awk -F': ' '$2 ~ /^wl/ && /state UP/ {print $2; exit}')
    if [[ -n "$iface" ]]; then
        if command -v iw &>/dev/null || [[ -x /usr/sbin/iw ]]; then
            iw dev "$iface" set power_save off 2>/dev/null \
                || /usr/sbin/iw dev "$iface" set power_save off 2>/dev/null \
                || true
        else
            warn "WiFi power save: iw not found, skipping immediate disable"
        fi
    fi

    # Persistent: NM dispatcher runs iw on every interface-up
    if [[ -d /etc/NetworkManager/dispatcher.d ]]; then
        local hook="/etc/NetworkManager/dispatcher.d/99-wifi-powersave-off"
        if [[ ! -f "$hook" ]]; then
            if cat > "$hook" <<'WEOF'
#!/bin/sh
# NetworkManager also calls dispatcher hooks for lo/docker/veth events.
# Those are not WiFi devices; always exit 0 so NM doesn't log failures.
case "$1:$2" in
    wl*:up|wlan*:up)
        /usr/sbin/iw dev "$1" set power_save off >/dev/null 2>&1 || true
        ;;
esac
exit 0
WEOF
            then
                chmod +x "$hook"
                ok "WiFi power save disabled (persistent via NM dispatcher)"
            else
                is_overlayroot && warn "WiFi power save: dispatcher script skipped (overlayroot)"
            fi
        else
            ok "WiFi power save already configured"
        fi
    fi
}

# ── Docker daemon.json ────────────────────────────────────────────
# Merges settings into /etc/docker/daemon.json.
# Usage:
#   tune_docker_daemon                        # log rotation only
#   tune_docker_daemon --live-restore         # + live-restore
#   tune_docker_daemon --fuse-overlayfs       # + fuse-overlayfs storage driver
#   tune_docker_daemon --live-restore --fuse-overlayfs  # all modes (read-only FS support)
#
# Uses Python JSON merge to safely update existing configs.
# Returns 0 on success, 1 on failure.
tune_docker_daemon() {
    local want_live_restore=false
    local want_fuse_overlayfs=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --live-restore)     want_live_restore=true ;;
            --fuse-overlayfs)   want_fuse_overlayfs=true ;;
            *) warn "tune_docker_daemon: unknown option $1" ;;
        esac
        shift
    done

    mkdir -p /etc/docker 2>/dev/null || true

    # Build desired config as Python dict literal
    local py_updates='cfg.setdefault("log-driver", "json-file"); cfg.setdefault("log-opts", {"max-size": "10m", "max-file": "3"})'
    [[ "$want_live_restore" == "true" ]] && py_updates="$py_updates; cfg['live-restore'] = True"
    if [[ "$want_fuse_overlayfs" == "true" ]]; then
        py_updates="$py_updates; cfg['storage-driver'] = 'fuse-overlayfs'"
    else
        # Remove storage-driver if present — reverts Docker to its default (overlay2)
        py_updates="$py_updates; cfg.pop('storage-driver', None)"
    fi

    if [[ -f /etc/docker/daemon.json ]]; then
        # Check if already configured
        local needs_update=false
        if [[ "$want_live_restore" == "true" ]] && ! grep -q '"live-restore"' /etc/docker/daemon.json 2>/dev/null; then
            needs_update=true
        fi
        if [[ "$want_fuse_overlayfs" == "true" ]] && ! grep -q '"fuse-overlayfs"' /etc/docker/daemon.json 2>/dev/null; then
            needs_update=true
        fi
        # Also update if fuse-overlayfs is present but not wanted (rollback)
        if [[ "$want_fuse_overlayfs" != "true" ]] && grep -q '"storage-driver"' /etc/docker/daemon.json 2>/dev/null; then
            needs_update=true
        fi
        if ! grep -q '"log-driver"' /etc/docker/daemon.json 2>/dev/null; then
            needs_update=true
        fi

        if [[ "$needs_update" == "true" ]]; then
            if ! command -v python3 &>/dev/null; then
                warn "Docker daemon.json: python3 not found, cannot merge config"
                return 1
            fi
            info "Updating /etc/docker/daemon.json..."
            local tmp
            tmp=$(mktemp)
            if python3 -c "
import json
with open('/etc/docker/daemon.json') as f:
    cfg = json.load(f)
$py_updates
with open('$tmp', 'w') as f:
    json.dump(cfg, f, indent=2)
    f.write('\n')
" 2>/dev/null && mv "$tmp" /etc/docker/daemon.json; then
                ok "Docker daemon.json updated"
            else
                rm -f "$tmp"
                warn "Docker daemon.json: merge failed"
                return 1
            fi
        else
            info "Docker daemon.json already configured"
        fi
    else
        # Create fresh
        info "Writing /etc/docker/daemon.json..."
        local json_content='{'
        [[ "$want_fuse_overlayfs" == "true" ]] && json_content="$json_content"$'\n  "storage-driver": "fuse-overlayfs",'
        [[ "$want_live_restore" == "true" ]] && json_content="$json_content"$'\n  "live-restore": true,'
        json_content="$json_content"'
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}'
        echo "$json_content" > /etc/docker/daemon.json
        ok "Docker daemon.json created"
    fi
}

# ── Avahi hardening ─────────────────────────────────────────────
# Pins mDNS hostname, restricts to physical network interfaces, and
# keeps announcements IPv4-only. Snapclient 0.35 can pick IPv6
# link-local SRV targets from Avahi and then fail to connect from a
# different interface scope; the rest of snapMULTI discovery is already
# IPv4-first for this reason.
tune_avahi_daemon() {
    local hostname="${1:-$(hostname)}"
    local conf="/etc/avahi/avahi-daemon.conf"
    [[ -f "$conf" ]] || return 0

    local avahi_changed=false

    # Pin hostname to prevent avahi from appending -2, -3, etc.
    if grep -q '^\[server\]' "$conf"; then
        if ! grep -q "^host-name=" "$conf"; then
            sed -i "/^\[server\]/a host-name=${hostname}" "$conf"
            avahi_changed=true
        fi

        if grep -q "^use-ipv4=" "$conf"; then
            if ! grep -q "^use-ipv4=yes$" "$conf"; then
                sed -i "s/^use-ipv4=.*/use-ipv4=yes/" "$conf"
                avahi_changed=true
            fi
        else
            sed -i "/^\[server\]/a use-ipv4=yes" "$conf"
            avahi_changed=true
        fi

        if grep -q "^use-ipv6=" "$conf"; then
            if ! grep -q "^use-ipv6=no$" "$conf"; then
                sed -i "s/^use-ipv6=.*/use-ipv6=no/" "$conf"
                avahi_changed=true
            fi
        else
            sed -i "/^\[server\]/a use-ipv6=no" "$conf"
            avahi_changed=true
        fi
    fi

    # Restrict to the primary physical interface. On Ethernet+WiFi
    # devices, Avahi can otherwise publish the same hostname on the
    # transient WiFi DHCP address before WiFi exclusivity disables wlan0;
    # macOS and consumer mDNS reflectors (e.g. FritzBox) then keep the
    # stale .local address in cache, which forces a hostname rename to
    # <host>-2.local on conflict (issue #425).
    #
    # Wired-carrier priority: if any eth*/en* interface has carrier we
    # restrict Avahi to wired only — this mirrors boot-tune.sh which
    # disables WiFi when Ethernet has an IP, but takes effect during the
    # first-boot window before boot-tune has run. WiFi-only devices (no
    # eth carrier) fall through to the default-route enumeration.
    local ifaces=""
    local iface
    local wired_iface=""
    for iface in /sys/class/net/eth* /sys/class/net/en*; do
        [[ -e "$iface" ]] || continue
        if [[ "$(cat "$iface/carrier" 2>/dev/null)" == "1" ]]; then
            wired_iface="${iface##*/}"
            break
        fi
    done
    if [[ -n "$wired_iface" ]]; then
        ifaces="$wired_iface"
    else
        for iface in $(ip -o route show default 2>/dev/null | awk '
            {
                for (i = 1; i <= NF; i++) {
                    if ($i == "dev" && $(i + 1) ~ /^(eth|wlan|en)/ && !seen[$(i + 1)]++) {
                        print $(i + 1)
                    }
                }
            }
        '); do
            [[ -n "$ifaces" ]] && ifaces="${ifaces},"
            ifaces="${ifaces}${iface}"
        done
        if [[ -z "$ifaces" ]]; then
            for iface in $(ip -o -4 addr show scope global up 2>/dev/null | awk '$2 ~ /^(eth|wlan|en)/ && !seen[$2]++ {print $2}'); do
                [[ -n "$ifaces" ]] && ifaces="${ifaces},"
                ifaces="${ifaces}${iface}"
            done
        fi
    fi
    if [[ -n "$ifaces" ]]; then
        if ! grep -q "^allow-interfaces=${ifaces}$" "$conf"; then
            if grep -q '^allow-interfaces=' "$conf"; then
                sed -i "s/^allow-interfaces=.*/allow-interfaces=${ifaces}/" "$conf"
            elif grep -q '^\[server\]' "$conf"; then
                sed -i "/^\[server\]/a allow-interfaces=${ifaces}" "$conf"
            fi
            avahi_changed=true
        fi
    fi

    if [[ "$avahi_changed" == "true" ]]; then
        systemctl restart avahi-daemon 2>/dev/null || true
        # Snapcast 0.35 libavahi-client does not reconnect after avahi
        # restart. snapmulti-server.service and snapclient.service no
        # longer have PartOf=avahi-daemon.service (that gave Avahi full
        # lifecycle control over the audio stack), so we trigger an
        # explicit, operator-initiated refresh of the snapcast
        # processes here. Both restarts are best-effort: this function
        # also runs during firstboot before the audio units exist.
        local audio_unit
        for audio_unit in snapmulti-server.service snapclient.service; do
            if systemctl is-active --quiet "$audio_unit" 2>/dev/null; then
                systemctl restart "$audio_unit" 2>/dev/null || true
            fi
        done
        ok "Avahi hardened: host-name=${hostname}, interfaces=${ifaces:-all}, ipv4=yes, ipv6=no"
    else
        ok "Avahi already configured"
    fi

    # Drop-in: order avahi-daemon AFTER network-online.target so mDNS only
    # publishes once the network is usable. Without this, avahi can answer
    # mDNS before NM finishes IPv4 acquisition, advertising on a transient
    # IP that goes away seconds later.
    local dropin_dir="/etc/systemd/system/avahi-daemon.service.d"
    local dropin="${dropin_dir}/network.conf"
    if mkdir -p "$dropin_dir" 2>/dev/null && [[ ! -f "$dropin" ]]; then
        if cat > "$dropin" <<'AVEOF'
[Unit]
After=network-online.target
Wants=network-online.target
AVEOF
        then
            systemctl daemon-reload 2>/dev/null || true
            ok "Avahi ordered after network-online.target"
        fi
    fi
}

# Tell NetworkManager to ignore Docker bridges + veth pairs. Without
# this, NM adopts every `br-*` / `veth*` / `docker0` interface that
# Docker creates as "connected (externally)". That state leaks netlink
# address-change events when host-side probes run on eth0 (notably
# device-smoke's `arping -D`), which makes avahi-daemon briefly
# withdraw its address record on eth0, re-register, and then see its
# own re-announce coming back through the NM-tracked bridge — declared
# as a foreign claim of the hostname and resolved by renaming the host
# to `<hostname>-2`. Snapcast / AirPlay / MPD then publish via the -2
# name and clients searching for `<hostname>.local` fail.
#
# Root-cause reproducer on pi-server (both mode, 2026-05-15 11:53:17):
# arping -D on eth0 → avahi "Withdrawing address record for ..." →
# "Host name conflict, retrying with pi-server-2". With NM excluded
# from Docker interfaces this loop does not arm.
#
# Idempotent. Only acts when NetworkManager is installed.
tune_nm_docker_unmanaged() {
    command -v nmcli >/dev/null 2>&1 || return 0
    [[ -d /etc/NetworkManager ]] || return 0

    local conf_dir="/etc/NetworkManager/conf.d"
    local conf="${conf_dir}/99-docker-unmanaged.conf"
    local desired
    desired=$(cat <<'NMCONF'
# Managed by snapMULTI tune_nm_docker_unmanaged() — see system-tune.sh
# for the rationale (avahi hostname conflict triggered by NM-tracked
# Docker bridges during arping DAD probes).
[keyfile]
unmanaged-devices=interface-name:veth*;interface-name:br-*;interface-name:docker*
NMCONF
)

    mkdir -p "$conf_dir" 2>/dev/null || return 0

    if [[ -f "$conf" ]] && [[ "$(cat "$conf" 2>/dev/null)" == "$desired" ]]; then
        ok "NetworkManager already ignores Docker bridges"
        return 0
    fi

    printf '%s\n' "$desired" > "$conf" || {
        warn "Failed to write $conf — NM may still adopt Docker bridges"
        return 0
    }

    systemctl reload NetworkManager 2>/dev/null || \
        systemctl restart NetworkManager 2>/dev/null || true

    # Detach interfaces NM already adopted before the rule landed.
    # `set managed no` is idempotent and a no-op if the interface is
    # already unmanaged.
    local iface
    while IFS= read -r iface; do
        [[ -z "$iface" ]] && continue
        nmcli device set "$iface" managed no >/dev/null 2>&1 || true
    done < <(nmcli -t -f DEVICE,TYPE device 2>/dev/null \
        | awk -F: '/:bridge$|:ethernet$/ {print $1}' \
        | grep -E '^(veth|br-|docker)' || true)

    ok "NetworkManager configured to ignore Docker bridges (veth*, br-*, docker*)"
}

# ── Read-only filesystem (overlayroot) ──────────────────────────

# Install ro-mode helper and persist SSH host keys for overlayroot.
prepare_readonly_helpers() {
    local ro_mode_script="${1:-}"

    # Install ro-mode helper if available
    if [[ -n "$ro_mode_script" ]] && [[ -f "$ro_mode_script" ]]; then
        install -m 755 "$ro_mode_script" /usr/local/bin/ro-mode
        ok "ro-mode helper installed"
    fi

    # Persist SSH host keys across reboots
    if [[ -d /etc/ssh ]]; then
        mkdir -p /etc/ssh/keys_permanent
        cp -n /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub /etc/ssh/keys_permanent/ 2>/dev/null || true
        cat > /etc/systemd/system/ssh-keys-restore.service << 'SSHEOF'
[Unit]
Description=Restore SSH host keys from permanent storage
Before=ssh.service sshd.service
ConditionPathExists=/etc/ssh/keys_permanent

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'cp /etc/ssh/keys_permanent/ssh_host_* /etc/ssh/ 2>/dev/null && chmod 600 /etc/ssh/ssh_host_*_key'

[Install]
WantedBy=multi-user.target
SSHEOF
        systemctl daemon-reload
        systemctl enable ssh-keys-restore.service 2>/dev/null
        ok "SSH host keys persisted"
    fi
}

# Configure overlayfs for SD card protection. Requires raspi-config.
setup_readonly_fs() {
    local ro_mode_script="${1:-}"

    prepare_readonly_helpers "$ro_mode_script"

    # Workaround: Debian trixie systemd-remount-fs fails with overlayroot
    # because fsconfig() rejects overlay reconfigure (systemd/systemd#39558).
    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/overlayfs-workaround.conf << 'SYSDEOF'
[Manager]
DefaultEnvironment="LIBMOUNT_FORCE_MOUNT2=always"
SYSDEOF

    # Defensive cmdline.txt sanity check BEFORE raspi-config touches it.
    # Some Pi OS images ship `console=serial0,115200 console=tty1` and
    # raspi-config preserves both. If `console=tty1` is missing — e.g. a
    # custom image dropped it — the first boot post-overlayroot will
    # render emergency-mode messages on a console nobody sees, leaving
    # the user with a frozen black screen. Restore tty1 before enabling
    # overlayfs so a failure surface stays visible.
    local _cmdline_check
    _cmdline_check=$(cmdline_path 2>/dev/null || true)
    if [[ -n "$_cmdline_check" ]] && ! grep -qE '(^| )console=tty1( |$)' "$_cmdline_check"; then
        if cmdline_ensure_console_tty1; then
            ok "Restored console=tty1 to cmdline.txt (was missing)"
        else
            warn "Could not restore console=tty1 — emergency mode messages may not be visible"
        fi
    fi

    # Enable overlayfs via raspi-config (takes effect after reboot)
    if command -v raspi-config &>/dev/null; then
        if raspi-config nonint do_overlayfs 0; then
            if persist_overlayroot_enabled; then
                # NOTE: an explicit `update-initramfs -u -k all` used to live
                # here as "cheap insurance" (PR #317). It backfired:
                # raspi-config has already installed the overlayroot package
                # and its initramfs hooks are partially live by the time we
                # get here, so `update-initramfs -u` calls into mkinitramfs
                # which can no longer determine the underlying device for
                # `/` and aborts with `failed to determine device for /`.
                # The fail was silent (`>/dev/null 2>&1`), the on-disk
                # initramfs from raspi-config's own `update-initramfs -c -k
                # all` is fine, BUT the WARN message it printed was
                # auto-realising: pi-server + pi-display both required a
                # manual power-cycle at first boot post-2026-05-10 v0.7.0.
                # Trusting raspi-config's internal rebuild fixes the
                # symptom on both devices. If a future race re-emerges,
                # the right fix is to capture output and apply MODULES=most
                # — NOT to reintroduce a silent extra rebuild.
                ok "Read-only filesystem enabled (activates after reboot)"
            else
                rm -f /etc/systemd/system.conf.d/overlayfs-workaround.conf
                warn "overlayroot persistence failed — workaround rolled back"
                return 1
            fi
        else
            rm -f /etc/systemd/system.conf.d/overlayfs-workaround.conf
            warn "raspi-config do_overlayfs failed — workaround rolled back"
            return 1
        fi
    else
        rm -f /etc/systemd/system.conf.d/overlayfs-workaround.conf
        warn "raspi-config not found — overlayroot not enabled"
        return 1
    fi
}

# ── Boot tuning service ─────────────────────────────────────────
# Installs systemd oneshot that re-applies runtime tuning at every boot.
# Required because cpufrequtils/networkd-dispatcher aren't installed.
install_boot_tune_service() {
    local boot_tune_script="${1:-}"
    [[ -f "$boot_tune_script" ]] || return 0

    # Always overwrite — ensures fixes propagate even on overlayroot systems
    # where the lower layer may have a stale copy from a previous install.
    install -m 755 "$boot_tune_script" /usr/local/bin/snapmulti-boot-tune.sh

    # Enable hardware watchdog — auto-reboot on system hang (60s timeout)
    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/watchdog.conf <<'WEOF'
[Manager]
RuntimeWatchdogSec=60
WEOF
    cat > /etc/systemd/system/snapmulti-boot-tune.service <<'SEOF'
[Unit]
Description=snapMULTI boot-time system tuning
After=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/snapmulti-boot-tune.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SEOF
    # Docker driver reconciliation — runs Before=docker.service
    local driver_script
    driver_script=$(dirname "$boot_tune_script")/docker-driver-reconcile.sh
    if [[ -f "$driver_script" ]]; then
        install -m 755 "$driver_script" /usr/local/bin/snapmulti-docker-driver.sh
        cat > /etc/systemd/system/snapmulti-docker-driver.service <<'DEOF'
[Unit]
Description=snapMULTI Docker storage driver reconciliation
DefaultDependencies=no
Before=docker.service
After=local-fs.target
Conflicts=shutdown.target
Before=shutdown.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/snapmulti-docker-driver.sh

[Install]
WantedBy=multi-user.target
DEOF
    fi

    install_smoke_tone_service

    systemctl daemon-reload
    systemctl enable snapmulti-boot-tune.service 2>/dev/null
    systemctl enable snapmulti-docker-driver.service 2>/dev/null || true

    # NetworkManager-wait-online.service is masked at kernel cmdline level
    # (prepare-sd.sh writes systemd.mask=NetworkManager-wait-online.service
    # to cmdline.txt) — survives overlayroot upper-layer wipes and is
    # parsed before any unit starts. No systemctl mask needed here.

    ok "Boot tuning service installed (CPU, USB, CAKE persist across reboots)"
}

# Install acoustic smoke assets (WAVs + play-smoke-tone helper + auto-boot-smoke service).
# Callable from server's install_boot_tune_service AND from client-native's
# setup-zero2w.sh — Pi Zero gets the post-reboot tone without the rest of
# the boot-tune chain (no Docker, no compose, no docker-driver-reconcile).
# Arg 1: "server" (default) or "client" — drives whether the unit Wants/After docker.service.
install_smoke_tone_service() {
    local _mode="${1:-server}"
    # Resolved relative to ${BASH_SOURCE[0]} so this works whether system-tune.sh
    # was sourced from the server (scripts/common/) or client (client/common/scripts/common/) tree.
    local _tune_dir audio_src
    _tune_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    audio_src="$_tune_dir/audio"
    if [[ -d "$audio_src" ]]; then
        install -d -m 755 /usr/share/snapmulti/audio
        for _wav in "$audio_src"/smoke-*.wav; do
            [[ -f "$_wav" ]] && install -m 644 "$_wav" /usr/share/snapmulti/audio/
        done
        unset _wav
    fi
    if [[ -f "$_tune_dir/play-smoke-tone.sh" ]]; then
        install -m 755 "$_tune_dir/play-smoke-tone.sh" /usr/local/bin/snapmulti-play-smoke-tone
    fi

    if [[ -f "$_tune_dir/auto-boot-smoke.sh" ]]; then
        install -m 755 "$_tune_dir/auto-boot-smoke.sh" /usr/local/bin/snapmulti-auto-boot-smoke
        # Client-native (Pi Zero) has no Docker → omit Wants=docker.service to avoid `Unit docker.service not found` journal noise on every boot.
        if [[ "$_mode" == "client" ]]; then
            cat > /etc/systemd/system/snapmulti-auto-boot-smoke.service <<'BSEOF'
[Unit]
Description=snapMULTI auto boot smoke (acoustic health cue)
After=multi-user.target snapclient.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/snapmulti-auto-boot-smoke
TimeoutStartSec=240
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
BSEOF
        else
            cat > /etc/systemd/system/snapmulti-auto-boot-smoke.service <<'BSEOF'
[Unit]
Description=snapMULTI auto boot smoke (acoustic health cue)
After=multi-user.target docker.service snapmulti-server.service snapclient.service
Wants=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/snapmulti-auto-boot-smoke
# 90s systemd-settled wait + 90s audio-core healthy wait + 10s buffer + 50s margin = 240s ceiling. NFS-grandi scan MPD non blocca (best-effort, non in CORE_SERVICES).
TimeoutStartSec=240
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
BSEOF
        fi
        systemctl daemon-reload
        systemctl enable snapmulti-auto-boot-smoke.service 2>/dev/null || true
    fi
}
