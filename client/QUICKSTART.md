# Quick Start Guide (Manual Setup)

Get your Raspberry Pi Snapcast client running manually.

> **Prefer zero-touch?** Use the [snapMULTI unified installer](https://github.com/lollonet/snapMULTI) — choose "Audio Player" option. No SSH or terminal needed.

## Prerequisites

- Raspberry Pi 4 (2GB+)
- One of the supported audio HATs (HiFiBerry, IQaudio, Allo, JustBoom) or USB audio device
- microSD card (16GB+)
- Display (any resolution from 800x480 to 4K) — optional for headless
- Computer with Raspberry Pi Imager
- **[snapMULTI](https://github.com/lollonet/snapMULTI) server** already running on your network

## Supported Audio HATs

See the [Supported Audio HATs](README.md#supported-audio-hats) table in the README for the full list (17 HATs + USB audio).

## Step 1: Flash SD Card

1. Download **Raspberry Pi Imager**: https://www.raspberrypi.com/software/
2. Select **Raspberry Pi OS Lite (64-bit)**
3. Choose your SD card as the target
4. Click **Next** → **Edit Settings** to configure:
   - Set hostname (e.g. `snapdigi`)
   - Set username and password
   - Configure WiFi (SSID, password, and country)
   - Enable SSH (Services tab)
5. Click **Write** and wait for completion

## Step 2: First Boot

1. Attach your audio HAT to Raspberry Pi GPIO pins (or connect USB audio device)
2. Connect display (optional):
   - **9" screen**: DSI or HDMI
   - **4K TV**: HDMI
3. Insert SD card into Raspberry Pi
4. Power on and wait ~30 seconds for boot

## Step 3: Copy Project Files

From your computer, clone the repo and copy files to the Pi:

```bash
git clone https://github.com/lollonet/snapclient-pi.git
scp -r snapclient-pi <username>@<hostname>.local:/home/<username>/
```

Then SSH into the Pi:

```bash
ssh <username>@<hostname>.local
```

## Step 4: Run Setup Script

On the Raspberry Pi:

```bash
cd ~/snapclient-pi
sudo bash common/scripts/setup.sh
```

The script will:
1. **Auto-detect your audio HAT** (or prompt you to select from 16 options)
2. **Prompt you to select display resolution** (6 presets + custom)
3. Auto-generate CLIENT_ID from hostname
4. Optionally ask for your Snapserver IP (leave empty for mDNS autodiscovery)
5. Install Docker CE and dependencies
6. Configure audio HAT, ALSA, and boot settings
7. Set up framebuffer display at selected resolution
8. Create systemd services for auto-start

The script takes 3-5 minutes. It uses pre-built Docker images from Docker Hub (no building required).

## Step 5: Reboot

```bash
sudo reboot
```

## Verification

After reboot (~30 seconds), SSH back in and check:

```bash
sudo docker ps --format 'table {{.Names}}\t{{.Status}}'
```

Expected output:
```
NAMES              STATUS
snapclient         Up X minutes (healthy)
audio-visualizer   Up X minutes (healthy)
fb-display         Up X minutes (healthy)
```

`audio-visualizer` and `fb-display` only appear if an HDMI display was connected at boot.

## Configuration

To change settings after installation:

```bash
sudo nano /opt/snapclient/.env
cd /opt/snapclient
sudo docker compose up -d   # NOT restart — restart doesn't pick up .env changes
```

See [`common/.env.example`](common/.env.example) for all available settings.

## Next Steps

- See **[README.md](README.md)** for full documentation
- Set up additional clients for multiroom audio
- Install an MPD control app (MPDroid, Cantata, etc.) to browse your music library
