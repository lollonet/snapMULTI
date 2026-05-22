#!/usr/bin/env bash
# snapMULTI deployment script
# Bootstraps a fresh Linux machine as a snapMULTI server.
# Usage: sudo ./scripts/deploy.sh [--profile minimal|standard|performance]
set -euo pipefail

#######################################
# Common Utilities
#######################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# When run by firstboot, UNIFIED_LOG is set and firstboot handles logging
# via pipe. Prevent unified-log.sh from writing directly to the log file
# (which causes duplicate lines with [unknown] source).
if [[ -n "${UNIFIED_LOG:-}" ]]; then
    export SNAPMULTI_FIRSTBOOT_CHAIN=1
    export LOG_SOURCE="deploy"
    export UNIFIED_LOG="/dev/null"
fi

# shellcheck source=common/logging.sh
source "$SCRIPT_DIR/common/logging.sh"

# unified-log.sh (transitively sourced by logging.sh) already defines
# log_info / log_warn / log_error / log_ok plus the info / warn / error
# back-compat aliases. The source guard in unified-log.sh makes the
# re-source attempted by pull-images.sh a no-op, so no manual wrappers
# are needed here.

# shellcheck source=common/system-tune.sh
source "$SCRIPT_DIR/common/system-tune.sh"
# shellcheck source=common/resource-detect.sh
source "$SCRIPT_DIR/common/resource-detect.sh"
# shellcheck source=common/pull-images.sh
source "$SCRIPT_DIR/common/pull-images.sh"
# shellcheck source=common/systemd-snippets.sh
source "$SCRIPT_DIR/common/systemd-snippets.sh"
# Guarded source: custom-built trees without the helper fall through to
# the legacy IMAGE_TAG-only path. Inline `derive_image_tag` fallback
# below preserves today's behaviour when the file is absent.
if [[ -f "$SCRIPT_DIR/common/release-manifest.sh" ]]; then
    # shellcheck source=common/release-manifest.sh
    source "$SCRIPT_DIR/common/release-manifest.sh"
