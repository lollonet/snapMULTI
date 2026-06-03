#!/usr/bin/env bash
# Unit tests for scripts/common/env-reader.sh's `env_get` helper.
#
# Covers the contract documented at the top of env-reader.sh: input
# validation, missing-file tolerance, value-containing-`=` preservation,
# CRLF handling, surrounding-quote trim, four strip modes, and unknown-
# mode rejection. Bash 3.2 + bash 5 compatible.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/../scripts/common/env-reader.sh"

# shellcheck source=../scripts/common/env-reader.sh
source "$LIB"

pass=0
fail=0

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

assert_rc() {
    local rc="$1" want="$2" desc="$3"
    if [[ "$rc" == "$want" ]]; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc (rc=$rc, want=$want)"
        fail=$((fail + 1))
    fi
}

# Build a sandbox .env fixture with the shapes the migration covers.
SANDBOX=$(mktemp -d -t env-reader-XXXXXX)
trap 'rm -rf "$SANDBOX"' EXIT

ENV_FILE="$SANDBOX/.env"
cat > "$ENV_FILE" <<'ENV'
# Comment line — must NOT match any key.
SIMPLE=hello
QUOTED="quoted"
TRAILING_SPACES=value
SNAPSERVER_RPC_PORT=1705
MUSIC_SOURCE="nfs"
MUSIC_PATH=/media/music

# Values containing `=` — the f2- vs f2 trap.
BASE64_TOKEN=abc=def==
PASSWORD_WITH_EQUALS=p@ss=word

# Duplicate key — first occurrence wins (matches `bash -a; source` shape).
DUP=first
DUP=second

# Empty value.
EMPTY=

# Numeric value used in opt-out paths.
SNAPMULTI_BOOT_SMOKE_TONES=off
ENV

# Trailing-whitespace fixtures — use raw printf so the spaces/tabs land
# verbatim. SPACED_VALUE has trailing spaces; TABBED_VALUE has a trailing
# tab + spaces. SIMPLE_NO_TRAIL is a clean copy for the all-mode identity
# test.
printf 'SPACED_VALUE=hello   \n' >> "$ENV_FILE"
printf 'TABBED_VALUE=hello\t  \n' >> "$ENV_FILE"
# CRLF line for the cr/trim tests.
printf 'CRLF_VALUE=carriage\r\n' >> "$ENV_FILE"

echo "=== Input validation ==="

_rc=0
env_get "" "$ENV_FILE" >/dev/null 2>&1 || _rc=$?
assert_rc "$_rc" 1 "empty key → rc 1"

_rc=0
env_get "lower_first" "$ENV_FILE" >/dev/null 2>&1 || _rc=$?
# Identifier must start with letter or underscore — `lower_first` is OK
# (starts with `l`). Use `1starts_with_digit` for the negative case.
assert_rc "$_rc" 0 "lowercase letters allowed (valid identifier)"

_rc=0
env_get "1starts_with_digit" "$ENV_FILE" >/dev/null 2>&1 || _rc=$?
assert_rc "$_rc" 1 "key starting with digit → rc 1"

_rc=0
env_get "has-dash" "$ENV_FILE" >/dev/null 2>&1 || _rc=$?
assert_rc "$_rc" 1 "key with dash → rc 1 (regex injection guard)"

_rc=0
env_get "has.dot" "$ENV_FILE" >/dev/null 2>&1 || _rc=$?
assert_rc "$_rc" 1 "key with dot → rc 1"

_rc=0
env_get "has space" "$ENV_FILE" >/dev/null 2>&1 || _rc=$?
assert_rc "$_rc" 1 "key with space → rc 1"

echo
echo "=== Missing file / key ==="

assert_eq "$(env_get SIMPLE /nonexistent/path/.env)" "" \
    "missing file → empty value, rc 0"
assert_eq "$(env_get NOT_PRESENT "$ENV_FILE")" "" \
    "missing key → empty value, rc 0"

# rc for both must be 0 — callers test the returned string, not the rc.
_rc=0
env_get SIMPLE /nonexistent/path/.env >/dev/null || _rc=$?
assert_rc "$_rc" 0 "missing file → rc 0 (non-fatal)"
_rc=0
env_get NOT_PRESENT "$ENV_FILE" >/dev/null || _rc=$?
assert_rc "$_rc" 0 "missing key → rc 0 (non-fatal)"

