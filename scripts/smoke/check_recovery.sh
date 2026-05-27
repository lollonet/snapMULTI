#!/usr/bin/env bash
# scripts/smoke/check_recovery.sh — diagnostic bundle on the boot partition
#
# Sourced by device-smoke.sh. Relies on helpers from the main script.
#
# What this catches:
#   scripts/diagnostic.sh drops a `snapmulti-diag-<reason>-<ts>.tar.gz`
#   bundle into /boot/firmware/ by default. The FAT32 boot partition
#   survives rootfs failure, overlayroot wedge, or no-WiFi states — it is
#   the project's offline recovery path (see pattern_boot_partition_rescue
#   in the maintainer notes). Without a bundle there, a broken Pi can
#   only be diagnosed by pulling the SD and reading the rootfs from a
#   second machine — much slower than reading a tarball off the FAT32.
#
# Status semantics:
#   pass  — at least one bundle present (recovery path is live, the user
#           knows where to look)
#   info  — no bundle yet (normal on a clean install; the file appears
#           after the first install failure or a manual diagnostic.sh run)
#   warn  — many bundles piled up (FAT32 has a few-hundred-MB budget on
#           a typical Pi OS image — clean old ones before they squeeze
#           cmdline.txt / config.txt rewrites)
#
# Reference messaging guidelines in scripts/smoke/MESSAGING.md.

# shellcheck disable=SC2154

_BOOT_FW=/boot/firmware

check_recovery() {
    section "Recovery"

    if [[ ! -d "$_BOOT_FW" ]]; then
        info "Diagnostic bundle check skipped (N/A on this host — $_BOOT_FW not present)"
        return 0
    fi

    # Glob match — bash leaves the pattern literal if nothing matches,
    # so test the first element for existence before counting.
    local bundles=( "$_BOOT_FW"/snapmulti-diag-*.tar.gz )
    local count=0
    if [[ -e "${bundles[0]}" ]]; then
        count=${#bundles[@]}
    fi

    if (( count == 0 )); then
        info "Diagnostic bundle on $_BOOT_FW: none yet (created automatically on install failure, or manually via 'sudo scripts/diagnostic.sh')"
        return 0
    fi

    # Newest bundle: its mtime tells us how fresh the recovery path is.
    # Smallest stat dependency — no `find -printf`, no awk.
    local newest_mtime=0 m
    local total_bytes=0 sz
    for b in "${bundles[@]}"; do
        m=$(stat -c %Y "$b" 2>/dev/null || echo 0)
        sz=$(stat -c %s "$b" 2>/dev/null || echo 0)
        total_bytes=$(( total_bytes + sz ))
        if (( m > newest_mtime )); then
            newest_mtime=$m
        fi
    done

    local newest_age_min=0
    if (( newest_mtime > 0 )); then
        newest_age_min=$(( ( $(date +%s) - newest_mtime ) / 60 ))
    fi

    # Human-friendly size — bytes → KB/MB. Avoid `numfmt` for portability.
    local total_human
    if (( total_bytes > 1024 * 1024 )); then
        total_human="$(( total_bytes / 1024 / 1024 )) MB"
    elif (( total_bytes > 1024 )); then
        total_human="$(( total_bytes / 1024 )) KB"
    else
        total_human="${total_bytes} B"
    fi

    if (( count >= 5 )); then
        warn "Diagnostic bundles on $_BOOT_FW: $count (${total_human} total) — consider clearing older ones to free FAT32 space (newest is ${newest_age_min} min old)"
    elif (( count == 1 )); then
        pass_check "Diagnostic bundle on $_BOOT_FW: 1 present (${total_human}, ${newest_age_min} min old) — recovery path live"
    else
        pass_check "Diagnostic bundles on $_BOOT_FW: $count present (${total_human} total, newest ${newest_age_min} min old)"
    fi
}
