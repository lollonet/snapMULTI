# Usage & Operations Guide

Technical reference for snapMULTI — architecture, services, MPD control, autodiscovery, deployment, and configuration.

For audio source types and JSON-RPC API, see [SOURCES.md](SOURCES.md).

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

## Services & Ports

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
2. Configure connection to `<server-ip>:6600`
3. Browse and play music

**Other clients**:
- **ncmpcpp**: Terminal-based client
- **Ario**: Qt-based client
- **GMPC**: Gnome Music Player Client

### Using Mobile Apps

- **MPDroid** (Android)
- **MPD Remote** (iOS)
- Connect to `<server-ip>:6600`

### Update MPD Database

```bash
# Trigger database update
printf 'update\n' | nc localhost 6600

# Check update progress
printf 'status\n' | nc localhost 6600 | grep updating_db
```

## Switch Audio Sources

```bash
# List available streams
curl -s http://<server-ip>:1780/jsonrpc \
  -d '{"id":1,"jsonrpc":"2.0","method":"Server.GetStatus"}' | jq '.result.server.streams'

# Switch a group to a different stream
curl -s http://<server-ip>:1780/jsonrpc \
  -d '{"id":1,"jsonrpc":"2.0","method":"Group.SetStream","params":{"id":"<GROUP_ID>","stream_id":"Spotify"}}'
```

For the full JSON-RPC API reference, see [SOURCES.md — JSON-RPC API](SOURCES.md#json-rpc-api-reference).

## Autodiscovery (mDNS)

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

**Do NOT run `avahi-daemon` inside container** — it will conflict with host's Avahi on port 5353.

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

## Configuration Reference

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

### Snapclient Connection Options

**Automatic discovery** (recommended):
```bash
snapclient
```

**Manual connection**:
```bash
snapclient --host <server-ip>
snapclient --host <server-ip> --port 1704
```

**List available sound cards**:
```bash
snapclient --list
```

**Run as daemon**:
```bash
snapclient --host <server-ip> --daemon
```

**Using Docker**:
```bash
docker run -d --name snapclient \
  --device /dev/snd \
  sweisgerber/snapcast:latest
```

**Browser as client** (MPD HTTP stream only):
```
http://<server-ip>:8000
```
