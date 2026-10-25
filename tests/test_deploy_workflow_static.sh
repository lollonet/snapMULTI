#!/usr/bin/env bash
# Static checks on .github/workflows/deploy.yml (SSH deploy to the home
# server):
#   - every repo file docker-compose.yml bind-mounts is shipped with it
#     (shipping only docker-compose.yml ran a new compose against old /
#     missing configs and scripts), in both the upload and the remote list
#   - the running stack is only touched after a successful pull: no
#     `compose down`, no `image prune -a` before `compose pull`
#   - TIDAL_ENABLED=false in .env is honoured instead of re-adding tidal
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/.."
WF="$ROOT/.github/workflows/deploy.yml"
COMPOSE="$ROOT/docker-compose.yml"

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

# Upload list: the FILES=( ... ) array of the copy step.
# shellcheck disable=SC2034  # read inside assert eval
upload_list=$(awk '/^ *FILES=\(/{on=1; next} on && /^ *\)/{exit} on {gsub(/^ +/, ""); print}' "$WF")
# Remote list: DEPLOY_FILES="..." of the ssh script.
# shellcheck disable=SC2034  # read inside assert eval
remote_list=$(grep -m1 -oE 'DEPLOY_FILES="[^"]*"' "$WF" | cut -d'"' -f2 | tr ' ' '\n')

covered() {
    local path="$1" list="$2" entry
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        [[ "$path" == "$entry" || "$path" == "$entry"/* ]] && return 0
    done <<< "$list"
    return 1
}

echo "## Repo files bind-mounted by docker-compose.yml are shipped"
assert "[[ -n \"\$upload_list\" ]]" "upload FILES list found"
assert "[[ -n \"\$remote_list\" ]]" "remote DEPLOY_FILES list found"
assert "covered docker-compose.yml \"\$upload_list\" && covered docker-compose.yml \"\$remote_list\"" \
    "docker-compose.yml shipped"
n=0
while IFS= read -r src; do
    src="${src#./}"
    # Only files tracked in the repo (runtime dirs like audio/ or data/
    # are created on the device, not shipped).
    git -C "$ROOT" ls-files --error-unmatch "$src" >/dev/null 2>&1 \
        || [[ -n "$(git -C "$ROOT" ls-files "$src" 2>/dev/null)" ]] \
        || continue
    n=$((n + 1))
    assert "covered '$src' \"\$upload_list\"" "uploaded: $src"
    assert "covered '$src' \"\$remote_list\"" "installed on device: $src"
done < <(grep -oE '^\s+- \./[^:]+:' "$COMPOSE" | sed -E 's/^\s+- //; s/:$//' | sort -u)
assert "(( n >= 5 ))" "found the repo bind mounts in docker-compose.yml ($n)"

echo
echo "## Pull before touching the running stack"
pull_line=$(grep -n 'docker compose pull' "$WF" | head -1 | cut -d: -f1)
up_line=$(grep -n 'docker compose up -d' "$WF" | head -1 | cut -d: -f1)
assert "[[ -n '$pull_line' && -n '$up_line' ]] && (( pull_line < up_line ))" "compose pull runs before compose up"
assert "! grep -qE 'docker compose down' '$WF'" "no compose down (a failed pull used to leave no containers)"
assert "! grep -qE 'image prune -a' '$WF'" "no prune -a (a failed pull used to leave no images)"
assert "awk -v p='$pull_line' 'NR > p && /docker image prune -f/ {found=1} END {exit !found}' '$WF'" \
    "dangling images pruned after the new stack is up"
assert "grep -qE 'docker compose pull \\|\\| \\{.*exit 1' '$WF'" \
    "failed pull aborts the deploy"

echo
echo "## Tidal opt-out"
assert "grep -q 'TIDAL_ENABLED' '$WF'" "workflow reads TIDAL_ENABLED from .env"
assert "grep -qE 'false\\|0\\|no\\|off\\)' '$WF'" "false / 0 / no / off opt out (same rule as deploy.sh)"
assert "grep -q 'docker rm -f tidal-connect' '$WF'" "opted-out tidal-connect container removed"

echo
echo "## Summary"
echo "  Passed: $pass"
echo "  Failed: $fail"
[[ $fail -eq 0 ]]
