# Snapcast + MPD Multiroom Audio Server

[![CI/CD](https://github.com/lollonet/snapcast/actions/workflows/deploy.yml/badge.svg)](https://github.com/lollonet/snapcast/actions/workflows/deploy.yml)

Multiroom audio streaming server using Snapcast with MPD as the audio source. Serves synchronized audio to up to 5 clients on the local network.

## Overview

- **Snapserver**: Audio streaming server that distributes synchronized audio to multiple clients
- **MPD**: Music Player Daemon that plays local audio files and outputs to Snapcast via FIFO
- **Autodiscovery**: mDNS/Bonjour support for automatic client discovery (`snapcast.local`)
- **Architecture**: Both services run in Docker containers with host networking (Alpine Linux)
- **Music Library**: Configured via environment variables (see `.env.example`)

## Architecture

```
┌─────────────────┐
│  Music Library  │
│  (host paths)   │
└────────┬────────┘
         │
         ▼
┌─────────────────┐     ┌──────────────┐
│  Docker: MPD    │────▶│ /audio/fifo  │
│  (localhost:6600)│     └──────┬───────┘
└─────────────────┘            │
                               ▼
                     ┌──────────────────┐
                     │ Docker: Snapcast │
                     │ (port 1704)      │
                     └────────┬─────────┘
                              │
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
- Ports available: 1704, 1705, 1780, 6600, 8000

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

# Server configuration
SERVER_IP=your-server-ip
MAX_CLIENTS=5
TZ=Your/Timezone
```

3. (Optional) Adjust `max_clients` in `snapserver.conf` if needed

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

Snapcast uses **mDNS/Bonjour** (Avahi) for automatic client discovery on the local network.

### How It Works

- **Snapserver** advertises itself via mDNS as `snapcast.local`
- **Snapclients** automatically discover the server without manual IP configuration
- Uses **host networking** to allow mDNS broadcast traffic

### Verify Autodiscovery

```bash
# Check if Avahi is running in the container
docker exec snapserver ps aux | grep avahi

# Check mDNS advertisements from host
avahi-browse -r _snapcast._tcp --terminate

# Check published services
docker exec snapserver avahi-browse -a | grep snapcast
```

### Troubleshooting Autodiscovery

**Clients can't find the server:**
```bash
# Verify Avahi is running
docker exec snapserver rc-status | grep avahi

# Check host can see mDNS
avahi-browse -a | grep snapcast

# Restart Avahi
docker exec snapserver avahi-daemon -r
```

**Firewall blocking mDNS:**
```bash
# Allow mDNS traffic (UDP 5353)
sudo ufw allow 5353/udp
```

## Deployment

### Automated Deployment (Recommended)

Push to `main` branch → Auto-deploys to home server via GitHub Actions.

1. Make changes locally
2. Commit and push: `git push origin main`
3. GitHub Actions automatically:
   - Validates configuration
   - Tests Docker builds
   - Deploys to server via SSH

### Manual Deployment

```bash
cd /home/claudio/Code/snapcast
docker compose up -d
```

### CI/CD Workflows

- **Validate**: Checks docker-compose syntax and environment template
- **Build Test**: Tests Docker images build correctly
- **Deploy**: Auto-deploys to home server on push to main

See GitHub Actions tab for workflow status and logs.

## Services

### Snapserver

| Port | Protocol | Purpose |
|------|----------|---------|
| 1704 | TCP | Audio streaming to clients |
| 1705 | HTTP | JSON-RPC API |
| 1780 | HTTP | Snapweb UI (not installed) |

**Configuration**: `snapserver.conf`
- Max clients: 0 (unlimited, adjust in config as needed)
- Codec: FLAC
- Sample format: 48000:16:2
- Buffer: 1000ms

### MPD

| Port | Protocol | Purpose |
|------|----------|---------|
| 6600 | TCP | MPD protocol (client control) |
| 8000 | HTTP | Audio stream (direct access) |

**Configuration**: `mpd/config/mpd.conf`
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
mpd current                 # Show current song
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

**With autodiscovery** (recommended - no IP needed):
```bash
# Automatically finds snapcast.local
snapclient

# Or specify discovery method explicitly
snapclient --discover
```

**Manual IP configuration** (if autodiscovery fails):
```bash
snapclient --host 192.168.63.3
```

### Using Browser as Client

Access the MPD HTTP stream directly:
```
http://192.168.63.3:8000
```

## Configuration Files

### docker-compose.yml

Defines both services and their configuration:

```yaml
services:
  snapcast:
    build:
      dockerfile: Dockerfile.snapcast
    image: snapcast:latest
    ports:
      - "1704:1704"
      - "1705:1705"
      - "1780:1780"
    volumes:
      - ./config:/config
      - ./data:/data
      - ./audio:/audio

  mpd:
    build:
      dockerfile: Dockerfile.mpd
    image: mpd:latest
    ports:
      - "6600:6600"
      - "8000:8000"
    volumes:
      - ./audio:/audio
      - /data8T/music/Lossless:/music/Lossless:ro
      - /data8T/music/Lossy:/music/Lossy:ro
      - ./mpd/config:/etc/mpd.d
      - ./mpd/playlists:/playlists
      - ./mpd/data:/data
```

### snapserver.conf

Key settings:
```ini
[stream]
source = pipe:////audio/snapcast_fifo?name=MPD
sampleformat = 48000:16:2
codec = flac
buffer = 1000
max_clients = 5
```

### mpd.conf

Key settings:
```ini
music_directory         "/music"
audio_output {
        type            "fifo"
        name            "Snapcast"
        path            "/audio/snapcast_fifo"
        format          "48000:16:2"
}
```

## Troubleshooting

### Snapserver

**No audio streaming**:
```bash
# Check if FIFO exists and has data
ls -l audio/snapcast_fifo

# Check Snapserver logs
docker logs snapserver | tail -50

# Verify MPD is writing to FIFO
docker exec mpd lsof /audio/snapcast_fifo
```

**Clients can't connect**:
```bash
# Check if ports are listening
ss -tlnp | grep -E "1704|1705|1780"

# Test from client machine
telnet 192.168.63.3 1704
```

### MPD

**Database not updating**:
```bash
# Check log for errors
docker exec mpd tail -100 /data/mpd.log | grep -i error

# Verify music directories are mounted
docker exec mpd ls -la /music

# Force database update
printf 'update\n' | nc localhost 6600
```

**No audio output**:
```bash
# Check if FIFO is being written to
docker exec mpd ls -l /audio/snapcast_fifo

# Check MPD status
printf 'status\n' | nc localhost 6600

# Check for errors in log
docker logs mpd | tail -50
```

### Container Issues

**Container won't start**:
```bash
# Check container logs
docker logs snapserver
docker logs mpd

# Rebuild images
docker compose build --no-cache

# Check resource usage
docker stats
```

## Performance

### Resource Usage

- **Snapserver**: ~50MB RAM, minimal CPU when idle
- **MPD**: ~100MB RAM, low CPU during playback
- **Bandwidth**: ~1-2 Mbps per client (FLAC codec)

### Scaling

- **Max clients**: Configured for 5 (can increase in `snapserver.conf`)
- **Codec**: FLAC provides good quality/bandwidth balance
- **Alternatives**: Use PCM for max quality, Opus for lower bandwidth

## Development

### Rebuild Images

```bash
# Rebuild Snapcast
docker compose build --no-cache snapcast

# Rebuild MPD
docker compose build --no-cache mpd

# Rebuild both
docker compose build --no-cache
```

### Update Snapcast Version

Edit `Dockerfile.snapcast`, change git clone command to specify tag/branch, then rebuild:

```dockerfile
RUN git clone --branch v0.35.0 https://github.com/badaix/snapcast.git . && \
```

## Network Access

- **Server IP**: `192.168.63.3` (adjust as needed)
- **Snapserver**: Ports 1704 (stream), 1705 (control), 1780 (web)
- **MPD**: Ports 6600 (control), 8000 (stream)

### Firewall Configuration

If using UFW:
```bash
sudo ufw allow 1704/tcp  # Snapcast stream
sudo ufw allow 1705/tcp  # Snapcast control
sudo ufw allow 6600/tcp  # MPD
sudo ufw allow 8000/tcp  # MPD stream
```

## TODO

- [ ] Install and configure Cantata client
- [ ] Complete MPD database update (70k songs)
- [ ] Optionally install Snapweb UI files
- [ ] Configure auto-start on boot
- [ ] Set up backup for MPD database and playlists
- [ ] Document client setup for various devices

## License

This setup uses:
- **Snapcast**: GPLv3 (https://github.com/badaix/snapcast)
- **MPD**: GPL (https://www.musicpd.org/)

## References

- [Snapcast Documentation](https://github.com/badaix/snapcast)
- [MPD Documentation](https://www.musicpd.org/doc/html/)
- [Docker Snapcast Images](https://github.com/sweisgerber/docker-snapcast)