else
    # Minimal inline shim — only derive_image_tag is consumed below.
    derive_image_tag() {
        local e="${1:-}" f="${2:-}"
        e="${e#"${e%%[![:space:]]*}"}"; e="${e%"${e##*[![:space:]]}"}"
        f="${f#"${f%%[![:space:]]*}"}"; f="${f%"${f##*[![:space:]]}"}"
        if [[ -n "$e" ]]; then printf '%s\n' "$e"
        elif [[ -n "$f" ]]; then printf '%s\n' "$f"
        else printf 'latest\n'; fi
    }
fi

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

    printf '[INFO] Scanning for music libraries...\n' >&2

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
                printf '[INFO]   Found: %s (%s audio files)\n' "$dir" "$count" >&2
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
    # Use shared hardware detection (resource-detect.sh)
    detect_hardware

    [[ -n "$DETECTED_PI_MODEL" ]] && info "Detected: $DETECTED_PI_MODEL"
    info "Hardware: ${DETECTED_RAM_MB}MB RAM, ${DETECTED_CPU_CORES} CPU cores"

    if [[ $DETECTED_RAM_MB -lt 512 ]]; then
        warn "Only ${DETECTED_RAM_MB}MB RAM — server needs at least 512MB, expect OOM issues"
    fi

    detect_profile_from_hardware 8000  # server: 8GB+ for performance (more services)
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
# 2026-05-12 fleet measurements (pi4-test, NFS library): MPD steady-state
#   200 MB observed once cache warms → 256 MB limit → 78 % utilisation, too tight.
#   Headroom check: 1895 MB total RAM, sum of limits previously 1120 MB +
#   200 MB host overhead = 1320 MB worst-case; raising MPD by 128 MB still
#   leaves ~450 MB free in the worst case. Bumped to 384 MB for safety.
SNAPSERVER_MEM_LIMIT=192M
SNAPSERVER_MEM_RESERVE=96M
SNAPSERVER_CPU_LIMIT=1.0
AIRPLAY_MEM_LIMIT=64M
AIRPLAY_MEM_RESERVE=32M
AIRPLAY_CPU_LIMIT=0.5
SPOTIFY_MEM_LIMIT=256M
SPOTIFY_MEM_RESERVE=128M
SPOTIFY_CPU_LIMIT=0.5
MPD_MEM_LIMIT=384M
MPD_MEM_RESERVE=192M
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

    # Warn if memory reserves exceed available RAM
    local total_reserve_mb=0
    while IFS='=' read -r key val; do
        if [[ "$key" == *_MEM_RESERVE ]]; then
            total_reserve_mb=$(( total_reserve_mb + ${val%M} ))
        fi
    done < <(grep '_MEM_RESERVE=' "$ENV_FILE")
    local avail_mb
    avail_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null) || true
    if [[ -n "$avail_mb" && "$total_reserve_mb" -gt "$avail_mb" ]]; then
        warn "Memory reserves (${total_reserve_mb}M) exceed available RAM (${avail_mb}M)"
        warn "Containers may be OOM-killed. Consider 'minimal' profile."
    fi

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

setup_server_host() {
    step "System dependencies"

    # Shared host bootstrap — packages, locale, avahi, monitoring
    # Skip apt upgrade in standalone deploy (only firstboot does full upgrade)
    # shellcheck source=common/install-deps.sh
    source "$SCRIPT_DIR/common/install-deps.sh"

    # Skip the full install_dependencies pass when firstboot has already
    # provisioned the host (PROGRESS_MANAGED=1). install-deps.sh is
    # idempotent, but on Pi Zero 2W the redundant `apt-get update` + dpkg
    # checks add ~30-60 s and risk transient ENOSPC on the small tmpfs.
    # Mirrors the guard in client/common/scripts/setup.sh:474.
    if [[ -n "${PROGRESS_MANAGED:-}" ]] \
       && command -v docker &>/dev/null \
       && command -v curl &>/dev/null \
       && command -v avahi-daemon &>/dev/null; then
        info "Skipping install_dependencies — firstboot already provisioned the host (PROGRESS_MANAGED=${PROGRESS_MANAGED})"
    else
        INSTALL_ROLE=server SKIP_UPGRADE=true install_dependencies
    fi

    # Server-specific tuning (not package management)
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

    # Check Docker Compose (v2+ required for profiles, --status, config --services)
    if docker compose version >/dev/null 2>&1; then
        local _compose_ver
        _compose_ver=$(docker compose version --short 2>/dev/null)
        info "Docker Compose: $_compose_ver"
        # Strip leading 'v' and compare major version
        local _compose_major="${_compose_ver#v}"
        _compose_major="${_compose_major%%.*}"
        if [[ "$_compose_major" -lt 2 ]]; then
            error "Docker Compose v2+ required (found $_compose_ver)"
            error "Update: sudo apt-get install docker-compose-plugin"
            exit 1
        fi
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

    # Preserve fuse-overlayfs if already configured (firstboot pre-sets it
    # for read-only installs so images land with the correct driver).
    # Otherwise keep Docker's default overlay2.
    #
    # Two ways to detect "we need fuse-overlayfs":
    #  (a) docker info returns "fuse-overlayfs" — daemon up, current config OK
    #  (b) `/` is overlay (overlayroot active) — even if Docker is currently
    #      stopped (e.g. mid-redeploy), we MUST preserve the storage-driver
    #      setting in daemon.json. Without case (b), a redeploy on overlayroot
    #      while Docker is briefly down would let tune_docker_daemon strip
    #      the storage-driver key (the `cfg.pop` branch in system-tune.sh),
    #      Docker would restart with overlay2 default, and previously-pulled
    #      images would silently disappear.
    local _tune_args=(--live-restore)
    if docker info --format '{{.Driver}}' 2>/dev/null | grep -q fuse-overlayfs \
       || mount 2>/dev/null | grep -q ' on / type overlay'; then
        _tune_args+=(--fuse-overlayfs)
    fi
    tune_docker_daemon "${_tune_args[@]}"

    # Enable and start Docker
    systemctl enable docker >/dev/null 2>&1 || true
    systemctl start docker

    # Verify Docker is running
    if ! docker info &>/dev/null; then
        error "Cannot connect to Docker daemon. Is it running?"
        exit 1
    fi

    # Enable cgroup memory controller for Docker resource limits on Pi.
    # Without this, deploy.resources.limits.memory in docker-compose.yml is
    # ignored. The helper is idempotent (grep-before-sed); detect whether
    # we actually mutated cmdline.txt by checking presence pre- and
    # post-call so we don't emit the "reboot required" warn on re-runs.
    local _cmdline _had_cgroup
    _cmdline=$(cmdline_path 2>/dev/null || true)
    if [[ -n "$_cmdline" ]]; then
        _had_cgroup=0
        grep -q "cgroup_enable=memory" "$_cmdline" 2>/dev/null && _had_cgroup=1
        if (( _had_cgroup == 0 )); then
            info "Enabling cgroup memory controller in $_cmdline..."
            cmdline_ensure_memory_cgroup
            warn "Reboot required for memory limits to take effect"
        fi
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

        # Detect music source for downstream tools (device-smoke.sh, MPD
        # backup gate, MPD start period below). Prefer the explicit
        # MUSIC_SOURCE exported by mount-music.sh; fall back to inferring
        # from the mount point so manual / pre-existing setups still get
        # a value persisted.
        local music_source_value="${MUSIC_SOURCE:-}"
        if [[ -z "$music_source_value" ]]; then
            if is_network_mount "$music_path"; then
                # is_network_mount returns true for both nfs and cifs/smb,
                # but we don't know which here — use the generic label.
                music_source_value="network"
            elif [[ "$music_path" == /media/usb-* ]] || [[ "$music_path" == /mnt/usb* ]]; then
                music_source_value="usb"
            else
                music_source_value="local"
            fi
        fi

        # MPD start period: extend to 5 min for network-backed libraries
        # so the healthcheck doesn't trip while NFS/SMB attaches and MPD
        # scans. Decision MUST come from music_source_value (authoritative
        # at install time) — not from is_network_mount, which probes the
        # live mount and returns false during firstboot when the NFS
        # mount timed out (fstab is set, retry will succeed on next boot).
        local mpd_start_period="30s"
        case "$music_source_value" in
            nfs|smb|network)
                mpd_start_period="300s"
                info "Network-backed library ($music_source_value) — using extended MPD start period (5 min)"
                ;;
            *)
                info "Local storage ($music_source_value) — using standard MPD start period (30s)"
                ;;
        esac

        # Generate .env
        cat > "$ENV_FILE" <<EOF
