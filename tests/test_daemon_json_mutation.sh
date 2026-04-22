#!/usr/bin/env bash
set -euo pipefail

# Behavioral test: tune_docker_daemon writes/removes storage-driver
# correctly in daemon.json. Exercises the REAL production function
# extracted from system-tune.sh with /etc/docker patched to temp dir.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TUNE_SH="$SCRIPT_DIR/../scripts/common/system-tune.sh"

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

FAKE_DOCKER=$(mktemp -d)
DAEMON_JSON="$FAKE_DOCKER/daemon.json"
trap 'rm -rf "$FAKE_DOCKER"' EXIT

# Stub logging
info()  { :; }
ok()    { :; }
warn()  { :; }

# Extract tune_docker_daemon from production using Python brace matching
# (sed /^}/p fails on nested braces), then patch /etc/docker path
_func_body=$(python3 -c "
with open('$TUNE_SH') as f:
    content = f.read()
start = content.find('tune_docker_daemon()')
brace = content.index('{', start)
depth = 0
i = brace
while i < len(content):
    if content[i] == '{': depth += 1
    elif content[i] == '}': depth -= 1
    if depth == 0: break
    i += 1
func = content[start:i+1]
func = func.replace('/etc/docker/daemon.json', '$DAEMON_JSON')
func = func.replace('/etc/docker', '$FAKE_DOCKER')
print(func)
")
eval "$_func_body"

echo "Testing tune_docker_daemon JSON mutation..."

# Test 1: create fresh with fuse-overlayfs
rm -f "$DAEMON_JSON"
tune_docker_daemon --live-restore --fuse-overlayfs
driver=$(python3 -c "import json; print(json.load(open('$DAEMON_JSON')).get('storage-driver',''))")
assert_eq "$driver" "fuse-overlayfs" "create fresh config with fuse-overlayfs"

# Test 2: rollback removes storage-driver
tune_docker_daemon --live-restore
has_driver=$(python3 -c "import json; print('storage-driver' in json.load(open('$DAEMON_JSON')))")
assert_eq "$has_driver" "False" "rollback removes storage-driver"

# Test 3: live-restore preserved after rollback
live=$(python3 -c "import json; print(json.load(open('$DAEMON_JSON')).get('live-restore', False))")
assert_eq "$live" "True" "live-restore preserved after rollback"

# Test 4: re-add fuse-overlayfs
tune_docker_daemon --live-restore --fuse-overlayfs
driver=$(python3 -c "import json; print(json.load(open('$DAEMON_JSON')).get('storage-driver',''))")
assert_eq "$driver" "fuse-overlayfs" "re-add fuse-overlayfs to existing config"

# Test 5: log-driver always present
log_driver=$(python3 -c "import json; print(json.load(open('$DAEMON_JSON')).get('log-driver',''))")
assert_eq "$log_driver" "json-file" "log-driver always set"

echo ""
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
