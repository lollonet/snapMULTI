#!/usr/bin/env bash
# resource-detect.sh — Hardware detection for resource profiling
# Sourced by: setup.sh (client), deploy.sh (server)
# Exports: detect_hardware() → sets DETECTED_RAM_MB, DETECTED_CPU_CORES, DETECTED_PI_MODEL, DETECTED_IS_ARM
#          detect_profile_from_hardware() → echoes minimal|standard|performance

# Source logger if not already available
if ! declare -F log_info &>/dev/null; then
    # shellcheck source=unified-log.sh
    source "$(dirname "${BASH_SOURCE[0]}")/unified-log.sh" 2>/dev/null || {
        log_info()  { echo "[INFO] $*"; }
        log_warn()  { echo "[WARN] $*" >&2; }
    }
fi

# Detect hardware: RAM, CPU cores, Pi model, architecture.
# Sets global variables for callers to use.
# shellcheck disable=SC2034  # Variables used by callers
detect_hardware() {
    # Detect RAM (in MB)
    if [[ -f /proc/meminfo ]]; then
        DETECTED_RAM_MB=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)
    else
        DETECTED_RAM_MB=$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f", $1/1024/1024}') || DETECTED_RAM_MB=4096
    fi

    # Detect CPU cores
    if [[ -f /proc/cpuinfo ]]; then
        DETECTED_CPU_CORES=$(grep -c ^processor /proc/cpuinfo)
    else
        DETECTED_CPU_CORES=$(sysctl -n hw.ncpu 2>/dev/null) || DETECTED_CPU_CORES=4
    fi

    # Detect Raspberry Pi model
    if [[ -f /proc/device-tree/model ]]; then
        DETECTED_PI_MODEL=$(tr -d '\0' < /proc/device-tree/model)
    elif [[ -f /proc/cpuinfo ]] && grep -q "Raspberry Pi" /proc/cpuinfo 2>/dev/null; then
        DETECTED_PI_MODEL=$(grep "Model" /proc/cpuinfo | cut -d: -f2 | xargs)
    else
        DETECTED_PI_MODEL=""
    fi

    # Architecture
    case "$(uname -m)" in
        aarch64|armv7l|armv6l) DETECTED_IS_ARM=true ;;
        *)                     DETECTED_IS_ARM=false ;;
    esac
}

# Determine resource profile from detected hardware.
# Call detect_hardware() first. Echoes: minimal|standard|performance
detect_profile_from_hardware() {
    local ram="${DETECTED_RAM_MB:-0}"
    local model="${DETECTED_PI_MODEL:-}"

    if [[ -n "$model" ]]; then
        case "$model" in
            *"Zero 2"*) echo "minimal"; return ;;
            *"Pi 3"*)   echo "minimal"; return ;;
            *"Pi 4"*)
                if [[ $ram -ge 4000 ]]; then echo "performance"
                else echo "standard"; fi
                return ;;
            *"Pi 5"*)   echo "performance"; return ;;
        esac
    fi

    # Generic detection (non-Pi or unknown model)
    if [[ $ram -lt 2000 ]]; then
        echo "minimal"
    elif [[ $ram -lt 4000 ]]; then
        echo "standard"
    else
        echo "performance"
    fi
}
