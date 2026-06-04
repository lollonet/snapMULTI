#!/usr/bin/env bash
# fleet-smoke.sh — discover a snapMULTI fleet from one server, run smoke on all hosts
#
# Walks the Snapcast JSON-RPC API on the server (:1780/jsonrpc) to enumerate
# every connected client, then SSHs in parallel to (server + clients) to:
#   1. read SNAPMULTI_RELEASE from /opt/snapmulti/.env + /opt/snapclient/.env
#      (release identity, bare tag) and /opt/snapmulti/VERSION +
#      /opt/snapclient/VERSION (build id, may include `-N-gSHA` distance
#      suffix when flashed from a post-tag main HEAD)
#   2. invoke /opt/.../scripts/device-smoke.sh --json --no-fail-on-warn
# Aggregates the results into a single table (or one JSON object with --json).
#
# Usage:
#   ./scripts/fleet-smoke.sh                       # auto-discover server
#   ./scripts/fleet-smoke.sh --server pi-server    # explicit server
#   ./scripts/fleet-smoke.sh --json                # machine output
#   ./scripts/fleet-smoke.sh --client-only         # skip server, smoke clients only
#
# Requirements on the operator machine: curl, jq, ssh.
# Requirements on each device: snapMULTI v0.7.0+ (device-smoke.sh --json schema 1).
# No Ansible. No state files. Idempotent and read-only — never modifies devices.

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────
SERVER=""
SSH_USER="${USER}"
# ServerAliveInterval=15 + ServerAliveCountMax=3 = client-side keepalive
# every 15 s, give up after 3 missed (~45 s) so a host whose TCP socket
# stays open but whose remote `bash -s` is wedged does not hang the
# fleet probe. The external `timeout` binary set up below is the
# primary kill switch, but macOS dev boxes routinely lack it; this
# keeps the worst-case bounded regardless.
#
# ControlMaster=no + ControlPath=none: ignore the operator's local SSH
# multiplexing config. On dev/sandbox boxes the user's `ControlPath`
# (~/.ssh/sockets/...) can point at a path that the script process
# cannot bind, surfacing as `unix_listener: cannot bind to path` and
# collapsing every host into a generic "ssh-timeout-or-fail". Forcing
# no-mux per-invocation keeps the probe independent of the operator's
# global SSH state.
SSH_OPTS=(-o ConnectTimeout=8 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
          -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
          -o ControlMaster=no -o ControlPath=none)
OUTPUT="text"
CLIENT_ONLY=false
TIMEOUT_SMOKE=120

# ── SSH error classification ─────────────────────────────────────
# Sort SSH stderr into actionable error codes consumed by the renderer
# and by --json output. Order matters: more specific patterns first so
# `Permission denied` does not eat e.g. a future "Permission denied (gss)"
# we want classified separately.
_classify_ssh_stderr() {
    local stderr="$1"
    case "$stderr" in
        *"REMOTE HOST IDENTIFICATION HAS CHANGED"*) printf 'host-key-changed' ;;
        *"unix_listener"*|*"mux_client_request_session"*|*"ControlPath"*|*"ControlSocket"*|*"multiplexing"*) printf 'ssh-controlpath-error' ;;
        *"Permission denied"*|*"publickey"*) printf 'auth-failed' ;;
        *"Connection timed out"*|*"Operation timed out"*|*"No route to host"*|*"Could not resolve hostname"*|*"Network is unreachable"*|*"Name or service not known"*|*"Connection refused"*|*"Host is down"*|*"Host is unreachable"*) printf 'connection-failed' ;;
        *) printf 'ssh-failed' ;;
    esac
}

# Build an actionable note for the operator when stderr names a fix.
# Today: just host-key-changed. Extend as new actionable cases land.
_ssh_failure_note() {
    local stderr="$1" host="$2"
    case "$stderr" in
        *"REMOTE HOST IDENTIFICATION HAS CHANGED"*)
            # ssh prints "Offending [ECDSA|ED25519|...] key in <path>:<line>"
            # plus sometimes the IP. Suggest cleaning both name + IP from
            # known_hosts so the next probe reconciles cleanly.
            local ip
            ip=$(printf '%s' "$stderr" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1 || true)
            if [[ -n "$ip" ]]; then
                printf 'run: ssh-keygen -R %s && ssh-keygen -R %s' "$host" "$ip"
            else
                printf 'run: ssh-keygen -R %s' "$host"
            fi
            ;;
        *) printf '' ;;
    esac
}

