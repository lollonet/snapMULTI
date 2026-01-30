# snapMULTI - Multiroom Audio Server

[![CI/CD](https://github.com/lollonet/snapMULTI/actions/workflows/deploy.yml/badge.svg)](https://github.com/lollonet/snapMULTI/actions/workflows/deploy.yml)
[![SnapForge](https://img.shields.io/badge/part%20of-SnapForge-blue)](https://github.com/lollonet/snapforge)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Multiroom audio streaming server using Snapcast with four audio sources: MPD, TCP input, AirPlay, and Spotify Connect. Serves synchronized audio to multiple clients on the local network. Pre-built multi-arch Docker images (amd64 + arm64) available on GitHub Container Registry.

## Overview

- **Snapserver**: Audio streaming server that distributes synchronized audio to multiple clients
- **Multi-source support**: Four audio sources available - MPD, TCP input, AirPlay, and Spotify Connect
- **MPD**: Music Player Daemon that plays local audio files and outputs to Snapcast via FIFO
- **AirPlay**: Apple's proprietary wireless audio streaming protocol (via shairport-sync)
- **TCP input**: Stream audio from any application via TCP port 4953
- **Spotify Connect**: Stream from the Spotify app on any device (via librespot, requires Premium)
- **Autodiscovery**: mDNS/Bonjour services via Avahi (_snapcast._tcp, _snapcast-http._tcp, _raop._tcp)
- **Multi-arch images**: Pre-built Docker images for `linux/amd64` and `linux/arm64` on [ghcr.io](https://github.com/lollonet/snapMULTI/pkgs/container/snapmulti)
- **Extensible sources**: Additional source types available — ALSA capture, meta stream, file playback, TCP client (see [docs/SOURCES.md](docs/SOURCES.md))
- **Architecture**: Both services run in Docker containers with host networking (Alpine Linux)
- **Music Library**: Configured via environment variables (see `.env.example`)

## Audio Sources

Four active sources, plus four additional types ready to enable. All clients can switch sources at any time.

| Source | Stream ID | How to Connect |
|--------|-----------|----------------|
| **MPD** | `MPD` | MPD client (mpc, Cantata, MPDroid) → `<server-ip>:6600` |
| **TCP Input** | `TCP-Input` | Send PCM audio to `<server-ip>:4953` via ffmpeg or any app |
| **AirPlay** | `AirPlay` | iOS/macOS Control Center → AirPlay → "snapMULTI" |
| **Spotify** | `Spotify` | Spotify app → Connect to a device → "snapMULTI" (Premium required) |
| **Android / Tidal** | via TCP or AirPlay | See [Streaming from Android](docs/SOURCES.md#streaming-from-android) |

Additional source types (ALSA capture, meta stream, file playback, TCP client) are available as commented-out examples in `config/snapserver.conf`.

For full technical details, parameters, JSON-RPC API, and source type schema, see **[docs/SOURCES.md](docs/SOURCES.md)**.

### Switch Sources

```bash
# List available streams
curl -s http://<server-ip>:1780/jsonrpc \
  -d '{"id":1,"jsonrpc":"2.0","method":"Server.GetStatus"}' | jq '.result.server.streams'

# Switch a group to a different stream
curl -s http://<server-ip>:1780/jsonrpc \
  -d '{"id":1,"jsonrpc":"2.0","method":"Group.SetStream","params":{"id":"<GROUP_ID>","stream_id":"Spotify"}}'
```

## Architecture

```
┌─────────────────┐
│  Music Library  │
│  (host paths)   │
└────────┬────────┘
         │
         ▼
┌─────────────────┐     ┌──────────────┐
│  Docker: MPD    │────▶│ /audio/fifo  │──┐
│ (localhost:6600)│     └──────────────┘  │
└─────────────────┘                       │
                                          ▼
┌─────────────────┐              ┌──────────────────┐
│ TCP Input       │─────────────▶│                  │
│ (port 4953)     │              │ Docker: Snapcast │
└─────────────────┘              │ (port 1704)      │
                                 │                  │
┌─────────────────┐              │ Sources:         │
│ AirPlay         │─────────────▶│  - MPD (FIFO)    │
│ (shairport-sync)│              │  - TCP-Input     │
└─────────────────┘              │  - AirPlay       │
                                 │  - Spotify       │
┌─────────────────┐              │                  │
│ Spotify Connect │─────────────▶│                  │
│ (librespot)     │              └────────┬─────────┘
└─────────────────┘                       │
                            ┌─────────────┼─────────────┐
                            ▼             ▼             ▼
                       ┌────────┐    ┌────────┐   ┌────────┐
                       │Client 1│    │Client 2│   │Client 3│
                       │(Snap)  │    │(Snap)  │   │(Snap)  │
                       └────────┘    └────────┘   └────────┘
```

## Quick Start

### Prerequisites

- Docker and Docker Compose installed
- Host directories with music files
- Ports available: 1704, 1705, 1780, 4953, 6600, 8000
- Supported platforms: `linux/amd64`, `linux/arm64` — pre-built images pulled from ghcr.io

### Configuration

1. Copy the example environment file:
```bash
cp .env.example .env
```

2. Edit `.env` with your settings:
```bash
# Music library paths (host)
MUSIC_LOSSLESS_PATH=/path/to/your/music/Lossless
MUSIC_LOSSY_PATH=/path/to/your/music/Lossy

# Timezone
TZ=Your/Timezone

# User/Group for container processes (match your host user)
PUID=1000
PGID=1000
```

3. (Optional) Adjust `max_clients` in `config/snapserver.conf` to limit connections (default: unlimited)

### Start Services

```bash
docker compose up -d
```

### Check Status

```bash
# Check containers
docker ps

# Check Snapserver logs
docker logs snapserver

# Check MPD logs
docker logs mpd
```

### Update MPD Database

```bash
# Trigger database update
printf 'update\n' | nc localhost 6600

# Check update progress
printf 'status\n' | nc localhost 6600 | grep updating_db
```

## Autodiscovery

Snapcast uses **mDNS/Bonjour via Avahi** for automatic client discovery on the local network.

### Critical Requirements

Snapcast requires these docker-compose settings for mDNS:

```yaml
network_mode: host                    # Required for mDNS broadcasts
security_opt:
  - apparmor:unconfined               # CRITICAL: allows D-Bus socket access
user: "${PUID:-1000}:${PGID:-1000}"    # Required for D-Bus policy
volumes:
  - /run/dbus/system_bus_socket:/run/dbus/system_bus_socket  # Host's Avahi
```

**⚠️ Do NOT run `avahi-daemon` inside container** - it will conflict with host's Avahi on port 5353.

### Verification

```bash
# Check if Snapserver is publishing mDNS services
avahi-browse -r _snapcast._tcp --terminate

# Check container network mode
docker inspect snapserver | grep NetworkMode  # Should be "host"

# Check D-Bus socket access
docker exec snapserver ls -la /run/dbus/system_bus_socket

# Verify ports listening
ss -tlnp | grep -E "1704|1705|1780"
```

### Client Connection

**Automatic discovery** (recommended):
```bash
snapclient
```

**Manual connection**:
```bash
snapclient --host 192.168.63.3
snapclient --host 192.168.63.3 --port 1704
```

### Troubleshooting

**No mDNS services visible:**
1. Verify docker-compose has all critical requirements above
2. Check logs: `docker logs snapserver | grep -i "avahi"`
3. Test direct connection: `snapclient --host <server_ip>`
4. Allow firewall ports: `sudo ufw allow 1704/tcp 1705/tcp 1780/tcp 5353/udp`

**Common errors:**
- `"Failed to create client: Access denied"` → Missing `security_opt: [apparmor:unconfined]`
- `"Avahi already running"` → Remove `avahi-daemon` from container command
- No services found → Check `network_mode: host` is set

### Resources

- [Snapcast mDNS Setup](https://github.com/badaix/snapcast/wiki/Client-server-communication)
- [Server Configuration](https://github.com/badaix/snapcast/blob/develop/server/snapserver.conf)

## Deployment

### Automated Deployment (Recommended)

Push to `main` branch triggers the full CI/CD pipeline:

1. **Build** — Multi-arch Docker images built natively on two self-hosted runners (amd64 + arm64)
2. **Manifest** — Per-arch images merged into multi-arch `:latest` tags on ghcr.io
3. **Deploy** — Images pulled and containers restarted on the home server via SSH

```
push to main → build-push.yml → build (amd64 + arm64) → manifest → deploy.yml → server updated
```

### Manual Deployment

```bash
cd /home/claudio/Code/snapMULTI
docker compose pull
docker compose up -d
```

### CI/CD Workflows

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| **Build & Push** | Push to `main` | Build multi-arch images, push to ghcr.io, trigger deploy |
| **Deploy** | Called by Build & Push | Pull images and restart containers on server via SSH |
| **Validate** | Push to any branch, pull requests | Check docker-compose syntax and environment template |
| **Build Test** | Pull requests | Validate Docker images build correctly (no push) |

### Container Registry

Docker images are hosted on GitHub Container Registry:

| Image | Description |
|-------|-------------|
| `ghcr.io/lollonet/snapmulti:latest` | Snapserver + shairport-sync + librespot |
| `ghcr.io/lollonet/snapmulti-mpd:latest` | Music Player Daemon |

Both images support `linux/amd64` and `linux/arm64` architectures.

See GitHub Actions tab for workflow status and logs.

## Services

### Snapserver

| Port | Protocol | Purpose |
|------|----------|---------|
| 1704 | TCP | Audio streaming to clients |
| 1705 | TCP | JSON-RPC control |
| 1780 | HTTP | Snapweb UI (not installed) |

**Configuration**: `config/snapserver.conf`
- Max clients: 0 (unlimited, adjust in config as needed)
- Codec: FLAC
- Sample format: 48000:16:2
- Buffer: 1000ms

### MPD

| Port | Protocol | Purpose |
|------|----------|---------|
| 6600 | TCP | MPD protocol (client control) |
| 8000 | HTTP | Audio stream (direct access) |

**Configuration**: `config/mpd.conf`
- Output: FIFO to `/audio/snapcast_fifo`
- Music directories: `/music/Lossless`, `/music/Lossy`
- Database: `/data/mpd.db`

## Control MPD

### Using mpc (Command Line)

```bash
# Install mpc
sudo apt install mpc

# Basic commands
mpc play                    # Start playback
mpc pause                   # Pause playback
mpc next                    # Next track
mpc prev                    # Previous track
mpc stop                    # Stop playback
mpc volume 50               # Set volume to 50%

# Browse library
mpc listall                 # List all songs (huge!)
mpc list artist             # List all artists
mpc list album "Artist"     # List albums by artist
mpc search title "song"     # Search for song

# Queue management
mpc add "Artist/Album"      # Add album to queue
mpc clear                   # Clear queue
mpc playlist                # Show current queue

# Status
mpc status                  # Show playback status
mpc current                 # Show current song
```

### Using Desktop Clients

**Cantata** (recommended):
1. Install: `sudo apt install cantata`
2. Configure connection to `192.168.63.3:6600`
3. Browse and play music

**Other clients**:
- **ncmpcpp**: Terminal-based client
- **Ario**: Qt-based client
- **GMPC**: Gnome Music Player Client

### Using Mobile Apps

- **MPDroid** (Android)
- **MPD Remote** (iOS)
- Connect to `192.168.63.3:6600`

## Connect Snapclients

Snapclient devices connect to the Snapserver to receive synchronized audio.

### Install Snapclient

**On Debian/Ubuntu**:
```bash
sudo apt install snapclient
```

**On Arch Linux**:
```bash
sudo pacman -S snapcast
```

**Using Docker**:
```bash
docker run -d --name snapclient \
  --device /dev/snd \
  sweisgerber/snapcast:latest
```

### Starting Snapclient

**Automatic connection** (discovers server on local network):
```bash
snapclient
```

**Manual IP configuration**:
```bash
snapclient --host 192.168.63.3
```

**Specify custom port**:
```bash
snapclient --host 192.168.63.3 --port 1704
```

**List available sound cards**:
```bash
snapclient --list
```

**Run as daemon**:
```bash
snapclient --host 192.168.63.3 --daemon
```

### Using Browser as Client

Access the MPD HTTP stream directly:
```
http://192.168.63.3:8000
```

## Configuration Files

### docker-compose.yml

Defines both services with pre-built ghcr.io images and host networking for mDNS:

```yaml
services:
  snapmulti:
    image: ghcr.io/lollonet/snapmulti:latest
    container_name: snapserver
    hostname: snapmulti
    restart: unless-stopped
    network_mode: host
    security_opt:
      - apparmor:unconfined
    user: "${PUID:-1000}:${PGID:-1000}"
    volumes:
      - ./config/snapserver.conf:/etc/snapserver.conf:ro
      - ./config:/config
      - ./data:/data
      - ./audio:/audio
      - /run/dbus/system_bus_socket:/run/dbus/system_bus_socket
    environment:
      - TZ=${TZ:-Europe/Berlin}
    command: ["snapserver", "-c", "/etc/snapserver.conf"]

  mpd:
    image: ghcr.io/lollonet/snapmulti-mpd:latest
    container_name: mpd
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./audio:/audio
      - ${MUSIC_LOSSLESS_PATH}:/music/Lossless:ro
      - ${MUSIC_LOSSY_PATH}:/music/Lossy:ro
      - ./config/mpd.conf:/etc/mpd.conf:ro
      - ./mpd/playlists:/playlists
      - ./mpd/data:/data
    environment:
      - TZ=${TZ:-Europe/Berlin}
```
