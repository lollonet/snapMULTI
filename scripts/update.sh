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
    for cmd in curl tar docker python3; do
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

parse_latest_tag() {
    local response="$1"
    echo "$response" \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        | head -n1
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
    tag=$(parse_latest_tag "$response")
    if [[ -z "$tag" ]]; then
        error "Could not parse latest release tag"
        exit 1
    fi
    echo "$tag"
}

compare_versions() {
    local current="$1" latest="$2"

    if [[ -z "$current" ]] || [[ "$current" == "unknown" ]]; then
        return 1  # unknown local version: allow update
    fi

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
    local ts
    ts=$(date +%Y%m%d-%H%M%S)

    info "Applying update..."

    # Stage the update in a temporary copy so a failed cp doesn't leave
    # the live install half-mutated. On success we swap; on failure we
    # restore the backup.
    local backup_root="$HOME/.claude-backups/update/$ts"
    local staging_dir
    staging_dir=$(mktemp -d "${INSTALL_DIR}.staging.XXXXXX")

    # Snapshot current install into staging (hard-link where possible for speed)
    # Full copy (not hard links) so staging is fully isolated from live install.
    # Hard links would share inodes — cp overwrites would mutate INSTALL_DIR.
    cp -a "$INSTALL_DIR/." "$staging_dir/"

    # Apply changes to the staging copy
    for target in "${UPDATE_TARGETS[@]}"; do
        if [[ -e "$src_dir/$target" ]]; then
            if [[ -d "$src_dir/$target" ]]; then
                # Remove entries (files, symlinks, empty dirs) absent from new release
                if [[ -d "$staging_dir/$target" ]]; then
                    while IFS= read -r rel_path; do
                        if [[ ! -e "$src_dir/$target/$rel_path" ]]; then
                            local dest="$staging_dir/$target/$rel_path"
                            mkdir -p "$backup_root/$target/$(dirname "$rel_path")"
                            mv "$dest" "$backup_root/$target/$rel_path" 2>/dev/null || true
                        fi
                    done < <(cd "$staging_dir/$target" && find . \( -type f -o -type l \) | sed 's|^\./||')
                    # Prune empty directories not present in new release
                    (cd "$staging_dir/$target" && find . -depth -type d -empty -exec rmdir {} \; 2>/dev/null) || true
                fi
                mkdir -p "$staging_dir/$target"
                cp -r "$src_dir/$target/." "$staging_dir/$target/"
            else
                cp "$src_dir/$target" "$staging_dir/$target"
            fi
        fi
    done

    # Ensure scripts are executable
    chmod +x "$staging_dir/scripts/"*.sh 2>/dev/null || true

    # Atomic swap: move live → backup, staging → live
    # If the swap fails, restore the backup.
    local live_backup="${INSTALL_DIR}.pre-update.$ts"
    if mv "$INSTALL_DIR" "$live_backup" && mv "$staging_dir" "$INSTALL_DIR"; then
        rm -rf "$live_backup"
        # Clean up empty backup dir
        rmdir "$backup_root" 2>/dev/null || true
        for target in "${UPDATE_TARGETS[@]}"; do
            [[ -e "$src_dir/$target" ]] && ok "Updated: $target"
        done
    else
        error "Swap failed — restoring previous install"
        # Restore: put back whatever we moved
        [[ -d "$live_backup" && ! -d "$INSTALL_DIR" ]] && mv "$live_backup" "$INSTALL_DIR"
        rm -rf "$staging_dir"
        exit 1
    fi
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
    sleep 5

    # shellcheck source=common/verify-compose.sh
    source "$(dirname "${BASH_SOURCE[0]}")/common/verify-compose.sh" 2>/dev/null \
        || source "$INSTALL_DIR/scripts/common/verify-compose.sh" 2>/dev/null \
        || { error "verify-compose.sh not found"; return 1; }
    verify_compose_stack "$INSTALL_DIR/docker-compose.yml" "server" 6 10
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
