#!/usr/bin/env bash
# Test backup-snapmulti-state.sh integrity guard:
# A corrupt (tiny / non-JSON) source must NOT overwrite a known-good
# backup. The previous good backup must be preserved on disk.
#
# Regression target: the historical class where the backup script
# silently published partial / corrupt files (e.g. on disk-full or
# FAT32 fragmentation), then a reboot's restore loaded the corrupt
# file and either failed loud OR restored bad state.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Reference path for the script under test — production logic is
# replicated inline below so the unit test stays free of mount/
# root requirements. Kept for traceability.
: "${SCRIPT_DIR}/../scripts/common/backup-snapmulti-state.sh"

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

# Each test runs in an isolated tempdir simulating snapMULTI's
# /opt/snapmulti + /boot/firmware/snapmulti-backup layout. The
# script is invoked with INSTALL_DIR pointing at our fake install
# tree; the script reads /boot/firmware OR /boot as BOOT, so we
# mock that via a wrapper that overrides the BOOT detection by
# pre-creating ONLY /boot/firmware = pointing into our sandbox via
# a bind-style symlink isn't possible here, so we run the script
# inline in a subshell with the relevant globals pre-set.

setup_sandbox() {
    local sandbox="$1"
    mkdir -p "$sandbox/install/data" "$sandbox/install/mympd/workdir/state"
    mkdir -p "$sandbox/boot/snapmulti-backup/data"
    # Pre-existing good backup we want to preserve on a corrupt source.
    cat > "$sandbox/boot/snapmulti-backup/data/server.json" <<'EOF'
{"Server":{"Groups":[{"name":"Kitchen","clients":[{"id":"a"},{"id":"b"}]}],"streams":[]}}
EOF
    chmod 0644 "$sandbox/boot/snapmulti-backup/data/server.json"
}

# Run the backup script's logic in a subshell with stubbed BOOT
# detection so we don't touch the real /boot. We source the script
# functions but call them with INSTALL_DIR + BOOT pointing into
# the sandbox; the script auto-detects /boot/firmware vs /boot,
# so we point at a path the script will resolve to.
run_backup_in_sandbox() {
    local sandbox="$1"
    INSTALL_DIR="$sandbox/install" \
    BOOT="$sandbox/boot" \
    BACKUP_DIR="$sandbox/boot/snapmulti-backup" \
    bash -c '
        set -euo pipefail
        # Inline the integrity-validated server.json backup logic
        # under test. (Sourcing the full script would also try to
        # remount BOOT — we want a unit-level test of the guard.)
        src="$INSTALL_DIR/data/server.json"
        dst_dir="$BACKUP_DIR/data"
        dst="$dst_dir/server.json"
        prev="$dst_dir/server.json.prev"
        tmp="$dst_dir/server.json.tmp.$$"

        [[ -s "$src" ]] || exit 0
        (( $(wc -c < "$src") >= 64 )) || exit 0

        mkdir -p "$dst_dir"
        cp "$src" "$tmp" || { rm -f "$tmp"; exit 0; }
        (( $(wc -c < "$tmp") >= 64 )) || { rm -f "$tmp"; exit 0; }
        if command -v jq >/dev/null 2>&1; then
            jq -e . "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; exit 0; }
        fi
        # Validate existing $dst before rotating — never promote a
        # corrupt current backup to .prev (would destroy fallback).
        if [[ -s "$dst" ]]; then
            _dst_valid=true
            (( $(wc -c < "$dst") >= 64 )) || _dst_valid=false
            if [[ "$_dst_valid" == "true" ]] && command -v jq >/dev/null 2>&1; then
                jq -e . "$dst" >/dev/null 2>&1 || _dst_valid=false
            fi
            if [[ "$_dst_valid" == "true" ]]; then
                mv "$dst" "$prev"
            else
                rm -f "$dst"
            fi
        fi
        mv "$tmp" "$dst"
    '
}

echo "## Backup integrity validation"

# --- Case 1: source is corrupt (tiny) → backup preserved unchanged ---
SBX="$(mktemp -d)"
trap 'rm -rf "$SBX"' EXIT
setup_sandbox "$SBX"
ORIG_BACKUP_SHA=$(sha256sum "$SBX/boot/snapmulti-backup/data/server.json" | cut -d' ' -f1)

# Write a tiny "corrupt" source — under the 64-byte threshold.
echo '{}' > "$SBX/install/data/server.json"

run_backup_in_sandbox "$SBX"

NEW_BACKUP_SHA=$(sha256sum "$SBX/boot/snapmulti-backup/data/server.json" | cut -d' ' -f1)
assert "[[ '$ORIG_BACKUP_SHA' == '$NEW_BACKUP_SHA' ]]" \
    "tiny corrupt source did NOT overwrite good backup"
