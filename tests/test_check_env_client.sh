#!/usr/bin/env bash
# Regression test for scripts/smoke/check_env.sh — it must validate the CLIENT
# .env (/opt/snapclient/.env), not only the server one.
#
# The bug: check_env only looked at /opt/snapmulti/.env, so a pure client (no
# server .env) reported "no .env" and never validated its own config — even
# though setup.sh writes /opt/snapclient/.env with SNAPCLIENT_/VISUALIZER_/
# FBDISPLAY_ limit keys. Verified live on a client (snapdigi).
#
# bash 3.2 compatible.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE="$SCRIPT_DIR/../scripts/smoke/check_env.sh"

pass=0
fail=0
assert_contains() {
    local hay="$1" needle="$2" desc="$3"
    if grep -qF -- "$needle" <<<"$hay"; then echo "  PASS: $desc"; pass=$((pass+1))
    else echo "  FAIL: $desc (missing '$needle')"; fail=$((fail+1)); fi
}
assert_not_contains() {
    local hay="$1" needle="$2" desc="$3"
    if grep -qF -- "$needle" <<<"$hay"; then echo "  FAIL: $desc (found '$needle')"; fail=$((fail+1))
    else echo "  PASS: $desc"; pass=$((pass+1)); fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/client" "$TMP/server"
# Client .env: one well-formed + one MALFORMED limit key (bare int, no unit).
cat > "$TMP/client/.env" <<'ENV'
SNAPCLIENT_MEM_LIMIT=64M
FBDISPLAY_MEM_LIMIT=256
ENV
# Server .env: all well-formed.
cat > "$TMP/server/.env" <<'ENV'
SNAPSERVER_MEM_LIMIT=256M
MPD_CPU_LIMIT=1.0
ENV

run() {  # $1=SERVER_DIR $2=CLIENT_DIR
    SERVER_DIR="$1" CLIENT_DIR="$2" MODE=client bash -c "
        section(){ printf 'SECTION %s\n' \"\$*\"; }
        pass_check(){ printf '[OK] %s\n' \"\$*\"; }
        fail_check(){ printf '[ERROR] %s\n' \"\$*\"; }
        warn(){ printf '[WARN] %s\n' \"\$*\"; }
        info(){ printf '[INFO] %s\n' \"\$*\"; }
        source '$MODULE'
        check_env
    "
}

echo "== client-only: validates /opt/snapclient/.env (the bug) =="
out="$(run '' "$TMP/client")"
assert_contains "$out" "[OK] .env present at $TMP/client/.env" "client .env is found + validated"
assert_contains "$out" "[ERROR] .env has malformed memory limit(s)" "malformed client key is caught"
assert_contains "$out" "FBDISPLAY_MEM_LIMIT=256" "the specific bad key is named"
assert_not_contains "$out" "No .env found" "client-only no longer reports 'no .env'"

echo "== both: validates server AND client .env =="
out="$(run "$TMP/server" "$TMP/client")"
assert_contains "$out" "[OK] .env present at $TMP/server/.env" "server .env validated"
assert_contains "$out" "[OK] .env present at $TMP/client/.env" "client .env validated too"

echo "== neither dir has a .env (native client): INFO, no crash =="
out="$(run "$TMP/nope" "$TMP/alsonope")"
assert_contains "$out" "[INFO] No .env found" "genuinely-absent .env -> INFO"
assert_not_contains "$out" "[ERROR]" "no false failure when there's truly no .env"

echo ""
if [[ "$fail" -gt 0 ]]; then echo "FAILED: $fail failed, $pass passed"; exit 1; fi
echo "All $pass tests passed!"
