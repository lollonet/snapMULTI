#!/usr/bin/env bash
# install-conf-mirror.sh — atomic file→file mirror of install.conf
#
# Single owner of `/opt/snapmulti/install.conf` and `/opt/snapclient/install.conf`
# writes. Mirrors the canonical install.conf from the boot partition
# ($SNAP_BOOT/install.conf) to the install directories so that smoke
# checks (`scripts/smoke/check_containers.sh`, `scripts/device-smoke.sh`)
# and the diagnostic bundle (`scripts/diagnostic.sh`) have a stable
# read path regardless of whether the device is currently mounted in
# read-only mode.
#
# Why an atomic mirror (not `cp`)?
# Smoke checks may run while firstboot is still iterating. A reader
# that lands during a partial `cp` sees a truncated file and treats
# INSTALL_TYPE as empty, which causes wrong-profile dispatch. The
# temp-file + atomic `mv` pattern guarantees the reader sees either
# the old file (or no file) OR the new complete file — never partial.
#
# Why a separate module from cmdline-manager.sh / prepare-sd.sh?
# - `cmdline-manager.sh` owns runtime cmdline.txt edits (different file,
#   different concerns).
# - `prepare-sd.sh` runs on the HOST (macOS / Linux / WSL) — Bash 3.2
#   portability constraints there. This mirror runs on the Pi only
#   (Bash 5.x), and does NOT need field-level knowledge of install.conf,
#   so the two paths are kept apart.
#
# Source guard: this file is safe to source multiple times.

if [[ "${_INSTALL_CONF_MIRROR_SH_SOURCED:-0}" == "1" ]]; then
    return 0
fi
_INSTALL_CONF_MIRROR_SH_SOURCED=1

# mirror_install_conf <src-install-conf-path> <dest-dir>
#
# Copies <src> to <dest-dir>/install.conf atomically:
#   1. mkdir -p <dest-dir>
#   2. mktemp <dest-dir>/install.conf.XXXXXX (positional template — portable
#      across GNU and BSD mktemp; the GNU --tmpdir= flag is NOT used)
#   3. cp <src> <tmp>
#   4. verify INSTALL_TYPE= present in <tmp>; bail and clean up if not
#   5. mv -f <tmp> <dest-dir>/install.conf  (atomic on same filesystem)
#
# Returns:
#   0 on success
#   1 if src does not exist or is unreadable
#   2 if dest-dir cannot be created or written to
#   3 if the temp copy, the source-guard check, or the atomic publish
#     fails (covers `cp` errors, missing INSTALL_TYPE= field, and `mv`
#     errors — callers that need to distinguish these can grep the
#     stderr line emitted by the helper)
#
# Logs via log_warn / log_error if those helpers are available (the
# Pi-side caller has unified-log.sh sourced already); otherwise falls
# back to plain echo on stderr.
mirror_install_conf() {
    local src="${1:-}"
    local dest_dir="${2:-}"

    _icm_log_warn()  {
        if declare -F log_warn >/dev/null 2>&1; then log_warn "$@"; else echo "WARN: $*" >&2; fi
    }
    _icm_log_error() {
        if declare -F log_error >/dev/null 2>&1; then log_error "$@"; else echo "ERROR: $*" >&2; fi
    }

    if [[ -z "$src" || -z "$dest_dir" ]]; then
        _icm_log_error "mirror_install_conf: usage: mirror_install_conf <src> <dest-dir>"
        return 2
    fi
    if [[ ! -r "$src" ]]; then
        _icm_log_warn "mirror_install_conf: source not readable: $src"
        return 1
    fi

    # Ensure dest-dir exists. mkdir -p is idempotent.
    if ! mkdir -p "$dest_dir" 2>/dev/null; then
        _icm_log_error "mirror_install_conf: cannot create dest dir: $dest_dir"
        return 2
    fi
    if [[ ! -w "$dest_dir" ]]; then
        _icm_log_error "mirror_install_conf: dest dir not writable: $dest_dir"
        return 2
    fi

    # Portable mktemp: positional template (works on GNU + BSD).
    local tmp
    tmp=$(mktemp "${dest_dir}/install.conf.XXXXXX" 2>/dev/null) || {
        _icm_log_error "mirror_install_conf: mktemp failed in $dest_dir"
        return 2
    }

    # Copy + verify before publish. cp returns non-zero on partial write
    # (which the tmp-file pattern would still tolerate since the reader
    # never sees tmp), but we want to bail loudly so smoke later doesn't
    # find an old / stale destination file.
    if ! cp "$src" "$tmp" 2>/dev/null; then
        _icm_log_error "mirror_install_conf: cp $src -> $tmp failed"
        rm -f "$tmp"
        return 3
    fi
    if ! grep -q '^INSTALL_TYPE=' "$tmp" 2>/dev/null; then
        _icm_log_error "mirror_install_conf: copied file missing INSTALL_TYPE — refusing to publish"
        rm -f "$tmp"
        return 3
    fi

    # Atomic publish. mv -f on same filesystem is rename(2) — no reader
    # ever sees a half-written destination. mv across filesystems would
    # fall back to cp+rm and re-introduce the partial-read window;
    # callers must pass a dest-dir on the SAME filesystem as the temp
    # file (we ensure this by mktemp-ing IN dest-dir).
    if ! mv -f "$tmp" "$dest_dir/install.conf"; then
        _icm_log_error "mirror_install_conf: atomic mv failed for $dest_dir/install.conf"
        rm -f "$tmp"
        return 3
    fi
    return 0
}
