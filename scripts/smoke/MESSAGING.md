# Smoke output messaging guidelines

> Audience: someone managing one or more snapMULTI Raspberry Pis. Comfortable on a terminal, not a Linux specialist. Reads smoke output to answer **"is this Pi healthy and if not, what do I do?"**

## Status semantics

| Status | When |
|--------|------|
| `[OK]` | Check pass — positive outcome confirmed |
| `[WARN]` | Functional but suboptimal — system works, polish/observe |
| `[FAIL]` | Broken — user-visible feature does not work, action required |
| `[INFO]` | Skipped or contextual — neither pass nor fail, just FYI |

## Sentence shape

```
[STATUS] <Subject>: <verdict>[ — <reason or action>]
```

- **Subject**: short noun phrase (`MPD healthcheck`, `Snapcast mDNS announcement`, `Overlay tmpfs`).
- **Verdict**: present-tense state (`healthy`, `not advertised`, `92% full`).
- **Reason / action** (after `—`): only when the verdict alone is not actionable.

Examples:

```
[OK]   MPD healthcheck: healthy
[FAIL] Snapcast mDNS announcement: not advertised — clients won't find this server
[WARN] Overlay tmpfs: 87% full (approaching the 90% unbootable threshold)
[INFO] Per-HAT kernel module check: skipped (HAT_CONFIG not in .env; ALSA card check above is the authoritative one)
```

## Banned phrasing

- **Implementation detail leakage**: `libavahi-client`, `fuse-overlayfs upper layer`, `BASH_REMATCH`. Replace with what the user observes (`Avahi client library`, `read-only filesystem overlay`).
- **PR / issue numbers**: `(PR #285 ...)` — git blame / ADR is for code archaeology, not user-facing text.
- **File paths** in pass_check / info: `/etc/systemd/system/...mount` adds noise; mention the kind of artefact, not the path. Keep paths in fail/warn where the operator may need to `cd` / inspect.
- **Pseudo-questions**: `"avahi socket race? port collision?"` reads as uncertainty. Either confirm the issue or split into two checks.
- **Self-referential phrasing**: don't claim something is wrong when the check itself is what made it wrong (see ADR/auto-boot smoke `starting` paradox).

## "Skipped" rule

Every `info "... skipped"` MUST include the reason in parentheses + one of:

- **(authoritative check above)** — another check already covers the same property
- **(missing dep: <name>)** — install hint
- **(N/A on <profile>)** — wrong device class, e.g. `(N/A on native client)`

## Glossary inline

When using terms not obvious to a Pi-hobbyist operator, add one-line inline gloss the first time per check:

```
[OK] Snapcast RPC (port 1705 JSON-RPC control): responsive
[OK] DSCP EF marking (per-packet priority hint): present on port 1704
```

Single mention per `check_*.sh` script is enough — repetition becomes noise.
