🇬🇧 **English** | 🇮🇹 [Italiano](TROUBLESHOOTING.it.md)

# Troubleshooting

What to check when things fail. For first-time install see [INSTALL.md](INSTALL.md); for ops and customisation see [ADVANCED.md](ADVANCED.md).

## First boot fails

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| HDMI blank, no progress | Normal on headless boot | Wait 10 min; check with `ping <hostname>.local` |
| `ping <hostname>.local` fails | Pi not on network yet | Wait 2 min; if still failing, check WiFi country in Imager. 5 GHz DFS channels (100+) may fail on first boot — try 2.4 GHz or a non-DFS 5 GHz channel (36–48) |
| `.local` resolves but SSH refused | SSH not yet started | Wait 1–2 more min |
| SSH works but containers missing | Installation still running | `sudo journalctl -u cloud-init -f` to watch progress |
| Containers in restart loop | Image pull failed (network) | `cd /opt/snapmulti && sudo docker compose logs -f` |
| Wrong hostname | Wrong value in Imager | Re-flash SD, redo from Step 1 |
| `prepare-sd.sh`: boot partition not found | SD not re-inserted after Imager | Remove SD, re-insert, re-run |
| Windows: script won't run | Execution policy | `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` |
| Audio HAT not detected (client) | EEPROM-less board | SSH in: `sudo bash /opt/snapclient/common/scripts/setup.sh` and select your HAT manually |
| `no matching manifest for linux/arm/v7` | 32-bit OS flashed instead of 64-bit | Re-flash with **Raspberry Pi OS Lite (64-bit)** — all Pi models including Zero 2 W support it |
| Pi Zero 2 W: WiFi won't connect | 5 GHz SSID set, but Pi Zero only does 2.4 GHz | Re-flash with your 2.4 GHz SSID in Imager WiFi settings |
| Pi Zero 2 W: audio HAT not detected | `otg_mode=1` or `dr_mode=host` in `config.txt` | `prepare-sd.sh` fixes this automatically. Manual: comment out `otg_mode=1` and remove `dr_mode=host` from the dwc2 overlay |
| Pi Zero 2 W: first boot aborts with "cannot host the snapMULTI server stack" | You picked **Music Server** or **Server + Player** on a 512 MB board | Reflash and choose **1 — Audio Player**. See [HARDWARE.md — Pi Zero 2 W Notes](HARDWARE.md#pi-zero-2-w-notes) |

### Recovering a diagnostic bundle

If `firstboot.sh` fails partway through, the cleanup trap writes a redacted tarball to the **FAT32 boot partition** — readable on any computer without SSH.

1. Power off the Pi, eject the SD, plug it into your laptop
2. Open the **boot partition** (auto-mounts as `bootfs` on macOS / Linux, drive letter on Windows)
3. Look for `snapmulti-diag-<reason>-<UTC-ts>.tar.gz` (e.g. `snapmulti-diag-install-failed-20260513T142301Z.tar.gz`)
4. Attach it to a [GitHub issue](https://github.com/lollonet/snapMULTI/issues/new/choose) — the bundle is anonymised (no MAC, no RFC1918 IPs, no SSID, no passwords, no API tokens)

The bundle contains the last hour of install logs, hardware detection output (model, audio HAT, network), and the failing step name. The boot partition survives overlayroot activation and rootfs corruption — that's why we write there rather than `/var/log`.

## First check — run the smoke test

Before digging into individual symptoms, run the all-in-one health check:

```bash
sudo bash /opt/snapmulti/scripts/device-smoke.sh --server   # or --client, or --both
```

It validates: root mount + overlayroot state, Docker storage driver, required systemd units, container expected / running / healthy counts, mDNS advertisement, Snapcast TCP/RPC reachability, audio kernel modules vs configured HAT, QoS, music mounts, and timer health (10 modules in `scripts/smoke/`).

If every section is green, the platform is healthy and the problem is elsewhere (network upstream, app-side, casting client). If anything is red, the failing check tells you which subsystem to focus on. The same script is the release gate (ADR-005) and what `fleet-smoke.sh` runs across multiple devices.

JSON output for scripts / dashboards: `sudo bash /opt/snapmulti/scripts/device-smoke.sh --server --json`.

## Post-install issues

| Symptom | First check |
|---------|-------------|
| No audio out, all containers `healthy` | snapclient picked the wrong sound card — on the client: `docker exec snapclient snapclient --list` to find the card name, set `SOUND_CARD` in client `.env`, then `docker compose up -d` |
| Spotify / AirPlay / Tidal not visible in apps | mDNS issue — see [mDNS discovery troubleshooting](#mdns-discovery) below |
| MPD database empty, all files visible on NFS | `mpc -h <server> update`, watch `mpc status \| grep updating_db`. If hours of D-state, copy a pre-built `mpd.db` instead — see [ADVANCED.md — Music library](ADVANCED.md#music-library-on-the-network) |
| A container in restart loop | `cd /opt/snapmulti && docker compose logs <name>`. The web status page (`http://<server>:8083/status`) shows which container is unhealthy |
| Pi Zero 2 W boots then kernel-panics | Zram swap saturated the overlay tmpfs — `tune_pi_zero_2w_swap_safety()` should mask it. Reflash to apply the fix |
| `.local` doesn't resolve after install | Try the IP directly. Find it in your router's DHCP client list, or check the HDMI console after reboot — the Pi prints its IP |

### mDNS discovery

If a source isn't visible in the casting app (Spotify, AirPlay, Tidal) or speakers don't appear in Snapweb:

```bash
# on the server
systemctl is-active avahi-daemon            # must say active
avahi-browse -r _snapcast._tcp --terminate  # must list the server hostname
avahi-browse -r _raop._tcp --terminate      # for AirPlay
```

Common causes:

1. **Host avahi-daemon down** → `sudo systemctl start avahi-daemon`
2. **AppArmor blocking the container** → check `apparmor:unconfined` in `docker-compose.yml` (server stack)
3. **Different subnet / VLAN** → mDNS doesn't cross VLAN boundaries. Use a static IP in `.env` (`SNAPSERVER_HOST=<server-ip>` on clients) or run an mDNS repeater
4. **Firewall** → see [HARDWARE.md — Firewall Rules](HARDWARE.md#firewall-rules)

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
```

For a portable bundle to attach to a bug report:

```bash
sudo /opt/snapmulti/scripts/diagnostic.sh --reason crash --out-dir /tmp
```

Same redaction rules as the first-boot trap — safe to share publicly.

## Still stuck?

- Pi-specific issue → [HARDWARE.md](HARDWARE.md)
- Customisation / ops → [ADVANCED.md](ADVANCED.md)
- Bug / unclear behaviour → [open a GitHub issue](https://github.com/lollonet/snapMULTI/issues/new/choose) (attach the diagnostic bundle)
