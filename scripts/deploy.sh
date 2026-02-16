#!/usr/bin/env bash
# snapMULTI deployment script
# Bootstraps a fresh Linux machine as a snapMULTI server.
# Usage: sudo ./scripts/deploy.sh [--profile minimal|standard|performance]
set -euo pipefail

#######################################
# Common Utilities
#######################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common/logging.sh
source "$SCRIPT_DIR/common/logging.sh"

# Global: set by preflight_checks based on architecture
IS_ARM=false

#######################################
# Project Root Detection
#######################################

# Handle both ./scripts/deploy.sh and ./deploy.sh (symlink) cases
if [[ -f "$SCRIPT_DIR/../docker-compose.yml" ]]; then
    PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
elif [[ -f "$SCRIPT_DIR/docker-compose.yml" ]]; then
    PROJECT_ROOT="$SCRIPT_DIR"
else
    error "Cannot find docker-compose.yml. Run from the snapMULTI directory."
    exit 1
fi

ENV_FILE="$PROJECT_ROOT/.env"

#######################################
# Music Library Detection
#######################################

is_network_mount() {
    local path="$1"
    [[ -z "$path" ]] && return 1

    # Get filesystem type for the path
    local fstype
    fstype=$(df -T "$path" 2>/dev/null | awk 'NR==2 {print $2}')

    # Check if it's a network filesystem
    case "$fstype" in
        nfs|nfs4|cifs|smb|smbfs|fuse.sshfs|fuse.rclone)
            return 0  # true - is network mount
            ;;
        *)
            return 1  # false - local
            ;;
    esac
}

