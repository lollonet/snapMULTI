# snapMULTI — Project Instructions

## Documentation SSOT (Single Source of Truth)

Each topic has ONE authoritative document. Other files link to it — never duplicate content.

| Topic | Owner | Notes |
|-------|-------|-------|
| Audio sources (config, params, schema, API) | `docs/SOURCES.md` | Technical reference for all source types |
| Android / Tidal streaming | `docs/SOURCES.md` | Setup guides for non-native casting |
| JSON-RPC API | `docs/SOURCES.md` | Stream management endpoints |
| Architecture, services, ports | `docs/USAGE.md` | System diagram, port tables, config details |
| MPD control (mpc, clients, apps) | `docs/USAGE.md` | Command-line and GUI client usage |
| Autodiscovery / mDNS | `docs/USAGE.md` | Docker requirements, troubleshooting |
| Deployment / CI/CD | `docs/USAGE.md` | Pipeline, workflows, container registry |
| docker-compose.yml reference | `docs/USAGE.md` | Full example with annotations |
| Snapclient advanced options | `docs/USAGE.md` | Daemon mode, Docker, sound cards, browser |
| User quickstart | `README.md` | How to get running (essential steps only) |
| Client basic setup | `README.md` | Install snapclient + connect (minimal) |
| Changelog | `CHANGELOG.md` | Historical log, not duplicated |
| Hardware requirements, network, setups | `docs/HARDWARE.md` | Server/client specs, Pi models, bandwidth, configs |
| Source config (inline) | `config/snapserver.conf` | Comments per-source, links to docs/ |

**Rules:**
- README is an appliance manual — what it does, how to install, how to connect. No jargon.
- When adding a new source type: update `docs/SOURCES.md` (full details) + `config/snapserver.conf` (commented example) + `README.md` source table (one-liner)
- When changing source parameters: update `docs/SOURCES.md` only
- When changing services, ports, deployment, mDNS: update `docs/USAGE.md` only
- When changing hardware specs, network, or recommended setups: update `docs/HARDWARE.md` only
- README links to docs/ for anything technical — never inline technical details

## Project Structure

```
snapMULTI/
  config/
    snapserver.conf      # Snapcast server config (4 active + 4 commented sources)
    mpd.conf             # MPD config (FIFO + HTTP outputs)
    shairport-sync.conf  # shairport-sync pipe backend config
  docs/
    HARDWARE.md          # Hardware & network guide (server/client specs, Pi, bandwidth, setups)
    USAGE.md             # Technical operations guide (architecture, services, MPD, mDNS, CI/CD)
    SOURCES.md           # Audio sources technical reference (SSOT for sources)
  .github/workflows/
    build-push.yml       # Native dual-arch build + push to ghcr.io (4 images)
    deploy.yml           # SSH deploy (workflow_call from build-push, 5 containers)
    build-test.yml       # PR-only build validation (4 Dockerfiles)
    validate.yml         # Config syntax validation
  mympd/
    workdir/             # myMPD persistent data
    cachedir/            # myMPD cache (album art, etc.)
  Dockerfile.snapserver  # Snapserver only (from lollonet/santcasp, multi-stage)
  Dockerfile.shairport-sync  # AirPlay receiver (pipe output)
  Dockerfile.librespot   # Spotify Connect (pipe output)
  Dockerfile.mpd         # MPD + ffmpeg (Alpine)
  docker-compose.yml     # 5 services (ghcr.io + myMPD images, host networking)
  .env.example           # Environment template
  .dockerignore          # Build context exclusions
  README.md              # Essential user guide (quickstart, connect, links to docs/)
  CHANGELOG.md           # Project history
```

## Conventions

- **Docker images**: `ghcr.io/lollonet/snapmulti-server:latest`, `ghcr.io/lollonet/snapmulti-airplay:latest`, `ghcr.io/lollonet/snapmulti-spotify:latest`, `ghcr.io/lollonet/snapmulti-mpd:latest`
- **Multi-arch**: linux/amd64 (raspy) + linux/arm64 (studio), native builds on self-hosted runners
- **Config paths**: all config in `config/` directory
- **Deployment**: tag push (`v*`) triggers build → manifest → deploy (never push directly to main without PR unless explicitly requested)
- **Audio format**: 44100:16:2 (44.1kHz, 16-bit, stereo) across all sources
