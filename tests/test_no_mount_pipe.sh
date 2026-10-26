#!/usr/bin/env bash
# No script pipes mount(1) output into another command.
#
# The scripts run under `set -euo pipefail`. A reader that stops early
# (`grep -q`, `awk '... exit'`, `head`) closes the pipe while mount is still
# writing; once the mount table is longer than one write (many Docker
# mounts), mount dies of SIGPIPE and the pipeline returns 141. A condition
# then reads false although it matched, and a plain assignment kills the
# script under set -e. Read the root filesystem type with
# `findmnt -n -o FSTYPE /`, or capture mount's output in a variable first.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# `mount` as a command (not part of a word such as findmnt or umount),
# optionally with arguments or redirections, followed by a pipe.
pattern='(^|[^[:alnum:]_./-])mount([[:space:]][^|;&#]*)?[|]([^|]|$)'

hits=$(cd "$REPO_ROOT" && git grep -nE "$pattern" -- 'scripts' 'client' ':!*.md' \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)

if [[ -n "$hits" ]]; then
    echo "FAIL: mount output piped into another command:"
    printf '  %s\n' "$hits"
    exit 1
fi
echo "PASS: no script pipes mount output"
