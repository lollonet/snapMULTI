# Contributing to snapclient-pi

## Quick Start

1. Fork and clone the repo
2. Create a feature branch: `git checkout -b feature/my-change`
3. Make changes, commit with [Conventional Commits](https://www.conventionalcommits.org/)
4. Push and open a PR

## Development

```bash
# Run pre-push checks locally
./dev/git-hooks/pre-push

# Run tests
pytest tests/ -v
```

## Code Style

- **Shell**: `set -euo pipefail`, quote variables, use `[[` not `[`
- **Python**: ruff for linting/formatting, type hints required
- **Docker**: Follow hadolint recommendations (see `.hadolint.yaml`)
- **Commits**: `feat:`, `fix:`, `docs:`, `refactor:`, `perf:`, `test:`, `chore:`

## Architecture

snapclient-pi is part of the [snapMULTI](https://github.com/lollonet/snapMULTI) project. See `CLAUDE.md` for detailed conventions.

## Reporting Issues

- **Bugs**: Use the issue template
- **Security**: See `SECURITY.md`
