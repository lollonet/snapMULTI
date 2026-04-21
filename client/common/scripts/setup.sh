#!/usr/bin/env bash
set -euo pipefail

# Diagnostic dump on failure (standalone mode only — firstboot has its own trap)
_setup_failure_dump() {
    local rc=$?
    [[ $rc -eq 0 ]] && return
    stop_progress_animation 2>/dev/null || true
    echo ""
    echo "=== SETUP FAILED (exit: $rc) ==="
    echo "--- Memory ---"
    free -m 2>/dev/null || true
    echo "--- Disk ---"
    df -h / /opt 2>/dev/null || true
    echo "--- Docker ---"
    docker ps -a --format 'table {{.Names}}\t{{.Status}}' 2>/dev/null || true
    echo "=== END DIAGNOSTIC DUMP ==="
}
trap _setup_failure_dump EXIT

# Suppress locale warnings from apt and other tools; avoids stdout pollution
# in functions called via $() substitution.
export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# ============================================
# Auto mode: --auto [config_file]
# Reads settings from config file, skips all prompts.
# HAT auto-detection via EEPROM when AUDIO_HAT=auto.
#
# Optional flags:
#   --no-readonly  Disable read-only filesystem (default: enabled)
# ============================================
AUTO_MODE=false
AUTO_CONFIG=""
ENABLE_READONLY=true
NEEDS_REBOOT=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto)
            AUTO_MODE=true
            if [[ $# -gt 1 && "$2" != --* ]]; then
                AUTO_CONFIG="$2"
                shift 2
            else
                AUTO_CONFIG=""
                shift
            fi
            ;;
        --read-only)
            ENABLE_READONLY=true
            shift
            ;;
        --no-readonly)
            ENABLE_READONLY=false
            shift
            ;;
        *) shift ;;
    esac
done

if [ "$AUTO_MODE" = true ]; then
    if [ -n "$AUTO_CONFIG" ] && [ -f "$AUTO_CONFIG" ]; then
        # Validate config path (prevent path traversal and injection)
        if [[ ! "$AUTO_CONFIG" =~ ^[a-zA-Z0-9_./-]+$ ]]; then
            echo "Error: Invalid characters in config path: $AUTO_CONFIG"
            exit 1
        fi
        # Reject path traversal attempts
        if [[ "$AUTO_CONFIG" == *".."* ]]; then
            echo "Error: Path traversal not allowed in config path: $AUTO_CONFIG"
            exit 1
        fi
        # Resolve to absolute path and verify it exists
        AUTO_CONFIG_REAL=$(realpath -e "$AUTO_CONFIG" 2>/dev/null) || {
            echo "Error: Config file not found: $AUTO_CONFIG"
            exit 1
        }
        # shellcheck source=/dev/null
        source "$AUTO_CONFIG_REAL"
    fi
    # Defaults for auto mode (can be overridden by config file)
    AUDIO_HAT="${AUDIO_HAT:-auto}"
    DISPLAY_RESOLUTION="${DISPLAY_RESOLUTION:-}"
    BAND_MODE="${BAND_MODE:-third-octave}"
    SNAPSERVER_HOST="${SNAPSERVER_HOST:-}"
    # ENABLE_READONLY: command line --read-only takes precedence, then config file
    if [[ "$ENABLE_READONLY" != "true" ]]; then
        ENABLE_READONLY="${ENABLE_READONLY:-false}"
    fi
fi

# Source shared system tuning functions early (needed throughout the script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_MODULE_DIR=""
for _mod_candidate in \
    "$SCRIPT_DIR/common" \
    "$SCRIPT_DIR/../scripts/common" \
    "$(dirname "$0")/common"; do
    if [[ -d "$_mod_candidate" ]]; then
        COMMON_MODULE_DIR="$_mod_candidate"
        break
    fi
done
if [[ -n "$COMMON_MODULE_DIR" ]]; then
    # shellcheck source=common/system-tune.sh
    [[ -f "$COMMON_MODULE_DIR/system-tune.sh" ]] && source "$COMMON_MODULE_DIR/system-tune.sh"
    # shellcheck source=common/resource-detect.sh
    [[ -f "$COMMON_MODULE_DIR/resource-detect.sh" ]] && source "$COMMON_MODULE_DIR/resource-detect.sh"
    # shellcheck source=common/pull-images.sh
    [[ -f "$COMMON_MODULE_DIR/pull-images.sh" ]] && source "$COMMON_MODULE_DIR/pull-images.sh"
fi

echo "========================================="
echo "Raspberry Pi Snapclient Setup Script"
echo "With Audio HAT and Cover Display Support"
if [ "$AUTO_MODE" = true ]; then
    echo "  Mode: AUTO (non-interactive)"
fi
echo "========================================="
echo ""

# ============================================
# Progress display (auto mode only)
# ============================================
# When PROGRESS_MANAGED=1 (set by firstboot.sh), the parent script owns the
# /dev/tty1 display. We only write log messages to the parent's PROGRESS_LOG
# and skip all tty1 rendering to avoid display "bouncing."
#
# Sources the shared progress.sh library (same code as firstboot.sh uses)
# instead of duplicating ~170 lines of progress rendering code.
PROGRESS_MANAGED="${PROGRESS_MANAGED:-}"

# Log file: use parent's if PROGRESS_MANAGED, otherwise our own
if [[ -n "$PROGRESS_MANAGED" ]]; then
    PROGRESS_LOG="${PROGRESS_LOG:-/tmp/snapmulti-progress.log}"
else
    PROGRESS_LOG="/tmp/snapclient-progress.log"
    : > "$PROGRESS_LOG"
fi

if [[ "$AUTO_MODE" == true ]]; then
    # Step definitions for client setup
    # shellcheck disable=SC2034
    STEP_NAMES=("System dependencies" "Docker CE" "Audio HAT config"
                "ALSA loopback" "Boot settings" "Docker environment"
                "Security hardening" "Systemd service" "Read-only filesystem"
                "Pulling images")
    # Weights reflect actual duration (Pull=40%, Docker=33%, Deps=12%, RO=5%, rest=10%)
    # shellcheck disable=SC2034
    STEP_WEIGHTS=(12 33 2 2 2 2 2 3 5 37)
    # Title for standalone TUI (overridden by firstboot.sh when PROGRESS_MANAGED)
    # shellcheck disable=SC2034
    PROGRESS_TITLE="Snapclient Auto-Install"

    # Source shared progress library (provides render_progress, start/stop
    # animation, progress, progress_complete, milestone, log_progress).
    # When PROGRESS_MANAGED=1, the shared library's render_progress writes
    # to the parent's PROGRESS_LOG only (tty1 is owned by firstboot.sh).
    _progress_sourced=false
    for _progress_candidate in \
        "$SCRIPT_DIR/common/progress.sh" \
        "$SCRIPT_DIR/../scripts/common/progress.sh" \
        "$(dirname "$0")/common/progress.sh"; do
        # shellcheck source=common/progress.sh
        if [[ -f "$_progress_candidate" ]]; then
            source "$_progress_candidate"
            progress_init 2>/dev/null || true
            _progress_sourced=true
            break
        fi
    done
    if [[ "$_progress_sourced" != true ]]; then
        echo "WARNING: progress.sh not found — TUI disabled"
    fi
    unset _progress_sourced _progress_candidate
fi

# Define no-op stubs for any functions not yet defined (interactive mode,
# or progress.sh not found). This ensures progress/log_progress calls
# throughout the script never fail.
declare -F progress_init &>/dev/null       || progress_init() { :; }
declare -F render_progress &>/dev/null     || render_progress() { :; }
declare -F log_progress &>/dev/null        || log_progress() { echo "$*" >> "$PROGRESS_LOG"; }
declare -F start_progress_animation &>/dev/null || start_progress_animation() { :; }
declare -F stop_progress_animation &>/dev/null  || stop_progress_animation() { :; }
declare -F progress &>/dev/null            || progress() { :; }
declare -F progress_complete &>/dev/null   || progress_complete() { :; }
declare -F milestone &>/dev/null           || milestone() { :; }

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root: sudo bash setup.sh"
    exit 1
fi

# Get the script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
COMMON_DIR="$PROJECT_DIR/common"
# Fallback: if common/ doesn't exist, check if the install dir has audio-hats
# (happens when running from /opt/snapclient/scripts/ via firstboot)
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
if [[ ! -d "$COMMON_DIR" ]]; then
    if [[ -d "$INSTALL_DIR/audio-hats" ]]; then
        COMMON_DIR="$INSTALL_DIR"
    elif [[ -d "$PROJECT_DIR/audio-hats" ]]; then
        COMMON_DIR="$PROJECT_DIR"
    fi
