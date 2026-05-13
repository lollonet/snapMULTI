🇮🇹 **Italiano** | 🇬🇧 [English](TROUBLESHOOTING.md)

# Risoluzione problemi

Cosa controllare quando qualcosa fallisce. Per l'installazione da zero vedi [INSTALL.it.md](INSTALL.it.md); per operazioni e personalizzazioni vedi [ADVANCED.it.md](ADVANCED.it.md).

## Il primo boot fallisce

| Sintomo | Causa probabile | Cosa fare |
|---------|-----------------|-----------|
| HDMI nero, nessun progresso | Normale al boot headless | Aspetta 10 min; controlla con `ping <hostname>.local` |
| `ping <hostname>.local` non risponde | Pi non ancora in rete | Aspetta 2 min; se non risponde, controlla il country WiFi in Imager. I canali DFS 5 GHz (100+) possono fallire al primo boot — usa 2,4 GHz o un canale 5 GHz non-DFS (36–48) |
| `.local` risolve ma SSH rifiutato | SSH non ancora attivo | Aspetta altri 1–2 min |
| SSH funziona ma niente container | Installazione ancora in corso | `sudo journalctl -u cloud-init -f` per seguire l'avanzamento |
| Container in restart loop | Image pull fallito (rete) | `cd /opt/snapmulti && sudo docker compose logs -f` |
| Hostname sbagliato | Valore errato in Imager | Riflasha l'SD, riparti dal Passo 1 |
| `prepare-sd.sh`: partizione boot non trovata | SD non reinserita dopo Imager | Estrai l'SD, reinseriscila, riesegui |
| Windows: lo script non parte | Execution policy | `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` |
| HAT audio non rilevato (client) | Scheda senza EEPROM | SSH nel Pi: `sudo bash /opt/snapclient/common/scripts/setup.sh` e seleziona il tuo HAT manualmente |
| `no matching manifest for linux/arm/v7` | Flashato OS 32-bit invece di 64-bit | Riflasha con **Raspberry Pi OS Lite (64-bit)** — tutti i modelli Pi incluso Zero 2 W lo supportano |
| Pi Zero 2 W: WiFi non si collega | SSID 5 GHz impostato ma Pi Zero supporta solo 2,4 GHz | Riflasha con il tuo SSID 2,4 GHz nelle impostazioni WiFi di Imager |
| Pi Zero 2 W: HAT audio non rilevato | `otg_mode=1` o `dr_mode=host` in `config.txt` | `prepare-sd.sh` lo corregge automaticamente. Manuale: commenta `otg_mode=1` e rimuovi `dr_mode=host` dall'overlay dwc2 |
| Pi Zero 2 W: il primo boot si interrompe con "cannot host the snapMULTI server stack" | Hai scelto **Music Server** o **Server + Player** su una scheda da 512 MB | Riflasha e scegli **1 — Audio Player**. Vedi [HARDWARE.it.md — Note Pi Zero 2 W](HARDWARE.it.md#note-pi-zero-2-w) |

### Recupero del bundle diagnostico

Se `firstboot.sh` fallisce a metà, la trap di cleanup scrive un tarball anonimizzato sulla **partizione boot FAT32** — leggibile da qualsiasi computer senza SSH.

1. Spegni il Pi, estrai l'SD, inseriscila nel tuo laptop
2. Apri la **partizione boot** (si monta come `bootfs` su macOS / Linux, lettera di unità su Windows)
3. Cerca `snapmulti-diag-<reason>-<UTC-ts>.tar.gz` (es. `snapmulti-diag-install-failed-20260513T142301Z.tar.gz`)
4. Allegalo a una [issue GitHub](https://github.com/lollonet/snapMULTI/issues/new/choose) — il bundle è anonimizzato (niente MAC, niente IP RFC1918, niente SSID, niente password, niente token API)

Il bundle contiene l'ultima ora di log di installazione, l'output del rilevamento hardware (modello, HAT audio, rete) e il nome del passo fallito. La partizione boot sopravvive all'attivazione di overlayroot e alla corruzione del rootfs — è per questo che scriviamo lì invece che in `/var/log`.

## Problemi dopo l'installazione

| Sintomo | Primo controllo |
|---------|-----------------|
| Niente audio in uscita, tutti i container `healthy` | snapclient ha scelto la sound card sbagliata — sul client: `docker exec snapclient snapclient --list` per trovare il nome della card, imposta `SOUND_CARD` nel `.env` del client, poi `docker compose up -d` |
| Spotify / AirPlay / Tidal non visibili nelle app | Problema mDNS — vedi [Discovery mDNS](#discovery-mdns) qui sotto |
| Database MPD vuoto, file visibili su NFS | `mpc -h <server> update`, monitora `mpc status \| grep updating_db`. Se sta in D-state per ore, copia un `mpd.db` pre-costruito — vedi [ADVANCED.it.md — Libreria musicale](ADVANCED.it.md#libreria-musicale-in-rete) |
| Un container in restart loop | `cd /opt/snapmulti && docker compose logs <name>`. La pagina di stato web (`http://<server>:8083/status`) mostra quale container è unhealthy |
| Pi Zero 2 W parte e poi va in kernel-panic | Zram swap ha saturato il tmpfs dell'overlay — `tune_pi_zero_2w_swap_safety()` dovrebbe mascherarlo. Riflasha per applicare il fix |
| `.local` non risolve dopo l'install | Prova l'IP direttamente. Lo trovi nella lista client DHCP del router, o controlla la console HDMI dopo il riavvio — il Pi stampa il suo IP |

### Discovery mDNS

Se una sorgente non è visibile nelle app di cast (Spotify, AirPlay, Tidal) o gli speaker non compaiono in Snapweb:

```bash
# sul server
systemctl is-active avahi-daemon            # deve dire active
avahi-browse -r _snapcast._tcp --terminate  # deve elencare l'hostname del server
avahi-browse -r _raop._tcp --terminate      # per AirPlay
```

Cause comuni:

1. **avahi-daemon dell'host spento** → `sudo systemctl start avahi-daemon`
2. **AppArmor blocca il container** → controlla `apparmor:unconfined` in `docker-compose.yml` (stack server)
3. **Sottoreti / VLAN diverse** → mDNS non attraversa le VLAN. Usa un IP statico in `.env` (`SNAPSERVER_HOST=<server-ip>` sui client) o un mDNS repeater
4. **Firewall** → vedi [HARDWARE.it.md — Regole Firewall](HARDWARE.it.md#regole-firewall)

## Log utili

```bash
# server, log live
cd /opt/snapmulti && docker compose logs -f
docker compose logs -f snapserver shairport-sync librespot mpd

# salute dei container
docker compose ps
docker inspect --format='{{.State.Health.Status}}' snapserver

# install log (il layer scrivibile sopravvive fino al reboot)
cat /var/log/snapmulti-install.log
```

Per un bundle portabile da allegare a una bug report:

```bash
sudo /opt/snapmulti/scripts/diagnostic.sh --reason crash --out-dir /tmp
```

Le regole di anonimizzazione sono identiche a quelle della trap del primo boot — si può condividere pubblicamente in sicurezza.

## Ancora bloccato?

- Problema specifico del Pi → [HARDWARE.it.md](HARDWARE.it.md)
- Personalizzazione / operazioni → [ADVANCED.it.md](ADVANCED.it.md)
- Bug / comportamento poco chiaro → [apri una issue GitHub](https://github.com/lollonet/snapMULTI/issues/new/choose) (allega il bundle diagnostico)
