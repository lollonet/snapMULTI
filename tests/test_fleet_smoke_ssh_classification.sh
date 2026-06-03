#!/usr/bin/env bash
# Pin the SSH-failure classification + multiplexing-bypass behaviour in
# scripts/fleet-smoke.sh.
#
# Background: on a home LAN after a reflash, fleet-smoke.sh reported every
# host as `UNREACH ssh-timeout-or-fail` because:
#   - the script inherited the operator's local `ControlMaster auto` /
#     `ControlPath ~/.ssh/sockets/...`, which fails in sandboxed shells
#   - SSH stderr was swallowed by `2>/dev/null`, collapsing every distinct
#     failure into the same opaque blob
#
# The fix introduces two helpers — _classify_ssh_stderr + _ssh_failure_note
# — and bakes `ControlMaster=no` + `ControlPath=none` into SSH_OPTS.
# This test pins both, statically and via function-level unit tests, with
# bash 3.2 compatibility for the macOS dev loop.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FS="$SCRIPT_DIR/../scripts/fleet-smoke.sh"

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

assert_eq() {
    local got="$1" want="$2" desc="$3"
    if [[ "$got" == "$want" ]]; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc"
        echo "        got:  '$got'"
        echo "        want: '$want'"
        fail=$((fail + 1))
    fi
}

echo "== static: SSH_OPTS bypass operator multiplexing =="
assert 'grep -qE "ControlMaster=no" "$FS"' \
    "SSH_OPTS contains ControlMaster=no"
assert 'grep -qE "ControlPath=none" "$FS"' \
    "SSH_OPTS contains ControlPath=none"
# Security: we must NOT have weakened host-key checking while fixing the
# multiplexing issue. `accept-new` is fine; `=no` would silently trust any
# key.
assert 'grep -qE "StrictHostKeyChecking=accept-new" "$FS"' \
    "StrictHostKeyChecking=accept-new preserved"
assert '! grep -qE "StrictHostKeyChecking=no\\b" "$FS"' \
    "no StrictHostKeyChecking=no — host key validation intact"

echo
echo "== static: stderr no longer swallowed =="
# The buggy form was `... 2>/dev/null <<'REMOTE'` immediately above the
# heredoc. The fix routes stderr into a per-host file. Pin both: the
# swallowed-stderr form must NOT come back, and stderr_file must be
# wired.
assert '! grep -qE "ssh .*SSH_OPTS.* 2>/dev/null <<.REMOTE" "$FS"' \
    "ssh invocation no longer redirects stderr to /dev/null"
assert 'grep -qE "stderr_file=" "$FS"' \
    "per-host stderr_file captured for classification"

echo
echo "== function: classification correctness =="
# Source the script in library-only mode so the classifier functions
# become available without triggering main argv parsing or mDNS probes.
__FLEET_SMOKE_LIB_ONLY=1
export __FLEET_SMOKE_LIB_ONLY
# shellcheck source=/dev/null
source "$FS"

assert_eq \
    "$(_classify_ssh_stderr '@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@')" \
    "host-key-changed" \
    "REMOTE HOST IDENTIFICATION HAS CHANGED -> host-key-changed"

assert_eq \
    "$(_classify_ssh_stderr 'snapvideo: Permission denied (publickey).')" \
    "auth-failed" \
    "Permission denied (publickey) -> auth-failed"

assert_eq \
    "$(_classify_ssh_stderr 'unix_listener: cannot bind to path /Users/claudio/.ssh/sockets/abc.sock: No such file or directory')" \
    "ssh-controlpath-error" \
    "unix_listener bind error -> ssh-controlpath-error"

assert_eq \
    "$(_classify_ssh_stderr 'mux_client_request_session: read from master failed: Broken pipe')" \
    "ssh-controlpath-error" \
    "mux_client_request_session -> ssh-controlpath-error"

assert_eq \
    "$(_classify_ssh_stderr 'ssh: connect to host snapvideo port 22: Connection timed out')" \
    "connection-failed" \
    "Connection timed out -> connection-failed"

assert_eq \
    "$(_classify_ssh_stderr 'ssh: Could not resolve hostname snapvideo: nodename nor servname provided')" \
    "connection-failed" \
    "Could not resolve hostname -> connection-failed"

assert_eq \
    "$(_classify_ssh_stderr 'ssh: connect to host snapvideo port 22: Connection refused')" \
    "connection-failed" \
    "Connection refused -> connection-failed"

assert_eq \
    "$(_classify_ssh_stderr 'something unrecognised about ssh')" \
    "ssh-failed" \
    "unrecognised stderr -> ssh-failed (fallback)"

assert_eq \
    "$(_classify_ssh_stderr '')" \
    "ssh-failed" \
    "empty stderr -> ssh-failed (fallback)"

echo
echo "== function: actionable note for host-key-changed =="
host_key_stderr='@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
The fingerprint for the ED25519 key sent by the remote host is
SHA256:ENi/0G+3VgPjVA7JY9CUGs/59IU5rHjQ5zUT3sNpUMA.
Please contact your system administrator.
Add correct host key in /Users/claudio/.ssh/known_hosts to get rid of this message.
Offending ECDSA key in /Users/claudio/.ssh/known_hosts:196
Host key for 192.168.1.42 has changed and you have requested strict checking.
Host key verification failed.'

assert_eq \
    "$(_ssh_failure_note "$host_key_stderr" "snapvideo.local")" \
    "run: ssh-keygen -R snapvideo.local && ssh-keygen -R 192.168.1.42" \
    "host-key-changed note suggests cleaning both name and IP"

# When stderr does not name an IP, still suggest cleaning the host name.
no_ip_stderr='WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED'
assert_eq \
    "$(_ssh_failure_note "$no_ip_stderr" "snapvideo.local")" \
    "run: ssh-keygen -R snapvideo.local" \
    "host-key-changed without IP still suggests cleaning the host name"

# Non-actionable cases return empty so the renderer skips the dash + note.
assert_eq \
    "$(_ssh_failure_note 'Permission denied (publickey)' 'snapvideo')" \
    "" \
    "auth-failed has no note (operator already knows how to fix)"

echo
echo "Results: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
