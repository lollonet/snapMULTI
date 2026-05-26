#!/usr/bin/env bash
# Boot-time system tuning for snapMULTI
#
# Re-applies runtime tuning at every boot. Required because:
# - cpufrequtils is not installed (nobody reads /etc/default/cpufrequtils)
# - udev rules don't re-trigger for already-present USB devices at boot
# - networkd-dispatcher is not installed (CAKE/DSCP hook never runs)
#
# Installed as systemd oneshot by deploy.sh/setup.sh. Idempotent and safe on
# both writable and overlayroot filesystems.

set -euo pipefail

# ── CPU governor: performance ─────────────────────────────────────
for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -f "$gov" ] && echo performance > "$gov" 2>/dev/null \
        || logger -t boot-tune -p warning "Failed to set CPU governor on $gov"
done

# ── USB autosuspend: disabled ─────────────────────────────────────
if [ -f /sys/module/usbcore/parameters/autosuspend ]; then
    echo -1 > /sys/module/usbcore/parameters/autosuspend 2>/dev/null \
        || logger -t boot-tune -p warning "Failed to disable USB autosuspend"
fi

# Also apply to any already-connected USB devices
for ctrl in /sys/bus/usb/devices/*/power/autosuspend; do
    [ -f "$ctrl" ] && echo -1 > "$ctrl" 2>/dev/null || true
done

# ── WiFi auto-disable when Ethernet is connected ─────────────────
# Avoids dual mDNS announcements (clients might connect to the wrong IP).
# If Ethernet is unplugged or has no IP, WiFi stays active as fallback.
#
# `|| true` is required: on WiFi-only devices (Pi Zero 2W, Pi 5 wireless,
# anything without an `eth0` device) `ip -4 addr show eth0` returns
# exit 1 ("Device 'eth0' does not exist"). Under `set -euo pipefail`
# that propagates through the pipeline and the assignment kills the
# script before reaching the rest of the boot-time tuning. Verified
# 2026-05-10 on pi-zero — snapmulti-boot-tune.service was failing in
# 87 ms with no diagnostic in the journal, every boot.
if command -v nmcli &>/dev/null; then
    eth_ip=$(ip -4 addr show eth0 2>/dev/null | awk '/inet /{print $2; exit}' || true)
    if [[ -n "$eth_ip" ]]; then
        # Ethernet has an IP — safe to disable WiFi
        nmcli radio wifi off 2>/dev/null \
            && logger -t boot-tune "Ethernet $eth_ip — WiFi disabled (single mDNS)" \
            || logger -t boot-tune -p warning "Failed to disable WiFi"
    else
        # No Ethernet IP — ensure WiFi is on (recovery after cable removal)
        nmcli radio wifi on 2>/dev/null || true
    fi
fi

# ── Memory tuning: reduce swappiness for audio workloads ──────────
# Default 60 is too aggressive — audio buffers should stay in RAM
echo 10 > /proc/sys/vm/swappiness 2>/dev/null || true

# ── Hardware watchdog: auto-reboot on system hang ─────────────────
# Pi's bcm2835_wdt triggers reboot if systemd stops petting it
modprobe bcm2835_wdt 2>/dev/null || true

# ── Artwork cache cleanup: remove files older than 30 days ────────
find /opt/snapmulti/artwork -type f -mtime +30 -delete 2>/dev/null || true

# ── Overlayroot tmpfs sizing + monitoring ──────────────────────────
# Default tmpfs is 50% of RAM. On 2GB Pi that's 1GB — tight for Docker
# runtime state + logs. Size to 25% of RAM (Docker images are baked to
# the lower layer, so tmpfs only holds runtime writes).
if mount | grep -q ' on / type overlay'; then
    total_mb=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null) || total_mb=0
    if [ "$total_mb" -gt 0 ] 2>/dev/null; then
        target_mb=$((total_mb / 4))
        # Floor at 256MB, cap at 2048MB
        [ "$target_mb" -lt 256 ] && target_mb=256
        [ "$target_mb" -gt 2048 ] && target_mb=2048
        # Find the tmpfs backing the overlay upper dir.
        # Raspberry Pi OS mounts it at /media/root-rw (not /overlay).
        # Extract upperdir from the overlay mount, then walk up to the tmpfs.
        tmpfs_mp=""
        if command -v findmnt &>/dev/null; then
            # upperdir=/media/root-rw/overlay → parent tmpfs at /media/root-rw
            _upper=$(findmnt -n -o OPTIONS / 2>/dev/null | sed -n 's/.*upperdir=\([^,]*\).*/\1/p') || true
            if [ -n "${_upper:-}" ]; then
                # The tmpfs is the parent of the upperdir (e.g. /media/root-rw)
                tmpfs_mp=$(findmnt -n -o TARGET -T "$(dirname "$_upper")" 2>/dev/null) || true
            fi
        fi
        [ -z "$tmpfs_mp" ] && tmpfs_mp=$(awk '$3 == "tmpfs" && $2 ~ /root-rw|overlay/ {print $2; exit}' /proc/mounts)
        [ -z "$tmpfs_mp" ] && tmpfs_mp="/media/root-rw"  # last resort default
        # Remount with explicit size (idempotent — safe to re-run)
        if mount -o "remount,size=${target_mb}M" "$tmpfs_mp" 2>/dev/null; then
            logger -t boot-tune "Overlayroot tmpfs sized to ${target_mb}MB at $tmpfs_mp (RAM: ${total_mb}MB)"
        else
            logger -t boot-tune -p warning "Failed to resize overlayroot tmpfs at $tmpfs_mp"
        fi
    fi

    # Monitor usage — warn early so user can act before system crashes
    usage=$(df / --output=pcent 2>/dev/null | tail -1 | tr -cd '0-9')
    if [ -n "$usage" ] 2>/dev/null; then
        if [ "$usage" -gt 90 ]; then
            logger -t boot-tune -p crit "CRITICAL: root tmpfs ${usage}% full — reboot imminent. Run: sudo ro-mode disable && sudo reboot"
        elif [ "$usage" -gt 70 ]; then
            logger -t boot-tune -p warning "WARNING: root tmpfs ${usage}% full. Run: sudo ro-mode disable && sudo reboot"
        fi
    fi
