# Contributing to snapMULTI

Bug fixes, features, doc improvements and "show your setup" posts all welcome.

- [Issues](https://github.com/lollonet/snapMULTI/issues) — bug reports + feature requests (use the templates)
- [Discussions](https://github.com/lollonet/snapMULTI/discussions) — questions, ideas, show your setup
- [SECURITY.md](SECURITY.md) — private vulnerability disclosure

## Submitting code

1. Fork + branch off `main` (`feature/<short-name>` or `fix/<short-name>`).
2. Make focused, atomic commits. Reference related issues (`Fix audio dropout on Pi 3 (#42)`).
3. Test locally:
   ```bash
   shellcheck scripts/*.sh scripts/**/*.sh
   bash tests/run-all-tests.sh
   docker compose config --quiet
   ```
4. Open a PR against `main`. CI runs `validate.yml` (shellcheck + docker-compose syntax) and `build-test.yml` (Docker build).

## Documentation

Each topic has ONE authoritative file (full SSOT table in [CLAUDE.md](CLAUDE.md)). Don't duplicate content across docs.

| File | Content |
|------|---------|
| `README.md` | What it does, value prop, 4-step quick start |
| `docs/INSTALL.md` | First-time install walk-through, troubleshooting, diagnostic bundle recovery |
| `docs/HARDWARE.md` | Pi models, DAC HATs, network, recommended setups |
| `docs/USAGE.md` | Architecture, audio sources, services/ports, mDNS, deployment, operations |
| `config/snapserver.conf` | Authoritative source-parameter schema (inline comments) |

Italian mirrors (`*.it.md`) follow the English files 1:1 — update them in the same PR when you change English docs. Full diacritical correctness (use `à è é ì ò ù`, never the ASCII equivalents).

## Code conventions

**Shell scripts** — `set -euo pipefail` at top, must pass `shellcheck -S warning`, use `scripts/common/unified-log.sh` (`info` / `warn` / `error` / `log_info` / `log_warn` / `log_error`). ASCII-only output for `/dev/tty1` (PSF fonts lack Unicode).

**Docker** — pin specific base-image versions (`alpine:3.23`, not `:latest`). Containers run read-only with `cap_drop: ALL` + `no-new-privileges` where possible; the only exception is `tidal-connect` (proprietary binary needs `DAC_OVERRIDE`). Every container has a healthcheck. Multi-arch builds support `linux/amd64` + `linux/arm64`.

**Audio format** — `44100:16:2` across all sources, no resampling. Don't change without discussion in an issue first.

**Config** — `.env` for user-configurable values (documented in `.env.example`), source config in `config/`, scripts in `scripts/` (shared libraries in `scripts/common/`).

## License

By contributing, you agree your contributions are licensed under `GPL-3.0-only` (see [LICENSE](LICENSE)).
