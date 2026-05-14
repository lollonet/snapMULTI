#!/usr/bin/env bash
# Regression test: firstboot.sh's install.conf reader must tolerate missing
# keys WITHOUT aborting under `set -euo pipefail`.
#
# The bug: each `VAR=$(grep -m1 '^KEY=' file | cut -d= -f2 | tr -d ...)` is
# a pipeline. When the key is missing, grep exits 1; pipefail propagates;
# the command substitution carries the non-zero status; set -e aborts the
# script. The aborts happens BEFORE the logger, TUI, or failure trap are
# initialised — so the operator sees the Pi go quiet (black screen / login
# prompt) with no log indicating WHY.
#
# Fix: append `|| true` to each pipeline. Downstream `${VAR:-default}`
# guards already handle the empty-string case; the goal here is just to
# stop set -e from killing the script before that fallback runs.
#
# This test simulates several real-world install.conf shapes:
#   - empty file (every default fires)
#   - partial config (only INSTALL_TYPE set, music block missing)
#   - full config (no regression for the happy path)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIRSTBOOT_SH="$SCRIPT_DIR/../scripts/firstboot.sh"

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

# Extract the install.conf reading block from firstboot.sh (lines 66-110 ish).
# We sed-extract from "# ── Read install.conf" through the closing `fi` of
# the advanced-options block, then prepend a SNAP_BOOT setup + a no-op
# sanitize_* stub so the extracted code runs standalone under `set -euo
# pipefail`. If the extracted code aborts, the test fails — that's the
# regression we're guarding against.
extract_reader_block() {
    sed -n '/^# ── Read install.conf/,/^# Install directories/p' "$FIRSTBOOT_SH" \
        | sed '/^# Install directories/d'
}

# Stubs for sanitize_* so the extracted block doesn't need sanitize.sh.
SANITIZE_STUBS=$(cat <<'STUBS'
sanitize_hostname() { printf '%s' "$1"; }
sanitize_nfs_export() { printf '%s' "$1"; }
sanitize_smb_share() { printf '%s' "$1"; }
sanitize_smb_user() { printf '%s' "$1"; }
# Source-guard the sanitize.sh existence check so the extracted block
# stays inside its `if [[ -f ... ]] elif [[ -f ... ]] fi` branch without
# actually loading anything (we already declared the stubs above).
STUBS
)

run_reader_with_conf() {
    local conf_path="$1"
    local tmpdir
    tmpdir=$(mktemp -d /tmp/firstboot-tolerance-XXXXXX)
    trap 'rm -rf "$tmpdir"' RETURN
    mkdir -p "$tmpdir/common"
    cp "$conf_path" "$tmpdir/install.conf"
    # Run the extracted reader block with set -euo pipefail. If the block
    # aborts because of the bug, the subshell exits non-zero and we capture
    # that via $? — assertion logic below handles the comparison.
    local block
    block=$(extract_reader_block)
    bash -c "
        set -euo pipefail
        SNAP_BOOT='$tmpdir'
        SCRIPT_DIR='$tmpdir'  # sanitize.sh fallback path; we've stubbed
        $SANITIZE_STUBS
        $block
        # Echo all vars on success so the caller can assert
        echo \"INSTALL_TYPE=\$INSTALL_TYPE\"
        echo \"MUSIC_SOURCE=\${MUSIC_SOURCE:-}\"
        echo \"NFS_SERVER=\${NFS_SERVER:-}\"
        echo \"SMB_SHARE=\${SMB_SHARE:-}\"
        echo \"SMB_USER=\${SMB_USER:-}\"
        echo \"SMB_PASS=\${SMB_PASS:-}\"
        echo \"ENABLE_READONLY=\${ENABLE_READONLY:-}\"
        echo \"IMAGE_TAG=\${IMAGE_TAG:-}\"
    " 2>&1
}