fi

# ── CAKE QoS + DSCP EF on Snapcast ports (server only) ────────────
# CAKE prioritizes outbound audio packets from snapserver (ports 1704/1705).
# On clients, audio arrives inbound — DSCP OUTPUT marking does nothing,
# and CAKE can hang on Pi Zero 2 W when interfaces are DOWN.
# Skip entirely on client-only systems (no server compose file present).
if [[ -f /opt/snapmulti/docker-compose.yml ]]; then
    modprobe sch_cake 2>/dev/null || true

    for iface in $(ip -o route show default 2>/dev/null | awk '{print $5}'); do
        # Skip interfaces that are not UP — tc qdisc can hang in D-state
        if ! ip link show "$iface" 2>/dev/null | grep -q 'state UP'; then
            continue
        fi
        if echo "$iface" | grep -qE '^(wlan|wlp)'; then
            tc qdisc replace dev "$iface" root cake diffserv4 2>/dev/null || true
        else
            bw=$(cat "/sys/class/net/$iface/speed" 2>/dev/null) || true
            if [ -n "$bw" ] && [ "$bw" -gt 0 ] 2>/dev/null; then
                tc qdisc replace dev "$iface" root cake bandwidth "${bw}mbit" diffserv4 2>/dev/null || true
            else
                tc qdisc replace dev "$iface" root cake diffserv4 2>/dev/null || true
            fi
        fi
    done

    # DSCP is interface-agnostic (OUTPUT chain by sport)
    for port in 1704 1705; do
        iptables -t mangle -C OUTPUT -p tcp --sport "$port" -j DSCP --set-dscp-class EF 2>/dev/null \
            || iptables -t mangle -A OUTPUT -p tcp --sport "$port" -j DSCP --set-dscp-class EF 2>/dev/null \
            || true
    done
fi

