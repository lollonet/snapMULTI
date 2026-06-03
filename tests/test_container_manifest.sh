#!/usr/bin/env bash
# Pin the SSOT for the snapMULTI container manifest:
#   scripts/common/container-manifest.txt
#
# Consumers that must stay aligned:
#   - scripts/smoke/check_containers.sh   builds _SNAPMULTI_CONTAINERS
#   - docker/metadata-service/metadata-service.py builds _CONTAINER_ROLE
#
# Before this manifest, the smoke list and the role map were two
# hardcoded lists in two languages that drifted silently. This file
# enforces:
#   1. the manifest itself is well-formed (every row has a role
#      that is either `server` or `client`, no duplicate names)
#   2. the bash loader actually reads the file (not just a fallback)
#      and produces the same set the manifest declares
#   3. the Python loader exposes the same name→role mapping as the
#      manifest declares
#   4. no second hardcoded duplicate of the full list survives in
#      either consumer (the inline fallbacks are intentional and
#      bounded; this check guards against a future "back to two
#      lists" regression)
#
# Bash 3.2 compatible — no namerefs, no associative arrays, no mapfile.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$REPO_ROOT/scripts/common/container-manifest.txt"
SMOKE="$REPO_ROOT/scripts/smoke/check_containers.sh"
META_PY="$REPO_ROOT/docker/metadata-service/metadata-service.py"

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

# ── (1) Manifest itself ─────────────────────────────────────────
echo "== manifest well-formed =="

assert '[[ -f "$MANIFEST" ]]' "manifest file exists"

