#!/usr/bin/env bash
# Functional + atomicity tests for scripts/common/install-conf-mirror.sh.
#
# The helper is sourceable with no top-level side effects — we source
# it directly and drive it against tmpfiles. Covers:
#   1. Happy path — src copied to dest with INSTALL_TYPE preserved.
#   2. Idempotency — second mirror call produces byte-identical output.
#   3. Missing source — returns 1, leaves dest unchanged.
#   4. Unwritable dest dir — returns 2, no partial file at dest.
#   5. Missing INSTALL_TYPE in source — returns 3, no partial file.
#   6. Concurrent reader never sees partial file (atomic mv proof).
#   7. Source guard: re-sourcing is a no-op.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIRROR_SH="$SCRIPT_DIR/../scripts/common/install-conf-mirror.sh"

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

assert_contains() {
    local haystack="$1" needle="$2" desc="$3"
    if grep -qF -- "$needle" <<<"$haystack"; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc (missing '$needle')"
        fail=$((fail + 1))
    fi
}

echo "=== Static checks ==="
assert_eq "$(test -f "$MIRROR_SH" && echo yes)" "yes" "install-conf-mirror.sh exists"
assert_eq "$(bash -n "$MIRROR_SH" 2>&1 && echo OK)" "OK" "bash -n clean"
if command -v shellcheck >/dev/null 2>&1; then
    assert_eq "$(shellcheck -S warning "$MIRROR_SH" >/dev/null 2>&1 && echo OK)" "OK" "shellcheck -S warning clean"
fi

# shellcheck source=../scripts/common/install-conf-mirror.sh
source "$MIRROR_SH"
assert_eq "$(declare -F mirror_install_conf >/dev/null 2>&1 && echo yes)" "yes" "mirror_install_conf defined"

