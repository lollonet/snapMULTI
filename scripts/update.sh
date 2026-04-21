#!/usr/bin/env bash
# snapMULTI update script
# Downloads latest release from GitHub and updates config/scripts/compose files.
# Works without git — designed for SD-card installs where the repo is copied, not cloned.
#
# Usage: sudo ./scripts/update.sh [--check] [--force]
#   --check   Check for updates without applying them
#   --force   Skip confirmation prompt
set -euo pipefail

REPO="lollonet/snapMULTI"
INSTALL_DIR="${SNAP_DIR:-/opt/snapmulti}"
VERSION_FILE="$INSTALL_DIR/.version"

# Files/dirs to update from the release tarball (everything else is skipped)
UPDATE_TARGETS=(
    config
    scripts
    docker-compose.yml
    Dockerfile.snapserver
    Dockerfile.shairport-sync
    Dockerfile.mpd
    Dockerfile.metadata
    Dockerfile.tidal
    .env.example
)

#######################################
# Logging (inline — no dependency on common/logging.sh which may be outdated)
#######################################
info()  { echo -e "\033[34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[31m[ERROR]\033[0m $*" >&2; }

#######################################
# Helpers
#######################################

check_dependencies() {
    local missing=()
    for cmd in curl tar docker; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required commands: ${missing[*]}"
        exit 1
    fi
}

get_current_version() {
    if [[ -f "$VERSION_FILE" ]]; then
        cat "$VERSION_FILE"
    else
        echo "unknown"
    fi
}

get_latest_release() {
    local response
    response=$(curl -sf --max-time 15 \
        "https://api.github.com/repos/$REPO/releases/latest") || {
        error "Failed to fetch release info from GitHub"
        exit 1
    }

    # Extract tag_name without jq dependency
    local tag
    tag=$(echo "$response" | grep -o '"tag_name":"[^"]*"' | cut -d'"' -f4)
    if [[ -z "$tag" ]]; then
        error "Could not parse latest release tag"
        exit 1
    fi
    echo "$tag"
}

compare_versions() {
    local current="$1" latest="$2"

    # Strip leading 'v' for comparison
    local current_clean="${current#v}"
    local latest_clean="${latest#v}"

    if [[ "$current_clean" == "$latest_clean" ]]; then
        return 0  # same
    fi

    # Check for major version mismatch (refuse to cross major versions)
    local current_major="${current_clean%%.*}"
    local latest_major="${latest_clean%%.*}"
    if [[ "$current_major" != "$latest_major" ]]; then
        error "Major version change detected ($current_clean -> $latest_clean)"
        error "Automatic updates across major versions are not supported."
        error "Please update manually: https://github.com/$REPO/releases"
        exit 1
    fi

    return 1  # different (update available)
}

download_and_extract() {
    local tag="$1"
    local tmp
    tmp=$(mktemp -d)

    info "Downloading release $tag..."
    local tarball_url="https://github.com/$REPO/archive/refs/tags/${tag}.tar.gz"

    if ! curl -sL --max-time 120 "$tarball_url" | tar xz -C "$tmp" --strip-components=1; then
        error "Failed to download or extract release tarball"
        rm -rf "$tmp"
        exit 1
    fi

    echo "$tmp"
}

apply_update() {
    local src_dir="$1"

    info "Applying update..."

    for target in "${UPDATE_TARGETS[@]}"; do
        if [[ -e "$src_dir/$target" ]]; then
            if [[ -d "$src_dir/$target" ]]; then
                # Directory: sync contents (don't delete existing extra files)
                cp -r "$src_dir/$target" "$INSTALL_DIR/"
            else
                # File: overwrite
                cp "$src_dir/$target" "$INSTALL_DIR/$target"
            fi
            ok "Updated: $target"
        fi
    done

    # Ensure scripts are executable
    chmod +x "$INSTALL_DIR/scripts/"*.sh 2>/dev/null || true
}

pull_and_restart() {
    info "Pulling updated Docker images..."
    cd "$INSTALL_DIR"

    if ! docker compose pull; then
        warn "Some images failed to pull — containers will use existing images"
    fi

    info "Restarting services..."
    if ! docker compose up -d; then
        error "Failed to restart services"
        exit 1
    fi

    ok "Services restarted"
}

verify_services() {
    info "Verifying services..."
    local max_attempts=6
    local total
    total=$(docker compose config --services 2>/dev/null | wc -l)

    sleep 5

    for attempt in $(seq 1 "$max_attempts"); do
        local running healthy
        running=$(docker compose ps --status running -q 2>/dev/null | wc -l)
        healthy=$(docker compose ps --status healthy -q 2>/dev/null | wc -l)

        if [[ "$running" -ge "$total" ]] && [[ "$healthy" -ge "$total" ]]; then
            ok "All $total services running and healthy"
            return 0
        fi

        if [[ $attempt -lt $max_attempts ]]; then
            info "Attempt $attempt/$max_attempts: $running/$total running, $healthy healthy..."
            sleep 10
        fi
    done

    error "Not all services healthy after verification"
    docker compose ps --format 'table {{.Name}}\t{{.Status}}' 2>/dev/null | while read -r line; do
        error "  $line"
    done
    return 1
}

#######################################
# Main
#######################################

main() {
    local check_only=false
    local force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --check)  check_only=true; shift ;;
            --force)  force=true; shift ;;
            -h|--help)
                echo "Usage: $0 [--check] [--force]"
                echo ""
                echo "Updates snapMULTI to the latest release."
                echo "Downloads config, scripts, and compose files from GitHub."
                echo "Does NOT touch .env, audio/, artwork/, mpd/, or other user data."
                echo ""
                echo "Options:"
                echo "  --check   Check for updates without applying"
                echo "  --force   Skip confirmation prompt"
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    # Must run as root (for file permissions and docker)
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (sudo $0)"
        exit 1
    fi

    check_dependencies

    if [[ ! -d "$INSTALL_DIR" ]]; then
        error "Install directory not found: $INSTALL_DIR"
        error "Set SNAP_DIR if installed elsewhere"
        exit 1
    fi

    local current latest
    current=$(get_current_version)
    latest=$(get_latest_release)
    local latest_clean="${latest#v}"

    info "Current version: $current"
    info "Latest release:  $latest_clean"

    if compare_versions "$current" "$latest"; then
        ok "Already up to date ($current)"
        exit 0
    fi

    if [[ "$check_only" == "true" ]]; then
        echo ""
        echo "Update available: $current -> $latest_clean"
        echo "Run without --check to apply: sudo $0"
        exit 0
    fi

    if [[ "$force" != "true" ]]; then
        echo ""
        echo "Update $current -> $latest_clean"
        echo "This will update config/, scripts/, and docker-compose.yml."
        echo "Your .env, audio data, and playlists will NOT be touched."
        echo ""
        read -rp "Continue? [y/N] " confirm
        if [[ ! "$confirm" =~ ^[Yy] ]]; then
            echo "Cancelled."
            exit 0
        fi
    fi

    # Download, extract, apply
    local tmp_dir
    tmp_dir=$(download_and_extract "$latest")
    trap 'rm -rf "$tmp_dir"' EXIT

    apply_update "$tmp_dir"

    # Pull images and restart
    pull_and_restart
    if ! verify_services; then
        error "Update applied but services are not healthy"
        error "Run 'docker compose ps' to check status"
        exit 1
    fi

    # Record new version (only on success)
    echo "$latest_clean" > "$VERSION_FILE"

    echo ""
    ok "Updated: $current -> $latest_clean"
}

main "$@"
