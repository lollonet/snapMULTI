#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_SNAPCAST="$SCRIPT_DIR/../scripts/smoke/check_snapcast.sh"
CHECK_CONTAINERS="$SCRIPT_DIR/../scripts/smoke/check_containers.sh"

pass=0
fail=0

assert_contains() {
    local haystack="$1" needle="$2" desc="$3"
    if grep -qF -- "$needle" <<<"$haystack"; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc (missing '$needle')"
        fail=$((fail + 1))
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" desc="$3"
    if grep -qF -- "$needle" <<<"$haystack"; then
        echo "  FAIL: $desc (found '$needle')"
        fail=$((fail + 1))
    else
        echo "  PASS: $desc"
        pass=$((pass + 1))
    fi
}

assert_rc() {
    local actual="$1" expected="$2" desc="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc (got $actual, expected $expected)"
        fail=$((fail + 1))
    fi
}

if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq not installed"
    exit 0
fi

MOCK_BIN="$(mktemp -d)"
trap 'rm -rf "$MOCK_BIN"' EXIT

cat > "$MOCK_BIN/curl" <<'MOCK'
#!/usr/bin/env bash
cat <<'JSON'
{
  "result": {
    "server": {
      "groups": [
        {
          "clients": [
            {"connected": true, "host": {"name": "pi-server", "ip": "127.0.0.1"}},
            {"connected": true, "host": {"name": "pi-zero", "ip": "192.0.2.95"}},
            {"connected": false, "host": {"name": "pi3-1gb", "ip": "192.0.2.89"}}
          ]
        }
      ]
    }
  }
}
JSON
MOCK
chmod +x "$MOCK_BIN/curl"

cat > "$MOCK_BIN/docker" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "ps" ]]; then
    printf 'mympd\n'
    exit 0
fi
if [[ "$1" == "inspect" ]]; then
    fmt=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --format) fmt="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    case "$fmt" in
        *RestartCount*) echo 1 ;;
        *State.Status*) echo running ;;
        *State.Health*) echo "${MOCK_HEALTH:-healthy}" ;;
        *HostConfig.Memory*) echo 134217728 ;;
        *State.StartedAt*) echo "2026-05-15T12:00:00Z" ;;
        *) echo "" ;;
    esac
    exit 0
fi
exit 0
MOCK
chmod +x "$MOCK_BIN/docker"

cat > "$MOCK_BIN/sudo" <<'MOCK'
#!/usr/bin/env bash
[[ "${1:-}" == "-n" ]] && shift
if [[ "${1:-}" == "true" ]]; then
    exit 0
fi
exec "$@"
MOCK
chmod +x "$MOCK_BIN/sudo"

# numfmt stub — macOS dev hosts without coreutils don't have numfmt in PATH.
# Implements just the `--to=iec --format='%.0f' <bytes>` form check_containers
# uses for the limit suffix. 128 MiB → "128M". The check is conservative when
# numfmt is missing, so this stub keeps the assertion stable across hosts.
cat > "$MOCK_BIN/numfmt" <<'MOCK'
#!/usr/bin/env bash
bytes=""
for arg in "$@"; do
    case "$arg" in
        --to=*|--format=*) ;;
        *[0-9]*) bytes="$arg" ;;
    esac
done
[[ -z "$bytes" ]] && exit 0
units=("" K M G T)
i=0
val="$bytes"
while (( val >= 1024 && i < 4 )); do
    val=$(( val / 1024 ))
    i=$(( i + 1 ))
done
printf '%s%s\n' "$val" "${units[$i]}"
MOCK
chmod +x "$MOCK_BIN/numfmt"

echo "Testing smoke runtime classification..."

snapcast_output="$(
    PATH="$MOCK_BIN:$PATH" \
    MODE=both \
    bash -c "section() { printf 'SECTION %s\\n' \"\$*\"; }; pass_check() { printf '[OK] %s\\n' \"\$*\"; }; fail_check() { printf '[ERROR] %s\\n' \"\$*\"; }; warn() { printf '[WARN] %s\\n' \"\$*\"; }; info() { printf '[INFO] %s\\n' \"\$*\"; }; source '$CHECK_SNAPCAST'; check_snapcast"
)"
assert_contains "$snapcast_output" "[OK] Snapcast clients: 2 of 3 connected" "offline Snapcast clients do not prevent pass"
assert_contains "$snapcast_output" "[INFO] Snapcast clients offline: pi3-1gb(192.0.2.89)" "offline Snapcast clients are listed"
assert_not_contains "$snapcast_output" "[WARN] Snapcast clients: 2 of 3 connected" "offline Snapcast clients are not warnings"

set +e
container_output="$(
    PATH="$MOCK_BIN:$PATH" \
    MODE=client \
    bash -c "section() { printf 'SECTION %s\\n' \"\$*\"; }; pass_check() { printf '[OK] %s\\n' \"\$*\"; }; fail_check() { printf '[ERROR] %s\\n' \"\$*\"; }; warn() { printf '[WARN] %s\\n' \"\$*\"; }; info() { printf '[INFO] %s\\n' \"\$*\"; }; is_pi_zero_2w() { return 1; }; source '$CHECK_CONTAINERS'; check_containers"
)"
rc=$?
set -e
assert_rc "$rc" "0" "historical restart on healthy container does not fail"
assert_contains "$container_output" "[OK] No active container restart failures among 1 snapMULTI container(s)" "healthy restart history is classified as OK"
assert_contains "$container_output" "[INFO] Container(s) restarted in the past but stable now: mympd(RC=1)" "historical restart is still reported"
assert_not_contains "$container_output" "crash-loop" "historical restart is not called crash-loop"
# The new HostConfig.Memory passthrough — 128 MiB shown in the health row so
# the /status page can surface it without env propagation. Works the same for
# server and client containers (the same docker inspect, the same suffix).
assert_contains "$container_output" "[OK] mympd: healthy (limit=128M)" "container health row includes runtime mem limit"

unhealthy_output="$(
    PATH="$MOCK_BIN:$PATH" \
    MODE=client \
    MOCK_HEALTH=unhealthy \
    bash -c "section() { printf 'SECTION %s\\n' \"\$*\"; }; pass_check() { printf '[OK] %s\\n' \"\$*\"; }; fail_check() { printf '[ERROR] %s\\n' \"\$*\"; }; warn() { printf '[WARN] %s\\n' \"\$*\"; }; info() { printf '[INFO] %s\\n' \"\$*\"; }; is_pi_zero_2w() { return 1; }; source '$CHECK_CONTAINERS'; check_containers"
)"
assert_contains "$unhealthy_output" "[ERROR] Container(s) with active restart failure: mympd(RC=1,status=running,health=unhealthy)" "unhealthy restarted container remains an active failure"
assert_contains "$unhealthy_output" "[ERROR] mympd: unhealthy — service is failing its healthcheck probe (limit=128M)" "unhealthy row also carries mem limit"

# Pinning the source-level behaviour: the helper that builds mem_suffix must
# guard on numfmt presence (so dev hosts without coreutils don't break) and
# the suffix must be the documented `(limit=…)` shape the renderer parses.
assert_contains "$(cat "$CHECK_CONTAINERS")" 'command -v numfmt' "check_containers gates on numfmt availability"
assert_contains "$(cat "$CHECK_CONTAINERS")" '(limit=$mem_h)' "check_containers emits the documented (limit=…) suffix"

echo ""
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
