#!/usr/bin/env bash
# Discover an IPv4 _snapcast._tcp advertiser via avahi-browse and pin
# `--host <ip>` into /etc/default/snapclient. Wired as ExecStartPre on
# snapclient.service via the snapMULTI drop-in installed by
# setup-zero2w.sh.
#
# Native client only (Pi Zero 2W). The Docker client path uses
# scripts/discover-server.sh which feeds the result to docker compose
# via .env — that file is pruned on the native install (see comment at
# top of discover-server.sh) because it depends on docker compose, but
# the underlying problem it solves applies here too: snapclient's
# built-in libavahi-client browse can latch onto an IPv6 link-local SRV
# target that does not route, leaving audio silent even with a healthy
# server on the same LAN. Pinning an explicit IPv4 host removes the
# guesswork.
#
# Idempotent: only rewrites /etc/default/snapclient when the resolved
# host differs from what the file already carries. Safe to run on every
# snapclient.service start.
#
# Best-effort: when avahi-browse is missing or returns no IPv4 target,
# leave SNAPCLIENT_OPTS untouched. snapclient's own mDNS retry is the
# graceful fallback — better silent than wedged on a stale --host.
set -euo pipefail

DEFAULTS="${SNAPCLIENT_DEFAULTS:-/etc/default/snapclient}"
SCAN_TIMEOUT="${SCAN_TIMEOUT:-8}"
SERVICE_TYPE="${SNAPCAST_SERVICE_TYPE:-_snapcast._tcp}"
TAG="[discover-native]"

_log() { echo "$TAG $*" >&2; }

[[ -f "$DEFAULTS" ]] || { _log "$DEFAULTS missing — nothing to do"; exit 0; }

if ! command -v avahi-browse >/dev/null 2>&1; then
    _log "avahi-browse missing — leaving SNAPCLIENT_OPTS unchanged"
    exit 0
fi

# avahi-browse -rpt format (semicolon-separated):
#   =;iface;proto;name;type;domain;hostname;address;port;txt   ← fully resolved
# Require resolved record (`=`), IPv4 protocol, numeric port (rejects PTR-only).
ip=$(timeout "$SCAN_TIMEOUT" avahi-browse -rpt "$SERVICE_TYPE" 2>/dev/null \
    | awk -F';' '/^=/ && $3=="IPv4" && $9 ~ /^[0-9]+$/ {print $8; exit}' || true)

if [[ -z "$ip" || ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    _log "no IPv4 ${SERVICE_TYPE} advertiser — falling back to snapclient built-in mDNS"
    exit 0
fi

current=$(grep -oE -- '--host[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$DEFAULTS" 2>/dev/null \
    | awk '{print $NF}' | head -1 || true)
if [[ "$current" == "$ip" ]]; then
    _log "snapserver $ip already pinned, no change"
    exit 0
fi

# Strip any prior --host arg (idempotent on multiple runs / IP changes),
# then prepend the freshly resolved one. SNAPCLIENT_OPTS must be a single
# line for this rewrite to work — setup-zero2w.sh writes it that way.
tmp=$(mktemp "${DEFAULTS}.XXXXXX")
sed -E \
    -e 's|--host[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+[[:space:]]*||g' \
    -e "s|^(SNAPCLIENT_OPTS=\")|\\1--host ${ip} |" \
    "$DEFAULTS" > "$tmp"
mv "$tmp" "$DEFAULTS"
chmod 644 "$DEFAULTS"
_log "pinned snapserver ${ip}${current:+ (was: $current)}"
