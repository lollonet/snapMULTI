#!/usr/bin/env bash
# scripts/status.sh — One-command health overview for snapMULTI
#
# Auto-detects install type (server, client, or both) and shows:
#   - Container health and memory usage
#   - Stream status (via Snapcast JSON-RPC on port 1705)
#   - Connected clients with volume levels
#
# Usage: bash scripts/status.sh
# Requires: docker, python3, nc (netcat)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common/logging.sh
source "${SCRIPT_DIR}/common/logging.sh"

# ---------------------------------------------------------------------------
# Install detection
# ---------------------------------------------------------------------------
SERVER_DIR=""
CLIENT_DIR=""

for path in /opt/snapmulti "${SCRIPT_DIR}/.."; do
    if [[ -d "$path" && -f "${path}/docker-compose.yml" ]]; then
        SERVER_DIR="$(cd "$path" && pwd)"
        break
    fi
done

for path in /opt/snapclient/common "${SCRIPT_DIR}/../client/common"; do
    if [[ -d "$path" && -f "${path}/docker-compose.yml" ]]; then
        CLIENT_DIR="$(cd "$path" && pwd)"
        break
    fi
done

if [[ -z "$SERVER_DIR" && -z "$CLIENT_DIR" ]]; then
    error "No snapMULTI installation found"
    error "Expected docker-compose.yml in /opt/snapmulti or /opt/snapclient/common"
    exit 1
fi

if ! command -v docker &>/dev/null; then
    error "docker is not installed"
    exit 1
fi

# ---------------------------------------------------------------------------
# Collect memory stats (single docker call for all running containers)
# ---------------------------------------------------------------------------
declare -A MEM_USAGE=()
while IFS=$'\t' read -r cname mem; do
    MEM_USAGE["$cname"]="$mem"
done < <(docker stats --no-stream --format '{{.Name}}\t{{.MemUsage}}' 2>/dev/null \
    | sed 's/MiB/M/g; s/GiB/G/g; s/ //g' || true)

# ---------------------------------------------------------------------------
# Container health (docker inspect is instant — no sampling delay)
# ---------------------------------------------------------------------------
declare -A HEALTH=()
HEALTHY=0
TOTAL=0

SERVER_CONTAINERS=(snapserver mpd shairport-sync librespot mympd metadata tidal-connect)
CLIENT_CONTAINERS=(snapclient audio-visualizer fb-display)

count_health() {
    local cname
    for cname in "$@"; do
        if docker inspect "$cname" &>/dev/null; then
            TOTAL=$((TOTAL + 1))
            local h
            h=$(docker inspect --format \
                '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
                "$cname" 2>/dev/null) || h="unknown"
            HEALTH["$cname"]="$h"
            if [[ "$h" == "healthy" || "$h" == "running" ]]; then
                HEALTHY=$((HEALTHY + 1))
            fi
        fi
    done
}

[[ -n "$SERVER_DIR" ]] && count_health "${SERVER_CONTAINERS[@]}"
[[ -n "$CLIENT_DIR" ]] && count_health "${CLIENT_CONTAINERS[@]}"

show_container() {
    local cname="$1"
    local health="${HEALTH[$cname]:-}"
    [[ -z "$health" ]] && return

    local mem="${MEM_USAGE[$cname]:----}"
    local color
    case "$health" in
        healthy|running) color="$GREEN" ;;
        unhealthy)       color="$RED" ;;
        *)               color="$YELLOW" ;;
    esac

    printf "  %-18s %b%-10s%b %s\n" "$cname" "$color" "$health" "$NC" "$mem"
}

# ---------------------------------------------------------------------------
# Snapcast JSON-RPC query (server only)
# ---------------------------------------------------------------------------
active_stream="n/a"
client_count=0
rpc_response=""