fi

# Markers for idempotent config.txt edits
CONFIG_MARKER_START="# --- SNAPCLIENT SETUP START ---"
CONFIG_MARKER_END="# --- SNAPCLIENT SETUP END ---"

# ============================================
# Step 1: Select Audio HAT
# ============================================
show_hat_options() {
    echo "Select your audio HAT:"
    echo "1) HiFiBerry DAC+"
    echo "2) HiFiBerry Digi+"
    echo "3) HiFiBerry DAC2 HD"
    echo "4) IQaudio DAC+"
    echo "5) IQaudio DigiAMP+"
    echo "6) IQaudio Codec Zero"
    echo "7) Allo Boss DAC"
    echo "8) Allo DigiOne"
    echo "9) JustBoom DAC"
    echo "10) JustBoom Digi"
    echo "11) USB Audio Device"
    echo "12) HiFiBerry AMP2"
    echo "13) HiFiBerry DAC+ ADC Pro"
    echo "14) Innomaker DAC PRO"
    echo "15) Waveshare WM8960"
    echo "16) HiFiBerry DAC+ Standard (clone/no EEPROM)"
}

validate_choice() {
    local choice="$1"
    local max="$2"
    if [[ ! "$choice" =~ ^[1-9]$|^1[0-9]$ ]] || [ "$choice" -gt "$max" ]; then
        echo "Invalid choice. Please enter a number between 1 and $max."
        exit 1
    fi
}

get_hat_config() {
    local choice="$1"
    case "$choice" in
        1) echo "hifiberry-dac" ;;
        2) echo "hifiberry-digi" ;;
        3) echo "hifiberry-dac2hd" ;;
        4) echo "iqaudio-dac" ;;
        5) echo "iqaudio-digiamp" ;;
        6) echo "iqaudio-codec" ;;
        7) echo "allo-boss" ;;
        8) echo "allo-digione" ;;
        9) echo "justboom-dac" ;;
        10) echo "justboom-digi" ;;
        11) echo "usb-audio" ;;
        12) echo "hifiberry-amp2" ;;
        13) echo "hifiberry-dacplusadc" ;;
        14) echo "innomaker-dac-pro" ;;
        15) echo "waveshare-wm8960" ;;
        16) echo "hifiberry-dac-std" ;;
        *) echo "Invalid choice"; exit 1 ;;
    esac
}

# Tracks how the HAT was detected: eeprom, alsa, i2c, usb, internal, none
HAT_DETECTION_SOURCE="none"

detect_hat() {
    # Detect audio HAT automatically.
    # 1. Pi firmware reads HAT EEPROM at boot → /proc/device-tree/hat/product
    # 2. Fallback: check ALSA card names via aplay -l (requires overlay already loaded)
    # 3. Fallback: I2C bus scan for known DAC chip addresses (works without overlay)
    # 4. USB audio device check
    # 5. Final fallback: internal audio (bcm2835)
    local hat_product=""

    if [ -f /proc/device-tree/hat/product ]; then
        hat_product=$(tr -d '\0' < /proc/device-tree/hat/product)
        HAT_DETECTION_SOURCE="eeprom"
        # Log detected product for debugging
        echo "EEPROM product: '$hat_product'" >&2
        # Match EEPROM strings - patterns based on Volumio dacs.json and real devices
        # Order matters: more specific patterns first
        case "$hat_product" in
            # HiFiBerry (EEPROM: "DAC 2 HD", "HiFiBerry DAC+", "Digi+", etc.)
            # More-specific patterns first: AMP2 and DAC+ADC before generic DAC+
            *DAC*2*HD*)                                  echo "hifiberry-dac2hd"     ; return ;;
            Digi+*|*Digi\ +*|*HiFiBerry*Digi*)          echo "hifiberry-digi"        ; return ;;
            *AMP*2*|*Amp*2*)                             echo "hifiberry-amp2"        ; return ;;
            *DAC*ADC*)                                   echo "hifiberry-dacplusadc"  ; return ;;
            *HiFiBerry*DAC*|DAC+*|*DAC\ +*)             echo "hifiberry-dac"         ; return ;;
            # IQaudio/Raspberry Pi (EEPROM: "Pi-DigiAMP+", "Pi-CodecZero", "Raspberry Pi DAC Plus")
            *Pi-DigiAMP*|*DigiAMP*)                     echo "iqaudio-digiamp"       ; return ;;
            *Pi-Codec*|*CodecZero*|*Codec*Zero*)        echo "iqaudio-codec"         ; return ;;
            *Raspberry*Pi*DAC*|*IQaudio*DAC*|*IQaudIO*) echo "iqaudio-dac"           ; return ;;
            # Allo (EEPROM varies)
            *Boss*|*BOSS*)                              echo "allo-boss"             ; return ;;
            *DigiOne*|*Allo*Digi*)                      echo "allo-digione"          ; return ;;
            # JustBoom (EEPROM: "JustBoom DAC HAT", "JustBoom Digi HAT")
            *JustBoom*Digi*)                            echo "justboom-digi"         ; return ;;
            *JustBoom*DAC*|*JustBoom*Amp*)              echo "justboom-dac"          ; return ;;
            # Innomaker (EEPROM: "HiFi DAC PRO", "ES9038", or "Katana")
            *Innomaker*|*INNO*|*ES9038*|*Katana*)      echo "innomaker-dac-pro"     ; return ;;
            # Waveshare (EEPROM: "WM8960 Audio HAT")
            *WM8960*|*Waveshare*Audio*)                 echo "waveshare-wm8960"      ; return ;;
        esac
        echo "Warning: Unknown HAT product '$hat_product', falling back to USB" >&2
    fi

    HAT_DETECTION_SOURCE="alsa"
    if command -v aplay &>/dev/null; then
        local cards
        cards=$(aplay -l 2>/dev/null || true)
        case "$cards" in
            # NOTE: sndrpihifiberry is shared by hifiberry-dac, hifiberry-amp2, and
            # hifiberry-dacplusadc. Without EEPROM, use hifiberry-dacplus-std (Pi as
            # clock master) to avoid DAC+ Pro misdetection on clone boards with floating
            # GPIO3. AMP2 boards without EEPROM also work in std mode (no oscillator).
            # HiFiBerry boards ship with EEPROM so this path is rarely reached.
            *sndrpihifiberry*)  echo "hifiberry-dac-std"  ; return ;;
            # IQaudio DAC+ and DigiAMP+ both surface IQaudIODAC in ALSA. Preserve
            # exact identity via EEPROM when present; ALSA fallback resolves to the
            # compatible DAC profile only.
            *IQaudIODAC*)       echo "iqaudio-dac"        ; return ;;
            *IQaudIOCODEC*)     echo "iqaudio-codec"      ; return ;;
            *BossDAC*)          echo "allo-boss"          ; return ;;
            *sndallodigione*)   echo "allo-digione"       ; return ;;
            # JustBoom DAC and Digi share sndrpijustboomd in ALSA. Exact board
            # identity requires EEPROM; ALSA fallback resolves to the DAC profile.
            *sndrpijustboom*)   echo "justboom-dac"       ; return ;;
            *Katana*)           echo "innomaker-dac-pro"  ; return ;;
            *wm8960soundcard*)  echo "waveshare-wm8960"   ; return ;;
        esac
    fi

    # I2C bus scan: detect DAC chips by address, works even without overlay loaded.
    # Many cheap HATs (InnoMaker, Waveshare, some Allo) ship without an EEPROM, so
    # the overlay is never loaded and aplay -l never shows the card. Raw I2C probing
    # identifies the chip regardless. modprobe i2c-dev persists until reboot.
    # Known addresses:
    #   0x4C-0x4F  PCM5122 (InnoMaker HiFi DAC, IQaudio DAC+, Allo Boss, JustBoom DAC, …)
    #              NOTE: shared with TMP112, ADS1x1x, PCA9685 and other non-DAC chips.
    #              Safe on a bare Pi + DAC HAT; may false-positive on mixed I2C buses.
    #   0x1A       WM8960  (Waveshare WM8960)
    #   0x3B       WM8804  (HiFiBerry Digi, JustBoom Digi, Allo DigiOne — no EEPROM variants)
    local i2cdetect_bin="" modprobe_bin=""
    i2cdetect_bin=$(command -v i2cdetect 2>/dev/null || true)
    [[ -z "$i2cdetect_bin" && -x /usr/sbin/i2cdetect ]] && i2cdetect_bin=/usr/sbin/i2cdetect
    modprobe_bin=$(command -v modprobe 2>/dev/null || true)
    [[ -z "$modprobe_bin" && -x /usr/sbin/modprobe ]] && modprobe_bin=/usr/sbin/modprobe

    if [[ -z "$i2cdetect_bin" ]]; then
        # Redirect stdout to stderr: detect_hat() output goes to a temp file,
        # so any apt-get stdout here would corrupt the detected HAT name.
        apt-get install -y -q i2c-tools >&2 || true
        i2cdetect_bin=$(command -v i2cdetect 2>/dev/null || true)
        [[ -z "$i2cdetect_bin" && -x /usr/sbin/i2cdetect ]] && i2cdetect_bin=/usr/sbin/i2cdetect
    fi
    if [[ -z "$modprobe_bin" ]]; then
        apt-get install -y -q kmod >&2 || true
        modprobe_bin=$(command -v modprobe 2>/dev/null || true)
        [[ -z "$modprobe_bin" && -x /usr/sbin/modprobe ]] && modprobe_bin=/usr/sbin/modprobe
    fi
    # Enable i2c_arm at runtime in case dtparam=i2c_arm=on is not yet in config.txt
    # (e.g. on first boot before setup.sh has written the overlay). dtparam applies
    # the param immediately without reboot; modprobe i2c-dev exposes /dev/i2c-*.
    dtparam i2c_arm=on &>/dev/null || true
    [[ -n "$modprobe_bin" ]] && "$modprobe_bin" i2c-dev &>/dev/null || true
    if [[ -n "$i2cdetect_bin" ]]; then
        local bus addr result="" found_bus=false
        for bus_path in /dev/i2c-*; do
            [[ -e "$bus_path" ]] || continue
            found_bus=true
            bus="${bus_path##*/i2c-}"
            local scan
            scan=$("$i2cdetect_bin" -y "$bus" 2>/dev/null) || continue
            echo "I2C bus $bus scan complete" >&2
            # PCM5122 at 0x4C/0x4D/0x4E/0x4F → PCM5122-based DAC (hifiberry-dac config)
            for addr in 4c 4d 4e 4f; do
                if echo "$scan" | grep -qE "(^[[:space:]]*[0-9a-f]0:[[:space:]]|[[:space:]])${addr}([[:space:]]|$)"; then
                    echo "I2C: PCM5122 at 0x${addr} on bus ${bus} → hifiberry-dac-std" >&2
                    result="hifiberry-dac-std"; break 2
                fi
            done
            # WM8960 at 0x1A → Waveshare WM8960
            if echo "$scan" | grep -qE "(^[[:space:]]*10:[[:space:]]|[[:space:]])1a([[:space:]]|$)"; then
                echo "I2C: WM8960 at 0x1a on bus ${bus} → waveshare-wm8960" >&2
                result="waveshare-wm8960"; break
            fi
            # WM8804 at 0x3B → generic digital HAT profile.
            # I2C alone cannot distinguish Digi-class boards that share WM8804.
            if echo "$scan" | grep -qE "(^[[:space:]]*30:[[:space:]]|[[:space:]])3b([[:space:]]|$)"; then
                echo "I2C: WM8804 at 0x3b on bus ${bus} → hifiberry-digi" >&2
                result="hifiberry-digi"; break
            fi
        done
        $found_bus || echo "I2C: no /dev/i2c-* nodes available after runtime enable" >&2
        if [[ -n "$result" ]]; then
            HAT_DETECTION_SOURCE="i2c"
            echo "$result"
            return
        fi
        echo "I2C: scan completed without matching a supported HAT" >&2
    else
        echo "I2C: i2cdetect unavailable after install attempt, skipping I2C detection" >&2
    fi

    # Step 4: Check for USB audio device
    if command -v aplay &>/dev/null && aplay -l 2>/dev/null | grep -qi 'USB'; then
        echo "Detected USB audio device" >&2
        HAT_DETECTION_SOURCE="usb"
        echo "usb-audio"
        return
    fi

    # Step 5: Fall back to internal audio (bcm2835 headphone jack / HDMI)
    if command -v aplay &>/dev/null && aplay -l 2>/dev/null | grep -qi 'bcm2835\|Headphones'; then
        echo "No HAT or USB DAC found, using internal audio (bcm2835)" >&2
        HAT_DETECTION_SOURCE="internal"
        echo "internal-audio"
        return
    fi

    # Nothing found — default to internal (safer than USB which may not exist)
    echo "WARNING: No audio device detected, defaulting to internal audio" >&2
    HAT_DETECTION_SOURCE="internal"
    echo "internal-audio"
}

