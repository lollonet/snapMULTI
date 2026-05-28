#!/usr/bin/env bash
# shellcheck disable=SC2016  # assert() conditions are eval'd inside the
#                              function — single quotes are intentional.
#
# Static checks for the avahi-daemon readiness fix.
#
# The bug: snapmulti-server.service (and snapclient.service) only waited
# for `docker info` readiness before `docker compose up -d`. When
# avahi-daemon was still initialising at that point, snapserver's
# libavahi-client connect race-lost — snapserver fell back to PTR-only
# UDP 5353 multicast. Strict mDNS clients (Python zeroconf, snapclient
# 0.36+) failed to discover the service.
#
# The fix:
#   1. Both units have a second ExecStartPre that polls
#      `systemctl is-active --quiet avahi-daemon.service` AND the socket
#      `/run/avahi-daemon/socket` for up to 30 s, then sleeps 2 s for
#      avahi's first announce.
#   2. snapmulti-server.service has an ExecStartPost self-heal: 12 s
#      after compose up, query avahi-browse for _snapcast._tcp; if PTR
#      is present but SRV/TXT are not, restart the snapserver container.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SH="$SCRIPT_DIR/../scripts/deploy.sh"
SETUP_SH="$SCRIPT_DIR/../client/common/scripts/setup.sh"
SYSTEM_TUNE_SH="$SCRIPT_DIR/../scripts/common/system-tune.sh"
SNIPPETS_SH="$SCRIPT_DIR/../scripts/common/systemd-snippets.sh"

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

# Render the snapmulti-server unit body: extract the heredoc, source the
# systemd-snippets helper, set the variables the heredoc references, then
# eval the heredoc body so $(helper) substitutions resolve. This makes
# the test assert on the FINAL unit content (what systemd sees) rather
# than the source-file text — assertions stay valid across refactors
# that move snippet generation behind helpers.
# shellcheck source=../scripts/common/systemd-snippets.sh
source "$SNIPPETS_SH"