# snapMULTI Environment Configuration
# Generated by deploy.sh on $(date -Iseconds)

# Music library path
MUSIC_PATH=$music_path

# Music source kind (nfs, smb, usb, streaming-only, local, network).
# Used by device-smoke.sh to decide whether to validate the library
# (network sources can be silently empty if the share isn't mounted)
# and by the MPD backup timer to decide whether to copy mpd.db across
# reflashes (only meaningful for network-backed libraries).
MUSIC_SOURCE=$music_source_value

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

    # Ensure COMPOSE_PROFILES includes required profiles
    ensure_profile() {
        local profile="$1"
        if ! grep -q '^COMPOSE_PROFILES=' "$ENV_FILE" 2>/dev/null; then
            printf '\n# Docker Compose profiles\nCOMPOSE_PROFILES=%s\n' "$profile" >> "$ENV_FILE"
        elif ! grep -q "^COMPOSE_PROFILES=.*${profile}" "$ENV_FILE"; then
            sed -i "s/^COMPOSE_PROFILES=\(.*\)/COMPOSE_PROFILES=\1,${profile}/" "$ENV_FILE"
        else
            return 0
        fi
        info "Enabled profile: $profile"
    }

    # Tidal Connect is ARM-only
    if [[ "$IS_ARM" == "true" ]]; then
        ensure_profile "tidal"
    else
        info "Tidal Connect skipped (ARM-only, current arch: $(uname -m))"
    fi

    # Persist release identity (SNAPMULTI_RELEASE + SNAPMULTI_IMAGE_SET
    # + IMAGE_TAG). Values come from firstboot via env vars — deploy
    # does NOT re-read install.conf or the manifest (firstboot is
    # authoritative for the precedence chain). The IMAGE_TAG line is
    # always written via derive_image_tag so a stale value in an
    # existing .env is overwritten coherently instead of being trusted
    # as input to the chain.
    local _release="${SNAPMULTI_RELEASE:-}"
    local _image_set="${SNAPMULTI_IMAGE_SET:-}"
    local _coherent_tag
    _coherent_tag=$(derive_image_tag "${IMAGE_TAG:-}" "$_image_set")

    # awk -v avoids sed metacharacter corruption; temp-file mv is atomic
    persist_env_kv() {
        local key="$1" value="$2"
        if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
            awk -v k="$key" -v v="$value" '
                BEGIN { pat = "^" k "=" }
                $0 ~ pat { print k "=" v; next }
                { print }
            ' "$ENV_FILE" > "${ENV_FILE}.tmp" \
                && mv -- "${ENV_FILE}.tmp" "$ENV_FILE"
        else
            printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
        fi
    }

    # SNAPMULTI_RELEASE / SNAPMULTI_IMAGE_SET always persisted so smoke
    # and diagnostic surface the live release identity; empty values are
    # still written (downstream readers treat empty as "unknown").
    persist_env_kv "SNAPMULTI_RELEASE" "$_release"
    persist_env_kv "SNAPMULTI_IMAGE_SET" "$_image_set"

    # IMAGE_TAG only persisted when non-default (preserves the existing
    # "latest is the implicit default in docker-compose.yml" pattern).
    if [[ "$_coherent_tag" != "latest" ]]; then
        persist_env_kv "IMAGE_TAG" "$_coherent_tag"
        info "IMAGE_TAG=$_coherent_tag"
    fi
    if [[ -n "$_release" || -n "$_image_set" ]]; then
        info "Release $_release (images $_image_set)"
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

    _pull_progress() {
        # Under firstboot, deploy.sh routes its normal logger to /dev/null
        # to avoid duplicate writes. Keep image-pull milestones visible to
        # firstboot's pipe filter so the HDMI/log output does not appear
        # frozen during the longest install phase.
        if [[ "${SNAPMULTI_FIRSTBOOT_CHAIN:-0}" == "1" ]]; then
            printf '[INFO] %s\n' "$*"
        fi
        info "$*"
    }

    # Metadata build fallback: if pull fails for metadata service, build locally
    _metadata_fallback() {
        local svc="$1"
        if [[ "$svc" == "metadata" ]]; then
            info "Building metadata locally (not yet on registry)"
            if ! docker compose build metadata; then
                error "Failed to build metadata"
                return 1
            fi
            return 0
        fi
        return 1
    }

    # Use shared pull module (2 GB minimum for server)
    if ! pull_compose_images _pull_progress 2048 _metadata_fallback; then
        exit 1
    fi
    ok "All images ready"
}

