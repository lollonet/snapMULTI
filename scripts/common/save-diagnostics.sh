#!/usr/bin/env bash
# Save diagnostic logs to boot partition (FAT32) so they survive
# overlayroot reboots. Runs periodically via systemd timer.
#
# Captures: dmesg (I2S/ALSA errors), docker container status,
# snapclient logs, and system state. Keeps last 3 snapshots
# to avoid filling the boot partition.
set -euo pipefail

# Detect boot partition
if [[ -d /boot/firmware ]]; then
    BOOT="/boot/firmware"
else
    BOOT="/boot"
fi

DIAG_DIR="$BOOT/diagnostics"
# 12 × 15 min = 3 h of context. Snapshots ~50 KB each → ~600 KB worst
# case on a multi-GB FAT32 boot partition. Trade-off against FAT32 wear
# is negligible compared to the debug value of having recent history
# when a user opens a bug report.
MAX_SNAPSHOTS=12
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
SNAPSHOT="$DIAG_DIR/$TIMESTAMP"

# Serialise /boot/firmware mount/write with sibling backup scripts (see
# backup-mpd.sh for the race scenario).
exec 9>/run/snapmulti-boot-write.lock
if ! flock -w 60 9; then
    logger -t save-diagnostics "skipped: could not acquire /run/snapmulti-boot-write.lock within 60s"
    exit 0
fi

# See backup-mpd.sh for the remount validation rationale.
remount_rw() {
    mount -o remount,rw "$BOOT" 2>&1 || true
}

remount_ro() {
    mount -o remount,ro "$BOOT" 2>/dev/null || true
}

mount_err=$(remount_rw)
trap 'remount_ro' EXIT

# Exit 0 — best-effort; next 15-min timer tick will retry.
if findmnt -n -o OPTIONS "$BOOT" 2>/dev/null | tr ',' '\n' | grep -qx ro; then
    logger -t save-diagnostics \
        "skipped: $BOOT failed to remount rw (mount err: ${mount_err:-none})"
    exit 0
fi

mkdir -p "$DIAG_DIR"

# Rotate: keep only the last MAX_SNAPSHOTS.
# Use `find` instead of `ls glob`: when DIAG_DIR is empty (first run), the
# unmatched glob makes ls exit 2, pipefail propagates it, set -e kills the
# script — and systemd reports the unit failed despite the rotation being
# a no-op anyway. find returns 0 on empty results.
existing=$(find "$DIAG_DIR" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' 2>/dev/null \
    | sort | head -n -"$MAX_SNAPSHOTS" || true)
if [[ -n "$existing" ]]; then
    echo "$existing" | while IFS= read -r old; do
        rm -rf "$old"
    done
fi

mkdir -p "$SNAPSHOT"

# 1. Kernel audio/I2S errors
dmesg 2>/dev/null | grep -iE 'i2s|alsa|snd|hifiberry|underrun|xrun|pcm|wm8804|error' \
    > "$SNAPSHOT/dmesg-audio.log" 2>/dev/null || true

# 2. Docker container status
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.RunningFor}}' \
    > "$SNAPSHOT/docker-ps.log" 2>/dev/null || true

# 3. Snapclient logs (last 100 lines)
docker logs snapclient --tail 100 \
    > "$SNAPSHOT/snapclient.log" 2>&1 || true

# 4. fb-display logs (last 50 lines)
docker logs fb-display --tail 50 \
    > "$SNAPSHOT/fb-display.log" 2>&1 || true

# 5. Audio visualizer logs (last 50 lines)
docker logs audio-visualizer --tail 50 \
    > "$SNAPSHOT/audio-visualizer.log" 2>&1 || true

# 6. Server containers (if running — "both" mode)
docker logs snapserver --tail 50 \
    > "$SNAPSHOT/snapserver.log" 2>&1 || true

# 7. ALSA state
if command -v aplay &>/dev/null; then
    aplay -l > "$SNAPSHOT/alsa-devices.log" 2>&1 || true
fi
cat /proc/asound/cards > "$SNAPSHOT/asound-cards.log" 2>/dev/null || true

