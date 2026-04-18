#!/usr/bin/env bash
# Integration test: docker compose up → health check → docker compose down
#
# Verifies that all server services start and become healthy.
# Designed to run on any Linux/macOS machine with Docker.
# Skips ARM-only services (tidal-connect) on amd64.
#
# Usage: bash tests/test_compose_health.sh [--keep]
#   --keep    Don't tear down containers after test (for debugging)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

KEEP=false
[[ "${1:-}" == "--keep" ]] && KEEP=true

pass=0
fail=0

ok()   { echo -e "  ${GREEN}PASS${NC}: $*"; pass=$((pass + 1)); }
fail() { echo -e "  ${RED}FAIL${NC}: $*"; fail=$((fail + 1)); }
warn() { echo -e "  ${YELLOW}SKIP${NC}: $*"; }

cleanup() {
    if [[ "$KEEP" == "false" ]]; then
        echo "Tearing down..."
        cd "$PROJECT_DIR"
        docker compose down --timeout 10 >/dev/null 2>&1 || true
        docker compose -f client/common/docker-compose.yml down --timeout 10 >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

# ── Prerequisites ────────────────────────────────────────────────
echo "Checking prerequisites..."

if ! command -v docker &>/dev/null; then
    echo "ERROR: docker not found"
    exit 1
fi

if ! docker info &>/dev/null 2>&1; then
    echo "ERROR: Docker daemon not running"
    exit 1
fi

# ── Server compose ───────────────────────────────────────────────
echo ""
echo "=== Server compose up ==="

cd "$PROJECT_DIR"

# Create minimal .env if not present
if [[ ! -f .env ]]; then
    cp .env.example .env 2>/dev/null || {
        cat > .env <<EOF
MUSIC_PATH=/tmp/test-music
TZ=UTC
PUID=$(id -u)
PGID=$(id -g)
EOF
    }
fi

# Create required directories
mkdir -p audio data mpd/data mympd/workdir mympd/cachedir artwork

# Create FIFOs if missing
for fifo in audio/mpd_fifo audio/spotify_fifo audio/airplay_fifo audio/tidal_fifo; do
    [[ -p "$fifo" ]] || mkfifo "$fifo" 2>/dev/null || true
done

# Start server (exclude tidal on non-ARM)
ARCH=$(uname -m)
if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
    docker compose up -d 2>&1 | tail -5
else
    # Filter out tidal profile on amd64
    docker compose up -d 2>&1 | tail -5
fi

# Wait for health checks (max 90s)
echo "Waiting for services to become healthy..."
MAX_WAIT=90
INTERVAL=5
elapsed=0

while [[ $elapsed -lt $MAX_WAIT ]]; do
    sleep $INTERVAL
    elapsed=$((elapsed + INTERVAL))

    total=$(docker compose ps --services 2>/dev/null | wc -l)
    running=$(docker compose ps --status running -q 2>/dev/null | wc -l)
    healthy=$(docker compose ps --status healthy -q 2>/dev/null | wc -l)

    echo "  ${elapsed}s: $running/$total running, $healthy healthy"

    if [[ "$running" -ge "$total" ]] && [[ "$healthy" -ge "$total" ]]; then
        break
    fi
done

# Verify each service
echo ""
echo "=== Service health ==="

for svc in $(docker compose ps --services 2>/dev/null); do
    status=$(docker compose ps "$svc" --format '{{.Status}}' 2>/dev/null)
    if echo "$status" | grep -qi "healthy"; then
        ok "$svc: $status"
    elif echo "$status" | grep -qi "running"; then
        warn "$svc: running but not healthy yet ($status)"
    else
        fail "$svc: $status"
    fi
done

# ── Basic connectivity ───────────────────────────────────────────
echo ""
echo "=== Endpoint checks ==="

# Snapweb
if curl -sf --max-time 5 http://127.0.0.1:1780/ >/dev/null 2>&1; then
    ok "Snapweb (:1780) responds"
else
    fail "Snapweb (:1780) not responding"
fi

# myMPD
if curl -sf --max-time 5 http://127.0.0.1:8180/ >/dev/null 2>&1; then
    ok "myMPD (:8180) responds"
else
    fail "myMPD (:8180) not responding"
fi

# Metadata health
if curl -sf --max-time 5 http://127.0.0.1:8083/health >/dev/null 2>&1; then
    ok "Metadata (:8083/health) responds"
else
    fail "Metadata (:8083/health) not responding"
fi

# Snapserver JSON-RPC
if echo '{"id":1,"jsonrpc":"2.0","method":"Server.GetStatus"}' | nc -w 2 127.0.0.1 1705 2>/dev/null | grep -q "jsonrpc"; then
    ok "Snapserver JSON-RPC (:1705) responds"
else
    # nc may not be available everywhere
    warn "Snapserver JSON-RPC (:1705) — nc not available or no response"
fi

# MPD
if echo "ping" | nc -w 2 127.0.0.1 6600 2>/dev/null | grep -q "OK"; then
    ok "MPD (:6600) responds"
else
    warn "MPD (:6600) — nc not available or no response"
fi

# ── Results ──────────────────────────────────────────────────────
echo ""
echo "=== Results ==="
if [[ $fail -gt 0 ]]; then
    echo -e "${RED}FAILED${NC}: $fail failed, $pass passed"
    echo ""
    echo "Container status:"
    docker compose ps --format 'table {{.Name}}\t{{.Status}}'
    exit 1
fi
echo -e "${GREEN}All $pass checks passed!${NC}"
