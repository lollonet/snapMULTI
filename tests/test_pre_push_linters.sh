#!/usr/bin/env bash
# Tests for scripts/git-hooks/pre-push linter pinning: the hook must read
# the ruff/hadolint pins from validate.yml, run a local binary only when
# it matches the pin, fall back to uvx / Docker for the pinned version,
# skip when neither exists, and exit non-zero when the pins are missing.
# Bash 3.2 + bash 5 compatible.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$ROOT/scripts/git-hooks/pre-push"
WORKFLOW="$ROOT/.github/workflows/validate.yml"

pass=0
fail=0

check() {
    local desc="$1"
    shift
    if "$@"; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc"
        fail=$((fail + 1))
    fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# PATH holds only the tools the hook needs plus per-case stubs, so a real
# ruff / uvx / docker / hadolint on the host never leaks into a case.
TOOLS="$TMP/tools"
mkdir -p "$TOOLS"
for t in sed head awk; do
    ln -s "$(command -v "$t")" "$TOOLS/$t"
done

stub() {
    # stub <dir> <name> <version output> [exit code]
    mkdir -p "$1"
    printf '#!/bin/sh\necho "%s"\nexit %s\n' "$3" "${4:-0}" > "$1/$2"
    chmod +x "$1/$2"
}

docker_stub() {
    # docker_stub <dir> <exit code of `docker info`>; `docker run` logs its args
    mkdir -p "$1"
    cat > "$1/docker" <<EOF
#!/bin/sh
case "\$1" in
    info) exit $2 ;;
    run)  printf '%s\n' "\$@" > "$1/docker.args" ;;
esac
EOF
    chmod +x "$1/docker"
}

linters() {
    # linters <stub dir> <cwd> -> --print-linters output
    (cd "$2" && PATH="$1:$TOOLS" "$BASH" "$HOOK" --print-linters)
}

field() {
    # field <output> <key>
    printf '%s\n' "$1" | sed -n "s/^$2=//p"
}

echo "Pins come from validate.yml"
out=$(linters "$TMP/none" "$ROOT")
ruff_pin=$(field "$out" ruff_pin)
hl_pin=$(field "$out" hadolint_pin)
check "ruff pin is set" test -n "$ruff_pin"
check "hadolint pin is set" test -n "$hl_pin"
check "validate.yml installs ruff==$ruff_pin" grep -qF "pip install ruff==$ruff_pin" "$WORKFLOW"
check "validate.yml installs hadolint v$hl_pin" grep -qF "HL_VERSION=\"v$hl_pin\"" "$WORKFLOW"

echo "ruff resolution"
stub "$TMP/r1" ruff "ruff $ruff_pin"
check "matching local ruff is used" test "$(field "$(linters "$TMP/r1" "$ROOT")" ruff_cmd)" = "ruff"
stub "$TMP/r2" ruff "ruff 99.0.0"
stub "$TMP/r2" uvx "ruff $ruff_pin"
check "mismatched ruff falls back to uvx pin" \
    test "$(field "$(linters "$TMP/r2" "$ROOT")" ruff_cmd)" = "uvx ruff@$ruff_pin"
stub "$TMP/r3" ruff "ruff 99.0.0"
check "mismatched ruff without uvx is skipped" test -z "$(field "$(linters "$TMP/r3" "$ROOT")" ruff_cmd)"
stub "$TMP/r4" ruff "ruff 99.0.0"
stub "$TMP/r4" uvx "error: failed to fetch ruff" 2
check "uvx that cannot fetch the pin is skipped, not run" \
    test -z "$(field "$(linters "$TMP/r4" "$ROOT")" ruff_cmd)"

echo "hadolint resolution"
stub "$TMP/h1" hadolint "Haskell Dockerfile Linter $hl_pin"
check "matching local hadolint is used" \
    test "$(field "$(linters "$TMP/h1" "$ROOT")" hadolint_cmd)" = "hadolint"
stub "$TMP/h5" hadolint "Haskell Dockerfile Linter v$hl_pin-no-git"
check "matching local hadolint with v prefix / -suffix is used" \
    test "$(field "$(linters "$TMP/h5" "$ROOT")" hadolint_cmd)" = "hadolint"
stub "$TMP/h2" hadolint "Haskell Dockerfile Linter 99.0.0"
docker_stub "$TMP/h2" 0
h2=$(field "$(linters "$TMP/h2" "$ROOT")" hadolint_cmd)
check "mismatched hadolint falls back to pinned image" \
    test "${h2#*hadolint/hadolint:v$hl_pin }" = "hadolint"
mkdir -p "$TMP/repo with space"
(cd "$TMP/repo with space" && PATH="$TMP/h2:$TOOLS" eval "$h2 --config .hadolint.yaml Dockerfile.x")
check "the Docker command evals with the cwd mounted as one argument" \
    grep -qxF "$TMP/repo with space:/w" "$TMP/h2/docker.args"
stub "$TMP/h3" hadolint "Haskell Dockerfile Linter 99.0.0"
check "mismatched hadolint without docker is skipped" \
    test -z "$(field "$(linters "$TMP/h3" "$ROOT")" hadolint_cmd)"
stub "$TMP/h4" hadolint "Haskell Dockerfile Linter 99.0.0"
docker_stub "$TMP/h4" 1
check "docker CLI with the daemon down is skipped, not run" \
    test -z "$(field "$(linters "$TMP/h4" "$ROOT")" hadolint_cmd)"

echo "Hook lints the same Dockerfiles as validate.yml"
check "client Dockerfiles are in the hook's hadolint loop" \
    grep -qF 'client/common/docker/*/Dockerfile' "$HOOK"

echo "Missing pins fail hard"
mkdir -p "$TMP/nopins/.github/workflows"
echo "jobs: {}" > "$TMP/nopins/.github/workflows/validate.yml"
rc=0
err=$(cd "$TMP/nopins" && PATH="$TOOLS" "$BASH" "$HOOK" --print-linters 2>&1 >/dev/null) || rc=$?
check "workflow without pins exits non-zero" test "$rc" -ne 0
check "... saying it cannot read the pins" grep -q 'cannot read ruff/hadolint pins' <<< "$err"
mkdir -p "$TMP/noworkflow"
rc=0
err=$(cd "$TMP/noworkflow" && PATH="$TOOLS" "$BASH" "$HOOK" --print-linters 2>&1 >/dev/null) || rc=$?
check "missing workflow exits non-zero" test "$rc" -ne 0
check "... saying validate.yml is not found" grep -q 'validate.yml not found' <<< "$err"

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
