#!/usr/bin/env bash
# Wrapper invoked by snapmulti-auto-boot-smoke.service: runs device-smoke.sh --tone for the host's install role.

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

# Wait up to 90 s for Snapcast healthy — avoid false-positive FAIL during slow container startup.
if [[ "$INSTALL_TYPE" == "server" || "$INSTALL_TYPE" == "both" ]]; then
    for _ in $(seq 1 45); do
        curl -s --max-time 2 -d '{"id":1,"jsonrpc":"2.0","method":"Server.GetStatus"}' \
            http://localhost:1780/jsonrpc 2>/dev/null | grep -q '"streams"' && break
        sleep 2
    done
fi

sleep 3   # container-metric settle window

exec "$SMOKE" "$MODE" --tone >/dev/null 2>&1