echo
echo "=== Value containing '=' (the f2- vs f2 trap) ==="

assert_eq "$(env_get BASE64_TOKEN "$ENV_FILE" none)" "abc=def==" \
    "base64 value with trailing == preserved"
assert_eq "$(env_get PASSWORD_WITH_EQUALS "$ENV_FILE" none)" "p@ss=word" \
    "password value with internal = preserved"

echo
echo "=== Duplicate key — first wins ==="

assert_eq "$(env_get DUP "$ENV_FILE" none)" "first" \
    "grep -m1 picks first occurrence (de-facto value)"

echo
echo "=== Strip modes ==="

# none — preserves quotes + whitespace as the file declares them.
assert_eq "$(env_get QUOTED "$ENV_FILE" none)" '"quoted"' \
    "strip=none preserves surrounding double quotes"
assert_eq "$(env_get SPACED_VALUE "$ENV_FILE" none)" "hello   " \
    "strip=none preserves trailing whitespace"

# cr — strips only trailing \r (CRLF-saved .env files).
crlf_cr=$(env_get CRLF_VALUE "$ENV_FILE" cr)
assert_eq "$crlf_cr" "carriage" "strip=cr removes trailing CR"
# But cr preserves whitespace AND quotes.
assert_eq "$(env_get QUOTED "$ENV_FILE" cr)" '"quoted"' \
    "strip=cr preserves quotes"
assert_eq "$(env_get SPACED_VALUE "$ENV_FILE" cr)" "hello   " \
    "strip=cr preserves trailing whitespace"

# trim — strips surrounding quotes + trailing CR/space. The default mode.
assert_eq "$(env_get QUOTED "$ENV_FILE" trim)" "quoted" \
    "strip=trim removes surrounding double quotes"
assert_eq "$(env_get SPACED_VALUE "$ENV_FILE" trim)" "hello" \
    "strip=trim removes trailing whitespace"
assert_eq "$(env_get MUSIC_SOURCE "$ENV_FILE" trim)" "nfs" \
    "strip=trim removes surrounding quotes (check_mounts pattern)"
assert_eq "$(env_get MUSIC_PATH "$ENV_FILE" trim)" "/media/music" \
    "strip=trim leaves unquoted value untouched"
assert_eq "$(env_get CRLF_VALUE "$ENV_FILE" trim)" "carriage" \
    "strip=trim removes trailing CR"
# Default mode is trim.
assert_eq "$(env_get QUOTED "$ENV_FILE")" "quoted" \
    "default strip mode is trim"

# all — strips every whitespace + CR (legacy aggressive behaviour).
assert_eq "$(env_get SPACED_VALUE "$ENV_FILE" all)" "hello" \
    "strip=all removes all trailing whitespace"
assert_eq "$(env_get TABBED_VALUE "$ENV_FILE" all)" "hello" \
    "strip=all removes trailing tabs"
assert_eq "$(env_get CRLF_VALUE "$ENV_FILE" all)" "carriage" \
    "strip=all removes trailing CR"
assert_eq "$(env_get SNAPMULTI_BOOT_SMOKE_TONES "$ENV_FILE" all)" "off" \
    "strip=all on clean value is identity"

echo
echo "=== Empty value ==="

# `EMPTY=` row → empty value (the assignment exists, the value is empty).
# All strip modes return empty.
assert_eq "$(env_get EMPTY "$ENV_FILE" none)" "" \
    "EMPTY= → empty value (strip=none)"
assert_eq "$(env_get EMPTY "$ENV_FILE" trim)" "" \
    "EMPTY= → empty value (strip=trim)"
assert_eq "$(env_get EMPTY "$ENV_FILE" all)" "" \
    "EMPTY= → empty value (strip=all)"

echo
echo "=== Unknown strip mode ==="

_rc=0
env_get SIMPLE "$ENV_FILE" unknown_mode >/dev/null 2>&1 || _rc=$?
assert_rc "$_rc" 1 "unknown strip mode → rc 1"

