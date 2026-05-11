# Quick Start

Turn a Raspberry Pi into a multiroom audio system. Cast from Spotify, AirPlay, or your music library to speakers in every room.

## What You Need

- Raspberry Pi 4 or 5 (2 GB+ RAM)
- microSD card (16 GB+)
- A computer to prepare the SD card — macOS, Linux, or **Windows**

## Install (5 minutes)

### Step 1 — Flash the SD card

Use [Raspberry Pi Imager](https://www.raspberrypi.com/software/):

1. Choose **Raspberry Pi OS Lite (64-bit)**.
2. Click the **gear icon** (or `Ctrl/Cmd+Shift+X`) to open advanced options.
3. Fill in:
   - **Hostname** (e.g. `pi-audio` — the name you'll use to reach it on the network)
   - **Username + password** (default user; you'll use these to log in)
   - **WiFi** (SSID + password, or leave empty if using Ethernet)
   - **☑ Enable SSH** with password authentication

> **What does "Enable SSH" do?** It turns on the remote shell on the Pi so the install scripts can finish the setup over the network during first boot. Without it, the Pi boots but you can't talk to it without a keyboard + monitor. Always tick this box.
>
> *Already flashed without SSH enabled?* Drop an empty file named `ssh` (no extension) onto the SD card's `bootfs` partition before first boot — Raspberry Pi OS detects it and enables SSH automatically.

### Step 2 — Get the snapMULTI project files

Pick one. Both end up with a folder called `snapMULTI` next to your prompt.

**A. Download as ZIP** (no git required, easiest for Windows / non-developers):

1. Open <https://github.com/lollonet/snapMULTI/releases/latest>
2. Under **Assets**, download **`Source code (zip)`**
3. Unzip it. The folder will be named `snapMULTI-<version>` (e.g. `snapMULTI-0.7.3`) — rename it to **`snapMULTI`** so the commands below work as-is.

**B. Clone with git** (recommended if you already have git — easy to update later):

```bash
git clone https://github.com/lollonet/snapMULTI.git
```

### Step 3 — Run the prep script

Re-insert the freshly-flashed SD card so the `bootfs` partition appears on your computer, then open a terminal in the folder that *contains* `snapMULTI/`:

**macOS / Linux:**

```bash
./snapMULTI/scripts/prepare-sd.sh
```

**Windows (PowerShell):**

```powershell
.\snapMULTI\scripts\prepare-sd.ps1
```

> First time running a PowerShell script? Windows blocks unsigned scripts by default. Allow them once for your user:
>
> ```powershell
> Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
> ```

The script asks what to install:

1. **Audio Player** — a speaker that plays from your server
2. **Music Server** — Spotify, AirPlay, Tidal, music library
3. **Server + Player** — both on one Pi

### Step 4 — Boot the Pi

Eject the SD card, insert it in the Pi, power on. Wait ~10 minutes. Done.

## URLs after install

All on the server Pi — replace `hostname` with what you set in Step 1:

| URL | What it does |
|-----|--------------|
| `http://hostname.local:1780` | **Snapweb** — control room volumes, mute, group/move speakers, see what's playing |
| `http://hostname.local:8180` | **myMPD** — browse and play the music library (NFS / USB / local files) |
| `http://hostname.local:8083/status` | **System status page** — container health, source presence, last smoke results (refreshed every 5 min) |
| `http://hostname.local:8083/health` | **Health check** — returns `{"status":"ok"}` when the server is up; handy for uptime probes / monitoring |

Bookmark `:1780` and `:8083/status` — they cover 90% of day-to-day use.

## Play Music

| Source | How |
|--------|-----|
| **Spotify** | Open app, select device: "*hostname* Spotify" |
| **AirPlay** | AirPlay icon, select "*hostname* AirPlay" |
| **Music library** | Open `http://hostname.local:8180` (myMPD) |

## Add More Speakers

Flash another SD card, choose "Audio Player", insert in any Pi. It finds the server automatically.

## Updating

Reflash the SD card with the latest version. That's it.

If you have a music library (NFS/USB), extract the database first so MPD doesn't rescan:

```bash
./scripts/backup-from-sd.sh    # reads backup from old SD
# flash with Imager, then:
./scripts/prepare-sd.sh        # includes database automatically
```

---

**Problems?** See the [full install guide](docs/INSTALL.md).
**Hardware details?** See [hardware guide](docs/HARDWARE.md).
