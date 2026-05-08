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
eval "$(sed -n '/^_write_systemd_mount_unit()/,/^}/p' "$MOUNT_SH")"

log_info() { :; }
log_warn() { :; }
log_error() { :; }

echo "Testing mount-music SMB credential cleanup..."

test_smb_cleanup() {
    local tmpdir creds_file fstab_file mount_point unit_dir mount_ok expected_creds expected_unit desc
    mount_ok="$1"
    expected_creds="$2"
    expected_unit="$3"
    desc="$4"
    tmpdir=$(mktemp -d)
    creds_file="$tmpdir/smb-creds"
    fstab_file="$tmpdir/fstab"
    mount_point="$tmpdir/smb-mount"
    unit_dir="$tmpdir/systemd"
    mkdir -p "$unit_dir"
    : > "$fstab_file"

    # Drive the subshell. We mock:
    #   - mkdir/chmod/rm/timeout: pass-through
    #   - mount: returns based on MOUNT_OK
    #   - grep -qF: real implementation
    #   - systemctl: no-op (CI runners have no systemd; the helper guards
    #     it but `systemctl ... 2>/dev/null` still exits 127 under set -e
    #     unless the function trapping is forgiving)
    #   - systemd-escape: deterministic path-to-unit-name mapper
    local run_rc=0
    MOUNT_OK="$mount_ok" \
    CREDS_FILE="$creds_file" \
    FSTAB_FILE="$fstab_file" \
    MOUNT_POINT="$mount_point" \
    UNIT_DIR="$unit_dir" \
    bash -c '
        set -euo pipefail
        '"$(declare -f setup_music_source)"'
        '"$(declare -f _write_systemd_mount_unit)"'
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
        # Mock systemctl (CI has no systemd) — always succeed.
        systemctl() { return 0; }
        # Mock systemd-escape for deterministic unit name. Only handles
        # the -p --suffix=mount case the helper uses.
        systemd-escape() {
            local path="" suffix="mount"
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    -p) shift ;;
                    --suffix=*) suffix="${1#*=}"; shift ;;
                    *) path="$1"; shift ;;
                esac
            done
            local escaped="${path#/}"; escaped="${escaped//-/\\x2d}"; escaped="${escaped//\//-}"
            printf "%s.%s" "$escaped" "$suffix"
        }
        export -f systemd-escape
        # Make `command -v systemd-escape` find our function.
        # bash export -f is enough; helpers use `&>` redirection which is fine.

        MUSIC_SOURCE="smb"
        SMB_SERVER="nas"
        SMB_SHARE="Music"
        SMB_USER="alice"
        SMB_PASS="secret"
        # Redirect helper paths into the sandbox.
        # shellcheck disable=SC2016
        eval "$(declare -f setup_music_source | sed "s|/etc/snapmulti-smb-credentials|$CREDS_FILE|g; s|/etc/fstab|$FSTAB_FILE|g; s|/media/smb-music|$MOUNT_POINT|g")"
        # shellcheck disable=SC2016
        eval "$(declare -f _write_systemd_mount_unit | sed "s|/etc/systemd/system|$UNIT_DIR|g; s|/etc/fstab|$FSTAB_FILE|g")"
        setup_music_source
    ' >/dev/null 2>&1 || run_rc=$?

    # New layout: a `.mount` unit is generated under $unit_dir (instead of
    # an /etc/fstab line). Check for the unit file rather than fstab.
    local creds_exists="false" unit_exists="false" fstab_has="false"
    [[ -f "$creds_file" ]] && creds_exists="true"
    if find "$unit_dir" -maxdepth 1 -name '*.mount' -print -quit 2>/dev/null | grep -q .; then
        unit_exists="true"
    fi
    grep -qF '//nas/Music' "$fstab_file" && fstab_has="true" || true

    assert_eq "$run_rc" "0" "$desc: helper exits cleanly"
    assert_eq "$creds_exists" "$expected_creds" "$desc: creds file state"
    assert_eq "$unit_exists" "$expected_unit" "$desc: .mount unit generated"
    # Defensive: the new flow MUST NOT write /etc/fstab for SMB.
    assert_eq "$fstab_has" "false" "$desc: NO fstab line written (overlayroot-safe)"

    rm -rf "$tmpdir"
}

# Both branches generate the .mount unit; creds are kept for systemd retry.
test_smb_cleanup "false" "true" "true" "failed mount keeps creds + .mount unit for retry"
test_smb_cleanup "true"  "true" "true" "successful mount keeps creds + .mount unit"

echo ""
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
