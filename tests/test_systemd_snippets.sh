#!/usr/bin/env bash
# Functional + static checks for scripts/common/systemd-snippets.sh.
#
# Each helper emits exactly one systemd unit-file line. The output is
# consumed via $(helper) inside an unquoted heredoc, so:
#   - bash strips the trailing newline from $() — helpers MUST NOT emit
#     a trailing newline (otherwise the next heredoc line shifts down).
#   - the substituted text is plain characters: bash does NOT re-process
#     $(...) or $VAR inside the substituted result. So `$(seq …)` and
#     `$$mem` must appear literally in helper output, NOT in their
#     bash-evaluated forms.
#
# We assert byte-for-byte equality against the strings that previously
# lived inlined in deploy.sh (snapmulti-server.service) and setup.sh
# (snapclient.service), to lock the helper outputs to the pre-refactor
# behaviour.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNIPPETS="$SCRIPT_DIR/../scripts/common/systemd-snippets.sh"

pass=0
fail=0

assert_eq() {
    local actual="$1" expected="$2" desc="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        fail=$((fail + 1))
    fi
}

echo "=== Static checks ==="
assert_eq "$(test -f "$SNIPPETS" && echo yes)" "yes" "systemd-snippets.sh exists"
assert_eq "$(bash -n "$SNIPPETS" 2>&1 && echo OK)" "OK" "bash -n clean"
if command -v shellcheck >/dev/null 2>&1; then
    assert_eq "$(shellcheck -S warning "$SNIPPETS" >/dev/null 2>&1 && echo OK)" "OK" "shellcheck -S warning clean"
fi
for fn in docker_info_ready_execstartpre avahi_daemon_ready_execstartpre \
          mem_drift_recreate_execstartpre compose_stop_5s_execstop; do
    assert_eq "$(grep -cE "^${fn}\\(\\) \\{" "$SNIPPETS")" "1" "function $fn defined"
done

echo
echo "=== Source guard ==="
# Source twice — second source must be a no-op (idempotent load).
( # shellcheck disable=SC1090
  source "$SNIPPETS"
  loaded_first="$_SNAPMULTI_SYSTEMD_SNIPPETS_LOADED"
  # shellcheck disable=SC1090
  source "$SNIPPETS"
  loaded_second="$_SNAPMULTI_SYSTEMD_SNIPPETS_LOADED"
  echo "  first=$loaded_first second=$loaded_second"
  [[ "$loaded_first" == "1" && "$loaded_second" == "1" ]]
) && { echo "  PASS: source guard works"; pass=$((pass + 1)); } || { echo "  FAIL: source guard"; fail=$((fail + 1)); }

# Reset guard for the rest of the test (we want to source fresh).
unset _SNAPMULTI_SYSTEMD_SNIPPETS_LOADED
# shellcheck source=../scripts/common/systemd-snippets.sh
source "$SNIPPETS"

echo
echo "=== docker_info_ready_execstartpre ==="
expected_docker="ExecStartPre=/bin/bash -c 'for i in \$(seq 1 60); do docker info >/dev/null 2>&1 && exit 0; sleep 2; done; exit 1'"
actual_docker=$(docker_info_ready_execstartpre)
assert_eq "$actual_docker" "$expected_docker" "docker info wait line matches pre-refactor"
# No trailing newline (the function must NOT emit one; verify length).
actual_with_marker=$(printf '%s|END' "$(docker_info_ready_execstartpre)")
assert_eq "${actual_with_marker: -4}" "|END" "docker_info has no trailing newline"

echo
echo "=== avahi_daemon_ready_execstartpre ==="
expected_avahi="ExecStartPre=/bin/bash -c 'for i in \$(seq 1 30); do systemctl is-active --quiet avahi-daemon.service && [[ -S /run/avahi-daemon/socket ]] && break; sleep 1; done; sleep 2'"
actual_avahi=$(avahi_daemon_ready_execstartpre)
assert_eq "$actual_avahi" "$expected_avahi" "avahi readiness line matches pre-refactor"

echo
echo "=== mem_drift_recreate_execstartpre snapserver /opt/snapmulti ==="
expected_mem_srv='ExecStartPre=-/bin/bash -c '\''mem=$(/usr/bin/docker inspect snapserver --format "{{.HostConfig.Memory}}" 2>/dev/null || true); if [[ "$$mem" == "0" ]]; then cd /opt/snapmulti && /usr/bin/docker compose up -d --force-recreate; fi'\'
actual_mem_srv=$(mem_drift_recreate_execstartpre snapserver /opt/snapmulti)
assert_eq "$actual_mem_srv" "$expected_mem_srv" "server mem-drift line matches deploy.sh pre-refactor"

echo
echo "=== mem_drift_recreate_execstartpre snapclient /opt/snapclient ==="
expected_mem_cli='ExecStartPre=-/bin/bash -c '\''mem=$(/usr/bin/docker inspect snapclient --format "{{.HostConfig.Memory}}" 2>/dev/null || true); if [[ "$$mem" == "0" ]]; then cd /opt/snapclient && /usr/bin/docker compose up -d --force-recreate; fi'\'
actual_mem_cli=$(mem_drift_recreate_execstartpre snapclient /opt/snapclient)
assert_eq "$actual_mem_cli" "$expected_mem_cli" "client mem-drift line matches setup.sh pre-refactor"

echo
echo "=== mem_drift_recreate_execstartpre parametrization ==="
# Container name parametrized — alternate value must flow through.
custom=$(mem_drift_recreate_execstartpre someother /tmp/foo)
case "$custom" in
    *'docker inspect someother --format'*) container_ok=1 ;;
    *) container_ok=0 ;;
