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

> **Why 2 GB minimum?** All containers combined use ~720 MB RAM when streaming (no display). Add OS overhead (~500 MB) and you need >1.2 GB free — a 1 GB board has no headroom. See [measured data](#reference-builds-and-performance-measurements) below.

### What Drives Server Requirements

- **shairport-sync** is CPU-light at idle: measured at **0.01% CPU, 18 MiB RAM** on Pi 4 (streaming idle) — requires a Pi 2 or better ([source](https://github.com/mikebrady/shairport-sync))
- **librespot** (Spotify Connect): measured at **7.4% CPU, 177 MiB RAM** on Pi 4 8 GB; earlier reports of ~20% CPU on Pi 3 with the ALSA backend ([source](https://github.com/librespot-org/librespot/issues/343))
- **MPD** with streaming-only (no local library): measured at **0.6% CPU, 181 MiB RAM** — heavier on first startup with NFS-mounted library (full scan)
- **Snapserver** with 2 active clients: measured at **8.1% CPU, 102 MiB RAM** on Pi 4; scales linearly per client ([source](https://github.com/badaix/snapcast/issues/1336))
- **metadata-service**: measured at **1.3% CPU, 80 MiB RAM** (after PR #95 optimisation)

### Server Examples

| Hardware | Suitability | Notes |
|----------|-------------|-------|
| Raspberry Pi 4 (4 GB) | ✅ Good | Handles all 4 sources + 10 clients comfortably |
| Raspberry Pi 4 (2 GB) | ✅ Minimum | Sufficient for streaming-only (no local MPD library) |
| Raspberry Pi 3B+ | ⚠️ RAM-limited | 1 GB RAM — below the 2 GB minimum; full stack may OOM |
| Intel NUC / mini PC | ✅ Excellent | Ideal for large deployments or music libraries |
| Old laptop / desktop | ✅ Excellent | Any x86_64 machine with 2+ GB RAM works well |
| NAS with Docker | ✅ Good | If it supports Docker and has 2+ cores and 2+ GB RAM |

> **Note:** Pi 3B+ has only **1 GB RAM** — below the 2 GB minimum for running all containers. It may work with reduced container memory limits but is not recommended. Use Pi 4 2 GB or better. Pi 2 is too slow for simultaneous AirPlay + Spotify; avoid for server use.

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

snapMULTI uses **Docker Compose for client deployment** via the [`rpi-snapclient-usb`](../client/) submodule. This provides a self-contained stack including snapclient, cover art display, and audio visualizer — all managed together.

The client Docker stack runs three containers:
- `lollonet/rpi-snapclient-usb:latest` — Snapcast audio player
- `lollonet/rpi-snapclient-usb-fb-display:latest` — Cover art display (framebuffer)
- `lollonet/rpi-snapclient-usb-visualizer:latest` — Audio visualizer

See [README.md](../README.md) for the full installation procedure (SD card path or manual).

For minimal or manual setups without the full client submodule, snapclient can be installed natively:

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

**Client images** (from [`rpi-snapclient-usb`](../client/) submodule):

| Image | Size |
|-------|------|
| `lollonet/rpi-snapclient-usb:latest` | ~30–50 MB |
| `lollonet/rpi-snapclient-usb-fb-display:latest` | ~80–120 MB |
| `lollonet/rpi-snapclient-usb-visualizer:latest` | ~50–80 MB |

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

Prices in EUR, Italian market (March 2026). See [idealo.it](https://www.idealo.it) for current best prices on Raspberry Pi boards.

### Minimum Viable Setup — Server + 1 Client (~€200)

Two nodes: one colocated server+client, one minimal audio-only client in a second room.

**Node 1 — Server + Client colocated (Pi 4)**

| # | Item | Source | Price |
|---|------|--------|-------|
| 1 | [Raspberry Pi 4 Model B 4 GB](https://www.idealo.it/confronta-prezzi/6628198/raspberry-pi-4-model-b.html) | idealo.it | ~€55 |
| 1 | [HiFiBerry DAC2 Pro](https://www.hifiberry.com/shop/boards/dac2-pro/) — RCA analog out | hifiberry.com | €44.90 |
| 1 | MicroSD 32 GB (SanDisk Ultra A1) | amazon.it | ~€9 |
| 1 | [Official Pi 4 power supply](https://www.robotstore.it/en/Alimentatore-ufficiale-Raspberry-Pi-4-5-1V-3A) (USB-C 5.1V 3A) | robotstore.it | ~€12 |
| 1 | Case with HAT slot (passive cooling) | amazon.it | ~€12 |
| | **Subtotal** | | **~€133** |

**Node 2 — Minimal Client (Pi Zero 2 W) — audio only, no display**

| # | Item | Source | Price |
|---|------|--------|-------|
| 1 | [Raspberry Pi Zero 2 W](https://www.idealo.it/confronta-prezzi/201674823/raspberry-pi-zero-2-w.html) | idealo.it | ~€20 |
| 1 | [HiFiBerry DAC+ Zero](https://www.hifiberry.com/shop/boards/dacplus-zero/) — RCA analog out | hifiberry.com | €19.90 |
| 1 | GPIO 2×20 header (soldare) ¹ | amazon.it | ~€2 |
| 1 | MicroSD 16 GB (SanDisk Ultra A1) | amazon.it | ~€7 |
| 1 | Micro-USB power supply 5V 2.5A | amazon.it | ~€8 |
| 1 | [HiFiBerry Case for Zero](https://www.hifiberry.com/shop/cases/hifiberry-case-pi-zero/) | hifiberry.com | ~€10 |
| | **Subtotal** | | **~€67** |

> ¹ The Pi Zero 2 W is sold without GPIO header pre-soldered. Either solder a 2×20 pin header (~€2 + soldering iron) or buy a pre-soldered variant from [Pimoroni](https://shop.pimoroni.com/products/raspberry-pi-zero-2-w) (~€3 extra, no soldering needed).

> **Network:** Pi Zero 2 W has **2.4 GHz WiFi only** (no 5 GHz). This is sufficient for snapclient (requires only ~1 Mbps per stream) but may be less reliable in congested RF environments. If 5 GHz is required, use a Pi 3B+ or Pi 4 instead.

**Total system: ~€200**

---

### Alternative Audio Output — S/PDIF to AV Receiver

If a node connects to an AV receiver or home theatre system via optical cable, use [HiFiBerry Digi+](https://www.hifiberry.com/shop/boards/hifiberry-digi/) (~€30) instead of the DAC2 Pro. This shifts the D/A conversion to your receiver.

| Replace | With | Saving |
|---------|------|--------|
| HiFiBerry DAC2 Pro (€44.90) | HiFiBerry Digi+ (~€30) | −€15 per node |

---

### Enthusiast Setup (~€300+)

| Role | Hardware | Cost |
|------|----------|------|
| Server | Intel NUC or mini PC (x86_64) | ~€150+ |
| Client × 3 | Pi Zero 2 W + HiFiBerry DAC+ Zero + accessories each | ~€57 × 3 = €171 |
| Network | 5-port managed switch (TP-Link TL-SG105E) | ~€25 |

## Known Limitations

| Limitation | Details |
|------------|---------|
| **Pi Zero W (v1) as server** | Too slow for shairport-sync + librespot simultaneously |
| **librespot on ARMv6** | Not officially supported on Pi Zero v1 / Pi 1 ([details](https://github.com/librespot-org/librespot/pull/1457)). Cross-compilation possible but unsupported |
| **3.5mm audio on Pi** | Noticeable noise floor; use DAC HAT or USB DAC for quality |
| **2.4 GHz WiFi** | Works but susceptible to interference; 5 GHz preferred for >10 clients |
| **Docker on 32-bit Pi OS** | Being deprecated; use 64-bit Pi OS for Docker deployments |
| **Pi Zero 2 W with display** | 512 MB RAM is too tight if running fb-display (cover art) — use Pi 4 2GB+ for display clients |
| **Pi 4 1 GB as server** | Insufficient: all containers use ~720 MB RAM minimum; no headroom for OS |

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
| Temperature | **59.9°C** — no throttling (`throttled=0x0`) |
| System load | 0.43 / 0.53 / 0.57 (4-core → **~13% effective**) |
| Uptime | 5 days continuous |

**Docker container load** (all services active, streaming idle, 2 clients connected):

| Container | CPU % | RAM used | RAM limit |
|-----------|-------|----------|-----------|
| snapserver | 8.05% | 102 MiB | 512 MiB |
| fb-display | 11.49% | 140 MiB | 384 MiB |
| audio-visualizer | 8.00% | 31 MiB | 384 MiB |
| librespot (Spotify) | 7.37% | 177 MiB | 256 MiB |
| mpd | 0.61% | 181 MiB | 512 MiB |
| mympd | 0.00% | 108 MiB | 256 MiB |
| metadata | 1.25% | 80 MiB | 192 MiB |
| shairport-sync (AirPlay) | 0.01% | 18 MiB | 256 MiB |
| tidal-connect | 3.23% | 43 MiB | 192 MiB |
| snapclient | 2.69% | 19 MiB | 192 MiB |
| **Total** | **~42%** | **~899 MiB** | |

**System RAM:** 2520 MiB used / 7645 MiB total (1534 MiB shared/cache — Docker layer cache)

> Services without display (fb-display + audio-visualizer) would reduce CPU to ~22% and RAM to ~728 MiB — a Pi 4 2 GB is then viable.

---

### snapdigi — Client Only

| Attribute | Value |
|-----------|-------|
| Board | Raspberry Pi 4 Model B Rev 1.1 — **2 GB RAM** |
| Audio | [HiFiBerry Digi+](https://www.hifiberry.com/shop/boards/hifiberry-digi/) (`snd_rpi_hifiberry_digi`, WM8804) — **S/PDIF optical/coaxial out** |
| Network | 5 GHz WiFi |
| Temperature | **65.7°C** — no throttling (`throttled=0x0`) |
| System load | 0.68 / 0.73 / 0.77 (4-core → **~19% effective**) |
| Uptime | 2 days continuous |

**Docker container load** (client with cover art display active):

| Container | CPU % | RAM used | RAM limit |
|-----------|-------|----------|-----------|
| fb-display | **50.65%** | 120 MiB | 128 MiB ⚠ |
| audio-visualizer | 8.70% | 56 MiB | 128 MiB |
| snapclient | 1.49% | 18 MiB | 96 MiB |
| **Total** | **~61%** | **~194 MiB** | |

**System RAM:** 409 MiB used / 1669 MiB total (605 MiB buff/cache)

> ⚠ **fb-display** is at 93% of its 128 MiB RAM limit on this node. If you see OOM kills, increase the limit in your `.env` or `docker-compose.override.yml`.

> The higher temperature vs snapvideo (65.7°C vs 59.9°C) is due to the higher sustained CPU load from fb-display rendering. Still well below the 80°C throttle threshold.

---

### Minimum Hardware — Conclusions

| Use Case | Minimum Board | RAM | Reason |
|----------|---------------|-----|--------|
| Server only (no display) | Pi 4 **2 GB** | 2 GB | ~720 MiB containers + ~500 MB OS = ~1.2 GB total |
| Server + Client (no display) | Pi 4 **2 GB** | 2 GB | snapclient adds only 19 MiB |
| Server + Client (with display) | Pi 4 **4 GB** | 4 GB | fb-display + audio-visualizer add ~170 MiB; recommended headroom |
| Client only, no display | **Pi Zero 2 W** | 512 MB | snapclient: ~1.5% CPU, 18 MiB RAM |
| Client only, with display | Pi 4 **2 GB** | 2 GB | fb-display alone needs ~120 MiB; Pi Zero 2 W is too tight |

**Thermal:** Both Pi 4 boards ran continuously for days at 58–65°C without thermal throttling (snapvideo 57.9°C, snapdigi 64.7°C). Passive cooling (heatsink case) is sufficient; active cooling (fan) is not required for typical home use.
