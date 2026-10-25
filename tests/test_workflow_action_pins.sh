#!/usr/bin/env bash
# Every third-party action in .github/workflows is pinned to a full commit
# SHA. A tag (even an exact one like v7.0.1) can be moved by the action's
# owner; a SHA cannot. Local actions (./...) and docker:// refs are exempt.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WF_DIR="$SCRIPT_DIR/../.github/workflows"

echo "## workflow action pins"

unpinned=$(grep -nE '^[[:space:]-]*uses:[[:space:]]' "$WF_DIR"/*.yml \
    | grep -vE 'uses:[[:space:]]+(\./|docker://)' \
    | grep -vE 'uses:[[:space:]]+[^[:space:]@]+@[0-9a-f]{40}([[:space:]]|$)' || true)

if [[ -n "$unpinned" ]]; then
    echo "  FAIL: actions not pinned to a commit SHA:"
    printf '%s\n' "$unpinned" | sed "s|^$WF_DIR/|    |"
    exit 1
fi

count=$(grep -hcE '^[[:space:]-]*uses:[[:space:]]' "$WF_DIR"/*.yml | awk '{s+=$1} END{print s}')
echo "  PASS: all $count action refs pinned to a commit SHA"
