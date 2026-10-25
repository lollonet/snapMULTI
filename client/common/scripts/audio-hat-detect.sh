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
#   detect_usb_card_id()      — ALSA card id of the first USB audio card
#   detect_internal_card_name() — ALSA card id of the built-in jack/HDMI output
#   resolve_hat_card_name()   — runtime card id for usb-audio / internal-audio
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

# hat_from_i2c_scan SCAN → echoes the HAT profile for an `i2cdetect -y 1`
# table, or returns 1 when no supported chip answers. Pure (no I/O besides
# stderr logging) so it can be unit-tested with captured scans.
# Known addresses:
#   0x4C-0x4F  PCM5122. The overlay must match the address: upstream
#              hifiberry-dacplus-std (also allo-boss-dac-pcm512x-audio,
#              justboom-dac) hard-codes pcm5122@4d, while iqaudio-dacplus
#              (and rpi-dacplus, which includes it) uses pcm5122@4c — an
#              IQaudio / RPi DAC+-family board at 0x4c never binds under the
#              HiFiBerry overlay. 0x4e/0x4f have no upstream overlay in this
#              family; they keep the previous hifiberry-dac-std fallback.
#              NOTE: shared with TMP112, ADS1x1x, PCA9685 and other non-DAC
#              chips — may false-positive on mixed I2C buses.
#   0x1A       WM8960  (Waveshare WM8960)
#   0x3B       WM8804  (HiFiBerry Digi, JustBoom Digi, Allo DigiOne)
# Cells showing "UU" (address claimed by a bound driver) do not match:
# with the overlay already loaded the ALSA-name path identifies the card.
hat_from_i2c_scan() {
    local scan="$1" addr result
    for addr in 4c 4d 4e 4f; do
        if grep -qE "(^[[:space:]]*[0-9a-f]0:[[:space:]]|[[:space:]])${addr}([[:space:]]|$)" <<<"$scan"; then
            if [[ "$addr" == "4c" ]]; then
                result="iqaudio-dac"
            else
                result="hifiberry-dac-std"
            fi
            echo "I2C: PCM5122 at 0x${addr} → ${result}" >&2
            printf '%s\n' "$result"
            return 0
        fi
    done
    if grep -qE "(^[[:space:]]*10:[[:space:]]|[[:space:]])1a([[:space:]]|$)" <<<"$scan"; then
        echo "I2C: WM8960 at 0x1a" >&2
        printf 'waveshare-wm8960\n'
        return 0
    fi
    # I2C alone cannot distinguish Digi-class boards that share WM8804.
    if grep -qE "(^[[:space:]]*30:[[:space:]]|[[:space:]])3b([[:space:]]|$)" <<<"$scan"; then
        echo "I2C: WM8804 at 0x3b" >&2
        printf 'hifiberry-digi\n'
        return 0
    fi
    return 1
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
        # Match EEPROM strings — patterns based on Volumio dacs.json and real devices.
        # Order matters: more specific patterns first (AMP2/DAC+ADC before generic DAC+).
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
    # Address → profile mapping lives in hat_from_i2c_scan (above).
    local i2cdetect_bin="" modprobe_bin=""
    i2cdetect_bin=$(command -v i2cdetect 2>/dev/null || true)
    [[ -z "$i2cdetect_bin" && -x /usr/sbin/i2cdetect ]] && i2cdetect_bin=/usr/sbin/i2cdetect
    modprobe_bin=$(command -v modprobe 2>/dev/null || true)
    [[ -z "$modprobe_bin" && -x /usr/sbin/modprobe ]] && modprobe_bin=/usr/sbin/modprobe

    if [[ -z "$i2cdetect_bin" ]]; then
        # stdout to stderr: detect_hat() stdout is captured by callers for HAT name
        if ! apt-get install -y -q i2c-tools >&2; then
            # apt fail is non-fatal — the downstream `if [[ -n "$i2cdetect_bin" ]]`
            # gate at line 176 falls back to "I2C: i2cdetect unavailable, skipping",
            # so detection drops one fallback layer. Log the cause so operators
            # don't have to grep apt logs to understand why I2C scan was skipped.
            echo "WARN: apt-get install i2c-tools failed — I2C HAT scan will be skipped" >&2
        fi
        i2cdetect_bin=$(command -v i2cdetect 2>/dev/null || true)
        [[ -z "$i2cdetect_bin" && -x /usr/sbin/i2cdetect ]] && i2cdetect_bin=/usr/sbin/i2cdetect
    fi
    if [[ -z "$modprobe_bin" ]]; then
        # stdout to stderr: same reason as above
        if ! apt-get install -y -q kmod >&2; then
            # Downstream `[[ -n "$modprobe_bin" ]]` gate at line 169 short-circuits
            # i2c-dev module load. Log the cause for parity with the i2c-tools
            # branch above.
            echo "WARN: apt-get install kmod failed — i2c-dev module will not be auto-loaded" >&2
        fi
        modprobe_bin=$(command -v modprobe 2>/dev/null || true)
        [[ -z "$modprobe_bin" && -x /usr/sbin/modprobe ]] && modprobe_bin=/usr/sbin/modprobe
    fi
    # Enable i2c_arm at runtime: on first boot config.txt may not yet have the
    # overlay written. dtparam applies immediately; modprobe i2c-dev exposes /dev/i2c-*.
    dtparam i2c_arm=on &>/dev/null || true
    [[ -n "$modprobe_bin" ]] && "$modprobe_bin" i2c-dev &>/dev/null || true
    # Wait briefly for /dev/i2c-1 to appear after module load
    local _i2c_wait
    for _i2c_wait in 1 2 3; do
        [[ -e /dev/i2c-1 ]] && break
        sleep 1
    done
    if [[ -n "$i2cdetect_bin" ]]; then
        local bus result="" found_bus=false
        # Scan only bus 1 (GPIO header). Pi 4/400 have HDMI internal buses
        # (20, 21) and Pi 5 has buses (11, 12) with devices at 0x4C-0x4F
        # that false-positive as PCM5122 audio DACs.
        # shellcheck disable=SC2043  # intentional single-iteration: only GPIO bus
        for bus in 1; do
            [[ -e "/dev/i2c-$bus" ]] || continue
            found_bus=true
            local scan
            scan=$(timeout 10 "$i2cdetect_bin" -y "$bus" 2>/dev/null) || continue
            echo "I2C bus $bus scan complete" >&2
            if result=$(hat_from_i2c_scan "$scan"); then
                break
            fi
        done
        $found_bus || echo "I2C: /dev/i2c-1 not available" >&2
        if [[ -n "$result" ]]; then
            HAT_DETECTION_SOURCE="i2c"
            echo "$result"
            return
        fi
        echo "I2C: no supported HAT found" >&2
    else
        echo "I2C: i2cdetect unavailable, skipping" >&2
    fi

    # USB audio device check.
    # `aplay -l` lines look like:
    #   card 1: Audio [USB Audio CODEC], device 0: USB Audio [USB Audio]
    # The literal token "USB" appears in the description but the ALSA
    # card *id* (between `card N:` and the bracketed name) is what we
    # need for `hw:CARD=NAME,DEV=0`. Many USB DACs report ids like
    # "Device", "S2", "X20", etc. — hardcoding "USB" yields a non-existent
    # card. Probe the actual id and export it for setup.sh to consume.
    if command -v aplay &>/dev/null; then
        local _usb_card_id=""
        _usb_card_id=$(aplay -l 2>/dev/null \
            | awk -F'[ :]+' '/USB/ && /^card [0-9]+/ {print $3; exit}' || true)
        if [[ -n "$_usb_card_id" ]]; then
            echo "Detected USB audio device (ALSA card id: $_usb_card_id)" >&2
            HAT_DETECTION_SOURCE="usb"
            export USB_CARD_ID="$_usb_card_id"
            echo "usb-audio"
            return
        fi
    fi

    # Internal audio fallback
    if command -v aplay &>/dev/null && aplay -l 2>/dev/null | grep -qi 'bcm2835\|Headphones'; then
        echo "No HAT or USB DAC found, using internal audio" >&2
        HAT_DETECTION_SOURCE="internal"
        echo "internal-audio"
        return
    fi

    # Nothing found — default to internal (safer than USB which may not exist)
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

# detect_usb_card_id → echoes the ALSA card id of the first USB audio card.
#
# `aplay -l` lines look like:
#   card 1: Device [USB Audio Device], device 0: USB Audio [USB Audio]
# The card *id* is the token between `card N:` and the bracketed long
# name ("Device" above) — that, not the literal "USB", is what
# `hw:CARD=<id>,DEV=0` needs.
#
# Returns 0 and prints the id, or 1 with no output.
detect_usb_card_id() {
    command -v aplay &>/dev/null || return 1
    local id
    id=$(aplay -l 2>/dev/null \
        | awk -F'[ :]+' '/USB/ && /^card [0-9]+/ {print $3; exit}' || true)
    [[ -n "$id" ]] || return 1
    printf '%s\n' "$id"
}

# detect_internal_card_name MODE → echoes the real ALSA card id for the
# built-in audio output. MODE is `hdmi` or `jack`.
#
# Why this exists: the `internal-audio.conf` profile hard-codes
# HAT_CARD_NAME="Headphones", which only exists on boards with an analog
# jack (Pi 3/4). Pi 5 and Pi Zero 2W have no jack at all, and the HDMI
# card id depends on the kernel driver:
#   KMS (Bookworm/Trixie)    Pi 4/5: vc4hdmi0, vc4hdmi1   Pi 3 / Zero 2W: vc4hdmi
#   legacy bcm2835 (no KMS)  b1 (HDMI 1), b2 (HDMI 2 on Pi 4)
# `vc4-hdmi-0` is the card's display name, not its id — ALSA rejects it
# in `hw:CARD=...`.
#
# Card ids are taken from the `CARD=<id>` fields of `aplay -L` (e.g.
# `hw:CARD=vc4hdmi0,DEV=0`, `sysdefault:CARD=Headphones`); bare card
# names never appear there as whole lines. The returned value is used
# verbatim as `CARD=<id>` / `hw:<id>,0` by setup.sh and setup-zero2w.sh.
#
# Returns:
#   stdout: the resolved card id (e.g. "Headphones", "vc4hdmi0").
#   exit 0: id resolved.
#   exit 1: no match found OR aplay unavailable (caller falls back).
#
# Resolution order (first present wins):
#   hdmi → vc4hdmi0 | vc4hdmi1 | vc4hdmi | b1 | b2 | HDMI
#   jack → Headphones    (Pi 3/4 only — Pi 5 / Zero 2W must use hdmi)
detect_internal_card_name() {
    local mode="${1:?detect_internal_card_name: mode required (hdmi|jack)}"
    local candidates
    case "$mode" in
        hdmi) candidates="vc4hdmi0 vc4hdmi1 vc4hdmi b1 b2 HDMI" ;;
        jack) candidates="Headphones" ;;
        *)    return 1 ;;
    esac
    local aplay_bin
    aplay_bin=$(command -v aplay 2>/dev/null) || return 1
    local aplay_out
    aplay_out=$("$aplay_bin" -L 2>/dev/null) || return 1
    local ids
    ids=$(grep -oE 'CARD=[^,[:space:]]+' <<<"$aplay_out" | cut -d= -f2 | awk '!seen[$0]++' || true)
    [[ -n "$ids" ]] || return 1
    local candidate
    for candidate in $candidates; do
        if grep -qxF "$candidate" <<<"$ids"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

