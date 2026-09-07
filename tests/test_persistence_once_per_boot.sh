#!/usr/bin/env bash
# Synthetic regression coverage for the boot-scoped state restore guard.
# shellcheck disable=SC2016  # assert() evaluates single-quoted conditions.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESTORE="$TEST_DIR/../scripts/common/restore-snapmulti-state.sh"
SBX=$(mktemp -d /tmp/snapmulti-persistence-guard-XXXXXX)
trap 'rm -rf "$SBX"' EXIT

pass=0
fail=0

assert() {
    local condition="$1" description="$2"
    if eval "$condition"; then
        echo "  PASS: $description"
        pass=$((pass + 1))
    else
        echo "  FAIL: $description"
        fail=$((fail + 1))
    fi
}

mkdir -p "$SBX/bin"
cat > "$SBX/bin/mount" <<'EOF'
#!/bin/sh
echo 'overlay on / type overlay (rw)'
EOF
chmod +x "$SBX/bin/mount"

write_valid_server_json() {
    local path="$1" name="$2"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<EOF
{"Config":{"Groups":[{"id":"group-000000000000000000000000000001","name":"$name"}]}}
EOF
}

run_restore() {
    PATH="$SBX/bin:$PATH" \
        BOOT="$SBX/boot" \
        INSTALL_DIR="$SBX/install" \
        RESTORE_GUARD="$SBX/run/restore.complete" \
        bash "$RESTORE"
}

reset_case() {
    rm -rf "${SBX:?}/boot" "$SBX/install" "$SBX/run"
    mkdir -p "$SBX/boot" "$SBX/install" "$SBX/run"
}

echo "=== restore once per boot ==="
reset_case
write_valid_server_json "$SBX/boot/snapmulti-backup/data/server.json" "backup-state"
mkdir -p "$SBX/boot/snapmulti-backup/mympd/workdir/state"
echo "backup-theme" > "$SBX/boot/snapmulti-backup/mympd/workdir/state/theme"
run_restore >/dev/null 2>&1
assert '[[ -f "$SBX/run/restore.complete" ]]' "successful restore creates the boot-scoped guard"
assert 'grep -q backup-state "$SBX/install/data/server.json"' "first start restores snapserver state"
assert 'grep -q backup-theme "$SBX/install/mympd/workdir/state/theme"' "first start restores the complete myMPD seed"

write_valid_server_json "$SBX/install/data/server.json" "new-live-state"
echo "new-live-theme" > "$SBX/install/mympd/workdir/state/theme"
write_valid_server_json "$SBX/boot/snapmulti-backup/data/server.json" "stale-backup"
echo "stale-theme" > "$SBX/boot/snapmulti-backup/mympd/workdir/state/theme"
run_restore >/dev/null 2>&1
assert 'grep -q new-live-state "$SBX/install/data/server.json"' "same-boot restart preserves newer live snapserver state"
assert 'grep -q new-live-theme "$SBX/install/mympd/workdir/state/theme"' "same-boot restart preserves newer live myMPD state"

echo
echo "=== no-backup first start ==="
reset_case
run_restore >/dev/null 2>&1
assert '[[ -f "$SBX/run/restore.complete" ]]' "successful no-backup start still creates the guard"
write_valid_server_json "$SBX/boot/snapmulti-backup/data/server.json" "late-backup"
run_restore >/dev/null 2>&1
assert '[[ ! -e "$SBX/install/data/server.json" ]]' "later same-boot backup does not overwrite a fresh live tree"

echo
echo "=== failed restore retry ==="
reset_case
mkdir -p "$SBX/boot/snapmulti-backup/data"
echo "bad current" > "$SBX/boot/snapmulti-backup/data/server.json"
echo "bad previous" > "$SBX/boot/snapmulti-backup/data/server.json.prev"
if run_restore >/dev/null 2>&1; then
    echo "  FAIL: corrupt restore fails"
    fail=$((fail + 1))
else
    echo "  PASS: corrupt restore fails"
    pass=$((pass + 1))
fi
assert '[[ ! -e "$SBX/run/restore.complete" ]]' "failed restore does not create the guard"

write_valid_server_json "$SBX/boot/snapmulti-backup/data/server.json" "recovered-backup"
run_restore >/dev/null 2>&1
assert '[[ -f "$SBX/run/restore.complete" ]]' "successful retry creates the guard"
assert 'grep -q recovered-backup "$SBX/install/data/server.json"' "successful retry restores corrected backup"

echo
echo "Results: $pass passed, $fail failed"
(( fail == 0 ))
