# Contributing to snapMULTI

Thanks for your interest in snapMULTI! Whether you're fixing a bug, adding a feature, improving docs, or just sharing your setup — every contribution matters.

## Quick Links

- [Issues](https://github.com/lollonet/snapMULTI/issues) — Bug reports and feature requests
- [Discussions](https://github.com/lollonet/snapMULTI/discussions) — Questions, ideas, show your setup
- [Security](SECURITY.md) — Report vulnerabilities privately

## How to Contribute

### Report a Bug

Use the [Bug Report template](https://github.com/lollonet/snapMULTI/issues/new?template=bug_report.yml). Include:

- Your hardware (Pi model, x86_64, etc.)
- Output of `docker compose ps` and `docker compose logs <service>`
- Steps to reproduce the issue

### Suggest a Feature

Use the [Feature Request template](https://github.com/lollonet/snapMULTI/issues/new?template=feature_request.yml). Describe what you want, why it's useful, and any alternatives you've considered.

### Submit Code

1. **Fork** the repo and create a branch from `main`:
   ```bash
   git checkout -b feature/my-improvement
   ```

2. **Make your changes** — keep commits focused and atomic.

3. **Test locally:**
   ```bash
   # Shell scripts: lint with shellcheck
   shellcheck scripts/*.sh scripts/**/*.sh

   # Docker: verify compose syntax
   docker compose config --quiet

   # Full stack: build and run
   docker compose build
   docker compose up -d
   docker compose ps   # all containers should be healthy
   ```

4. **Open a Pull Request** against `main`. CI will run automatically:
   - `validate.yml` — shellcheck + docker-compose syntax
   - `build-test.yml` — Docker build validation (no push)

### Improve Documentation

Documentation lives in:

| File | Content |
|------|---------|
| `README.md` | What it does, how to install, how to connect |
| `docs/SOURCES.md` | Audio source types, parameters, JSON-RPC API |
| `docs/USAGE.md` | Architecture, services, deployment, CI/CD |
| `docs/HARDWARE.md` | Hardware requirements, network, recommended setups |

Italian translations (`*.it.md`) mirror the English docs. If you update English docs, note it in your PR so translations can be synced.

### Share Your Setup

Post in [GitHub Discussions — Show Your Setup](https://github.com/lollonet/snapMULTI/discussions). We love seeing how people use snapMULTI — photos of your speaker setup, custom configs, Home Assistant integrations, or creative audio routing.

## Code Conventions

### Shell Scripts

- **Safety first**: all scripts start with `set -euo pipefail`
- **Lint**: must pass `shellcheck -S warning`
- **Logging**: use `scripts/common/logging.sh` functions (`info`, `warn`, `error`)
- **Console output**: ASCII-only for `/dev/tty1` — PSF fonts lack Unicode symbols

### Docker

- **Base images**: pin specific versions (e.g., `alpine:3.23`, not `alpine:latest`)
- **Security**: read-only root filesystem, drop all capabilities, no-new-privileges
- **Health checks**: every container must have a health check
- **Multi-arch**: support both `linux/amd64` and `linux/arm64`

### Configuration

- **Audio format**: 44100:16:2 (44.1kHz, 16-bit, stereo) — don't change without discussion
- **Config files**: all in `config/`, all scripts in `scripts/`
- **Environment**: use `.env` for user-configurable values, document in `.env.example`

### Documentation

Follow the [Single Source of Truth](CLAUDE.md) principle — each topic has ONE authoritative file. Don't duplicate content across docs.

### Commits

- Write clear commit messages explaining **why**, not just what
- Reference related issues: `Fix audio dropout on Pi 3 (#42)`
- Keep commits focused — one logical change per commit

## Development Setup

```bash
# Clone with submodules (includes client repo)
git clone --recurse-submodules https://github.com/lollonet/snapMULTI.git
cd snapMULTI

# Copy environment template
cp .env.example .env
# Edit .env with your local paths

# Start the stack
docker compose up -d

# Watch logs
docker compose logs -f
```

## Getting Help

- **Questions?** Open a [Discussion](https://github.com/lollonet/snapMULTI/discussions)
- **Bug?** File an [Issue](https://github.com/lollonet/snapMULTI/issues)
- **Security concern?** See [SECURITY.md](SECURITY.md)

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
