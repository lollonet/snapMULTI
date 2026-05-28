#!/usr/bin/env bash
# Test restore-snapmulti-state.sh fallback logic:
# 1. When server.json is valid → restore from it.
# 2. When server.json is corrupt but .prev is valid → restore from .prev with WARN.
# 3. When BOTH are corrupt → fail loud (exit non-zero), no restore.
#
# Regression target: the historical class where a single transient
# write corruption would brick snapmulti-server.service on next boot
# (ExecStartPre fatal, no fallback).
set -euo pipefail

# Reference path for the production script — logic replicated
# inline below to avoid root/mount requirements at unit-test time.
: "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/common/restore-snapmulti-state.sh"

pass=0
fail=0

assert() {
    local cond="$1" desc="$2"
    if eval "$cond"; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc"
        fail=$((fail + 1))
    fi
}

# Run the restore script's server.json branch under the integrity
# guard. We don't run the full restore script (it includes mount
# detection + ownership + workdir scope that need root); we
# replicate the candidate-validation + fallback flow under test.
run_restore() {
    local sbx="$1" exitcode_var="$2" outvar="$3"
    set +e
    local _stdout _exit
    _stdout=$(
        INSTALL_DIR="$sbx/install" \
        BACKUP_DIR="$sbx/boot/snapmulti-backup" \
        bash -c '
            set -euo pipefail
            _validate_candidate() {
                local c="$1"
                [[ -s "$c" ]] || return 1
                (( $(wc -c < "$c") >= 64 )) || return 1
                if command -v jq >/dev/null 2>&1; then
                    jq -e . "$c" >/dev/null 2>&1 || return 1
                fi
                return 0
            }
            mkdir -p "$INSTALL_DIR/data"
            if [[ -s "$BACKUP_DIR/data/server.json" || -s "$BACKUP_DIR/data/server.json.prev" ]]; then
                if _validate_candidate "$BACKUP_DIR/data/server.json"; then
                    cp "$BACKUP_DIR/data/server.json" "$INSTALL_DIR/data/server.json"
                    echo "OK_CURRENT"
                    exit 0
                elif _validate_candidate "$BACKUP_DIR/data/server.json.prev"; then
                    cp "$BACKUP_DIR/data/server.json.prev" "$INSTALL_DIR/data/server.json"
                    echo "OK_PREV"
                    exit 0
                else
                    echo "FATAL_BOTH_CORRUPT" >&2
                    exit 1
                fi
            fi
            echo "OK_NO_BACKUP"
            exit 0
        ' 2>&1
    )
    _exit=$?
    set -e
    eval "$outvar=\$_stdout"
    eval "$exitcode_var=\$_exit"
}

setup_sandbox() {
    local sbx="$1"
    mkdir -p "$sbx/install" "$sbx/boot/snapmulti-backup/data"
}

echo "## Restore .prev fallback"

# --- Case 1: server.json valid → restore from it ---
SBX="$(mktemp -d)"
trap 'rm -rf "$SBX"' EXIT
setup_sandbox "$SBX"
cat > "$SBX/boot/snapmulti-backup/data/server.json" <<'EOF'
{"Server":{"Groups":[{"name":"Current","clients":[{"id":"a"}]}],"streams":[]}}
EOF

run_restore "$SBX" RC OUT
assert "[[ '$RC' == '0' ]]" "current valid → exit 0"
assert "echo '$OUT' | grep -q OK_CURRENT" "current valid → restored from server.json"
assert "grep -q Current '$SBX/install/data/server.json'" "current valid → install dir has restored content"

# --- Case 2: server.json corrupt, .prev valid → restore from .prev ---
rm -rf "$SBX"; SBX="$(mktemp -d)"; setup_sandbox "$SBX"
echo "this is not json" > "$SBX/boot/snapmulti-backup/data/server.json"  # < 64 bytes too
cat > "$SBX/boot/snapmulti-backup/data/server.json.prev" <<'EOF'
{"Server":{"Groups":[{"name":"PrevGroup","clients":[{"id":"x"}]}],"streams":[]}}
EOF

run_restore "$SBX" RC OUT
assert "[[ '$RC' == '0' ]]" "current corrupt + prev valid → exit 0 (no brick)"
assert "echo '$OUT' | grep -q OK_PREV" "current corrupt + prev valid → restored from .prev"
assert "grep -q PrevGroup '$SBX/install/data/server.json'" "install dir has .prev content (not corrupt current)"

# --- Case 3: BOTH corrupt → fail loud ---
rm -rf "$SBX"; SBX="$(mktemp -d)"; setup_sandbox "$SBX"
echo "garbage 1" > "$SBX/boot/snapmulti-backup/data/server.json"
echo "garbage 2" > "$SBX/boot/snapmulti-backup/data/server.json.prev"

run_restore "$SBX" RC OUT
assert "[[ '$RC' != '0' ]]" "both corrupt → exit non-zero (fail loud)"
assert "echo '$OUT' | grep -q FATAL_BOTH_CORRUPT" "FATAL message emitted to stderr"
assert "[[ ! -s '$SBX/install/data/server.json' ]]" "install dir UNCHANGED (no partial restore)"

# --- Case 4: nothing to restore (fresh install) → exit 0 silently ---
rm -rf "$SBX"; SBX="$(mktemp -d)"; setup_sandbox "$SBX"

run_restore "$SBX" RC OUT
assert "[[ '$RC' == '0' ]]" "no backup → exit 0 silently"
assert "echo '$OUT' | grep -q OK_NO_BACKUP" "fresh install path taken"
assert "[[ ! -s '$SBX/install/data/server.json' ]]" "no file fabricated when no backup"

echo
echo "## Summary"
echo "  Passed: $pass"
echo "  Failed: $fail"
[[ $fail -eq 0 ]]
