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
# Verified live 2026-05-10 on pi-server + pi-display after the v0.7.0
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
    # `degraded` means at least one unit is in failed state, and
    # anything else (e.g. `starting`, `maintenance`) is an outright fail.
    #
    # `degraded` is too noisy as-is: several upstream Pi OS units
    # legitimately fail on a read-only / overlayroot filesystem — we
    # cannot fix them and they don't impact snapMULTI behaviour. Treat
    # them as an allowlist; only fail when a unit OUTSIDE that list is
    # in failed state. The allowlist matches both the bare unit name
    # ("rpi-resize-swap-file.service") and the variant systemd prints
    # in --failed output (just the prefix, with ".service" appended).
    local _expected_failures=(
        # Pi OS swap resize: skipped on overlayroot (target FS is RO).
        "rpi-resize-swap-file.service"
        # cloud-init runs once at first boot; its main service often
        # finishes "failed" because of timeouts/race conditions even
        # when firstboot.sh succeeded. snapmulti's own checkpoint files
        # are the real source of truth for install completion.
        "cloud-init-main.service"
        # Debian's daily man-page index regeneration races with the
        # fuse-overlayfs upper layer on /var/cache/man — `mandb` aborts
        # with "Resource temporarily unavailable" (EAGAIN) on overlayroot.
        # Caught on pi4-test 2026-05-10: the per-locale subdir creation
        # (/var/cache/man/pt_BR/<PID>) races with fuse-overlayfs file
        # ops. Not snapMULTI-related and we don't ship man pages anyway.
        "man-db.service"
        # Imager-staged WiFi creds can stall NM in need-auth → 75s timeout
        "NetworkManager-wait-online.service"
    )

    local sys_state
    sys_state=$(systemctl is-system-running 2>/dev/null || true)
    case "$sys_state" in
        running)
            pass_check "systemd is-system-running: running"
            ;;
        degraded)
            # Build the actual failed-unit list, then subtract the
            # allowlist. `--no-legend --plain` produces one unit name
            # per line (with possible trailing column noise we strip
            # via awk).
            local all_failed unexpected_failed
            all_failed=$(systemctl --failed --no-legend --no-pager --plain 2>/dev/null | awk '{print $1}' || true)
            unexpected_failed=""
            local unit
            while IFS= read -r unit; do
                [[ -z "$unit" ]] && continue
                local skip=false
                local allowed
                for allowed in "${_expected_failures[@]}"; do
                    if [[ "$unit" == "$allowed" ]]; then
                        skip=true
                        break
                    fi
                done
                if [[ "$skip" != "true" ]]; then
                    unexpected_failed+="$unit"$'\n'
                fi
            done <<< "$all_failed"

            local unexpected_count expected_count
            unexpected_count=$(printf '%s' "$unexpected_failed" | grep -c . || true)
            expected_count=$(printf '%s\n' "$all_failed" | grep -c . || true)
            unexpected_count="${unexpected_count:-0}"
            expected_count="${expected_count:-0}"

            if (( unexpected_count == 0 )); then
                pass_check "systemd is-system-running: degraded (only expected failures: ${expected_count} unit(s) on the readonly-FS allowlist)"
            else
                local first_three
                first_three=$(printf '%s' "$unexpected_failed" | tr '\n' ',' | sed 's/,*$//' | cut -c-200)
                fail_check "systemd state degraded — ${unexpected_count} unexpected failed unit(s): ${first_three}"
            fi
            ;;
        *)
            fail_check "systemd state unexpected: '${sys_state:-unknown}'"
            ;;
    esac
}
