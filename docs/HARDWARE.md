🇬🇧 **English** | 🇮🇹 [Italiano](HARDWARE.it.md)

# Hardware & Network Guide

Hardware requirements, recommended setups, and network considerations for snapMULTI.

## Server Requirements

The server runs all audio services: Snapcast, MPD, shairport-sync (AirPlay), and librespot (Spotify Connect) inside Docker containers.

### Minimum Server Hardware

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| CPU | 2 cores, ARMv7+ or x86_64 | 4 cores |
| RAM | 1 GB | 2 GB+ |
| Storage | 16 GB (OS + Docker) | 32 GB+ |
| Network | 100 Mbps Ethernet | Gigabit Ethernet |
| Architecture | `linux/amd64` or `linux/arm64` | Either |

### What Drives Server Requirements

- **shairport-sync** is the most demanding component — requires at minimum a Raspberry Pi 2 or Pi Zero 2 W level of CPU ([source](https://github.com/mikebrady/shairport-sync))
- **librespot** uses ~20% CPU on a Pi 3 with ALSA backend ([source](https://github.com/librespot-org/librespot/issues/343))
- **MPD** uses 2–3 MB RAM idle; FLAC decoding is lightweight, but resampling is CPU-intensive ([source](https://mpd.readthedocs.io/en/stable/user.html))
- **Snapserver** uses <2% CPU on a Pi 4 when idle ([source](https://github.com/badaix/snapcast/issues/1336))
- CPU scales linearly with number of connected clients

### Server Examples

| Hardware | Suitability | Notes |
|----------|-------------|-------|
| Raspberry Pi 4 (4 GB) | Good | Handles all 4 sources + 10 clients comfortably |
| Raspberry Pi 3B+ | Adequate | Works but may struggle with all sources active simultaneously |
| Intel NUC / mini PC | Excellent | Overkill but ideal for large deployments |
| Old laptop / desktop | Excellent | Any x86_64 machine with 2+ GB RAM works well |
| NAS with Docker | Good | If it supports Docker and has 2+ cores |

> **Note:** Raspberry Pi 2 and Pi Zero 2 W can run the server but are borderline. A Pi 3B+ or better is recommended for all four audio sources.

## Client Requirements

Snapcast clients are lightweight — they receive audio and play it through speakers.

### Minimum Client Hardware

| Component | Minimum | Notes |
|-----------|---------|-------|
| CPU | Any ARMv6+ or x86_64 | Even Pi Zero W (original) works |
| RAM | 256 MB | Snapclient uses very little memory |
| Storage | 8 GB microSD | 16 GB recommended |
| Audio output | 3.5mm, HDMI, USB DAC, or I2S HAT | See audio output section |

### Client Device Options

| Device | Price Range | Audio Output | Power | Notes |
|--------|-------------|--------------|-------|-------|
| **Raspberry Pi Zero 2 W** | ~$15 | USB DAC or I2S HAT | 0.75 W | Best budget option, WiFi built-in |
| **Raspberry Pi Zero W** (v1) | ~$10 | USB DAC or I2S HAT | 0.5 W | Works but slower; no built-in audio jack |
| **Raspberry Pi 3B/3B+** | ~$35 | 3.5mm jack, HDMI, USB DAC | 2.5 W | Built-in audio output, WiFi + Ethernet |
| **Raspberry Pi 4** | ~$35–55 | 3.5mm jack, HDMI, USB DAC | 3–6 W | More power than needed for a client |
| **Raspberry Pi 5** | ~$60–80 | HDMI, USB DAC | 4–8 W | Overkill for client use |
| **Old Android phone** | Free | Built-in speaker | Battery | Via Snapcast Android app |
| **Any Linux PC** | Varies | Built-in audio | Varies | `apt install snapclient` |

### Audio Output Quality

| Output Method | Quality | Cost | Notes |
|---------------|---------|------|-------|
| **I2S DAC HAT** (HiFiBerry, IQAudio) | Excellent | $20–50 | Best audio quality, connects directly to Pi GPIO |
| **USB DAC** | Very good | $10–100 | Wide range of options, works with Pi Zero |
| **HDMI** | Good | Free | Use your TV/receiver as speaker |
| **3.5mm jack** (Pi 3/4) | Adequate | Free | Noticeable hiss on some models; fine for casual listening |

> **Tip:** For the best audio experience on Raspberry Pi, use a HiFiBerry DAC+ Zero (~$20) or any USB DAC. The built-in 3.5mm jack on Pi 3/4 is adequate but not audiophile-grade.

### Docker vs Native Install (Clients)

For **client** devices, native installation is recommended over Docker:

- Lower overhead on resource-constrained devices
- Direct access to audio hardware
- Simpler configuration

```bash
# Native install (recommended for clients)
sudo apt install snapclient

# Docker (only if you prefer containerization)
docker run -d --name snapclient --network host --device /dev/snd ghcr.io/badaix/snapcast:latest snapclient
```

Docker is recommended for the **server** where you benefit from container management and reproducibility.

## Network Requirements

### Bandwidth

Audio format: 44100 Hz, 16-bit, stereo (default FLAC codec).

| Metric | Value |
|--------|-------|
| Raw PCM bitrate | 1.536 Mbps (192 KB/s) |
| FLAC compressed (typical) | ~0.9 Mbps (~115 KB/s) |
| Protocol overhead per client | ~14 kbps (negligible) |

**Total bandwidth by number of clients:**

| Clients | FLAC Bandwidth | Network Needed |
|---------|---------------|----------------|
| 5 | ~4.5 Mbps | Any modern network |
| 10 | ~9 Mbps | Any modern network |
| 20 | ~18 Mbps | 100 Mbps Ethernet or 5 GHz WiFi |
| 50 | ~45 Mbps | Gigabit Ethernet recommended |

> **Bandwidth is NOT a bottleneck** for typical home setups. Even 2.4 GHz WiFi (practical throughput ~20–50 Mbps) handles 10+ clients.

### WiFi vs Ethernet

| Factor | WiFi (2.4 GHz) | WiFi (5 GHz) | Ethernet |
|--------|-----------------|---------------|----------|
| Bandwidth | 20–50 Mbps practical | 150–400 Mbps | 100–1000 Mbps |
| Latency | 2–10 ms | 1–5 ms | <1 ms |
| Reliability | Variable (interference) | Good | Excellent |
| Client capacity | 10–15 clients | 20+ clients | 50+ clients |
| Best for | Clients in rooms without Ethernet | Clients needing reliability | Server, critical clients |

**Recommendations:**
- **Server**: Ethernet whenever possible
- **Clients**: WiFi works fine; use 5 GHz if available
- **Latency-sensitive setups**: Ethernet reduces sync jitter

### Synchronization

- Snapcast achieves **sub-millisecond sync** across clients
- Default buffer: 2400 ms (configurable in `snapserver.conf`)
- Larger buffer = more stable on poor networks, but adds playback delay
- WiFi jitter is compensated automatically — clients adjust playback speed

### Network Configuration

**Required ports:**

| Port | Protocol | Direction | Purpose |
|------|----------|-----------|---------|
| 1704 | TCP | Server → Clients | Audio streaming |
| 1705 | TCP | Bidirectional | JSON-RPC control |
| 1780 | HTTP | Bidirectional | HTTP API |
| 6600 | TCP | Bidirectional | MPD protocol (client control) |
| 8000 | HTTP | Bidirectional | MPD HTTP audio stream |
| 8180 | HTTP | Bidirectional | myMPD web UI |
| 5353 | UDP | Multicast | mDNS autodiscovery |

**Router requirements:**
- Clients and server must be on the same subnet (or mDNS must be forwarded)
- IGMP snooping support recommended for larger networks
- No special router features needed for typical home use

### Firewall Rules

```bash
# Allow Snapcast traffic
sudo ufw allow 1704/tcp   # Audio streaming
sudo ufw allow 1705/tcp   # JSON-RPC control
sudo ufw allow 1780/tcp   # HTTP API
sudo ufw allow 6600/tcp   # MPD protocol
sudo ufw allow 8000/tcp   # MPD HTTP stream
sudo ufw allow 8180/tcp   # myMPD web UI
sudo ufw allow 5353/udp   # mDNS discovery
```

## Storage

### Docker Images

| Image | Size |
|-------|------|
| `ghcr.io/lollonet/snapmulti-server:latest` | ~80–120 MB |
| `ghcr.io/lollonet/snapmulti-airplay:latest` | ~30–50 MB |
| `ghcr.io/lollonet/snapmulti-spotify:latest` | ~30–50 MB |
| `ghcr.io/lollonet/snapmulti-mpd:latest` | ~50–80 MB |

### Music Library

| Format | Typical Album Size | 1000 Albums |
|--------|--------------------|-------------|
| FLAC (lossless) | 300–500 MB | 300–500 GB |
| MP3 320 kbps | 80–120 MB | 80–120 GB |
| MP3 192 kbps | 50–80 MB | 50–80 GB |

**Storage recommendations:**
- FLAC libraries: external USB drive or NAS mount
- MP3 libraries: 256 GB+ microSD or internal drive
- MPD database file: <100 MB regardless of library size

## Recommended Setups

### Budget Setup (~$50)

| Role | Hardware | Cost |
|------|----------|------|
| Server | Raspberry Pi 3B+ (used) | ~$25 |
| Client (1 room) | Raspberry Pi Zero 2 W + USB DAC | ~$25 |

### Mid-Range Setup (~$150)

| Role | Hardware | Cost |
|------|----------|------|
| Server | Raspberry Pi 4 (4 GB) | ~$55 |
| Client (3 rooms) | 3× Raspberry Pi Zero 2 W + HiFiBerry DAC+ Zero | ~$105 |

### Enthusiast Setup (~$300+)

| Role | Hardware | Cost |
|------|----------|------|
| Server | Intel NUC or mini PC | ~$150+ |
| Client (5 rooms) | Mix of Pi Zero 2 W with HiFiBerry HATs | ~$175 |
| Network | Managed switch + Ethernet to server | ~$30 |

## Known Limitations

| Limitation | Details |
|------------|---------|
| **Pi Zero W (v1) as server** | Too slow for shairport-sync + librespot simultaneously |
| **librespot on ARMv6** | Not officially supported on Pi Zero v1 / Pi 1 ([details](https://github.com/librespot-org/librespot/pull/1457)). Cross-compilation possible but unsupported |
| **3.5mm audio on Pi** | Noticeable noise floor; use DAC HAT or USB DAC for quality |
| **2.4 GHz WiFi** | Works but susceptible to interference; 5 GHz preferred for >10 clients |
| **Docker on 32-bit Pi OS** | Being deprecated; use 64-bit Pi OS for Docker deployments |
