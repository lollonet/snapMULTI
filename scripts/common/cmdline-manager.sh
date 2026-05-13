#!/usr/bin/env bash
# cmdline-manager.sh — single owner of /boot/firmware/cmdline.txt mutations
#
# All snapMULTI scripts that need to add or remove kernel cmdline tokens
# source this module and call the helpers below instead of inlining sed
# patterns. Before this consolidation the same `overlayroot=tmpfs` and
# `cgroup_enable=memory cgroup_memory=1` edits lived in 4 different
# files (`scripts/deploy.sh`, `scripts/common/system-tune.sh`,
# `client/common/scripts/setup.sh`, `client/common/scripts/ro-mode.sh`)
# with byte-identical sed patterns — a single typo in any one of them
# would have produced silently-different boot configurations across
# server and client.
#
# Contract:
#   - Every helper is idempotent (grep-before-sed). Safe to call
#     repeatedly during firstboot retry or operator-driven re-runs.
#   - Helpers DO NOT log — they return 0 on success, non-zero on
#     file-discovery failure. Callers wrap them and emit info / warn /
#     ok messages so existing log surfaces stay unchanged.
#   - Best-effort: a missing cmdline.txt returns non-zero rather than
#     aborting the caller. The boot path is fragile; a refusal-mode
#     here would brick first-boot. Operators see the non-zero return
#     in the caller's log and can recover.
#
# Sourced by:
#   scripts/common/system-tune.sh     (overlayroot persist / unpersist + console=tty1)
#   scripts/deploy.sh                  (memory cgroup enable on server)
#   client/common/scripts/setup.sh    (memory cgroup enable on client)
#   client/common/scripts/ro-mode.sh  (overlayroot toggle)

