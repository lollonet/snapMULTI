🇬🇧 **English** | 🇮🇹 [Italiano](TROUBLESHOOTING.it.md)

# Troubleshooting

Symptom-driven guide for when something on snapMULTI isn't working. For first-time install see [INSTALL.md](INSTALL.md); for the technical pipeline behind the install (useful when you want to know *where* in the flow it broke) see [INSTALL-FLOW.md](INSTALL-FLOW.md); for ops and customisation see [ADVANCED.md](ADVANCED.md).

## When in doubt — grab the diagnostic bundle

If `firstboot.sh` aborts, the cleanup trap writes a redacted tarball to the **FAT32 boot partition** of the SD card — readable from any computer without SSH:

```
/boot/firmware/snapmulti-diag-install-failed-<UTC-ts>.tar.gz
```

What's inside: last hour of install logs, hardware detection output (model, audio HAT, network), failing step name, container logs. The bundle is **anonymised** before it lands on the SD — no MAC addresses, no LAN IPs, no SSIDs, no passwords, no API tokens — so it is safe to attach to a public [GitHub issue](https://github.com/lollonet/snapMULTI/issues/new/choose). The boot partition survives overlayroot activation and rootfs corruption; that's why we write there rather than `/var/log`.

You can also create one manually on a running device for support reports:

```bash
sudo /opt/snapmulti/scripts/diagnostic.sh --reason crash --out-dir /tmp
```

Same redaction rules.

> **Not comfortable with terminal commands?** Stop here: attach the diagnostic bundle to a GitHub issue and describe what you saw on HDMI / LEDs / router app. The commands below are useful, but the bundle is the support-first path.

## First check — run the smoke test

Before drilling into a specific symptom, run the all-in-one health check on the device:

```bash
sudo bash /opt/snapmulti/scripts/device-smoke.sh --server   # or --client, or --both
```

It validates root mount + overlayroot state, Docker storage driver, required systemd units, container expected / running / healthy counts, mDNS advertisement, Snapcast TCP/RPC reachability, audio kernel modules vs configured HAT, QoS, music mounts, and timer health (10 modules in `scripts/smoke/`). If every section is green, the platform itself is healthy — focus on the upstream (network, casting client, app account). If something is red, the failing check tells you which subsystem to focus on. The same script is the release gate (ADR-005) and what `fleet-smoke.sh` runs across multiple devices.

JSON for scripts / dashboards: `sudo bash /opt/snapmulti/scripts/device-smoke.sh --server --json`.

### Audible result cues — `--tone` <a id="health-check-tones"></a>

Add `--tone` to play a short audio cue at the end of the run (headless server installs without HDMI):

```bash
sudo bash /opt/snapmulti/scripts/device-smoke.sh --both --tone
```

| Cue | Meaning |
|-----|---------|
| Ascending three-note chime (C5–E5–G5 major triad) | All checks passed |
| Two-note alternating chime | Passed with warnings — check the log |
| Descending two-note tone | One or more checks failed |
| Single low chirp | Boot still settling, retry in a minute |

The cues also fire automatically after every boot (`snapmulti-auto-boot-smoke.service`), so an unattended Pi reports its post-reboot health audibly. Keep volume moderate — the tone repeats at every power-up.

**Multi-room opt-out:** hearing 5 rooms chime in sequence at boot is bad UX. Set `SNAPMULTI_BOOT_SMOKE_TONES=off` in `/opt/snapmulti/.env` (server) or `/opt/snapclient/.env` (client) to silence the auto-boot tone while keeping the manual `--tone` invocation working. `TEST_TONE=false` in `install.conf` silences everything (install-time tone + boot tone + manual). Tones never play over an active Snapcast stream.

---

## Installation seems stuck

**Symptoms.** HDMI shows the progress screen but doesn't advance for several minutes, or the screen is blank and the Pi isn't reachable yet.

**Likely cause.** First boot is downloading container images over the network (the slow part, 2–6 minutes on typical home WiFi). Cheap / counterfeit SD cards also cause apparent "hangs" — the install is actually waiting on SD write throughput.