start_services() {
    step "Starting services"
    cd "$PROJECT_ROOT"

    # Pre-flight: check host ports are available before compose up.
    # All snapMULTI services bind directly to the host (network_mode: host),
    # so a port collision with a foreign daemon manifests as a mysterious
    # container crash at startup. Catch it early with a friendly message.
    #
    # Ports covered (must mirror docs/USAGE.md "Port conflicts" list):
    #   1704  snapcast streaming
    #   1705  snapcast JSON-RPC
    #   1780  snapweb UI
    #   2019  tidal-connect TCP control
    #   4953  snapserver TCP input source
    #   5000  shairport-sync RTSP
    #   5858  meta_shairport cover-art HTTP
    #   6600  MPD
    #   8000  MPD HTTP audio stream (direct access)
    #   8082  metadata-service WebSocket
    #   8083  metadata-service HTTP
    #   8180  myMPD
    #   24879 go-librespot WebSocket API (localhost only, but listed for completeness)
    local _port_conflict=false
    for port in 1704 1705 1780 2019 4953 5000 5858 6600 8000 8082 8083 8180 24879; do
        if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            local _holder
            _holder=$(ss -tlnp 2>/dev/null | grep ":${port} " | awk '{print $NF}' | head -1)
            warn "Port $port already in use by $_holder"
            _port_conflict=true
        fi
    done
    if [[ "$_port_conflict" == "true" ]]; then
        warn "Port conflicts detected — services may fail to start"
    fi

    # COMPOSE_PROFILES in .env controls which services are active.
    # docker compose up -d starts all services matching active profiles.
    #
    # --force-recreate is required: deploy.sh writes (or rewrites) .env
    # right before this call, and Docker Compose does NOT consider
    # deploy.resources.limits.memory part of the recreate-hash. Without
    # --force-recreate, a container that's already running keeps the
    # memory limit it had at first creation (often unlimited from the
    # initial firstboot), and subsequent .env tweaks silently never
    # apply. CPU limits go through HostConfig.NanoCpus and ARE applied,
    # which made the drift invisible until inspected with
    # `docker inspect ... HostConfig.Memory`.
    # Prefer the systemd unit when it's already installed (normal
    # firstboot flow: install_systemd_service ran first). systemctl start
    # triggers ExecStart=`docker compose up -d` AND the mDNS self-heal
    # ExecStartPost. Fall back to raw compose only when the unit isn't
    # registered yet (e.g. manual `deploy.sh` from a dev host or tests).
    info "Launching docker compose (containers will start and become healthy in 30-60s)..."
    if systemctl list-unit-files snapmulti-server.service --no-legend 2>/dev/null | grep -q snapmulti-server.service; then
        # `up -d --force-recreate` (NOT `compose down`) so ExecStart picks up the new .env without a 30-40 s network teardown; `|| true` covers fresh installs with no compose project yet.
        docker compose up -d --force-recreate >/dev/null 2>&1 || true
        info "Handing over to systemd (snapmulti-server.service)..."
        if ! systemctl start snapmulti-server.service; then
            error "Failed to start snapmulti-server.service"
            exit 1
        fi
    else
        if ! docker compose up -d --force-recreate; then
            error "Failed to start services"
            exit 1
        fi
    fi
    ok "Services started"
}

