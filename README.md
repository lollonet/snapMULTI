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
- **Architecture**: Both services run in Docker containers with host networking (Alpine Linux)
- **Music Library**: Configured via environment variables (see `.env.example`)

## Multi-Source Audio Support

Snapcast is configured with **four audio sources** that clients can choose from:

| Source | Description | Stream ID | Use Case |
|--------|-------------|-----------|----------|
| **MPD** | Local music library | `MPD` | Default - plays your local music collection |
| **TCP** | Network audio input | `TCP-Input` | Stream from any app via TCP (port 4953) |
| **AirPlay** | Apple devices | `AirPlay` | Stream from iPhone/iPad/Mac via AirPlay |
| **Spotify** | Spotify Connect | `Spotify` | Stream from Spotify app (requires Premium) |

### Source Details

#### 1. MPD (Default - Local Music Library)

**Plays your local music collection** controlled via MPD.

**Control MPD using:**
```bash
# Command line
mpc play                    # Start playback
mpc add "Artist/Album"      # Add album to queue
mpc volume 50               # Set volume

# Desktop clients
cantata                    # Qt-based client (recommended)
ncmpcpp                    # Terminal-based client

# Mobile apps
MPDroid (Android)          # Free, open-source
MPD Remote (iOS)           # Paid, full-featured
```

**Connect to MPD:** `192.168.63.3:6600`

#### 2. TCP Input (Stream from Any App)

**Any application can stream audio** to port 4953.

**Example usage:**
```bash
# Stream internet radio
ffmpeg -i http://stream.example.com/radio \
  -f s16le -ar 48000 -ac 2 \
  tcp://192.168.63.3:4953

# Stream from file
ffmpeg -i music.mp3 \
  -f s16le -ar 48000 -ac 2 \
  tcp://192.168.63.3:4953

# Stream from URL
ffmpeg -re -i http://example.com/stream.mp3 \
  -f s16le -ar 48000 -ac 2 \
  tcp://192.168.63.3:4953
```

**Audio format required:**
- Sample rate: 48000 Hz
- Bit depth: 16 bit
- Channels: 2 (stereo)
- Format: Raw PCM (s16le)

#### 3. AirPlay (Apple Devices)

**Stream from iPhone, iPad, or Mac** using AirPlay.

**Connect from iOS:**
1. Open **Control Center** on iPhone/iPad
2. Tap **AirPlay** icon
3. Select **"snapMULTI"** from the list
4. Play music from Apple Music, Spotify, YouTube, etc.

**Verify AirPlay is visible:**
```bash
avahi-browse -r _raop._tcp --terminate
```

Should show "snapMULTI" as an available AirPlay receiver.

#### 4. Spotify Connect (Spotify Premium)

**Stream from the Spotify app** on any device.

**Connect from Spotify:**
1. Open **Spotify** on phone, tablet, or desktop
2. Start playing a song
3. Tap the **Connect to a device** icon
4. Select **"snapMULTI"** from the list

**Requirements:**
- Spotify Premium account (free tier not supported by librespot)
- Bitrate: 320 kbps (highest quality)

### How Stream Selection Works

**By default**, all clients play from the **MPD** source.

**To switch sources**, use the Snapcast JSON-RPC API:

```bash
# Get available streams
curl -s http://192.168.63.3:1780/jsonrpc \
  -H "Content-Type: application/json" \
  -d '{"id":1,"jsonrpc":"2.0","method":"Server.GetStatus"}' \
  | jq '.result.streams'

# Switch a group to a different stream
curl -s http://192.168.63.3:1780/jsonrpc \
  -H "Content-Type: application/json" \
  -d '{
    "id":1,
    "jsonrpc":"2.0",
    "method":"Group.SetStream",
    "params":{
      "id":"<GROUP_ID>",
      "stream_id":"TCP-Input"
    }
  }'
```

**Stream IDs:** `MPD`, `TCP-Input`, `AirPlay`, `Spotify`

### Troubleshooting

#### AirPlay not visible on iOS
```bash
# Verify shairport-sync is installed
docker exec snapserver which shairport-sync

# Check if shairport-sync is running
docker exec snapserver ps aux | grep shairport

# Verify mDNS service is published
avahi-browse -r _raop._tcp --terminate
```

#### TCP stream not receiving audio
```bash
# Check if port 4953 is listening
ss -tlnp | grep 4953

# Test with example stream
ffmpeg -f lavfi -i anullsrc=r=48000:cl=stereo \
  -f s16le -ar 48000 -ac 2 \
  tcp://localhost:4953
```

#### MPD not playing
```bash
# Check MPD status
mpc status

# Update MPD database
printf 'update\n' | nc localhost 6600

# Check FIFO pipe exists
ls -la /audio/snapcast_fifo
```

### Configuration

All four sources are configured in `snapserver.conf`:

```ini
[stream]
# Source 1: MPD (local music library)
source = pipe:////audio/snapcast_fifo?name=MPD

# Source 2: TCP input (any app)
source = tcp://0.0.0.0:4953?name=TCP-Input&mode=server

# Source 3: AirPlay (Apple devices)
source = airplay:///usr/bin/shairport-sync?name=AirPlay&devicename=snapMULTI

# Source 4: Spotify Connect (requires Premium)
source = librespot:///usr/bin/librespot?name=Spotify&devicename=snapMULTI&bitrate=320

# Common settings
sampleformat = 48000:16:2
codec = flac
buffer = 1000
```

To add more sources, simply add additional `source =` lines to the `[stream]` section.

**AirPlay service not visible on iOS:**
```bash
# Verify shairport-sync is installed
docker exec snapserver which shairport-sync

# Check if Snapserver launched shairport-sync
docker logs snapserver | grep -i airplay

# Verify mDNS service is published
avahi-browse -r _raop._tcp --terminate
```

**No audio from AirPlay:**
- Verify snapserver.conf has AirPlay source configured (not MPD)
- Check `docker logs snapserver` for "AirPlay" state changes
- Ensure iPhone volume is up and not muted
- Verify music is actually playing on iPhone (play button, timer moving)

**Configuration error after editing:**
```bash
# Check syntax
docker compose config

# View logs
docker logs snapserver | tail -50

# Revert config to last committed version if needed
git checkout config/snapserver.conf
docker compose restart snapmulti
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
