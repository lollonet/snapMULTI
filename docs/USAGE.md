🇬🇧 **English** | 🇮🇹 [Italiano](USAGE.it.md)

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
└────────▲────────┘                       │
         │                                ▼
┌─────────────────┐              ┌──────────────────┐
│ Docker: myMPD   │              │                  │
│ (localhost:8180)│  ┌──────────▶│ Docker: Snapcast │
└─────────────────┘  │          │ (port 1704)      │
                     │          │                  │
┌─────────────────┐  │          │ Sources:         │
│ TCP Input       │──┘   ┌─────▶│  - MPD (FIFO)    │
│ (port 4953)     │      │      │  - TCP-Input     │
└────────▲────────┘      │      │  - AirPlay       │
         │               │      │  - Spotify       │
┌─────────────────┐      │      │                  │
│ AirPlay         │──────┘  ┌──▶│                  │
│ (shairport-sync)│         │   └────────┬─────────┘
└─────────────────┘         │            │
                            │  ┌─────────┼─────────────┐
┌─────────────────┐         │  ▼         ▼             ▼
│ Spotify Connect │─────────┘ ┌────────┐ ┌────────┐ ┌────────┐
│ (librespot)     │           │Client 1│ │Client 2│ │Client 3│
└─────────────────┘           │(Snap)  │ │(Snap)  │ │(Snap)  │
                              └────────┘ └────────┘ └────────┘
┌─────────────────┐
│ Tidal           │───────────────┘ (via TCP Input)
│ (tidal-bridge)  │
└─────────────────┘
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
- Buffer: 2400ms (chunk_ms: 40)

### myMPD

| Port | Protocol | Purpose |
|------|----------|---------|
| 8180 | HTTP | Web UI (PWA, mobile-ready) |

**Configuration**: environment variables in `docker-compose.yml`
- Connects to MPD at `localhost:6600`
- SSL disabled (local network)
- Data: `mympd/workdir/`, cache: `mympd/cachedir/`

### MPD

| Port | Protocol | Purpose |
|------|----------|---------|
| 6600 | TCP | MPD protocol (client control) |
| 8000 | HTTP | Audio stream (direct access) |

**Configuration**: `config/mpd.conf`
- Output: FIFO to `/audio/snapcast_fifo`
- Music directory: `/music` (mapped to `MUSIC_PATH` on host)
- Database: `/data/mpd.db`

## Control MPD

### Using myMPD (Web UI — Recommended)

Open `http://<server-ip>:8180` in any browser. myMPD is a full-featured PWA that works on desktop and mobile — browse your library, manage playlists, control playback, and view album art.

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

Three containers need mDNS for service discovery: **snapserver** (Snapcast client discovery), **shairport-sync** (AirPlay advertisement), and **librespot** (Spotify Connect advertisement). All three use the host's Avahi daemon via D-Bus — no Avahi runs inside containers.

Required docker-compose settings:

```yaml
network_mode: host                    # Required for mDNS broadcasts
security_opt:
  - apparmor:unconfined               # Required for D-Bus access (AppArmor blocks it otherwise)
volumes:
  - /run/dbus/system_bus_socket:/run/dbus/system_bus_socket  # Host's Avahi
```

All three containers (snapserver, shairport-sync, librespot) need all three settings above.

**Host requirement**: `avahi-daemon` must be running on the host (`systemctl status avahi-daemon`).

**Do NOT run `avahi-daemon` inside containers** — it will conflict with the host's Avahi on port 5353.

