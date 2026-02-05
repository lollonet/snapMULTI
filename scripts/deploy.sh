#!/usr/bin/env bash
# snapMULTI deployment script with auto hardware detection
# Usage: ./scripts/deploy.sh [--profile minimal|standard|performance]
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()  { echo -e "${BLUE}[INFO]${NC} $*" >&2; }
ok()    { echo -e "${GREEN}[OK]${NC} $*" >&2; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Detect script location and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$PROJECT_ROOT/.env"

# Validate PROJECT_ROOT is set and exists
if [[ -z "$PROJECT_ROOT" ]] || [[ ! -d "$PROJECT_ROOT" ]]; then
    echo "[ERROR] PROJECT_ROOT is not set or does not exist: $PROJECT_ROOT" >&2
    exit 1
fi

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
    # Pi Zero 2 W: 512MB RAM, 4 cores (but weak)
    # Pi 3: 1GB RAM, 4 cores
    # Pi 4: 2-8GB RAM, 4 cores
    # Pi 5: 4-8GB RAM, 4 cores (fast)

    if [[ -n "$pi_model" ]]; then
        case "$pi_model" in
            *"Zero 2"*)
                profile="minimal"
                ;;
            *"Pi 3"*)
                profile="minimal"
                ;;
            *"Pi 4"*)
                if [[ $total_ram_mb -ge 4000 ]]; then
                    profile="performance"
                else
                    profile="standard"
                fi
                ;;
            *"Pi 5"*)
                profile="performance"
                ;;
            *)
                # Unknown Pi, use RAM-based detection
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
            # Pi Zero 2 W, Pi 3, low-RAM systems (~1GB total)
            # Total container memory: ~450MB
            cat >> "$ENV_FILE" <<'EOF'

# Hardware Profile: minimal (auto-detected)
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
EOF
            ;;
        standard)
            # Pi 4 2GB, typical x86 systems
            # Total container memory: ~900MB
            cat >> "$ENV_FILE" <<'EOF'

# Hardware Profile: standard (auto-detected)
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
EOF
            ;;
        performance)
            # Pi 4 4GB+, Pi 5, powerful x86
            # Total container memory: ~1.8GB
            cat >> "$ENV_FILE" <<'EOF'

# Hardware Profile: performance (auto-detected)
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
# Environment Setup
#######################################

setup_env() {
    local profile="$1"

    if [[ -f "$ENV_FILE" ]]; then
        # Check if profile already set
        if grep -q "Hardware Profile:" "$ENV_FILE"; then
            local current_profile
            current_profile=$(grep "Hardware Profile:" "$ENV_FILE" | awk '{print $4}')
            if [[ "$current_profile" == "$profile" ]]; then
                info "Profile '$profile' already configured"
                return 0
            else
                warn "Existing profile: $current_profile, updating to: $profile"
                # Remove old profile settings
                sed -i.bak '/# Hardware Profile:/,$d' "$ENV_FILE"
                rm -f "$ENV_FILE.bak"
            fi
        fi
    else
        # Create new .env from example or defaults
        if [[ -f "$PROJECT_ROOT/.env.example" ]]; then
            cp "$PROJECT_ROOT/.env.example" "$ENV_FILE"
            info "Created .env from .env.example"
        else
            cat > "$ENV_FILE" <<EOF
# snapMULTI Configuration
TZ=$(timedatectl show -p Timezone --value 2>/dev/null || echo "Europe/Berlin")
PUID=$(id -u)
PGID=$(id -g)
MUSIC_PATH=/media/music
EOF
            info "Created new .env file"
        fi
    fi

    apply_resource_profile "$profile"
}

#######################################
# Directory Setup
#######################################

