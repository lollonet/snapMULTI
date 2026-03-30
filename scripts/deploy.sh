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
# shellcheck source=common/system-tune.sh
source "$SCRIPT_DIR/common/system-tune.sh"

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
# User Detection
#######################################

# Detect the real (non-root) user who should own files.
# In sudo context: SUDO_USER is set. In firstboot/cloud-init: neither
# SUDO_USER nor a non-root login exists, so fall back to uid 1000.
detect_real_user() {
    local user="${SUDO_USER:-}"
    if [[ -z "$user" ]] || [[ "$user" == "root" ]]; then
        user=$(getent passwd 1000 2>/dev/null | cut -d: -f1) || true
    fi
    printf '%s' "${user:-root}"
}

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
    local real_user
    real_user="$(detect_real_user)"

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
    eval "$old_nullglob"

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
# Measured baseline (idle): snapserver 87M, shairport 18M, librespot 22M,
#   mpd 90M (6k songs), mympd 8M, metadata 52M, tidal 32M
SNAPSERVER_MEM_LIMIT=128M
SNAPSERVER_MEM_RESERVE=64M
SNAPSERVER_CPU_LIMIT=0.5
AIRPLAY_MEM_LIMIT=48M
AIRPLAY_MEM_RESERVE=24M
AIRPLAY_CPU_LIMIT=0.3
SPOTIFY_MEM_LIMIT=96M
SPOTIFY_MEM_RESERVE=48M
SPOTIFY_CPU_LIMIT=0.3
MPD_MEM_LIMIT=128M
MPD_MEM_RESERVE=64M
MPD_CPU_LIMIT=0.5
MYMPD_MEM_LIMIT=32M
MYMPD_MEM_RESERVE=16M
MYMPD_CPU_LIMIT=0.25
METADATA_MEM_LIMIT=96M
METADATA_MEM_RESERVE=48M
METADATA_CPU_LIMIT=0.3
TIDAL_MEM_LIMIT=64M
TIDAL_MEM_RESERVE=32M
TIDAL_CPU_LIMIT=0.3
# Hardware Profile: END
EOF
            ;;
        standard)
            cat >> "$ENV_FILE" <<'EOF'

# Hardware Profile: BEGIN
# Profile: standard (auto-detected)
# For: Pi 4 2GB, systems with 2-4GB RAM
# Measured baseline (idle): snapserver 87M, shairport 18M, librespot 22M,
#   mpd 90M (6k songs), mympd 8M, metadata 52M, tidal 32M
SNAPSERVER_MEM_LIMIT=192M
SNAPSERVER_MEM_RESERVE=96M
SNAPSERVER_CPU_LIMIT=1.0
AIRPLAY_MEM_LIMIT=64M
AIRPLAY_MEM_RESERVE=32M
AIRPLAY_CPU_LIMIT=0.5
SPOTIFY_MEM_LIMIT=256M
SPOTIFY_MEM_RESERVE=128M
SPOTIFY_CPU_LIMIT=0.5
MPD_MEM_LIMIT=256M
MPD_MEM_RESERVE=128M
MPD_CPU_LIMIT=1.0
MYMPD_MEM_LIMIT=64M
MYMPD_MEM_RESERVE=32M
MYMPD_CPU_LIMIT=0.5
METADATA_MEM_LIMIT=128M
METADATA_MEM_RESERVE=64M
METADATA_CPU_LIMIT=0.5
TIDAL_MEM_LIMIT=96M
TIDAL_MEM_RESERVE=48M
TIDAL_CPU_LIMIT=0.5
# Hardware Profile: END
EOF
            ;;
        performance)
            cat >> "$ENV_FILE" <<'EOF'

# Hardware Profile: BEGIN
# Profile: performance (auto-detected)
# For: Pi 4 4GB+, Pi 5, systems with 8GB+ RAM
# Measured baseline (idle): snapserver 87M, shairport 18M, librespot 22M,
#   mpd 90M (6k songs), mympd 8M, metadata 52M, tidal 32M
SNAPSERVER_MEM_LIMIT=256M
SNAPSERVER_MEM_RESERVE=128M
SNAPSERVER_CPU_LIMIT=2.0
AIRPLAY_MEM_LIMIT=96M
AIRPLAY_MEM_RESERVE=48M
AIRPLAY_CPU_LIMIT=0.5
SPOTIFY_MEM_LIMIT=256M
SPOTIFY_MEM_RESERVE=128M
SPOTIFY_CPU_LIMIT=1.0
MPD_MEM_LIMIT=384M
MPD_MEM_RESERVE=192M
MPD_CPU_LIMIT=2.0
MYMPD_MEM_LIMIT=128M
MYMPD_MEM_RESERVE=64M
MYMPD_CPU_LIMIT=0.5
METADATA_MEM_LIMIT=128M
METADATA_MEM_RESERVE=64M
METADATA_CPU_LIMIT=0.5
TIDAL_MEM_LIMIT=128M
TIDAL_MEM_RESERVE=64M
TIDAL_CPU_LIMIT=0.5
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
    if curl -sf --max-time 5 https://hub.docker.com >/dev/null 2>&1; then
        info "Network: OK (Docker Hub reachable)"
    else
        error "Cannot reach Docker Hub — check network connectivity"
        exit 1
    fi
}

