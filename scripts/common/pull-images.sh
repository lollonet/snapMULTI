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
    # Check if deploy.sh-style logging.sh functions are already defined
    if declare -F info &>/dev/null && declare -F warn &>/dev/null; then
        # deploy.sh context: create log_* wrappers to preserve stderr output
        log_info()  { info "$@"; }
        log_warn()  { warn "$@"; }
        log_error() { error "$@"; }
        log_ok()    { ok "$@"; }
    else
        # firstboot.sh or standalone context: use unified-log.sh
        # shellcheck source=unified-log.sh
        source "$(dirname "${BASH_SOURCE[0]}")/unified-log.sh" 2>/dev/null || {
            log_info()  { echo "[INFO] $*"; }
            log_warn()  { echo "[WARN] $*" >&2; }
            log_error() { echo "[ERROR] $*" >&2; }
        }
    fi
fi

# Check if a compose service image already exists locally.
# Uses a cached service→image map (built once per pull_compose_images call).
_image_exists() {
    local svc="$1"
    # Use cached map if available (set by pull_compose_images)
    if [[ -n "${_svc_image_map:-}" ]] && [[ -f "$_svc_image_map" ]]; then
        local image
        image=$(grep "^${svc}=" "$_svc_image_map" 2>/dev/null | cut -d= -f2-)
        [[ -n "$image" ]] && docker image inspect "$image" >/dev/null 2>&1
        return $?
    fi
    # Fallback: query per service (slower)
    local image
    image=$(docker compose config --format json 2>/dev/null \
        | SVC="$svc" python3 -c "import sys,json,os; print(json.load(sys.stdin)['services'][os.environ['SVC']]['image'])" 2>/dev/null) || return 1
    docker image inspect "$image" >/dev/null 2>&1
}

# Pull a single service with 3-attempt retry.
# Output suppressed on success, last 5 lines surfaced on failure.
# Detects rate limit (429) and fails fast.
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
        # Detect Docker Hub rate limit — no point retrying
        if grep -qi "too many requests\|rate limit\|429" "$log" 2>/dev/null; then
            log_warn "Docker Hub rate limit hit — run 'sudo docker login' for higher limits"
            tail -3 "$log"
            rm -f "$log"
            return 2  # special exit code: rate limited
        fi
    done
    tail -5 "$log"
    rm -f "$log"
    return 1
}

# Pull all compose services with parallel execution (2 at a time).
# Skips services whose images already exist locally.
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

    # Build service→image map once (avoids repeated docker compose config calls)
    _svc_image_map=$(mktemp)
    docker compose config --format json 2>/dev/null \
        | python3 -c "import sys,json; c=json.load(sys.stdin)['services']; [print(f'{k}={v[\"image\"]}') for k,v in c.items()]" \
        > "$_svc_image_map" 2>/dev/null || true

    # Filter out services whose images already exist
    local to_pull=()
    for svc in "${services[@]}"; do
        if _image_exists "$svc"; then
            "$log_fn" "$svc: image exists, skipping pull"
        else
            to_pull+=("$svc")
        fi
    done

    if [[ ${#to_pull[@]} -eq 0 ]]; then
        "$log_fn" "All ${#services[@]} images already present"
        return 0
    fi

    local total=${#to_pull[@]}
    local count=0

    # Temp directory for pull output.
    # Cleaned up explicitly at the end — NOT via RETURN trap, because
    # background jobs still reference files in this directory.
    _pi_tmp=$(mktemp -d)

    local pull_failed=()
    local rate_limited=false

    # Pull in pairs: background + foreground
    for ((i=0; i<${#to_pull[@]}; i+=2)); do
        if [[ "$rate_limited" == "true" ]]; then break; fi

        local svc1="${to_pull[$i]}"
        local svc2="${to_pull[$i+1]:-}"

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
        local rc=0
        _pull_one "$svc1" "$log_fn" || rc=$?
        if [[ $rc -eq 2 ]]; then
            rate_limited=true
            pull_failed+=("$svc1")
            # Kill background pull immediately — no point continuing
            [[ -n "$bg_pid" ]] && kill "$bg_pid" 2>/dev/null || true
        elif [[ $rc -ne 0 ]]; then
            if [[ -n "$fail_callback" ]] && "$fail_callback" "$svc1"; then
                :  # callback handled it
            else
                pull_failed+=("$svc1")
            fi
        fi

        # Always wait for background svc2 before next pair
        if [[ -n "$bg_pid" ]]; then
            local bg_rc=0
            wait "$bg_pid" 2>/dev/null || bg_rc=$?
            if [[ $bg_rc -ne 0 ]]; then
                cat "$bg_log" 2>/dev/null
                if grep -qi "too many requests\|rate limit\|429" "$bg_log" 2>/dev/null; then
                    rate_limited=true
                fi
                if [[ -n "$fail_callback" ]] && "$fail_callback" "$svc2"; then
                    :  # callback handled it
                else
                    pull_failed+=("$svc2")
                fi
            fi
            rm -f "$bg_log"
        fi
    done

    # Clean up temp directory and cache (safe — all background jobs have been waited on)
    rm -rf "$_pi_tmp"
    rm -f "${_svc_image_map:-}"

    # Prune dangling images
    docker image prune -f >/dev/null 2>&1 || true

    if [[ "$rate_limited" == "true" ]]; then
        log_error "Docker Hub rate limit reached. Run 'sudo docker login' for higher limits."
        log_error "Then retry: docker compose pull"
        return 1
    fi

    if [[ ${#pull_failed[@]} -gt 0 ]]; then
        log_error "Failed to pull after 3 attempts: ${pull_failed[*]}"
        return 1
    fi

    "$log_fn" "All $total images pulled successfully"
    return 0
}
