#!/usr/bin/env bash
# scripts/smoke/check_boot_health.sh — systemd boot graph integrity
#
# Sourced by device-smoke.sh. Relies on helpers exposed by the main
# script: section, pass_check, fail_check, warn, info.
#
# What this catches that the original smoke missed:
# An ordering cycle in the systemd unit graph forces systemd to break
# the cycle by deleting jobs (typical victims: local-fs.target,
# sockets.target, systemd-update-done.service, systemd-binfmt.service).
# The deleted jobs degrade the first post-overlayroot boot in subtle
# ways — services come up but in a wrong order, the network stack lags,
# DNS races with services that need it. On heavier configurations
# (server+display + multiple containers) the user observes "device came
# up without network" and force-reboots to recover.
#
# Verified live 2026-05-10 on snapvideo + snapdigi after the v0.7.0
# reflash: PR #334's `.automount` template carried network ordering it
# should not have, creating exactly this cycle. PR #337 fixed the root
# cause; this module makes the cycle observable in the smoke gate so a
# similar regression cannot pass silently again.
#
# The check is mode-agnostic: ordering cycles are equally bad on
# server, client, and both.

# shellcheck disable=SC2154  # MODE et al come from the parent script.

check_boot_health() {
    section "Boot Health"

    # journalctl --priority=info captures the "ordering cycle"
    # diagnostic. Counting matches in the current boot is enough — the
    # message is one line per cycle systemd identified.
    #
    # `grep` exits 1 on no-match. With `set -euo pipefail` inherited
    # from the parent, that propagates through the pipeline and the
    # `$()` substitution fails. The empty-result case is exactly the
    # GOOD case (no cycles), so we cannot let pipefail kill us here.
    # Pattern: terminate the pipeline with `{ grep ... || true; }` so
    # the inner failure is swallowed before pipefail evaluates the
    # final exit code. Do NOT use `... || echo 0` outside `$()` —
    # that produces "0\n0" output (grep prints 0, fallback prints 0
    # again, both captured) and downstream `[[ -eq ]]` blows up.
    local cycle_lines deleted_units
    cycle_lines=$(journalctl --no-pager -b 0 2>/dev/null | { grep -c 'ordering cycle' || true; })

    if [[ "${cycle_lines:-0}" -eq 0 ]]; then
        pass_check "No systemd ordering cycles in current boot"
    else
        fail_check "systemd reported $cycle_lines ordering cycle line(s) in current boot — graph degraded (run \`journalctl -b 0 | grep \"ordering cycle\"\` for the cycle path)"
    fi

    # Units actually DELETED to break the cycle. Different message,
    # printed once per affected job. If anything was deleted, jobs that
    # should have run did not — even if no system-wide failure shows up
    # in `systemctl --failed` (the deleted job is silently skipped).
    deleted_units=$(journalctl --no-pager -b 0 2>/dev/null | { grep -oE 'Job [a-z0-9._-]+\.(service|target|socket)/start deleted' || true; } | sort -u | wc -l | tr -d ' ')

    if [[ "${deleted_units:-0}" -eq 0 ]]; then
        pass_check "No systemd units deleted from boot graph"
    else
        local sample
        sample=$(journalctl --no-pager -b 0 2>/dev/null | { grep -oE 'Job [a-z0-9._-]+\.(service|target|socket)/start' || true; } | sort -u | head -3 | tr '\n' ',' | sed 's/,$//')
        fail_check "$deleted_units distinct systemd unit(s) deleted from boot graph (sample: ${sample:-none})"
    fi

    # systemd's overall verdict on the boot. `running` is healthy,
    # `degraded` means some unit failed (caught by --failed below), and
    # anything else (e.g. `starting`, `maintenance`) is an outright fail.
    local sys_state
    sys_state=$(systemctl is-system-running 2>/dev/null || true)
    case "$sys_state" in
        running)
            pass_check "systemd is-system-running: running"
            ;;
        degraded)
            local failed_count failed_list
            failed_count=$(systemctl --failed --no-legend --no-pager 2>/dev/null | wc -l | tr -d ' ')
            failed_list=$(systemctl --failed --no-legend --no-pager --plain 2>/dev/null | awk '{print $1}' | head -3 | tr '\n' ',' | sed 's/,$//')
            fail_check "systemd state degraded — ${failed_count:-?} failed unit(s) (${failed_list:-none})"
            ;;
        *)
            fail_check "systemd state unexpected: '${sys_state:-unknown}'"
            ;;
    esac
}