create_directories() {
    info "Creating required directories..."

    local dirs=(
        "audio"
        "data"
        "config"
        "mpd/data"
        "mpd/playlists"
        "mympd/workdir"
        "mympd/cachedir"
        "tidal"
    )

    for dir in "${dirs[@]}"; do
        mkdir -p "$PROJECT_ROOT/$dir"
    done

    # Create FIFOs if they don't exist
    for fifo in snapcast_fifo airplay_fifo spotify_fifo; do
        if [[ ! -p "$PROJECT_ROOT/audio/$fifo" ]]; then
            mkfifo "$PROJECT_ROOT/audio/$fifo"
        fi
    done

    # Set permissions (660 = owner+group read/write, more secure than 666)
    chmod 770 "$PROJECT_ROOT/audio"
    chmod 660 "$PROJECT_ROOT/audio"/*_fifo 2>/dev/null || true

    ok "Directories created"
}

#######################################
# Configuration Validation
#######################################

validate_config() {
    local errors=0

    info "Validating configuration..."

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

    for config in "${required_configs[@]}"; do
        if [[ ! -f "$PROJECT_ROOT/$config" ]]; then
            error "Missing config file: $config"
            errors=$((errors + 1))
        fi
    done

    # Validate FIFO paths in configs match audio directory
    if [[ -f "$PROJECT_ROOT/config/snapserver.conf" ]]; then
        if ! grep -q "/audio/" "$PROJECT_ROOT/config/snapserver.conf"; then
            warn "snapserver.conf may have incorrect FIFO paths (expected /audio/)"
        fi
    fi

    # Validate docker-compose.yml syntax
    if command -v docker &>/dev/null; then
        if ! docker compose -f "$PROJECT_ROOT/docker-compose.yml" config --quiet 2>/dev/null; then
            error "docker-compose.yml has syntax errors"
            errors=$((errors + 1))
        fi
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

check_docker() {
    if ! command -v docker &>/dev/null; then
        error "Docker not found. Please install Docker and try again."
        exit 1
    fi

    if ! docker compose version &>/dev/null; then
        error "Docker Compose not found. Install Docker Compose plugin."
        exit 1
    fi

    if ! docker info &>/dev/null; then
        error "Cannot connect to Docker daemon. Is it running?"
        exit 1
    fi

    ok "Docker ready"
}

pull_images() {
    info "Pulling Docker images..."
    cd "$PROJECT_ROOT"
    docker compose pull
    ok "Images pulled"
}

start_services() {
    info "Starting services..."
    cd "$PROJECT_ROOT"
    if ! docker compose up -d; then
        error "Failed to start services"
        exit 1
    fi
    ok "Services started"
}

verify_services() {
    local expected_services=("snapserver" "shairport-sync" "librespot" "mpd" "mympd")
    local max_attempts=6
    local wait_seconds=10
    local attempt=1

    info "Verifying services (max ${max_attempts} attempts, ${wait_seconds}s interval)..."

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
            info "Attempt $attempt/$max_attempts: ${#running_services[@]}/${#expected_services[@]} services running, waiting ${wait_seconds}s..."
            sleep "$wait_seconds"
        fi

        attempt=$((attempt + 1))
    done

    # Final report after all attempts
    warn "Service verification failed after $max_attempts attempts"
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
    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "  snapMULTI is running!"
    echo "════════════════════════════════════════════════════════════"
    echo ""

    # Get IP address
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="<server-ip>"

    echo "  Services:"
    echo "    myMPD Web UI:   http://$ip:8180"
    echo "    Snapcast API:   http://$ip:1780"
    echo "    MPD Control:    $ip:6600"
    echo ""
    echo "  Connect clients:"
    echo "    apt install snapclient"
    echo "    snapclient --host $ip"
    echo ""
    echo "  Check status:"
    echo "    docker compose ps"
    echo "    docker compose logs -f"
    echo ""
    echo "════════════════════════════════════════════════════════════"
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
                # Validate profile value
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

    echo ""
    info "snapMULTI Deployment"
    echo ""

    # Change to project root
    cd "$PROJECT_ROOT"

    # Check prerequisites
    check_docker

    # Validate configuration files
    validate_config

    # Auto-detect hardware if profile not specified
    if [[ -z "$profile" ]]; then
        profile=$(detect_hardware_profile)
    fi
    info "Using profile: $profile"

    # Setup environment
    setup_env "$profile"

    # Create directories
    create_directories

    # Pull and start
    pull_images
    start_services

    # Verify all services started
    verify_services

    # Show status
    show_status
}

main "$@"