# Setup tmp workdir.
WORKDIR=$(mktemp -d /tmp/snapmulti-mirror-test.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT
SRC="$WORKDIR/boot-install.conf"
DEST="$WORKDIR/dest"

cat > "$SRC" <<EOF
INSTALL_TYPE=server
ENABLE_READONLY=true
MUSIC_SOURCE=nfs
NFS_SERVER=nas.lan
NFS_EXPORT=/music
EOF

echo
echo "=== Happy path ==="
rm -rf "$DEST"
if mirror_install_conf "$SRC" "$DEST"; then
    echo "  PASS: mirror succeeds (rc=0)"; pass=$((pass + 1))
else
    echo "  FAIL: mirror returned non-zero"; fail=$((fail + 1))
fi
assert_eq "$(test -f "$DEST/install.conf" && echo yes)" "yes" "destination install.conf exists"
src_md5=$(md5 -q "$SRC" 2>/dev/null || md5sum "$SRC" | awk '{print $1}')
dest_md5=$(md5 -q "$DEST/install.conf" 2>/dev/null || md5sum "$DEST/install.conf" | awk '{print $1}')
assert_eq "$dest_md5" "$src_md5" "destination is byte-identical to source"

echo
echo "=== Idempotency ==="
mirror_install_conf "$SRC" "$DEST" >/dev/null 2>&1
dest_md5_2=$(md5 -q "$DEST/install.conf" 2>/dev/null || md5sum "$DEST/install.conf" | awk '{print $1}')
assert_eq "$dest_md5_2" "$src_md5" "second mirror call produces identical destination"

# No leftover temp files from either call.
leftover=$(find "$DEST" -name 'install.conf.*' -type f 2>/dev/null | head -1)
assert_eq "$leftover" "" "no leftover temp files after successful mirror"

echo
echo "=== Failure: missing source ==="
rc=0
mirror_install_conf "$WORKDIR/does-not-exist" "$DEST" >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "1" "missing source returns rc=1"
# Destination still has the OLD copy — no truncation.
dest_md5_3=$(md5 -q "$DEST/install.conf" 2>/dev/null || md5sum "$DEST/install.conf" | awk '{print $1}')
assert_eq "$dest_md5_3" "$src_md5" "destination preserved after failed mirror (rc=1)"

echo
echo "=== Failure: unwritable dest dir ==="
RO_DEST="$WORKDIR/readonly-dest"
mkdir -p "$RO_DEST"
chmod 555 "$RO_DEST"
rc=0
mirror_install_conf "$SRC" "$RO_DEST" >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "2" "unwritable dest returns rc=2"
# No install.conf created at the unwritable dest.
assert_eq "$(test -f "$RO_DEST/install.conf" && echo yes || echo no)" "no" "no install.conf at unwritable dest"
chmod 755 "$RO_DEST"

echo
echo "=== Failure: missing INSTALL_TYPE in source ==="
BAD_SRC="$WORKDIR/no-install-type.conf"
cat > "$BAD_SRC" <<EOF
# placeholder install.conf — INSTALL_TYPE deliberately absent
MUSIC_SOURCE=local
EOF
BAD_DEST="$WORKDIR/bad-dest"
rc=0
mirror_install_conf "$BAD_SRC" "$BAD_DEST" >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "3" "source missing INSTALL_TYPE returns rc=3"
assert_eq "$(test -f "$BAD_DEST/install.conf" && echo yes || echo no)" "no" "no partial install.conf published"
leftover=$(find "$BAD_DEST" -name 'install.conf.*' -type f 2>/dev/null | head -1)
assert_eq "$leftover" "" "no orphan temp file after failed verification"

echo
echo "=== Atomicity: concurrent reader never sees partial file ==="
# Stress test: run 100 mirror cycles in a background loop while a
# reader checks the destination's INSTALL_TYPE in a tight loop.
# Without temp+mv atomicity, the reader would occasionally see a
# missing or partial INSTALL_TYPE line. With atomic rename(2), the
# reader sees only complete files (old or new).
RACE_DEST="$WORKDIR/race-dest"
mkdir -p "$RACE_DEST"
# Seed with the initial mirror.
mirror_install_conf "$SRC" "$RACE_DEST" >/dev/null 2>&1

# Writer: 100 mirror cycles, alternating between two sources to ensure
# the file's content actually changes (so a stale-read couldn't fake a
# pass).
ALT_SRC="$WORKDIR/alt-src.conf"
cat > "$ALT_SRC" <<EOF
INSTALL_TYPE=client
ENABLE_READONLY=false
EOF

(
    for _ in $(seq 1 100); do
        mirror_install_conf "$SRC" "$RACE_DEST" >/dev/null 2>&1
        mirror_install_conf "$ALT_SRC" "$RACE_DEST" >/dev/null 2>&1
    done
) &
writer_pid=$!

# Reader: also 200 iterations, asserting INSTALL_TYPE always present.
reader_failures=0
for _ in $(seq 1 200); do
    if [[ -f "$RACE_DEST/install.conf" ]]; then
        if ! grep -q '^INSTALL_TYPE=' "$RACE_DEST/install.conf" 2>/dev/null; then
            reader_failures=$((reader_failures + 1))
        fi
    fi
done
wait "$writer_pid" 2>/dev/null || true

assert_eq "$reader_failures" "0" "concurrent reader never saw a partial install.conf (atomic mv proof)"

echo
echo "=== Source guard idempotency ==="
guarded=$(
    set -e
    # shellcheck source=../scripts/common/install-conf-mirror.sh
    source "$MIRROR_SH"
    declare -p _INSTALL_CONF_MIRROR_SH_SOURCED 2>/dev/null \
        | head -1 \
        | grep -oE 'SOURCED="?1"?' \
        | head -1
)
assert_contains "$guarded" "SOURCED" "source guard sentinel set after first source"

# Re-source must not error.
if (
    set -e
    # shellcheck source=../scripts/common/install-conf-mirror.sh
    source "$MIRROR_SH"
    # shellcheck source=../scripts/common/install-conf-mirror.sh
    source "$MIRROR_SH"
) 2>/dev/null; then
    echo "  PASS: re-sourcing install-conf-mirror.sh is idempotent (no error)"
    pass=$((pass + 1))
else
    echo "  FAIL: re-source returned non-zero"
    fail=$((fail + 1))
fi

echo
echo "Results: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