verify_services() {
    step "Verifying services"

    # Verify timeout is decoupled from MPD_START_PERIOD: the healthcheck
    # (TCP ping on 6600) does not wait for library scan, but Pi 4/Zero during
    # firstboot has cold caches + post-pull I/O contention that can delay MPD's
    # listener bind beyond 120s (observed on pi4-test Pi 4 2GB --both:
    # 130-150s needed). Floor at 180s for local mounts; honor extended
    # MPD_START_PERIOD for network mounts (NFS/SMB).
    local start_period
    start_period=$(grep '^MPD_START_PERIOD=' "$ENV_FILE" 2>/dev/null | cut -d= -f2 | tr -d 's')
    start_period=${start_period:-30}
    local wait_seconds=15
    local floor_seconds=180
    local effective=$(( start_period > floor_seconds ? start_period : floor_seconds ))
    local max_attempts=$(( (effective / wait_seconds) + 2 ))

    info "Checking services (up to ${effective}s, ${wait_seconds}s interval)..."

    # shellcheck source=common/verify-compose.sh
    source "$SCRIPT_DIR/common/verify-compose.sh"
    verify_compose_stack "$PROJECT_ROOT/docker-compose.yml" "server" "$max_attempts" "$wait_seconds"
}

show_status() {
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="<server-ip>"

    echo ""
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
}

#######################################
# Systemd Service
#######################################