# probe_host is defined HERE (above the library-mode guard, despite the
# main parallel loop calling it ~400 lines below) so the regression test
# can source the script + drive a real failure path with a stubbed ssh.
# Bash defers variable resolution to invocation time, so referencing
# TIMEOUT_CMD / SSH_OPTS / SSH_USER / TMP — all set further down — is
# safe as long as the test sets them itself before calling probe_host.

# Single source of truth for the remote ~30-line bash payload that
# probe_host streams over ssh. Lives as a here-doc-captured variable
# instead of two inlined heredocs (one per timeout-wrapped vs bare-ssh
# branch) so a future change to the payload is impossible to apply to
# only half of probe_host. The script runs on every snapMULTI host the
# operator points fleet-smoke at — `/opt/snapmulti/.../device-smoke.sh
# --json` is the source of truth for the smoke verdict that drives the
# fleet aggregate. NB: single-quoted heredoc delimiter (`<<'PAYLOAD'`)
# disables variable expansion so the payload reaches the device verbatim.
_FLEET_SMOKE_REMOTE_PAYLOAD=$(cat <<'PAYLOAD'
# Two distinct version notions on a snapMULTI device:
#   * RELEASE IDENTITY — the snapMULTI release line ("v0.8.1"). Single
#     source of truth: SNAPMULTI_RELEASE in /opt/snapmulti/.env or
#     /opt/snapclient/.env (baked from release-manifest.json at flash).
#     This is what device-smoke.sh prints as "Release vX.Y.Z" and what
#     the operator means by "what version is this device running".
#   * BUILD ID — the literal `git describe --tags` value of the commit
#     the SD was prepared from ("v0.8.1" when flashed from the tag,
#     "v0.8.1-7-g68e102f" when flashed from N commits past the tag).
#     Lives in /opt/snapmulti/VERSION or /opt/snapclient/VERSION.
# Pre-fix this script confused the two: it compared client BUILD ID
# against server RELEASE IDENTITY and called any mismatch "version
# drift". A fleet flashed from a mix of tag + post-tag main HEAD
# tripped that check on every client even though every device was on
# the same release line. The drift check below now reads the release
# identity; the build id is kept in `versions` for --json consumers
# (operator debugging — "which commit did I flash this from").
_read_release_from_env() {
    local env_file="$1"
    [ -r "$env_file" ] || return 0
    grep -m1 '^SNAPMULTI_RELEASE=' "$env_file" 2>/dev/null | cut -d= -f2- | tr -d '"'\''[:space:]'
}
# Client-native installs (Pi Zero 2 W path) have no `.env` because
# there is no docker-compose stack — snapclient runs as a plain
# systemd unit. Their release identity lives only in the manifest
# on the boot partition. Fall back to it when no `.env` is present.
_read_release_from_manifest() {
    local manifest="${1:-/boot/firmware/snapmulti/release-manifest.json}"
    [ -r "$manifest" ] || return 0
    # No jq dependency on the device side: a single field grep is fine
    # because release-manifest.json is a short, machine-written file
    # with one "snapmulti_release" key.
    grep -m1 '"snapmulti_release"' "$manifest" 2>/dev/null \
        | sed -E 's/.*"snapmulti_release"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' \
        | tr -d '[:space:]'
}
srv_build=$(cat /opt/snapmulti/VERSION 2>/dev/null || echo "")
cli_build=$(cat /opt/snapclient/VERSION 2>/dev/null || echo "")
srv_release=$(_read_release_from_env /opt/snapmulti/.env)
cli_release=$(_read_release_from_env /opt/snapclient/.env)
if [ -z "$srv_release" ] && [ -z "$cli_release" ]; then
    manifest_release=$(_read_release_from_manifest)
    # Assign to the role-canonical slot. A client-native device is
    # always a client, so attribute the manifest release to cli_release.
    # If /opt/snapmulti exists we are server / both — attribute to srv.
    if [ -d /opt/snapmulti ]; then
        srv_release="$manifest_release"
    else
        cli_release="$manifest_release"
    fi
fi
smoke_script=""
if [ -x /opt/snapmulti/scripts/device-smoke.sh ]; then
    smoke_script=/opt/snapmulti/scripts/device-smoke.sh
elif [ -x /opt/snapclient/scripts/device-smoke.sh ]; then
    smoke_script=/opt/snapclient/scripts/device-smoke.sh
fi
if [ -n "$smoke_script" ]; then
    smoke_json=$(sudo -n "$smoke_script" --json --no-fail-on-warn 2>/dev/null || true)
else
    smoke_json=""
fi
[ -z "$smoke_json" ] && smoke_json="{}"
SMOKE_JSON="$smoke_json" python3 -c '
import json
import os
import sys

srv_build = sys.argv[1]
cli_build = sys.argv[2]
srv_release = sys.argv[3]
cli_release = sys.argv[4]
raw = os.environ.get("SMOKE_JSON", "").strip()
smoke = {}
if raw:
    try:
        smoke, _ = json.JSONDecoder().raw_decode(raw)
    except json.JSONDecodeError:
        smoke = {}
print(json.dumps({
    "srv": srv_build,
    "cli": cli_build,
    "release_srv": srv_release,
    "release_cli": cli_release,
    "smoke": smoke,
}, separators=(",", ":")))
' "$srv_build" "$cli_build" "$srv_release" "$cli_release"
PAYLOAD
)

