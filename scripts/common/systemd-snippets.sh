#!/usr/bin/env bash
# systemd-snippets.sh — single owner of ExecStartPre/Post/Stop snippets
# shared between snapmulti-server.service (scripts/deploy.sh:1034) and
# snapclient.service (client/common/scripts/setup.sh:1243).
#
# Before this consolidation, four identical (modulo container name +
# project-dir variable) snippets were inlined twice each — one in the
# server unit, one in the client unit — and any drift between them
# would have surfaced only at runtime on the device. Cluster surfaced
# by code-architecture-auditor after PR #402; bundled with #402 per
# "narrative-coherent fixes go in one PR" rule.
#
# Contract:
#   - Every helper prints exactly one unit-file line to stdout, no
#     trailing newline. Consumed via `$(helper)` substitution inside an
#     unquoted heredoc (the trailing newline that `$()` already strips
#     would otherwise need explicit handling).
#   - Output text is literal: bash's heredoc substitution drops the
#     command-substitution result in as plain characters and does NOT
#     re-process `$(...)` or `$VAR` inside it. So the snippet helpers
#     embed `$(seq …)` and `$$mem` literally — systemd then interprets
#     them at unit-execution time.
#   - Helpers take no environment dependencies. The only parameter is
#     for the mem-drift helper, which is parameterized on container
#     name and compose project dir.
#
# Sourced by:
#   scripts/deploy.sh                          (server unit generator)
#   client/common/scripts/setup.sh             (client unit generator)
#
# Path resolution from setup.sh is fallback-based (firstboot, dev tree,
# baked install) — see setup.sh for the candidate list. deploy.sh has a
# single predictable path.

# Source guard: re-sourcing is harmless (function redefinitions only),
# but skip the work on repeat to keep the load-time profile flat.
[[ -n "${_SNAPMULTI_SYSTEMD_SNIPPETS_LOADED:-}" ]] && return 0
_SNAPMULTI_SYSTEMD_SNIPPETS_LOADED=1

# ExecStartPre that waits for `docker info` to succeed (≤ 120 s).
# Used by both server and client to gate compose-up on a healthy
# Docker daemon. Hard-fail (exit 1) is intentional: with no daemon
# there is nothing to start.
docker_info_ready_execstartpre() {
    printf 'ExecStartPre=/bin/bash -c %s' \
        "'for i in \$(seq 1 60); do docker info >/dev/null 2>&1 && exit 0; sleep 2; done; exit 1'"
}

# ExecStartPre that waits for avahi-daemon readiness (≤ 30 s + 2 s
# settle). Mitigates the snapcast 0.35 mDNS reconnect bug: if
# libavahi-client connects before avahi is fully up it falls back to
# PTR-only multicast and strict zeroconf clients (Python zeroconf,
# dns-sd, snapclient ≥ 0.36) fail to discover. Non-fatal: falls through
# silently when avahi is absent.
avahi_daemon_ready_execstartpre() {
    printf 'ExecStartPre=/bin/bash -c %s' \
        "'for i in \$(seq 1 30); do systemctl is-active --quiet avahi-daemon.service && [[ -S /run/avahi-daemon/socket ]] && break; sleep 1; done; sleep 2'"
}

# ExecStartPre that detects HostConfig.Memory=0 drift (created before
# cgroup memory v2 was active) and force-recreates the compose stack.
# Args:
#   $1 — container name (snapserver | snapclient)
#   $2 — compose project directory (interpolated at generation time)
# Empty inspect output (fresh reflash, no container yet) returns "",
# which is neither "0" nor a byte count, so the recreate is skipped.
# The `=-` (ignore-failure) prefix is intentional: a flaky probe must
# not block ExecStart.
mem_drift_recreate_execstartpre() {
    local container="${1:?container name required}"
    local project_dir="${2:?compose project dir required}"
    printf 'ExecStartPre=-/bin/bash -c %s' \
        "'mem=\$(/usr/bin/docker inspect ${container} --format \"{{.HostConfig.Memory}}\" 2>/dev/null || true); if [[ \"\$\$mem\" == \"0\" ]]; then cd ${project_dir} && /usr/bin/docker compose up -d --force-recreate; fi'"
}

# ExecStop using `compose stop -t 5`, NOT `compose down`. Non-destructive:
# halts container processes (5 s grace) but leaves container objects
# and the compose network in place, so a subsequent `systemctl start`
# re-enters ExecStart=`compose up -d` and `start`s the existing
# containers — no rebuild, no network teardown, no image re-pull. A
# `systemctl restart` therefore costs 2-5 s of audio silence instead
# of the 30-40 s a full `compose down` would cost.
compose_stop_5s_execstop() {
    printf 'ExecStop=/usr/bin/docker compose stop -t 5'
}