if [[ -n "$SERVER_DIR" ]]; then
    if command -v nc &>/dev/null; then
        rpc_response=$(echo '{"id":1,"jsonrpc":"2.0","method":"Server.GetStatus"}' \
            | nc -w 2 127.0.0.1 1705 2>/dev/null) || true
    fi

    if [[ -n "$rpc_response" ]] && command -v python3 &>/dev/null; then
        active_stream=$(printf '%s' "$rpc_response" | python3 -c "
import json, sys
data = json.load(sys.stdin)
streams = data.get('result',{}).get('server',{}).get('streams',[])
playing = [s['id'] for s in streams if s['status'] == 'playing']
print(f'{playing[0]} (playing)' if playing else 'idle')
" 2>/dev/null) || active_stream="error"

        client_count=$(printf '%s' "$rpc_response" | python3 -c "
import json, sys
data = json.load(sys.stdin)
groups = data.get('result',{}).get('server',{}).get('groups',[])
print(sum(1 for g in groups for c in g.get('clients',[]) if c.get('connected')))
" 2>/dev/null) || client_count=0
    fi
fi

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
section() { printf "\n%b%b==> %s%b\n" "$CYAN" "$BOLD" "$*" "$NC"; }

# ---------------------------------------------------------------------------
# Summary header
# ---------------------------------------------------------------------------
echo ""
echo "snapMULTI Status"
echo "==================================="
printf "  Containers:  %s/%s healthy\n" "$HEALTHY" "$TOTAL"
if [[ -n "$SERVER_DIR" ]]; then
    printf "  Stream:      %s\n" "$active_stream"
    printf "  Clients:     %s connected\n" "$client_count"
fi
echo "==================================="

# ---------------------------------------------------------------------------
# Server containers
# ---------------------------------------------------------------------------
if [[ -n "$SERVER_DIR" ]]; then
    section "SERVER CONTAINERS"
    for cname in "${SERVER_CONTAINERS[@]}"; do
        show_container "$cname"
    done
fi

# ---------------------------------------------------------------------------
# Client containers
# ---------------------------------------------------------------------------
if [[ -n "$CLIENT_DIR" ]]; then
    section "CLIENT CONTAINERS"
    for cname in "${CLIENT_CONTAINERS[@]}"; do
        show_container "$cname"
    done
fi

# ---------------------------------------------------------------------------
# Streams (server only, requires python3)
# ---------------------------------------------------------------------------
if [[ -n "$SERVER_DIR" && -n "$rpc_response" ]] && command -v python3 &>/dev/null; then
    section "STREAMS"
    printf '%s' "$rpc_response" | python3 -c "
import json, sys
use_color = sys.stdout.isatty()
green  = '\033[0;32m' if use_color else ''
yellow = '\033[1;33m' if use_color else ''
nc     = '\033[0m'    if use_color else ''
data = json.load(sys.stdin)
for s in data.get('result',{}).get('server',{}).get('streams',[]):
    status = s['status']
    color = green if status == 'playing' else yellow
    print(f'  {s[\"id\"]:<18s} {color}{status}{nc}')
" 2>/dev/null || warn "Could not parse stream data"
fi

# ---------------------------------------------------------------------------
# Connected clients (server only, requires python3)
# ---------------------------------------------------------------------------
if [[ -n "$SERVER_DIR" && -n "$rpc_response" ]] && command -v python3 &>/dev/null; then
    section "CLIENTS"
    printf '%s' "$rpc_response" | python3 -c "
import json, sys
use_color = sys.stdout.isatty()
yellow = '\033[1;33m' if use_color else ''
nc     = '\033[0m'    if use_color else ''
data = json.load(sys.stdin)
groups = data.get('result',{}).get('server',{}).get('groups',[])
found = False
for g in groups:
    sid = g.get('stream_id','')
    for c in g.get('clients',[]):
        if not c.get('connected'):
            continue
        found = True
        cfg = c.get('config',{})
        name = cfg.get('name','unknown')
        vol = cfg.get('volume',{})
        pct = vol.get('percent',0)
        muted_str = f'  {yellow}(muted){nc}' if vol.get('muted') else ''
        print(f'  {name:<18s} {sid:<8s} vol:{pct}%{muted_str}')
if not found:
    print('  (none)')
" 2>/dev/null || warn "Could not parse client data"
fi

echo ""
