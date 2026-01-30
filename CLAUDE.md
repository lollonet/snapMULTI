# snapMULTI — Project Instructions

## Documentation SSOT (Single Source of Truth)

Each topic has ONE authoritative document. Other files link to it — never duplicate content.

| Topic | Owner | Notes |
|-------|-------|-------|
| Audio sources (config, params, schema, API) | `docs/SOURCES.md` | Technical reference for all source types |
| Android / Tidal streaming | `docs/SOURCES.md` | Setup guides for non-native casting |
| JSON-RPC API | `docs/SOURCES.md` | Stream management endpoints |
| User quickstart | `README.md` | How to get running, connect clients |
| MPD control (mpc, clients, apps) | `README.md` | User-facing usage guide |
| Snapclient setup | `README.md` | Client installation and connection |
| Autodiscovery / mDNS | `README.md` | Docker requirements, troubleshooting |
| Deployment / CI/CD | `README.md` | Pipeline, workflows, container registry |
| docker-compose.yml reference | `README.md` | Full example with annotations |
| Changelog | `CHANGELOG.md` | Historical log, not duplicated |
| Source config (inline) | `config/snapserver.conf` | Comments per-source, links to docs/ |

**Rules:**
- When adding a new source type: update `docs/SOURCES.md` (full details) + `config/snapserver.conf` (commented example) + `README.md` source table (one-liner)
- When changing source parameters: update `docs/SOURCES.md` only
- When changing deployment: update `README.md` only
- README audio section is a summary table + link to SOURCES.md — no detailed source configs or troubleshooting

## Project Structure

```
snapMULTI/
  config/
    snapserver.conf    # Snapcast server config (4 active + 4 commented sources)
    mpd.conf           # MPD config (FIFO + HTTP outputs)
  docs/
    SOURCES.md         # Audio sources technical reference (SSOT for sources)
  .github/workflows/
    build-push.yml     # Native dual-arch build + push to ghcr.io
    deploy.yml         # SSH deploy (workflow_call from build-push)
    build-test.yml     # PR-only build validation
    validate.yml       # Config syntax validation
  Dockerfile.snapMULTI # Snapserver + shairport-sync + librespot (Alpine)
  Dockerfile.mpd       # MPD + ffmpeg (Alpine)
  docker-compose.yml   # App services (ghcr.io images, host networking)
  .env.example         # Environment template
  .dockerignore        # Build context exclusions
  README.md            # User-facing docs (quickstart, clients, deployment)
  CHANGELOG.md         # Project history
```

## Conventions

- **Docker images**: `ghcr.io/lollonet/snapmulti:latest` and `ghcr.io/lollonet/snapmulti-mpd:latest`
- **Multi-arch**: linux/amd64 (raspy) + linux/arm64 (studio), native builds on self-hosted runners
- **Config paths**: all config in `config/` directory
- **Deployment**: push to main triggers build → manifest → deploy (never push directly to main without PR unless explicitly requested)
- **Audio format**: 48000:16:2 (48kHz, 16-bit, stereo) across all sources