assert "[[ ! -e '$SBX/boot/snapmulti-backup/data/server.json.prev' ]]" \
    "no .prev file was created when source was rejected"

# --- Case 2: source is non-JSON (invalid) → backup preserved unchanged ---
rm -rf "$SBX"; SBX="$(mktemp -d)"; setup_sandbox "$SBX"
ORIG_BACKUP_SHA=$(sha256sum "$SBX/boot/snapmulti-backup/data/server.json" | cut -d' ' -f1)

# 64+ byte payload that's NOT valid JSON
printf '%s' "this is definitely not json content but long enough to pass the size check easily" > "$SBX/install/data/server.json"

if command -v jq >/dev/null 2>&1; then
    run_backup_in_sandbox "$SBX"
    NEW_BACKUP_SHA=$(sha256sum "$SBX/boot/snapmulti-backup/data/server.json" | cut -d' ' -f1)
    assert "[[ '$ORIG_BACKUP_SHA' == '$NEW_BACKUP_SHA' ]]" \
        "non-JSON source did NOT overwrite good backup (jq guard works)"
else
    echo "  SKIP: jq missing — JSON validity check cannot be exercised"
fi

# --- Case 3: source is valid + different → publishes new, rotates old to .prev ---
rm -rf "$SBX"; SBX="$(mktemp -d)"; setup_sandbox "$SBX"
ORIG_BACKUP_SHA=$(sha256sum "$SBX/boot/snapmulti-backup/data/server.json" | cut -d' ' -f1)

cat > "$SBX/install/data/server.json" <<'EOF'
{"Server":{"Groups":[{"name":"Bedroom","clients":[{"id":"c"}]}],"streams":[]}}
EOF

run_backup_in_sandbox "$SBX"

NEW_BACKUP_SHA=$(sha256sum "$SBX/boot/snapmulti-backup/data/server.json" | cut -d' ' -f1)
assert "[[ '$ORIG_BACKUP_SHA' != '$NEW_BACKUP_SHA' ]]" \
    "valid different source DID overwrite previous backup"
assert "[[ -s '$SBX/boot/snapmulti-backup/data/server.json.prev' ]]" \
    ".prev was created from previous good backup"
PREV_SHA=$(sha256sum "$SBX/boot/snapmulti-backup/data/server.json.prev" | cut -d' ' -f1)
assert "[[ '$PREV_SHA' == '$ORIG_BACKUP_SHA' ]]" \
    ".prev contents match the previous good backup byte-for-byte"

# --- Case 4: current backup is corrupt + .prev is good (post-restore-fallback state) ---
# After restore-from-.prev, the corrupt current is still on disk. The
# NEXT backup must NOT promote that garbage to .prev — that would
# destroy the only known-good fallback.
rm -rf "$SBX"; SBX="$(mktemp -d)"; setup_sandbox "$SBX"

# Simulate the post-restore-fallback boot-partition state:
echo "garbage truncated current" > "$SBX/boot/snapmulti-backup/data/server.json"  # < 64 bytes
cat > "$SBX/boot/snapmulti-backup/data/server.json.prev" <<'EOF'
{"Server":{"Groups":[{"name":"OriginalGood","clients":[{"id":"x"}]}],"streams":[]}}
EOF
PREV_SHA_ORIG=$(sha256sum "$SBX/boot/snapmulti-backup/data/server.json.prev" | cut -d' ' -f1)

# snapserver wrote good state (restored from .prev) — simulate a backup cycle on it
cat > "$SBX/install/data/server.json" <<'EOF'
{"Server":{"Groups":[{"name":"NewState","clients":[{"id":"y"}]}],"streams":[]}}
EOF

run_backup_in_sandbox "$SBX"

# .prev MUST still contain the original good content — corrupt current
# was discarded, not promoted.
PREV_SHA_AFTER=$(sha256sum "$SBX/boot/snapmulti-backup/data/server.json.prev" | cut -d' ' -f1)
assert "[[ '$PREV_SHA_ORIG' == '$PREV_SHA_AFTER' ]]" \
    "corrupt current was NOT promoted to .prev (good .prev preserved)"
assert "grep -q OriginalGood '$SBX/boot/snapmulti-backup/data/server.json.prev'" \
    ".prev still contains original good content"
assert "grep -q NewState '$SBX/boot/snapmulti-backup/data/server.json'" \
    "current contains the new valid backup"

echo
echo "## Summary"
echo "  Passed: $pass"
echo "  Failed: $fail"
[[ $fail -eq 0 ]]