# Map AUDIO_HAT config name (e.g. "usb") to .conf filename
resolve_hat_config_name() {
    local name="$1"
    case "$name" in
        usb|usb-audio)      echo "usb-audio" ;;
        internal|internal-audio|bcm2835) echo "internal-audio" ;;
        *)                  echo "$name" ;;
    esac
}

if [ "$AUTO_MODE" = true ]; then
    # Auto mode: detect or use configured HAT
    if [ "$AUDIO_HAT" = "auto" ]; then
        # Run detect_hat in current shell (not subshell) so HAT_DETECTION_SOURCE
        # survives — command substitution $() would discard global side-effects.
        _hat_tmp=$(mktemp)
        detect_hat > "$_hat_tmp"
        AUDIO_HAT=$(cat "$_hat_tmp")
        rm -f "$_hat_tmp"
        echo "Auto-detected HAT: $AUDIO_HAT (source: $HAT_DETECTION_SOURCE)"
    fi
    HAT_CONFIG=$(resolve_hat_config_name "$AUDIO_HAT")
else
    show_hat_options
    read -rp "Enter choice [1-16]: " hat_choice
    validate_choice "$hat_choice" 16
    HAT_CONFIG=$(get_hat_config "$hat_choice")
fi

# Load HAT configuration
# shellcheck source=/dev/null
HAT_CONFIG_FILE="$COMMON_DIR/audio-hats/$HAT_CONFIG.conf"
if [[ ! -f "$HAT_CONFIG_FILE" ]]; then
    echo "ERROR: HAT configuration file not found: $HAT_CONFIG_FILE"
    echo "Available configurations:"
    ls "$COMMON_DIR/audio-hats/"*.conf 2>/dev/null || echo "  No HAT configurations found"
    exit 1
fi

# shellcheck source=/dev/null
source "$HAT_CONFIG_FILE"

# Validate required HAT configuration variables
if [[ -z "${HAT_NAME:-}" ]] || [[ -z "${HAT_CARD_NAME:-}" ]]; then
    echo "ERROR: Invalid HAT configuration file: $HAT_CONFIG_FILE"
    echo "Required variables: HAT_NAME, HAT_CARD_NAME"
    exit 1
fi

echo "Selected HAT: $HAT_NAME"
echo ""

# ============================================
# Step 2: Select Display Resolution
# ============================================
show_resolution_options() {
    echo "Select your display resolution:"
    echo "1) 800x480   (Small touchscreen)"
    echo "2) 1024x600  (9-inch display)"
    echo "3) 1280x720  (720p HD)"
    echo "4) 1920x1080 (1080p Full HD)"
    echo "5) 2560x1440 (1440p QHD)"
    echo "6) 3840x2160 (4K UHD)"
    echo "7) Custom    (Enter WIDTHxHEIGHT)"
}

get_resolution() {
    local choice="$1"
    case "$choice" in
        1) echo "800x480" ;;
        2) echo "1024x600" ;;
        3) echo "1280x720" ;;
        4) echo "1920x1080" ;;
        5) echo "2560x1440" ;;
        6) echo "3840x2160" ;;
        7)
            read -rp "Enter resolution (e.g., 1366x768): " custom_resolution
            if [[ ! "$custom_resolution" =~ ^[0-9]+x[0-9]+$ ]]; then
                echo "Invalid format. Use WIDTHxHEIGHT (e.g., 1366x768)"
                exit 1
            fi
            # Validate reasonable bounds (320-7680 width, 240-4320 height)
            local width height
            width="${custom_resolution%x*}"
            height="${custom_resolution#*x}"
            if (( width < 320 || width > 7680 || height < 240 || height > 4320 )); then
                echo "Invalid resolution. Width must be 320-7680, height must be 240-4320."
                exit 1
            fi
            echo "$custom_resolution"
            ;;
        *) echo "Invalid choice"; exit 1 ;;
    esac
}

if [ "$AUTO_MODE" = true ]; then
    echo "Resolution: ${DISPLAY_RESOLUTION:-auto}"
