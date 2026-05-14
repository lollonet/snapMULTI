# snapMULTI — Complete Installation Guide

🇬🇧 **English** | 🇮🇹 [Italiano](INSTALL.it.md)

This guide takes you from a blank SD card to a working multiroom audio system, step by step.

---

## Fast path

Already comfortable with Raspberry Pi Imager and terminals? This is the whole install in one pass:

1. Flash **Raspberry Pi OS Lite (64-bit)** with Raspberry Pi Imager.
2. In Imager settings, set hostname, username/password, WiFi country/network, and enable SSH.
3. When the write finishes, remove and re-insert the SD so the `bootfs` partition mounts.
4. Download the latest snapMULTI release ZIP or `git clone https://github.com/lollonet/snapMULTI.git`.
5. From the snapMULTI folder, run `./scripts/prepare-sd.sh` on macOS/Linux or `.\scripts\prepare-sd.ps1` on Windows.
6. Choose what this Pi should do: **Audio Player**, **Music Server**, or **Server + Player**.
7. Eject the SD, boot the Pi, and wait about 10-15 minutes. It installs, verifies, then reboots once.
8. Open `http://<hostname>.local:1780` for Snapweb or `http://<hostname>.local:8180` for myMPD.

If any step is unclear, continue with the detailed walkthrough below. If first boot fails, recover the diagnostic bundle from the SD card as described in [TROUBLESHOOTING.md — When in doubt](TROUBLESHOOTING.md#when-in-doubt--grab-the-diagnostic-bundle).

---

## What you need

| Item | Notes |
|------|-------|
| Raspberry Pi 4 or 5 (2 GB+ RAM) | Pi 5 fully supported; Pi 3B+ tested (minimal profile) |
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

> **Important: 64-bit is required.** Do not select the 32-bit version — snapMULTI Docker images are built for `arm64` only. This applies to all Pi models including Pi Zero 2 W (Imager may default to 32-bit for it — make sure to select 64-bit).

### 1b. Choose the SD card

Click **Choose Storage** → select your SD card.

> If you don't see your card: make sure it is inserted. On Windows, Imager only shows removable drives — it will not show fixed disks.

### 1c. Configure the OS (important)

Click **Next** → Imager asks **"Would you like to apply OS customisation settings?"** → click **Edit Settings**.

Fill in the **General** tab:

| Field | What to enter |
|-------|---------------|
| **Set hostname** | A name for this Pi — e.g. `pi-server` (server), `pi-display` (speaker) |
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

## Step 3 — Get the snapMULTI files

Pick one of the two options. Both produce a folder named `snapMULTI/` that the next step expects.

### Option A — Download the ZIP (no Git required)

1. Open [https://github.com/lollonet/snapMULTI/releases/latest](https://github.com/lollonet/snapMULTI/releases/latest) in your browser
2. Under **Assets**, click **Source code (zip)** to download the latest release
3. Extract the ZIP — you get a folder named `snapMULTI-<version>` (e.g. `snapMULTI-0.7.4`). The folder name doesn't matter — `prepare-sd.sh` finds its project root via its own location
4. Open a terminal inside that extracted folder

> Prefer the tagged release ZIP over the green **Code → Download ZIP** button on the repo home page — the latter ships the `main` branch, which may include unreleased work-in-progress.
>
> Run `./scripts/prepare-sd.sh` from inside the project folder. The folder name does not matter — `prepare-sd.sh` resolves its own path. Alternatively, from the parent folder, use `./<folder-name>/scripts/prepare-sd.sh`.

### Option B — Clone with Git (recommended for updates)

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

Then:
```bash
git clone https://github.com/lollonet/snapMULTI.git
cd snapMULTI
```

> The repository includes both server and client software in a single monorepo.

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
| **3 — Server + Player** | One Pi does everything — server and local speaker. **Choose this if you only have one Pi** and want to play music on it directly |

> **Pi Zero 2 W users:** the installer behaves differently because the board has only 512 MB RAM:
> - **Choice 1 (Audio Player)** — works, but the profile is auto-promoted to `client-native`: native snapclient `.deb`, no Docker, no cover-art display, single-client role only. The full Docker stack does not fit
> - **Choices 2 and 3** — the first boot aborts with `Pi Zero 2W (512 MB RAM) cannot host the snapMULTI server stack` and stops. The server needs at least a Pi 3 B+ with 1 GB RAM. Reflash the SD card with choice 1, or use a different Pi
>
> See [HARDWARE.md — Pi Zero 2 W Notes](HARDWARE.md#pi-zero-2-w-notes) for the full constraint list.

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
| **4 — Set up later** | Skips music config. Add your library to `/opt/snapmulti/.env` after install (see [ADVANCED.md — Music library on the network](ADVANCED.md#music-library-on-the-network)) |

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

> If the HDMI stays blank throughout: the installation is still running in the background — `firstboot.sh` is a systemd service that does not need a display. Wait 10 minutes; to check progress without a screen, `ssh <username>@<hostname>.local` and run `sudo journalctl -u snapmulti-firstboot.service -f`.

---

## Step 6 — Verify it works

> **Hostname placeholder.** From here on, `<hostname>.local` means the hostname you set in Imager at Step 1c. If you set `myradio`, use `myradio.local` everywhere `<hostname>.local` appears below.

### Find the Pi on your network

From your computer, ping the Pi using its hostname:

```bash
ping <hostname>.local
```

If ping works, SSH in:

```bash
ssh <username>@<hostname>.local
```

> **Windows users:** Use Windows Terminal, PowerShell, or [PuTTY](https://putty.org) with `<hostname>.local` as the host.

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
http://<hostname>.local:8180
```

This is **myMPD** — browse your music library, build playlists, control playback.

The **Snapcast web UI** (control which speaker plays what) is at:

```
http://<hostname>.local:1780
```

If everything shows "healthy" and the web interfaces load — your server is ready. Try playing a track from Snapweb (`http://<hostname>.local:1780`) or cast from Spotify/AirPlay to confirm audio works.

---

## Connecting music sources

| Source | What to do after install |
|--------|--------------------------|
| **Spotify** | Open Spotify app → Devices → select **"`<hostname>` Spotify"** (Premium required) |
| **AirPlay** | iPhone/iPad/Mac → AirPlay icon → select **"`<hostname>` AirPlay"** |
| **Tidal** | Open Tidal app → Cast → select **"`<hostname>` Tidal"** (ARM/Pi only) |
| **Music library** | Open `http://<hostname>.local:8180` and browse your files |
| **Snapcast app** | [Android](https://play.google.com/store/apps/details?id=de.badaix.snapcast) — connect to `<hostname>.local` |

---

## Next steps

| Goal | Where |
|------|-------|
| Add another speaker (multi-room), connect a NAS library, customise `.env`, manual deploy | [ADVANCED.md](ADVANCED.md) |
| Something failed (first boot, post-install, mDNS, audio) | [TROUBLESHOOTING.md](TROUBLESHOOTING.md) |
| Hardware matrix, network requirements, Pi Zero 2 W details | [HARDWARE.md](HARDWARE.md) |
| Architecture, audio sources, security model | [USAGE.md](USAGE.md) |

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
- Most home networks work out of the box — no port forwarding or firewall changes needed
- For the full list of ports and firewall rules, see [Advanced Guide — Firewall rules](ADVANCED.md#firewall-rules)
- mDNS uses UDP 5353 — if you have multiple VLANs, you'll need an mDNS repeater or set static IPs in `.env`
