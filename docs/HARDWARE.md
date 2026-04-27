🇬🇧 **English** | 🇮🇹 [Italiano](HARDWARE.it.md)

# Hardware & Network Guide

Hardware requirements, recommended setups, and network considerations for snapMULTI.

## Server Requirements

The server runs all audio services: Snapcast, MPD, shairport-sync (AirPlay), and go-librespot (Spotify Connect) inside Docker containers.

### Minimum Server Hardware

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| CPU | 4 cores, ARMv8 or x86_64 (Pi 3B+) | Pi 4 or x86_64 (faster single-core) |
| RAM | 2 GB | 4 GB+ |
| Storage | 32 GB microSD | 32 GB+ |
| Network | 100 Mbps Ethernet or WiFi 5 GHz | Gigabit Ethernet |
| Architecture | `linux/amd64` or `linux/arm64` | Either |

> **Why 2 GB recommended?** All server containers combined use ~309 MiB RAM at idle. Add OS overhead (~200 MB) and Docker daemon, and a 1 GB Pi 3 works but has limited headroom for spikes (MPD library scans, concurrent streaming). A Pi 4 2 GB gives comfortable margin. See [resource profiles](#resource-profiles) and [measured data](#reference-builds-and-performance-measurements) below.

### What Drives Server Requirements

- **shairport-sync** is CPU-light: measured at **0.0% CPU, 18 MiB RAM** on Pi 4 (streaming idle) — requires a Pi 2 or better ([source](https://github.com/mikebrady/shairport-sync))
- **librespot** (Spotify Connect): measured at **0.0% CPU, 22 MiB RAM** idle; can reach ~180 MiB during active Spotify streaming ([source](https://github.com/librespot-org/librespot/issues/343))
- **MPD**: measured at **6.4% CPU, 90 MiB RAM** (6,418 song library) — heavier on first startup with NFS-mounted library (full scan)
- **Snapserver** with 2 active clients: measured at **6.0% CPU, 87 MiB RAM** on Pi 4; scales linearly per client ([source](https://github.com/badaix/snapcast/issues/1336))
- **metadata-service**: measured at **0.6% CPU, 52 MiB RAM** (after PR #95 optimisation)

### Server Examples

| Hardware | Suitability | Notes |
|----------|-------------|-------|
| Raspberry Pi 4 (4 GB+) | ✅ Recommended | Handles all sources + 10 clients + display comfortably |
| Raspberry Pi 4 (2 GB) | ✅ Good | Server-only or server + headless client; tight with display |
| Raspberry Pi 3B+ | ⚠️ Tight | 1 GB RAM — works server-only but no headroom for spikes |
| Raspberry Pi Zero 2 W | ❌ Not supported | 512 MB RAM — cannot fit server containers |
| Intel NUC / mini PC | ✅ Excellent | Ideal for large deployments or music libraries |
| Old laptop / desktop | ✅ Excellent | Any x86_64 machine with 2+ GB RAM works well |
| NAS with Docker | ✅ Good | If it supports Docker and has 2+ cores and 2+ GB RAM |

> **Note:** Pi 3B+ has only **1 GB RAM**. Server-only works (measured ~309 MiB actual usage) but leaves limited headroom. Not recommended for "both" mode (server + client with display). Pi 2 is too slow for simultaneous AirPlay + Spotify; avoid for server use.

> **Beginners:** If this is your first time, use a Raspberry Pi 4 (4GB) with the [zero-touch SD setup](../README.md#beginners-plug-and-play-raspberry-pi). It handles everything automatically — no terminal required.

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

| Device | Price (IT) | Audio Output | Power | Notes |
|--------|------------|--------------|-------|-------|
| **Raspberry Pi Zero 2 W** | ~€20 | USB DAC or I2S HAT | 0.75 W | Best budget option; 2.4 GHz WiFi only; audio-only (no display) |
| **Raspberry Pi Zero W** (v1) | ~€15 | USB DAC or I2S HAT | 0.5 W | Works but slow; no GPIO audio; 2.4 GHz WiFi only |
| **Raspberry Pi 3B/3B+** | ~€35 | 3.5mm jack, HDMI, USB DAC | 2.5 W | Built-in audio output, 5 GHz WiFi + Ethernet |
| **Raspberry Pi 4** (2 GB+) | ~€45–60 | 3.5mm jack, HDMI, USB DAC | 3–6 W | Required for client with cover art display (fb-display) |
| **Raspberry Pi 5** | ~€65–85 | HDMI, USB DAC | 4–8 W | Overkill for client use |
| **Old Android phone** | Free | Built-in speaker | Battery | Via [Snapcast Android app](https://github.com/badaix/snapdroid) |
| **Any Linux PC** | Varies | Built-in audio | Varies | `apt install snapclient` |

### Pi Zero 2 W Notes

The Pi Zero 2 W is the cheapest client option but has specific requirements:

- **64-bit OS required** — Imager defaults to 32-bit for this model. Select "Raspberry Pi OS Lite (64-bit)" explicitly
- **2.4 GHz WiFi only** — no 5 GHz. Use your 2.4 GHz SSID when configuring WiFi in Imager
- **512 MB RAM** — headless audio only (no display). Cannot run fb-display or server
- **I2S HAT compatibility** — works with PCM5122-based HATs (HiFiBerry DAC+, InnoMaker Mini). The USB `otg_mode=1` setting from Imager conflicts with I2S — `prepare-sd.sh` and `setup.sh` fix this automatically
- **USB gadget mode** — for debugging without WiFi, connect the data USB port to your computer. Requires `dtoverlay=dwc2` under `[all]` in config.txt (not under `[cm5]`)

### Audio Output Quality

| Output Method | Quality | Cost | Notes |
|---------------|---------|------|-------|
| **I2S DAC HAT** (HiFiBerry DAC+, DAC2 Pro) | Excellent | €20–45 | Best analog quality, RCA output, connects directly to Pi GPIO |
| **I2S S/PDIF HAT** (HiFiBerry Digi+) | Excellent | €25–35 | Digital optical/coaxial out to AV receiver or external DAC; no analog conversion on the Pi |
| **USB DAC** | Very good | €10–80 | Wide range of options; works with Pi Zero (no GPIO header needed) |
| **HDMI** | Good | Free | Use your TV/AV receiver as output device |
| **3.5mm jack** (Pi 3/4) | Adequate | Free | Noticeable noise floor on some boards; fine for casual listening |

> **Tip:** Use an I2S HAT for the best quality. [HiFiBerry DAC+ Zero](https://www.hifiberry.com/shop/boards/dacplus-zero/) (~€20) for client nodes, [HiFiBerry DAC2 Pro](https://www.hifiberry.com/shop/boards/dac2-pro/) (~€45) or [HiFiBerry Digi+](https://www.hifiberry.com/shop/boards/hifiberry-digi/) (~€30) for nodes connected to AV receivers.

### Client Install Method

snapMULTI uses **Docker Compose for client deployment** via the [client](../client/) directory. This provides a self-contained stack including snapclient, cover art display, and audio visualizer — all managed together.

The client Docker stack runs three containers:
- `lollonet/snapclient-pi:latest` — Snapcast audio player
- `lollonet/snapclient-pi-fb-display:latest` — Cover art display (framebuffer)
- `lollonet/snapclient-pi-visualizer:latest` — Audio visualizer

See [README.md](../README.md) for the full installation procedure (SD card path or manual).

For minimal or manual setups without the full client directory, snapclient can be installed natively:

```bash
sudo apt install snapclient
```

Docker is recommended for the **server** and for full client nodes with display; native `apt` install is adequate for a bare audio-only client on very constrained hardware.

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
| 1705 | TCP | Bidirectional | Snapcast JSON-RPC control |
| 1780 | HTTP | Bidirectional | Snapweb UI + HTTP API |
| 4953 | TCP | Inbound | TCP audio input (ffmpeg/Android streaming) |
| 5000 | TCP | Inbound | AirPlay (shairport-sync RTSP) |
| 5858 | TCP | Inbound | AirPlay cover art (meta_shairport.py) |
| 2019 | TCP | Inbound | Tidal Connect discovery (ARM only) |
| 6600 | TCP | Bidirectional | MPD protocol (client control) |
| 8000 | HTTP | Server → Clients | MPD HTTP audio stream |
| 8082 | WebSocket | Server → Clients | Metadata service (track info push) |
| 8083 | HTTP | Server → Clients | Metadata service (cover art, health) |
| 8180 | HTTP | Bidirectional | myMPD web UI |
| 5353 | UDP | Multicast | mDNS autodiscovery |

**Router requirements:**
- Clients and server must be on the same subnet (or mDNS must be forwarded)
- IGMP snooping support recommended for larger networks
- No special router features needed for typical home use

### Firewall Rules

```bash
# Snapcast core
sudo ufw allow 1704/tcp   # Audio streaming
sudo ufw allow 1705/tcp   # JSON-RPC control
sudo ufw allow 1780/tcp   # HTTP API + Snapweb UI

# Audio sources — required for casting from phone/app
sudo ufw allow 4953/tcp   # TCP audio input (ffmpeg/Android streaming)
sudo ufw allow 5000/tcp   # AirPlay (shairport-sync RTSP)
sudo ufw allow 5858/tcp   # AirPlay cover art (meta_shairport.py)
sudo ufw allow 2019/tcp   # Tidal Connect discovery (ARM only)
# Spotify Connect uses a random TCP port for zeroconf discovery;
# if ufw is enabled, allow the ephemeral range or use connection tracking:
# sudo ufw allow proto tcp from 192.168.0.0/16 to any port 30000:65535

# Music library
sudo ufw allow 6600/tcp   # MPD protocol
sudo ufw allow 8000/tcp   # MPD HTTP stream
sudo ufw allow 8180/tcp   # myMPD web UI

# Metadata
sudo ufw allow 8082/tcp   # Metadata service (WebSocket)
sudo ufw allow 8083/tcp   # Metadata service (HTTP/cover art)

# Discovery
sudo ufw allow 5353/udp   # mDNS (Avahi/Bonjour)
```

### Network QoS (Quality of Service)

For optimal audio streaming performance, especially on congested networks or with bulk file transfers, `deploy.sh` configures network QoS:

**CAKE + DSCP EF**: Snapcast audio packets are marked with DSCP EF (Expedited Forwarding) for priority handling. The CAKE (Common Applications Kept Enhanced) qdisc provides low-latency queuing and automatic bandwidth management.

```bash
# Applied automatically by deploy.sh on compatible systems
tc qdisc add dev eth0 root cake bandwidth 100mbit
# Snapcast uses DSCP EF marking for real-time audio priority
```

This ensures consistent audio streaming even during network congestion from file transfers, updates, or other bulk traffic.

## Storage

### Docker Images

**Server images:**

| Image | Size |
|-------|------|
| `lollonet/snapmulti-server:latest` | ~80–120 MB |
| `lollonet/snapmulti-airplay:latest` | ~30–50 MB |
| `ghcr.io/devgianlu/go-librespot:v0.7.0` | ~30–50 MB |
| `lollonet/snapmulti-mpd:latest` | ~50–80 MB |
| `lollonet/snapmulti-metadata:latest` | ~60–80 MB |
| `ghcr.io/jcorporation/mympd/mympd:latest` | ~30–50 MB |
| `lollonet/snapmulti-tidal:latest` | ~200–300 MB |

**Client images** (from [client](../client/) directory):

| Image | Size |
|-------|------|
| `lollonet/snapclient-pi:latest` | ~30–50 MB |
| `lollonet/snapclient-pi-fb-display:latest` | ~80–120 MB |
| `lollonet/snapclient-pi-visualizer:latest` | ~50–80 MB |

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

### Starter — 2 rooms

| Node | Hardware | Audio output |
|------|----------|-------------|
| Server + Client | Pi 4 (4 GB) + HiFiBerry DAC2 Pro | RCA analog |
| Client (headless) | Pi Zero 2 W + HiFiBerry DAC+ Zero | RCA analog |

> Pi Zero 2 W requires soldering a GPIO header (or buy the WH variant with pre-soldered header). **WiFi only** — no Ethernet port, 2.4 GHz only.

### Budget — 2 rooms (all available on Amazon)

| Node | Hardware | Audio output |
|------|----------|-------------|
| Server + Client | Pi 4 (2 GB) + InnoMaker HiFi DAC HAT (PCM5122) | RCA + 3.5mm |
| Client (headless) | Pi 3 B+ + InnoMaker DAC Mini HAT (PCM5122) | RCA + 3.5mm |

> Pi 4 2 GB is comfortable for server-only (~309 MiB RAM at idle). For server + client with display, the 4 GB model is preferred.

### Enthusiast — 4+ rooms

| Node | Hardware | Connection |
|------|----------|------------|
| Server | Intel NUC or mini PC (x86_64) | Ethernet |
| Client × 3+ | Pi Zero 2 W + HiFiBerry DAC+ Zero | WiFi (2.4 GHz) |

> Pi Zero clients connect via WiFi (no Ethernet port). Server should use Ethernet for reliability. A managed switch helps if you also have wired clients (Pi 3/4).

### Alternative: S/PDIF to AV Receiver

If a node connects to an AV receiver via optical cable, use HiFiBerry Digi+ instead of a DAC HAT. This shifts the D/A conversion to your receiver — better quality if your receiver has a good DAC.

## Tested Combinations

These hardware combinations have been verified end-to-end (firstboot → smoke test → audio playback) on the dates indicated. The 2026-04-27 batch was the v0.6.x release-gate validation: 6 devices reflashed from `main`, smoke test PASS on each, ALSA `hw_ptr` advancing during playback (audio actually reaching the DAC, not just the FIFO).

| Hostname | Pi Model | Audio HAT | DAC chip | Mode | Display | Music Source | Validated | Status |
|---|---|---|---|---|---|---|---|---|
| snapvideo | Pi 4 B (8 GB) | HiFiBerry DAC+ | PCM5122 (analog) | both | HDMI 800×600 (cover art display) | local | 2026-04-27 | Working |
| moniaserver | Pi 4 B (2 GB) | HiFiBerry DAC+ Standard | PCM5122 (analog) | both | headless | USB | 2026-04-27 | Working |
| snapdigi | Pi 4 B (2 GB) | HiFiBerry Digi+ | WM8804 (S/PDIF) | client | HDMI to LG 50" TV | n/a | 2026-04-27 | Working |
| piotto | Pi 4 B (2 GB) | none (bcm2835 onboard) | — | client | headless | n/a | 2026-04-27 | Working |
| moniaclient | Pi 3 B+ (1 GB) | InnoMaker HIFI DAC HAT | PCM5122 (analog) | client | headless | n/a | 2026-04-27 | Working |
| pizero | Pi Zero 2 W (512 MB) | InnoMaker DAC | PCM5122 (analog) | client | headless | n/a | 2026-04-27 | Working |

**Coverage achieved on 2026-04-27**:

- 3 Pi families: Pi Zero 2 W, Pi 3 B+, Pi 4 B (4 different rev numbers on the Pi 4: 1.1, 1.2, 1.4, 1.5)
- 2 DAC chip families: PCM5122 (analog, 4 boards across HiFiBerry + InnoMaker brands) and WM8804 (S/PDIF digital)
- Plus 1 device with onboard `bcm2835` (no HAT)
- Both mixer paths: hardware (`hardware:Digital` on PCM5122) and software fallback (S/PDIF + onboard)
- Both install modes (`--both`, `--client`) and `--server` exercised in earlier rounds
- Headless and HDMI-display variants
- Read-only filesystem (overlayroot + fuse-overlayfs) active on every device
- Auto-detect via I2C bus 1 EEPROM-less PCM5122 detection works on all four DAC HATs

## Known Limitations

| Limitation | Details |
|------------|---------|
| **Pi Zero 2 W as server** | 512 MB RAM cannot fit server containers (592M limits in minimal profile). Use as headless client only |
| **Pi Zero 2 W with display** | 512 MB RAM is too tight for fb-display + visualizer (352M limits). Use Pi 3+ for display clients |
| **Pi 3 1 GB — both mode with display** | Server (592M) + client display (352M) = 944M limits on 1 GB — not supported. Use server-only or client-only, not both |
| **Pi Zero W (v1) as server** | Too slow for shairport-sync + librespot simultaneously |
| **librespot on ARMv6** | Not officially supported on Pi Zero v1 / Pi 1 ([details](https://github.com/librespot-org/librespot/pull/1457)). Cross-compilation possible but unsupported |
| **3.5mm audio on Pi** | Noticeable noise floor; use DAC HAT or USB DAC for quality |
| **2.4 GHz WiFi** | Works but susceptible to interference; 5 GHz preferred for >10 clients |
| **Docker on 32-bit Pi OS** | Being deprecated; use 64-bit Pi OS for Docker deployments |

---

## Resource Profiles

`deploy.sh` (server) and `setup.sh` (client) auto-detect hardware and apply one of three profiles: **minimal**, **standard**, or **performance**. Limits can be overridden in `.env`.

### Profile Selection

| Hardware | RAM | Profile |
|----------|-----|---------|
| Pi Zero 2 W, Pi 3 | < 2 GB | minimal |
| Pi 4 2 GB | 2–4 GB | standard |
| Pi 4 4 GB+, Pi 5, x86_64 | 4 GB+ | performance |

### Server Memory Limits by Profile

| Service | Measured | minimal | standard | performance |
|---------|----------|---------|----------|-------------|
| snapserver | 87 MiB | 128M | 192M | 256M |
| shairport-sync | 18 MiB | 48M | 64M | 96M |
| librespot | 22 MiB | 96M | 256M | 256M |
| mpd | 90 MiB | 128M | 256M | 384M |
| mympd | 8 MiB | 32M | 64M | 128M |
| metadata | 52 MiB | 96M | 128M | 128M |
| tidal-connect | 32 MiB | 64M | 96M | 128M |
| **Total** | **~309 MiB** | **592M** | **1,056M** | **1,376M** |

> Measured values are idle baselines from snapvideo (Pi 4 8 GB) with all services running and 2 clients connected. Actual usage rises during active playback (librespot can reach ~180 MiB during Spotify streaming) and MPD library scans (proportional to library size — 90 MiB idle with 6,418 songs).

### Client Memory Limits by Profile

| Service | Measured | minimal | standard | performance |
|---------|----------|---------|----------|-------------|
| snapclient | 18 MiB | 64M | 64M | 96M |
| audio-visualizer | 36–51 MiB | 96M | 128M | 192M |
| fb-display | 89–114 MiB | 192M | 256M | 384M |
| **Total** | **~168 MiB** | **352M** | **448M** | **672M** |

> fb-display memory scales with resolution: ~89 MiB at 1080p, ~114 MiB at 4K (3840x2160). CPU usage also scales: ~12% at 1080p, ~66% at 4K. Headless clients (no display) run only snapclient (~18 MiB, ~2% CPU).

### Hardware Compatibility Matrix

Assumes ~200 MB OS + Docker overhead. "Avail" = RAM remaining after container limits.

**Server-only** (all services including Tidal on ARM):

| Hardware | RAM | Profile | Limits | % RAM | Status |
|----------|-----|---------|--------|-------|--------|
| Pi Zero 2W | 512M | minimal | 592M | 190% | **Not supported** |
| Pi 3 1GB | 1024M | minimal | 592M | 72% | Tight — works, no headroom for spikes |
| Pi 4 2GB | 2048M | standard | 1,056M | 57% | OK |
| Pi 4 4GB+ | 4096M | performance | 1,376M | 35% | OK |
| Pi 5 | 4–8 GB | performance | 1,376M | 17–35% | OK |

**Client with display:**

| Hardware | RAM | Profile | Limits | % RAM | Status |
|----------|-----|---------|--------|-------|--------|
| Pi Zero 2W | 512M | minimal | 352M | 113% | **Not supported** |
| Pi 3 1GB | 1024M | minimal | 352M | 43% | OK |
| Pi 4 2GB | 2048M | standard | 448M | 24% | OK |
| Pi 4 4GB+ | 4096M | performance | 672M | 17% | OK |

**Client headless** (snapclient only — no display):

| Hardware | RAM | Profile | Limits | Status |
|----------|-----|---------|--------|--------|
| Pi Zero 2W | 512M | minimal | 64M | OK |
| Pi 3 1GB | 1024M | minimal | 64M | OK |
| Any 2GB+ | 2GB+ | standard+ | 64–96M | OK |

**Both mode** (server + client with display on same Pi):

| Hardware | RAM | Profile | Server | Client | Total | % RAM | Status |
|----------|-----|---------|--------|--------|-------|-------|--------|
| Pi Zero 2W | 512M | minimal | 592M | 352M | 944M | 303% | **Not supported** |
| Pi 3 1GB | 1024M | minimal | 592M | 352M | 944M | 115% | **Not supported** |
| Pi 4 2GB | 2048M | standard | 1,056M | 448M | 1,504M | 81% | Tight — works, limited headroom |
| Pi 4 4GB+ | 4096M | performance | 1,376M | 672M | 2,048M | 53% | OK |

**Both mode** (server + client headless on same Pi):

| Hardware | RAM | Profile | Server | Client | Total | % RAM | Status |
|----------|-----|---------|--------|--------|-------|-------|--------|
| Pi Zero 2W | 512M | minimal | 592M | 64M | 656M | 210% | **Not supported** |
| Pi 3 1GB | 1024M | minimal | 592M | 64M | 656M | 80% | Tight — works, limited headroom |
| Pi 4 2GB | 2048M | standard | 1,056M | 64M | 1,120M | 61% | OK |
| Pi 4 4GB+ | 4096M | performance | 1,376M | 96M | 1,472M | 38% | OK |

> **Important:** These percentages represent *limits* (ceilings), not actual usage. Measured total usage across all 10 services is ~468 MiB idle. Services rarely hit their limits simultaneously — the limits exist to prevent runaway processes from starving the system. A 74% limit-to-RAM ratio on Pi 4 2 GB is safe in practice.

---

## Reference Builds and Performance Measurements

Two production systems measured in March 2026. Both on 5 GHz WiFi, 64-bit Pi OS, no throttling.

> CPU % figures are point-in-time samples and vary with playback activity. RAM figures are more stable. The totals below represent a typical streaming-idle state with all services running.

### snapvideo — Server + Client Colocated

| Attribute | Value |
|-----------|-------|
| Board | Raspberry Pi 4 Model B Rev 1.4 — **8 GB RAM** |
| Audio | [HiFiBerry DAC+](https://www.hifiberry.com/shop/boards/hifiberry-dacplus/) (`snd_rpi_hifiberry_dacplus`, pcm512x) — RCA analog out |
| Network | 5 GHz WiFi |
| Profile | performance (server + client) |

**Docker container load** (all services active, streaming idle, 2 clients connected):

| Container | CPU % | RAM used | RAM limit |
|-----------|-------|----------|-----------|
| snapserver | 6.0% | 87 MiB | 512 MiB |
| fb-display | 11.7% | 89 MiB | 384 MiB |
| audio-visualizer | 7.8% | 51 MiB | 384 MiB |
| librespot (Spotify) | 0.0% | 22 MiB | 256 MiB |
| mpd | 6.4% | 90 MiB | 512 MiB |
| mympd | 0.0% | 8 MiB | 256 MiB |
| metadata | 0.6% | 52 MiB | 192 MiB |
| shairport-sync (AirPlay) | 0.0% | 18 MiB | 256 MiB |
| tidal-connect | 4.7% | 32 MiB | 192 MiB |
| snapclient | 1.2% | 18 MiB | 192 MiB |
| **Total** | **~38%** | **~468 MiB** | |

**System RAM:** 787 MiB used / 7645 MiB total (6.7 GiB available)

> Services without display (fb-display + audio-visualizer) would reduce CPU to ~19% and RAM to ~327 MiB — a Pi 4 2 GB is then viable as server.

---

### snapdigi — Client Only (4K Display)

| Attribute | Value |
|-----------|-------|
| Board | Raspberry Pi 4 Model B Rev 1.1 — **2 GB RAM** |
| Audio | [HiFiBerry Digi+](https://www.hifiberry.com/shop/boards/hifiberry-digi/) (`snd_rpi_hifiberry_digi`, WM8804) — **S/PDIF optical/coaxial out** |
| Display | 3840x2160 (4K) |
| Network | 5 GHz WiFi |
| Profile | custom (tuned for 4K display) |

**Docker container load** (client with 4K cover art display active):

| Container | CPU % | RAM used | RAM limit |
|-----------|-------|----------|-----------|
| fb-display | **66.1%** | 114 MiB | 384 MiB |
| audio-visualizer | 8.6% | 36 MiB | 128 MiB |
| snapclient | 1.8% | 18 MiB | 96 MiB |
| **Total** | **~77%** | **~168 MiB** | |

**System RAM:** 1.1 GiB used / 1.6 GiB total (547 MiB available)

> fb-display at 4K resolution uses significantly more CPU (~66%) and RAM (~114 MiB) than at 1080p (~12% CPU, ~89 MiB). The 384 MiB limit provides safe headroom. For 4K displays, Pi 4 2 GB is the minimum; Pi 4 4 GB+ is recommended.

---

### Minimum Hardware — Conclusions

| Use Case | Minimum Board | RAM | Reason |
|----------|---------------|-----|--------|
| Server only | Pi 3 **1 GB** | 1 GB | ~309 MiB actual usage; tight but works. Pi 4 2 GB recommended |
| Server + Client headless | Pi 3 **1 GB** | 1 GB | snapclient adds only 18 MiB |
| Server + Client with display | Pi 4 **2 GB** | 2 GB | fb-display + visualizer add ~140 MiB |
| Client only, headless | **Pi Zero 2 W** | 512 MB | snapclient: ~2% CPU, 18 MiB RAM |
| Client only, with display (1080p) | Pi 3 **1 GB** | 1 GB | fb-display + visualizer: ~140 MiB |
| Client only, with display (4K) | Pi 4 **2 GB** | 2 GB | fb-display at 4K: ~114 MiB, ~66% CPU |

**Thermal:** Both Pi 4 boards ran continuously for days at 58–65°C without thermal throttling (snapvideo 57.9°C, snapdigi 64.7°C). Passive cooling (heatsink case) is sufficient; active cooling (fan) is not required for typical home use.
