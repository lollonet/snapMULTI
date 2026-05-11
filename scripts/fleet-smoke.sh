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
SSH_OPTS=(-o ConnectTimeout=8 -o BatchMode=yes -o StrictHostKeyChecking=accept-new)
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
    local candidates=()
    if command -v dns-sd >/dev/null 2>&1; then
        # macOS: dns-sd doesn't terminate cleanly; tee with timeout
        while IFS= read -r line; do
            local h
            h=$(echo "$line" | awk '{print $7}')
            [[ -n "$h" && "$h" != "Name" ]] && candidates+=("$h")
        done < <(timeout 4 dns-sd -B _snapcast._tcp local 2>/dev/null | awk 'NR>4 {print}' || true)
    elif command -v avahi-browse >/dev/null 2>&1; then
        while IFS= read -r host; do
            [[ -n "$host" ]] && candidates+=("${host%.local}")
        done < <(timeout 4 avahi-browse -prt _snapcast._tcp 2>/dev/null \
                  | awk -F';' '/^=/ {print $7}' | sort -u || true)
    fi

    # Probe each candidate; first one that responds wins.
    local h
    for h in "${candidates[@]}"; do
        if curl -sS --max-time 3 \
              -X POST -H 'Content-Type: application/json' \
              -d '{"jsonrpc":"2.0","id":0,"method":"Server.GetStatus"}' \
              "http://${h}:1780/jsonrpc" >/dev/null 2>&1; then
            echo "$h"
            return 0
        fi
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
SERVER_REPORTED=$(jq -r '.result.server.host.name // ""' <<<"$RPC_OUT")
# `connected: false` clients are kept in the list but skipped from smoke —
# they're known peers that left the LAN, not new evidence.
mapfile -t CLIENTS < <(
    jq -r '.result.server.groups[]?.clients[]?
            | select(.connected == true)
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
    smoke_json=$(sudo -n "$smoke_script" --json --no-fail-on-warn 2>/dev/null || echo "{}")
else
    smoke_json="{}"
fi
[ -z "$smoke_json" ] && smoke_json="{}"
# Use jq -n to safely escape srv/cli/smoke_json — printf would emit broken
# JSON if VERSION contains a double-quote or backslash.
printf '%s' "$smoke_json" | jq -nc --arg srv "$srv" --arg cli "$cli" \
    '{srv:$srv, cli:$cli, smoke:(input // {})}'
REMOTE
    ); then
        # SSH or smoke timed out / failed
        jq -nc --arg h "$host" --arg r "$role" \
            '{host:$h, role:$r, reachable:false, error:"ssh-timeout-or-fail"}' >"$out"
        return
    fi
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
          smoke:.smoke}' <<<"$payload" >"$out"
}

echo "Probing ${#HOSTS[@]} host(s) in parallel..." >&2
declare -a PIDS=()
for i in "${!HOSTS[@]}"; do
    probe_host "${HOSTS[$i]}" "${ROLES[$i]}" &
    PIDS+=($!)
done
for pid in "${PIDS[@]}"; do
    wait "$pid" || true
done

# ── Collect ──────────────────────────────────────────────────────
mapfile -t RECORDS < <(cat "$TMP"/*.json 2>/dev/null)
ALL=$(printf '%s\n' "${RECORDS[@]}" | jq -s '.')

# ── Compute overall pass/fail (shared by text + JSON output) ─────
# A host counts as a failure if it's unreachable OR if smoke recorded at
# least one fail. Calculated up-front so --json consumers get a proper
# exit code (was 0 unconditionally before).
overall_fail=$(jq '
    [.[] | select(.reachable==false or ([.smoke.records[]? | select(.status=="fail")] | length > 0))]
    | length > 0 | if . then 1 else 0 end' <<<"$ALL")

# ── Render ───────────────────────────────────────────────────────
if [[ "$OUTPUT" == "json" ]]; then
    jq --arg server "$SERVER" \
       '{server:$server, generated_at: (now | todate), hosts:.}' <<<"$ALL"
    exit "$overall_fail"
else
    printf '\nFleet smoke against %s — %s\n\n' "$SERVER" "$(date -u +%FT%TZ)"
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
        if [[ "$fails" == "0" ]]; then
            status="PASS"
        else
            status="FAIL"
        fi
        notes=""
        if [[ "$fails" != "0" ]]; then
            notes=$(jq -r '[.smoke.records[]? | select(.status=="fail") | .msg] | join("; ")' <<<"$rec" \
                    | cut -c-30)
        elif [[ "$warns" != "0" && "$warns" != "?" ]]; then
            notes="${warns} warning(s)"
        fi
        printf '%-20s %-7s %-15s %-7s %-6s %-30s\n' \
            "$host" "$role" "$ver" "$status" "$fails" "$notes"
    done < <(jq -c '.[]' <<<"$ALL")
    echo
    if (( overall_fail == 0 )); then
        echo "Overall: PASS — ${#HOSTS[@]}/${#HOSTS[@]} hosts green."
        exit 0
    else
        # Count reachable failures vs unreachable to give a useful summary.
        reachable_count=$(jq '[.[] | select(.reachable==true)] | length' <<<"$ALL")
        pass_count=$(jq '[.[] | select(.reachable==true) | select([.smoke.records[]? | select(.status=="fail")] | length == 0)] | length' <<<"$ALL")
        echo "Overall: FAIL — ${pass_count}/${reachable_count} reachable hosts green, $((${#HOSTS[@]} - reachable_count)) unreachable."
        exit 1
    fi
fi