# Empty strip mode = "" gets normalised to the documented default `trim`
# by `${3:-trim}` parameter expansion (`:-` treats empty as "use default").
# This is the documented behaviour — passing an empty 3rd arg is the same
# as omitting it. Anything ELSE non-empty + unknown still fails closed.
_rc=0
env_get SIMPLE "$ENV_FILE" "" >/dev/null 2>&1 || _rc=$?
assert_rc "$_rc" 0 "empty strip mode → rc 0 (normalised to default 'trim')"

echo
echo "=== Migration pinning ==="
# Pin that the five low-risk consumers actually wire env_get into their
# main read path (with a guarded `if declare -F env_get` fallback for
# stripped bundles). A future refactor that drops the helper call would
# silently revert to the legacy inline `grep | cut | tr | sed` chain and
# the SSOT extraction would be undone — surface that here at CI time.

PLAY="$SCRIPT_DIR/../scripts/common/play-smoke-tone.sh"
CHECK_SYSTEM="$SCRIPT_DIR/../scripts/smoke/check_system.sh"
CHECK_MOUNTS="$SCRIPT_DIR/../scripts/smoke/check_mounts.sh"
CHECK_QOS="$SCRIPT_DIR/../scripts/smoke/check_qos.sh"
DIAG="$SCRIPT_DIR/../scripts/diagnostic.sh"

assert_grep() {
    local file="$1" pattern="$2" desc="$3"
    if grep -qE "$pattern" "$file"; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc (pattern not found in ${file##*/})"
        fail=$((fail + 1))
    fi
}

# play-smoke-tone.sh — SNAPMULTI_BOOT_SMOKE_TONES opt-out, strip=all.
assert_grep "$PLAY" "env_get SNAPMULTI_BOOT_SMOKE_TONES" \
    "play-smoke-tone.sh wires env_get for SNAPMULTI_BOOT_SMOKE_TONES"
assert_grep "$PLAY" "env_get .* all" \
    "play-smoke-tone.sh uses strip=all (preserves legacy aggressive trim)"

# check_system.sh — release identity, strip=none.
assert_grep "$CHECK_SYSTEM" "env_get SNAPMULTI_RELEASE" \
    "check_system.sh wires env_get for SNAPMULTI_RELEASE"
assert_grep "$CHECK_SYSTEM" "env_get SNAPMULTI_IMAGE_SET" \
    "check_system.sh wires env_get for SNAPMULTI_IMAGE_SET"
assert_grep "$CHECK_SYSTEM" "env_get .* none" \
    "check_system.sh uses strip=none for raw identifiers"

# check_mounts.sh — MUSIC_SOURCE + MUSIC_PATH, strip=trim.
assert_grep "$CHECK_MOUNTS" "env_get MUSIC_SOURCE" \
    "check_mounts.sh wires env_get for MUSIC_SOURCE"
assert_grep "$CHECK_MOUNTS" "env_get MUSIC_PATH" \
    "check_mounts.sh wires env_get for MUSIC_PATH"
assert_grep "$CHECK_MOUNTS" "env_get .* trim" \
    "check_mounts.sh uses strip=trim for quoted values"

# check_qos.sh — SNAPSERVER_RPC_PORT, strip=trim.
assert_grep "$CHECK_QOS" "env_get SNAPSERVER_RPC_PORT" \
    "check_qos.sh wires env_get for SNAPSERVER_RPC_PORT"

# diagnostic.sh — release identity, strip=none.
assert_grep "$DIAG" "env_get SNAPMULTI_RELEASE" \
    "diagnostic.sh wires env_get for SNAPMULTI_RELEASE"
assert_grep "$DIAG" "env_get SNAPMULTI_IMAGE_SET" \
    "diagnostic.sh wires env_get for SNAPMULTI_IMAGE_SET"

# All five must guard the call so stripped/legacy bundles still work.
for f in "$PLAY" "$CHECK_SYSTEM" "$CHECK_MOUNTS" "$CHECK_QOS" "$DIAG"; do
    if grep -qE "declare -F env_get" "$f"; then
        echo "  PASS: ${f##*/} guards env_get call with declare -F fallback"
        pass=$((pass + 1))
    else
        echo "  FAIL: ${f##*/} missing declare -F env_get guard"
        fail=$((fail + 1))
    fi
done

echo
echo "Results: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
