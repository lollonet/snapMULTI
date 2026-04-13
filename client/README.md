# SnapClient Pi

> Raspberry Pi Snapcast client with HiFiBerry support and cover display.

[![CI](https://github.com/lollonet/snapMULTI/actions/workflows/validate.yml/badge.svg)](https://github.com/lollonet/snapMULTI/actions/workflows/validate.yml)
[![downloads](https://img.shields.io/docker/pulls/lollonet/snapclient-pi?color=green)](https://hub.docker.com/r/lollonet/snapclient-pi)
[![Donate](https://img.shields.io/badge/Donate-PayPal-yellowgreen)](https://paypal.me/lolettic)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

> **Requires [snapMULTI](https://github.com/lollonet/snapMULTI) server.** This is the client component of the snapMULTI multiroom audio system. Install the server first — the unified installer handles both server and client setup.

Docker-based Snapcast client for Raspberry Pi with HiFiBerry DACs, featuring synchronized multiroom audio and visual cover art display.

## Client Architecture

```
                    snapMULTI Server
                    (on your network)
                          │
                   WiFi / Ethernet
                          │
              ┌───────────┴───────────┐
              │   THIS PI (Client)    │
              │                       │
              │  ┌─────────────────┐  │
              │  │   snapclient    │  │  ← receives audio stream
              │  │   (port 1704)   │  │
              │  └────────┬────────┘  │
              │           │           │
              │  ┌────────┴────────┐  │
              │  │  Audio HAT /    │  │  ← plays through speakers
              │  │  USB DAC        │  │
              │  └─────────────────┘  │
              │                       │
              │  ┌─────────────────┐  │
              │  │  fb-display     │  │  ← shows cover art (optional)
              │  │  (framebuffer)  │  │
              │  └─────────────────┘  │
              │                       │
              │  ┌─────────────────┐  │
              │  │ audio-visualizer│  │  ← spectrum analyzer (optional)
              │  │  (port 8081)    │  │
              │  └─────────────────┘  │
              └───────────────────────┘
```

For the full system architecture (server + all clients), see [snapMULTI README](https://github.com/lollonet/snapMULTI#how-it-works).

## Features

- 🎵 **Synchronized Audio**: Multi-room playback via Snapcast
- 🎨 **Cover Display**: Full-screen album art with track metadata (MPD embedded art → iTunes → MusicBrainz)
- ⏱️ **Song Progress Bar**: Elapsed/duration time with visual progress for file playback (uses local clock for smooth updates)
- 📊 **Real-Time Spectrum Analyzer**: dBFS FFT visualizer with half/third-octave bands, auto-gain normalization
- 😴 **Standby Screen**: Retro hi-fi artwork with breathing animation when idle
- 🔍 **mDNS Autodiscovery**: Snapserver found automatically — no IP configuration needed
- 🎛️ **Multiple Audio HATs**: Support for 17 Raspberry Pi audio HATs + USB audio
- 📺 **Flexible Display**: Direct framebuffer rendering, 6 resolution presets (800x480 to 4K)
- ⚡ **Zero-Touch Install**: Via [snapMULTI](https://github.com/lollonet/snapMULTI) unified installer — flash SD, power on, auto-detects HAT
- 🐳 **Docker-based**: Pre-built images for easy deployment
- 🔄 **Auto-start**: Systemd services for automatic startup
- 🔒 **Security Hardened**: Input validation, non-root containers, granular capabilities
- 💾 **Read-Only Filesystem**: SD card protection with overlayfs, enabled by default (preserves SD card lifespan)
- 📡 **WebSocket Metadata**: Real-time track info push to display (no polling from clients)
- 📊 **Resource Limits**: Auto-detected CPU/memory limits based on Pi RAM

## Supported Audio HATs

| HAT | Type | Output |
|-----|------|--------|
| **HiFiBerry DAC+** | Analog | Line out, headphones |
| **HiFiBerry DAC+ Standard/clone** | Analog | Line out (EEPROM-less boards) |
| **HiFiBerry Digi+** | S/PDIF | Digital coax/optical |
| **HiFiBerry DAC2 HD** | Analog HD | High-res line out |
| **HiFiBerry AMP2** | Analog+Amp | Speaker terminals |
| **HiFiBerry DAC+ ADC Pro** | Analog | Line in/out + recording |
| **IQaudio DAC+** | Analog | Line out |
| **IQaudio DigiAMP+** | Analog+Amp | Speaker terminals |
| **IQaudio Codec Zero** | Analog | Line in/out |
| **Allo Boss DAC** | Analog | High-res line out |
| **Allo DigiOne** | S/PDIF | Digital coax/optical |
| **JustBoom DAC** | Analog | Line out, headphones |
| **JustBoom Digi** | S/PDIF | Digital coax/optical |
| **InnoMaker DAC PRO** | Analog HD | High-res line out (ES9038Q2M) |
| **Waveshare WM8960** | Analog | Line in/out |
| **USB Audio** | Varies | Any USB DAC/soundcard |

## Hardware Requirements

### Common Components
- Raspberry Pi 4 (2GB+)
- microSD card (16GB+)
- Display: 9" touchscreen (1024x600) or 4K HDMI TV (3840x2160)
- One of the supported audio HATs listed above, or a USB audio device

### Compatibility

For the full hardware compatibility matrix (Pi models, RAM requirements, resource profiles, display support), see [snapMULTI Hardware Guide](https://github.com/lollonet/snapMULTI/blob/main/docs/HARDWARE.md#client-requirements).

## Installation

### Unified Installer (Recommended)

Use the snapMULTI unified installer — it handles both server and client:

1. Flash **Raspberry Pi OS Lite (64-bit)** with Raspberry Pi Imager
   - Configure WiFi and hostname in the Imager settings
2. Re-insert SD card in your computer
3. Run `prepare-sd.sh` from the [snapMULTI](https://github.com/lollonet/snapMULTI) project
4. Choose **"Audio Player"** (client only) or **"Server + Player"** (both)
5. Eject SD card, insert in Pi, power on — installation takes ~5-10 minutes

> **HAT auto-detection**: Uses a 3-step detection chain — EEPROM (`/proc/device-tree/hat/product`) → ALSA card name → I2C bus scan. The I2C scan detects chip families used by EEPROM-less boards (PCM5122, WM8960, WM8804), then maps them to compatible profiles. That fallback is reliable for generic bring-up, but it cannot always preserve exact board identity for every no-EEPROM variant. Falls back to USB audio if nothing is found.

> **Custom settings**: Edit `snapmulti/client/snapclient.conf` on the boot partition before step 5 to override defaults (resolution, display mode, band mode, snapserver host).

## Manual Setup

For advanced users who prefer interactive control, see **[QUICKSTART.md](QUICKSTART.md)**.

### Summary

1. Flash Raspberry Pi OS Lite (64-bit) to microSD card
2. Enable SSH and WiFi in Raspberry Pi Imager settings
3. Boot Pi with your audio HAT attached
4. Copy project files and run `sudo bash common/scripts/setup.sh`
5. Select your audio HAT (16 options) and display resolution (6 presets + custom)
6. Optionally enter Snapserver IP (or leave empty for mDNS autodiscovery) and reboot

The setup script installs Docker CE, automatically configures your audio HAT and ALSA, sets up the cover display for your chosen resolution, and creates systemd services for auto-start. Client ID is automatically generated from hostname.

## Project Structure

```
client/                           # Part of the snapMULTI monorepo
├── install/
│   └── snapclient.conf         # Config defaults (AUDIO_HAT=auto)
│
├── common/
│   ├── scripts/
│   │   ├── setup.sh            # Main installation script (--auto mode)
│   │   ├── discover-server.sh  # mDNS server discovery (boot-time)
│   │   ├── display.sh          # Display detection functions
│   │   ├── display-detect.sh   # Boot-time display profile reconciliation
│   │   └── ro-mode.sh          # Read-only filesystem management
│   ├── docker-compose.yml      # Docker services (snapclient, visualizer, fb-display)
│   ├── .env.example            # Environment template
│   ├── audio-hats/             # Audio HAT configurations (17 files)
│   └── docker/
│       ├── snapclient/         # Snapclient Docker image
│       ├── audio-visualizer/   # Spectrum analyzer (dBFS)
│       └── fb-display/         # Framebuffer display renderer
│
└── tests/                      # Test and validation scripts
```

> **Note**: This is the `client/` directory of the [snapMULTI](https://github.com/lollonet/snapMULTI) monorepo. The server's `prepare-sd.sh` copies the necessary files to the SD card; the server's `firstboot.sh` runs `setup.sh --auto` during first boot.

## Configuration

The setup script auto-generates `/opt/snapclient/.env` from your selections. See [`common/.env.example`](common/.env.example) for all available settings (server, audio, display, spectrum, resource limits, read-only filesystem).

To change settings after installation:

```bash
sudo nano /opt/snapclient/.env
cd /opt/snapclient
sudo docker compose up -d   # NOT restart — restart doesn't pick up .env changes
```

## Post-Install Verification

Follow these steps in order after installation to confirm everything works.

### 1. Docker services running

```bash
sudo docker ps --format 'table {{.Names}}\t{{.Status}}'
```

Expected: all containers show `Up ... (healthy)`:

```
NAMES              STATUS
fb-display         Up 2 minutes (healthy)
audio-visualizer   Up 2 minutes (healthy)
snapclient         Up 2 minutes (healthy)
```

### 2. Audio device detected

```bash
aplay -l
```

Expected: your HAT or USB device appears (e.g. `card 0: sndrpihifiberry`).

### 3. Snapserver connection

```bash
sudo docker logs snapclient 2>&1 | grep -i "connected to"
```

Expected: `Connected to <server-ip>` message. If missing, check mDNS or set `SNAPSERVER` in `.env`.

### 4. Display rendering

For framebuffer mode, the screen should show cover art or standby artwork. Verify the framebuffer is accessible:

```bash
sudo docker logs fb-display 2>&1 | head -5
```

Expected: `Framebuffer: <width>x<height>, <bpp>bpp, stride=<stride>`.

### 5. Spectrum analyzer

Port 8081 is a WebSocket-only endpoint. Check the container logs:

```bash
sudo docker logs audio-visualizer 2>&1 | tail -5
```

Expected: `Starting spectrum analyzer on port 8081` and periodic data lines when audio is playing.

### 6. Read-only filesystem (if enabled)

```bash
ro-mode status
```

Expected: `Read-only mode: enabled` with overlay active. Use `ro-mode disable && sudo reboot` to make changes.

## Troubleshooting

### Audio

| Problem | Cause | Fix |
|---------|-------|-----|
| No sound output | Wrong ALSA device | Check `SOUNDCARD` in `.env` matches `aplay -l` output. Use `default:CARD=<name>` format |
| Choppy/stuttering | Buffer underrun | Increase `ALSA_BUFFER_TIME` (default 200000) or `ALSA_FRAGMENTS` (default 4) in `.env` |
| Spectrum shows silence | No loopback | Snapclient must output to `default` device, not `hw:` directly |

### Display

| Problem | Cause | Fix |
|---------|-------|-----|
| Black screen | Wrong display mode | Check `COMPOSE_PROFILES` in `.env` (should be `framebuffer`). Display is auto-detected at boot by `display-detect.sh` |
| Cover art not updating | Stale metadata connection | `sudo docker restart fb-display` |
| Wrong resolution | Override active | Remove `DISPLAY_RESOLUTION` from `.env` to auto-detect from framebuffer |
| Stuck at 800x600 | Install video mode | Remove `video=HDMI-A-1:800x600@60` from `/boot/firmware/cmdline.txt` and reboot |
| Display not detected at boot | Service not running | Check `sudo systemctl status snapclient-display`; runs `display-detect.sh` to set `COMPOSE_PROFILES` |

### Network

| Problem | Cause | Fix |
|---------|-------|-----|
| Snapserver not found | mDNS blocked | Set `SNAPSERVER=<ip>` in `.env`, or check firewall allows port 1704 |
| Metadata disconnects | Server restart | fb-display auto-reconnects; check `SNAPSERVER_HOST` in `.env` points to server |

### Docker

| Problem | Cause | Fix |
|---------|-------|-----|
| Containers won't start | Resource limits | Check `sudo docker stats --no-stream`; reduce limits in `.env` if OOM |
| `docker compose` not found | Old Docker | Run setup.sh again — it installs Docker CE with Compose v2 plugin |
| overlay2 driver fails | Read-only FS | Expected on overlayfs root — setup.sh configures `fuse-overlayfs` automatically |

### Read-Only Filesystem

| Problem | Cause | Fix |
|---------|-------|-----|
| Cannot install/update | Overlay active | `ro-mode disable && sudo reboot`, then make changes |
| Docker data lost on reboot | Expected | Docker volumes are on the overlay; persistent data uses bind mounts |
| `/opt/snapclient` missing | Overlay reset | Re-run setup.sh or restore from backup |

## Docker Image

This project uses pre-built Docker images:
- **Images**: `lollonet/snapclient-pi-*:latest` (Docker Hub) (snapclient, visualizer, fb-display)
- **Platform**: ARM64 (Raspberry Pi 4). Python display code also runs natively on other Linux architectures (e.g. PowerPC)
- **Requires**: Docker Compose v2+ (installed automatically by setup.sh via Docker CE)

All containers run with:
- **Healthchecks** with dependency ordering (fb-display waits for visualizer, etc.)
- **Resource limits** auto-detected based on Pi RAM (minimal/standard/performance profiles)
- **Security hardening**: no-new-privileges, capability drops, tmpfs restrictions

Update to latest version:
```bash
# If read-only mode is enabled:
sudo ro-mode disable && sudo reboot
# After reboot:
cd /opt/snapclient
sudo docker compose pull
sudo docker compose up -d
sudo ro-mode enable && sudo reboot
```

## Resources

- **Snapcast**: https://github.com/badaix/snapcast
- **HiFiBerry**: https://www.hifiberry.com/docs/
- **Raspberry Pi OS**: https://www.raspberrypi.com/documentation/
- **MPD Clients**: https://www.musicpd.org/clients/

## Development

### Git Hooks (Local CI)

Install pre-push hooks to run CI checks locally before pushing:

```bash
bash dev/install-hooks.sh
```

This installs a pre-push hook that runs:
- Shellcheck (bash linting)
- Hadolint (Dockerfile linting)
- HAT configuration tests
- Syntax validation

To bypass: `git push --no-verify`

### Contributing

1. Create a feature branch from `main`
2. Make changes and commit
3. Pre-push hook runs automatically
4. Push and create a PR
5. CI must pass before merge

## Acknowledgments

This project is built on:

- **[Snapcast](https://github.com/badaix/snapcast)** by Johannes Pohl — the multiroom audio streaming engine
- **[snapMULTI](https://github.com/lollonet/snapMULTI)** — the server that powers this client

Part of the [snapMULTI ecosystem](https://github.com/lollonet/snapMULTI#snapmulti-ecosystem).

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Notes

- Installation is done via the [snapMULTI unified installer](https://github.com/lollonet/snapMULTI) — `setup.sh` is called automatically by `firstboot.sh`
- Docker CE is installed during first boot (not the Debian `docker.io` package)
- ALSA configuration is automatically generated based on the detected audio HAT
- Metadata is served by the snapMULTI server; fb-display connects via WebSocket (port 8082) for track info and HTTP (port 8083) for artwork
- All configuration is done via `.env` files — no hardcoded IP addresses
- Read-only filesystem (overlayroot) is enabled by default — use `ro-mode disable` for changes
