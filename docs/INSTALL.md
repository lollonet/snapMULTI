# snapMULTI — Complete Installation Guide

🇬🇧 **English** | 🇮🇹 [Italiano](INSTALL.it.md)

This guide takes you from a blank SD card to a working multiroom audio system, step by step.

---

## What you need

| Item | Notes |
|------|-------|
| Raspberry Pi 4 (2 GB+ RAM) | Pi 5 should work; Pi 3B+ tested (minimal profile) |
| microSD card (16 GB+) | Class 10 / A1 or better. 32 GB recommended |
| Power supply | Official 15W USB-C for Pi 4 |
| A second computer | macOS, Linux, or Windows — to prepare the SD card |
| Network connection | Ethernet (recommended) or WiFi |
| Audio output | USB DAC, HiFiBerry HAT, or HDMI |

For a speaker Pi (Audio Player mode): same as above plus a way to connect speakers (HAT or USB audio device).

---

## Step 1 — Flash the SD card

Use **[Raspberry Pi Imager](https://www.raspberrypi.com/software/)** (free download for macOS, Windows, Linux).

### 1a. Choose the OS

1. Open Raspberry Pi Imager
2. Click **Choose Device** → select **Raspberry Pi 4** (or your model)
3. Click **Choose OS** → scroll to **Raspberry Pi OS (other)** → select **Raspberry Pi OS Lite (64-bit)**

> **Why Lite?** snapMULTI runs entirely in Docker. The desktop environment wastes RAM and storage. Use Lite.

### 1b. Choose the SD card

Click **Choose Storage** → select your SD card.

> If you don't see your card: make sure it is inserted. On Windows, Imager only shows removable drives — it will not show fixed disks.

### 1c. Configure the OS (important)

Click **Next** → Imager asks **"Would you like to apply OS customisation settings?"** → click **Edit Settings**.

Fill in the **General** tab:

| Field | What to enter |
|-------|---------------|
| **Set hostname** | A name for this Pi — e.g. `snapvideo` (server), `snapdigi` (speaker) |
| **Set username and password** | Any username/password — you'll use these to SSH in |
| **Configure wireless LAN** | Your WiFi SSID, password, and **country** (required for 5 GHz bands) |
| **Set locale** | Your timezone and keyboard layout |

Switch to the **Services** tab:

- Check **Enable SSH**
- Select **Use password authentication**

Click **Save**, then **Yes** to apply the settings.

> **Tip:** If connecting via Ethernet, you can skip WiFi — the Pi will get an IP via DHCP automatically.

### 1d. Write the image

Click **Yes** to erase and write. This takes 3–8 minutes depending on your SD card speed.

When Imager shows "Write Successful" — **do not click the Eject button yet** (see next step).

---

## Step 2 — Re-insert the SD card

Imager may unmount the SD card after writing. You need it mounted to run the setup script.

**macOS:** Remove and re-insert the SD card. It appears in Finder as **bootfs**.

**Linux:** Remove and re-insert. It mounts automatically, usually at `/media/$USER/bootfs`. Check with:
```bash
lsblk -o NAME,LABEL,MOUNTPOINT | grep bootfs
```

**Windows:** Remove and re-insert. It appears in File Explorer as a small drive (~250 MB) labeled **bootfs** — typically `E:\` or `F:\`. Ignore the larger partition if two appear; only the small FAT32 one is needed.

---

## Step 3 — Clone the repository

You need Git installed on your computer.

**macOS** — Git comes with Xcode Command Line Tools:
```bash
xcode-select --install
```
Or install via [Homebrew](https://brew.sh): `brew install git`

**Linux (Debian/Ubuntu):**
```bash
sudo apt install git
```

**Windows** — Install [Git for Windows](https://git-scm.com/download/win). Accept all defaults during install. Then open **Git Bash** (not PowerShell) for the next steps, or use PowerShell with the commands below.

### Clone

```bash
git clone --recurse-submodules https://github.com/lollonet/snapMULTI.git
cd snapMULTI
```

> `--recurse-submodules` is required — it also fetches the client (speaker) software. If you forget it, the script will fetch it automatically when needed.

---

## Step 4 — Prepare the SD card

Run the preparation script. It auto-detects your SD card and walks you through a short menu.

### macOS / Linux

```bash
./scripts/prepare-sd.sh
```

If auto-detection fails (multiple SD cards, unusual mount point):
```bash
./scripts/prepare-sd.sh /Volumes/bootfs        # macOS
./scripts/prepare-sd.sh /media/$USER/bootfs    # Linux
```

### Windows (PowerShell)

Open PowerShell as your regular user (not Administrator). If you haven't run scripts before:
```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

Then:
```powershell
.\scripts\prepare-sd.ps1
```

If auto-detection fails:
```powershell
.\scripts\prepare-sd.ps1 -Boot E:\    # replace E: with your SD card's drive letter
```

---

### Menu 1 — What should this Pi do?

```
  +---------------------------------------------+
  |        snapMULTI -- SD Card Setup            |
  |                                              |
  |  What should this Pi do?                     |
  |                                              |
  |  1) Audio Player                             |
  |     Play music from your server on speakers  |
  |                                              |
  |  2) Music Server                             |
  |     Central hub for Spotify, AirPlay, etc.   |
  |                                              |
  |  3) Server + Player                          |
  |     Both server and local speaker output     |
  |                                              |
  +---------------------------------------------+
```

| Option | Use when |
|--------|----------|
| **1 — Audio Player** | This Pi will be a speaker only. Streams audio from a snapMULTI server elsewhere on your network |
| **2 — Music Server** | Central hub. Hosts Spotify Connect, AirPlay, Tidal, MPD. No local speaker output |
| **3 — Server + Player** | One Pi does everything — server and local speaker. Good for starting out with a single device |

---

### Menu 2 — Where is your music? *(Music Server and Server+Player only)*

```
  +---------------------------------------------+
  |        Where is your music?                  |
  |                                              |
  |  1) Streaming only                           |
  |     Spotify, AirPlay, Tidal (no local files) |
  |                                              |
  |  2) USB drive                                |
  |     Plug in before powering on the Pi        |
  |                                              |
  |  3) Network share (NFS/SMB)                  |
  |     Music on a NAS or another computer       |
  |                                              |
  |  4) I'll set it up later                     |
  |     Mount music dir manually after install   |
  |                                              |
  +---------------------------------------------+
```

| Option | Notes |
|--------|-------|
| **1 — Streaming only** | No local music library. Spotify, AirPlay and Tidal work without any files |
| **2 — USB drive** | Plug your USB drive into the Pi *before* powering on. It auto-mounts |
| **3 — Network share** | You'll be asked for server hostname/IP and share path. NFS for Linux/Mac/NAS; SMB for Windows shares. Credentials are stored on the SD card temporarily and removed after first boot |
| **4 — Set up later** | Skips music config. Add your library to `/opt/snapmulti/.env` after install (see [USAGE.md](USAGE.md)) |

If you choose **Network share**, you'll then enter:
- **NFS:** server hostname or IP (e.g. `nas.local`) and export path (e.g. `/volume1/music`)
- **SMB:** server hostname or IP, share name (e.g. `Music`), and optional username/password

---

### What the script does

After you answer the menus, `prepare-sd.sh` / `prepare-sd.ps1`:

1. Copies the installer and config files onto the boot partition
2. Patches the Pi's first-boot mechanism (`user-data` on Bookworm) to run the installer automatically
3. Sets a temporary 800×600 display resolution for the install progress screen
4. Verifies all files are present
5. Unmounts / ejects the SD card

You should see **"All checks passed."** and **"SD card ready!"** at the end.

---

## Step 5 — Boot the Pi

1. **Remove the SD card** from your computer
2. Insert it into the Pi
3. Connect power
4. **Wait ~5–10 minutes** — the Pi installs Docker, pulls images, and starts all services

### What you'll see on HDMI

If you have a monitor or TV connected, the Pi shows a text progress display:

```
snapMULTI Auto-Install
======================

[ ] Waiting for network...
[>] Installing Docker...          [=====>          ] 40%
[ ] Pulling images...
[ ] Starting services...
[ ] Verifying health...
```

The Pi **reboots automatically** when installation is complete. After the reboot, the display goes dark (normal — no desktop on Lite OS).

> If the HDMI stays blank throughout: the Pi is still installing via SSH in the background. Wait 10 minutes before assuming something went wrong.

---

## Step 6 — Verify it works

### Find the Pi on your network

From your computer, ping the Pi using its hostname:

```bash
ping snapvideo.local     # replace with the hostname you chose in Imager
```

If ping works, SSH in:

```bash
ssh <username>@snapvideo.local
```

> **Windows users:** Use Windows Terminal, PowerShell, or [PuTTY](https://putty.org) with `snapvideo.local` as the host.

> **If `.local` doesn't resolve:** Use the IP address instead. Find it in your router's DHCP client list, or check the HDMI output after reboot — the Pi prints its IP on the console.

### Check running containers

```bash
sudo docker ps --format 'table {{.Names}}\t{{.Status}}'
```

**Music Server (option 2 or 3)** — expected output:
```
NAMES              STATUS
snapserver         Up X minutes (healthy)
shairport-sync     Up X minutes (healthy)
librespot          Up X minutes (healthy)
mpd                Up X minutes (healthy)
mympd              Up X minutes (healthy)
metadata           Up X minutes (healthy)
```
On Raspberry Pi (ARM): `tidal-connect` also appears if you have a Pi 4/5.

**Audio Player (option 1)** — expected output:
```
NAMES              STATUS
snapclient         Up X minutes (healthy)
audio-visualizer   Up X minutes (healthy)
fb-display         Up X minutes (healthy)
```
`audio-visualizer` and `fb-display` only appear if an HDMI display was connected at first boot.

### Open the web interface (server only)

Open your browser and go to:

```
http://snapvideo.local:8180
```

This is **myMPD** — browse your music library, build playlists, control playback.

The **Snapcast web UI** (control which speaker plays what) is at:

```
http://snapvideo.local:1780
```

---

## Connecting music sources

| Source | What to do after install |
|--------|--------------------------|
| **Spotify** | Open Spotify app → Devices → select **"snapvideo Spotify"** (Premium required) |
| **AirPlay** | iPhone/iPad/Mac → AirPlay icon → select **"snapvideo AirPlay"** |
| **Tidal** | Open Tidal app → Cast → select **"snapvideo Tidal"** (ARM/Pi only) |
| **Music library** | Open `http://snapvideo.local:8180` and browse your files |
| **Snapcast app** | [Android](https://play.google.com/store/apps/details?id=de.badaix.snapcast) / [iOS (SnapForge)](https://apps.apple.com/app/snapforge/id6670397895) — connect to `snapvideo.local` |

---

## Adding more speaker Pis

For each additional speaker:

1. Flash a new SD card with Raspberry Pi Imager
   - Set a **unique hostname** (e.g. `snapdigi`, `kitchen`, `bedroom`)
   - Same user/password as your server is convenient but not required
2. Re-insert → run `prepare-sd.sh` → choose **1) Audio Player**
3. Boot → the speaker Pi auto-discovers the server via mDNS

The new speaker appears in the Snapcast web UI at `http://snapvideo.local:1780` within ~30 seconds of booting.

---

## Troubleshooting first boot

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| HDMI blank, no progress | Normal on headless boot | Wait 10 min; check with `ping snapvideo.local` |
| `ping snapvideo.local` fails | Pi not on network yet | Wait 2 min; if still failing, check WiFi country setting in Imager |
| `.local` resolves but SSH refused | SSH not yet started | Wait 1–2 more min |
| SSH works but containers missing | Installation still running | Run `sudo journalctl -u cloud-init -f` to watch progress |
| Containers in restart loop | Image pull failed (network) | Run `sudo docker compose logs -f` in `/opt/snapmulti` |
| Wrong hostname | Set wrong value in Imager | Re-flash SD, redo from Step 1 |
| `prepare-sd.sh`: boot partition not found | SD not re-inserted after Imager | Remove SD, re-insert, run script again |
| Windows: script won't run | Execution policy | Run `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` first |

For post-install issues see [Troubleshooting in USAGE.md](USAGE.md#troubleshooting).

---

## What's installed where

| Path | Contents |
|------|----------|
| `/opt/snapmulti/` | Server: Docker Compose files, config, data |
| `/opt/snapclient/` | Client: Docker Compose files, audio config |
| `/opt/snapmulti/.env` | Server settings (edit to change config) |
| `/opt/snapclient/.env` | Client settings (edit to change config) |

To change settings after install:
```bash
sudo nano /opt/snapmulti/.env      # or /opt/snapclient/.env for speaker Pi
cd /opt/snapmulti
sudo docker compose up -d           # NOT restart — restart doesn't reload .env
```

---

## Network requirements

- The Pi and your phone/computer must be on the **same subnet** (same router) for mDNS (`.local` hostnames) and auto-discovery to work
- Ports that must be reachable from other devices on your LAN:

| Port | Service |
|------|---------|
| 1704 | Snapcast audio streaming |
| 1705 | Snapcast control |
| 1780 | Snapcast web UI |
| 6600 | MPD |
| 8082 | Metadata WebSocket |
| 8083 | Metadata HTTP (artwork) |
| 8180 | myMPD web UI |

- mDNS uses UDP 5353 — if you have multiple VLANs, you'll need an mDNS repeater or set static IPs in `.env`
