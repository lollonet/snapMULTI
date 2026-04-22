#!/usr/bin/env bash
# shellcheck disable=SC2034  # HAT_DETECTION_SOURCE set here, used by callers
set -euo pipefail
# audio-hat-detect.sh — Audio HAT detection and menu for Raspberry Pi
#
# Detects audio HATs via: EEPROM -> ALSA -> I2C -> USB -> internal fallback.
# Provides interactive menu for manual selection.
#
# Exports:
#   detect_hat()              — auto-detect, prints config name to stdout
#   show_hat_options()        — print interactive menu
#   validate_choice()         — validate numeric menu choice
#   get_hat_config()          — map menu choice number to config name
#   resolve_hat_config_name() — normalize aliases (usb -> usb-audio)
#
# Sets:
#   HAT_DETECTION_SOURCE      — how detection succeeded (eeprom|alsa|i2c|usb|internal|none)
#
# Usage:
#   source audio-hat-detect.sh
#   AUDIO_HAT=$(detect_hat 2>/dev/null)
#   echo "Detected: $AUDIO_HAT via $HAT_DETECTION_SOURCE"

HAT_DETECTION_SOURCE="none"

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

detect_hat() {
    # Detect audio HAT automatically.
    # 1. Pi firmware reads HAT EEPROM at boot -> /proc/device-tree/hat/product
    # 2. Fallback: check ALSA card names via aplay -l (requires overlay already loaded)
    # 3. Fallback: I2C bus scan for known DAC chip addresses (works without overlay)
    # 4. USB audio device check
    # 5. Final fallback: internal audio (bcm2835)
    local hat_product=""

    if [ -f /proc/device-tree/hat/product ]; then
        hat_product=$(tr -d '\0' < /proc/device-tree/hat/product)
        HAT_DETECTION_SOURCE="eeprom"
        echo "EEPROM product: '$hat_product'" >&2
        case "$hat_product" in
            *DAC*2*HD*)                                  echo "hifiberry-dac2hd"     ; return ;;
            Digi+*|*Digi\ +*|*HiFiBerry*Digi*)          echo "hifiberry-digi"        ; return ;;
            *AMP*2*|*Amp*2*)                             echo "hifiberry-amp2"        ; return ;;
            *DAC*ADC*)                                   echo "hifiberry-dacplusadc"  ; return ;;
            *HiFiBerry*DAC*|DAC+*|*DAC\ +*)             echo "hifiberry-dac"         ; return ;;
            *Pi-DigiAMP*|*DigiAMP*)                     echo "iqaudio-digiamp"       ; return ;;
            *Pi-Codec*|*CodecZero*|*Codec*Zero*)        echo "iqaudio-codec"         ; return ;;
            *Raspberry*Pi*DAC*|*IQaudio*DAC*|*IQaudIO*) echo "iqaudio-dac"           ; return ;;
            *Boss*|*BOSS*)                              echo "allo-boss"             ; return ;;
            *DigiOne*|*Allo*Digi*)                      echo "allo-digione"          ; return ;;
            *JustBoom*Digi*)                            echo "justboom-digi"         ; return ;;
            *JustBoom*DAC*|*JustBoom*Amp*)              echo "justboom-dac"          ; return ;;
            *Innomaker*|*INNO*|*ES9038*|*Katana*)      echo "innomaker-dac-pro"     ; return ;;
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
    #   0x4C-0x4F  PCM5122 (InnoMaker HiFi DAC, IQaudio DAC+, Allo Boss, JustBoom DAC, ...)
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
        # stdout to stderr: detect_hat() stdout is captured by callers for HAT name
        apt-get install -y -q i2c-tools >&2 || true
        i2cdetect_bin=$(command -v i2cdetect 2>/dev/null || true)
        [[ -z "$i2cdetect_bin" && -x /usr/sbin/i2cdetect ]] && i2cdetect_bin=/usr/sbin/i2cdetect
    fi
    if [[ -z "$modprobe_bin" ]]; then
        # stdout to stderr: same reason as above
        apt-get install -y -q kmod >&2 || true
        modprobe_bin=$(command -v modprobe 2>/dev/null || true)
        [[ -z "$modprobe_bin" && -x /usr/sbin/modprobe ]] && modprobe_bin=/usr/sbin/modprobe
    fi
    # Enable i2c_arm at runtime: on first boot config.txt may not yet have the
    # overlay written. dtparam applies immediately; modprobe i2c-dev exposes /dev/i2c-*.
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
            for addr in 4c 4d 4e 4f; do
                if echo "$scan" | grep -qE "(^[[:space:]]*[0-9a-f]0:[[:space:]]|[[:space:]])${addr}([[:space:]]|$)"; then
                    echo "I2C: PCM5122 at 0x${addr} on bus ${bus} → hifiberry-dac-std" >&2
                    result="hifiberry-dac-std"; break 2
                fi
            done
            if echo "$scan" | grep -qE "(^[[:space:]]*10:[[:space:]]|[[:space:]])1a([[:space:]]|$)"; then
                echo "I2C: WM8960 at 0x1a on bus ${bus}" >&2
                result="waveshare-wm8960"; break
            fi
            if echo "$scan" | grep -qE "(^[[:space:]]*30:[[:space:]]|[[:space:]])3b([[:space:]]|$)"; then
                echo "I2C: WM8804 at 0x3b on bus ${bus}" >&2
                result="hifiberry-digi"; break
            fi
        done
        $found_bus || echo "I2C: no /dev/i2c-* nodes available" >&2
        if [[ -n "$result" ]]; then
            HAT_DETECTION_SOURCE="i2c"
            echo "$result"
            return
        fi
        echo "I2C: no supported HAT found" >&2
    else
        echo "I2C: i2cdetect unavailable, skipping" >&2
    fi

    # USB audio device check
    if command -v aplay &>/dev/null && aplay -l 2>/dev/null | grep -qi 'USB'; then
        echo "Detected USB audio device" >&2
        HAT_DETECTION_SOURCE="usb"
        echo "usb-audio"
        return
    fi

    # Internal audio fallback
    if command -v aplay &>/dev/null && aplay -l 2>/dev/null | grep -qi 'bcm2835\|Headphones'; then
        echo "No HAT or USB DAC found, using internal audio" >&2
        HAT_DETECTION_SOURCE="internal"
        echo "internal-audio"
        return
    fi

    echo "WARNING: No audio device detected, defaulting to internal audio" >&2
    HAT_DETECTION_SOURCE="internal"
    echo "internal-audio"
}

resolve_hat_config_name() {
    local name="$1"
    case "$name" in
        usb|usb-audio)      echo "usb-audio" ;;
        internal|internal-audio|bcm2835) echo "internal-audio" ;;
        *)                  echo "$name" ;;
    esac
}