#######################################
# System Dependencies
#######################################

install_dependencies() {
    step "System dependencies"

    # Set system locale to C.UTF-8 — always available on Debian, no locale-gen needed.
    # Prevents apt warnings and locale errors in subprocesses.
    export DEBIAN_FRONTEND=noninteractive
    export LANG=C.UTF-8
    export LC_ALL=C.UTF-8
    update-locale LANG=C.UTF-8 LC_ALL=C.UTF-8 2>/dev/null || true

    # Git for updates (git pull)
    if ! command -v git >/dev/null 2>&1; then
        info "Installing git..."
        apt-get update -qq
        apt-get install -y -qq git >/dev/null
        ok "Git installed"
    else
        info "Git already installed"
    fi

    # Avahi is required for mDNS discovery (Spotify Connect, AirPlay)
    if ! command -v avahi-daemon >/dev/null 2>&1; then
        info "Installing Avahi for mDNS discovery..."
        apt-get update -qq
        apt-get install -y -qq avahi-daemon avahi-utils >/dev/null
        systemctl enable --now avahi-daemon >/dev/null 2>&1
        ok "Avahi installed"
    else
        info "Avahi already installed"
        # Ensure it's running
        if ! systemctl is-active --quiet avahi-daemon; then
            systemctl start avahi-daemon
        fi
    fi

    # Harden avahi: pin hostname and restrict to physical interfaces
    tune_avahi_daemon "$(tr -d '[:space:]' < /etc/hostname)"

    # Lightweight monitoring tools (sar, iotop, dstat)
    local mon_pkgs=()
    command -v sar >/dev/null 2>&1 || mon_pkgs+=(sysstat)
    command -v iotop >/dev/null 2>&1 || mon_pkgs+=(iotop-c)
    command -v dstat >/dev/null 2>&1 || mon_pkgs+=(dstat)
    if [[ ${#mon_pkgs[@]} -gt 0 ]]; then
        info "Installing monitoring tools: ${mon_pkgs[*]}..."
        # Wait for apt lock — firstboot may still be upgrading packages
        local _apt_wait
        for _apt_wait in $(seq 1 60); do
            fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || break
            sleep 5
        done
        if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
            warn "apt lock still held after 5 minutes — proceeding anyway"
        fi
        apt-get install -y -qq "${mon_pkgs[@]}" >/dev/null
        # Enable sysstat data collection (sar)
        if [[ -f /etc/default/sysstat ]]; then
            sed -i 's/^ENABLED="false"/ENABLED="true"/' /etc/default/sysstat
            systemctl enable --now sysstat >/dev/null 2>&1 || true
        fi
        ok "Monitoring tools installed"
    fi

    # Audio performance tuning (system-tune.sh sourced at top of file)
    tune_cpu_governor
    tune_usb_autosuspend

    # Network QoS: prioritize Snapcast audio over bulk transfers
    # CAKE qdisc with diffserv4 gives DSCP EF-marked packets lowest latency
    local net_iface
    net_iface=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
    if [[ -n "$net_iface" ]]; then
        if modprobe sch_cake 2>/dev/null; then
            # Mark Snapcast streaming and control ports with DSCP EF
            if command -v iptables &>/dev/null; then
                iptables -t mangle -C OUTPUT -p tcp --sport 1704 -j DSCP --set-dscp-class EF 2>/dev/null \
                    || iptables -t mangle -A OUTPUT -p tcp --sport 1704 -j DSCP --set-dscp-class EF
                iptables -t mangle -C OUTPUT -p tcp --sport 1705 -j DSCP --set-dscp-class EF 2>/dev/null \
                    || iptables -t mangle -A OUTPUT -p tcp --sport 1705 -j DSCP --set-dscp-class EF
                if command -v iptables-save &>/dev/null; then
                    mkdir -p /etc/iptables
                    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
                fi
            else
                warn "Network QoS: iptables not found, DSCP marking skipped (CAKE still active)"
            fi
            # Replace default qdisc with CAKE
            tc qdisc replace dev "$net_iface" root cake diffserv4 2>/dev/null \
                && ok "Network QoS: CAKE + DSCP EF on $net_iface (Snapcast prioritized)" \
                || warn "Network QoS: CAKE setup failed on $net_iface"
            # Persist CAKE via networkd-dispatcher (re-detect interface at boot)
            mkdir -p /etc/networkd-dispatcher/routable.d
            cat > /etc/networkd-dispatcher/routable.d/50-cake-qos <<'QEOF'
#!/bin/sh
PATH=/usr/sbin:/sbin:$PATH
iface=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
[ -n "$iface" ] || exit 0
modprobe sch_cake 2>/dev/null
tc qdisc replace dev "$iface" root cake diffserv4 2>/dev/null
# DSCP EF marking for Snapcast (streaming + control)
if command -v iptables >/dev/null 2>&1; then
    iptables -t mangle -C OUTPUT -p tcp --sport 1704 -j DSCP --set-dscp-class EF 2>/dev/null \
        || iptables -t mangle -A OUTPUT -p tcp --sport 1704 -j DSCP --set-dscp-class EF
    iptables -t mangle -C OUTPUT -p tcp --sport 1705 -j DSCP --set-dscp-class EF 2>/dev/null \
        || iptables -t mangle -A OUTPUT -p tcp --sport 1705 -j DSCP --set-dscp-class EF
fi
QEOF
            chmod +x /etc/networkd-dispatcher/routable.d/50-cake-qos
        else
            warn "Network QoS: CAKE kernel module not available, skipped"
        fi
    fi

    # Boot-time tuning service (shared function from system-tune.sh)
    install_boot_tune_service "$SCRIPT_DIR/boot-tune.sh"

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
        info "Installing Docker via official APT repository..."
        # shellcheck source=common/install-docker.sh
        source "$SCRIPT_DIR/common/install-docker.sh"
        install_docker_apt
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
    local real_user
    real_user="$(detect_real_user)"
    if ! id -nG "$real_user" | grep -qw docker; then
        usermod -aG docker "$real_user"
        info "Added $real_user to docker group (re-login to take effect)"
    fi

    # Install fuse-overlayfs (required for read-only FS support)
    if ! command -v fuse-overlayfs &>/dev/null; then
        apt-get install -y fuse-overlayfs >/dev/null 2>&1 \
            || warn "fuse-overlayfs install failed — read-only mode may not work"
    fi

    # Docker daemon config (live-restore + fuse-overlayfs for read-only FS)
    tune_docker_daemon --live-restore --fuse-overlayfs

    # Enable and start Docker
    systemctl enable docker >/dev/null 2>&1 || true
    systemctl start docker

    # Verify Docker is running
    if ! docker info &>/dev/null; then
        error "Cannot connect to Docker daemon. Is it running?"
        exit 1
    fi

    # Enable cgroup memory controller for Docker resource limits on Pi.
    # Without this, deploy.resources.limits.memory in docker-compose.yml is ignored.
    local cmdline=""
    if [[ -f /boot/firmware/cmdline.txt ]]; then
        cmdline="/boot/firmware/cmdline.txt"
    elif [[ -f /boot/cmdline.txt ]]; then
        cmdline="/boot/cmdline.txt"
    fi
    if [[ -n "$cmdline" ]] && ! grep -q "cgroup_enable=memory" "$cmdline"; then
        info "Enabling cgroup memory controller in $cmdline..."
        sed -i '1s/$/ cgroup_enable=memory cgroup_memory=1/' "$cmdline"
        warn "Reboot required for memory limits to take effect"
    fi

    ok "Docker ready"
}

#######################################
# Directory Setup
#######################################

create_directories() {
    step "Creating directories"

    local real_user
    real_user="$(detect_real_user)"
    local real_uid real_gid
    real_uid="$(id -u "$real_user")"
    real_gid="$(id -g "$real_user")"

    local dirs=(
        "audio"
        "artwork"
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
    for fifo in mpd_fifo airplay_fifo spotify_fifo tidal_fifo; do
        if [[ ! -p "$PROJECT_ROOT/audio/$fifo" ]]; then
            mkfifo "$PROJECT_ROOT/audio/$fifo"
        fi
    done

    # Create metadata pipe for shairport-sync (if not exists)
    # Note: shairport-sync will also create this, but we ensure it exists
    if [[ ! -p "$PROJECT_ROOT/audio/shairport-metadata" ]]; then
        mkfifo "$PROJECT_ROOT/audio/shairport-metadata"
    fi

    # Remove empty/corrupt MPD database (causes "Database corrupted" on start).
    # Keep valid pre-built databases (from prepare-sd.sh) for fast incremental scan.
    local mpd_db="$PROJECT_ROOT/mpd/data/mpd.db"
    if [[ -f "$mpd_db" && ! -s "$mpd_db" ]]; then
        rm -f "$mpd_db"
    fi

    # Set ownership and permissions
    # Note: 777/666 needed because containers run with cap_drop: ALL
    # and may run as different UIDs than the host user
    chown -R "$real_uid:$real_gid" "$PROJECT_ROOT/audio" "$PROJECT_ROOT/artwork" \
        "$PROJECT_ROOT/data" "$PROJECT_ROOT/mpd" "$PROJECT_ROOT/mympd"
    chmod 750 "$PROJECT_ROOT/audio"
    chmod 755 "$PROJECT_ROOT/artwork"
    chmod 660 "$PROJECT_ROOT/audio"/*_fifo 2>/dev/null || true
    chmod 660 "$PROJECT_ROOT/audio"/shairport-metadata 2>/dev/null || true

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

    local real_user
    real_user="$(detect_real_user)"
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

        # Music library path: use pre-configured MUSIC_PATH if set by firstboot.sh,
        # otherwise auto-detect
        local music_path
        if [[ -n "${MUSIC_PATH:-}" ]]; then
            music_path="$MUSIC_PATH"
            # SKIP_MUSIC_SCAN controls the log message only — MPD still scans
            # the (empty) directory, which is a no-op. The variable signals intent
            # so deploy.sh doesn't emit a confusing "no music found" warning.
            if [[ "${SKIP_MUSIC_SCAN:-}" == "1" ]]; then
                info "Streaming-only setup — skipping music library scan"
            else
                info "Using pre-configured music path: $music_path"
            fi
        else
            music_path="$(detect_music_library)"
            if [[ -n "$music_path" ]]; then
                info "Auto-detected music library: $music_path"
            else
                music_path="/media/music"
                warn "No music library found — using default: $music_path"
                warn "Mount your music there or edit .env to set MUSIC_PATH"
            fi
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

        # Enable Tidal Connect profile on ARM (ARM-only image)
        if [[ "$IS_ARM" == "true" ]]; then
            cat >> "$ENV_FILE" <<EOF

# Docker Compose profiles (tidal-connect is ARM-only)
COMPOSE_PROFILES=tidal
EOF
        fi

        chown "$real_uid:$real_gid" "$ENV_FILE"
        info "Generated .env:"
        info "  MUSIC_PATH=$music_path"
        info "  TZ=$tz_detected"
        info "  PUID=$real_uid  PGID=$real_gid"
        info "  MPD_START_PERIOD=$mpd_start_period"
        if [[ "$IS_ARM" == "true" ]]; then
            info "  COMPOSE_PROFILES=tidal"
        fi

        apply_resource_profile "$profile"
    fi

    # Migrate existing .env: add COMPOSE_PROFILES=tidal on ARM if absent
    # (installs from before PR #99 have no COMPOSE_PROFILES key)
    if [[ "$IS_ARM" == "true" ]]; then
        if ! grep -q '^COMPOSE_PROFILES=' "$ENV_FILE" 2>/dev/null; then
            printf '\n# Docker Compose profiles (tidal-connect is ARM-only)\nCOMPOSE_PROFILES=tidal\n' >> "$ENV_FILE"
            info "Migrated .env: added COMPOSE_PROFILES=tidal for ARM"
        elif ! grep -q '^COMPOSE_PROFILES=.*tidal' "$ENV_FILE"; then
            sed -i 's/^COMPOSE_PROFILES=\(.*\)/COMPOSE_PROFILES=\1,tidal/' "$ENV_FILE"
            info "Migrated .env: added tidal to existing COMPOSE_PROFILES"
        fi
    fi

    # Enable auto-update profile if requested
    if grep -q '^AUTO_UPDATE=true' "$ENV_FILE" 2>/dev/null; then
        if grep -q '^COMPOSE_PROFILES=' "$ENV_FILE"; then
            # Append auto-update to existing profiles (if not already present)
            if ! grep -q 'auto-update' "$ENV_FILE"; then
                sed -i 's/^COMPOSE_PROFILES=\(.*\)/COMPOSE_PROFILES=\1,auto-update/' "$ENV_FILE"
                info "Added auto-update to COMPOSE_PROFILES"
            fi
        else
            echo "COMPOSE_PROFILES=auto-update" >> "$ENV_FILE"
            info "Set COMPOSE_PROFILES=auto-update"
        fi
        ok "Watchtower auto-update enabled"
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

    # COMPOSE_PROFILES in .env controls which services are active (e.g. tidal
    # profile on ARM). docker compose pull respects profiles automatically.
    local services
    mapfile -t services < <(docker compose config --services)
    if [[ ${#services[@]} -eq 0 ]]; then
        error "No services returned from docker compose config — check compose file"
        exit 1
    fi
    local total=${#services[@]}
    local count=0

    for svc in "${services[@]}"; do
        count=$((count + 1))
        info "Pulling $svc ($count/$total)"
        local pull_ok=false
        local delays=(0 10 30)  # retry after 10s, 30s
        for delay in "${delays[@]}"; do
            [[ $delay -gt 0 ]] && { info "Retrying $svc in ${delay}s..."; sleep "$delay"; }
            if docker compose pull "$svc" 2>&1 | tail -5; then
                pull_ok=true
                break
            fi
        done
        if [[ "$pull_ok" != "true" ]]; then
            # metadata has a build: directive — fall back to local build
            if [[ "$svc" == "metadata" ]]; then
                info "Building metadata locally (not yet on registry)"
                if ! docker compose build metadata; then
                    error "Failed to build metadata image"
                    exit 1
                fi
            else
                error "Failed to pull $svc after 3 attempts"
                exit 1
            fi
        fi
    done

    ok "All $total images ready"
}

start_services() {
    step "Starting services"
    cd "$PROJECT_ROOT"

    # COMPOSE_PROFILES in .env controls which services are active.
    # docker compose up -d starts all services matching active profiles.
    info "Starting containers..."
    if ! docker compose up -d; then
        error "Failed to start services"
        exit 1
    fi
    ok "Services started"
}

verify_services() {
    step "Verifying services"

    # Derive expected services from active compose config (respects profiles)
    local expected_services
    mapfile -t expected_services < <(docker compose config --services)
    if [[ ${#expected_services[@]} -eq 0 ]]; then
        error "No services returned from docker compose config — check compose file"
        exit 1
    fi
    # Use MPD_START_PERIOD from .env (default 30s) to set verification timeout.
    # NFS mounts may need 300s for MPD to become healthy.
    local start_period
    start_period=$(grep '^MPD_START_PERIOD=' "$ENV_FILE" 2>/dev/null | cut -d= -f2 | tr -d 's')
    start_period=${start_period:-30}
    local wait_seconds=15
    local max_attempts=$(( (start_period / wait_seconds) + 2 ))
    local attempt=1

    info "Checking services (up to ${start_period}s, ${wait_seconds}s interval)..."

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
    echo "    Metadata WS:   ws://${ip}:8082"
    echo "    Artwork HTTP:  http://${ip}:8083"
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
# Version Tracking
#######################################

# Detect version from git tag or .version file
_detect_version() {
    local version=""
    if command -v git >/dev/null 2>&1 && git -C "$PROJECT_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
        version=$(git -C "$PROJECT_ROOT" describe --tags --abbrev=0 2>/dev/null || true)
        version="${version#v}"
    fi
    if [[ -z "$version" ]] && [[ -f "$PROJECT_ROOT/.version" ]]; then
        version=$(cat "$PROJECT_ROOT/.version")
    fi
    echo "$version"
}

# Write SNAPMULTI_VERSION to .env (called early so metadata container gets it).
# Does NOT write .version file — that's done by write_version after verify.
write_version_to_env() {
    local version
    version=$(_detect_version)
    if [[ -n "$version" ]] && [[ -f "$ENV_FILE" ]]; then
        if grep -q '^SNAPMULTI_VERSION=' "$ENV_FILE" 2>/dev/null; then
            sed -i "s|^SNAPMULTI_VERSION=.*|SNAPMULTI_VERSION=$version|" "$ENV_FILE"
        else
            echo "SNAPMULTI_VERSION=$version" >> "$ENV_FILE"
        fi
        info "Version: $version"
    fi
}

# Record deployed version to .version file (called after successful verify).
write_version() {
    local version
    version=$(_detect_version)
    if [[ -n "$version" ]]; then
        echo "$version" > "$PROJECT_ROOT/.version"
    else
        warn "Could not determine version (no git tag, no .version file)"
    fi
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
    write_version_to_env
    validate_config
    pull_images
    start_services
    verify_services
    write_version

    show_status
}

main "$@"