**Try this.**
1. Wait the full 15-20 minutes on a Pi 4/5 before assuming a problem — longer on Pi 3 or Pi Zero 2 W. The install runs `cloud-init` → `snapmulti-firstboot.service`, both headless.
2. From your laptop: `ping <hostname>.local`. If it answers, the network side is up.
3. If SSH works: `ssh <username>@<hostname>.local`, then `sudo journalctl -u snapmulti-firstboot.service -f` to watch the install in real time.

**If still broken.** Pull the SD card and check for `snapmulti-diag-install-failed-*.tar.gz` on the boot partition — that means the install gave up. Attach it to a GitHub issue. If no bundle exists and the Pi is fully unreachable after 20 minutes, the SD card is the most common culprit (use a SanDisk / Samsung A1 or better — see [HARDWARE.md](HARDWARE.md#if-unsure-buyuse-this)).

## Device doesn't show up on the network / `.local` doesn't resolve

**Symptoms.** `ping <hostname>.local` fails. The Pi never appears in your router's DHCP client list.

**Likely cause.** WiFi configuration mismatch in Imager (wrong country code, 5 GHz SSID on a 2.4 GHz-only board, DFS channel that the Pi can't use on first boot), or your phone / laptop is on a different network than the Pi (guest WiFi, separate VLAN), or your router doesn't relay mDNS.

**Try this.**
1. Use the IP directly. Find it in your router's DHCP client list, or attach HDMI: the Pi prints the IP on the console after boot.
2. Check both devices are on the same subnet — `192.168.x.y` on the Pi vs. `192.168.x.z` on your laptop, same first three octets.
3. On Pi Zero 2 W: confirm Imager has a 2.4 GHz SSID, not 5 GHz (the Zero 2 W radio doesn't do 5 GHz).
4. On a Pi 4 / 5 stuck on a DFS 5 GHz channel: re-flash with a 2.4 GHz SSID or a non-DFS 5 GHz channel (36–48).

**If still broken.** If you have HDMI: log in, run `ip addr` and `iwgetid -r` to confirm the Pi is even on WiFi. If `ip addr` shows no `wlan0` address, the WiFi credentials in Imager were wrong — re-flash. If `iwgetid` shows the right SSID but `ip addr` shows no address, you have a DHCP issue at the router.

## Emergency console / root locked out

**Symptoms.** SSH is refused even though you set up Imager correctly. Or you set the SSH key only and lost it.

**Likely cause.** Imager wrote the wrong username, the read-only overlay is masking your changes, or the cloud-init step that installs the SSH key didn't run.

**Try this.**
1. Plug an HDMI display + USB keyboard into the Pi for a local console. Username and password are what you set in Imager.
2. From there: `sudo ro-mode disable && sudo reboot` if you need persistent changes (see [ADVANCED.md — Read-only filesystem](ADVANCED.md#read-only-filesystem)).
3. If the Pi never gets to a login prompt: pull the SD, open the **boot partition** on your laptop, edit `user-data` to reset credentials, re-insert and boot.

**If still broken.** Reflash with Imager — snapMULTI is reflash-first by design ([DEC-003](decisions/DEC-003-reflash-only-updates.md)), and the install takes about 15-20 min on a Pi 4/5. Back up `/opt/snapmulti/mpd.db` first with `scripts/backup-from-sd.sh` if you want to preserve the music library index.

## No audio

**Symptoms.** Containers are all `healthy`, you can cast from Spotify / AirPlay / Tidal and see the "Now Playing" status in Snapweb, but no sound comes out.

**Likely cause.** snapclient picked the wrong ALSA card, the HAT overlay was loaded but the physical wiring is off, or volume is muted at the hardware mixer.

**Try this.**
1. On the client device: `docker exec snapclient snapclient --list` (or `snapclient --list` on the Pi Zero 2 W native install) to enumerate cards. The right card is the one matching your HAT (e.g. `sndrpihifiberry`).
2. Set `SOUNDCARD` in `/opt/snapclient/.env` to that name (no underscore — that's the exact env-var name `docker-compose.yml` reads), then `cd /opt/snapclient && sudo docker compose up -d` (NOT `restart` — that doesn't reload `.env`).
3. Check the hardware mixer: `alsamixer -c 0`, press F6 to pick the right card, raise the master and any "Digital" / "Speaker" controls.
4. Verify the HAT was detected: `aplay -l` should show your DAC; `dmesg | grep -i 'snd\|hifiberry\|wm8'` should show driver load messages.

**If still broken.** Run the smoke test (it has an `audio_modules` check that flags kernel-module / HAT mismatches). If `config.txt` is missing `dtoverlay=hifiberry-*` etc., re-run `setup.sh` and confirm the HAT detection picks the right model — EEPROM-less boards need a manual choice.

## Speakers don't find the server (snapclient won't connect)

**Symptoms.** A client device is fully booted but never appears in Snapweb. `journalctl -u snapclient` on the client shows repeated reconnect attempts.

**Likely cause.** mDNS isn't reaching the client (different subnet, VLAN isolation, router doesn't forward `_snapcast._tcp`), or the server's `avahi-daemon` isn't advertising.

**Try this.**
1. On the server: `systemctl is-active avahi-daemon` — must say `active`. Then `avahi-browse -r _snapcast._tcp --terminate` — must list the server's hostname.
2. On the client: `avahi-browse -r _snapcast._tcp --terminate` — must list the server. If it doesn't, mDNS isn't crossing your network.
3. As a workaround, set a static server in the client `.env`: `SNAPSERVER_HOST=<server-ip>` and `cd /opt/snapclient && sudo docker compose up -d`.

**If still broken.** Most common cause is a router that doesn't relay mDNS across SSIDs / VLANs (mesh routers and "guest network" features are typical). Put the server and clients on the same SSID, or install an mDNS repeater on your router (DD-WRT, OpenWrt, UniFi all support it).

## Spotify / AirPlay / Tidal not visible in the casting app

**Symptoms.** The server is running, Snapweb works, but when you open the Spotify / AirPlay / Tidal app there is no `<hostname> Spotify` / `<hostname> AirPlay` / `<hostname> Tidal` device to cast to.

**Likely cause.** Same mDNS problem as above — the casting app is on a different network than the server, or the relevant container isn't healthy.

**Try this.**
1. Confirm the container is up: `cd /opt/snapmulti && docker compose ps` — `librespot` (Spotify), `shairport-sync` (AirPlay), `tidal-connect` (Tidal, ARM only) all `healthy`.
2. From the server: `avahi-browse -r _spotify-connect._tcp --terminate`, `avahi-browse -r _raop._tcp --terminate` (AirPlay) — must list your server.
3. Phone and server on the same WiFi SSID? Guest networks and VLANs block discovery.
4. Tidal Connect is ARM-only and **enabled by default on ARM installs**. If it doesn't appear: confirm you're on an ARM Pi (`uname -m` returns `aarch64`), check `COMPOSE_PROFILES` includes `tidal` in `/opt/snapmulti/.env`, and verify the `tidal-connect` container is `healthy`. See [USAGE.md — Tidal Connect security note](USAGE.md#tidal-connect-security-note) for the disclosure and opt-out path.
5. Spotify Connect needs **Premium** — Free accounts don't show the device.

**If still broken.** Restart the relevant container: `cd /opt/snapmulti && sudo docker compose up -d --force-recreate librespot` (or `shairport-sync` / `tidal-connect`). Then re-check `avahi-browse`. See also the "Speakers don't find the server" section above for detailed mDNS triage.

## NAS library empty or never mounts (NFS / SMB)

**Symptoms.** myMPD shows zero tracks. `mount | grep music` shows nothing on the server. Or you see "permission denied" / "no such directory" in the install log.

**Likely cause.** NAS share path mismatch (snapMULTI rejects paths with spaces — Synology's default `Music Share` must be renamed `Music_Share`), wrong username / password for SMB, NFS export not allowed for the Pi's IP, or the systemd `.automount` failed to enable.

**Try this.**
1. On the server: identify the mount unit name (systemd-escapes the mount path) and check its state. Default mount points are `/media/nfs-music` for NFS or `/media/smb-music` for SMB — substitute the one that matches your install:
   ```bash
   # NFS install:
   systemctl status "$(systemd-escape -p --suffix=automount /media/nfs-music)"
   systemctl status "$(systemd-escape -p --suffix=mount /media/nfs-music)"
   # SMB install:
   systemctl status "$(systemd-escape -p --suffix=automount /media/smb-music)"
   systemctl status "$(systemd-escape -p --suffix=mount /media/smb-music)"
   ```
2. Try a manual mount with the same path against a throwaway target. The error message is more informative than the systemd one:
   ```bash
   sudo mkdir -p /mnt/test
   sudo mount -t nfs <nas>:<share> /mnt/test       # NFS
   sudo mount -t cifs //<nas>/<share> /mnt/test    # SMB (add -o username=...,password=...)
   ```
3. Check the path has **no spaces** on the NAS side. Rename `Music Share` → `Music_Share`.
4. For SMB, the persistent credentials live in `/etc/snapmulti-smb-credentials` (root-only, on ext4). They are also written into `install.conf` on the FAT32 boot partition during `prepare-sd.sh` and `firstboot.sh`, then scrubbed once `mount-music` has copied them to `/etc/snapmulti-smb-credentials`.

**If still broken.** Reflash the SD with the corrected NAS path — snapMULTI is reflash-first by design ([DEC-003](decisions/DEC-003-reflash-only-updates.md)) and a fresh install takes about 15-20 min on a Pi 4/5. Manual recovery without reflash is possible but not officially supported; it requires editing `/etc/snapmulti-smb-credentials` and the systemd `.mount`/`.automount` units by hand. MPD library scan over NFS is slow on the first run — see [ADVANCED.md — Music library](ADVANCED.md#music-library-on-the-network) for the `mpd.db` backup trick.

## Install marked failed but containers run <a id="install-marked-failed-but-containers-run"></a>

**Symptoms.** SSH into the device works, `docker ps` shows snapserver / myMPD / metadata-service `Up (healthy)`, snapweb answers on port 1780 — but `/boot/firmware/snapmulti-diag-install-failed-*.tar.gz` exists, the `/status` page reports `[FAIL] writable root but Docker driver is fuse-overlayfs`, and `mount | grep ' on / type'` shows `ext4` instead of `overlay`.

**Likely cause.** First-boot install reached the deploy step but `verify_services` returned non-zero (most commonly: MPD on a large NFS/SMB library exceeded the install healthcheck window — see [ADVANCED.md — MPD_START_PERIOD](ADVANCED.md#mpd_start_period)). `firstboot.sh` then wrote `/var/lib/snapmulti-installer/.install-failed` and aborted **before** the `[finalize]` step that would have written `overlayroot=tmpfs` to `cmdline.txt`. systemd's `Restart=on-failure` on `snapmulti-server.service` brought the containers up autonomously after the install gave up, masking the missing finalize step.

**Confirm this is the state.**

```bash
[[ -f /var/lib/snapmulti-installer/.install-failed ]] && echo "INSTALL DID NOT COMPLETE"
mount | grep -q ' on / type overlay' || echo "OVERLAY NOT ACTIVE"
[[ -s /etc/overlayroot.local.conf ]] || echo "overlayroot config missing — finalize never ran"
ls /boot/firmware/snapmulti-diag-install-failed-*.tar.gz 2>/dev/null
```

If all four signal "not done", the install genuinely did not complete.

**Try this.** Re-reflash is the supported path. Before flashing, bump the MPD healthcheck window so the install survives the first cold scan:

```ini
# install.conf on the SD card boot partition (prepare-sd.sh writes this file)
MPD_START_PERIOD=3600s
```

The 1-hour budget is empirically enough for cold NFS scans up to ~100 k tracks on Pi 4. Pull the diagnostic bundle off the failed SD first (`/boot/firmware/snapmulti-diag-install-failed-*.tar.gz`) for the GitHub issue.

**Manual retry without reflash** (not officially supported — re-reflash is the supported path). The installer skips work once `.install-failed` exists; clear it and rerun the script directly (`firstboot.sh` is idempotent — it skips steps already done and resumes from the failure point):

```bash
# Bump the MPD healthcheck window first if a slow NFS scan was the cause
sudo sed -i 's/^MPD_START_PERIOD=.*/MPD_START_PERIOD=3600s/' /opt/snapmulti/.env
# Clear the failure marker
sudo rm /var/lib/snapmulti-installer/.install-failed
# Rerun firstboot from the copy on the boot partition (where prepare-sd put it)
sudo bash /boot/firmware/snapmulti/firstboot.sh
sudo reboot
```

After the reboot, re-run the smoke check (`sudo bash /opt/snapmulti/scripts/device-smoke.sh --server`) and verify `mount | grep ' on / type overlay'` reports the overlay is active.

## First-boot "fail" tone on large NFS / SMB libraries <a id="first-boot-fail-tone-large-library"></a>

**Symptoms.** Right after a fresh reflash with a very large network music library (≥ ~50 k tracks), the boot-time acoustic cue is the descending two-note **fail** tone (not the ascending three-note **pass** chime). Every subsequent reboot during the same day may also play **fail** until the library scan completes. The `/status` page shows the MPD container as `unhealthy`. Nothing else appears broken — clients connect, AirPlay / Spotify / Tidal work.

**Likely cause.** MPD's first scan over NFS/SMB on a cold cache takes longer than the container healthcheck window. While the scan is in progress (can be hours on huge libraries), the healthcheck reports `unhealthy`. `device-smoke.sh` classifies that as a failure → the overall verdict is FAIL → the boot tone reflects FAIL. This is expected, not a real fault: the scan is the long-pole single-time cost of the first install.

**How to confirm it's a scan, not a real failure.**

```bash
docker exec mpd mpc status | head
# Look for: "Updating DB (#NNN)" line — that's the in-progress scan
# If present: scan is genuinely running, the unhealthy is benign
# If absent and mpd is still unhealthy: real MPD problem (see "No audio" above)
```

**Try this.**

1. **Wait.** First scan finishes between minutes (small library) and several hours (50 k+ tracks over slow NFS). Once it completes the next boot tone will be **pass** (ascending).
2. **Pre-warm next reflash.** Before reflashing, run `sudo bash /opt/snapmulti/scripts/backup-from-sd.sh` on the old SD card. The script extracts MPD's `mpd.db` file to the boot partition; on the new install, MPD loads the cached database in seconds instead of full-scanning the NFS share. See [ADVANCED.md — Music library on the network](ADVANCED.md#music-library-on-the-network).

**If still broken.** If `docker exec mpd mpc status` does NOT show `Updating DB` AND mpd remains `unhealthy` for more than an hour, you have a real problem — check `docker logs mpd` and the NAS reachability ([NAS library empty or never mounts](#nas-library-empty-or-never-mounts-nfs--smb)).

## Docker / "no space left on device"

**Symptoms.** Containers fail to start with `no space left on device` in `docker compose logs`. `df -h` shows the rootfs nearly full or shows the overlay tmpfs full.

**Likely cause.** The overlayroot tmpfs upper layer is finite. If a process inside a container writes a lot to a non-tmpfs path inside `/var/lib/docker`, it eats the upper layer. Pi Zero 2 W is particularly tight (256 MB).

**Try this.**
1. `df -h /` — if the overlay is full, reboot. The upper layer is wiped each boot (that's the whole point of overlayroot).
2. `docker system df` — see which images / containers / volumes are using space.
3. If a specific container is misbehaving: `docker compose logs <name>` to find the runaway log writer, then `docker compose up -d --force-recreate <name>`.

**If still broken.** On Pi Zero 2 W, the `tune_pi_zero_2w_swap_safety()` function disables zram swap to prevent it from filling the overlay — if you've manually re-enabled zram, that's likely the cause. Reflash applies the fix.

## Slow shutdown / reboot

**Symptoms.** `sudo reboot` takes longer than 60 seconds. systemd shows "A stop job is running".

**Likely cause.** A snapclient or container with a long graceful-shutdown timeout (default 90 s in systemd), or `network-online.target` waiting for an unreachable NAS mount on shutdown.

**Try this.**
1. Identify the slow unit: `systemctl list-jobs` during shutdown, or `journalctl -b -1 | grep -i 'timeout\|stop job'` after reboot.
2. If a music NAS mount is blocking, drop in a stop-timeout override on the actual unit (computed via `systemd-escape`):
   ```bash
   sudo systemctl edit "$(systemd-escape -p --suffix=mount /media/nfs-music)"
   # then add under [Mount]: TimeoutStopSec=10s
   ```
3. For container shutdown: snapMULTI's systemd units run `docker compose stop -t 5` (non-destructive — stops the processes but keeps containers + network in place, so the next start is a fast `compose up -d` rather than a recreate). On healthy stops the whole cycle is 2–5 s; on an unresponsive container, expect to wait up to the per-service Docker timeout, then up to the systemd unit's own `TimeoutStopSec` (90 s default) before systemd SIGKILLs.

**If still broken.** A 60–90 second shutdown is not a bug per se — systemd's default unit timeout is 90 s. If everything still completes, ignore it. If shutdown actually never finishes, that's a hardware-level hang and a `dmesg` post-reboot will usually show the cause (USB device, SD card timeout, etc.).

## Pi Zero 2 W specifics

**Symptoms.** Install reaches the menu but first boot aborts with `Pi Zero 2W (512 MB RAM) cannot host the snapMULTI server stack`. Or the install runs but no Docker is installed. Or the audio HAT isn't detected.

**Likely cause.** The Zero 2 W only has 512 MB RAM. The installer enforces this:

- **Menu choice 1 (Audio Player)** auto-promotes the profile to `client-native` — native snapclient `.deb`, no Docker, no cover-art display.
- **Menu choices 2 (Music Server) and 3 (Server + Player)** abort at first boot. Reflash with choice 1 instead, or use a different Pi.

The HAT-detection issue is usually `otg_mode=1` or `dr_mode=host` in `config.txt` conflicting with I2S. `prepare-sd.sh` fixes this automatically; manual installs need to comment those out.

**Try this.**
1. For unsupported-mode aborts: pull the SD, re-run `prepare-sd.sh` and pick Audio Player.
2. For native install verification: `systemctl status snapclient` (not `docker compose ps`, there's no Docker).
3. For HAT issues: see [HARDWARE.md — Pi Zero 2 W Notes](HARDWARE.md#pi-zero-2-w-notes).

**If still broken.** The Pi Zero 2 W is the most resource-constrained device we support. If it kernel-panics on boot after install: zram swap may have saturated the overlay tmpfs (incident 2026-05-11). `tune_pi_zero_2w_swap_safety()` should mask zram; a reflash applies the fix.

---

## IPv6 enabled by default — is this expected?

snapMULTI enables IPv6 at the kernel level by default (ADR-008 supersedes the earlier ADR-007 kernel-disable). `ip -6 addr` returning addresses on a snapMULTI device is the **expected** state. Software defenses (Avahi `use-ipv6=no`, snapclient IPv4 SRV pin via `discover-server.sh`, fb-display IPv4 zeroconf filter, `boot-tune.sh` single-publish) cover the original dual-stack mDNS races; the kernel kill-switch was redundant and broke Tidal Connect's WebSocket listen.

Symptoms that are **not** caused by IPv6 being on:
- snapclient can't find the server → check `avahi-browse -rpt _snapcast._tcp` returns the IPv4 advertiser (Avahi `use-ipv6=no` keeps publishing IPv4-only).
- AirPlay / Tidal / Spotify cast app doesn't see the device → same probe with `_airplay._tcp`, `_tidalconnect._tcp`, `_spotify-connect._tcp`.
- apt-get update slow → if you opted into `DISABLE_IPV6=true` then `/etc/apt/apt.conf.d/99force-ipv4` self-installs; with the default IPv6-on, apt works dual-stack and no force-IPv4 config is written.

To disable IPv6 on a device (legacy network, broken router advertisements, etc.):

```bash
# Mount the boot partition from another host (FAT32, no overlayroot involvement)
# Add `ipv6.disable=1` to cmdline.txt
# Reboot the Pi
```

Or for a fresh install, set `DISABLE_IPV6=true` before running `prepare-sd.sh` / `prepare-sd.ps1` (see [ADVANCED.md](ADVANCED.md#ipv6-enabled-by-default)).

## Logs that matter

```bash
# server live logs
cd /opt/snapmulti && docker compose logs -f
docker compose logs -f snapserver shairport-sync librespot mpd

# container health
docker compose ps
docker inspect --format='{{.State.Health.Status}}' snapserver

# install log (writable layer survives until reboot)
cat /var/log/snapmulti-install.log

# system status web page
http://<server>:8083/status
```

For a portable, anonymised bundle to attach to a bug report: `sudo /opt/snapmulti/scripts/diagnostic.sh --reason crash --out-dir /tmp`.

## Still stuck?

- Pi-specific issue → [HARDWARE.md](HARDWARE.md)
- Customisation / ops question → [ADVANCED.md](ADVANCED.md)
- Architecture / service-level question → [USAGE.md](USAGE.md)
- Bug or unclear behaviour → [open a GitHub issue](https://github.com/lollonet/snapMULTI/issues/new/choose) and attach the diagnostic bundle.
