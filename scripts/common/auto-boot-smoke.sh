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

# Wait up to 5 min for systemd to exit 'starting' state — otherwise check_boot_health reports a false-positive `systemd state unexpected: 'starting'` FAIL.
for _ in $(seq 1 60); do
    state=$(systemctl is-system-running 2>/dev/null || true)
    [[ "$state" == "starting" ]] || break
    sleep 5
done

# Wait up to 5 min for all HEALTH-CHECKED containers healthy. Server project picked for server/both (MPD has the longest start_period); client project for client-only.
if [[ "$INSTALL_TYPE" == "client" || "$INSTALL_TYPE" == "client-native" ]]; then
    COMPOSE_DIR=/opt/snapclient
else
    COMPOSE_DIR=/opt/snapmulti
fi
if [[ -f "$COMPOSE_DIR/docker-compose.yml" ]]; then
    for _ in $(seq 1 60); do
        # Only containers WITH a healthcheck count — services without one print empty string and would block the gate forever.
        health_states=$(cd "$COMPOSE_DIR" && docker compose ps -q 2>/dev/null \
            | xargs -r docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' 2>/dev/null \
            | grep -E '^(healthy|starting|unhealthy)$' || true)
        total=$(printf '%s\n' "$health_states" | grep -c . || true)
        healthy=$(printf '%s\n' "$health_states" | grep -c '^healthy$' || true)
        [[ "$total" -gt 0 && "$healthy" -ge "$total" ]] && break
        sleep 5
    done
fi

sleep 10  # let snapmulti-status.timer fire its first snapshot

# Always exit 0 — the tone IS the signal. Failing the unit on a smoke WARN would degrade systemd state (sys is-system-running=degraded) and trigger a self-referential FAIL cascade on the next smoke run.
# SNAPMULTI_FORCE_TONE=1: auto-boot must always play (user explicitly chose option B over "don't interrupt music") so post-reboot status is audible even when MPD autoplay resumed during boot.
SNAPMULTI_FORCE_TONE=1 "$SMOKE" "$MODE" --tone >/dev/null || true
exit 0
