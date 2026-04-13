#!/usr/bin/env bash
# pull-images.sh — Docker image pull with retry and parallel execution
# Sourced by: setup.sh (client), deploy.sh (server)
# Exports: pull_compose_images()
#
# Usage:
#   pull_compose_images <log_fn> <min_disk_mb> [pull_fail_callback]
#
#   log_fn          — function name for progress messages (e.g. log_progress, info)
#   min_disk_mb     — minimum free disk in MB before pull (1024 for client, 2048 for server)
#   pull_fail_callback — optional function called with service name on pull failure
#                        return 0 to mark as handled, non-zero to add to failed list

# Source logger if not already available
if ! declare -F log_info &>/dev/null; then
    # shellcheck source=unified-log.sh
    source "$(dirname "${BASH_SOURCE[0]}")/unified-log.sh" 2>/dev/null || {
        log_info()  { echo "[INFO] $*"; }
        log_warn()  { echo "[WARN] $*" >&2; }
        log_error() { echo "[ERROR] $*" >&2; }
    }
fi

# Pull a single service with 3-attempt retry.
# Output suppressed on success, last 5 lines surfaced on failure.
# Requires: _pi_tmp (temp directory set by pull_compose_images)
_pull_one() {
    local svc="$1"
    local log_fn="$2"
    local log="$_pi_tmp/pull-$svc"
    local delays=(0 10 30)
    for i in 0 1 2; do
        [[ ${delays[$i]} -gt 0 ]] && { "$log_fn" "Retrying $svc in ${delays[$i]}s..."; sleep "${delays[$i]}"; }
        if docker compose pull "$svc" >"$log" 2>&1; then
            rm -f "$log"
            return 0
        fi
    done
    tail -5 "$log"
    rm -f "$log"
    return 1
}

# Pull all compose services with parallel execution (2 at a time).
# Args: log_fn min_disk_mb [pull_fail_callback]
pull_compose_images() {
    local log_fn="${1:-echo}"
    local min_disk_mb="${2:-1024}"
    local fail_callback="${3:-}"

    # Pre-flight: disk space check
    local avail_mb
    avail_mb=$(df -BM --output=avail "." 2>/dev/null | tail -1 | tr -d ' M')
    if [[ -n "$avail_mb" ]] && [[ "$avail_mb" -lt "$min_disk_mb" ]]; then
        log_error "Only ${avail_mb}MB free — need at least ${min_disk_mb} MB for container images"
        return 1
    fi

    # Discover services from compose config
    local services
    mapfile -t services < <(docker compose config --services 2>/dev/null)
    if [[ ${#services[@]} -eq 0 ]]; then
        log_error "No services found in docker-compose.yml"
        return 1
    fi

    local total=${#services[@]}
    local count=0

    # Temp directory for pull output (cleaned up on function return).
    # RETURN only — EXIT would clobber the caller's global EXIT trap.
    _pi_tmp=$(mktemp -d)
    trap 'rm -rf "$_pi_tmp"' RETURN

    local pull_failed=()

    # Pull in pairs: background + foreground
    for ((i=0; i<${#services[@]}; i+=2)); do
        local svc1="${services[$i]}"
        local svc2="${services[$i+1]:-}"

        count=$((count + 1))
        "$log_fn" "Pulling $svc1 ($count/$total)..."

        # Start svc2 in background
        local bg_pid="" bg_log=""
        if [[ -n "$svc2" ]]; then
            count=$((count + 1))
            "$log_fn" "Pulling $svc2 ($count/$total)..."
            bg_log="$_pi_tmp/bg-$svc2"
            _pull_one "$svc2" "$log_fn" >"$bg_log" 2>&1 &
            bg_pid=$!
        fi

        # svc1 in foreground
        if ! _pull_one "$svc1" "$log_fn"; then
            if [[ -n "$fail_callback" ]] && "$fail_callback" "$svc1"; then
                :  # callback handled it
            else
                pull_failed+=("$svc1")
            fi
        fi

        # Wait for background svc2
        if [[ -n "$bg_pid" ]]; then
            if ! wait "$bg_pid" 2>/dev/null; then
                cat "$bg_log" 2>/dev/null
                if [[ -n "$fail_callback" ]] && "$fail_callback" "$svc2"; then
                    :  # callback handled it
                else
                    pull_failed+=("$svc2")
                fi
            fi
            rm -f "$bg_log"
        fi
    done

    # Prune dangling images
    docker image prune -f >/dev/null 2>&1 || true

    if [[ ${#pull_failed[@]} -gt 0 ]]; then
        log_error "Failed to pull after 3 attempts: ${pull_failed[*]}"
        return 1
    fi

    "$log_fn" "All $total images pulled successfully"
    return 0
}