# 8. Audio FIFO health
{
    echo "=== FIFO status ==="
    # FIFOs are in the audio volume — find host path from common locations
    audio_dir=""
    for _d in /opt/snapmulti/audio /opt/snapclient/audio; do
        [[ -d "$_d" ]] && audio_dir="$_d" && break
    done
    for fifo in "${audio_dir:-.}"/*_fifo; do
        [[ -e "$fifo" ]] || continue
        name=$(basename "$fifo")
        if [[ -p "$fifo" ]]; then
            readers=$(fuser "$fifo" 2>/dev/null | wc -w) || readers=0
            echo "$name: pipe exists, $readers process(es) attached"
        else
            echo "$name: NOT A PIPE (type: $(stat -c %F "$fifo" 2>/dev/null || echo unknown))"
        fi
    done
    echo "=== container restarts ==="
    docker ps --format '{{.Names}}|{{.Status}}' 2>/dev/null | while IFS='|' read -r name status; do
        restarts=$(docker inspect --format '{{.RestartCount}}' "$name" 2>/dev/null) || restarts=0
        [[ "$restarts" -gt 0 ]] && echo "WARNING: $name restarted $restarts times ($status)"
    done
} > "$SNAPSHOT/audio-health.log" 2>/dev/null || true

# 9. System state
{
    echo "=== uptime ==="
    uptime
    echo "=== memory ==="
    free -h
    echo "=== disk ==="
    df -h / /boot/firmware 2>/dev/null || df -h / /boot
    echo "=== temperature ==="
    cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null \
        | awk '{printf "%.1f°C\n", $1/1000}' || echo "N/A"
    echo "=== overlayroot ==="
    if mount | grep -q 'overlayroot'; then
        echo "active"
    else
        echo "inactive"
    fi
} > "$SNAPSHOT/system.log" 2>/dev/null || true

# 10. Network state (brief)
{
    echo "=== interfaces ==="
    ip -brief addr 2>/dev/null
    echo "=== route ==="
    ip route show default 2>/dev/null
    echo "=== NetworkManager connections ==="
    nmcli -t -f NAME,DEVICE,STATE connection show 2>/dev/null
} > "$SNAPSHOT/network.log" 2>/dev/null || true

# 11. Smoke output snapshot — single-source view of system health.
# Run the smoke without --tone (silent) and capture; cap at 200 lines so
# a stuck check can't bloat the snapshot.
SMOKE=""
for _s in /opt/snapmulti/scripts/device-smoke.sh /opt/snapclient/scripts/device-smoke.sh; do
    [[ -x "$_s" ]] && { SMOKE="$_s"; break; }
done
if [[ -n "$SMOKE" ]]; then
    # Detect mode from install.conf — same precedence the smoke uses.
    _mode=""
    for _c in /boot/firmware/snapmulti/install.conf /boot/snapmulti/install.conf; do
        if [[ -f "$_c" ]]; then
            _it=$(grep -m1 '^INSTALL_TYPE=' "$_c" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
            case "$_it" in
                server) _mode=--server ;;
                client|client-native) _mode=--client ;;
                both) _mode=--both ;;
            esac
            break
        fi
    done
    [[ -z "$_mode" ]] && _mode=--both
    SNAPMULTI_AUTO_BOOT=1 "$SMOKE" "$_mode" 2>&1 | head -200 \
        > "$SNAPSHOT/smoke.log" 2>/dev/null || true
fi

# 12. Failed systemd units (any unit, not just snapMULTI).
systemctl --failed --no-pager 2>/dev/null > "$SNAPSHOT/systemd-failed.log" || true

# 13. Recent errors from current boot (journal severity err+).
# Cap at 100 lines so a flapping unit can't bloat the snapshot.
journalctl -b 0 -p err --no-pager 2>/dev/null | tail -100 \
    > "$SNAPSHOT/journal-errors.log" || true

# 14. Release identity + redacted .env (mask SMB_PASS and any *_PASS / *_TOKEN).
for _env in /opt/snapmulti/.env /opt/snapclient/.env; do
    [[ -f "$_env" ]] || continue
    _name=$(basename "$(dirname "$_env")")-env.log
    sed -E 's/^(.*_(PASS|TOKEN|SECRET|KEY))=.*/\1=***REDACTED***/' "$_env" \
        > "$SNAPSHOT/$_name" 2>/dev/null || true
done

# remount_ro handled by EXIT trap

echo "Diagnostics saved to $SNAPSHOT"