probe_host() {
    local host="$1"
    local role="$2"
    local out="$TMP/${host//[^a-zA-Z0-9_-]/_}.json"
    # Capture SSH stderr so a failure surfaces with a specific cause
    # instead of the legacy generic "ssh-timeout-or-fail" blob. The
    # exit code distinguishes `timeout(1)` (124) from a true SSH error.
    local stderr_file="$TMP/${host//[^a-zA-Z0-9_-]/_}.stderr"
    # On the device: read VERSION files, run smoke --json. Both best-effort.
    # The smoke wrapper exits 0/1; --no-fail-on-warn keeps us non-fatal on WARN.
    # Script piped via stdin to avoid quoting hell with -c '...'.
    local payload
    local rc=0
    # NB: `|| rc=$?` MUST sit outside the `$(...)` — inside the command
    # substitution it runs in a subshell and the assignment to `rc` never
    # propagates to the caller, so `if (( rc != 0 ))` below would always
    # see 0 and the classification path would be silently bypassed.
    # Reviewed in PR #589 (claude-review HIGH).
    #
    # Split the timeout-prefixed vs bare-ssh forms because bash 3.2
    # expands `"${TIMEOUT_CMD[@]}"` under `set -u` to an unbound-variable
    # error when TIMEOUT_CMD=() (macOS dev box without timeout/gtimeout,
    # or library-mode test). Bash 5 silently treats empty-array `[@]` as
    # zero words, so the script "worked" in CI but bombed on real dev
    # macs. The branch keeps the timeout wrapper when present, drops it
    # cleanly when absent — same observable behaviour as a 4-arg vs
    # 3-arg invocation, no empty-array expansion under `set -u`.
    # The remote payload lives in $_FLEET_SMOKE_REMOTE_PAYLOAD above —
    # single source of truth so a future change can't be applied to only
    # one of the timeout-wrapped / bare-ssh branches. `<<<` pipes the
    # variable to the ssh remote shell as stdin (equivalent to the
    # previous inline heredoc, no quoting overhead).
    if (( ${#TIMEOUT_CMD[@]} > 0 )); then
        payload=$("${TIMEOUT_CMD[@]}" \
                ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" 'bash -s' \
                2>"$stderr_file" <<<"$_FLEET_SMOKE_REMOTE_PAYLOAD") || rc=$?
    else
        payload=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" 'bash -s' \
                2>"$stderr_file" <<<"$_FLEET_SMOKE_REMOTE_PAYLOAD") || rc=$?
    fi
    if (( rc != 0 )); then
        # `timeout(1)` sends SIGTERM and exits 124 on its own timeout —
        # distinguish from a true SSH error so the operator does not chase
        # a host-key / auth issue when the actual problem was a stuck
        # remote shell.
        local err note stderr_content
        stderr_content=$(cat "$stderr_file" 2>/dev/null || true)
        if (( rc == 124 )); then
            err="smoke-timeout"
            note=""
        else
            err=$(_classify_ssh_stderr "$stderr_content")
            note=$(_ssh_failure_note "$stderr_content" "$host")
        fi
        jq -nc --arg h "$host" --arg r "$role" \
                --arg err "$err" --arg note "$note" \
            '{host:$h, role:$r, reachable:false, error:$err, note:$note}' >"$out"
        return
    fi
    # Sanitize: some hosts ship a stdout-echoing login banner (motd, last
    # login, PAM echo) ahead of `bash -s`. The remote python3 prints the
    # JSON as a SINGLE LINE (separators=(",",":")), so picking the line
    # that starts with `{` and ends with `}` after the banner is robust
    # and avoids breaking the subsequent jq parse.
    payload=$(printf '%s\n' "$payload" | awk '/^\{.*\}$/' | tail -n 1)
    # Validate JSON; if smoke returned non-JSON (older snapMULTI?), mark partial.
    if ! jq -e . <<<"$payload" >/dev/null 2>&1; then
        jq -nc --arg h "$host" --arg r "$role" --arg raw "$payload" \
            '{host:$h, role:$r, reachable:true, parse_error:true, raw:$raw}' >"$out"
        return
    fi
    # Compose final per-host record.
    # `release` is the snapMULTI release identity (bare tag, e.g. "v0.8.1")
    # read from SNAPMULTI_RELEASE in .env. `versions` is the build id
    # (`git describe --tags` baked on prepare-sd, e.g. "v0.8.1-7-g68e102f")
    # — useful for "which commit did I flash from?" but never used for the
    # drift check since two devices on the same release flashed from
    # different post-tag commits are not drifting.
    jq --arg h "$host" --arg r "$role" \
        '{host:$h, role:$r, reachable:true,
          release:{server:.release_srv, client:.release_cli},
          versions:{server:.srv, client:.cli},
          non_snapmulti: ((.srv == "" and .cli == "" and .release_srv == "" and .release_cli == "") and ((.smoke.schema_version // null) == null)),
          smoke:.smoke}' <<<"$payload" >"$out"
}

# Library mode — when sourced for tests, stop here so the test can call
# the classification helpers + probe_host without triggering arg parsing,
# mDNS probes, or SSH against real hosts.
if [[ "${__FLEET_SMOKE_LIB_ONLY:-}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi

# ── Usage ────────────────────────────────────────────────────────
usage() {
    cat <<'EOF'
fleet-smoke.sh — discover + smoke a snapMULTI fleet from one server

Options:
  --server HOST       Snapcast server hostname (default: auto-discover via mDNS)
  --ssh-user USER     SSH user (default: current $USER)
  --json              Machine-readable JSON output (one object, all hosts)
  --client-only       Skip the server, smoke connected clients only
  --timeout N         Per-host smoke timeout in seconds (default: 120)
  -h, --help          Show this help

Exit code:
  0 — all reachable hosts passed smoke
  1 — at least one host failed
  2 — usage / unreachable server error
EOF
}

# ── Parse args ────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --server)        SERVER="${2:?--server requires a hostname}"; shift 2 ;;
        --ssh-user)      SSH_USER="${2:?--ssh-user requires a user}"; shift 2 ;;
        --json)          OUTPUT="json"; shift ;;
        --client-only)   CLIENT_ONLY=true; shift ;;
        --timeout)       TIMEOUT_SMOKE="${2:?--timeout requires N}"; shift 2 ;;
        -h|--help)       usage; exit 0 ;;
        *)               echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# ── Preflight: tooling ────────────────────────────────────────────
for cmd in curl jq ssh; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "ERROR: required command not found: $cmd" >&2
        echo "  macOS: brew install jq curl" >&2
        echo "  Linux: apt-get install jq curl openssh-client" >&2
        exit 2
    }
done

# `timeout` is GNU coreutils — present on Linux, missing on macOS unless
# `brew install coreutils` (which installs it as `gtimeout`). Pick whichever
# exists; if neither, run without a hard kill — SSH's ConnectTimeout
# still bounds connect-phase hangs, just not post-connect stuck shells.
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD=(timeout "$TIMEOUT_SMOKE")
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD=(gtimeout "$TIMEOUT_SMOKE")
else
    echo "WARN: no \`timeout\` / \`gtimeout\` found — per-host smoke can hang." >&2
    echo "      Install: macOS  brew install coreutils  /  Linux  apt-get install coreutils" >&2
    TIMEOUT_CMD=()
fi

run_with_timeout() {
    local seconds="$1"
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$seconds" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$seconds" "$@"
    else
        "$@" &
        local pid=$!
        (
            sleep "$seconds"
            kill "$pid" 2>/dev/null || true
        ) &
        local watchdog=$!
        wait "$pid" 2>/dev/null
        local rc=$?
        kill "$watchdog" 2>/dev/null || true
        wait "$watchdog" 2>/dev/null || true
        return "$rc"
    fi
}

# ── Discover server (if not given) ────────────────────────────────
discover_server() {
    # Try mDNS browse — prefer dns-sd (macOS) then avahi-browse (linux).
    # Pick the first _snapcast._tcp service that resolves to a reachable
    # JSON-RPC endpoint. We DO NOT pick blindly — many things publish PTR
    # without SRV+TXT; require a successful curl probe.
    #
    # macOS quirks that previously broke discovery:
    #   1. `dns-sd | awk` buffers in pipes → `timeout 4` killed the process
    #      before any output flushed. Wrap with `stdbuf -oL` (present in
    #      /usr/bin since macOS 12 and also via brew coreutils).
    #   2. The instance name returned by `dns-sd -B` is the service label
    #      (e.g. literal "Snapcast"), NOT a resolvable hostname. We must
    #      follow up with `dns-sd -L <instance>` and pull the SRV Target.
    local candidates=()
    local stdbuf_cmd=()
    if command -v stdbuf >/dev/null 2>&1; then
        stdbuf_cmd=(stdbuf -oL)
    fi

    if command -v dns-sd >/dev/null 2>&1; then
        local instances=() line inst
        while IFS= read -r line; do
            # Only `Add` rows expose an instance. The instance name is always
            # the LAST whitespace-delimited field on the row, regardless of
            # whether macOS emits a domain column between the service type and
            # the instance (e.g. `Add 2 0 _snapcast._tcp. local. Snapcast` vs
            # `Add 2 0 _snapcast._tcp. Snapcast`). $NF is format-agnostic and
            # handles both layouts; the previous `-F` split on the service-
            # type token silently produced "local.<spaces>Snapcast" on the
            # domain-column variant, which then failed silently in `dns-sd -L`.
            if [[ "$line" == *"Add"* && "$line" == *"_snapcast._tcp."* ]]; then
                inst=$(echo "$line" | awk '{print $NF}')
                [[ -n "$inst" ]] && instances+=("$inst")
            fi
        done < <(run_with_timeout 4 "${stdbuf_cmd[@]}" dns-sd -B _snapcast._tcp local 2>/dev/null || true)

        # Deduplicate instances (mDNS often echoes Add on multiple interfaces).
        local uniq_instances=()
        local seen
        for inst in "${instances[@]}"; do
            seen=0
            for s in "${uniq_instances[@]}"; do
                [[ "$s" == "$inst" ]] && { seen=1; break; }
            done
            (( seen == 0 )) && uniq_instances+=("$inst")
        done

        # Resolve each instance to its SRV Target.
        local resolve_line host
        for inst in "${uniq_instances[@]}"; do
            resolve_line=$(run_with_timeout 3 "${stdbuf_cmd[@]}" dns-sd -L "$inst" _snapcast._tcp local 2>/dev/null \
                            | grep -m1 'can be reached at' || true)
            # Line format: `<fqdn>. can be reached at <host>.local.:<port> (interface N)`
            host=$(echo "$resolve_line" | sed -nE 's/.*can be reached at ([^ :]+):[0-9]+.*/\1/p')
            host="${host%.}"        # strip trailing dot
            host="${host%.local}"   # strip .local suffix (curl resolves it locally)
            [[ -n "$host" ]] && candidates+=("$host")
        done
    elif command -v avahi-browse >/dev/null 2>&1; then
        while IFS= read -r host; do
            [[ -n "$host" ]] && candidates+=("${host%.local}")
        done < <(run_with_timeout 4 "${stdbuf_cmd[@]}" avahi-browse -prt _snapcast._tcp 2>/dev/null \
                  | awk -F';' '/^=/ {print $7}' | sort -u || true)
    fi

    # Probe each candidate; first one that responds wins. Try bare and
    # `.local` form — bare may resolve only on systems with mDNS as the
    # default resolver, `.local` works wherever an mDNS responder is up.
    local h url
    for h in "${candidates[@]}"; do
        for url in "http://${h}:1780/jsonrpc" "http://${h}.local:1780/jsonrpc"; do
            if curl -sS --max-time 3 \
                  -X POST -H 'Content-Type: application/json' \
                  -d '{"jsonrpc":"2.0","id":0,"method":"Server.GetStatus"}' \
                  "$url" >/dev/null 2>&1; then
                # Strip trailing path so the caller gets just the host token.
                echo "$h"
                return 0
            fi
        done
    done
    return 1
}

if [[ -z "$SERVER" ]]; then
    echo "Discovering Snapcast server via mDNS..." >&2
    SERVER=$(discover_server || true)
    if [[ -z "$SERVER" ]]; then
        echo "ERROR: could not auto-discover a Snapcast server." >&2
        echo "       Pass --server <hostname> or check that _snapcast._tcp resolves." >&2
        exit 2
    fi
    echo "  → ${SERVER}" >&2
fi

# ── Query Server.GetStatus ────────────────────────────────────────
RPC_URL="http://${SERVER}:1780/jsonrpc"
echo "Querying ${RPC_URL}..." >&2
RPC_OUT=$(curl -sS --max-time 8 \
    -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"Server.GetStatus"}' \
    "$RPC_URL" 2>/dev/null) || {
        echo "ERROR: Snapcast JSON-RPC unreachable at $RPC_URL" >&2
        exit 2
    }

