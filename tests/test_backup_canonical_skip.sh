#!/usr/bin/env bash
# Test backup-snapmulti-state.sh canonical-equal short-circuit:
# When the only diff between source and existing backup is the
# snapserver `lastSeen` field (heartbeat updates every ~3 s), the
# backup script must NOT republish the file. This kills the loop on
# FAT32 boot partitions where unconditional rewrites would burn flash.
#
# Regression target: pre-v0.7.9.1 .path unit watched server.json and
# fired backup-snapmulti-state.service on every lastSeen tick — ~98
# invocations / 5 min on a live system.
set -euo pipefail

: "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/common/backup-snapmulti-state.sh"

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

# Replicate the canonical-equal short-circuit logic in isolation
# (the full script needs mount + INSTALL_DIR + BACKUP_DIR + sudo).
canonical_equal() {
    local a="$1" b="$2"
    command -v jq >/dev/null 2>&1 || return 2
    command -v sha256sum >/dev/null 2>&1 || return 2
    local _a _b
    _a=$(jq -S 'walk(if type == "object" then del(.lastSeen) else . end)' "$a" 2>/dev/null | sha256sum | cut -d' ' -f1)
    _b=$(jq -S 'walk(if type == "object" then del(.lastSeen) else . end)' "$b" 2>/dev/null | sha256sum | cut -d' ' -f1)
    [[ -n "$_a" && "$_a" == "$_b" ]]
}

if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq not installed (required for canonical short-circuit)"
    exit 0
fi

echo "## Canonical-equal short-circuit"

SBX="$(mktemp -d)"
trap 'rm -rf "$SBX"' EXIT

# --- Case 1: identical files → canonical-equal ---
cat > "$SBX/a.json" <<'EOF'
{"Server":{"Groups":[{"name":"G1","clients":[{"id":"c1","lastSeen":{"sec":111,"usec":0}}]}],"streams":[]}}
EOF
cp "$SBX/a.json" "$SBX/b.json"
if canonical_equal "$SBX/a.json" "$SBX/b.json"; then
    assert "true" "byte-identical files are canonical-equal"
else
    assert "false" "byte-identical files are canonical-equal"
fi

# --- Case 2: only lastSeen differs → canonical-equal (the loop trigger) ---
cat > "$SBX/a.json" <<'EOF'
{"Server":{"Groups":[{"name":"G1","clients":[{"id":"c1","lastSeen":{"sec":111,"usec":0}}]}],"streams":[]}}
EOF
cat > "$SBX/b.json" <<'EOF'
{"Server":{"Groups":[{"name":"G1","clients":[{"id":"c1","lastSeen":{"sec":222,"usec":500}}]}],"streams":[]}}
EOF
if canonical_equal "$SBX/a.json" "$SBX/b.json"; then
    assert "true" "lastSeen-only diff is canonical-equal (heartbeat must NOT trigger backup)"
else
    assert "false" "lastSeen-only diff is canonical-equal (heartbeat must NOT trigger backup)"
fi

# --- Case 3: group rename → NOT canonical-equal (user change must back up) ---
cat > "$SBX/a.json" <<'EOF'
{"Server":{"Groups":[{"name":"Kitchen","clients":[{"id":"c1","lastSeen":{"sec":111,"usec":0}}]}],"streams":[]}}
EOF
cat > "$SBX/b.json" <<'EOF'
{"Server":{"Groups":[{"name":"Living Room","clients":[{"id":"c1","lastSeen":{"sec":222,"usec":0}}]}],"streams":[]}}
EOF
if canonical_equal "$SBX/a.json" "$SBX/b.json"; then
    assert "false" "group rename + lastSeen diff is NOT canonical-equal (user change must back up)"
else
    assert "true" "group rename + lastSeen diff is NOT canonical-equal (user change must back up)"
fi

# --- Case 4: new client added → NOT canonical-equal ---
cat > "$SBX/a.json" <<'EOF'
{"Server":{"Groups":[{"name":"G1","clients":[{"id":"c1","lastSeen":{"sec":111,"usec":0}}]}],"streams":[]}}
EOF
cat > "$SBX/b.json" <<'EOF'
{"Server":{"Groups":[{"name":"G1","clients":[{"id":"c1","lastSeen":{"sec":111,"usec":0}},{"id":"c2","lastSeen":{"sec":111,"usec":0}}]}],"streams":[]}}
EOF
if canonical_equal "$SBX/a.json" "$SBX/b.json"; then
    assert "false" "client added is NOT canonical-equal"
else
    assert "true" "client added is NOT canonical-equal"
fi

# --- Case 5: stream config change → NOT canonical-equal ---
cat > "$SBX/a.json" <<'EOF'
{"Server":{"Groups":[],"streams":[{"id":"s1","uri":"pipe:///x"}]}}
EOF
cat > "$SBX/b.json" <<'EOF'
{"Server":{"Groups":[],"streams":[{"id":"s1","uri":"pipe:///y"}]}}
EOF
if canonical_equal "$SBX/a.json" "$SBX/b.json"; then
    assert "false" "stream URI change is NOT canonical-equal"
else
    assert "true" "stream URI change is NOT canonical-equal"
fi

# --- Case 6: key ordering must not matter (jq -S sorts) ---
cat > "$SBX/a.json" <<'EOF'
{"Server":{"Groups":[{"name":"G1","clients":[{"id":"c1","lastSeen":{"sec":1,"usec":0}}]}],"streams":[]}}
EOF
cat > "$SBX/b.json" <<'EOF'
{"Server":{"streams":[],"Groups":[{"clients":[{"lastSeen":{"sec":1,"usec":0},"id":"c1"}],"name":"G1"}]}}
EOF
if canonical_equal "$SBX/a.json" "$SBX/b.json"; then
    assert "true" "reordered keys are canonical-equal (jq -S normalises)"
else
    assert "false" "reordered keys are canonical-equal (jq -S normalises)"
fi

echo
echo "## Path-unit no longer watches server.json"
PATH_UNIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/common/snapmulti-state-backup.path"
assert "! grep -q 'PathChanged=/opt/snapmulti/data/server.json' '$PATH_UNIT'" \
       'snapmulti-state-backup.path no longer fires on server.json (heartbeat loop killed)'
assert "grep -q 'PathChanged=/opt/snapmulti/mympd/workdir/state' '$PATH_UNIT'" \
       'snapmulti-state-backup.path still fires on myMPD workdir state'

echo
echo "## Timer cadence aligned with server.json being primary"
TIMER_UNIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/common/snapmulti-state-backup.timer"
assert "grep -q 'OnUnitActiveSec=5min' '$TIMER_UNIT'" \
       'timer fires every 5 min (was 10 min — tighter cadence now timer is primary for server.json)'

echo
echo "## Summary"
echo "  Passed: $pass"
echo "  Failed: $fail"
[[ $fail -eq 0 ]]
