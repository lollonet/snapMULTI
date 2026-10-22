#!/usr/bin/env bash
# Static checks for the music library bind mount in docker-compose.yml:
#   - mpd and mympd mount /music through the shared &music-volume anchor
#   - the anchor is read-only, rslave (a share mounted on the host after the
#     container started must appear inside) and still creates a missing path
#   - no short-syntax /music bind is left (short syntax is always rprivate)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE="$SCRIPT_DIR/../docker-compose.yml"

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

# Print the lines of one x- anchor block or one service block.
block() {
    awk -v start="$1" '
        $0 ~ "^" start { on = 1; next }
        on && /^[^[:space:]#]/ { exit }
        on && /^  [a-z][a-z0-9_-]*:$/ && start ~ /^  / { exit }
        on { print }
    ' "$COMPOSE"
}

# shellcheck disable=SC2034  # read inside assert's eval
anchor="$(block 'x-music-volume: &music-volume')"

echo "## &music-volume anchor"
assert "grep -q 'target: /music' <<<\"\$anchor\"" "targets /music"
assert "grep -q 'read_only: true' <<<\"\$anchor\"" "read-only"
assert "grep -q 'propagation: rslave' <<<\"\$anchor\"" "rslave propagation"
assert "grep -q 'create_host_path: true' <<<\"\$anchor\"" "creates a missing host path"

echo
echo "## Services using the anchor"
for svc in mpd mympd; do
    assert "block '  $svc:' | grep -q -- '- \*music-volume'" "$svc mounts /music via *music-volume"
done
assert "! grep -qE ':/music(:|\$)' '$COMPOSE'" "no short-syntax /music bind left"

echo
echo "Results: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
