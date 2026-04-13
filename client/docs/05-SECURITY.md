# Security

## Threat Model

This is a **single-user embedded device on a trusted LAN** — not a public-facing server. The threat model focuses on:

1. **SD card corruption** from power loss (primary risk)
2. **Container escape** from compromised audio/display services
3. **Network injection** from metadata or artwork URLs
4. **Supply chain** via Docker image integrity

Threats explicitly out of scope:
- Physical access attacks (device is in the user's home)
- Attacks requiring control of the local MPD/Snapcast server
- DDoS or brute-force (no exposed authentication surfaces)

## Container Hardening

All three containers follow defense-in-depth:

| Control | snapclient | audio-visualizer | fb-display |
|---------|-----------|-----------------|-----------|
| `read_only: true` | ✅ Yes | ✅ Yes | ✅ Yes |
| `no-new-privileges` | ✅ Yes | ✅ Yes | ✅ Yes |
| `cap_drop: ALL` | ✅ Yes | ✅ Yes | ✅ Yes |
| Non-root (uid 1000) | ✅ Yes | ✅ Yes | ✅ Yes |
| `tmpfs` for writes | `/tmp:32M` | `/tmp:32M` | `/tmp:64M` |
| Resource limits | CPU + memory | CPU + memory | CPU + memory |

### Capabilities Added (minimum required)

| Container | Capabilities | Reason |
|-----------|-------------|--------|
| snapclient | `SYS_NICE`, `IPC_LOCK`, `SYS_RESOURCE` | Real-time audio scheduling |
| audio-visualizer | `SYS_NICE` | Audio capture priority |
| fb-display | (none) | Framebuffer accessed via group `video(44)` |

## Network Security

| Port | Binding | Protocol | Exposure |
|------|---------|----------|----------|
| 1704 | (outbound) | TCP | Client connects to server |
| 8081 | `127.0.0.1:8081` | WebSocket | Localhost only |
| 8082 | (outbound) | WebSocket | Client connects to server |
| 8083 | (outbound) | HTTP | Client connects to server |

No ports are exposed to the network. The visualizer WebSocket binds to localhost only.

## Input Validation

### Setup Scripts
- HAT selection validated against known list
- Resolution validated against allowed presets
- Snapserver IP validated as hostname or IP format
- Shell variables quoted to prevent injection

### Snapclient Entrypoint

- `ALSA_BUFFER_TIME`: numeric-only (case pattern `*[!0-9]*`), bounds-checked 50–2000, fallback to `150`
- `ALSA_FRAGMENTS`: numeric-only, bounds-checked 2–16, fallback to `4`
- `SNAPSERVER_PORT`: numeric-only, fallback to `1704`
- `MIXER`: mode prefix validated against allowlist (`software|hardware|none`); element suffix rejected if it contains shell metacharacters via `validate_string`
- `HOST_ID`, `SOUNDCARD`, `SNAPSERVER_HOST`: rejected if containing shell metacharacters (`` '"\$;& |><(){}[] ``)

### fb-display
- Artwork URLs: relative paths (`/artwork/...`) are resolved against `METADATA_HOST`; full URLs from the server are trusted (low risk — server is under user control on trusted LAN)
- WebSocket messages parsed with JSON decoder (no eval)
- Framebuffer dimensions bounds-checked

### Metadata
- `CLIENT_ID` used only for WebSocket subscription (not in filesystem or shell paths)
- Cover art fetched only from the configured metadata host

## Filesystem Security

### Read-Only Root (default)
- Root filesystem mounted read-only via overlayfs (enabled by default via `ENABLE_READONLY=true`)
- All writes go to RAM-backed tmpfs (lost on reboot)
- Docker uses `fuse-overlayfs` storage driver (kernel overlay2 fails on overlayfs root)
- `ro-mode.sh enable/disable/status` to manage

### Benefits
- SD card protected from write wear and corruption
- Power loss cannot corrupt the filesystem
- No persistent malware after reboot

## Supply Chain

- Docker images built in CI from known Dockerfiles
- Base images: `python:3.13-slim` (official), `alpine` (snapclient)
- Images published to Docker Hub (`lollonet/snapclient-pi-*`)
- Pre-push hook runs shellcheck on all shell scripts
- CI runs lint + tests on every PR