#!/usr/bin/env bash
# Wrapper invoked by snapmulti-auto-boot-smoke.service: runs device-smoke.sh --tone for the host's install role.

# No -e: every branch exits 0 explicitly. Failure to fire the tone must NEVER fail boot.
set -uo pipefail

CONF=/opt/snapmulti/install.conf
[[ -f "$CONF" ]] || CONF=/opt/snapclient/install.conf
[[ -f "$CONF" ]] || CONF=/boot/firmware/install.conf
[[ -f "$CONF" ]] || exit 0

INSTALL_TYPE=$(grep -m1 '^INSTALL_TYPE=' "$CONF" 2>/dev/null | cut -d= -f2- | tr -d '\r[:space:]')

case "$INSTALL_TYPE" in
    server)              MODE=--server; SMOKE=/opt/snapmulti/scripts/device-smoke.sh ;;
    client|client-native) MODE=--client; SMOKE=/opt/snapclient/scripts/device-smoke.sh ;;
    both)                MODE=--both;   SMOKE=/opt/snapmulti/scripts/device-smoke.sh ;;
    *) exit 0 ;;
esac

[[ -x "$SMOKE" ]] || exit 0

# Mode-aware wait cap.
# - client / client-native: snapclient is ready in seconds (no MPD,
#   no library), so 90 s is plenty and we don't want to delay the
#   audible "device ready" cue.
# - server / both: MPD scans the library on first boot. Local or small
#   NFS libraries (≤ ~10 k tracks) finish within ~3-4 min — extending
#   the cap to 240 s lets the tone land PASS (ascending chime) on
#   those installs instead of always firing FAIL during MPD warmup.
#   Very large libraries (50 k+ tracks NFS) still exceed 240 s —
#   covered by the TROUBLESHOOTING entry on benign first-scan fail
#   tone + the backup-from-sd.sh mpd.db pre-warm workflow.
case "$INSTALL_TYPE" in
    server|both) WAIT_CAP_SEC=240 ;;
    *)           WAIT_CAP_SEC=90  ;;
esac
WAIT_ITERATIONS=$(( WAIT_CAP_SEC / 5 ))

# Wait up to WAIT_CAP_SEC for systemd to leave 'starting' (avoids false-positive `systemd state unexpected: 'starting'` smoke FAIL).
for _ in $(seq 1 "$WAIT_ITERATIONS"); do
    state=$(systemctl is-system-running 2>/dev/null || true)
    [[ "$state" == "starting" ]] || break
    sleep 5
done

# Wait up to WAIT_CAP_SEC for the audio CORE — snapserver (server/both) and snapclient (client/both). MPD/metadata/etc. are best-effort: if they're slow (NFS scan), the tone still fires and signals the audio path is up.
# Format: "<compose-dir>:<service>" — both-mode keeps snapserver in /opt/snapmulti and snapclient in /opt/snapclient (separate compose projects per CLAUDE.md).
case "$INSTALL_TYPE" in
    client|client-native) CORE_CHECKS="/opt/snapclient:snapclient" ;;
    both)                 CORE_CHECKS="/opt/snapmulti:snapserver /opt/snapclient:snapclient" ;;
    *)                    CORE_CHECKS="/opt/snapmulti:snapserver" ;;
esac
for _ in $(seq 1 "$WAIT_ITERATIONS"); do
    all_healthy=1
    for check in $CORE_CHECKS; do
        compose_dir="${check%%:*}"
        svc="${check##*:}"
        [[ -f "$compose_dir/docker-compose.yml" ]] || continue
        state=$(cd "$compose_dir" && docker compose ps -q "$svc" 2>/dev/null \
            | xargs -r docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' 2>/dev/null \
            | head -1)
        [[ "$state" == "healthy" ]] || { all_healthy=0; break; }
    done
    [[ "$all_healthy" -eq 1 ]] && break
    sleep 5
done

sleep 10  # let snapmulti-status.timer fire its first snapshot

# Always exit 0 — the tone IS the signal. Failing the unit on a smoke WARN would degrade systemd state (sys is-system-running=degraded) and trigger a self-referential FAIL cascade on the next smoke run.
# SNAPMULTI_FORCE_TONE=1: auto-boot must always play (user explicitly chose option B over "don't interrupt music") so post-reboot status is audible even when MPD autoplay resumed during boot.
# SNAPMULTI_AUTO_BOOT=1: signals check_boot_health.sh to tolerate
# 'starting' as info instead of FAIL (self-referential paradox — system
# state is starting *because* this very service is pending).
SNAPMULTI_AUTO_BOOT=1 SNAPMULTI_FORCE_TONE=1 "$SMOKE" "$MODE" --tone >/dev/null || true
exit 0
