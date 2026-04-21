#!/usr/bin/env bash
# Monitor snapserver IP and restart snapclient if the server moves.
# Boot mode:  runs as ExecStartPre (no args) — sets localhost for "both" mode.
# Watch mode: runs periodically (--watch) — restarts client if server IP changed.
#
# Discovers the snapserver via mDNS and writes its IPv4 to SNAPSERVER_HOST in .env.
# "Both" mode: SNAPSERVER_HOST=127.0.0.1 (local server always wins).
# If mDNS fails, the existing IP in .env is kept (avoids losing a valid server).
set -euo pipefail

ENV_FILE="/opt/snapclient/.env"
LAST_IP_FILE="/run/snapclient-server-ip"
WATCH_MODE=false
[[ "${1:-}" == "--watch" ]] && WATCH_MODE=true

# "Both" mode: local snapserver always wins.
# Detect via install.conf or server directory (robust — doesn't depend on container state).
_is_both_mode() {
    # Check install.conf (set by prepare-sd.sh)
    local conf
    for conf in /boot/firmware/snapmulti/install.conf /boot/snapmulti/install.conf; do
        if grep -q '^INSTALL_TYPE=both' "$conf" 2>/dev/null; then return 0; fi
    done
    # Fallback: server compose file exists alongside client
    [[ -f /opt/snapmulti/docker-compose.yml ]] && return 0
    return 1
}

if _is_both_mode; then
    current=$(grep "^SNAPSERVER_HOST=" "$ENV_FILE" 2>/dev/null | cut -d= -f2) || true
    if [[ "$current" != "127.0.0.1" ]]; then
        echo "snapclient-discover: local snapserver detected, switching to 127.0.0.1"
        if $WATCH_MODE; then
            if cd /opt/snapclient && docker compose restart 2>/dev/null; then
                sed -i "s|^SNAPSERVER_HOST=.*|SNAPSERVER_HOST=127.0.0.1|" "$ENV_FILE" 2>/dev/null \
                    || echo "SNAPSERVER_HOST=127.0.0.1" >> "$ENV_FILE"
            else
                echo "snapclient-discover: restart failed, will retry next cycle"
                exit 0
            fi
        else
            sed -i "s|^SNAPSERVER_HOST=.*|SNAPSERVER_HOST=127.0.0.1|" "$ENV_FILE" 2>/dev/null \
                || echo "SNAPSERVER_HOST=127.0.0.1" >> "$ENV_FILE"
        fi
    else
        echo "snapclient-discover: local snapserver, using 127.0.0.1"
    fi
    exit 0
fi

# Discover server via mDNS (IPv4 only) and write to .env.
# snapclient's built-in Avahi can pick IPv6 link-local addresses
# which don't work inside Docker containers (scope ID mismatch).
# We run discovery on the host and pass the IPv4 result to the container.
_discover_ipv4() {
    if command -v avahi-browse &>/dev/null; then
        timeout 10 avahi-browse -rpt _snapcast._tcp 2>/dev/null \
            | awk -F';' '/^=/ && $3=="IPv4" {print $8; exit}'
    fi
}

_update_server() {
    local new_ip="$1"
    local current
    current=$(grep "^SNAPSERVER_HOST=" "$ENV_FILE" 2>/dev/null | cut -d= -f2) || true
    if [[ "$new_ip" != "$current" ]]; then
        sed -i "s|^SNAPSERVER_HOST=.*|SNAPSERVER_HOST=$new_ip|" "$ENV_FILE" 2>/dev/null || true
        echo "snapclient-discover: server at $new_ip (was: ${current:-empty})"
        echo "$new_ip" > "$LAST_IP_FILE"
        return 0  # changed
    fi
    return 1  # unchanged
}

host=$(_discover_ipv4) || true
if [[ -n "$host" ]] && [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    if _update_server "$host" && $WATCH_MODE; then
        echo "snapclient-discover: restarting services for new server"
        cd /opt/snapclient && docker compose restart 2>/dev/null || true
    fi
else
    echo "snapclient-discover: no snapserver found via mDNS"
fi