# Locate the kernel cmdline file. Pi OS Bookworm/Trixie ships it as
# /boot/firmware/cmdline.txt on the standard image; the legacy
# /boot/cmdline.txt path is still seen on some custom builds. Returns
# 0 + path on stdout if found, 1 (and no output) otherwise.
cmdline_path() {
    local candidate
    for candidate in /boot/firmware/cmdline.txt /boot/cmdline.txt; do
        [[ -f "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
    done
    return 1
}

# Prepend `overlayroot=tmpfs` to cmdline.txt. The overlayroot-tools
# initramfs hook looks for this token as the FIRST entry of the
# kernel cmdline (the `1s#^#...#` sed prepends it at position 0).
# Idempotent — re-runs are no-ops when the token is already present.
cmdline_ensure_overlayroot() {
    local cmdline
    cmdline=$(cmdline_path) || return 1
    if grep -q 'overlayroot=tmpfs' "$cmdline" 2>/dev/null; then
        return 0
    fi
    sed -i '1s#^#overlayroot=tmpfs #' "$cmdline"
}

# Remove `overlayroot=tmpfs` from cmdline.txt. Tolerates leading,
# trailing, and multiple internal spaces (the cleanup steps after
# the substitution collapse them back to single spaces and strip
# edges). Idempotent.
cmdline_remove_overlayroot() {
    local cmdline
    cmdline=$(cmdline_path) || return 1
    if ! grep -q 'overlayroot=tmpfs' "$cmdline" 2>/dev/null; then
        return 0
    fi
    sed -i 's/\(^\| \)overlayroot=tmpfs\($\| \)/ /g; s/^ //; s/  */ /g; s/ $//' "$cmdline"
}

# Append `cgroup_enable=memory cgroup_memory=1` to cmdline.txt. Pi OS
# default cmdline contains `cgroup_disable=memory` (low-memory tuning
# inherited from the Pi 1 / Zero era); the kernel applies the LAST
# value, so appending these two tokens enables the memory controller
# without rewriting the original line. Docker requires this to enforce
# container memory limits — without it `docker run --memory N` is
# silently ignored. Idempotent.
cmdline_ensure_memory_cgroup() {
    local cmdline
    cmdline=$(cmdline_path) || return 1
    if grep -q 'cgroup_enable=memory' "$cmdline" 2>/dev/null; then
        return 0
    fi
    sed -i '1s/$/ cgroup_enable=memory cgroup_memory=1/' "$cmdline"
}

# Defensive: ensure `console=tty1` is present. Pi OS images normally
# ship both console=serial0,115200 and console=tty1; if a custom image
# dropped tty1, the first boot post-overlayroot would render emergency-
# mode messages on a console nobody sees, leaving the user with a
# frozen black screen. Restore tty1 before enabling overlayfs so any
# failure surface stays visible on HDMI. Idempotent.
cmdline_ensure_console_tty1() {
    local cmdline
    cmdline=$(cmdline_path) || return 1
    if grep -qE '(^| )console=tty1( |$)' "$cmdline" 2>/dev/null; then
        return 0
    fi
    sed -i '1s/$/ console=tty1/' "$cmdline"
}

# ── Generic token / pattern helpers ────────────────────────────────
# These three helpers replace ad-hoc `sed -i 's/ token//'` calls in
# callers (firstboot.sh, setup.sh). They operate on the cmdline.txt
# single line as a list of whitespace-delimited fields — NOT regex
# word-boundary matching — so tokens with punctuation (`fbcon=map:9`,
# `cgroup_memory=1`, `video=HDMI-A-1:1920M@60`) work correctly. All
# three are idempotent and validate input.

# Internal: re-emit fields as a single space-separated line + newline.
# Used by the three field-based helpers below.
_cmdline_write_fields() {
    local cmdline="$1"; shift
    # Join args with single space, terminate with newline.
    # The Pi bootloader requires the cmdline to live on one physical
    # line; trailing newline is permitted (and standard in Pi OS).
    printf '%s\n' "$*" > "$cmdline"
}

# Remove a token (exact field match). Idempotent: no-op if absent.
# Rejects empty tokens and tokens containing whitespace (would not be
# a single field anyway). Punctuation is fine.
cmdline_remove_token() {
    local token="$1"
    if [[ -z "$token" || "$token" =~ [[:space:]] ]]; then
        echo "ERROR: cmdline_remove_token: token must be non-empty and contain no whitespace" >&2
        return 2
    fi
    local cmdline
    cmdline=$(cmdline_path) || return 1
    local -a fields=() filtered=()
    # shellcheck disable=SC2034
    read -r -a fields < "$cmdline"
    local f present=0
    for f in "${fields[@]}"; do
        if [[ "$f" == "$token" ]]; then
            present=1
        else
            filtered+=("$f")
        fi
    done
    # Idempotent: skip write if nothing changed.
    (( present == 0 )) && return 0
    _cmdline_write_fields "$cmdline" "${filtered[@]}"
}

# Remove every field matching the given ERE. Used for parametric
# tokens like `video=HDMI-A-1:.*` where the value part is variable.
# Caller passes a plain ERE pattern (no leading slash, no anchors).
cmdline_remove_pattern() {
    local pattern="$1"
    if [[ -z "$pattern" ]]; then
        echo "ERROR: cmdline_remove_pattern: pattern must be non-empty" >&2
        return 2
    fi
    local cmdline
    cmdline=$(cmdline_path) || return 1
    local -a fields=() filtered=()
    # shellcheck disable=SC2034
    read -r -a fields < "$cmdline"
    local f matched=0
    for f in "${fields[@]}"; do
        if [[ "$f" =~ ^${pattern}$ ]]; then
            matched=1
        else
            filtered+=("$f")
        fi
    done
    (( matched == 0 )) && return 0
    _cmdline_write_fields "$cmdline" "${filtered[@]}"
}

# Append a token (exact field) if not already present. Idempotent.
cmdline_add_token() {
    local token="$1"
    if [[ -z "$token" || "$token" =~ [[:space:]] ]]; then
        echo "ERROR: cmdline_add_token: token must be non-empty and contain no whitespace" >&2
        return 2
    fi
    local cmdline
    cmdline=$(cmdline_path) || return 1
    local -a fields=()
    # shellcheck disable=SC2034
    read -r -a fields < "$cmdline"
    local f
    for f in "${fields[@]}"; do
        [[ "$f" == "$token" ]] && return 0  # already present
    done
    fields+=("$token")
    _cmdline_write_fields "$cmdline" "${fields[@]}"
}