else
    show_resolution_options
    read -rp "Enter choice [1-7]: " resolution_choice
    validate_choice "$resolution_choice" 7
    DISPLAY_RESOLUTION=$(get_resolution "$resolution_choice")
    echo "Selected resolution: $DISPLAY_RESOLUTION"
fi
echo ""

# ============================================
# Step 3: Select Spectrum Band Resolution
# ============================================
if [ "$AUTO_MODE" = true ]; then
    echo "Band mode: $BAND_MODE"
else
    echo "Select spectrum analyzer band resolution:"
    echo "1) Third-octave (31 bands) — recommended"
    echo "2) Half-octave (21 bands)"
    read -rp "Enter choice [1-2]: " band_mode_choice

    case "${band_mode_choice:-1}" in
        2) BAND_MODE="half-octave" ;;
        *) BAND_MODE="third-octave" ;;
    esac

    echo "Band mode: $BAND_MODE"
fi
echo ""

# ============================================
# Step 3c: Read-Only Filesystem Option
# ============================================
if [ "$AUTO_MODE" = true ]; then
    echo "Read-only mode: $ENABLE_READONLY"
else
    echo "Enable read-only filesystem? (protects SD card from corruption)"
    echo "  - All writes go to RAM, lost on reboot"
    echo "  - Requires 'sudo ro-mode disable' for updates"
    read -rp "Enable read-only mode? [Y/n]: " readonly_choice

    case "${readonly_choice:-y}" in
        [Nn]|[Nn][Oo]) ENABLE_READONLY=false ;;
        *) ENABLE_READONLY=true ;;
    esac

    echo "Read-only mode: $ENABLE_READONLY"
fi
echo ""

# ============================================
# Step 4: Auto-generate Client ID from hostname
# ============================================
CLIENT_ID="snapclient-$(hostname)"
echo "Client ID: $CLIENT_ID"
echo ""

# ============================================
# Step 5: Install Dependencies
# ============================================
INSTALL_DIR="/opt/snapclient"

progress 1 "Installing system dependencies..."
start_progress_animation 1 0 12  # Animate during apt-get

# Base packages (always needed)
BASE_PACKAGES="ca-certificates curl alsa-utils avahi-daemon avahi-utils"

# Skip apt-get if all base packages are already installed (firstboot did it)
_missing_pkgs=""
# shellcheck disable=SC2086
for _pkg in $BASE_PACKAGES; do
    dpkg -s "$_pkg" &>/dev/null || _missing_pkgs="$_missing_pkgs $_pkg"
done
if [[ -n "$_missing_pkgs" ]]; then
    log_progress "apt-get update + install:$_missing_pkgs"
    apt-get update
    # shellcheck disable=SC2086
    apt-get install -y $_missing_pkgs
    log_progress "System packages installed"
else
    log_progress "All base packages already installed, skipping apt-get"
fi

# Set system locale to C.UTF-8 — prevents warnings from apt and subprocesses.
# C.UTF-8 is always available on Debian without running locale-gen.
update-locale LANG=C.UTF-8 LC_ALL=C.UTF-8 2>/dev/null || true

progress 2 "Installing Docker CE..."
log_progress "Checking Docker installation..."
start_progress_animation 2 12 35  # Animate during long Docker install

# Install Docker CE — use shared install-docker.sh (single source of truth)
if command -v docker &> /dev/null && docker --version | grep -q "Docker version"; then
    log_progress "Docker CE already installed, skipping"
else
    log_progress "Removing conflicting packages..."
    apt-get remove -y docker.io docker-compose docker-buildx containerd runc 2>/dev/null || true

    # Source shared Docker installer (same as server's firstboot.sh)
    for _docker_candidate in \
        "$SCRIPT_DIR/common/install-docker.sh" \
        "$SCRIPT_DIR/../scripts/common/install-docker.sh" \
        "$(dirname "$0")/common/install-docker.sh"; do
        # shellcheck source=common/install-docker.sh
        [[ -f "$_docker_candidate" ]] && source "$_docker_candidate" && break
    done

    if command -v install_docker_apt &>/dev/null; then
        log_progress "Installing Docker CE via shared installer..."
        install_docker_apt
    else
        log_progress "WARNING: install-docker.sh not found, installing Docker inline"
        curl -fsSL https://get.docker.com | sh
    fi
fi

log_progress "systemctl enable docker"
systemctl enable docker
systemctl start docker

log_progress "systemctl enable avahi-daemon"
systemctl enable avahi-daemon
systemctl start avahi-daemon

# Harden avahi: pin hostname, restrict to physical interfaces
tune_avahi_daemon "$(hostname)"

log_progress "timedatectl set-ntp true"
timedatectl set-ntp true 2>/dev/null || true

log_progress "Docker and system services ready"
echo ""

# ============================================
# Step 6: Setup Installation Directory
# ============================================
echo "Setting up installation directory..."
mkdir -p "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/public"
mkdir -p "$INSTALL_DIR/scripts"

# Copy project files (skip if source == destination, e.g. firstboot installs)
if [[ "$(cd "$COMMON_DIR" 2>/dev/null && pwd)" != "$(cd "$INSTALL_DIR" 2>/dev/null && pwd)" ]]; then
    if [[ ! -f "$COMMON_DIR/docker-compose.yml" ]]; then
        echo "ERROR: Required file not found: $COMMON_DIR/docker-compose.yml"
        exit 1
    fi
    cp "$COMMON_DIR/docker-compose.yml" "$INSTALL_DIR/"
    cp -r "$COMMON_DIR/docker" "$INSTALL_DIR/"
    cp "$COMMON_DIR/public/index.html" "$INSTALL_DIR/public/"
fi

# Copy .env only if it doesn't exist (preserve user settings)
if [[ ! -f "$INSTALL_DIR/.env" ]]; then
    if [[ ! -f "$COMMON_DIR/.env.example" ]]; then
        echo "ERROR: Required template file not found: $COMMON_DIR/.env.example"
        exit 1
    fi
    echo "Creating new .env from template..."
    cp "$COMMON_DIR/.env.example" "$INSTALL_DIR/.env"
else
    echo "Preserving existing .env configuration..."
fi

echo "Files copied to $INSTALL_DIR"
echo ""

# ============================================
# Step 7: Configure ALSA (loopback only if display present)
# ============================================
progress 3 "Configuring audio HAT..."

# Detect display early — needed to decide whether to set up ALSA loopback.
# HAS_DISPLAY is reused later for Docker Compose profiles.
# shellcheck source=display.sh
if [[ ! "$(type -t has_display)" == "function" ]]; then
    source "$COMMON_DIR/scripts/display.sh"
fi

# Check for DISPLAY_MODE override from firstboot.sh config
_display_override="${DISPLAY_MODE:-}"

if [[ "$_display_override" == "headless" ]] || { [[ -z "$_display_override" ]] && ! has_display; }; then
    HAS_DISPLAY=false
else
    HAS_DISPLAY=true
fi

progress 4 "Setting up ALSA loopback..."

# Remove legacy FIFO tmpfs mount if present (from previous versions)
if grep -q "/tmp/audio" /etc/fstab 2>/dev/null; then
    sed -i '\|/tmp/audio|d' /etc/fstab
    echo "Removed legacy FIFO tmpfs mount from /etc/fstab"
fi

if [[ "$HAS_DISPLAY" == true ]]; then
    # Display present: loopback + multi plugin for spectrum analyzer
    modprobe snd-aloop
    if ! grep -q "snd-aloop" /etc/modules-load.d/snapclient.conf 2>/dev/null; then
        mkdir -p /etc/modules-load.d
        echo "snd-aloop" >> /etc/modules-load.d/snapclient.conf
    fi

    # Generate ALSA config with multi plugin (DAC + loopback simultaneously)
    # The multi plugin sends audio to both the hardware DAC and a loopback device.
    # The spectrum analyzer reads from the loopback capture side independently —
    # if it stalls or falls behind, the DAC output is completely unaffected.
    cat > /etc/asound.conf << EOF
# ALSA configuration for $HAT_NAME with spectrum analyzer
# Generated by setup script
# Audio is sent to both DAC and loopback simultaneously via multi plugin.
# The loopback feeds the spectrum analyzer without blocking the DAC.

pcm.multi_out {
    type multi
    slaves {
        a { pcm "hw:$HAT_CARD_NAME,0" channels 2 }
        b { pcm "hw:Loopback,0,0" channels 2 }
    }
    bindings {
        0 { slave a channel 0 }
        1 { slave a channel 1 }
        2 { slave b channel 0 }
        3 { slave b channel 1 }
    }
}