install_systemd_service() {
    step "Installing systemd service"

    # Resolve the persisted music path so the systemd unit can wait for
    # the actual NFS/SMB/USB mount before starting compose. Without this,
    # MPD/myMPD can come up bound to an empty bind-mount source and the
    # library silently appears empty until manual restart.
    #
    # Source of truth precedence:
    #   1. MUSIC_SOURCE in .env (set by mount-music.sh during firstboot) —
    #      authoritative because at install time the NFS/SMB mount may
    #      not be active yet (NAS slow, mount timed out), so a runtime
    #      df -T probe would see the underlying ext4 and skip the wait
    #      clause for exactly the case we wanted to cover.
    #   2. is_network_mount runtime probe — fallback for manual deploys
    #      without mount-music.sh (no MUSIC_SOURCE recorded).
    # Music library mount handling:
    #   - Network sources (nfs / smb): use systemd .automount (set up by
    #     mount-music.sh). These are LAZY — the actual mount fires on first
    #     access from inside MPD's container, not at boot. Do NOT add the
    #     mount path to RequiresMountsFor: a hard dependency would block
    #     snapserver / Spotify / AirPlay / Snapcast startup whenever the
    #     NAS is slow or unreachable, even though those services don't
    #     touch the music library at all.
    #   - Local sources (usb / direct): the kernel mounts these at boot,
    #     no extra wait required for compose start.
    #   - Manual / unknown: a runtime probe used to add network-backed
    #     paths to RequiresMountsFor; that path is now also handled by
    #     the automount and intentionally left out of the unit clause.
    local music_mount_clause=""
    local music_path_from_env=""
    local music_source_from_env=""
    if [[ -f "$ENV_FILE" ]]; then
        music_path_from_env=$(grep -m1 '^MUSIC_PATH=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
        music_source_from_env=$(grep -m1 '^MUSIC_SOURCE=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
    fi
    if [[ -n "$music_path_from_env" ]] \
       && [[ "$music_path_from_env" != "${PROJECT_ROOT}"* ]]; then
        case "$music_source_from_env" in
            nfs|smb|network)
                info "MUSIC_SOURCE=$music_source_from_env — using systemd .automount (lazy), NOT adding $music_path_from_env to RequiresMountsFor"
                ;;
            "")
                if is_network_mount "$music_path_from_env"; then
                    info "Runtime probe: $music_path_from_env is network-backed — using lazy mount, NOT adding to RequiresMountsFor"
                fi
                ;;
            *)
                # Local source (usb / local) — kernel mounts these at boot.
                ;;
        esac
    fi

    cat > /etc/systemd/system/snapmulti-server.service <<EOF
