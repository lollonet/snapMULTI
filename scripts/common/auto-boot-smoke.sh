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

# Wait up to 5 min for ALL containers healthy, not just Snapcast — otherwise smoke fires while mpd/librespot are still in their start_period and emits a false FAIL.
COMPOSE_DIR=/opt/snapmulti
[[ -f /opt/snapclient/docker-compose.yml ]] && COMPOSE_DIR=/opt/snapclient
if [[ -f "$COMPOSE_DIR/docker-compose.yml" ]]; then
    for _ in $(seq 1 60); do
        total=$(cd "$COMPOSE_DIR" && docker compose ps -q 2>/dev/null | wc -l)
        healthy=$(cd "$COMPOSE_DIR" && docker compose ps -q 2>/dev/null \
            | xargs -r docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' 2>/dev/null \
            | grep -c '^healthy$' || true)
        [[ "$total" -gt 0 && "$healthy" -ge "$total" ]] && break
        sleep 5
    done
fi

sleep 10  # let snapmulti-status.timer fire its first snapshot

# Always exit 0 — the tone IS the signal. Failing the unit on a smoke WARN would degrade systemd state (sys is-system-running=degraded) and trigger a self-referential FAIL cascade on the next smoke run.
"$SMOKE" "$MODE" --tone >/dev/null || true
exit 0
