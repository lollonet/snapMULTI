#!/usr/bin/env bash
# scripts/smoke/check_mounts.sh — NFS/SMB automount state (server only)
#
# Sourced by device-smoke.sh. Relies on helpers from the main script.
#
# What this catches:
# PR #334 introduced a lazy `.automount` companion next to the `.mount`
# unit for NFS/SMB music shares. The pattern is:
#   - `.automount` is enabled (WantedBy=multi-user.target)
#   - `.mount` is NOT enabled directly — it is fired on first access
# Whether the actual mount has happened depends on whether MPD has
# already scanned the library; in steady state both should be active.
# The previous form (eager `.mount` enable) made `snapmulti-server.service`
# hard-depend on the share — a slow NAS killed startup of every service
# in the stack, including those that don't touch music at all.
#
# This module asserts the post-PR-#334 state holds: the automount unit
# exists, is enabled, and is active. It also surfaces whether the mount
# fired (informational — not a fail when MPD has not scanned yet).

# shellcheck disable=SC2154

check_mounts() {
    [[ "$MODE" == "server" || "$MODE" == "both" ]] || return 0

    section "Mounts"

    # Discover the music source from the persisted server .env. Local
    # sources don't generate .mount/.automount units (kernel handles
    # them), so the section is a no-op unless source is network-backed.
    local server_env music_source music_path
    server_env="${SERVER_DIR:-/opt/snapmulti}/.env"
    if [[ ! -f "$server_env" ]]; then
        info "Server .env not found — mount unit checks skipped"
        return 0
    fi
    # Strip surrounding quotes — `.env` may store values as
    # `MUSIC_SOURCE="nfs"` (a sibling .env writer quotes by default).
    # Without `tr -d '"'` the case match below silently misses and the
    # entire mount-unit section returns "not network-backed" with no
    # signal — same pattern used in check_audio_modules.sh and check_qos.sh.
    # `cut -d= -f2-` (not `-f2`) preserves any '=' inside the value.
    music_source=$(grep '^MUSIC_SOURCE=' "$server_env" 2>/dev/null | cut -d= -f2- | tr -d '"' | sed 's/[[:space:]]*$//' || true)
    music_path=$(grep '^MUSIC_PATH=' "$server_env" 2>/dev/null | cut -d= -f2- | tr -d '"' | sed 's/[[:space:]]*$//' || true)

    case "$music_source" in
        nfs|smb|network)
            : # check below
            ;;
        *)
            info "MUSIC_SOURCE='${music_source:-unset}' — not network-backed, mount unit check skipped"
            return 0
            ;;
    esac

    # Compute the systemd-escaped unit names from the mount path so
    # this works with any custom MUSIC_PATH (default /media/nfs-music
    # or /media/smb-music; user-overridden paths are rare but valid).
    if ! command -v systemd-escape >/dev/null 2>&1; then
        warn "systemd-escape not available — mount unit name resolution skipped"
        return 0
    fi
    local mount_name automount_name
    mount_name=$(systemd-escape -p --suffix=mount "$music_path" 2>/dev/null)
    automount_name=$(systemd-escape -p --suffix=automount "$music_path" 2>/dev/null)
    if [[ -z "$mount_name" || -z "$automount_name" ]]; then
        fail_check "Could not derive systemd unit names from MUSIC_PATH='$music_path'"
        return 0
    fi

    # 1. Unit files exist on disk.
    if [[ -f "/etc/systemd/system/$automount_name" ]]; then
        pass_check "$automount_name unit file present in /etc/systemd/system/"
    else
        fail_check "$automount_name unit file missing — mount-music.sh did not run or failed"
    fi
    if [[ -f "/etc/systemd/system/$mount_name" ]]; then
        pass_check "$mount_name unit file present in /etc/systemd/system/"
    else
        fail_check "$mount_name unit file missing"
    fi

    # 1.5 Unit-file CONTENT regression guard for the `.automount`
    # ordering cycle that caused the v0.7.0 first-boot failure on
    # snapvideo and snapdigi (PR #337). Adding `After=network-online.target`
    # or `Wants=network-online.target` to the .automount section creates
    # a cycle (sysinit → local-fs → automount → network-online → ... →
    # sysinit). systemd resolves it by deleting local-fs.target and
    # sockets.target — the device boots in a degraded state.
    #
    # The systemd-fstab-generator pattern is: ordering on the .mount,
    # NEVER on the .automount. This assertion enforces that pattern.
    # `is-enabled` / `is-active` checks above don't catch this — they
    # would pass even with the wrong directives in the file.
    if [[ -f "/etc/systemd/system/$automount_name" ]]; then
        # Strip comments before grepping so a comment that mentions
        # the directive (e.g. our own NOTE explaining why it must NOT
        # be there) doesn't false-fail the check.
        local automount_active_lines
        automount_active_lines=$(grep -v '^[[:space:]]*#' "/etc/systemd/system/$automount_name" 2>/dev/null || true)
        if echo "$automount_active_lines" | grep -qE '^[[:space:]]*(After|Wants|Requires|BindsTo)=.*network-online\.target'; then
            fail_check "$automount_name carries network-online.target ordering (PR #334 regression — boot-time ordering cycle)"
        else
            pass_check "$automount_name has no network-online ordering (no boot-time cycle)"
        fi
        # nss-lookup is a similar trap — DNS lookups are not needed
        # before the actual mount fires, only the .mount unit itself
        # benefits from waiting for nss.
        if echo "$automount_active_lines" | grep -qE '^[[:space:]]*(After|Wants|Requires|BindsTo)=.*nss-lookup\.target'; then
            warn "$automount_name carries nss-lookup.target ordering — moving it to .mount avoids unnecessary boot-time dependency"
        fi
    fi

    # 2. The .automount must be enabled. The .mount must NOT be —
    # eager .mount enable is the regression PR #334 closed.
    local am_state mount_state
    am_state=$(systemctl is-enabled "$automount_name" 2>/dev/null || echo "missing")
    case "$am_state" in
        enabled|enabled-runtime)
            pass_check "$automount_name is enabled (lazy mount path)"
            ;;
        *)
            fail_check "$automount_name is '$am_state' (expected enabled)"
            ;;
    esac
    mount_state=$(systemctl is-enabled "$mount_name" 2>/dev/null || echo "static")
    case "$mount_state" in
        static|disabled|missing)
            pass_check "$mount_name is '$mount_state' (NOT eager-enabled — correct)"
            ;;
        enabled|enabled-runtime)
            fail_check "$mount_name is eager-enabled — slow NAS will block snapmulti-server.service startup (PR #334 regression)"
            ;;
    esac

    # 3. The .automount must be active (running). Without this the
    # watch on the mount point is not in place and MPD's first
    # readdir() will get an empty directory instead of triggering NFS.
    if systemctl is-active --quiet "$automount_name" 2>/dev/null; then
        pass_check "$automount_name is active (watching $music_path)"
    else
        fail_check "$automount_name is NOT active — first access to $music_path will not trigger the mount"
    fi

    # 4. The .mount fires on demand. INFO-only when not yet active —
    # MPD may not have scanned yet (start_period 300s). When active,
    # confirm the mount source matches what's in the unit so a stale
    # /etc/fstab line is not winning the race.
    if systemctl is-active --quiet "$mount_name" 2>/dev/null; then
        local what_from_unit what_from_mount
        what_from_unit=$(grep -E '^What=' "/etc/systemd/system/$mount_name" 2>/dev/null | head -1 | cut -d= -f2- || true)
        # mount(1) format: SOURCE on TARGET type FSTYPE (OPTIONS).
        # Filter on $5 (filesystem type) explicitly — using a free
        # regex on the whole line would match the path itself when
        # MUSIC_PATH contains a substring like "nfs" (e.g. the
        # default /media/nfs-music) and would pick up the autofs
        # watcher line ("systemd-1 on /media/nfs-music type autofs")
        # instead of the actual NFS / CIFS mount.
        what_from_mount=$(mount 2>/dev/null | awk -v p="$music_path" '$3 == p && $5 ~ /^(nfs|nfs4|cifs)$/ {print $1; exit}' || true)
        if [[ -n "$what_from_unit" && "$what_from_unit" == "$what_from_mount" ]]; then
            pass_check "$mount_name is active and source matches unit ($what_from_unit)"
        elif [[ -n "$what_from_mount" ]]; then
            warn "$mount_name is active but source diverges: unit='$what_from_unit' actual='$what_from_mount'"
        else
            warn "$mount_name reports active but $music_path is not in mount(1) output"
        fi
    else
        info "$mount_name not yet fired (MPD may still be scanning — non-fatal)"
    fi
}