pcm.!default {
    type plug
    slave {
        pcm "multi_out"
        channels 4
    }
    ttable {
        0.0 1
        1.1 1
        0.2 1
        1.3 1
    }
}

ctl.!default {
    type hw
    card $HAT_CARD_NAME
}

defaults.pcm.rate_converter "samplerate_best"
EOF

    echo "ALSA configured for $HAT_NAME (card: $HAT_CARD_NAME)"
    echo "  - Audio loopback enabled for spectrum analyzer (snd-aloop)"
else
    # Headless: direct DAC output, no loopback (simpler, more reliable)
    # Remove loopback from auto-load config and unload from running kernel
    if [[ -f /etc/modules-load.d/snapclient.conf ]]; then
        sed -i '/snd-aloop/d' /etc/modules-load.d/snapclient.conf
    fi
    modprobe -r snd-aloop 2>/dev/null || true

    cat > /etc/asound.conf << EOF
# ALSA configuration for $HAT_NAME (headless — no spectrum analyzer)
# Generated by setup script

pcm.!default {
    type plug
    slave {
        pcm "hw:$HAT_CARD_NAME,0"
    }
}

ctl.!default {
    type hw
    card $HAT_CARD_NAME
}

defaults.pcm.rate_converter "samplerate_best"
EOF

    echo "ALSA configured for $HAT_NAME (card: $HAT_CARD_NAME)"
    echo "  - Headless mode: direct DAC output, no loopback"
fi
echo ""

# ============================================
# Step 8: Configure Boot Settings (Idempotent)
# ============================================
progress 5 "Updating boot settings..."
_apply_boot_config() {
BOOT_CONFIG=""
if [ -f /boot/firmware/config.txt ]; then
    BOOT_CONFIG="/boot/firmware/config.txt"
elif [ -f /boot/config.txt ]; then
    BOOT_CONFIG="/boot/config.txt"
fi

CMDLINE=""
if [ -f /boot/firmware/cmdline.txt ]; then
    CMDLINE="/boot/firmware/cmdline.txt"
elif [ -f /boot/cmdline.txt ]; then
    CMDLINE="/boot/cmdline.txt"
fi

if [ -n "$BOOT_CONFIG" ]; then
    # Backup original config (only once per day)
    BACKUP_FILE="${BOOT_CONFIG}.backup.$(date +%Y%m%d)"
    if [ ! -f "$BACKUP_FILE" ]; then
        cp "$BOOT_CONFIG" "$BACKUP_FILE"
        echo "Backup created: $BACKUP_FILE"
    fi

    # Remove any previous snapclient setup section (idempotent)
    if grep -q "$CONFIG_MARKER_START" "$BOOT_CONFIG"; then
        echo "Removing previous snapclient configuration..."
        sed -i "/$CONFIG_MARKER_START/,/$CONFIG_MARKER_END/d" "$BOOT_CONFIG"
    fi

    # Remove temporary setup display section from prepare-sd.sh (legacy)
    if grep -q "SNAPCLIENT SETUP DISPLAY" "$BOOT_CONFIG"; then
        echo "Removing temporary setup display settings..."
        sed -i '/# --- SNAPCLIENT SETUP DISPLAY ---/,/# --- SNAPCLIENT SETUP DISPLAY END ---/d' "$BOOT_CONFIG"
    fi

    # Remove temporary video= parameter from cmdline.txt (KMS mode)
    if [ -n "$CMDLINE" ] && grep -q "video=HDMI-A-1:800x600" "$CMDLINE"; then
        echo "Removing temporary 800x600 video parameter..."
        sed -i 's/ video=HDMI-A-1:[^ ]*//' "$CMDLINE"
        NEEDS_REBOOT=true
        if grep -q "video=HDMI-A-1:" "$CMDLINE"; then
            echo "WARNING: Could not fully remove video= from cmdline.txt"
            echo "  Manually edit: $CMDLINE"
            NEEDS_REBOOT=false
        fi
    fi

    # Fix USB/I2S conflict: otg_mode=1 and dr_mode=host force USB into host
    # mode, which prevents GPIO I2S/I2C communication with audio HATs.
    if grep -q '^otg_mode=1' "$BOOT_CONFIG"; then
        sed -i 's/^otg_mode=1/#otg_mode=1 # disabled by snapclient (conflicts with I2S HATs)/' "$BOOT_CONFIG"
        echo "Disabled otg_mode=1 (conflicts with I2S audio HATs)"
        NEEDS_REBOOT=true
    fi
    if grep -q '^dtoverlay=dwc2,dr_mode=host' "$BOOT_CONFIG"; then
        sed -i 's/^dtoverlay=dwc2,dr_mode=host/dtoverlay=dwc2/' "$BOOT_CONFIG"
        echo "Removed dr_mode=host from dwc2 overlay (conflicts with I2S HATs)"
        NEEDS_REBOOT=true
    fi

    # Extract display width from resolution (default to 0 for autodiscovery mode)
    DISPLAY_WIDTH="${DISPLAY_RESOLUTION%x*}"
    DISPLAY_WIDTH="${DISPLAY_WIDTH:-0}"

    # Build new configuration block
    {
        echo ""
        echo "$CONFIG_MARKER_START"
        echo "# Audio HAT: $HAT_NAME"
        echo "# Display: ${DISPLAY_RESOLUTION}"
        echo "# Generated: $(date -Iseconds)"
        echo ""

        # Add device tree overlay for HAT (skip if USB audio)
        if [ -n "$HAT_OVERLAY" ]; then
            echo "dtoverlay=$HAT_OVERLAY"

            # Enable I2C once for HATs that require control-plane access after boot.
            # This covers PCM512x, WM8960, WM8804, and related amplifier boards.
            case "$HAT_OVERLAY" in
                hifiberry-*|iqaudio-*|rpi-digiampplus|allo-boss*|allo-digione|\
                justboom-dac|justboom-digi|allo-katana*|wm8960*)
                    echo "dtparam=i2c_arm=on"
                    ;;
            esac
        fi

        # Disable onboard audio only when HAT is confirmed (EEPROM or ALSA).
        # I2C detection can false-positive (e.g., non-DAC chip at 0x4D).
        # USB and internal audio need onboard audio as fallback.
        if [ -n "$HAT_OVERLAY" ] && [[ "$HAT_DETECTION_SOURCE" == "eeprom" || "$HAT_DETECTION_SOURCE" == "alsa" ]]; then
            echo "dtparam=audio=off"
        fi

        # GPU memory: headless needs minimal (16MB), display needs more
        if [[ "${HAS_DISPLAY:-true}" == "false" ]]; then
            echo "gpu_mem=16"
        elif [ "$DISPLAY_WIDTH" -gt 1920 ]; then
            echo "gpu_mem=512"
            echo "hdmi_enable_4kp60=1"
            echo "hdmi_force_hotplug=1"
        else
            echo "gpu_mem=256"
        fi

        # Video acceleration (only if not already in base config)
        if ! grep -q "^dtoverlay=vc4-kms-v3d" "$BOOT_CONFIG" 2>/dev/null; then
            echo "dtoverlay=vc4-kms-v3d"
            echo "max_framebuffers=2"
        fi

        echo "$CONFIG_MARKER_END"
    } >> "$BOOT_CONFIG"

    echo "Boot configuration updated"

    # Remove fbcon=map:9 if present (legacy: hid boot messages by mapping
    # console to nonexistent fb9). Kernel messages during boot are valuable
    # for diagnostics; fb-display overwrites fb0 once it starts.
    if [ -n "$CMDLINE" ] && grep -q "fbcon=map:9" "$CMDLINE"; then
        sed -i 's/ fbcon=map:9//' "$CMDLINE"
        echo "Removed fbcon=map:9 from cmdline.txt (boot messages now visible)"
    fi

    # Enable cgroup memory controller for Docker resource limits
    # Required for cgroups v2 on newer kernels (Bookworm+/Trixie)
    if [ -n "$CMDLINE" ] && ! grep -q "cgroup_enable=memory" "$CMDLINE"; then
        sed -i 's/$/ cgroup_enable=memory cgroup_memory=1/' "$CMDLINE"
        echo "Enabled cgroup memory controller (cmdline.txt updated)"
    fi
else
    echo "ERROR: Could not find boot config (config.txt)."
    echo "  Audio HAT overlay and display settings cannot be applied."
    echo "  Expected /boot/firmware/config.txt or /boot/config.txt"
    exit 1
fi
echo ""
}
_apply_boot_config

# ============================================
# Step 9: Detect Hardware Profile & Configure Docker
# ============================================
progress 6 "Configuring Docker environment..."

