#!/usr/bin/env bash
# Unit + integration tests for scripts/smoke/check_audio_liveness.sh
#
# Two layers:
#   1. Pure classifiers (_al_classify_flap / _al_classify_decoder) — driven
#      directly with every state combination. No I/O, no mocks.
#   2. check_audio_liveness orchestration — the I/O seams (_al_* helpers)
#      are overridden after sourcing to inject each scenario, and the
#      pass_check/fail_check/info shims capture the emitted verdicts.
#
# bash 3.2 compatible (runs on macOS /bin/bash during the dev loop): no
# mapfile, no declare -n, no ${var,,}.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE="$SCRIPT_DIR/../scripts/smoke/check_audio_liveness.sh"
DEVICE_SMOKE="$SCRIPT_DIR/../scripts/device-smoke.sh"

pass=0
fail=0

assert_eq() {
    local actual="$1" expected="$2" desc="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc (got '$actual', expected '$expected')"
        fail=$((fail + 1))
    fi
}

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

# ── Layer 1: pure classifiers ────────────────────────────────────────
# Source the module in a subshell-safe way: it only defines functions +
# sets _AL_* constants at top level, so sourcing runs no I/O.
# shellcheck source=/dev/null
source "$MODULE"

echo "== _al_classify_flap =="
assert_eq "$(_al_classify_flap 0 3600)"  "ok"        "0 reconnects, up 1h -> ok"
assert_eq "$(_al_classify_flap 1 3600)"  "transient" "1 reconnect, up 1h -> transient"
assert_eq "$(_al_classify_flap 2 3600)"  "transient" "2 reconnects, up 1h -> transient"
assert_eq "$(_al_classify_flap 3 3600)"  "flap"      "3 reconnects, up 1h -> flap"
assert_eq "$(_al_classify_flap 12 3600)" "flap"      "12 reconnects, up 1h -> flap"
assert_eq "$(_al_classify_flap 9 30)"    "boot"      "boot window suppresses flap regardless of count"
assert_eq "$(_al_classify_flap 0 30)"    "boot"      "boot window before grace even at 0 reconnects"

echo "== _al_classify_decoder =="
assert_eq "$(_al_classify_decoder playing 1 1 3600)" "playing_ok"   "playing + pcm running + connected -> playing_ok"
assert_eq "$(_al_classify_decoder playing 0 1 3600)" "silent"       "playing + pcm closed + connected -> silent"
assert_eq "$(_al_classify_decoder idle 0 1 3600)"    "idle"         "idle + pcm closed -> idle (expected)"
assert_eq "$(_al_classify_decoder idle 1 1 3600)"    "idle"         "idle stream never fails even if pcm running"
assert_eq "$(_al_classify_decoder playing 0 0 3600)" "disconnected" "disconnected short-circuits before silent"
assert_eq "$(_al_classify_decoder playing 0 1 30)"   "boot"         "boot window suppresses silent verdict"
assert_eq "$(_al_classify_decoder unknown 0 1 3600)" "unknown"      "unknown stream state -> unknown"