**Note on librespot**: The image is built from source with the `with-avahi` Zeroconf backend (instead of the default `libmdns`). This avoids requiring IPv6 socket support on the host — `libmdns` fails on systems with `ipv6.disable=1`.

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
2. Check host Avahi: `systemctl status avahi-daemon`
3. Check logs: `docker logs snapserver | grep -i "avahi"`
4. Test direct connection: `snapclient --host <server_ip>`
5. Allow firewall ports (see [HARDWARE.md — Firewall Rules](HARDWARE.md#firewall-rules))

**AirPlay not visible:**
1. Check logs: `docker logs shairport-sync | grep -i "avahi\|dbus\|fatal"`
2. Verify D-Bus socket mount: `docker exec shairport-sync ls -la /run/dbus/system_bus_socket`

**Spotify Connect not visible:**
1. Check logs: `docker logs librespot | grep -i "discovery\|avahi\|error"`
2. Verify D-Bus socket mount: `docker exec librespot ls -la /run/dbus/system_bus_socket`
3. If `Address family not supported` error: librespot was built without Avahi backend — rebuild image

**Common errors:**
- `"Failed to create client: Access denied"` → Missing `security_opt: [apparmor:unconfined]` (snapserver)
- `"couldn't create avahi client: Daemon not running!"` → Missing D-Bus socket mount or host avahi-daemon not running
- `"Address family not supported by protocol"` → librespot using `libmdns` on host with IPv6 disabled — need Avahi backend
- `"Avahi already running"` → Remove `avahi-daemon` from container command
- No services found → Check `network_mode: host` is set

### Resources

- [Snapcast mDNS Setup](https://github.com/badaix/snapcast/wiki/Client-server-communication)
- [Server Configuration](https://github.com/badaix/snapcast/blob/develop/server/snapserver.conf)

## Deployment

### Automated Deployment (Recommended)

Pushing a version tag (e.g. `git tag v1.1.0 && git push origin v1.1.0`) triggers the full CI/CD pipeline:

1. **Build** — Docker images built on self-hosted runner (amd64 native + arm64 via QEMU cross-compilation)
2. **Manifest** — Per-arch images combined into multi-arch `:latest` tags on ghcr.io
3. **Deploy** — Images pulled and all five containers (`snapserver`, `shairport-sync`, `librespot`, `mpd`, `mympd`) restarted on the home server via SSH

```
tag v* → build-push.yml → build (amd64 + arm64) → manifest (:latest + :version) → deploy.yml → server updated
```

### Automated Deployment (Fresh Install)

```bash
git clone https://github.com/lollonet/snapMULTI.git
cd snapMULTI
sudo ./deploy.sh
```

`deploy.sh` handles everything: installs Docker if needed, creates directories, **auto-detects your music library** (scans `/media/*`, `/mnt/*`, `~/Music`), generates `.env`, pulls images, and starts services. Fully non-interactive.

If no music library is detected, the script falls back to `MUSIC_PATH=/media/music` and warns the user. You must mount your music there or edit `.env` manually before MPD can access it.

### Manual Deployment

```bash
cd /path/to/snapMULTI
docker compose pull
docker compose up -d
```

### CI/CD Workflows

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| **Build & Push** | Tag push (`v*`) | Build 5 multi-arch images (amd64 + arm64), push to ghcr.io, trigger deploy |
| **Deploy** | Called by Build & Push | Pull images and restart all containers (snapserver, shairport-sync, librespot, mpd, mympd) on server via SSH |
| **Validate** | Push to any branch, pull requests | Check docker-compose syntax and environment template |
| **Build Test** | Pull requests | Validate Docker images build correctly (no push) |

### Container Registry

Docker images are hosted on GitHub Container Registry:

| Image | Description |
|-------|-------------|
| `ghcr.io/lollonet/snapmulti-server:latest` | Snapcast server (built from [santcasp](https://github.com/lollonet/santcasp)) |
| `ghcr.io/lollonet/snapmulti-airplay:latest` | AirPlay receiver (shairport-sync) |
| `ghcr.io/lollonet/snapmulti-spotify:latest` | Spotify Connect (librespot) |
| `ghcr.io/lollonet/snapmulti-mpd:latest` | Music Player Daemon |
| `ghcr.io/lollonet/snapmulti-tidal:latest` | Tidal streaming bridge (tidalapi + ffmpeg) |

All images support `linux/amd64` and `linux/arm64` architectures.

See GitHub Actions tab for workflow status and logs.

## Configuration Reference

### docker-compose.yml

Defines all services with pre-built images and host networking for mDNS. Each audio source runs in its own container, communicating via named pipes in the shared `/audio` volume:

```yaml
services:
  snapserver:
    image: ghcr.io/lollonet/snapmulti-server:latest
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

  shairport-sync:
    image: ghcr.io/lollonet/snapmulti-airplay:latest
    container_name: shairport-sync
    restart: unless-stopped
    network_mode: host
    security_opt:
      - apparmor:unconfined
    user: "${PUID:-1000}:${PGID:-1000}"
    volumes:
      - ./audio:/audio
      - /run/dbus/system_bus_socket:/run/dbus/system_bus_socket
    environment:
      - TZ=${TZ:-Europe/Berlin}
    depends_on:
      - snapserver

  librespot:
    image: ghcr.io/lollonet/snapmulti-spotify:latest
    container_name: librespot
    restart: unless-stopped
    network_mode: host
    security_opt:
      - apparmor:unconfined
    user: "${PUID:-1000}:${PGID:-1000}"
    volumes:
      - ./audio:/audio
      - /run/dbus/system_bus_socket:/run/dbus/system_bus_socket
    environment:
      - TZ=${TZ:-Europe/Berlin}
    depends_on:
      - snapserver

  mympd:
    image: ghcr.io/jcorporation/mympd/mympd:latest
    container_name: mympd
    restart: unless-stopped
    network_mode: host
    user: "${PUID:-1000}:${PGID:-1000}"
    volumes:
      - ./mympd/workdir:/var/lib/mympd
      - ./mympd/cachedir:/var/cache/mympd
      - ${MUSIC_PATH:-/media/music}:/music:ro
      - ./mpd/playlists:/playlists:ro
    environment:
      - TZ=${TZ:-Europe/Berlin}
      - MYMPD_HTTP_PORT=8180
      - MYMPD_SSL=false

  mpd:
    image: ghcr.io/lollonet/snapmulti-mpd:latest
    container_name: mpd
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./audio:/audio
      - ${MUSIC_PATH:-/media/music}:/music:ro
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
  --network host \
  --device /dev/snd \
  ghcr.io/badaix/snapcast:latest snapclient
```

**Browser as client** (MPD HTTP stream only):
```
http://<server-ip>:8000
```
