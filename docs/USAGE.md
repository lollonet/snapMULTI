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
┌─────────────────┐     ┌───────────────┐
│  Docker: MPD    │────▶│/audio/mpd_fifo│──┐
│ (localhost:6600)│     └───────────────┘  │
└────────▲────────┘                        │
         │                                 ▼
┌─────────────────┐              ┌──────────────────┐
│ Docker: myMPD   │              │                  │
│ (localhost:8180)│  ┌──────────▶│ Docker: Snapcast │
└─────────────────┘  │           │ (port 1704)      │
                     │           │                  │
┌─────────────────┐  │           │ Sources:         │
│ AirPlay         │──┘   ┌──────▶│  - MPD (FIFO)    │
│ (shairport-sync)│      │       │  - Tidal (FIFO)  │
└─────────────────┘      │       │  - AirPlay       │
                         │       │  - Spotify       │
┌─────────────────┐      │       │                  │
│ Spotify Connect │──────┘  ┌───▶│                  │
│ (go-librespot)  │         │    └────────┬─────────┘
└─────────────────┘         │             │
                            │             │
┌─────────────────┐         │  ┌─────────────────────┐
│ Tidal Connect   │─────────┘  │ Docker: Metadata    │
│ (ARM only)      │            │ (WS:8082, HTTP:8083)│
└─────────────────┘            │ cover art + track   │
                               │ info for clients    │
                               └──────────┬──────────┘
                                          │
                            ┌─────────────┼─────────────┐
                            ▼             ▼             ▼
                          ┌────────┐ ┌────────┐ ┌────────┐
                          │Client 1│ │Client 2│ │Client 3│
                          │(Snap)  │ │(Snap)  │ │(Snap)  │
                          └────────┘ └────────┘ └────────┘
```

## Audio Format (Sample Rate)

All audio sources use a unified sample format to ensure bit-perfect synchronization across clients:

| Parameter | Value | Description |
|-----------|-------|-------------|
| Sample rate | 44100 Hz | CD-quality audio (44.1 kHz) |
| Bit depth | 16-bit | Standard PCM resolution |
| Channels | 2 | Stereo |

**Format string**: `44100:16:2` (used in Snapcast configuration)

### Why 44.1 kHz?

- **CD standard**: Most music is mastered at 44.1 kHz
- **Universal compatibility**: All audio sources (MPD, Spotify, AirPlay) output at this rate
- **No resampling**: Avoids quality loss from sample rate conversion
- **Low latency**: Smaller buffers than 48 kHz for same chunk duration

### Audio Chain

```
Source → FIFO Pipe → Snapserver → Network → Snapclient → Sound Card
         (raw PCM)   (FLAC codec)  (1704/tcp)  (decode)    (PCM out)
