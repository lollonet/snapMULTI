#!/usr/bin/env bash
# Static invariants for the nightly MPD-NFS rescan trigger.
#
# Why pin these statically:
# - inotify-vs-NFS is a kernel limitation; if the script ever drops the
#   `mpc update` call or the NFS detection, the symptom is invisible
#   (DB silently misses new tracks on the NAS for days). Better to
#   catch in CI than discover after a release.
# - The path-arg variant of `mpc update <dir>` is brittle: spaces in
#   path components get truncated by URI parsing. The fleet hit this
#   live (snapvideo 2026-05-30 "Sonic Youth/2002-06_Murray Street").
#   Pin the no-arg invocation so a future "optimization" doesn't
#   reintroduce the bug.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../scripts/common/mpd-nfs-update.sh"
SERVICE="$SCRIPT_DIR/../scripts/common/snapmulti-mpd-update.service"
TIMER="$SCRIPT_DIR/../scripts/common/snapmulti-mpd-update.timer"
FIRSTBOOT="$SCRIPT_DIR/../scripts/firstboot.sh"

pass=0
fail=0

check() {
    local desc="$1" condition="$2"
    if eval "$condition" >/dev/null 2>&1; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc"
        fail=$((fail + 1))
    fi
}

echo "== mpd-nfs-update.sh =="
check "script exists" "[[ -f '$SCRIPT' ]]"
check "script is executable bit ready (mode 755 after install)" "head -1 '$SCRIPT' | grep -q '^#!/usr/bin/env bash'"
check "set -euo pipefail" "grep -q '^set -euo pipefail' '$SCRIPT'"
check "reads MUSIC_PATH from .env" "grep -q 'MUSIC_PATH=' '$SCRIPT'"
check "detects fstype via df -T" "grep -qE 'df -T.*MUSIC|df -T.*music_path' '$SCRIPT'"
check "matches NFS family (nfs|nfs4)" "grep -qE 'nfs[|)]' '$SCRIPT'"
check "matches SMB family (cifs|smb|smbfs)" "grep -qE 'cifs[|]' '$SCRIPT'"
check "exits early on local fs (case fallthrough logs and exits 0)" "grep -A 4 '\\*)' '$SCRIPT' | grep -q 'exit 0'"
check "verifies mpd container state via docker inspect" "grep -q 'docker inspect.*mpd' '$SCRIPT'"
check "uses plain 'docker exec mpd mpc update' (no path arg)" "grep -qE '^[[:space:]]*[^#]*docker exec mpd mpc update[[:space:]]*>' '$SCRIPT'"
check "polls updating_db field for completion" "grep -q 'updating_db' '$SCRIPT'"
check "30-min deadline cap" "grep -qE 'deadline.*1800|1800.*deadline' '$SCRIPT'"
check "uses logger for journal trace" "grep -q 'logger -t snapmulti-mpd-update' '$SCRIPT'"
# CRLF check uses inline assertion rather than `check` helper — matching the
# literal 5-char sequence `$'\r'` via eval would require painful nested escapes.
if grep -qE "tr -d \\\$'\\\\r'" "$SCRIPT"; then
    echo "  PASS: strips CRLF from .env MUSIC_PATH (Windows-edit safety)"
    pass=$((pass + 1))
else
    echo "  FAIL: strips CRLF from .env MUSIC_PATH (Windows-edit safety)"
    fail=$((fail + 1))
fi
check "empty fstype is guarded BEFORE the case (NFS-down does not mislog 'local fs')" "awk '/fstype=\\\$\\(df -T/{found=1} found && /\\[\\[ -z \"\\\$fstype\" \\]\\]/{ok=1; exit} found && /^case/{exit} END{exit !ok}' '$SCRIPT'"
check "initial sleep before poll loop (avoids premature 'finished' on tiny scans)" "awk '/mpc update >/{seen_update=1} seen_update && /^sleep / && !/sleep 10/{ok=1; exit} seen_update && /^while/{exit} END{exit !ok}' '$SCRIPT'"
check "poll loop separates docker-exec exit code from grep result" "grep -qE 'if ! mpc_out=\\\$\\(docker exec mpd mpc status' '$SCRIPT'"

echo
echo "== snapmulti-mpd-update.service =="
check "service file exists" "[[ -f '$SERVICE' ]]"
check "Type=oneshot" "grep -q '^Type=oneshot' '$SERVICE'"
check "After=docker.service" "grep -q 'After=.*docker.service' '$SERVICE'"
check "After=snapmulti-server.service" "grep -q 'After=.*snapmulti-server.service' '$SERVICE'"
check "TimeoutStartSec covers 30-min poll + margin" "grep -qE 'TimeoutStartSec=(2[0-9]{3}|[3-9][0-9]{3})' '$SERVICE'"
check "ExecStart points to /usr/local/bin/mpd-nfs-update" "grep -q 'ExecStart=/usr/local/bin/mpd-nfs-update' '$SERVICE'"

echo
echo "== snapmulti-mpd-update.timer =="
check "timer file exists" "[[ -f '$TIMER' ]]"
check "OnCalendar fires daily at 03:00" "grep -q 'OnCalendar=\\*-\\*-\\* 03:00:00' '$TIMER'"
check "Persistent=true (survives missed runs)" "grep -q 'Persistent=true' '$TIMER'"
check "WantedBy=timers.target" "grep -q 'WantedBy=timers.target' '$TIMER'"

echo
echo "== firstboot.sh integration =="
check "firstboot installs the script as /usr/local/bin/mpd-nfs-update" "grep -qE 'install -m 755.*MPD_UPDATE_SCRIPT.*/usr/local/bin/mpd-nfs-update' '$FIRSTBOOT'"
check "firstboot installs the service file" "grep -q 'snapmulti-mpd-update.service.*etc/systemd/system' '$FIRSTBOOT'"
check "firstboot installs the timer file" "grep -q 'snapmulti-mpd-update.timer.*etc/systemd/system' '$FIRSTBOOT'"
check "firstboot enables the timer (not the service)" "grep -q 'systemctl enable snapmulti-mpd-update.timer' '$FIRSTBOOT'"
check "install block is server-only / both-only (gated on INSTALL_TYPE)" "awk '/MPD nightly NFS-rescan|MPD_UPDATE_SCRIPT/{found=1} found && /INSTALL_TYPE.*server/{ok=1} END{exit !ok}' '$FIRSTBOOT' || grep -B 30 'MPD_UPDATE_SCRIPT=' '$FIRSTBOOT' | grep -q 'INSTALL_TYPE.*server.*both'"

echo
echo "Results: $pass passed, $fail failed"
exit $fail