# Detect network connection type (ethernet vs wifi)
detect_connection_type() {
    # Check for active Ethernet first (more reliable for audio)
    if ip link show eth0 2>/dev/null | grep -q 'state UP'; then
        echo "ethernet"
        return
    fi
    # Check for WiFi
    if ip link show wlan0 2>/dev/null | grep -q 'state UP'; then
        echo "wifi"
        return
    fi
    # Fallback: check default route interface
    local default_iface
    default_iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}') || true
    case "$default_iface" in
        eth*|en*) echo "ethernet" ;;
        wlan*|wl*) echo "wifi" ;;
        *) echo "ethernet" ;;  # conservative default
    esac
}

# Detect hardware and set appropriate resource profile.
# Uses shared detect_hardware() from resource-detect.sh.
detect_resource_profile() {
    detect_hardware
    local ram="${DETECTED_RAM_MB:-0}"

    # Fallback to standard profile if detection failed
    if (( ram < 256 )); then
        echo "WARNING: Only ${ram}MB RAM detected — client needs at least 256MB" >&2
        echo "standard"
        return
    fi

    detect_profile_from_hardware
}

# Set resource limits based on profile
set_resource_limits() {
    local profile=$1

    # Measured baseline (idle): snapclient 18M, visualizer 36-51M, fb-display 89-114M
    case "$profile" in
        minimal)
            # Pi Zero 2 W, Pi 3, <2GB RAM
            SNAPCLIENT_MEM_LIMIT="64M"
            SNAPCLIENT_MEM_RESERVE="32M"
            SNAPCLIENT_CPU_LIMIT="0.5"
            VISUALIZER_MEM_LIMIT="128M"
            VISUALIZER_MEM_RESERVE="48M"
            VISUALIZER_CPU_LIMIT="0.5"
            FBDISPLAY_MEM_LIMIT="192M"
            FBDISPLAY_MEM_RESERVE="96M"
            FBDISPLAY_CPU_LIMIT="0.5"
            ;;
        standard)
            # Pi 4 2GB, 2-4GB RAM
            SNAPCLIENT_MEM_LIMIT="64M"
            SNAPCLIENT_MEM_RESERVE="32M"
            SNAPCLIENT_CPU_LIMIT="0.5"
            VISUALIZER_MEM_LIMIT="128M"
            VISUALIZER_MEM_RESERVE="64M"
            VISUALIZER_CPU_LIMIT="1.0"
            FBDISPLAY_MEM_LIMIT="256M"
            FBDISPLAY_MEM_RESERVE="128M"
            FBDISPLAY_CPU_LIMIT="1.0"
            ;;
        performance)
            # Pi 4 4GB+, Pi 5
            SNAPCLIENT_MEM_LIMIT="96M"
            SNAPCLIENT_MEM_RESERVE="48M"
            SNAPCLIENT_CPU_LIMIT="1.0"
            VISUALIZER_MEM_LIMIT="192M"
            VISUALIZER_MEM_RESERVE="96M"
            VISUALIZER_CPU_LIMIT="1.5"
            FBDISPLAY_MEM_LIMIT="384M"
            FBDISPLAY_MEM_RESERVE="192M"
            FBDISPLAY_CPU_LIMIT="2.0"
            ;;
    esac
}

# Detect and apply resource profile
RESOURCE_PROFILE=$(detect_resource_profile)
set_resource_limits "$RESOURCE_PROFILE"
echo "Hardware profile: $RESOURCE_PROFILE ($(awk '/MemTotal/ {printf "%.1fGB RAM", $2/1024/1024}' /proc/meminfo), $(nproc) cores)"

# Detect network type and set ALSA buffer defaults
# Both mode (localhost): audio goes over loopback, not WiFi — use tight buffers
if [[ "${SNAPSERVER_HOST:-}" == "127.0.0.1" ]]; then
    CONNECTION_TYPE="local"
elif [[ "${CONNECTION_TYPE:-auto}" == "auto" ]]; then
    CONNECTION_TYPE=$(detect_connection_type)
fi
echo "Network: $CONNECTION_TYPE"

# Buffer sizing by connection type:
#   local: loopback has zero jitter — tightest buffers
#   ethernet: stable, low jitter
#   wifi: inherent jitter (10-100ms) — needs larger buffers
case "$CONNECTION_TYPE" in
    wifi)
        ALSA_BUFFER_TIME="${ALSA_BUFFER_TIME:-250}"
        ALSA_FRAGMENTS="${ALSA_FRAGMENTS:-8}"
        ;;
    local)
        ALSA_BUFFER_TIME="${ALSA_BUFFER_TIME:-100}"
        ALSA_FRAGMENTS="${ALSA_FRAGMENTS:-4}"
        ;;
    *)
        ALSA_BUFFER_TIME="${ALSA_BUFFER_TIME:-150}"
        ALSA_FRAGMENTS="${ALSA_FRAGMENTS:-4}"
        ;;
esac

cd "$INSTALL_DIR"

# Snapserver host: empty = autodiscovery via mDNS at boot.
# discover-server.sh (systemd ExecStartPre) handles boot-time mDNS lookup
# and writes the IP to .env. We don't bake an IP at install time because
# the server's address can change between installs and reboots.
# "Both" mode (server+client on same Pi) uses 127.0.0.1 — set by firstboot.sh.
current_snapserver=$(grep "^SNAPSERVER_HOST=" "$INSTALL_DIR/.env" 2>/dev/null | cut -d= -f2 || echo "")

if [ "$AUTO_MODE" = true ]; then
    # In auto mode, only use explicit env var (e.g. SNAPSERVER_HOST=127.0.0.1 for "both" mode)
    # Empty means autodiscovery — don't bake install-time mDNS results
    snapserver_ip="${SNAPSERVER_HOST:-}"
    echo "Snapserver: ${snapserver_ip:-autodiscovery (mDNS at boot)}"
else
    [ -z "$current_snapserver" ] && echo "Current: mDNS autodiscovery" || echo "Current Snapserver: $current_snapserver"
    # Configure snapserver host (empty = autodiscovery via mDNS)
    read -rp "Enter Snapserver IP/hostname (or press Enter for autodiscovery): " snapserver_ip
    snapserver_ip=${snapserver_ip:-$current_snapserver}
fi

# Always use "default" ALSA device — asound.conf routes it to either:
#   - multi_out (DAC + loopback) when display is present
#   - direct DAC hw: when headless
SOUNDCARD_VALUE="default"

# Docker Compose profile: use HAS_DISPLAY from earlier detection (Step 7).
if [[ "$HAS_DISPLAY" == true ]]; then
    DOCKER_COMPOSE_PROFILES="framebuffer"
else
    DOCKER_COMPOSE_PROFILES=""
    echo "No display detected -- headless mode (audio only)"
fi

# Update .env with all settings (idempotent - works on existing or new file)
update_env_var() {
    local key="$1"
    local value="$2"
    local file="$INSTALL_DIR/.env"
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$file"
    else
        echo "${key}=${value}" >> "$file"
    fi
}

# Write SNAPSERVER_HOST: explicit IP for "both" mode, empty for autodiscovery.
# discover-server.sh updates this at boot via mDNS.
update_env_var "SNAPSERVER_HOST" "${snapserver_ip:-}"

# Update all environment variables
declare -A env_vars=(
    ["CLIENT_ID"]="$CLIENT_ID"
    ["SOUNDCARD"]="$SOUNDCARD_VALUE"
    ["DISPLAY_RESOLUTION"]="$DISPLAY_RESOLUTION"
    ["BAND_MODE"]="$BAND_MODE"
    ["COMPOSE_PROFILES"]="$DOCKER_COMPOSE_PROFILES"
    # Resource limits (auto-detected)
    ["SNAPCLIENT_MEM_LIMIT"]="$SNAPCLIENT_MEM_LIMIT"
    ["SNAPCLIENT_MEM_RESERVE"]="$SNAPCLIENT_MEM_RESERVE"
    ["SNAPCLIENT_CPU_LIMIT"]="$SNAPCLIENT_CPU_LIMIT"
    ["VISUALIZER_MEM_LIMIT"]="$VISUALIZER_MEM_LIMIT"
    ["VISUALIZER_MEM_RESERVE"]="$VISUALIZER_MEM_RESERVE"
    ["VISUALIZER_CPU_LIMIT"]="$VISUALIZER_CPU_LIMIT"
    ["FBDISPLAY_MEM_LIMIT"]="$FBDISPLAY_MEM_LIMIT"
    ["FBDISPLAY_MEM_RESERVE"]="$FBDISPLAY_MEM_RESERVE"
    ["FBDISPLAY_CPU_LIMIT"]="$FBDISPLAY_CPU_LIMIT"
    # Mixer (auto-detected from HAT config)
    ["MIXER"]="${HAT_MIXER:-software}"
    # ALSA/network (auto-detected)
    ["ALSA_BUFFER_TIME"]="$ALSA_BUFFER_TIME"
    ["ALSA_FRAGMENTS"]="$ALSA_FRAGMENTS"
    ["CONNECTION_TYPE"]="$CONNECTION_TYPE"
    # Read-only filesystem (--no-readonly disables)
    ["ENABLE_READONLY"]="$ENABLE_READONLY"
    # Docker image tag — inherited from firstboot/prepare-sd (e.g. "dev" for --dev mode)
    ["IMAGE_TAG"]="${IMAGE_TAG:-latest}"
    # Version tag (for display) — prefer VERSION file baked by prepare-sd.sh,
    # fall back to git describe (dev clones), then short SHA, then "dev".
    ["APP_VERSION"]="$(cat "$INSTALL_DIR/VERSION" 2>/dev/null \
        || git -C "$INSTALL_DIR" describe --tags --always 2>/dev/null \
        || git -C "$INSTALL_DIR" rev-parse --short HEAD 2>/dev/null \
        || echo "dev")"
)

