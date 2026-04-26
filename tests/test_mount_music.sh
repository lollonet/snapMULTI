#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOUNT_SH="$SCRIPT_DIR/../scripts/common/mount-music.sh"

pass=0
fail=0

assert_eq() {
    local actual="$1" expected="$2" desc="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc (got '$actual', expected '$expected')"
        fail=$((fail + 1))
    fi
}

eval "$(sed -n '/^setup_music_source()/,/^}/p' "$MOUNT_SH")"

log_info() { :; }
log_warn() { :; }
log_error() { :; }

echo "Testing mount-music SMB credential cleanup..."

test_smb_cleanup() {
    local tmpdir creds_file fstab_file mount_point mount_ok expected_creds expected_fstab desc
    mount_ok="$1"
    expected_creds="$2"
    expected_fstab="$3"
    desc="$4"
    tmpdir=$(mktemp -d)
    creds_file="$tmpdir/smb-creds"
    fstab_file="$tmpdir/fstab"
    mount_point="$tmpdir/smb-mount"
    : > "$fstab_file"

    MUSIC_SOURCE="smb"
    SMB_SERVER="nas"
    SMB_SHARE="Music"
    SMB_USER="alice"
    SMB_PASS="secret"

    mkdir() { command mkdir "$@"; }
    chmod() { command chmod "$@"; }
    timeout() { shift; "$@"; }
    mount() { [[ "${MOUNT_OK:-false}" == "true" ]]; }
    grep() {
        if [[ "$1" == "-qF" ]]; then
            local needle="$2" file="$3"
            command grep -qF "$needle" "$file"
            return $?
        fi
        command grep "$@"
    }
    rm() { command rm "$@"; }

    export MUSIC_PATH=""

    # Override paths by temporarily editing function-local expectations via subshell
    local run_rc=0
    MOUNT_OK="$mount_ok" CREDS_FILE="$creds_file" FSTAB_FILE="$fstab_file" MOUNT_POINT="$mount_point" bash -c '
        set -euo pipefail
        '"$(declare -f setup_music_source)"'
        log_info() { :; }
        log_warn() { :; }
        log_error() { :; }
        mkdir() { command mkdir "$@"; }
        chmod() { command chmod "$@"; }
        timeout() { shift; "$@"; }
        mount() { [[ "${MOUNT_OK:-false}" == "true" ]]; }
        grep() {
            if [[ "$1" == "-qF" ]]; then
                local needle="$2" file="$3"
                command grep -qF "$needle" "$file"
                return $?
            fi
            command grep "$@"
        }
        rm() { command rm "$@"; }
        MUSIC_SOURCE="smb"
        SMB_SERVER="nas"
        SMB_SHARE="Music"
        SMB_USER="alice"
        SMB_PASS="secret"
        # shellcheck disable=SC2016
        eval "$(declare -f setup_music_source | sed "s|/etc/snapmulti-smb-credentials|$CREDS_FILE|g; s|/etc/fstab|$FSTAB_FILE|g; s|/media/smb-music|$MOUNT_POINT|g")"
        setup_music_source
    ' >/dev/null 2>&1 || run_rc=$?

    local creds_exists="false" fstab_has="false"
    [[ -f "$creds_file" ]] && creds_exists="true"
    grep -qF '//nas/Music' "$fstab_file" && fstab_has="true" || true

    assert_eq "$run_rc" "0" "$desc: helper exits cleanly"
    assert_eq "$creds_exists" "$expected_creds" "$desc: creds file state"
    assert_eq "$fstab_has" "$expected_fstab" "$desc: fstab state"

    rm -rf "$tmpdir"
}

# Failed mount: creds and fstab kept for systemd retry on next boot
test_smb_cleanup "false" "true" "true" "failed mount keeps creds+fstab for retry"
test_smb_cleanup "true" "true" "true" "successful mount keeps creds for fstab"

echo ""
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