esac
assert_eq "$container_ok" "1" "container name reflected in output"
case "$custom" in
    *'cd /tmp/foo &&'*) dir_ok=1 ;;
    *) dir_ok=0 ;;
esac
assert_eq "$dir_ok" "1" "project dir reflected in output"

# Missing args must hard-fail (parameter substitution :? guard).
if ( mem_drift_recreate_execstartpre 2>/dev/null ); then
    echo "  FAIL: mem_drift_recreate_execstartpre should reject missing container"
    fail=$((fail + 1))
else
    echo "  PASS: mem_drift_recreate_execstartpre rejects missing container"
    pass=$((pass + 1))
fi
if ( mem_drift_recreate_execstartpre snapserver 2>/dev/null ); then
    echo "  FAIL: mem_drift_recreate_execstartpre should reject missing dir"
    fail=$((fail + 1))
else
    echo "  PASS: mem_drift_recreate_execstartpre rejects missing dir"
    pass=$((pass + 1))
fi

echo
echo "=== compose_stop_5s_execstop ==="
expected_stop="ExecStop=/usr/bin/docker compose stop -t 5"
actual_stop=$(compose_stop_5s_execstop)
assert_eq "$actual_stop" "$expected_stop" "compose stop line matches pre-refactor"

echo
echo "=== Heredoc integration (smoke) ==="
# Confirm that consuming via $() inside a heredoc yields the expected
# output without surprises. The mem-drift case is the gnarliest because
# of the $$ escaping for systemd → bash.
PROJECT_ROOT=/opt/snapmulti
generated=$(cat <<EOF
$(docker_info_ready_execstartpre)
$(mem_drift_recreate_execstartpre snapserver "${PROJECT_ROOT}")
$(compose_stop_5s_execstop)
EOF
)
case "$generated" in
    *'for i in $(seq 1 60)'*) heredoc_seq_ok=1 ;;
    *) heredoc_seq_ok=0 ;;
esac
assert_eq "$heredoc_seq_ok" "1" "heredoc preserves literal \$(seq …)"
case "$generated" in
    *'"$$mem" == "0"'*) heredoc_dollar_ok=1 ;;
    *) heredoc_dollar_ok=0 ;;
esac
assert_eq "$heredoc_dollar_ok" "1" "heredoc preserves literal \$\$mem (systemd escape)"

echo
echo "Results: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
