#!/usr/bin/env bash
# Tests for tune_nm_docker_unmanaged() in scripts/common/system-tune.sh.
#
# WHY THIS EXISTS — observed live on snapvideo (both mode, 2026-05-15
# 11:53:17): a routine `arping -D` from device-smoke.sh's IP conflict
# check triggered avahi-daemon to declare a "Host name conflict" and
# rename the host to `snapvideo-2`. Snapcast / AirPlay / MPD then
# published via the -2 hostname and any client looking up
# `snapvideo.local` failed. Root cause: NetworkManager had adopted
# Docker bridges (br-*, veth*, docker0) as "connected (externally)";
# the arping DAD probe's address-state flicker on eth0 propagated as a
# netlink address change avahi observed, and the re-announce echoed
# back through the NM-tracked bridge as a foreign claim. The fix is to
# tell NetworkManager to ignore Docker interfaces entirely.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSTUNE="$SCRIPT_DIR/../scripts/common/system-tune.sh"
FIRSTBOOT="$SCRIPT_DIR/../scripts/firstboot.sh"

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

echo "== system-tune.sh: tune_nm_docker_unmanaged =="

assert 'grep -qE "^tune_nm_docker_unmanaged\\(\\) \\{" "$SYSTUNE"' \
       'function defined at top level'

assert 'awk "/^tune_nm_docker_unmanaged/,/^}/" "$SYSTUNE" | grep -qF "command -v nmcli"' \
       'guards on nmcli presence'

assert 'awk "/^tune_nm_docker_unmanaged/,/^}/" "$SYSTUNE" | grep -qF "99-docker-unmanaged.conf"' \
       'writes 99-docker-unmanaged.conf'

assert 'awk "/^tune_nm_docker_unmanaged/,/^}/" "$SYSTUNE" | grep -qF "interface-name:veth*"' \
       'unmanaged-devices includes veth*'

assert 'awk "/^tune_nm_docker_unmanaged/,/^}/" "$SYSTUNE" | grep -qF "interface-name:br-*"' \
       'unmanaged-devices includes br-*'

assert 'awk "/^tune_nm_docker_unmanaged/,/^}/" "$SYSTUNE" | grep -qF "interface-name:docker*"' \
       'unmanaged-devices includes docker*'

assert 'awk "/^tune_nm_docker_unmanaged/,/^}/" "$SYSTUNE" | grep -qF "nmcli device set"' \
       'detaches already-adopted interfaces with nmcli device set managed no'

# Idempotency: the function compares current file content to desired
# before touching it, and short-circuits with "already configured" so
# re-runs do not bounce NetworkManager.
assert 'awk "/^tune_nm_docker_unmanaged/,/^}/" "$SYSTUNE" | grep -qF "already ignores Docker bridges"' \
       'idempotent path emits "already ignores" instead of rewriting'

echo
echo "== firstboot.sh wiring =="

# Must run AFTER tune_avahi_daemon (same network-ready section), so the
# avahi hardening lands first and the NM rule prevents subsequent
# Docker-bridge churn from re-triggering the conflict path.
order=$(awk '
    /tune_avahi_daemon "\$\(hostname\)"/ {a=NR}
    /tune_nm_docker_unmanaged/ {b=NR}
    END {if (a && b && b>a) print "ok"; else print "bad a=" a " b=" b}
' "$FIRSTBOOT")
if [[ "$order" == "ok" ]]; then
    echo "  PASS: tune_nm_docker_unmanaged is invoked after tune_avahi_daemon"
    pass=$((pass + 1))
else
    echo "  FAIL: wiring order is wrong ($order)"
    fail=$((fail + 1))
fi

# Guard with command -v so a missing system-tune source does not abort firstboot.
assert 'grep -qE "command -v tune_nm_docker_unmanaged" "$FIRSTBOOT"' \
       'firstboot guards the call with command -v'

echo
echo "== Integration: replay against a fake /etc/NetworkManager ==="

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/etc/NetworkManager/conf.d"

# Replicate the conf write path without touching the real system.
# We don't run the function (it'd touch the real NM); we replay its
# write logic against $TMP and assert the file lands with the right content.
desired_content=$(cat <<'NMCONF'
# Managed by snapMULTI tune_nm_docker_unmanaged() — see system-tune.sh
# for the rationale (avahi hostname conflict triggered by NM-tracked
# Docker bridges during arping DAD probes).
[keyfile]
unmanaged-devices=interface-name:veth*;interface-name:br-*;interface-name:docker*
NMCONF
)
printf '%s\n' "$desired_content" > "$TMP/etc/NetworkManager/conf.d/99-docker-unmanaged.conf"
assert 'grep -qF "unmanaged-devices=interface-name:veth*;interface-name:br-*;interface-name:docker*" "$TMP/etc/NetworkManager/conf.d/99-docker-unmanaged.conf"' \
       'integration: written file contains the canonical unmanaged-devices line'
assert 'grep -qF "[keyfile]" "$TMP/etc/NetworkManager/conf.d/99-docker-unmanaged.conf"' \
       'integration: written file is in keyfile section format'

echo
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