[Unit]
Description=snapMULTI Docker Compose Server
Requires=docker.service
After=docker.service network-online.target avahi-daemon.service
Wants=network-online.target avahi-daemon.service
# Block startup until project root + /audio (FIFO dir) are mounted; avoids
# a Docker race where compose starts before NFS/USB attaches /music or /audio
RequiresMountsFor=${PROJECT_ROOT} ${PROJECT_ROOT}/audio${music_mount_clause}
# NOTE on snapcast 0.35 mDNS reconnect bug: when avahi-daemon restarts,
# snapserver's libavahi-client connection drops and the daemon never
# re-publishes \`_snapcast._tcp\`. We previously used
# PartOf=avahi-daemon.service to propagate avahi restarts to this unit,
# but that gave Avahi full lifecycle control over the audio stack: a
# routine avahi reload (config tune, hotplug, regulatory) tore the
# whole stack down. The correct fix is to leave systemd's coupling
# alone (Wants/After only) and recover mDNS via the ExecStartPost
# self-heal below at start time. If avahi is restarted at runtime,
# the operator must follow with \`systemctl restart snapmulti-server\`
# to refresh the mDNS publish — \`tune_avahi_daemon\` and the install
# scripts do this explicitly.

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${PROJECT_ROOT}
$(docker_info_ready_execstartpre)
# Wait for avahi-daemon to be fully ready before \`docker compose up\`.
# Without this, snapserver's libavahi-client connect race-loses against
# avahi-daemon initialisation and falls back to PTR-only UDP 5353
# multicast — strict mDNS clients (Python zeroconf, dns-sd, snapclient
# 0.36+) fail to discover the service. \`is-active\` gates on systemd
# state; the socket existence proves the dbus listener is up; the final
# \`sleep 2\` lets avahi publish its first announce. Non-fatal on
# unusual setups (no avahi installed) — falls through after 30 s.
$(avahi_daemon_ready_execstartpre)
# Detect-and-recreate on mem_limit drift, symmetric to snapclient.service
# (PR #393). The first compose up during firstboot runs BEFORE the final
# reboot that activates cgroup memory v2 (cmdline_ensure_memory_cgroup
# patches cmdline.txt but takes effect only after reboot). So even though
# deploy.sh:921 invokes \`docker compose up -d --force-recreate\`, the
# resulting containers are created without cgroup memory v2 →
# HostConfig.Memory=0. The next \`systemctl start\` (after reboot) runs
# plain \`compose up -d\`, which is idempotent on existing containers and
# keeps the limit-less ones. We probe snapserver (representative of the
# stack — they're all created together) and force-recreate the whole
# compose project exactly once when drift is detected. Empty inspect
# output (fresh reflash, no container yet) returns "", neither "0" nor a
# byte count, so the recreate is skipped — ExecStart will create the
# containers fresh with proper limits.
$(mem_drift_recreate_execstartpre snapserver "${PROJECT_ROOT}")
ExecStart=/usr/bin/docker compose up -d
# Self-heal mDNS publish race: 12 s after compose up, query the local
# avahi cache for \`_snapcast._tcp\`. If the PTR record is present but
# the SRV/TXT records are NOT, snapserver lost the libavahi-client race
# at startup and is now stuck publishing PTR-only via raw UDP 5353
# multicast. Restart the snapserver container — its
# fresh libavahi-client connection succeeds because avahi is now
# stable. avahi-browse exit code is 1 if no records are found at all
# (timeout), so we anchor on the SRV/TXT presence specifically.
# Use \`-prt\` (no \`-l\`): the \`l\` flag is --ignore-local, which would
# exclude services published by THIS host's avahi-daemon — exactly the
# records we need to inspect. Same convention as device-smoke.sh and
# discover-server.sh, which both omit \`-l\` for this reason.
# All non-fatal: failures here must not hold the unit in failed state.
ExecStartPost=-/bin/bash -c '\\
    sleep 12; \\
    if command -v avahi-browse >/dev/null 2>&1; then \\
        out=\$(avahi-browse -prt _snapcast._tcp 2>/dev/null || true); \\
        if echo "\$out" | grep -qE "^[+];.*;_snapcast[.]_tcp" \\
           && ! echo "\$out" | grep -qE "^=;.*;_snapcast[.]_tcp"; then \\
            logger -t snapmulti-server "mDNS PTR-only detected, restarting snapserver to recover SRV+TXT publish"; \\
            /usr/bin/docker compose -f ${PROJECT_ROOT}/docker-compose.yml restart snapserver >/dev/null 2>&1 || true; \\
        fi; \\
    fi'
# Non-destructive stop: \`compose stop\` halts the processes inside the
# containers (5 s grace) and leaves the container objects + compose
# network in place, so a subsequent \`systemctl start\` re-enters
# ExecStart=\`compose up -d\` and simply \`start\`s the existing
# containers — no rebuild, no network teardown, no image re-pull. A
# \`systemctl restart\` therefore costs 2-5 s of audio silence instead
# of the 30-40 s a full \`compose down\` would cost. If the operator
# needs a destructive teardown (image upgrade, volume rebuild) they
# call \`docker compose down\` manually from \${PROJECT_ROOT}.
$(compose_stop_5s_execstop)
TimeoutStartSec=180
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    if systemctl enable snapmulti-server.service >/dev/null 2>&1; then
        ok "snapmulti-server.service enabled"
    else
        warn "snapmulti-server.service could not be enabled"
    fi
}

#######################################
# Version Tracking
#######################################

# Detect version from git tag or .version file
_detect_version() {
    local version=""
    if command -v git >/dev/null 2>&1 && git -C "$PROJECT_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
        version=$(git -C "$PROJECT_ROOT" describe --tags --abbrev=0 2>/dev/null || true)
    fi
    if [[ -z "$version" ]] && [[ -f "$PROJECT_ROOT/.version" ]]; then
        version=$(cat "$PROJECT_ROOT/.version")
    fi
    echo "$version"
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
    setup_server_host
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
    # Install the systemd unit BEFORE the first compose start so that
    # `start_services` can hand off to `systemctl start
    # snapmulti-server.service` instead of running `docker compose up`
    # directly. This way the unit's ExecStartPost mDNS self-heal takes
    # effect on first boot — not just on restarts after install
    # completes.
    install_systemd_service
    start_services
    verify_services
    write_version

    show_status
}

main "$@"