```

All sources must output raw S16LE PCM at 44100:16:2 to the FIFO pipes. Snapserver encodes to FLAC for network transmission (lossless), and clients decode back to PCM.

### Codec Options

Snapserver supports multiple codecs (configured in `config/snapserver.conf`):

| Codec | Compression | Latency | Use Case |
|-------|-------------|---------|----------|
| **flac** (default) | Lossless | Low | Best quality, recommended |
| opus | Lossy | Very low | Limited bandwidth |
| ogg | Lossy | Low | Legacy clients |
| pcm | None | Lowest | LAN only, high bandwidth |

## Music Library

### Beginner Setup (SD card)

During `prepare-sd.sh`, choose your music source:

| Option | Config value | What happens on first boot |
|--------|-------------|---------------------------|
| Streaming only | `streaming` | Empty `/media/music` created, music scan skipped |
| USB drive | `usb` | `deploy.sh` auto-detects at `/media/*` |
| NFS share | `nfs` | Mounted read-only at `/media/nfs-music`, added to `/etc/fstab` |
| SMB share | `smb` | Mounted read-only at `/media/smb-music`, credentials in `/etc/snapmulti-smb-credentials` |
| Manual | `manual` | No auto-setup — configure after install |

### Advanced Setup

For manual NFS/SMB configuration after install:

**NFS** (Linux/Mac/NAS):
```bash
sudo apt install nfs-common
sudo mkdir -p /media/nfs-music
sudo mount -t nfs nas.local:/volume1/music /media/nfs-music -o ro,soft,timeo=50,_netdev
# Persist across reboots:
echo "nas.local:/volume1/music /media/nfs-music nfs ro,soft,timeo=50,_netdev 0 0" | sudo tee -a /etc/fstab
```

**SMB/CIFS** (Windows/NAS):
```bash
sudo apt install cifs-utils
sudo mkdir -p /media/smb-music
# Guest access:
sudo mount -t cifs //mynas/Music /media/smb-music -o ro,guest,_netdev,iocharset=utf8
# With credentials:
printf 'username=myuser\npassword=mypass\n' | sudo tee /etc/snapmulti-smb-credentials
sudo chmod 600 /etc/snapmulti-smb-credentials
sudo mount -t cifs //mynas/Music /media/smb-music -o ro,_netdev,iocharset=utf8,credentials=/etc/snapmulti-smb-credentials
```

Then update `.env`:
```bash
# Edit MUSIC_PATH in /opt/snapmulti/.env
MUSIC_PATH=/media/nfs-music   # or /media/smb-music
```

Restart MPD to pick up the new library:
```bash
cd /opt/snapmulti && docker compose restart mpd
```

### Troubleshooting Network Shares

| Problem | Cause | Fix |
|---------|-------|-----|
| `mount: permission denied` | NAS share not exported to Pi's IP | On NAS, add Pi's IP to allowed hosts for the share |
| `mount: wrong fs type` | Missing NFS/CIFS packages | `sudo apt install nfs-common` (NFS) or `sudo apt install cifs-utils` (SMB) |
| `mount: connection timed out` | Firewall blocking NFS/SMB | Allow port 2049 (NFS) or 445 (SMB) on your NAS/router |
| `mount: bad UNC` | Wrong SMB path format | Use `//hostname/ShareName` (forward slashes, case-sensitive) |
| myMPD shows empty library | MPD hasn't scanned yet | Run `printf 'update\n' \| nc localhost 6600` and wait for scan to complete |
| MPD scan takes very long | Large NFS library | Normal for first scan over NFS (each file requires a network call). Subsequent boots use the cached `mpd.db` |

## Network Mode

All snapMULTI containers use **host network mode** (`network_mode: host`). This is required for:

### mDNS / Autodiscovery

Avahi publishes services (AirPlay, Spotify Connect, Snapcast) via multicast DNS on port 5353. Bridge networking isolates containers from the host network, breaking mDNS broadcasts. Host mode allows containers to:

- Share the host's network namespace
- Use the host's Avahi daemon via D-Bus
- Broadcast mDNS services on all interfaces

### Low-Latency Audio

Audio streaming requires consistent, low-latency networking. Host mode eliminates:

- Docker's NAT translation overhead
- Port mapping delays
- Potential buffer bloat from virtual bridges

### Implications

1. **Port conflicts**: Services bind directly to host ports (1704, 1705, 1780, 2019, 5000, 5858, 6600, 8000, 8082, 8083, 8180)
2. **Firewall rules**: Must allow traffic on service ports (see [HARDWARE.md](HARDWARE.md))
3. **Single instance**: Cannot run multiple snapMULTI stacks on the same host

### Alternative: macvlan (Advanced)

For multi-instance deployments, macvlan networking assigns each container a unique IP address on the physical network. This requires:

- Router DHCP reservations
- Manual mDNS configuration
- More complex setup

Host mode is recommended for single-server deployments.

## Services & Ports

### Snapserver

| Port | Protocol | Purpose |
|------|----------|---------|
| 1704 | TCP | Audio streaming to clients |
| 1705 | TCP | JSON-RPC control |
| 1780 | HTTP | Snapweb UI + JSON-RPC API |
| 4953 | TCP | TCP audio input (ffmpeg/Android streaming) |

**Configuration**: `config/snapserver.conf`
- Max clients: 0 (unlimited, adjust in config as needed)
- Codec: FLAC
- Sample format: 44100:16:2
- Buffer: 2400ms (chunk_ms: 40)

### myMPD

| Port | Protocol | Purpose |
|------|----------|---------|
| 8180 | HTTP | Web UI (PWA, mobile-ready) |

**Configuration**: environment variables in `docker-compose.yml`
- Connects to MPD at `localhost:6600`
- SSL disabled (local network)
- Data: `mympd/workdir/`, cache: `mympd/cachedir/`

### Metadata Service

| Port | Protocol | Purpose |
|------|----------|---------|
| 8082 | WebSocket | Track metadata push (subscribe with CLIENT_ID) |
| 8083 | HTTP | Cover art files, metadata JSON, health check |

**Configuration**: environment variables (defaults to localhost for Snapserver/MPD connections)
- Polls Snapserver JSON-RPC every 2s for stream metadata
- Cover art chain: MPD embedded → iTunes → MusicBrainz → Radio-Browser
- Clients subscribe via WebSocket with `{"subscribe": "CLIENT_ID"}` to receive their stream's metadata
- Artwork served at `http://<server>:8083/artwork/<filename>`

### AirPlay (shairport-sync)

| Port | Protocol | Purpose |
|------|----------|---------|
| 5000 | TCP | RTSP (AirPlay session setup — must be LAN-reachable) |
| 5858 | HTTP | Cover art server (used by `meta_shairport.py` controlscript) |

### Spotify Connect (go-librespot)

| Port | Protocol | Purpose |
|------|----------|---------|
| 24879 | HTTP/WS | WebSocket API (used by `meta_go-librespot.py`, localhost only) |
| Random | TCP | Zeroconf discovery (ephemeral port, must be LAN-reachable) |

### Tidal Connect

| Port | Protocol | Purpose |
|------|----------|---------|
| 2019 | TCP | Tidal Connect discovery (ARM only, must be LAN-reachable) |

Metadata: `tidal-meta-bridge.sh` scrapes `speaker_controller_application`'s tmux TUI and writes JSON to `/audio/tidal-metadata.json` (shared Docker volume). The `meta_tidal.py` controlscript in snapserver polls this file.

> **Note:** Ports 5000, 5858, and the Spotify zeroconf port must be LAN-reachable for casting to work. Port 24879 binds to localhost only. If ufw is enabled, see [Firewall Rules](HARDWARE.md#firewall-rules) for the full list.

### MPD

| Port | Protocol | Purpose |
|------|----------|---------|
| 6600 | TCP | MPD protocol (client control) |
| 8000 | HTTP | Audio stream (direct access) |

**Configuration**: `config/mpd.conf`
- Output: FIFO to `/audio/mpd_fifo`
- Music directory: `/music` (mapped to `MUSIC_PATH` on host)
- Database: `/data/mpd.db`

## Systemd Units

After installation, systemd owns the container lifecycle (ADR-005). Docker's `restart: unless-stopped` handles individual container crashes; systemd handles boot-time bring-up.

| Unit | Install type | Purpose |
|------|-------------|---------|
| `snapmulti-server.service` | server, both | Starts server Docker Compose stack on boot |
| `snapclient.service` | client, both | Starts client Docker Compose stack on boot |
| `snapclient-discover.timer` | client, both | Re-discovers server via mDNS every 5 min |
| `snapclient-display.service` | client (display) | Detects HDMI and reconciles display containers |
| `snapmulti-boot-tune.service` | all | CPU governor, USB autosuspend, WiFi power save |

```bash
# Check status
systemctl status snapmulti-server.service
systemctl status snapclient.service

# Restart server stack
sudo systemctl restart snapmulti-server.service

# View logs
journalctl -u snapmulti-server.service --since "10 min ago"
```

In **both** mode, `snapclient.service` starts after `snapmulti-server.service` to ensure the server is ready before the client connects.

## Control Interfaces

snapMULTI has three control interfaces, each for a different purpose:

| Interface | Access | What it does |
|-----------|--------|-------------|
| **Snapweb** | `http://<server-ip>:1780` | Manage speakers: switch audio sources, adjust volume per room, group/ungroup speakers |
| **myMPD** | `http://<server-ip>:8180` | Browse and play your music library, manage playlists, view album art |
| **Snapcast app** | [Android](https://play.google.com/store/apps/details?id=de.badaix.snapcast) | Mobile speaker control — same features as Snapweb, from your phone |

**Which one do I need?**
- To **play music from your library** → open myMPD
- To **switch what a speaker plays** (e.g. from MPD to Spotify) → open Snapweb or the mobile app
- To **cast from Spotify/AirPlay/Tidal** → use those apps directly (they find snapMULTI automatically)

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

Three containers need mDNS for service discovery: **snapserver** (Snapcast client discovery), **shairport-sync** (AirPlay advertisement), and **go-librespot** (Spotify Connect advertisement). All three use the host's Avahi daemon via D-Bus — no Avahi runs inside containers.

Required docker-compose settings:

```yaml
network_mode: host                    # Required for mDNS broadcasts
security_opt:
  - apparmor:unconfined               # Required for D-Bus access (AppArmor blocks it otherwise)
volumes:
  - /run/dbus/system_bus_socket:/run/dbus/system_bus_socket  # Host's Avahi (snapserver, shairport-sync)
  # or
  - /var/run/dbus:/var/run/dbus       # Host's Avahi (go-librespot, tidal-connect)
```

All three containers (snapserver, shairport-sync, librespot) need host networking and D-Bus access.

**Host requirement**: `avahi-daemon` must be running on the host (`systemctl status avahi-daemon`).

**Do NOT run `avahi-daemon` inside containers** — it will conflict with the host's Avahi on port 5353.

**Note on go-librespot**: Zeroconf is configured via `zeroconf_backend: avahi` in `config/go-librespot.yml`. No build-time flags needed.

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
1. Check logs: `docker logs librespot | grep -i "zeroconf\|avahi\|error"`
2. Verify D-Bus access: `docker exec librespot ls -la /var/run/dbus/`
3. Verify config: `docker exec librespot cat /tmp/config.yml | grep zeroconf`

**Common errors:**
- `"Failed to create client: Access denied"` → Missing `security_opt: [apparmor:unconfined]` (snapserver)
- `"couldn't create avahi client: Daemon not running!"` → Missing D-Bus socket mount or host avahi-daemon not running
- `"Avahi already running"` → Remove `avahi-daemon` from container command
- No services found → Check `network_mode: host` is set

### Resources

- [Snapcast mDNS Setup](https://github.com/badaix/snapcast/wiki/Client-server-communication)
- [Server Configuration](https://github.com/badaix/snapcast/blob/develop/server/snapserver.conf)

## Deployment

### Deployment Methods

| Method | Audience | Hardware | What it does |
|--------|----------|----------|--------------|
| **Zero-touch SD** | Beginners | Raspberry Pi | Flash SD, insert, power on — fully automatic |
| **`deploy.sh`** | Advanced | Pi or x86_64 | Detects hardware, creates dirs, starts services |
| **Manual** | Advanced | Pi or x86_64 | Clone, edit `.env`, `docker compose up` |
| **CI/CD (tag push)** | Maintainers | N/A | Builds images, pushes to Docker Hub |

### Automated Build (tag push)

Pushing a version tag (e.g. `git tag v1.1.0 && git push origin v1.1.0`) triggers the CI pipeline:

1. **Build** — Docker images built on self-hosted runners (amd64 native + arm64 via QEMU)
2. **Manifest** — Per-arch images combined into multi-arch `:latest` tags on Docker Hub

```
tag v* → build-push.yml → build (amd64 + arm64) → manifest (:latest + :version)
                                                 → scan.yml → Trivy SARIF → GitHub Security tab
```

Devices get the new images on next reflash (`prepare-sd.sh` → `firstboot.sh` pulls `:latest`).

### Zero-Touch SD Card (Raspberry Pi)

Prepare an SD card that automatically installs snapMULTI on first boot. No SSH required.

For complete step-by-step instructions (Imager screenshots, SD card mount points, all three OS), see **[INSTALL.md](../docs/INSTALL.md)**.

**What happens on first boot:**
- Reads `install.conf` to determine install type (client/server/both)
- Waits for network (with WiFi regulatory domain fix for 5 GHz DFS channels)
- Copies project files from boot partition to `/opt/snapmulti` and/or `/opt/snapclient`
- Installs git, Docker, and system dependencies via APT
- Server: runs `deploy.sh` (hardware detection, music library scan, container deploy)
- Client: runs `setup.sh --auto` (audio HAT config, headless detection, container deploy)
- Shows full-screen progress TUI on HDMI (step checklist, progress bar, log output)
- Verifies containers healthy, then reboots

Installation log saved to `/var/log/snapmulti-install.log`.

**Supported OS versions:** Raspberry Pi OS Bookworm (recommended) and Bullseye. The script auto-detects the version and uses the correct boot paths (`/boot/firmware` vs `/boot`).

#### "Server + Player" (Both) Mode

When option 3 is selected, the Pi runs both the music server and a local audio player on the same device. The two stacks coexist without port conflicts:

| Component | Path | Networking | Ports |
|-----------|------|------------|-------|
| Server | `/opt/snapmulti/` | Host networking | 1704, 1705, 1780, 6600, 8082, 8083, 8180 |
| Client | `/opt/snapclient/` | Bridge networking | 8080, 8081 |

The client auto-connects to the local server (`SNAPSERVER_HOST=127.0.0.1`) and uses the Pi's local audio output (HAT or USB DAC).

### Automated Deployment (SSH)

```bash
git clone https://github.com/lollonet/snapMULTI.git
cd snapMULTI
sudo ./scripts/deploy.sh
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
| **Build & Push** | Tag push (`v*`) | Build 5 images (4 multi-arch + 1 ARM-only), push to Docker Hub |
| **Security Scan** | After build, weekly, manual | Trivy scans all images for CRITICAL/HIGH CVEs, uploads SARIF to GitHub Security tab |
| **Validate** | Push to any branch, pull requests | Check docker-compose syntax, shellcheck scripts/, and environment template |
| **Build Test** | Pull requests | Validate Docker images build correctly (no push) |
| **Claude Code Review** | Pull requests | Automated code review against project conventions |

### Container Registry

Docker images are hosted on Docker Hub:

| Image | Description |
|-------|-------------|
| `lollonet/snapmulti-server:latest` | Snapcast server (built from [badaix/snapcast](https://github.com/badaix/snapcast)) |
| `lollonet/snapmulti-airplay:latest` | AirPlay receiver (shairport-sync) |
| `ghcr.io/devgianlu/go-librespot:v0.7.0` | Spotify Connect (upstream, no custom build) |
| `lollonet/snapmulti-mpd:latest` | Music Player Daemon |
| `lollonet/snapmulti-metadata:latest` | Metadata service (cover art + track info) |
| `ghcr.io/jcorporation/mympd/mympd:latest` | Web UI (third-party image) |
| `lollonet/snapmulti-tidal:latest` | Tidal Connect (ARM only) |

Images support `linux/amd64` and `linux/arm64` except Tidal Connect (ARM only).

See GitHub Actions tab for workflow status and logs.

## Configuration Reference

### docker-compose.yml

Defines all services with pre-built images and host networking for mDNS. Each audio source runs in its own container, communicating via named pipes in the shared `/audio` volume:

**Security features**: All containers use `cap_drop: ALL`, `read_only: true` filesystems, `no-new-privileges: true`, and run as non-root (`PUID:PGID`) except for tidal-connect and watchtower (proprietary binary and Docker socket access respectively). See [Security Architecture](architecture/ARC-004.security.md) for complete details.

```yaml
services:
  snapserver:
    image: lollonet/snapmulti-server:latest
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
    image: lollonet/snapmulti-airplay:latest
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
    image: ghcr.io/devgianlu/go-librespot:v0.7.0
    container_name: librespot
    restart: unless-stopped
    network_mode: host
    security_opt:
      - apparmor:unconfined
    user: "${PUID:-1000}:${PGID:-1000}"
    volumes:
      - ./config/go-librespot.yml:/config/config.yml:ro
      - ./audio:/audio
      - /var/run/dbus:/var/run/dbus
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
    image: lollonet/snapmulti-mpd:latest
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

## Logs & Diagnostics

### Viewing Logs

```bash
# All services
docker compose logs -f

# Specific service
docker compose logs -f snapserver
docker compose logs -f shairport-sync
docker compose logs -f librespot
docker compose logs -f mpd

# Last 100 lines
docker compose logs --tail 100 snapserver
```

### Common Log Messages

| Service | Message | Meaning |
|---------|---------|---------|
| snapserver | `Avahi daemon not running` | Host's avahi-daemon not started |
| shairport-sync | `Connection refused on dbus` | Missing D-Bus socket mount |
| librespot | `zeroconf: failed to register` | Avahi daemon not running on host |
| mpd | `Failed to open FIFO` | FIFO pipe not created |

### Health Checks

```bash
# Service status
docker compose ps

# Detailed health
docker inspect --format='{{.State.Health.Status}}' snapserver

# Resource usage
docker stats --no-stream
```

### Installation Log (Zero-Touch)

For SD card installations, check:
```bash
cat /var/log/snapmulti-install.log
```

Failed installations create a marker at `/var/lib/snapmulti-installer/.install-failed`. Remove it to retry:
```bash
sudo rm /var/lib/snapmulti-installer/.install-failed
# Bookworm+ (boot partition at /boot/firmware):
sudo bash /boot/firmware/snapmulti/firstboot.sh
# Bullseye (boot partition at /boot):
# sudo bash /boot/snapmulti/firstboot.sh
```

## Updating

The recommended update method is **reflashing the SD card**. snapMULTI is designed as an appliance — all configuration is auto-detected, so a fresh install is equivalent to an update with zero risk of upgrade-path bugs.

### Reflash (Recommended)

The only data worth preserving across reflashes is the **MPD music database** (`mpd.db`). Without it, MPD rescans your entire music library on first boot — which can take hours over NFS.

A systemd timer on the Pi automatically backs up `mpd.db` to the boot partition daily. Before reflashing:

```bash
# 1. Remove SD card from Pi, insert in your computer
# 2. Extract the MPD database backup:
./scripts/backup-from-sd.sh

# 3. Flash with Pi Imager (this erases the SD card)
# 4. Run prepare-sd.sh — it includes mpd.db automatically:
./scripts/prepare-sd.sh

# 5. Insert SD, boot → MPD scans incrementally (seconds, not hours)
```

`backup-from-sd.sh` auto-detects the SD card mount point and saves `mpd.db` to the project directory where `prepare-sd.sh` picks it up.

> **No MPD database?** If this is a fresh install or you only use streaming sources (Spotify, AirPlay, Tidal), skip step 2 — there's nothing to back up.

### Automatic Image Updates (Watchtower) — opt-in

For advanced users who prefer in-place Docker image updates without reflashing. Disabled by default.

> **Not recommended for read-only or client installs.** Watchtower pulls new images into Docker storage. On overlayroot systems (clients, Pi Zero), images are stored in RAM tmpfs and lost on reboot. Use reflash instead.

```bash
# Enable: add to /opt/snapmulti/.env:
AUTO_UPDATE=true

# Restart with the auto-update profile:
COMPOSE_PROFILES=auto-update docker compose up -d
```

| Variable | Default | Description |
|----------|---------|-------------|
| `AUTO_UPDATE` | (disabled) | Set to `true` to enable Watchtower |
| `UPDATE_SCHEDULE` | `0 0 3 * * *` | Cron schedule (default: daily 3 AM) |
| `UPDATE_NOTIFY_URL` | (none) | Notification URL ([shoutrrr format](https://containrrr.dev/shoutrrr/)) |

**What Watchtower updates:** `lollonet/snapmulti-*` images (`:latest` tag only)

**What it does NOT update:** pinned images (go-librespot, mympd), config files, scripts

### Config & Script Updates

In-place updates via `update.sh` are no longer supported (see [ADR-005](adr/ADR-005.reflash-systemd-robustness.md)). The recommended method is reflashing the SD card — all configuration is auto-detected, and the MPD database is backed up/restored automatically.