for key in "${!env_vars[@]}"; do
    update_env_var "$key" "${env_vars[$key]}"
done

# Remove deprecated env vars from previous installs
for deprecated_key in METADATA_HOST METADATA_HTTP_PORT; do
    if grep -q "^${deprecated_key}=" "$INSTALL_DIR/.env" 2>/dev/null; then
        sed -i "/^${deprecated_key}=/d" "$INSTALL_DIR/.env"
        echo "Removed deprecated ${deprecated_key} from .env"
    fi
done

echo "Docker configuration ready"
echo "  - Snapserver: ${snapserver_ip:-autodiscovery}"
echo "  - Client ID: $CLIENT_ID"
echo "  - Soundcard: $SOUNDCARD_VALUE"
echo "  - Resolution: ${DISPLAY_RESOLUTION:-auto}"
echo "  - Band mode: $BAND_MODE"
echo "  - Network: $CONNECTION_TYPE (buffer: ${ALSA_BUFFER_TIME}ms/${ALSA_FRAGMENTS} frags)"
echo "  - Resource profile: $RESOURCE_PROFILE"
echo ""

# ============================================
# Step 10: Configure Display
# ============================================
echo "Framebuffer mode: display rendering handled by fb-display Docker container"

if systemctl is-enabled x11-autostart.service &>/dev/null; then
    systemctl disable x11-autostart.service
    echo "  Disabled previous X11 autostart service"
fi
echo ""

# ============================================
# Step 10b: Security Hardening
# ============================================
progress 7 "Security hardening..."
log_progress "Applying security settings..."

# Verify cgroup memory controller is configured (set in boot settings)
if [ -n "$CMDLINE" ] && grep -q "cgroup_enable=memory" "$CMDLINE"; then
    echo "✓ cgroup memory controller enabled (resource limits)"
    log_progress "cgroup memory: enabled"
else
    echo "⚠ cgroup memory controller not in cmdline (limits may not work)"
    log_progress "cgroup memory: not configured"
fi

# Verify docker-compose.yml has security settings
if grep -q "no-new-privileges" "$INSTALL_DIR/docker-compose.yml" 2>/dev/null; then
    echo "✓ Container security options configured"
    log_progress "Container security: configured"
else
    echo "⚠ Container security options not found in docker-compose.yml"
fi

# ── System tuning (system-tune.sh sourced at top of file) ──
if [[ "$CONNECTION_TYPE" == "wifi" ]]; then
    tune_wifi_powersave
    log_progress "WiFi power management: disabled"
else
    echo "Ethernet detected — no WiFi optimization needed"
    log_progress "Network: ethernet (no WiFi tuning)"
fi

tune_cpu_governor
tune_usb_autosuspend

# Boot-time tuning service (shared function from system-tune.sh)
BOOT_TUNE="$SCRIPT_DIR/boot-tune.sh"
[[ ! -f "$BOOT_TUNE" ]] && BOOT_TUNE="$INSTALL_DIR/scripts/common/boot-tune.sh"
install_boot_tune_service "$BOOT_TUNE"

# Verify read_only and tmpfs settings
if grep -q "read_only: true" "$INSTALL_DIR/docker-compose.yml" 2>/dev/null; then
    echo "✓ Read-only containers configured"
    log_progress "Read-only mode: enabled"
fi

echo ""

# ============================================
# Step 11: Create Systemd Service for Docker
# ============================================
progress 8 "Creating systemd service..."
_setup_systemd_services() {
log_progress "Creating snapclient.service..."

# Install mDNS discovery script (runs before Docker services start)
if [[ -f "$COMMON_DIR/scripts/discover-server.sh" ]]; then
    install -m 755 "$COMMON_DIR/scripts/discover-server.sh" /usr/local/bin/snapclient-discover
else
    echo "Warning: discover-server.sh not found, skipping mDNS boot discovery"
fi

# Docker Compose profiles are handled via COMPOSE_PROFILES in .env
cat > /etc/systemd/system/snapclient.service << EOF
[Unit]
Description=Snapclient Docker Compose Service
Requires=docker.service avahi-daemon.service
After=docker.service avahi-daemon.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${INSTALL_DIR}
ExecStartPre=-/usr/local/bin/snapclient-discover
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable snapclient.service

# Periodic server re-discovery (follows server across IP changes)
cat > /etc/systemd/system/snapclient-discover.service <<EOF
[Unit]
Description=Snapserver mDNS re-discovery
After=avahi-daemon.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/snapclient-discover --watch
EOF

cat > /etc/systemd/system/snapclient-discover.timer <<EOF
[Unit]
Description=Re-discover snapserver every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable snapclient-discover.timer

# Install display detection boot service (re-checks HDMI on every boot)
# Skip copy when source == destination (firstboot installs from /opt/snapclient)
if [[ "$(cd "$COMMON_DIR" 2>/dev/null && pwd)" != "$(cd "$INSTALL_DIR" 2>/dev/null && pwd)" ]]; then
    cp "$COMMON_DIR/scripts/display-detect.sh" "$INSTALL_DIR/scripts/"
    cp "$COMMON_DIR/scripts/display.sh" "$INSTALL_DIR/scripts/"
fi
chmod +x "$INSTALL_DIR/scripts/display-detect.sh"
chmod +x "$INSTALL_DIR/scripts/display.sh"
if [[ -d /etc/systemd/system ]]; then
    if [[ "$(cd "$COMMON_DIR" 2>/dev/null && pwd)" != "$(cd "$INSTALL_DIR" 2>/dev/null && pwd)" ]]; then
        cp "$COMMON_DIR/systemd/snapclient-display.service" /etc/systemd/system/
    elif [[ -f "$INSTALL_DIR/systemd/snapclient-display.service" ]]; then
        cp "$INSTALL_DIR/systemd/snapclient-display.service" /etc/systemd/system/
    fi
    systemctl daemon-reload
    systemctl enable snapclient-display.service
fi

echo "Systemd services created and enabled"
echo ""
}
_setup_systemd_services