# Extract:
#   - server hostname/IP from .result.server.host.name (snapcast reports its own host)
#   - each connected client's host.name (preferred over IP for SSH)
#   - connected non-snapMULTI clients for operator visibility only.
#     Example: iOS/macOS Snapcast apps connected to the server. They are
#     audio clients, not SSH-managed fleet nodes.
#   - disconnected paired clients for operator visibility only. They are
#     stale/offline peers remembered by Snapserver, not fleet-smoke
#     targets and not failures.
SERVER_REPORTED=$(jq -r '.result.server.host.name // ""' <<<"$RPC_OUT")
CONNECTED_NON_SNAPMULTI_JSON=$(jq -c '
    [.result.server.groups[]?.clients[]?
     | select(.connected == true)
     | select(((.host.os // "") != "") and (((.host.os // "") | startswith("Debian GNU/Linux")) | not))
     | {
         name: (.host.name // .host.ip // .id // "unknown"),
         ip: (.host.ip // ""),
         os: (.host.os // ""),
         id: (.id // "")
       }]
    | unique_by([.id, .name, .ip])
' <<<"$RPC_OUT")
DISCONNECTED_CLIENTS_JSON=$(jq -c '
    [.result.server.groups[]?.clients[]?
     | select(.connected != true)
     | {
         name: (.host.name // .host.ip // .id // "unknown"),
         ip: (.host.ip // ""),
         id: (.id // ""),
         last_seen: (.lastSeen.sec // null)
       }]
    | unique_by([.id, .name, .ip])
' <<<"$RPC_OUT")
CLIENTS=()
while IFS= read -r client_host; do
    [[ -n "$client_host" ]] && CLIENTS+=("$client_host")
done < <(
    jq -r '.result.server.groups[]?.clients[]?
            | select(.connected == true)
            | select(((.host.os // "") == "") or ((.host.os // "") | startswith("Debian GNU/Linux")))
            | .host.name' <<<"$RPC_OUT" | sort -u
)

# Build the run list. Use the operator-given --server as the SSH target
# for the server (preserves whatever name they reached it by); the
# snapcast-reported hostname is informational only.
declare -a HOSTS ROLES
if [[ "$CLIENT_ONLY" != "true" ]]; then
    HOSTS+=("$SERVER")
    ROLES+=("server")
fi
for c in "${CLIENTS[@]}"; do
    # Skip the server hostname if it also appears in the client list:
    # a `both`-mode device (server + colocated client) shows up in
    # snapcast's client list AND is the SSH target hostname. Avoid the
    # duplicate SSH probe — the single probe already covers BOTH sides
    # because `device-smoke.sh` auto-detects MODE=both when /opt/snapmulti/
    # AND /opt/snapclient/ are present (see device-smoke.sh ~line 183),
    # and runs every server-side AND client-side check module in one
    # pass. The "server" label in the ROLE column therefore reflects
    # the SSH-target role, not the coverage scope; on a `both` device
    # the smoke records JSON contains both server-side records (e.g.
    # `snapmulti-server.service`, server compose stack) and client-side
    # ones (e.g. `snapclient.service`, fb-display container).
    if [[ "$CLIENT_ONLY" != "true" ]]; then
        [[ "$c" == "$SERVER" || "$c" == "$SERVER_REPORTED" ]] && continue
    fi
    HOSTS+=("$c")
    ROLES+=("client")
done

if (( ${#HOSTS[@]} == 0 )); then
    echo "ERROR: no hosts to smoke." >&2
    exit 2
fi

# ── Per-host probe ────────────────────────────────────────────────
# Each host writes its own JSON line to a tmp file (parallel-safe).
# probe_host() is defined ~370 lines above this point so the regression
# test in tests/test_fleet_smoke_ssh_classification.sh can source the
# script and drive a real failure path with a stubbed ssh. TMP / TIMEOUT_CMD
# / SSH_OPTS / SSH_USER are referenced inside the function body — bash
# resolves them at call time, so the forward reference is safe.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Probing ${#HOSTS[@]} host(s) in parallel..." >&2
declare -a PIDS=()
for i in "${!HOSTS[@]}"; do
    # Background subshells inherit the parent's EXIT trap in bash. If a
    # worker runs that trap, it deletes $TMP while sibling probes are
    # still writing their JSON files. Disarm cleanup in workers; the
    # parent trap below owns tmpdir removal.
    (
        trap - EXIT
        probe_host "${HOSTS[$i]}" "${ROLES[$i]}"
    ) &
    PIDS+=($!)
done
for pid in "${PIDS[@]}"; do
    wait "$pid" || true
done

# ── Collect ──────────────────────────────────────────────────────
ALL=$(jq -s '.' "$TMP"/*.json)

# ── Compute overall pass/fail (shared by text + JSON output) ─────
# A host counts as a failure if it's unreachable OR if smoke recorded at
# least one fail. Calculated up-front so --json consumers get a proper
# exit code (was 0 unconditionally before).
overall_fail=$(jq '
    [.[] | select(.reachable==false or (((.non_snapmulti // false) | not) and ([.smoke.records[]? | select(.status=="fail")] | length > 0)))]
    | length > 0 | if . then 1 else 0 end' <<<"$ALL")

# ── Render ───────────────────────────────────────────────────────
if [[ "$OUTPUT" == "json" ]]; then
    jq --arg server "$SERVER" \
       --argjson connected_non_snapmulti "$CONNECTED_NON_SNAPMULTI_JSON" \
       --argjson disconnected "$DISCONNECTED_CLIENTS_JSON" \
       '{server:$server, generated_at: (now | todate), connected_non_snapmulti_clients:$connected_non_snapmulti, disconnected_clients:$disconnected, hosts:.}' <<<"$ALL"
    exit "$overall_fail"
else
    # Baseline is the release identity (bare tag) of the SERVER host. Build
    # id (post-tag commit suffix) is irrelevant for fleet coherence: a
    # client flashed from main HEAD 7 commits past v0.8.1 still runs v0.8.1
    # because release-manifest.json + .env carry the release line, not the
    # commit hash. Fall back to .versions if .release is empty (older
    # snapMULTI versions did not bake SNAPMULTI_RELEASE in .env).
    baseline_version=$(jq -r --arg server "$SERVER" '
        [.[] | select(.host == $server and .reachable == true and ((.non_snapmulti // false) | not))
         | (.release.server // "") as $rsrv
         | (.release.client // "") as $rcli
         | (.versions.server // "") as $vsrv
         | (.versions.client // "") as $vcli
         | if   $rsrv != "" then $rsrv
           elif $rcli != "" then $rcli
           elif $vsrv != "" then $vsrv
           elif $vcli != "" then $vcli
           else empty end][0] // ""
    ' <<<"$ALL")

    printf '\nFleet smoke against %s — %s\n\n' "$SERVER" "$(date -u +%FT%TZ)"
    connected_non_snapmulti_count=$(jq 'length' <<<"$CONNECTED_NON_SNAPMULTI_JSON")
    if (( connected_non_snapmulti_count > 0 )); then
        connected_non_snapmulti_list=$(jq -r '
            [.[] |
             if (.ip != "" and .ip != .name) then "\(.name)(\(.ip), \(.os))" else "\(.name)(\(.os))" end]
            | join(", ")
        ' <<<"$CONNECTED_NON_SNAPMULTI_JSON")
        printf 'Connected non-snapMULTI clients: %s\n\n' "$connected_non_snapmulti_list"
    fi
    disconnected_count=$(jq 'length' <<<"$DISCONNECTED_CLIENTS_JSON")
    if (( disconnected_count > 0 )); then
        disconnected_list=$(jq -r '
            [.[] |
             if (.ip != "" and .ip != .name) then "\(.name)(\(.ip))" else .name end]
            | join(", ")
        ' <<<"$DISCONNECTED_CLIENTS_JSON")
        printf 'Disconnected paired clients: %s\n\n' "$disconnected_list"
    fi
    printf '%-20s %-7s %-15s %-7s %-6s %-30s\n' "HOST" "ROLE" "VERSION" "SMOKE" "FAILS" "NOTES"
    printf '%-20s %-7s %-15s %-7s %-6s %-30s\n' \
        "--------------------" "-------" "---------------" "-------" "------" "------------------------------"
    while IFS= read -r rec; do
        host=$(jq -r '.host' <<<"$rec")
        role=$(jq -r '.role' <<<"$rec")
        reachable=$(jq -r '.reachable' <<<"$rec")
        if [[ "$reachable" != "true" ]]; then
            err=$(jq -r '.error // .parse_error // "?"' <<<"$rec")
            note=$(jq -r '.note // ""' <<<"$rec")
            # Combine error + actionable note. NOTES column dropped its
            # %-30s truncation because suggestions like
            # `run: ssh-keygen -R hostname && ssh-keygen -R 192.168.1.4`
            # do not fit and the operator needs the full command verbatim.
            if [[ -n "$note" ]]; then
                printf '%-20s %-7s %-15s %-7s %-6s %s — %s\n' \
                    "$host" "$role" "—" "UNREACH" "—" "$err" "$note"
            else
                printf '%-20s %-7s %-15s %-7s %-6s %s\n' \
                    "$host" "$role" "—" "UNREACH" "—" "$err"
            fi
            continue
        fi
        non_snapmulti=$(jq -r '.non_snapmulti // false' <<<"$rec")
        if [[ "$non_snapmulti" == "true" ]]; then
            printf '%-20s %-7s %-15s %-7s %-6s %-30s\n' \
                "$host" "$role" "non-snapMULTI" "SKIP" "—" "not a snapMULTI host"
            continue
        fi
        # Display the release identity (bare tag), with build id as fallback
        # when the device is older than the SNAPMULTI_RELEASE-in-.env bake.
        rsrv=$(jq -r '.release.server // ""' <<<"$rec")
        rcli=$(jq -r '.release.client // ""' <<<"$rec")
        srv=$(jq -r '.versions.server // ""' <<<"$rec")
        cli=$(jq -r '.versions.client // ""' <<<"$rec")
        # Prefer the role-canonical source but fall back to the
        # other one — a `--both` device populates both, and on legacy
        # installs only one path may exist. If neither release nor build
        # is present this is almost certainly NOT a snapMULTI host (e.g.
        # a peer macOS / Sonos / Echo wandered in via the Snapcast client
        # list); mark it as "—".
        if [[ "$role" == "server" ]]; then
            ver="${rsrv:-${rcli:-${srv:-${cli:-}}}}"
        else
            ver="${rcli:-${rsrv:-${cli:-${srv:-}}}}"
        fi
        if [[ -z "$ver" ]]; then
            ver="non-snapMULTI"
        fi
        fails=$(jq -r '[.smoke.records[]? | select(.status=="fail")] | length' <<<"$rec" 2>/dev/null || echo "?")
        warns=$(jq -r '[.smoke.records[]? | select(.status=="warn")] | length' <<<"$rec" 2>/dev/null || echo "?")
        version_drift=false
        if [[ -n "$baseline_version" && "$ver" != "non-snapMULTI" && "$ver" != "$baseline_version" ]]; then
            version_drift=true
        fi
        if [[ "$fails" == "0" ]]; then
            if [[ "$warns" != "0" && "$warns" != "?" ]] || [[ "$version_drift" == "true" ]]; then
                status="WARN"
            else
                status="PASS"
            fi
        else
            status="FAIL"
        fi
        notes=""
        if [[ "$fails" != "0" ]]; then
            notes=$(jq -r '[.smoke.records[]? | select(.status=="fail") | .msg] | join("; ")' <<<"$rec" \
                    | cut -c-30)
        elif [[ "$version_drift" == "true" ]]; then
            notes="version drift vs ${baseline_version}"
        elif [[ "$warns" != "0" && "$warns" != "?" ]]; then
            notes="${warns} warning(s)"
        fi
        printf '%-20s %-7s %-15s %-7s %-6s %-30s\n' \
            "$host" "$role" "$ver" "$status" "$fails" "$notes"
    done < <(jq -c '.[]' <<<"$ALL")
    echo
    reachable_snapmulti_count=$(jq '[.[] | select(.reachable==true and ((.non_snapmulti // false) | not))] | length' <<<"$ALL")
    pass_count=$(jq '[.[] | select(.reachable==true and ((.non_snapmulti // false) | not)) | select([.smoke.records[]? | select(.status=="fail")] | length == 0)] | length' <<<"$ALL")
    skipped_count=$(jq '[.[] | select(.reachable==true and (.non_snapmulti // false))] | length' <<<"$ALL")
    rpc_skipped_count=$(jq 'length' <<<"$CONNECTED_NON_SNAPMULTI_JSON")
    skipped_total=$((skipped_count + rpc_skipped_count))
    unreachable_count=$(jq '[.[] | select(.reachable==false)] | length' <<<"$ALL")
    if (( overall_fail == 0 )); then
        echo "Overall: PASS — ${pass_count}/${reachable_snapmulti_count} reachable snapMULTI hosts green, ${skipped_total} non-snapMULTI skipped, ${unreachable_count} unreachable."
        exit 0
    else
        echo "Overall: FAIL — ${pass_count}/${reachable_snapmulti_count} reachable snapMULTI hosts green, ${skipped_total} non-snapMULTI skipped, ${unreachable_count} unreachable."
        exit 1
    fi
fi
