#!/usr/bin/env bash
# scripts/smoke/check_recovery.sh — diagnostic bundle on the boot partition
#
# Sourced by device-smoke.sh. Relies on helpers from the main script.
#
# What this catches:
#   Two diagnostic artefacts can land on the FAT32 boot partition (the
#   offline recovery path — see pattern_boot_partition_rescue):
#
#     - /boot/firmware/snapmulti-diag-<reason>-<ts>.tar.gz
#       on-demand bundle from scripts/diagnostic.sh (install failure
#       trap or manual run by the operator for a bug report)
#
#     - /boot/firmware/diagnostics/<TIMESTAMP>/
#       periodic snapshot (every 15 min) from snapmulti-diagnostics.timer
#       → save-diagnostics — keeps the last 12 (3 h of context)
#
#   This module surfaces both: it tells the operator at a glance whether
#   the recovery path has anything to read when something later breaks.
#
# Reference messaging guidelines in scripts/smoke/MESSAGING.md.

# shellcheck disable=SC2154

_BOOT_FW=/boot/firmware

check_recovery() {
    section "Recovery"

    if [[ ! -d "$_BOOT_FW" ]]; then
        info "Recovery artefacts check skipped (N/A on this host — $_BOOT_FW not present)"
        return 0
    fi

    # On-demand bundles from scripts/diagnostic.sh.
    # Glob: bash leaves pattern literal if nothing matches.
    local bundles=( "$_BOOT_FW"/snapmulti-diag-*.tar.gz )
    local bundle_count=0
    if [[ -e "${bundles[0]}" ]]; then
        bundle_count=${#bundles[@]}
    fi

    # Periodic snapshots from snapmulti-diagnostics.timer.
    # Directories named like YYYYMMDD-HHMMSS under /boot/firmware/diagnostics/.
    local snap_dir="$_BOOT_FW/diagnostics"
    local snap_count=0
    local newest_snap_mtime=0
    if [[ -d "$snap_dir" ]]; then
        local d m
        while IFS= read -r d; do
            [[ -z "$d" ]] && continue
            snap_count=$(( snap_count + 1 ))
            m=$(stat -c %Y "$d" 2>/dev/null || echo 0)
            (( m > newest_snap_mtime )) && newest_snap_mtime=$m
        done < <(find "$snap_dir" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' 2>/dev/null)
    fi

    # No artefacts at all → info (timer hasn't fired yet, no install failure).
    if (( bundle_count == 0 && snap_count == 0 )); then
        info "Recovery artefacts on $_BOOT_FW: none yet (periodic snapshot timer fires every 15 min; on-demand bundle from 'sudo scripts/diagnostic.sh')"
        return 0
    fi

    # On-demand bundle report.
    if (( bundle_count > 0 )); then
        local newest_b_mtime=0 m sz total_bytes=0
        for b in "${bundles[@]}"; do
            m=$(stat -c %Y "$b" 2>/dev/null || echo 0)
            sz=$(stat -c %s "$b" 2>/dev/null || echo 0)
            total_bytes=$(( total_bytes + sz ))
            (( m > newest_b_mtime )) && newest_b_mtime=$m
        done
        local b_age_min=0
        (( newest_b_mtime > 0 )) && b_age_min=$(( ( $(date +%s) - newest_b_mtime ) / 60 ))
        local b_human
        if (( total_bytes > 1024 * 1024 )); then
            b_human="$(( total_bytes / 1024 / 1024 )) MB"
        elif (( total_bytes > 1024 )); then
            b_human="$(( total_bytes / 1024 )) KB"
        else
            b_human="${total_bytes} B"
        fi
        if (( bundle_count >= 5 )); then
            warn "On-demand recovery bundles on $_BOOT_FW: $bundle_count (${b_human} total) — consider clearing older ones to free FAT32 space"
        else
            pass_check "On-demand recovery bundles on $_BOOT_FW: $bundle_count (${b_human}, newest ${b_age_min} min old)"
        fi
    fi

    # Periodic snapshot report.
    if (( snap_count > 0 )); then
        local snap_age_min=0
        (( newest_snap_mtime > 0 )) && snap_age_min=$(( ( $(date +%s) - newest_snap_mtime ) / 60 ))
        if (( snap_age_min > 30 )); then
            warn "Periodic diagnostic snapshots on $_BOOT_FW: $snap_count present, newest ${snap_age_min} min old — timer may have stopped (expected interval is 15 min)"
        else
            pass_check "Periodic diagnostic snapshots on $_BOOT_FW: $snap_count present, newest ${snap_age_min} min old"
        fi
    fi

    # /boot/firmware FAT32 free space. Partition is fixed at ~512MB on
    # Pi Imager defaults. Full = no more diagnostic bundles, no MPD
    # backup, no kernel/firmware upgrade. Hard cap on a path the user
    # cannot grow.
    local fw_avail_kb fw_total_kb
    read -r fw_avail_kb fw_total_kb < <(df --output=avail,size -k "$_BOOT_FW" 2>/dev/null | tail -1)
    if [[ -n "$fw_avail_kb" && -n "$fw_total_kb" && "$fw_total_kb" -gt 0 ]]; then
        local fw_pct=$(( 100 * (fw_total_kb - fw_avail_kb) / fw_total_kb ))
        local fw_avail_mb=$(( fw_avail_kb / 1024 ))
        if (( fw_pct > 90 )); then
            fail_check "Boot partition ${fw_pct}% full (${fw_avail_mb} MB free) — no room for diagnostic bundles, MPD backup, or kernel upgrade"
        elif (( fw_pct > 75 )); then
            warn "Boot partition ${fw_pct}% full (${fw_avail_mb} MB free) — clear old snapshots to free space"
        else
            pass_check "Boot partition ${fw_pct}% used (${fw_avail_mb} MB free)"
        fi
    fi
}