_configure_readonly() {
if [[ "${ENABLE_READONLY:-false}" == "true" ]]; then
    progress 9 "Configuring read-only filesystem..."

    # Install fuse-overlayfs package (needed after reboot when overlayroot is active)
    log_progress "Installing fuse-overlayfs..."
    if ! apt-get install -y fuse-overlayfs; then
        log_progress "ERROR: fuse-overlayfs not available — read-only mode will be skipped"
        ENABLE_READONLY=false
        return 0
    fi

    # Verify binary works
    if ! fuse-overlayfs --version >/dev/null 2>&1; then
        log_progress "ERROR: fuse-overlayfs binary broken — read-only mode will be skipped"
        ENABLE_READONLY=false
        return 0
    fi

    # Write fuse-overlayfs to daemon.json for NEXT boot (when overlayroot is active).
    # Do NOT switch the running driver or wipe /var/lib/docker — that would destroy
    # images already pulled by deploy.sh (server) or earlier in this script.
    # After reboot with overlayroot, Docker data lives on tmpfs overlay anyway,
    # so images are re-pulled from the baked SD card layer.
    log_progress "Configuring Docker for fuse-overlayfs (activates after reboot)..."
    tune_docker_daemon --live-restore --fuse-overlayfs
    if ! grep -q 'fuse-overlayfs' /etc/docker/daemon.json 2>/dev/null; then
        log_progress "WARNING: Failed to write fuse-overlayfs to daemon.json"
        log_progress "         Read-only mode may not work correctly after reboot"
    fi

    # Install ro-mode helper script
    log_progress "Installing ro-mode helper..."
    if [[ -f "$COMMON_DIR/scripts/ro-mode.sh" ]]; then
        install -m 755 "$COMMON_DIR/scripts/ro-mode.sh" /usr/local/bin/ro-mode
    else
        echo "Warning: ro-mode.sh not found, skipping helper install"
    fi

    # Persist SSH host keys so they survive read-only reboots.
    # Without this, overlayfs generates new keys on every boot,
    # causing SSH "REMOTE HOST IDENTIFICATION HAS CHANGED" errors.
    log_progress "Persisting SSH host keys..."
    if [[ -d /etc/ssh ]]; then
        mkdir -p /etc/ssh/keys_permanent
        cp -n /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub /etc/ssh/keys_permanent/ 2>/dev/null || true
        # Create a service that restores keys from permanent storage on boot
        cat > /etc/systemd/system/ssh-keys-restore.service << 'SSHEOF'
[Unit]
Description=Restore SSH host keys from permanent storage
Before=ssh.service sshd.service
ConditionPathExists=/etc/ssh/keys_permanent

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'cp /etc/ssh/keys_permanent/ssh_host_* /etc/ssh/ 2>/dev/null && chmod 600 /etc/ssh/ssh_host_*_key'

[Install]
WantedBy=multi-user.target
SSHEOF
        systemctl daemon-reload
        systemctl enable ssh-keys-restore.service
        echo "SSH host keys will persist across reboots"
    fi

    # Enable overlayfs (takes effect after reboot)
    log_progress "Enabling overlayfs..."
    raspi-config nonint do_overlayfs 0

    echo "Read-only filesystem configured"
    echo "  - Docker storage driver: fuse-overlayfs (activates after reboot)"
    echo "  - SSH host keys: persisted"
    echo "  - Helper script: /usr/local/bin/ro-mode"
    echo "  - Status: Will activate after reboot"
    echo ""
    echo "To temporarily disable for updates:"
    echo "  sudo ro-mode disable && sudo reboot"
    echo ""
else
    echo "Read-only filesystem: skipped (ENABLE_READONLY=false)"
fi
echo ""
}
_configure_readonly

# ============================================
# Step 13: Pull container images (once, after storage driver is final)
# ============================================
progress 10 "Pulling container images..."
start_progress_animation 10 60 40  # Animate during long image pull

cd "$INSTALL_DIR"

# Pull images using shared module (1 GB minimum for client)
if ! pull_compose_images log_progress 1024; then
    stop_progress_animation
    echo ""
    echo "WARNING: Failed to pull some container images"
    echo "  firstboot will retry on next boot, or run manually:"
    echo "  cd $INSTALL_DIR && docker compose pull"
    # Don't exit 1 — let firstboot retry. After a Docker storage driver
    # switch (readonly mode), images were wiped and the pull may fail
    # due to rate limits or network issues. On next boot, fuse-overlayfs
    # is already configured so no wipe happens, and the pull retries.
    PULL_FAILED=true
else
    PULL_FAILED=false
fi
echo ""

# ============================================
# Step 13b: Bake Docker state to SD card (overlayroot only, defensive)
# First-boot: overlayroot not active yet -> harmless no-op.
# Re-runs on overlayroot: persists images so tmpfs doesn't fill on next boot.
# ============================================
if [[ "$PULL_FAILED" == "true" ]]; then
    echo "Skipping bake — images incomplete (will retry on next boot)"
elif mountpoint -q /media/root-ro 2>/dev/null; then
    log_progress "Baking Docker images to SD card..."
    BAKE_DIR=$(mktemp -d /tmp/snapclient-bake-XXXXX)
    bake_cleanup() {
        _setup_failure_dump  # chain diagnostic dump on failure
        sudo umount "$BAKE_DIR" 2>/dev/null || true
        rmdir "$BAKE_DIR" 2>/dev/null || true
        sudo sync
    }
    trap bake_cleanup EXIT

    sudo mount --bind /media/root-ro "$BAKE_DIR"
    sudo mount -o remount,rw "$BAKE_DIR"

    # Persist config files
    sudo mkdir -p "$BAKE_DIR$INSTALL_DIR"
    sudo rsync -a \
        "$INSTALL_DIR/.env" \
        "$INSTALL_DIR/docker-compose.yml" \
        "$BAKE_DIR$INSTALL_DIR/"
    sudo rsync -a --delete "$INSTALL_DIR/docker/" \
        "$BAKE_DIR$INSTALL_DIR/docker/"
    sudo rsync -a --delete "$INSTALL_DIR/public/" \
        "$BAKE_DIR$INSTALL_DIR/public/"
    if [[ -d "$INSTALL_DIR/audio-hats" ]]; then
        sudo rsync -a --delete "$INSTALL_DIR/audio-hats/" \
            "$BAKE_DIR$INSTALL_DIR/audio-hats/"
    fi
    if [[ -d "$INSTALL_DIR/scripts" ]]; then
        sudo rsync -a --delete "$INSTALL_DIR/scripts/" \
            "$BAKE_DIR$INSTALL_DIR/scripts/"
    fi

    # Persist Docker image index + layers
    sudo rsync -a /var/lib/docker/image/ \
        "$BAKE_DIR/var/lib/docker/image/"
    sudo rsync -aX --ignore-existing /var/lib/docker/fuse-overlayfs/ \
        "$BAKE_DIR/var/lib/docker/fuse-overlayfs/"

    # Verify bake wrote content (detect rsync failures)
    if [[ ! -d "$BAKE_DIR/var/lib/docker/image" ]] || \
       [[ -z "$(ls -A "$BAKE_DIR/var/lib/docker/image" 2>/dev/null)" ]]; then
        echo "ERROR: Bake verification failed -- Docker image index not written"
        exit 1
    fi

    # sync happens in bake_cleanup EXIT trap
    log_progress "Docker images baked to SD card"
else
    echo "Non-overlayroot system -- Docker images stored directly on disk"
fi

# ============================================
# Setup Complete
# ============================================
progress_complete

_elapsed="$((SECONDS / 60))m$((SECONDS % 60))s"

# Exit early with clear error if pull failed — don't show success banner.
# firstboot won't mark .done-setup, so it retries on next boot
# (fuse-overlayfs already configured, no wipe)
if [[ "${PULL_FAILED:-false}" == "true" ]]; then
    echo "========================================="
    echo "Setup Incomplete ($_elapsed)"
    echo "========================================="
    echo ""
    echo "WARNING: Image pull failed — will retry on next boot"
    echo "  To retry manually: cd $INSTALL_DIR && docker compose pull"
    exit 1
fi

echo "========================================="
echo "Setup Complete! ($_elapsed)"
echo "========================================="
echo ""
echo "Configuration Summary:"
echo "  - Audio HAT: $HAT_NAME"
echo "  - Mixer: ${HAT_MIXER:-software}"
echo "  - Resolution: ${DISPLAY_RESOLUTION:-auto}"
echo "  - Band mode: $BAND_MODE"
echo "  - Client ID: $CLIENT_ID"
echo "  - Snapserver: ${snapserver_ip:-autodiscovery (mDNS)}"
echo "  - Resource profile: $RESOURCE_PROFILE"
echo "  - Read-only mode: ${ENABLE_READONLY:-false}"
echo "  - Install dir: $INSTALL_DIR"
echo ""
echo "Next steps:"
echo "1. Review configuration in $INSTALL_DIR/.env"
echo "2. Reboot the system: sudo reboot"
echo "3. After reboot, check services:"
echo "   - sudo systemctl status snapclient"
echo "   - sudo docker ps"
echo ""
echo "The snapclient will start automatically on boot"
if [[ -n "$DOCKER_COMPOSE_PROFILES" ]]; then
    echo "Cover display will render directly to framebuffer (/dev/fb0)"
else
    echo "Headless mode: audio only (no display services)"
fi
if [[ "${ENABLE_READONLY:-false}" == "true" ]]; then
echo ""
echo "Read-only mode is enabled. After reboot:"
echo "  - Root filesystem will be read-only (protected from corruption)"
echo "  - Use 'sudo ro-mode status' to verify"
echo "  - Use 'sudo ro-mode disable && sudo reboot' for updates"
fi
if [[ "$NEEDS_REBOOT" == "true" ]]; then
echo ""
echo "NOTE: Boot configuration was modified."
echo "  A reboot is required for changes to take effect."
fi
echo ""