# resolve_hat_card_name HAT_CONFIG DEFAULT_CARD [INTERNAL_MODE]
#   → echoes the ALSA card id to use in asound.conf / SOUNDCARD.
#
# Shared by setup.sh (Docker client) and setup-zero2w.sh (native client)
# so both install paths agree. audio-hats/*.conf can only carry a static
# HAT_CARD_NAME; for two profiles the real id is only known at runtime:
#   usb-audio      → USB_CARD_ID (exported by detect_hat), else an
#                    `aplay -l` probe (menu / install.conf selection,
#                    where detect_hat never ran its USB branch).
#   internal-audio → detect_internal_card_name for INTERNAL_MODE
#                    (AUDIO_INTERNAL_OUTPUT: jack|hdmi). jack falls back
#                    to hdmi on boards without an analog jack; an empty
#                    mode tries jack first, then hdmi.
# Every other profile, and any probe miss, returns DEFAULT_CARD unchanged.
# Diagnostics go to stderr; stdout carries only the card id.
resolve_hat_card_name() {
    local hat_config="$1" default_card="$2" internal_mode="${3:-}"
    local card=""
    case "$hat_config" in
        usb-audio)
            card="${USB_CARD_ID:-}"
            if [[ -z "$card" ]]; then
                card=$(detect_usb_card_id || true)
                [[ -n "$card" ]] && echo "Probed USB ALSA card id: $card" >&2
            fi
            ;;
        internal-audio)
            case "$internal_mode" in
                hdmi)
                    card=$(detect_internal_card_name hdmi || true)
                    ;;
                jack|"")
                    card=$(detect_internal_card_name jack || true)
                    if [[ -z "$card" ]]; then
                        card=$(detect_internal_card_name hdmi || true)
                        if [[ -n "$card" && "$internal_mode" == "jack" ]]; then
                            echo "[WARN] AUDIO_INTERNAL_OUTPUT=jack requested but no Headphones card found (no analog jack on Pi 5 / Zero 2W). Falling back to HDMI." >&2
                        fi
                    fi
                    ;;
                *)
                    echo "[WARN] Unknown AUDIO_INTERNAL_OUTPUT='$internal_mode' (expected jack|hdmi)" >&2
                    ;;
            esac
            ;;
        *)
            printf '%s\n' "$default_card"
            return 0
            ;;
    esac
    if [[ -n "$card" ]]; then
        if [[ "$card" != "$default_card" ]]; then
            echo "Overriding HAT_CARD_NAME=$default_card with detected ALSA card id: $card ($hat_config)" >&2
        fi
        printf '%s\n' "$card"
    else
        echo "[WARN] Could not probe the ALSA card id for $hat_config — keeping profile default '$default_card'" >&2
        printf '%s\n' "$default_card"
    fi
}