# ── Layer 2: orchestration via seam overrides ────────────────────────
# Run check_audio_liveness in a child bash with helper shims + seam
# overrides, capturing its emitted lines.
run_check() {
    # $1 = extra shell setup (seam overrides + env), executed after source.
    local setup="$1"
    MODE="${MODE_OVERRIDE:-client}" \
    bash -c "
        section()    { printf 'SECTION %s\\n' \"\$*\"; }
        pass_check() { printf '[OK] %s\\n' \"\$*\"; }
        fail_check() { printf '[ERROR] %s\\n' \"\$*\"; }
        warn()       { printf '[WARN] %s\\n' \"\$*\"; }
        info()       { printf '[INFO] %s\\n' \"\$*\"; }
        source '$MODULE'
        $setup
        check_audio_liveness
    "
}

echo "== orchestration: reconnect flap =="
flap_out="$(run_check '
    _al_uptime_s()        { printf 3600; }
    _al_snapclient_logs() { printf "Reconnecting\nReconnecting\nReconnecting\nReconnecting\n"; }
    _al_client_identity() { printf ""; }  # stop after flap leg
')"
assert_contains "$flap_out" "[ERROR] snapclient flapping: 4 reconnects" "4 reconnects in window -> flap FAIL"

stable_out="$(run_check '
    _al_uptime_s()        { printf 3600; }
    _al_snapclient_logs() { printf "PcmDecoder init\nsome steady line\n"; }
    _al_client_identity() { printf ""; }
')"
assert_contains "$stable_out" "[OK] snapclient link stable: no reconnects" "no reconnects -> stable OK"

boot_out="$(run_check '
    _al_uptime_s()        { printf 30; }
    _al_snapclient_logs() { printf "Reconnecting\nReconnecting\nReconnecting\n"; }
    _al_client_identity() { printf ""; }
')"
assert_contains "$boot_out" "[INFO] snapclient reconnect check deferred" "boot window demotes flap to INFO"
assert_not_contains "$boot_out" "[ERROR]" "no FAIL during boot window"

# LOW-1 regression guard: an unreadable log source (docker present but
# inaccessible, journalctl denied) must skip with INFO, NOT read zero
# reconnects off the error text and declare the link stable.
unavailable_out="$(run_check '
    _al_uptime_s()        { printf 3600; }
    _al_snapclient_logs() { return 1; }  # source unavailable
    _al_client_identity() { printf ""; }
')"
assert_contains "$unavailable_out" "[INFO] snapclient reconnect check skipped (log source unavailable" "unreadable log source skips with INFO"
assert_not_contains "$unavailable_out" "[OK] snapclient link stable" "unreadable log source is NOT a false 'link stable' pass"

echo "== orchestration: decoder silent (#422) =="
silent_out="$(run_check '
    _al_uptime_s()          { printf 3600; }
    _al_snapclient_logs()   { printf ""; }
    _al_client_identity()   { printf "snapclient-snapdigi|192.0.2.4"; }
    _al_server_status_json(){ printf "{\"x\":1}"; }
    _al_client_stream_state(){ printf "1 playing"; }
    _al_pcm_running()       { return 1; }  # ALSA not RUNNING, both samples
    sleep()                 { :; }         # skip the settle delay in tests
')"
assert_contains "$silent_out" "[ERROR] decoder silent:" "playing + connected + no PCM RUNNING -> silent FAIL"

live_out="$(run_check '
    _al_uptime_s()          { printf 3600; }
    _al_snapclient_logs()   { printf ""; }
    _al_client_identity()   { printf "snapclient-snapdigi|192.0.2.4"; }
    _al_server_status_json(){ printf "{\"x\":1}"; }
    _al_client_stream_state(){ printf "1 playing"; }
    _al_pcm_running()       { return 0; }  # RUNNING
')"
assert_contains "$live_out" "[OK] decoder live:" "playing + PCM RUNNING -> live OK"

idle_out="$(run_check '
    _al_uptime_s()          { printf 3600; }
    _al_snapclient_logs()   { printf ""; }
    _al_client_identity()   { printf "snapclient-snapdigi|192.0.2.4"; }
    _al_server_status_json(){ printf "{\"x\":1}"; }
    _al_client_stream_state(){ printf "1 idle"; }
    _al_pcm_running()       { return 1; }
')"
assert_contains "$idle_out" "[OK] decoder idle:" "idle stream + closed PCM -> idle OK (not a failure)"
assert_not_contains "$idle_out" "[ERROR]" "idle stream never produces a FAIL"

echo "== orchestration: graceful skips =="
native_out="$(run_check '
    _al_uptime_s()        { printf 3600; }
    _al_snapclient_logs() { printf ""; }
    _al_client_identity() { printf ""; }  # native client, no .env
')"
assert_contains "$native_out" "[INFO] Decoder liveness: skipped (no client .env" "native client skips decoder leg"

norpc_out="$(run_check '
    _al_uptime_s()          { printf 3600; }
    _al_snapclient_logs()   { printf ""; }
    _al_client_identity()   { printf "snapclient-x|192.0.2.4"; }
    _al_server_status_json(){ printf ""; }  # RPC unreachable
')"
assert_contains "$norpc_out" "[INFO] Decoder liveness: skipped (snapserver RPC" "unreachable server RPC skips decoder leg"

echo "== orchestration: server-only mode is N/A =="
server_out="$(MODE_OVERRIDE=server run_check '
    _al_uptime_s()        { printf 3600; }
    _al_snapclient_logs() { printf "Reconnecting\nReconnecting\nReconnecting\n"; }
')"
assert_contains "$server_out" "[INFO] Audio liveness: skipped (no local snapclient" "server-only mode skips the whole check"
assert_not_contains "$server_out" "[ERROR]" "server-only mode never fails audio liveness"

# ── Layer 3: wiring pins ─────────────────────────────────────────────
echo "== wiring into device-smoke.sh =="
ds="$(cat "$DEVICE_SMOKE")"
assert_contains "$ds" "check_audio_liveness.sh" "module is in the device-smoke source list"
assert_contains "$ds" "check_audio_liveness >/dev/null && check_audio_liveness" "module is invoked in device-smoke"

echo ""
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
