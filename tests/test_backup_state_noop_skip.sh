#!/usr/bin/env bash
# Behavioural test for scripts/common/backup-snapmulti-state.sh, run end
# to end against a sandbox install dir + boot partition (mount / findmnt /
# flock / logger are PATH stubs).
#
# Regressions covered:
#   - every 5-min timer tick / .path event did a full myMPD workdir cp -R
#     + 2 mv + remount rw/ro of the FAT boot partition even when nothing
#     changed (the timer unit claimed no-op ticks cost zero FAT writes)
#   - a failed cp left workdir.tmp.<pid> behind on every attempt (only the
#     current PID was ever removed) until the boot partition filled up
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SH="$SCRIPT_DIR/../scripts/common/backup-snapmulti-state.sh"
TIMER="$SCRIPT_DIR/../scripts/common/snapmulti-state-backup.timer"

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

SBX="$(mktemp -d)"
trap 'rm -rf "$SBX"' EXIT
mkdir -p "$SBX/bin" "$SBX/install/data" "$SBX/install/mympd/workdir/state" "$SBX/boot"
echo ro > "$SBX/mountstate"

# mount -o remount,{rw,ro} <dir>: record the call, flip the state findmnt reports.
cat > "$SBX/bin/mount" <<'EOF'
#!/usr/bin/env bash
echo "mount $*" >> "$STUB/calls"
case "$*" in *remount,rw*) echo rw > "$STUB/mountstate" ;; *remount,ro*) echo ro > "$STUB/mountstate" ;; esac
EOF
cat > "$SBX/bin/findmnt" <<'EOF'
#!/usr/bin/env bash
echo "$(cat "$STUB/mountstate"),relatime"
EOF
cat > "$SBX/bin/logger" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$STUB/log"
EOF
printf '#!/bin/sh\nexit 0\n' > "$SBX/bin/flock"
chmod +x "$SBX/bin/"*

run_backup() {
    : > "$SBX/calls"
    : > "$SBX/log"
    STUB="$SBX" PATH="${EXTRA_PATH:+$EXTRA_PATH:}$SBX/bin:$PATH" \
        INSTALL_DIR="$SBX/install" BOOT="$SBX/boot" SNAPMULTI_BOOT_LOCK="$SBX/lock" \
        bash "$BACKUP_SH"
}
remounts() { local c; c=$(grep -c 'remount,rw' "$SBX/calls" 2>/dev/null) || true; echo "${c:-0}"; }

WD="$SBX/install/mympd/workdir"
BK="$SBX/boot/snapmulti-backup/mympd"
echo '{"theme":"dark"}' > "$WD/state/webui_settings"
echo 'smart' > "$WD/smartpls.txt"

echo "## First run publishes the workdir"
run_backup
assert "[[ -f '$BK/workdir/state/webui_settings' ]]" "workdir copied to the boot partition"
assert "[[ -s '$BK/workdir.sha256' ]]" "content hash stored next to the backup"
assert "[[ \"\$(remounts)\" == 1 ]]" "boot partition remounted rw once"
assert "[[ \"\$(cat '$SBX/mountstate')\" == ro ]]" "boot partition back to ro afterwards"

echo
echo "## Unchanged workdir: no remount, no FAT write"
before=$(find "$SBX/boot" -printf '%p %T@\n' | sort)
touch "$WD/state/webui_settings"   # mtime-only rewrite by myMPD
run_backup
after=$(find "$SBX/boot" -printf '%p %T@\n' | sort)
assert "[[ \"\$(remounts)\" == 0 ]]" "no remount on a no-op tick"
assert "[[ ! -s '$SBX/calls' ]]" "no mount call at all"
assert "[[ \"\$before\" == \"\$after\" ]]" "boot partition untouched (mtime-only change ignored)"

echo
echo "## Changed workdir is published again"
echo '{"theme":"light"}' > "$WD/state/webui_settings"
run_backup
assert "grep -q light '$BK/workdir/state/webui_settings'" "new content published"
assert "[[ \"\$(remounts)\" == 1 ]]" "remounted for the real change"
echo 'new' > "$WD/state/added"
run_backup
assert "[[ -f '$BK/workdir/state/added' ]]" "added file published"

echo
echo "## Stale staging dirs from earlier runs are cleaned"
mkdir -p "$BK/workdir.tmp.111/x" "$BK/workdir.tmp.222" "$BK/workdir.old.333"
echo 'change' > "$WD/state/added"
run_backup
assert "! compgen -G '$BK/workdir.tmp.*' >/dev/null && ! compgen -G '$BK/workdir.old.*' >/dev/null" \
    "workdir.tmp.* / workdir.old.* of other PIDs removed"

echo
echo "## Failed copy keeps the prior backup and leaves no staging dir"
mkdir -p "$SBX/failbin"
cat > "$SBX/failbin/cp" <<'EOF'
#!/usr/bin/env bash
# Fail the workdir copy after creating a partial staging dir.
if [[ "${*: -1}" == *workdir.tmp.* ]]; then mkdir -p "${*: -1}/partial"; exit 1; fi
exec /bin/cp "$@"
EOF
chmod +x "$SBX/failbin/cp"
echo 'lost' > "$WD/state/added"
rc=0
EXTRA_PATH="$SBX/failbin" run_backup || rc=$?
assert "[[ '$rc' == 0 ]]" "script exits 0 when cp fails (no set -e abort)"
assert "grep -q change '$BK/workdir/state/added'" "prior backup preserved"
assert "! compgen -G '$BK/workdir.tmp.*' >/dev/null" "partial staging dir removed"
assert "grep -q 'cp to temp failed' '$SBX/log'" "failure logged"
run_backup
assert "grep -q lost '$BK/workdir/state/added'" "next run retries and publishes (hash was not updated on failure)"

if command -v jq >/dev/null 2>&1; then
    echo
    echo "## server.json: heartbeat-only change skips, real change publishes"
    cat > "$SBX/install/data/server.json" <<'EOF'
{"Server":{"Groups":[{"name":"Kitchen","clients":[{"id":"c1","lastSeen":{"sec":1,"usec":0}}]}],"streams":[]}}
EOF
    run_backup
    assert "grep -q Kitchen '$SBX/boot/snapmulti-backup/data/server.json'" "server.json published"
    sed -i 's/"sec":1/"sec":99/' "$SBX/install/data/server.json"
    run_backup
    assert "[[ \"\$(remounts)\" == 0 ]]" "lastSeen-only change: no remount"
    sed -i 's/Kitchen/Living/' "$SBX/install/data/server.json"
    run_backup
    assert "grep -q Living '$SBX/boot/snapmulti-backup/data/server.json'" "group rename published"
    assert "[[ \"\$(remounts)\" == 1 ]]" "remounted once for the server.json change only"
fi

echo
echo "## Timer unit comment matches the behaviour"
assert "grep -q 'content hash' '$TIMER'" "timer comment mentions the workdir content hash"

echo
echo "## Summary"
echo "  Passed: $pass"
echo "  Failed: $fail"
[[ $fail -eq 0 ]]