detect_music_library() {
    local best_path=""
    local best_count=0
    local real_user="${SUDO_USER:-$(whoami)}"

    # Ensure globs that don't match expand to nothing
    local old_nullglob
    old_nullglob=$(shopt -p nullglob || true)
    shopt -s nullglob

    local search_paths=(
        /media/*
        /mnt/*
        "/home/$real_user/Music"
        "/home/$real_user/music"
    )

    echo -e "${BLUE}[INFO]${NC} Scanning for music libraries..." >&2

    for pattern in "${search_paths[@]}"; do
        # shellcheck disable=SC2086
        for dir in $pattern; do
            [[ -d "$dir" ]] || continue

            echo -ne "  Scanning ${dir}...\r" >&2

            local count
            count=$(find -L "$dir" -maxdepth 3 -type f \( \
                -iname '*.flac' -o -iname '*.mp3' -o -iname '*.m4a' \
                -o -iname '*.ogg' -o -iname '*.wav' -o -iname '*.aac' \
                -o -iname '*.opus' -o -iname '*.wma' \
            \) 2>/dev/null | head -1000 | wc -l)

            if [[ "$count" -gt 0 ]]; then
                echo -e "${BLUE}[INFO]${NC}   Found: $dir ($count audio files)" >&2
                if [[ "$count" -gt "$best_count" ]]; then
                    best_count="$count"
                    best_path="$dir"
                fi
            fi
        done
    done

    # Restore nullglob
    $old_nullglob

    if [[ -n "$best_path" ]]; then
        echo "$best_path"
    fi
}

#######################################
# Hardware Detection
#######################################

detect_hardware_profile() {
    local total_ram_mb cpu_cores profile pi_model

    # Detect RAM (in MB)
    if [[ -f /proc/meminfo ]]; then
        total_ram_mb=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)
    else
        total_ram_mb=$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f", $1/1024/1024}') || total_ram_mb=4096
    fi

    # Detect CPU cores
    if [[ -f /proc/cpuinfo ]]; then
        cpu_cores=$(grep -c ^processor /proc/cpuinfo)
    else
        cpu_cores=$(sysctl -n hw.ncpu 2>/dev/null) || cpu_cores=4
    fi

    # Detect Raspberry Pi model
    if [[ -f /proc/device-tree/model ]]; then
        pi_model=$(tr -d '\0' < /proc/device-tree/model)
        info "Detected: $pi_model"
    elif [[ -f /proc/cpuinfo ]] && grep -q "Raspberry Pi" /proc/cpuinfo 2>/dev/null; then
        pi_model=$(grep "Model" /proc/cpuinfo | cut -d: -f2 | xargs)
        info "Detected: $pi_model"
    else
        pi_model=""
    fi

    info "Hardware: ${total_ram_mb}MB RAM, ${cpu_cores} CPU cores"

    # Determine profile based on hardware
    if [[ -n "$pi_model" ]]; then
        case "$pi_model" in
            *"Zero 2"*) profile="minimal" ;;
            *"Pi 3"*)   profile="minimal" ;;
            *"Pi 4"*)
                if [[ $total_ram_mb -ge 4000 ]]; then
                    profile="performance"
                else
                    profile="standard"
                fi
                ;;
            *"Pi 5"*)   profile="performance" ;;
            *)
                if [[ $total_ram_mb -lt 1500 ]]; then
                    profile="minimal"
                elif [[ $total_ram_mb -lt 4000 ]]; then
                    profile="standard"
                else
                    profile="performance"
                fi
                ;;
        esac
    else
        # Non-Pi hardware (x86, etc.)
        if [[ $total_ram_mb -lt 2000 ]]; then
            profile="minimal"
        elif [[ $total_ram_mb -lt 8000 ]]; then
            profile="standard"
        else
            profile="performance"
        fi
    fi

    echo "$profile"
}

#######################################
# Resource Profiles
#######################################

apply_resource_profile() {
    local profile="$1"

    info "Applying '$profile' resource profile..."

    case "$profile" in
        minimal)
            cat >> "$ENV_FILE" <<'EOF'

# Hardware Profile: BEGIN
# Profile: minimal (auto-detected)
# For: Pi Zero 2 W, Pi 3, systems with <2GB RAM
SNAPSERVER_MEM_LIMIT=128M
SNAPSERVER_MEM_RESERVE=64M
SNAPSERVER_CPU_LIMIT=0.5
AIRPLAY_MEM_LIMIT=96M
AIRPLAY_MEM_RESERVE=48M
AIRPLAY_CPU_LIMIT=0.3
SPOTIFY_MEM_LIMIT=96M
SPOTIFY_MEM_RESERVE=48M
SPOTIFY_CPU_LIMIT=0.3
MPD_MEM_LIMIT=128M
MPD_MEM_RESERVE=64M
MPD_CPU_LIMIT=0.5
MYMPD_MEM_LIMIT=64M
MYMPD_MEM_RESERVE=32M
MYMPD_CPU_LIMIT=0.25
# Hardware Profile: END
EOF
            ;;
        standard)
            cat >> "$ENV_FILE" <<'EOF'

# Hardware Profile: BEGIN
# Profile: standard (auto-detected)
# For: Pi 4 2GB, systems with 2-4GB RAM
SNAPSERVER_MEM_LIMIT=256M
SNAPSERVER_MEM_RESERVE=128M
SNAPSERVER_CPU_LIMIT=1.0
AIRPLAY_MEM_LIMIT=128M
AIRPLAY_MEM_RESERVE=64M
AIRPLAY_CPU_LIMIT=0.5
SPOTIFY_MEM_LIMIT=128M
SPOTIFY_MEM_RESERVE=64M
SPOTIFY_CPU_LIMIT=0.5
MPD_MEM_LIMIT=256M
MPD_MEM_RESERVE=128M
MPD_CPU_LIMIT=1.0
MYMPD_MEM_LIMIT=128M
MYMPD_MEM_RESERVE=64M
MYMPD_CPU_LIMIT=0.5
# Hardware Profile: END
EOF
            ;;
        performance)
            cat >> "$ENV_FILE" <<'EOF'

# Hardware Profile: BEGIN
# Profile: performance (auto-detected)
# For: Pi 4 4GB+, Pi 5, systems with 8GB+ RAM
SNAPSERVER_MEM_LIMIT=512M
SNAPSERVER_MEM_RESERVE=256M
SNAPSERVER_CPU_LIMIT=2.0
AIRPLAY_MEM_LIMIT=256M
AIRPLAY_MEM_RESERVE=128M
AIRPLAY_CPU_LIMIT=1.0
SPOTIFY_MEM_LIMIT=256M
SPOTIFY_MEM_RESERVE=128M
SPOTIFY_CPU_LIMIT=1.0
MPD_MEM_LIMIT=512M
MPD_MEM_RESERVE=256M
MPD_CPU_LIMIT=2.0
MYMPD_MEM_LIMIT=256M
MYMPD_MEM_RESERVE=128M
MYMPD_CPU_LIMIT=1.0
# Hardware Profile: END
EOF
            ;;
        *)
            error "Unknown profile: $profile"
            exit 1
            ;;
    esac

    ok "Resource profile '$profile' applied"
}

#######################################
# Preflight Checks
#######################################

preflight_checks() {
    step "Preflight checks"

    # Must be Linux
    if [[ "$(uname -s)" != "Linux" ]]; then
        error "snapMULTI requires Linux (host networking for mDNS). Detected: $(uname -s)"
        exit 1
    fi
    info "OS: Linux"

    # Architecture check
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64)
            info "Architecture: amd64"
            IS_ARM=false
            ;;
        aarch64)
            info "Architecture: arm64"
            IS_ARM=true
            ;;
        armv7l)
            info "Architecture: armv7 (supported but arm64 recommended)"
            IS_ARM=true
            ;;
        armv6l)
            warn "Architecture: armv6 — too weak for server use (Pi Zero v1 / Pi 1)"
            IS_ARM=true
            ;;
        *)
            error "Unsupported architecture: $arch"
            exit 1
            ;;
    esac

    # Network check
    if curl -sf --max-time 5 https://ghcr.io >/dev/null 2>&1; then
        info "Network: OK (ghcr.io reachable)"
    else
        error "Cannot reach ghcr.io — check network connectivity"
        exit 1
    fi
}

#######################################
# System Dependencies
#######################################

install_dependencies() {
    step "System dependencies"

    # Avahi is required for mDNS discovery (Spotify Connect, AirPlay)
    if ! command -v avahi-daemon >/dev/null 2>&1; then
        info "Installing Avahi for mDNS discovery..."
        apt-get update -qq
        apt-get install -y -qq avahi-daemon >/dev/null
        systemctl enable --now avahi-daemon >/dev/null 2>&1
        ok "Avahi installed"
    else
        info "Avahi already installed"
        # Ensure it's running
        if ! systemctl is-active --quiet avahi-daemon; then
            systemctl start avahi-daemon
        fi
    fi

    ok "System dependencies ready"
}

#######################################
# Docker Installation
#######################################

install_docker() {
    step "Docker"

    if command -v docker >/dev/null 2>&1; then
        info "Docker already installed: $(docker --version)"
    else
        info "Installing Docker via official script (https://get.docker.com)..."
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sh /tmp/get-docker.sh
        rm -f /tmp/get-docker.sh
        ok "Docker installed: $(docker --version)"
    fi

    # Check Docker Compose
    if docker compose version >/dev/null 2>&1; then
        info "Docker Compose: $(docker compose version --short)"
    else
        error "Docker Compose not found. Install Docker Compose v2."
        exit 1
    fi

    # Add real user to docker group
    local real_user="${SUDO_USER:-$(whoami)}"
    if ! id -nG "$real_user" | grep -qw docker; then
        usermod -aG docker "$real_user"
        info "Added $real_user to docker group (re-login to take effect)"
    fi

    # Enable and start Docker
    systemctl enable docker >/dev/null 2>&1 || true
    systemctl start docker

    # Verify Docker is running
    if ! docker info &>/dev/null; then
        error "Cannot connect to Docker daemon. Is it running?"
        exit 1
    fi

    ok "Docker ready"
}

#######################################
# Directory Setup
#######################################

create_directories() {
    step "Creating directories"

    local real_user="${SUDO_USER:-$(whoami)}"
    local real_uid real_gid
    real_uid="$(id -u "$real_user")"
    real_gid="$(id -g "$real_user")"

    local dirs=(
        "audio"
        "data"
        "config"
        "mpd/data"
        "mpd/playlists"
        "mympd/workdir"
        "mympd/cachedir"
    )

    for dir in "${dirs[@]}"; do
        mkdir -p "$PROJECT_ROOT/$dir"
    done

    # Create FIFOs if they don't exist
    for fifo in snapcast_fifo airplay_fifo spotify_fifo tidal_fifo; do
        if [[ ! -p "$PROJECT_ROOT/audio/$fifo" ]]; then
            mkfifo "$PROJECT_ROOT/audio/$fifo"
        fi
    done

    # Create metadata pipe for shairport-sync (if not exists)
    # Note: shairport-sync will also create this, but we ensure it exists
    if [[ ! -p "$PROJECT_ROOT/audio/shairport-metadata" ]]; then
        mkfifo "$PROJECT_ROOT/audio/shairport-metadata"
    fi

    # Pre-create MPD database file to avoid startup error
    touch "$PROJECT_ROOT/mpd/data/mpd.db"

    # Set ownership and permissions
    # Note: 777/666 needed because containers run with cap_drop: ALL
    # and may run as different UIDs than the host user
    chown -R "$real_uid:$real_gid" "$PROJECT_ROOT/audio" "$PROJECT_ROOT/data" \
        "$PROJECT_ROOT/mpd" "$PROJECT_ROOT/mympd"
    chmod 777 "$PROJECT_ROOT/audio"
    chmod 666 "$PROJECT_ROOT/audio"/*_fifo 2>/dev/null || true
    chmod 666 "$PROJECT_ROOT/audio"/shairport-metadata 2>/dev/null || true

    # Ensure scripts are executable (git may not preserve permissions)
    chmod +x "$PROJECT_ROOT/scripts/"*.sh "$PROJECT_ROOT/scripts/"*.py 2>/dev/null || true

    ok "Directories created: ${dirs[*]}"
}

#######################################
# Environment Configuration
#######################################

setup_env() {
    local profile="$1"

    step "Environment configuration"

    local real_user="${SUDO_USER:-$(whoami)}"
    local real_uid real_gid
    real_uid="$(id -u "$real_user")"
    real_gid="$(id -g "$real_user")"

    if [[ -f "$ENV_FILE" ]]; then
        # Check if profile already set
        if grep -q "# Hardware Profile: BEGIN" "$ENV_FILE"; then
            local current_profile
            current_profile=$(grep "# Profile:" "$ENV_FILE" | awk '{print $3}')
            if [[ "$current_profile" == "$profile" ]]; then
                info "Profile '$profile' already configured"
                return 0
            else
                warn "Existing profile: $current_profile, updating to: $profile"
                sed -i.bak '/# Hardware Profile: BEGIN/,/# Hardware Profile: END/d' "$ENV_FILE"
                rm -f "$ENV_FILE.bak"
            fi
        else
            info "Existing .env found, adding hardware profile"
        fi
        apply_resource_profile "$profile"
    else
        # Auto-detect timezone
        local tz_detected
        if command -v timedatectl >/dev/null 2>&1; then
            tz_detected="$(timedatectl show -p Timezone --value 2>/dev/null || echo "Europe/Berlin")"
        elif [[ -f /etc/timezone ]]; then
            tz_detected="$(cat /etc/timezone)"
        else
            tz_detected="Europe/Berlin"
        fi

        # Auto-detect music library
        local music_path
        music_path="$(detect_music_library)"
        if [[ -n "$music_path" ]]; then
            info "Auto-detected music library: $music_path"
        else
            music_path="/media/music"
            warn "No music library found — using default: $music_path"
            warn "Mount your music there or edit .env to set MUSIC_PATH"
        fi

        # Detect if music is on network mount
        local mpd_start_period="30s"
        if is_network_mount "$music_path"; then
            mpd_start_period="300s"
            info "Network mount detected — using extended MPD start period (5 min)"
        else
            info "Local storage detected — using standard MPD start period (30s)"
        fi

        # Generate .env
        cat > "$ENV_FILE" <<EOF
# snapMULTI Environment Configuration
# Generated by deploy.sh on $(date -Iseconds)

# Music library path
MUSIC_PATH=$music_path

# Timezone
TZ=$tz_detected

# User/Group for container processes
PUID=$real_uid
PGID=$real_gid

# MPD healthcheck start period (longer for NFS/network mounts)
MPD_START_PERIOD=$mpd_start_period
EOF

        chown "$real_uid:$real_gid" "$ENV_FILE"
        info "Generated .env:"
        info "  MUSIC_PATH=$music_path"
        info "  TZ=$tz_detected"
        info "  PUID=$real_uid  PGID=$real_gid"
        info "  MPD_START_PERIOD=$mpd_start_period"

        apply_resource_profile "$profile"
    fi
}

#######################################
# Configuration Validation
#######################################

validate_config() {
    step "Validating configuration"

    cd "$PROJECT_ROOT"
    local errors=0

    # Check docker-compose.yml exists
    if [[ ! -f "$PROJECT_ROOT/docker-compose.yml" ]]; then
        error "docker-compose.yml not found in $PROJECT_ROOT"
        errors=$((errors + 1))
    fi

    # Check required config files
    local required_configs=(
        "config/snapserver.conf"
        "config/mpd.conf"
        "config/shairport-sync.conf"
    )

    # Tidal config only required on ARM (tidal-connect is ARM-only)
    if [[ "$IS_ARM" == "true" ]]; then
        required_configs+=("config/tidal-asound.conf")
    fi

    for config in "${required_configs[@]}"; do
        if [[ ! -f "$PROJECT_ROOT/$config" ]]; then
            error "Missing config file: $config"
            errors=$((errors + 1))
        fi
    done

    # Validate docker-compose.yml syntax
    if ! docker compose config --quiet; then
        error "docker-compose.yml has syntax errors (run 'docker compose config' for details)"
        errors=$((errors + 1))
    fi

    if [[ $errors -gt 0 ]]; then
        error "Configuration validation failed with $errors error(s)"
        exit 1
    fi

    ok "Configuration valid"
}

#######################################
# Docker Operations
#######################################

pull_images() {
    step "Pulling Docker images"
    cd "$PROJECT_ROOT"

    if [[ "$IS_ARM" == "true" ]]; then
        docker compose pull
    else
        # Skip tidal-connect on x86 (ARM-only image)
        info "Skipping tidal-connect (ARM-only) on x86"
        docker compose pull snapserver mpd mympd shairport-sync librespot
    fi
    ok "Images pulled"
}

start_services() {
    step "Starting services"
    cd "$PROJECT_ROOT"

    if [[ "$IS_ARM" == "true" ]]; then
        if ! docker compose up -d; then
            error "Failed to start services"
            exit 1
        fi
        ok "Services started (including Tidal Connect)"
    else
        # Skip tidal-connect on x86 (ARM-only image)
        if ! docker compose up -d snapserver mpd mympd shairport-sync librespot; then
            error "Failed to start services"
            exit 1
        fi
        ok "Services started (Tidal Connect skipped — ARM only)"
    fi
}

verify_services() {
    step "Verifying services"

    local expected_services=("snapserver" "shairport-sync" "librespot" "mpd" "mympd")
    # Include tidal-connect only on ARM
    if [[ "$IS_ARM" == "true" ]]; then
        expected_services+=("tidal-connect")
    fi
    local max_attempts=6
    local wait_seconds=10
    local attempt=1

    info "Checking services (max ${max_attempts} attempts, ${wait_seconds}s interval)..."

    while [[ $attempt -le $max_attempts ]]; do
        local failed=0
        local running_services=()

        for service in "${expected_services[@]}"; do
            if docker ps --format '{{.Names}}' | grep -q "^${service}$"; then
                running_services+=("$service")
            else
                failed=$((failed + 1))
            fi
        done

        if [[ $failed -eq 0 ]]; then
            for service in "${expected_services[@]}"; do
                ok "$service running"
            done
            ok "All services running"
            return 0
        fi

        if [[ $attempt -lt $max_attempts ]]; then
            info "Attempt $attempt/$max_attempts: ${#running_services[@]}/${#expected_services[@]} running, waiting ${wait_seconds}s..."
            sleep "$wait_seconds"
        fi

        attempt=$((attempt + 1))
    done

    # Final report
    warn "Service verification incomplete after $max_attempts attempts"
    for service in "${expected_services[@]}"; do
        if docker ps --format '{{.Names}}' | grep -q "^${service}$"; then
            ok "$service running"
        else
            error "$service not running"
        fi
    done
    warn "Check logs: docker compose logs"
    return 1
}

show_status() {
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="<server-ip>"

    echo ""
    echo -e "${GREEN}${BOLD}"
    echo "  ════════════════════════════════════════"
    echo "    snapMULTI is running!"
    echo "  ════════════════════════════════════════"
    echo ""
    echo "    myMPD Web UI:  http://${ip}:8180"
    echo "    Snapcast API:  http://${ip}:1780"
    echo "    MPD Control:   ${ip}:6600"
    echo ""
    echo "    Connect clients:"
    echo "      sudo apt install snapclient"
    echo "      snapclient --host ${ip}"
    echo ""
    echo "    Install dir:   ${PROJECT_ROOT}"
    echo "    Config:        ${PROJECT_ROOT}/.env"
    echo "  ════════════════════════════════════════"
    echo -e "${NC}"
}

#######################################
# Main
#######################################

main() {
    local profile=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --profile)
                if [[ -z "${2:-}" ]]; then
                    error "--profile requires a value (minimal|standard|performance)"
                    exit 1
                fi
                profile="$2"
                case "$profile" in
                    minimal|standard|performance) ;;
                    *)
                        error "Invalid profile: $profile (must be minimal, standard, or performance)"
                        exit 1
                        ;;
                esac
                shift 2
                ;;
            -h|--help)
                echo "Usage: $0 [--profile minimal|standard|performance]"
                echo ""
                echo "Bootstraps a fresh Linux machine as a snapMULTI server."
                echo "Installs Docker if needed, detects hardware, configures services."
                echo ""
                echo "Options:"
                echo "  --profile  Force a specific resource profile"
                echo "             (default: auto-detect from hardware)"
                echo ""
                echo "Profiles:"
                echo "  minimal      Pi Zero 2 W, Pi 3, <2GB RAM"
                echo "  standard     Pi 4 2GB, 2-4GB RAM"
                echo "  performance  Pi 4 4GB+, Pi 5, 8GB+ RAM"
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    # Must run as root for Docker installation
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (sudo $0)"
        exit 1
    fi

    echo ""
    info "snapMULTI Deployment"
    echo ""

    # Run deployment steps
    preflight_checks
    install_dependencies
    install_docker
    create_directories

    # Auto-detect hardware if profile not specified
    step "Hardware detection"
    if [[ -z "$profile" ]]; then
        profile=$(detect_hardware_profile)
    fi
    info "Using profile: $profile"

    setup_env "$profile"
    validate_config
    pull_images
    start_services
    verify_services
    show_status
}

main "$@"