render_unit() {
    local script="$1" marker="$2"
    local body
    body=$(awk -v m="$marker" '
        # Match both `cat > X <<EOF` and `cat > X << EOF` (server uses no-space,
        # client uses space) — tolerate either.
        $0 ~ ("cat > " m " *<< *EOF") {flag=1; next}
        flag && /^EOF$/ {flag=0; exit}
        flag {print}
    ' "$script")
    # Variables referenced inside the heredoc — set with install-time
    # defaults. shellcheck can't see through eval, so the SC2034 disables
    # below acknowledge that these locals are consumed by the heredoc
    # expansion. _after_units is only used by the client unit,
    # music_mount_clause only by the server unit.
    # shellcheck disable=SC2034
    local PROJECT_ROOT=/opt/snapmulti
    # shellcheck disable=SC2034
    local INSTALL_DIR=/opt/snapclient
    # shellcheck disable=SC2034
    local music_mount_clause=""
    # shellcheck disable=SC2034
    local _after_units="docker.service network-online.target avahi-daemon.service"
    eval "cat <<EOF
$body
EOF"
}

echo "=== snapmulti-server.service — avahi readiness ExecStartPre ==="

server_unit=$(render_unit "$DEPLOY_SH" "/etc/systemd/system/snapmulti-server.service")

assert 'echo "$server_unit" | grep -qE "ExecStartPre=.*systemctl is-active --quiet avahi-daemon"' \
       'snapmulti-server has ExecStartPre gating on avahi-daemon is-active'

assert 'echo "$server_unit" | grep -qE "ExecStartPre=.*-S /run/avahi-daemon/socket"' \
       'snapmulti-server gates on /run/avahi-daemon/socket existence'

# Must NOT exit 1 — we want non-fatal fallthrough (avahi may be missing
# in unusual setups, the unit must still come up).
assert '! (echo "$server_unit" | grep -E "ExecStartPre.*avahi-daemon" | grep -qE "exit 1")' \
       'avahi readiness ExecStartPre is non-fatal (no exit 1)'

# Avahi-readiness ExecStartPre must come AFTER docker readiness one.
docker_line=$(echo "$server_unit" | grep -nE "ExecStartPre=.*docker info" | head -1 | cut -d: -f1)
avahi_line=$(echo "$server_unit" | grep -nE "ExecStartPre=.*avahi-daemon" | head -1 | cut -d: -f1)
if [[ -n "$docker_line" && -n "$avahi_line" && "$avahi_line" -gt "$docker_line" ]]; then
    echo "  PASS: avahi ExecStartPre runs AFTER docker readiness check"
    pass=$((pass + 1))
else
    echo "  FAIL: avahi ExecStartPre order wrong (docker=$docker_line, avahi=$avahi_line)"
    fail=$((fail + 1))
fi

echo
echo "=== snapmulti-server.service — mDNS self-heal ExecStartPost ==="

assert 'echo "$server_unit" | grep -qE "ExecStartPost"' \
       'snapmulti-server has an ExecStartPost hook'

assert 'echo "$server_unit" | grep -qE "avahi-browse.*_snapcast"' \
       'ExecStartPost queries avahi-browse for _snapcast._tcp'

# Critical: avahi-browse must NOT carry the `-l` flag (--ignore-local).
# Local services are EXACTLY what we want to inspect — `-l` would
# exclude this host's snapserver records and the self-heal would
# never fire. Same convention as device-smoke.sh and
# discover-server.sh, which both omit -l.
assert '! echo "$server_unit" | grep -qE "avahi-browse [^_]*-[prtl]*l[prtl]* _snapcast"' \
       'avahi-browse runs WITHOUT -l (--ignore-local would skip our own records)'

assert 'echo "$server_unit" | grep -qE "docker compose.*restart snapserver"' \
       'ExecStartPost restarts snapserver on PTR-only detection'

# systemd parses backslash escapes in ExecStart* lines. Regexes such as
# `\+` and `\.` trigger "Ignoring unknown escape sequences" warnings at
# every daemon-reload. Use bracket expressions (`[+]`, `[.]`) instead.
assert '! echo "$server_unit" | grep -qF "\\+" && ! echo "$server_unit" | grep -qF "\\."' \
       'ExecStartPost avoids systemd unknown escape warnings in grep regexes'

# Self-heal must be ignore-failure (leading -) so a transient avahi-browse
# error never holds the unit in failed state.
assert 'echo "$server_unit" | grep -qE "ExecStartPost=-"' \
       'ExecStartPost is non-fatal (leading -)'

# mem_limit drift recreate guard — symmetric to snapclient.service (PR #393).
# Live evidence on pi4-test post-reflash: 7 server containers had
# HostConfig.Memory=0 because the first compose up ran before cgroup v2
# was active. The guard probes snapserver and force-recreates the stack
# when limit==0. Must be non-fatal (leading -) so a missing/transient
# docker inspect does not hold the unit in failed state.
assert 'echo "$server_unit" | grep -qE "ExecStartPre=-.*docker inspect snapserver.*HostConfig.Memory"' \
       'server has mem-drift force-recreate ExecStartPre (symmetric to snapclient)'

assert 'echo "$server_unit" | grep -qE "ExecStartPre=-.*if \[\[ .*mem.* == .0..*compose up -d --force-recreate"' \
       'server mem-drift guard force-recreates when HostConfig.Memory=0'

# State restore must run before the mem-drift guard because that guard can
# start Compose via force-recreate. Restoring afterward is too late:
# snapserver may already have created a default server.json.
restore_line=$(echo "$server_unit" | grep -nE "^ExecStartPre=/usr/local/sbin/restore-snapmulti-state" | head -1 | cut -d: -f1)
mem_line=$(echo "$server_unit" | grep -nE "^ExecStartPre=-.*docker inspect snapserver.*HostConfig.Memory" | head -1 | cut -d: -f1)
if [[ -n "$restore_line" && -n "$mem_line" && "$restore_line" -lt "$mem_line" ]]; then
    echo "  PASS: restore-snapmulti-state runs BEFORE mem-drift force-recreate"
    pass=$((pass+1))
else
    echo "  FAIL: restore-snapmulti-state order wrong (restore=$restore_line, mem=$mem_line)"
    fail=$((fail+1))
fi

assert 'echo "$server_unit" | grep -qE "^ExecStartPre=/usr/local/sbin/restore-snapmulti-state"' \
       'restore-snapmulti-state failures are fatal (no leading -)'

# PartOf=avahi-daemon.service has been removed: it gave Avahi full
# lifecycle control over the audio stack, so a routine avahi restart
# took the whole stack down. Server-side recovery from the snapcast
# 0.35 libavahi-client reconnect bug is now via explicit operator
# restart (tune_avahi_daemon) + the ExecStartPost mDNS self-heal.
assert '! echo "$server_unit" | grep -qE "^PartOf=.*avahi-daemon"' \
       'snapmulti-server.service does NOT have PartOf=avahi-daemon.service'

# ExecStop must NOT use `docker compose down` — that removes containers
# and the compose network, so a `systemctl restart` (operator or system)
# costs 30-40 s of audio silence. Use `docker compose stop -t 5`
# instead: containers and network persist, the next ExecStart=up -d
# is a fast `start`, the snapcast 0.35 libavahi-client reconnect bug
# is still resolved because the snapserver process restarts fresh
# inside the container.
assert '! echo "$server_unit" | grep -qE "^ExecStop=.*compose down"' \
       'ExecStop does NOT use destructive `compose down`'

assert 'echo "$server_unit" | grep -qE "^ExecStop=.*compose stop -t 5"' \
       'ExecStop uses non-destructive `compose stop -t 5`'

echo
echo "=== snapclient.service — avahi readiness ExecStartPre ==="

client_unit=$(render_unit "$SETUP_SH" "/etc/systemd/system/snapclient.service")

assert 'echo "$client_unit" | grep -qE "ExecStartPre=.*systemctl is-active --quiet avahi-daemon"' \
       'snapclient has ExecStartPre gating on avahi-daemon is-active'

assert 'echo "$client_unit" | grep -qE "ExecStartPre=.*-S /run/avahi-daemon/socket"' \
       'snapclient gates on /run/avahi-daemon/socket existence'

# Discover-server must run AFTER the avahi readiness wait — otherwise
# avahi-browse fired by snapclient-discover comes back empty. Filter by
# ExecStartPre prefix to avoid matching the explanatory comment.
avahi_cl=$(echo "$client_unit" | grep -nE "^ExecStartPre=.*avahi-daemon" | head -1 | cut -d: -f1)
discover_cl=$(echo "$client_unit" | grep -nE "^ExecStartPre=.*snapclient-discover" | head -1 | cut -d: -f1)
if [[ -n "$avahi_cl" && -n "$discover_cl" && "$avahi_cl" -lt "$discover_cl" ]]; then
    echo "  PASS: avahi readiness wait runs BEFORE snapclient-discover"
    pass=$((pass + 1))
else
    echo "  FAIL: snapclient-discover runs before avahi wait (avahi=$avahi_cl, discover=$discover_cl)"
    fail=$((fail + 1))
fi

# Same PartOf= removal + non-destructive ExecStop rules apply on the
# client side. See server assertions above for the rationale.
assert '! echo "$client_unit" | grep -qE "^PartOf=.*avahi-daemon"' \
       'snapclient.service does NOT have PartOf=avahi-daemon.service'

assert '! echo "$client_unit" | grep -qE "^ExecStop=.*compose down"' \
       'snapclient ExecStop does NOT use destructive `compose down`'

assert 'echo "$client_unit" | grep -qE "^ExecStop=.*compose stop -t 5"' \
       'snapclient ExecStop uses non-destructive `compose stop -t 5`'

# tune_avahi_daemon must restart the snapcast units after touching
# the config — otherwise the snapcast 0.35 libavahi-client reconnect
# bug leaves mDNS publish broken. This is the explicit replacement
# for the PartOf= cascade we just removed.
assert 'grep -qE "for audio_unit in snapmulti-server.service snapclient.service" "$SYSTEM_TUNE_SH"' \
       'tune_avahi_daemon restarts snapmulti-server.service + snapclient.service after avahi restart'

echo
echo "=== Avahi host tuning ==="

assert 'grep -qE "^tune_avahi_daemon\\(\\)" "$SYSTEM_TUNE_SH"' \
       'tune_avahi_daemon is defined'

assert 'grep -qF "use-ipv4=yes" "$SYSTEM_TUNE_SH"' \
       'tune_avahi_daemon forces Avahi IPv4 on'

assert 'grep -qF "use-ipv6=no" "$SYSTEM_TUNE_SH"' \
       'tune_avahi_daemon forces Avahi IPv6 off'

assert 'grep -qF "Snapclient 0.35 can pick IPv6" "$SYSTEM_TUNE_SH"' \
       'IPv6-off rationale is documented near the tuning code'

assert 'grep -qF "ip -o route show default" "$SYSTEM_TUNE_SH"' \
       'tune_avahi_daemon prefers default-route interface for mDNS'

assert 'grep -qF "ip -o -4 addr show scope global up" "$SYSTEM_TUNE_SH"' \
       'tune_avahi_daemon has IPv4-up physical-interface fallback'

# #425 — wired-carrier priority prevents the dual-publish race during
# the 6-sec window where wlan0 still has its DHCP address before
# boot-tune.sh disables WiFi. When eth*/en* has carrier we restrict
# Avahi to wired only, so the reflector never sees a transient WiFi
# announcement that would force a <host>-2.local rename on conflict.
assert 'grep -qF "for iface in /sys/class/net/eth* /sys/class/net/en*" "$SYSTEM_TUNE_SH"' \
       'tune_avahi_daemon enumerates wired interfaces by /sys/class/net'

assert 'grep -qF "carrier" "$SYSTEM_TUNE_SH"' \
       'tune_avahi_daemon checks wired carrier state'

assert 'grep -qF "wired_iface" "$SYSTEM_TUNE_SH"' \
       'tune_avahi_daemon prefers wired interface when carrier is up'

echo
echo "=== firstboot.sh — Avahi retune after network ==="

FIRSTBOOT_SH="$SCRIPT_DIR/../scripts/firstboot.sh"
network_line=$(grep -nE "^[[:space:]]*wait_for_network$" "$FIRSTBOOT_SH" | head -1 | cut -d: -f1)
retune_line=$(grep -nE "tune_avahi_daemon \"\\$\\(hostname\\)\"" "$FIRSTBOOT_SH" | head -1 | cut -d: -f1)
milestone_line=$(grep -nF 'milestone "$CURRENT_STEP" "Network ready"' "$FIRSTBOOT_SH" | head -1 | cut -d: -f1)
if [[ -n "$network_line" && -n "$retune_line" && -n "$milestone_line" \
      && "$network_line" -lt "$retune_line" && "$retune_line" -lt "$milestone_line" ]]; then
    echo "  PASS: firstboot retunes Avahi after wait_for_network and before Network-ready milestone"
    pass=$((pass + 1))
else
    echo "  FAIL: firstboot Avahi retune ordering wrong (network=$network_line retune=$retune_line milestone=$milestone_line)"
    fail=$((fail + 1))
fi

echo
echo "=== Bash syntax ==="
for f in "$DEPLOY_SH" "$SETUP_SH" "$SYSTEM_TUNE_SH" "$FIRSTBOOT_SH"; do
    if bash -n "$f"; then
        echo "  PASS: bash -n $(basename "$f")"
        pass=$((pass + 1))
    else
        echo "  FAIL: bash -n $(basename "$f")"
        fail=$((fail + 1))
    fi
done

echo
echo "=== Summary ==="
echo "  Pass: $pass"
echo "  Fail: $fail"

[[ "$fail" -eq 0 ]]