# Parse with the same shape both consumers use: split on whitespace,
# skip blanks + `#` comments. Build two parallel arrays (no assoc
# array — bash 3.2).
manifest_names=()
manifest_roles=()
while read -r _n _r _rest; do
    [[ -z "$_n" || "$_n" == \#* ]] && continue
    [[ -n "$_r" ]] || continue
    manifest_names+=("$_n")
    manifest_roles+=("$_r")
done < "$MANIFEST"

if (( ${#manifest_names[@]} >= 8 )); then
    echo "  PASS: manifest non-empty (${#manifest_names[@]} entries)"
    pass=$((pass + 1))
else
    echo "  FAIL: manifest suspiciously small (${#manifest_names[@]} entries)"
    fail=$((fail + 1))
fi

# Every role must be `server` or `client`.
bad_role_count=0
for r in "${manifest_roles[@]}"; do
    [[ "$r" == "server" || "$r" == "client" ]] || bad_role_count=$((bad_role_count + 1))
done
assert_eq "$bad_role_count" "0" "every manifest row has role server|client"

# No duplicate names — the grouping logic in metadata-service.py uses
# the name as a dict key and would silently keep only the last role
# if the same name appeared twice with different roles.
dup_count=0
for i in "${!manifest_names[@]}"; do
    for ((j = i + 1; j < ${#manifest_names[@]}; j++)); do
        [[ "${manifest_names[$i]}" == "${manifest_names[$j]}" ]] && dup_count=$((dup_count + 1))
    done
done
assert_eq "$dup_count" "0" "no duplicate container names in manifest"

# ── (2) Bash loader: smoke list matches manifest ────────────────
echo
echo "== bash check_containers.sh loader =="

# Source the smoke module in a controlled environment so the loader
# runs and populates _SNAPMULTI_CONTAINERS. Stubs cover the helpers
# the module expects from device-smoke.sh / device-detect.sh so the
# source does not fail under set -euo pipefail.
loader_test=$(SNAPMULTI_CONTAINER_MANIFEST="$MANIFEST" bash <<EOF
set -euo pipefail
# device-smoke.sh helpers
section() { :; }
pass_check() { :; }
fail_check() { :; }
warn() { :; }
info() { :; }
# device-detect.sh helper (called only if running as Pi Zero 2W — we
# never invoke the function body, only need it defined so the smoke
# source does not abort).
is_pi_zero_2w() { return 1; }
# shellcheck source=/dev/null
source "$SMOKE"
# Print one container name per line so the parent can compare to the
# manifest's name list.
for c in "\${_SNAPMULTI_CONTAINERS[@]}"; do
    echo "\$c"
done
EOF
)

# Build a sorted set from the manifest and from the loader output and
# compare. Same set = no drift; mismatch = something is hardcoded.
manifest_sorted=$(printf '%s\n' "${manifest_names[@]}" | sort -u)
loader_sorted=$(printf '%s\n' "$loader_test" | sort -u)
assert_eq "$loader_sorted" "$manifest_sorted" \
    "_SNAPMULTI_CONTAINERS (via loader) equals manifest names"

# ── (3) Python loader: role map matches manifest ────────────────
echo
echo "== python metadata-service.py loader =="

# Honour ${PYTHON:-python3} so CI / dev hosts can point at the venv
# interpreter when system python3 is stale. metadata-service.py uses
# PEP-604 union syntax (`str | None`, `dict | None`) which requires
# Python ≥ 3.10. macOS stock python3 on older releases is 3.9 — skip
# the Python subtest there instead of failing the whole shell test;
# pytest tests/test_metadata_service.py is the real Python gate.
PYTHON="${PYTHON:-python3}"
if command -v "$PYTHON" >/dev/null 2>&1; then
    py_version=$("$PYTHON" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "0.0")
    py_major=${py_version%%.*}
    py_minor=${py_version##*.}
    if [[ "$py_major" -lt 3 || ( "$py_major" -eq 3 && "$py_minor" -lt 10 ) ]]; then
        echo "  SKIP: $PYTHON is $py_version (<3.10) — pytest is the real Python gate"
        py_dump=""
    else
    py_dump=$(SNAPMULTI_CONTAINER_MANIFEST="$MANIFEST" "$PYTHON" - <<EOF
import importlib.util
import json
import sys
import types

# Stub aiohttp + websockets the way tests/test_metadata_service.py does —
# the production import line at module load only needs these symbols to
# exist, not to function.
aiohttp = types.ModuleType("aiohttp")
aiohttp.web = types.SimpleNamespace(
    Request=type("Request", (), {}),
    StreamResponse=type("StreamResponse", (), {}),
    Response=type("Response", (), {"__init__": lambda *a, **k: None}),
    FileResponse=type("FileResponse", (), {"__init__": lambda *a, **k: None}),
    json_response=lambda *a, **k: None,
    Application=type("Application", (), {"__init__": lambda *a, **k: None}),
    AppRunner=type("AppRunner", (), {"__init__": lambda *a, **k: None}),
    TCPSite=type("TCPSite", (), {"__init__": lambda *a, **k: None}),
)
aiohttp.ClientTimeout = lambda *a, **k: None
sys.modules["aiohttp"] = aiohttp

ws = types.ModuleType("websockets")
ws.exceptions = types.SimpleNamespace(ConnectionClosed=Exception)
ws.serve = lambda *a, **k: None
sys.modules["websockets"] = ws

spec = importlib.util.spec_from_file_location("ms", "$META_PY")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print(json.dumps(m._CONTAINER_ROLE, sort_keys=True))
EOF
)
    fi
    if [[ -n "$py_dump" ]]; then
        # Build the expected JSON shape from the manifest and compare.
        manifest_json=$("$PYTHON" -c "
import json, sys
names = '''$(printf '%s\n' "${manifest_names[@]}")'''.strip().splitlines()
roles = '''$(printf '%s\n' "${manifest_roles[@]}")'''.strip().splitlines()
print(json.dumps(dict(zip(names, roles)), sort_keys=True))
")
        assert_eq "$py_dump" "$manifest_json" \
            "metadata-service.py _CONTAINER_ROLE (via loader) equals manifest"
    fi
else
    echo "  SKIP: $PYTHON not available — Python loader check skipped"
fi

# ── (3b) Empty-parse guard (PR #590 review MEDIUM) ──────────────
# A manifest that exists but parses to zero entries (truncated file,
# header-only stub) must fall back to the hardcoded list — silent
# zero-container smoke would defeat every check the smoke is built to
# run. Mirrors the Python loader's `if mapping: return mapping`.
echo
echo "== bash loader empty-parse guard =="

EMPTY_FIXTURE=$(mktemp -t container-empty-manifest-XXXXXX)
trap 'rm -f "$EMPTY_FIXTURE"' EXIT
cat > "$EMPTY_FIXTURE" <<'TXT'
# Manifest exists but parses to zero entries — every meaningful row
# stripped (simulating a truncated SD-card write or header-only stub).
# Loader MUST fall back to the hardcoded list, not silently produce
# zero containers.
TXT

empty_loader_test=$(SNAPMULTI_CONTAINER_MANIFEST="$EMPTY_FIXTURE" bash <<EOF
set -euo pipefail
section() { :; }
pass_check() { :; }
fail_check() { :; }
warn() { :; }
info() { :; }
is_pi_zero_2w() { return 1; }
# shellcheck source=/dev/null
source "$SMOKE"
echo "\${#_SNAPMULTI_CONTAINERS[@]}"
EOF
)
if [[ "$empty_loader_test" =~ ^[0-9]+$ ]] && (( empty_loader_test >= 10 )); then
    echo "  PASS: empty-parse manifest falls back to hardcoded list ($empty_loader_test entries)"
    pass=$((pass + 1))
else
    echo "  FAIL: empty-parse manifest did not fall back (got '$empty_loader_test')"
    fail=$((fail + 1))
fi

# Pin source-level shape — a future "drop the guard" regression surfaces here.
assert 'grep -qE "\\\$\\{#_SNAPMULTI_CONTAINERS\\[@\\]\\} == 0" "$SMOKE"' \
    "check_containers.sh has empty-parse guard after the while-read loop"

# ── (3d) Malformed-row guard (Python parity) ────────────────────
# The Python loader validates role ∈ {server, client} (PR #590 LOW).
# Pre-fix Bash side accepted any role, so a malformed manifest like
# `not-a-real-container banana` loaded the bogus name as the only
# expected container and smoke silently bypassed the entire real
# fleet. Both name (Docker identifier shape) and role must validate.
echo
echo "== bash loader malformed-row fallback (Python parity) =="

# Malformed role.
BAD_ROLE_FIXTURE=$(mktemp -t container-bad-role-XXXXXX)
cat > "$BAD_ROLE_FIXTURE" <<'TXT'
fb-display banana
snapserver server
TXT
bad_role_out=$(SNAPMULTI_CONTAINER_MANIFEST="$BAD_ROLE_FIXTURE" bash <<EOF
set -euo pipefail
section() { :; }; pass_check() { :; }; fail_check() { :; }; warn() { :; }; info() { :; }
is_pi_zero_2w() { return 1; }
# shellcheck source=/dev/null
source "$SMOKE"
echo "\${#_SNAPMULTI_CONTAINERS[@]}"
EOF
)
rm -f "$BAD_ROLE_FIXTURE"
if [[ "$bad_role_out" =~ ^[0-9]+$ ]] && (( bad_role_out >= 10 )); then
    echo "  PASS: manifest with malformed role falls back to hardcoded list ($bad_role_out entries)"
    pass=$((pass + 1))
else
    echo "  FAIL: malformed role manifest did not fall back (got '$bad_role_out')"
    fail=$((fail + 1))
fi

# Malformed name (illegal first character).
BAD_NAME_FIXTURE=$(mktemp -t container-bad-name-XXXXXX)
cat > "$BAD_NAME_FIXTURE" <<'TXT'
-leading-dash client
fb-display client
TXT
bad_name_out=$(SNAPMULTI_CONTAINER_MANIFEST="$BAD_NAME_FIXTURE" bash <<EOF
set -euo pipefail
section() { :; }; pass_check() { :; }; fail_check() { :; }; warn() { :; }; info() { :; }
is_pi_zero_2w() { return 1; }
# shellcheck source=/dev/null
source "$SMOKE"
echo "\${#_SNAPMULTI_CONTAINERS[@]}"
EOF
)
rm -f "$BAD_NAME_FIXTURE"
if [[ "$bad_name_out" =~ ^[0-9]+$ ]] && (( bad_name_out >= 10 )); then
    echo "  PASS: manifest with malformed name falls back to hardcoded list ($bad_name_out entries)"
    pass=$((pass + 1))
else
    echo "  FAIL: malformed name manifest did not fall back (got '$bad_name_out')"
    fail=$((fail + 1))
fi

# Valid manifest still loads exactly the manifest entries (regression
# guard: the validation MUST NOT reject legitimate names like
# `audio-visualizer` with the dash in the middle, or `shairport-sync`).
VALID_FIXTURE=$(mktemp -t container-valid-XXXXXX)
cat > "$VALID_FIXTURE" <<'TXT'
# Comment row — skipped.
foo-bar.baz server
qux_quux client
TXT
valid_out=$(SNAPMULTI_CONTAINER_MANIFEST="$VALID_FIXTURE" bash <<EOF
set -euo pipefail
section() { :; }; pass_check() { :; }; fail_check() { :; }; warn() { :; }; info() { :; }
is_pi_zero_2w() { return 1; }
# shellcheck source=/dev/null
source "$SMOKE"
echo "\${#_SNAPMULTI_CONTAINERS[@]}"
echo "\${_SNAPMULTI_CONTAINERS[*]}"
EOF
)
rm -f "$VALID_FIXTURE"
valid_count=$(printf '%s\n' "$valid_out" | head -1)
valid_names=$(printf '%s\n' "$valid_out" | tail -1)
if [[ "$valid_count" == "2" && "$valid_names" == "foo-bar.baz qux_quux" ]]; then
    echo "  PASS: valid manifest loads exactly the declared entries (no fallback)"
    pass=$((pass + 1))
else
    echo "  FAIL: valid manifest loaded wrong entries (count=$valid_count, names='$valid_names')"
    fail=$((fail + 1))
fi

# ── (3e) Python loader: UTF-8 encoding pin (PR #590 review LOW) ──
# Manifest contains non-ASCII in comments (em-dash). On a POSIX/C
# locale container, default `open()` decodes ASCII and raises
# UnicodeDecodeError BEFORE the `startswith("#")` skip. The exception
# is a ValueError (not OSError), so `except OSError: continue` does
# not catch it and the metadata service fails to import.
echo
echo "== python loader UTF-8 encoding pin =="

assert 'grep -qE "open\\(path, encoding=.utf-8.\\)" "$META_PY"' \
    "metadata-service.py opens manifest with explicit encoding='utf-8'"

# ── (4) No duplicate hardcoded full list survives ───────────────
echo
echo "== no duplicate full-list hardcoded =="

# The bash module has a fallback hardcoded list AND the live loader.
# Both are intentional but the FALLBACK must stay aligned, AND the
# loader must actually be wired (a future revert that drops the
# loader and leaves only the fallback would silently bypass the
# manifest). Pin both:
assert 'grep -q "_load_container_manifest" "$SMOKE"' \
    "check_containers.sh defines _load_container_manifest loader"
assert 'grep -q "^_load_container_manifest$" "$SMOKE"' \
    "check_containers.sh actually calls the loader at module load"

# Same for the Python side. _CONTAINER_ROLE must come from
# _load_container_role_manifest(), not a bare dict literal. The
# fallback variable is named _CONTAINER_ROLE_FALLBACK so a `grep
# _CONTAINER_ROLE = {` regression is unambiguous.
assert 'grep -q "_load_container_role_manifest" "$META_PY"' \
    "metadata-service.py defines _load_container_role_manifest loader"
assert 'grep -qE "^_CONTAINER_ROLE: dict\[str, str\] = _load_container_role_manifest\\(\\)" "$META_PY"' \
    "metadata-service.py _CONTAINER_ROLE is assigned from the loader"
# The bare-literal form `_CONTAINER_ROLE: dict[str, str] = {` would
# be the drift signal — pin its absence.
literal_count=$(grep -cE "^_CONTAINER_ROLE: dict\[str, str\] = \{" "$META_PY" || true)
assert_eq "$literal_count" "0" \
    "no bare-literal _CONTAINER_ROLE = {...} remains in metadata-service.py"

echo
echo "Results: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
