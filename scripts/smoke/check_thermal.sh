#!/usr/bin/env bash
# scripts/smoke/check_thermal.sh — current SoC temperature
#
# Sourced by device-smoke.sh. Relies on section / pass_check / fail_check
# / warn / info helpers from the main script.
#
# What this catches:
#   Pi 4 / 3B+ throttle the ARM clock at 80 °C and start an emergency soft
#   shutdown at 85 °C; Pi Zero 2W behaves similarly with slightly less
#   thermal headroom because of its smaller die spreader. Smoke does not
#   wait for the throttle bits to flip — by the time `vcgencmd
#   get_throttled` reports the soft-temp-limit bit (handled by
#   check_system.sh section 6) audio glitches are already happening.
#   Reading the instantaneous temperature catches "running hot but no
#   throttling yet" cases that point at enclosure / airflow / ambient
#   issues operators can fix BEFORE the throttle event.
#
# Thresholds (Pi 4 / 3B+ / Zero 2W all share the same ARM throttle point):
#   < 75 °C  → pass
#   75-79 °C → warn ("hot, headroom shrinking")
#   ≥ 80 °C  → fail ("throttling imminent — check enclosure/airflow")
# Was 70 °C warn floor; raised because Pi 4 under sustained Snapcast+display load routinely sits at 65-75 °C with no thermal issue. Warn within 5 °C of the ARM soft-throttle is the meaningful signal.
#
# Source preference:
#   1. `vcgencmd measure_temp` — VideoCore firmware path, reports the SoC
#      die temp directly. This is the same sensor the throttle logic
#      reads internally, so the value is the authoritative one to compare
#      against the 80 °C limit.
#   2. `/sys/class/thermal/thermal_zone0/temp` — generic Linux fallback
#      (millidegrees Celsius). Works on x86 dev boxes and on Pi when
#      vcgencmd is missing for whatever reason.
#   3. No sensor available — emit a single info line and return. Not a
#      fail: snapMULTI may run in a sandbox / VM where no thermal info
#      is exposed.
#
# Throttle history (under-voltage, freq cap, soft temp limit) is checked
# by check_system.sh section 6 and intentionally NOT duplicated here.
# This module reports temperature only.

# shellcheck disable=SC2154

check_thermal() {
    section "Thermal"

    local temp_milli="" source=""

    if command -v vcgencmd >/dev/null 2>&1; then
        # `|| true` so a vcgencmd that exists but fails (missing VideoCore
        # permissions, stub package on a non-Pi runner, firmware iface
        # unavailable) doesn't abort the smoke under the caller's `set -e`.
        # Empty `raw` then naturally falls through to the sysfs branch.
        local raw
        raw=$(vcgencmd measure_temp 2>/dev/null || true)
        # Format is `temp=58.3'C`. Strip prefix and unit, multiply by 1000
        # so we can do integer-only comparisons (avoid floats / bc).
        if [[ "$raw" =~ ^temp=([0-9]+)\.([0-9])\'?C ]]; then
            temp_milli=$(( ${BASH_REMATCH[1]} * 1000 + ${BASH_REMATCH[2]} * 100 ))
            source="vcgencmd"
        fi
    fi

    if [[ -z "$temp_milli" ]] && [[ -r /sys/class/thermal/thermal_zone0/temp ]]; then
        local raw
        raw=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo "")
        # /sys reports millidegrees as an integer string. Sanity-bound:
        # 0..150 °C — anything outside is a malformed read or a virtual
        # zone (some VMs expose `0` or huge values).
        if [[ "$raw" =~ ^-?[0-9]+$ ]] && (( raw >= 0 && raw <= 150000 )); then
            temp_milli="$raw"
            source="sysfs"
        fi
    fi

    if [[ -z "$temp_milli" ]]; then
        info "No thermal sensor accessible (no vcgencmd, no /sys/class/thermal) — skipping"
        return
    fi

    # Integer comparison only — no awk/bc needed.
    local temp_c temp_dec
    temp_c=$(( temp_milli / 1000 ))
    temp_dec=$(( (temp_milli % 1000) / 100 ))

    if (( temp_milli >= 80000 )); then
        fail_check "SoC ${temp_c}.${temp_dec}°C via ${source} — at/over 80°C throttle threshold (check enclosure / airflow / ambient)"
    elif (( temp_milli >= 75000 )); then
        warn "SoC ${temp_c}.${temp_dec}°C via ${source} — within 5°C of the 80°C throttle (consider better cooling under sustained load)"
    else
        pass_check "SoC ${temp_c}.${temp_dec}°C via ${source} (below 75°C warn floor)"
    fi
}
