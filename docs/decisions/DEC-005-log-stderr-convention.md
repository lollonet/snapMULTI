---
type: decision
project: snapMULTI
date: 2026-04-28
status: accepted
pr: "#285"
tags: [decision, snapMULTI, shell, convention, lessons-learned]
---

# DEC-005: `_log` Writes to stderr in Scripts Called via `$()`

## Context

In `discover-server.sh`, `_pick_failover_ipv4` is invoked via command substitution to capture the chosen IP:

```bash
host=$(_pick_failover_ipv4 "$current")
```

The function uses internal logging via `_log()`. The original implementation:

```bash
_log() { echo "[discover] $*"; }
```

This routes log output to stdout. `$()` captures all stdout. Result: `host` contained the IP plus every log line emitted during the function's execution. The downstream regex check `[[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]` rejected the multi-line string, and the script silently fell into the "no servers found" branch.

Found via `bash -x` debugging on moniaclient — the trace showed all the right internal logic running, but the captured value was always polluted.

This is not a bug in `_pick_failover_ipv4` per se. It is a contract violation: a function that emits something on stdout for capture cannot also log to stdout.

## Decision

In any shell script where a logger function (`_log`, `info`, `warn`, etc.) is used inside another function whose stdout is captured (`x=$(other_fn)`), the logger MUST write to stderr.

Concretely, the `_log` helper in `discover-server.sh` and any future analog:

```bash
_log() { echo "[discover] $*" >&2; }
```

## Why

- systemd captures both stdout and stderr into the journal (`journalctl -u <service>`), so logging visibility is identical
- stderr is the canonical channel for diagnostics; reserving stdout for "the value the function returns" matches Unix convention
- `$()` captures stdout only by default — no mental model needed about which functions are "safe to capture from"

## Consequences

- Future `_log`-style helpers in this codebase must follow the convention (>&2 redirect)
- Reviewers should flag any logger that writes to stdout when called inside `$()`, especially in shell functions returning data
- `journalctl` output unchanged from a user's perspective

## Alternatives Considered

- **Make every function callable via `$()` always echo cleanly** — places the burden on every function instead of the logger, brittle
- **Use a separate logging channel (FD 3)** — overengineering for a shell script
- **Log to a file** — loses real-time journalctl integration, adds rotation concerns

## Files Changed

- `client/common/scripts/discover-server.sh` — single-line change to `_log` definition

## Lesson Generalized

Any function that emits its return value via stdout (i.e., is meant to be used in command substitution) cannot share stdout with side-channel output. This is the Unix way: stdout is the data channel, stderr is the diagnostic channel. Mixing them breaks command substitution silently.

In our case the bug was invisible because `journalctl -u` showed the log lines fine — the visible behavior matched the working case. Only `bash -x` revealed the polluted variable.

## Related

- [DEC-004](DEC-004-multi-server-failover-design.md) — discover-server.sh rewrite that triggered this convention