# ── Restart MPD if music directory wasn't ready at container start ──
# Docker bind-mounts capture directory state at start time. If NFS mounted
# after Docker, MPD sees empty /music. Wait for NFS, then restart.
#
# Scope guard: the race only affects NFS/SMB libraries declared in /etc/fstab
# (mount may finish after Docker starts). Streaming-only installs have no
# mount and an "empty" /music is the intended state — restarting MPD on
# every boot for them is pointless thrash. Local USB libraries also don't
# race (block device is ready well before docker.service).
#
# Format list mirrors scripts/mpd-entrypoint.sh:10 — using a narrower set
# (mp3+flac only) made libraries that are exclusively ogg / m4a / opus /
# wav / aac / wma look empty and triggered spurious MPD restarts at every
# boot for users with non-mp3 libraries.
_music_formats='-name *.mp3 -o -name *.flac -o -name *.m4a -o -name *.ogg -o -name *.wav -o -name *.aac -o -name *.opus -o -name *.wma'
# shellcheck disable=SC2086  # _music_formats is a deliberate find-arg list
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^mpd$'; then
    music_path=$(grep '^MUSIC_PATH=' /opt/snapmulti/.env 2>/dev/null | cut -d= -f2) || true
    if [ -n "$music_path" ] && grep -q "$music_path" /etc/fstab 2>/dev/null; then
        # Wait for network mount (up to 120s)
        wait=0
        while ! findmnt -n "$music_path" >/dev/null 2>&1 && [ "$wait" -lt 120 ]; do
            sleep 5
            wait=$((wait + 5))
        done
        # Only network-mounted libraries are restart-on-empty: streaming-only
        # and local USB never race the docker start sequence.
        if ! docker exec mpd find /music -maxdepth 3 -type f \( $_music_formats \) 2>/dev/null | head -1 | grep -q .; then
            cd /opt/snapmulti && docker compose restart mpd 2>/dev/null || true
            # After restart give MPD ~10s to re-bind the mount, then check again.
            # If /music is STILL empty, surface a loud warning so the user sees
            # something is wrong without having to journalctl-spelunk.
            sleep 10
            if ! docker exec mpd find /music -maxdepth 3 -type f \( $_music_formats \) 2>/dev/null | head -1 | grep -q .; then
                logger -t boot-tune -p warning "music library appears EMPTY after mount + MPD restart (path=$music_path) — check NFS/SMB mount status"
                [[ -w /var/log/snapmulti-install.log ]] && \
                    echo "[$(date -u +%FT%TZ)] WARN: music library empty after boot (path=$music_path)" \
                        >> /var/log/snapmulti-install.log
            fi
        fi
    fi
fi

# ── Containerd Leases plugin self-heal (false-ENOSPC at boot, see CHANGELOG) ──
# Scope to current boot only (-b 0): a 10-minute window picks up errors from
# previous boots on rapid-reboot loops, causing redundant restarts that mask
# a genuine tmpfs-full condition. Plus a hard cap of 3 self-heal attempts ever
# (counter persisted in /var/lib/snapmulti-installer) — if we've burned all 3,
# something is structurally wrong (real ENOSPC, hardware) and we want to fail
# loud rather than thrash containerd.
_CONTAINERD_HEAL_COUNTER="/var/lib/snapmulti-installer/containerd-heal.count"
# Strip non-numeric bytes — a partial / corrupt counter file (e.g. power loss
# during `echo … >`) must not feed garbage into the arithmetic `(( … ))` test
# below, which would abort the whole script under `set -euo pipefail` and
# silently skip the self-heal.
_containerd_heal_count() {
    local raw
    raw=$(cat "$_CONTAINERD_HEAL_COUNTER" 2>/dev/null | tr -dc '0-9')
    [[ -n "$raw" ]] && echo "$raw" || echo 0
}
if systemctl is-active --quiet containerd 2>/dev/null \
   && journalctl -u containerd -b 0 --no-pager 2>/dev/null \
        | grep -q 'io\.containerd\.lease\.v1.*no space left on device'; then
    _heal_count=$(_containerd_heal_count)
    if (( _heal_count >= 3 )); then
        logger -t boot-tune -p err "containerd Leases plugin still failing after $_heal_count self-heal attempts — manual intervention needed"
    else
        logger -t boot-tune -p warning "containerd Leases plugin failed at boot (transient ENOSPC, attempt $((_heal_count + 1))/3) — restarting stack"
        systemctl restart containerd 2>/dev/null || true
        # Poll up to 15s for containerd to be ready (Pi Zero 2W under pressure can take 5-10s)
        for _i in 1 2 3 4 5; do
            systemctl is-active --quiet containerd 2>/dev/null && break
            sleep 3
        done
        # Only restart docker if it was already meant to be running (avoid starting on disabled-docker hosts)
        if systemctl is-active --quiet docker 2>/dev/null \
           || systemctl is-enabled --quiet docker 2>/dev/null; then
            systemctl restart docker 2>/dev/null || true
        fi
        # Bump counter (best-effort; absent state dir means we can't track)
        if [[ -d "$(dirname "$_CONTAINERD_HEAL_COUNTER")" ]] || mkdir -p "$(dirname "$_CONTAINERD_HEAL_COUNTER")" 2>/dev/null; then
            echo $((_heal_count + 1)) > "$_CONTAINERD_HEAL_COUNTER" 2>/dev/null || true
        fi
    fi
fi
