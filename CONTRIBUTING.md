# Contributing to snapMULTI

Bug fixes, features, doc improvements and "show your setup" posts all welcome.

- [Issues](https://github.com/lollonet/snapMULTI/issues) — bug reports + feature requests (use the templates)
- [Discussions](https://github.com/lollonet/snapMULTI/discussions) — questions, ideas, show your setup
- [SECURITY.md](SECURITY.md) — private vulnerability disclosure

## Non-code contributions

The most useful community contributions are often not code:

- hardware validation reports for Pi models, DAC HATs, amps, SD cards and PSUs
- install logs or diagnostic bundles from failed first boots
- translation fixes for the Italian mirrors
- documentation improvements where a step was unclear
- photos or screenshots of working setups for future hardware examples

For a hardware report, include: Pi model + RAM, SD card model/class if known, PSU rating, HAT/DAC/audio output, install type (`server`, `client`, `both`), network path (Ethernet/WiFi/NAS), snapMULTI version, and `device-smoke.sh` or `fleet-smoke.sh` output if available.

## Where to start

Looking for an entry point:

- [`good first issue`](https://github.com/lollonet/snapMULTI/labels/good%20first%20issue) — small, well-scoped tasks suitable for a first contribution. Usually contained in a single file or directory, no deep architecture knowledge required.
- [`help wanted`](https://github.com/lollonet/snapMULTI/labels/help%20wanted) — substantive issues that would benefit from extra hands. Generally larger scope than `good first issue`.

Before starting work, leave a short comment on the issue to claim it (so two people don't duplicate the same fix). The maintainer replies in 1–2 days. Once acknowledged, open the PR against `main` when ready — no second permission needed.

## Submitting code

1. Fork + branch off `main` (`feature/<short-name>` or `fix/<short-name>`).
2. Make focused, atomic commits. Reference related issues (`Fix audio dropout on Pi 3 (#42)`).
3. Test locally:
   ```bash
   shellcheck scripts/*.sh scripts/**/*.sh
   for f in tests/test_*.sh; do bash "$f" || break; done   # shell tests
   pytest tests/                                            # Python tests (metadata service + plugins)
   docker compose config --quiet
   ```
   CI (`validate.yml` + `build-test.yml`) is the source of truth — local commands are best-effort.
4. Open a PR against `main`. CI runs `validate.yml` (shellcheck + docker-compose syntax) and `build-test.yml` (Docker build).

## Documentation

Each topic has ONE authoritative file (full SSOT table in [CLAUDE.md](CLAUDE.md)). Don't duplicate content across docs.

| File | Content |
|------|---------|
| `README.md` | Overview, quick start, realistic expectations, "choose your setup" |
| `docs/INSTALL.md` | First-time installation walk-through (basic linear path) |
| `docs/TROUBLESHOOTING.md` | Symptom-based support, mDNS / audio / install failure triage, diagnostic bundle recovery |
| `docs/ADVANCED.md` | Operational customisation — multi-room, NAS (NFS / SMB), custom `.env`, manual deploy, read-only fs, update strategy, MPD CLI, JSON-RPC |
| `docs/HARDWARE.md` | Supported Pi models, audio outputs, SD / network / hardware choice, Pi Zero 2 W notes |
| `docs/USAGE.md` | Architecture reference — services, ports, audio sources, security model |
| `docs/CLIENT-METADATA.md` | Client integration guide — Snapserver JSON-RPC + metadata-service WS/HTTP contracts, subscribe forms, artwork rules, transport control, anti-patterns (for anyone writing a UI / dashboard / external controller) |
| `config/snapserver.conf` | Authoritative source-parameter schema (inline comments) |

Italian mirrors (`*.it.md`) follow the English files 1:1 — update them in the same PR when you change English docs. Full diacritical correctness (use `à è é ì ò ù`, never the ASCII equivalents).

## Code conventions

**Shell scripts** — `set -euo pipefail` at top, must pass `shellcheck -S warning`, use `scripts/common/unified-log.sh` (`info` / `warn` / `error` / `log_info` / `log_warn` / `log_error`). ASCII-only output for `/dev/tty1` (PSF fonts lack Unicode).

**Docker** — pin specific base-image versions (`alpine:3.23`, not `:latest`). Containers run read-only with `cap_drop: ALL` + `no-new-privileges` where possible; the only exception is `tidal-connect` (proprietary binary needs `DAC_OVERRIDE`). Every container has a healthcheck. Multi-arch builds support `linux/amd64` + `linux/arm64`.

**Audio format** — `44100:16:2` across all sources, no resampling. Don't change without discussion in an issue first.

**Config** — `.env` for user-configurable values (documented in `.env.example`), source config in `config/`, scripts in `scripts/` (shared libraries in `scripts/common/`).

## License

By contributing, you agree your contributions are licensed under `GPL-3.0-only` (see [LICENSE](LICENSE)).

## Governance

snapMULTI is currently maintained by a single principal maintainer (architectural decisions, code review, releases). PRs from external contributors go through CI gates (shellcheck, smoke gate per ADR-005, automated review) and a human review before merge. Dependabot PRs are admin-squash-merged after diff + release-notes review.

The project is intentionally appliance-shaped — see the [`## Non-goals` section in CLAUDE.md](CLAUDE.md#non-goals) for the full list. A "no" to a feature is not personal; it usually means the change belongs in a separate layer (the amp, Home Assistant, a custom snapclient deployment) rather than in snapMULTI itself.

### Non-goals

- No hosted snapMULTI cloud or account system.
- No commercial SLA or universal hardware support promise.
- No public-WAN deployment without an operator-managed reverse proxy and authentication.
- No in-place upgrade workflow for ordinary users; the supported path is reflash-first.
- No broad plugin marketplace or arbitrary audio-stack configurator in the appliance core.

### Path to co-maintainership

Open to consideration after a contributor demonstrates sustained engagement: several substantive PRs landed, active participation in issue triage, and a working understanding of the reflash-first update model ([DEC-003](docs/decisions/DEC-003-reflash-only-updates.md)) + smoke gate (ADR-005). Not an automatism — the principal maintainer decides. If you're interested, start by tackling open issues labelled `help wanted`.

### Exit strategy

If the principal maintainer steps away, the project is designed to be auto-verifiable so a successor can continue without tribal knowledge: `device-smoke.sh` + `fleet-smoke.sh` + `release-manifest.json` + the bilingual documentation + the test suite collectively let a new contributor detect breakages and confirm a deploy is healthy. The fork path is technically open. Continuity is not guaranteed but the foundation exists.
