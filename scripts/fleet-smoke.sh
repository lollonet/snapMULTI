#!/usr/bin/env bash
# fleet-smoke.sh — discover a snapMULTI fleet from one server, run smoke on all hosts
#
# Walks the Snapcast JSON-RPC API on the server (:1780/jsonrpc) to enumerate
# every connected client, then SSHs in parallel to (server + clients) to:
#   1. read /opt/snapmulti/VERSION and /opt/snapclient/VERSION
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
SSH_OPTS=(-o ConnectTimeout=8 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
          -o ServerAliveInterval=15 -o ServerAliveCountMax=3)
OUTPUT="text"
CLIENT_ONLY=false
TIMEOUT_SMOKE=120

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
        done < <("${stdbuf_cmd[@]}" timeout 4 dns-sd -B _snapcast._tcp local 2>/dev/null || true)

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
            resolve_line=$("${stdbuf_cmd[@]}" timeout 3 dns-sd -L "$inst" _snapcast._tcp local 2>/dev/null \
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
        done < <("${stdbuf_cmd[@]}" timeout 4 avahi-browse -prt _snapcast._tcp 2>/dev/null \
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
    # Skip the server hostname appearing in the client list (a `both`-mode
    # device shows up as both — we keep it as "server" only).
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
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

probe_host() {
    local host="$1"
    local role="$2"
    local out="$TMP/${host//[^a-zA-Z0-9_-]/_}.json"
    # On the device: read VERSION files, run smoke --json. Both best-effort.
    # The smoke wrapper exits 0/1; --no-fail-on-warn keeps us non-fatal on WARN.
    # Script piped via stdin to avoid quoting hell with -c '...'.
    local payload
    if ! payload=$("${TIMEOUT_CMD[@]}" \
            ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" 'bash -s' 2>/dev/null <<'REMOTE'
srv=$(cat /opt/snapmulti/VERSION 2>/dev/null || echo "")
cli=$(cat /opt/snapclient/VERSION 2>/dev/null || echo "")
smoke_script=""
if [ -x /opt/snapmulti/scripts/device-smoke.sh ]; then
    smoke_script=/opt/snapmulti/scripts/device-smoke.sh
elif [ -x /opt/snapclient/scripts/device-smoke.sh ]; then
    smoke_script=/opt/snapclient/scripts/device-smoke.sh
fi
if [ -n "$smoke_script" ]; then
    # device-smoke.sh --json prints a complete JSON document and exits 1
    # when records fail. The previous `|| echo "{}"` appended a second
    # JSON object on failure, producing `{...real...}{}` — jq's input
    # reader stopped at the first document, but the python3 parser
    # below raises JSONDecodeError("Extra data") and silently falls
    # back to {} so the host's failure records would be lost and the
    # fleet would report PASS. Capture stdout regardless of exit code;
    # fall back to {} only when truly empty.
    smoke_json=$(sudo -n "$smoke_script" --json --no-fail-on-warn 2>/dev/null || true)
else
    smoke_json=""
fi
[ -z "$smoke_json" ] && smoke_json="{}"
# Use python3 instead of jq on the device: Pi Zero native installs are
# intentionally lean and may not have jq, while python3 is part of the
# snapMULTI dependency baseline. raw_decode is also a belt-and-suspenders
# against the historic concat bug: it stops at the first valid JSON
# document so any trailing garbage cannot mask real smoke failures.
SMOKE_JSON="$smoke_json" python3 -c '
import json
import os
import sys

srv = sys.argv[1]
cli = sys.argv[2]
raw = os.environ.get("SMOKE_JSON", "").strip()
smoke = {}
if raw:
    try:
        smoke, _ = json.JSONDecoder().raw_decode(raw)
    except json.JSONDecodeError:
        smoke = {}
print(json.dumps({"srv": srv, "cli": cli, "smoke": smoke}, separators=(",", ":")))
' "$srv" "$cli"
REMOTE
    ); then
        # SSH or smoke timed out / failed
        jq -nc --arg h "$host" --arg r "$role" \
            '{host:$h, role:$r, reachable:false, error:"ssh-timeout-or-fail"}' >"$out"
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
    jq --arg h "$host" --arg r "$role" \
        '{host:$h, role:$r, reachable:true,
          versions:{server:.srv, client:.cli},
          non_snapmulti: ((.srv == "" and .cli == "") and ((.smoke.schema_version // null) == null)),
          smoke:.smoke}' <<<"$payload" >"$out"
}

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
    baseline_version=$(jq -r --arg server "$SERVER" '
        [.[] | select(.host == $server and .reachable == true and ((.non_snapmulti // false) | not))
         | (.versions.server // "") as $srv
         | (.versions.client // "") as $cli
         | if $srv != "" then $srv elif $cli != "" then $cli else empty end][0] // ""
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
            printf '%-20s %-7s %-15s %-7s %-6s %-30s\n' \
                "$host" "$role" "—" "UNREACH" "—" "$(jq -r '.error // .parse_error // "?"' <<<"$rec")"
            continue
        fi
        non_snapmulti=$(jq -r '.non_snapmulti // false' <<<"$rec")
        if [[ "$non_snapmulti" == "true" ]]; then
            printf '%-20s %-7s %-15s %-7s %-6s %-30s\n' \
                "$host" "$role" "non-snapMULTI" "SKIP" "—" "not a snapMULTI host"
            continue
        fi
        srv=$(jq -r '.versions.server // ""' <<<"$rec")
        cli=$(jq -r '.versions.client // ""' <<<"$rec")
        # Prefer the role-canonical VERSION file but fall back to the
        # other one — a `--both` device has both, and a stock VERSION
        # may live in only one of the two paths depending on install
        # quirks. If neither exists this is almost certainly NOT a
        # snapMULTI host (e.g. a peer macOS / Sonos / Echo wandered in
        # via the Snapcast client list); mark it as "—".
        if [[ "$role" == "server" ]]; then
            ver="${srv:-${cli:-}}"
        else
            ver="${cli:-${srv:-}}"
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
