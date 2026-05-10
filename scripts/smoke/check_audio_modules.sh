#!/usr/bin/env bash
# scripts/smoke/check_audio_modules.sh — kernel audio modules consistency
#
# Sourced by device-smoke.sh. Relies on helpers from the main script.
#
# What this catches:
# The original Audio section validates that the ALSA card NAME (string
# in /proc/asound/card0/id) matches what's expected for the configured
# HAT — but a hostile mismatch can sneak in: the device-tree overlay
# loaded a generic codec module, no HAT-specific module is loaded, the
# card name happens to match by coincidence (e.g. fake `sndrpihifiberry`
# from a generic codec), but the I2S timing or DAC chip is wrong and
# audio plays at half-speed or with clicks.
#
# This module checks the kernel modules ACTUALLY loaded against the
# expected list for the configured HAT. It's mode-agnostic — both
# server and client devices have ALSA hardware to validate.

# shellcheck disable=SC2154

# HAT name → list of kernel-module name prefixes that MUST appear in
# `lsmod` output. Add entries when a new HAT is supported. The lookup
# at line 78 uses `grep -qF` (fixed-string substring match), so
# `snd_soc_pcm512x` matches both `snd_soc_pcm512x` and
# `snd_soc_pcm512x_i2c` (lsmod normalises underscores). Patterns that
# require real regex (alternation, anchors, character classes) are
# NOT supported here — `-F` treats brackets etc. as literals.
declare -A _HAT_MODULES=(
    ["hifiberry-dacplus"]="snd_soc_hifiberry_dacplus snd_soc_pcm512x"
    ["hifiberry-dacplusadc"]="snd_soc_hifiberry_dacplusadc snd_soc_pcm512x"
    ["hifiberry-digi"]="snd_soc_hifiberry_digi snd_soc_wm8804"
    ["hifiberry-amp2"]="snd_soc_hifiberry_amp"
    ["iqaudio-dacplus"]="snd_soc_iqaudio_dac snd_soc_pcm512x"
    ["iqaudio-codec"]="snd_soc_iqaudio_codec snd_soc_da7213"
    ["allo-boss2"]="snd_soc_allo_boss2_dac snd_soc_pcm512x"
    ["innomaker-dac"]="snd_soc_pcm512x"
    ["adafruit-i2s"]="snd_soc_simple_card snd_soc_max98357a"
    ["wm8960-soundcard"]="snd_soc_wm8960"
    ["usb-audio"]="snd_usb_audio"
    ["internal-audio"]="snd_bcm2835"
)

check_audio_modules() {
    section "Audio Modules"

    # Resolve HAT_CONFIG from server or client .env (whichever exists).
    local conf hat_config=""
    for conf in "${SERVER_DIR:-/opt/snapmulti}/.env" "${CLIENT_DIR:-/opt/snapclient}/.env"; do
        if [[ -f "$conf" ]]; then
            local probe
            probe=$(grep '^HAT_CONFIG=' "$conf" 2>/dev/null | cut -d= -f2- | tr -d '"' | sed 's/[[:space:]]*$//' || true)
            [[ -n "$probe" ]] && { hat_config="$probe"; break; }
        fi
    done

    if [[ -z "$hat_config" ]]; then
        info "HAT_CONFIG not set in .env — kernel module check skipped"
        return 0
    fi

    info "HAT_CONFIG=$hat_config"

    # Look up the expected modules for this HAT.
    local expected="${_HAT_MODULES[$hat_config]:-}"
    if [[ -z "$expected" ]]; then
        info "HAT '$hat_config' has no expected-modules list (add to scripts/smoke/check_audio_modules.sh _HAT_MODULES) — skipped"
        return 0
    fi

    # Snapshot lsmod once and grep against it. Faster than `lsmod | grep`
    # per module (saves a fork-per-module on a slow Pi Zero).
    local lsmod_dump
    lsmod_dump=$(lsmod 2>/dev/null || true)
    if [[ -z "$lsmod_dump" ]]; then
        warn "lsmod unavailable — module check skipped"
        return 0
    fi

    local missing=() found=()
    # Word-splitting on $expected is intentional — the value is a
    # space-separated list of module-name prefixes (see _HAT_MODULES
    # above). Storing as an array would require a parallel parser for
    # the literal table; the current form is simpler and safe because
    # all values are controlled by this file.
    # shellcheck disable=SC2086
    for mod in $expected; do
        if echo "$lsmod_dump" | awk '{print $1}' | grep -qF "$mod"; then
            found+=("$mod")
        else
            missing+=("$mod")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        local joined
        joined=$(IFS=','; echo "${found[*]}")
        pass_check "All expected kernel modules loaded for $hat_config: $joined"
    else
        local joined_missing joined_found
        joined_missing=$(IFS=','; echo "${missing[*]}")
        joined_found=$(IFS=','; echo "${found[*]}")
        fail_check "Missing kernel module(s) for $hat_config: $joined_missing (loaded: ${joined_found:-none})"
    fi

    # Cross-check: I2S codec module is loaded (via snd_soc_bcm2835_i2s
    # or equivalent platform driver). Without it, no audio path on Pi.
    # USB cards are exempt — they don't go through I2S.
    case "$hat_config" in
        usb-audio|internal-audio)
            : # not via I2S
            ;;
        *)
            if echo "$lsmod_dump" | awk '{print $1}' | grep -qE '^snd_soc_bcm2835_i2s$'; then
                pass_check "I2S platform driver loaded (snd_soc_bcm2835_i2s)"
            else
                fail_check "I2S platform driver NOT loaded — HAT will not produce audio (was dtoverlay applied?)"
            fi
            ;;
    esac
}
