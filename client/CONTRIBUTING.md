# Contributing to snapMULTI Client

> The client lives at `client/` in the [snapMULTI](https://github.com/lollonet/snapMULTI) monorepo.

## Quick Start

1. Fork and clone the monorepo: `git clone git@github.com:lollonet/snapMULTI.git`
2. Create a feature branch: `git checkout -b feature/my-change`
3. Make changes, commit with [Conventional Commits](https://www.conventionalcommits.org/)
4. Push and open a PR against `main`

## Development

```bash
# Run tests
bash client/tests/test_resource_profiles.sh
bash client/tests/test_pull_hardening.sh
bash client/tests/test_hat_configs.sh
```

## Code Style

- **Shell**: `set -euo pipefail`, quote variables, use `[[` not `[`
- **Python**: ruff for linting/formatting, type hints required
- **Docker**: Follow hadolint recommendations (see `.hadolint.yaml`)
- **Commits**: `feat:`, `fix:`, `docs:`, `refactor:`, `perf:`, `test:`, `chore:`

## Architecture

The client is part of the [snapMULTI](https://github.com/lollonet/snapMULTI) monorepo. See `CLAUDE.md` for detailed conventions.

## Reporting Issues

- **Bugs**: Use the issue template
- **Security**: See `SECURITY.md`