echo "=== Test 1: empty install.conf (every key missing) ==="
# This is the failure mode from the original bug report.
tmpconf=$(mktemp /tmp/test-conf-empty-XXXXXX.conf)
echo "# completely empty config" > "$tmpconf"
output=$(run_reader_with_conf "$tmpconf" 2>&1) || {
    echo "  FAIL: reader aborted under set -euo pipefail with empty conf"
    echo "  Output: $output"
    fail=$((fail + 1))
    rm -f "$tmpconf"
    exit 1
}
rm -f "$tmpconf"
assert_eq "$(echo "$output" | grep '^INSTALL_TYPE=' | cut -d= -f2)" "server" "INSTALL_TYPE defaults to 'server' when key missing"
assert_eq "$(echo "$output" | grep '^MUSIC_SOURCE=' | cut -d= -f2)" "" "MUSIC_SOURCE empty when key missing"
assert_eq "$(echo "$output" | grep '^SMB_PASS=' | cut -d= -f2)" "" "SMB_PASS empty when key missing"
assert_eq "$(echo "$output" | grep '^ENABLE_READONLY=' | cut -d= -f2)" "true" "ENABLE_READONLY defaults to 'true'"
assert_eq "$(echo "$output" | grep '^IMAGE_TAG=' | cut -d= -f2)" "latest" "IMAGE_TAG defaults to 'latest'"

echo
echo "=== Test 2: partial install.conf (INSTALL_TYPE only, no music keys) ==="
tmpconf=$(mktemp /tmp/test-conf-partial-XXXXXX.conf)
cat > "$tmpconf" <<'EOF'
INSTALL_TYPE=client
EOF
output=$(run_reader_with_conf "$tmpconf" 2>&1) || {
    echo "  FAIL: reader aborted with partial conf (only INSTALL_TYPE set)"
    echo "  Output: $output"
    fail=$((fail + 1))
    rm -f "$tmpconf"
    exit 1
}
rm -f "$tmpconf"
assert_eq "$(echo "$output" | grep '^INSTALL_TYPE=' | cut -d= -f2)" "client" "INSTALL_TYPE picks up explicit value"
assert_eq "$(echo "$output" | grep '^MUSIC_SOURCE=' | cut -d= -f2)" "" "MUSIC_SOURCE empty (no key in partial conf)"

echo
echo "=== Test 3: full install.conf (happy path — no regression) ==="
tmpconf=$(mktemp /tmp/test-conf-full-XXXXXX.conf)
cat > "$tmpconf" <<'EOF'
INSTALL_TYPE=both
MUSIC_SOURCE=nfs
NFS_SERVER=nas.local
NFS_EXPORT=/music
SMB_SERVER=
SMB_SHARE=
SMB_USER=
SMB_PASS=
ENABLE_READONLY=false
SKIP_UPGRADE=false
IMAGE_TAG=v0.7.5
VERBOSE_INSTALL=true
EOF
output=$(run_reader_with_conf "$tmpconf" 2>&1) || {
    echo "  FAIL: reader aborted on full conf (regression!)"
    echo "  Output: $output"
    fail=$((fail + 1))
    rm -f "$tmpconf"
    exit 1
}
rm -f "$tmpconf"
assert_eq "$(echo "$output" | grep '^INSTALL_TYPE=' | cut -d= -f2)" "both" "INSTALL_TYPE=both"
assert_eq "$(echo "$output" | grep '^MUSIC_SOURCE=' | cut -d= -f2)" "nfs" "MUSIC_SOURCE=nfs"
assert_eq "$(echo "$output" | grep '^NFS_SERVER=' | cut -d= -f2)" "nas.local" "NFS_SERVER=nas.local"
assert_eq "$(echo "$output" | grep '^ENABLE_READONLY=' | cut -d= -f2)" "false" "ENABLE_READONLY=false (override default)"
assert_eq "$(echo "$output" | grep '^IMAGE_TAG=' | cut -d= -f2)" "v0.7.5" "IMAGE_TAG=v0.7.5"

echo
echo '=== Test 4: password with "=" and spaces (preserved fields) ==='
# SMB_PASS uses `cut -f2-` and `tr -d '\r'` (NOT [:space:]) precisely to
# preserve passwords containing `=` and whitespace. The `|| true` must not
# alter that.
tmpconf=$(mktemp /tmp/test-conf-pw-XXXXXX.conf)
printf 'INSTALL_TYPE=client\nSMB_PASS=p@ss=word with spaces\n' > "$tmpconf"
output=$(run_reader_with_conf "$tmpconf" 2>&1) || {
    echo "  FAIL: reader aborted with complex SMB_PASS"
    echo "  Output: $output"
    fail=$((fail + 1))
    rm -f "$tmpconf"
    exit 1
}
rm -f "$tmpconf"
assert_eq "$(echo "$output" | grep '^SMB_PASS=' | cut -d= -f2-)" "p@ss=word with spaces" "SMB_PASS preserves '=' and spaces"

echo
echo "Results: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
