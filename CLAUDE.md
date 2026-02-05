# snapMULTI — Project Instructions

## Documentation SSOT (Single Source of Truth)

Each topic has ONE authoritative document. Other files link to it — never duplicate content.
Italian translations (`*.it.md`) mirror the English docs and must stay in sync.

| Topic | Owner |
|-------|-------|
| Audio sources, params, schema, JSON-RPC API | `docs/SOURCES.md` |
| Architecture, services, ports, mDNS, CI/CD | `docs/USAGE.md` |
| Hardware, network, recommended setups | `docs/HARDWARE.md` |
| User quickstart, client basic setup | `README.md` |
| Changelog | `CHANGELOG.md` |
| Source config (inline comments) | `config/snapserver.conf` |

**Rules:**
- README is an appliance manual — what it does, how to install, how to connect. No jargon.
- New source type → update `docs/SOURCES.md` + `config/snapserver.conf` + `README.md` source table
- Source param changes → `docs/SOURCES.md` only
- Services/ports/CI changes → `docs/USAGE.md` only
- Hardware/network changes → `docs/HARDWARE.md` only
- README links to docs/ for anything technical — never inline technical details

## Project Structure

```
snapMULTI/
  config/
    snapserver.conf          # Snapcast server config (4 active + 4 commented sources)
    mpd.conf                 # MPD config (FIFO + HTTP outputs)
    shairport-sync.conf      # shairport-sync pipe backend config
  scripts/
    deploy.sh                # Server deployment (profiles, FIFO setup, validation)
    firstboot.sh             # First-boot provisioning (network wait, healthcheck loop)
    airplay-entrypoint.sh    # AirPlay container entrypoint (DEVICE_NAME sanitization)
    prepare-sd.sh            # SD card preparation for new clients
    tidal-bridge.py          # Tidal Connect → TCP bridge
  docs/
    HARDWARE.md              # Hardware & network guide
    USAGE.md                 # Technical operations guide
    SOURCES.md               # Audio sources technical reference
    *.it.md                  # Italian translations
  .github/workflows/
    build-push.yml           # Dual-arch build + push to ghcr.io (5 images)
    deploy.yml               # SSH deploy (workflow_call, 6 containers)
    build-test.yml           # PR-only Docker build validation (5 Dockerfiles)
    validate.yml             # docker-compose syntax, shellcheck, env template
    claude-code-review.yml   # Automated PR review
  mympd/
    workdir/                 # myMPD persistent data
    cachedir/                # myMPD cache (album art, etc.)
  Dockerfile.snapserver      # Snapserver (from lollonet/santcasp, multi-stage)
  Dockerfile.shairport-sync  # AirPlay receiver (pipe output)
  Dockerfile.librespot       # Spotify Connect (pipe output)
  Dockerfile.mpd             # MPD + ffmpeg (Alpine)
  Dockerfile.tidal           # Tidal Connect bridge
  docker-compose.yml         # 6 services (host networking)
  .env.example               # Environment template
```

## Conventions

- **Docker images**: `ghcr.io/lollonet/snapmulti-{server,airplay,spotify,mpd,tidal}:latest`
- **Multi-arch**: linux/amd64 (raspy) + linux/arm64 (studio), native builds on self-hosted runners
- **Config paths**: all config in `config/`, all scripts in `scripts/`
- **Deployment**: tag push (`v*`) triggers build → manifest → deploy
- **Git workflow**: always use PRs, never push directly to main unless explicitly requested
- **Audio format**: 44100:16:2 (44.1kHz, 16-bit, stereo) across all sources
- **CI gates**: shellcheck on all `scripts/*.sh`, docker-compose syntax validation
