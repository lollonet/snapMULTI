🇮🇹 **Italiano** | 🇬🇧 [English](INSTALL-FLOW.md)

# Flusso di installazione

Cosa succede tra "flash della SD" e "appliance in esecuzione" — a un livello utile per utenti tecnici, senza dettagli interni esaustivi. Per la guida passo-passo da principianti vedi [INSTALL.it.md](INSTALL.it.md); per personalizzazioni operative vedi [ADVANCED.it.md](ADVANCED.it.md); per l'architettura (servizi, porte, modello di sicurezza) vedi [USAGE.it.md](USAGE.it.md).

## In una frase

`prepare-sd.sh` sul tuo laptop → cloud-init lancia `firstboot.sh` sul Pi → `firstboot.sh` chiama `deploy.sh` (server) e/o `setup.sh` (client) → riavvio nel runtime con overlayroot gestito da systemd.

## Flusso logico

```text
HOST (Mac / Linux / Windows)
└─ prepare-sd.sh                      ┐ Copia il repo sulla SD
   ├─ menu installazione (client/server/both) │ + scrive install.conf
   ├─ stage moduli scripts/common     │ + patcha runcmd di user-data
   └─ patch /boot/firmware/user-data  │
                                      ┘
                          ─── flash + SD inserita → accendi ───

PI (boot 1 — cloud-init esegue l'hook installato)
└─ firstboot.sh (root)
   ├─ wait-network                            (fix WiFi DFS regdom)
   ├─ install-deps + install-docker           (Docker CE: docker-ce,
   │                                           docker-ce-cli, containerd.io,
   │                                           docker-compose-plugin)
   ├─ install-profile resolve                 (server / client / both)
   ├─ esegue deploy.sh   (stack server)       ┐ gira solo il path
   ├─ esegue setup.sh    (stack client)       │ rilevante per la
   ├─ esegue setup-zero2w.sh (client nativo)  ┘ modalità scelta
   ├─ fase readonly/finalize                  ┐ con ENABLE_READONLY=true:
   │   ├─ install_initramfs_lzma_hook         │  il path server gira nel
   │   ├─ refresh_overlayroot_modules_dep     │  finalize di firstboot;
   │   └─ raspi-config nonint do_overlayfs 0  │  il path client/both gira
   │                                          ┘  dentro setup.sh
   ├─ scrittori backup /boot/firmware attivati
   ├─ marker /var/lib/snapmulti-installer/.auto-installed
   └─ reboot

PI (boot 2 — systemd gestisce il runtime)
├─ overlayroot=tmpfs:recurse=0
├─ snapmulti-server.service     (server / both)
├─ snapclient.service           (client / both / client nativo)
├─ snapmulti-status.timer       (aggiorna snapshot pagina /status)
└─ snapmulti-state-backup.{path,timer}  (persistenza server.json + workdir myMPD)
```

## Differenze per modalità

Le quattro modalità di installazione condividono lo stesso framework `firstboot.sh`; cambia solo quale step di deploy gira e quali container / servizi finiscono sul dispositivo.

| Modalità | Quando | Cosa gira al primo boot | Stack finale |
|---------|--------|--------------------------|--------------|
| **server** | Pi 3 / 4 / 5 cablato o WiFi, senza speaker locali | `deploy.sh` (solo server) | 7 container server (snapserver, mpd, mympd, metadata, shairport-sync, librespot, tidal-connect su ARM) |
| **client** | Pi 3 / 4 / 5 con speaker / DAC collegato, server altrove sulla LAN | `setup.sh` (stack Docker) | 3 container client (snapclient, audio-visualizer, fb-display) |
| **both** | Singolo Pi 4 / 5 come server + speaker locale | `deploy.sh` poi `setup.sh` | Tutti 10 i container sullo stesso host (server in host networking + client in bridge networking) |
| **client-native** | Pi Zero 2 W (risorse insufficienti per Docker) | `setup-zero2w.sh` — installazione apt diretta di snapclient + unit systemd | 1 servizio nativo (`snapclient.service`) — niente Docker |

`install-profile.sh` risolve la modalità da `install.conf` (scritto da `prepare-sd.sh`) e dalla device detection `is_pi_zero_2w`. La promozione a `client-native` avviene in modo trasparente: un operatore che ha scelto `client` per un Pi Zero 2 W ottiene il path nativo perché `client/Docker` eccederebbe il budget di 512 MB di RAM.

## Riferimento per fase

### 1. Host: `prepare-sd.sh` / `prepare-sd.ps1`

- Mostra il menu a 3 opzioni (Audio Player / Music Server / Server + Player) e il menu sorgente musicale quando rilevante.
- Copia l'albero snapMULTI sulla partizione boot della SD, poi strippa la spazzatura del lato host (`__pycache__`, `._*`, `.DS_Store`).
- Scrive `install.conf` con modalità scelta, sorgente musicale, HAT audio.
- Imprime `server/.version` + `client/VERSION` da `git describe --tags` così il dispositivo sa da che release è stato installato.
- Patcha `runcmd` di cloud-init `user-data` così il Pi esegue `/boot/firmware/snapmulti/firstboot.sh` al primo boot.
- Lo script gemello PowerShell (`prepare-sd.ps1`) fa lo stesso su Windows.

### 2. Pi: cloud-init → `firstboot.sh`

- Il `runcmd` di cloud-init esegue `/boot/firmware/snapmulti/firstboot.sh` come root.
- Il progresso è renderizzato su `/dev/tty1` (console HDMI) tramite `scripts/common/progress.sh` — TUI full-screen, solo ASCII, no-op quando lanciato via SSH.
- Resiliente a fallimenti parziali: ogni fase scrive un checkpoint marker (`.done-<fase>`) in `/var/lib/snapmulti-installer/` così un firstboot interrotto riprende invece di ripartire da zero al reboot. Il completamento riuscito alza `/var/lib/snapmulti-installer/.auto-installed`; un fallimento parziale alza invece `.install-failed` — entrambi nella stessa directory, NON sulla partizione boot.

### 3. Pi: path server — `deploy.sh`

Modalità server-only / both. Step:

- Hardware detection → resource profile (minimal / standard / performance) scrive le env var `*_MEM_LIMIT` in `.env`.
- Layout directory sotto `/opt/snapmulti/`.
- `docker compose pull` + `up -d` per i 7 servizi server.
- Valida `verify_services` (container healthy entro la finestra di grazia `MPD_START_PERIOD + 120s`).

### 4. Pi: path client — `setup.sh`

Modalità client / both (Pi 3 / 4 / 5). Step:

- HAT audio detection (EEPROM → scan I²C → fallback USB).
- ALSA `/etc/asound.conf` scritta dal HAT rilevato.
- Server discovery mDNS (oppure override `SNAPSERVER_HOST`).
- Durante firstboot, `docker compose up -d` avvia SOLO `snapclient` con `COMPOSE_PROFILES=""`. Il profilo `framebuffer` (audio-visualizer + fb-display) è rinviato al `snapclient.service` post-reboot, così la TUI di installazione su `/dev/tty3` non viene calpestata da fb-display che disegna su `/dev/fb0`. Dopo il riavvio, `snapclient.service` legge `.env` con `COMPOSE_PROFILES=framebuffer` e lo stack client completo parte.

### 5. Pi: path client-native — `setup-zero2w.sh`

Solo Pi Zero 2 W (il budget RAM esclude Docker). Step:

- `apt install snapclient` diretto.
- Genera un'unit systemd `snapclient.service` con `ExecStartPre` per il discovery del server mDNS + pin IPv4 dell'host.
- WiFi watchdog + marking DSCP applicati via boot-tune.sh (stile profilo server, scalato).

### 6. Pi: overlayroot + riavvio finale

- `install_initramfs_lzma_hook` installa `/etc/initramfs-tools/hooks/snapmulti-lzma` così kmod dentro initramfs può decomprimere `overlay.ko.xz`.
- `refresh_overlayroot_modules_dep` lancia `depmod -a` per ogni kernel sotto `/lib/modules/*` (cattura il kernel next-boot installato da `apt full-upgrade` il cui modules.dep sarebbe altrimenti stale).
- `raspi-config nonint do_overlayfs 0` scrive il token in cmdline.txt + `/etc/overlayroot.local.conf`.
- `persist_overlayroot_enabled` conferma la persistenza.
- `firstboot.sh` esegue il reboot. Al boot successivo `/` è montato come overlay tmpfs (`tmpfs:recurse=0` — overlay solo `/`, NFS/USB scrivibili), e da lì in avanti systemd gestisce il runtime.

## Modalità di errore e recupero

`firstboot.sh` scrive `/var/lib/snapmulti-installer/.install-failed` se una fase aborta (NON sulla partizione boot — `/boot/firmware/` ospita gli artefatti diagnostici e di backup, non il marker). Il dispositivo si avvia, i container partono (`snapmulti-server.service` ha il suo `Restart=on-failure`), ma overlayroot NON è attivo e l'install è marcato incompleto. Le due cause comuni:

- **Libreria NFS / SMB grande eccede la finestra di healthcheck di `verify_services`** — pre-imposta `MPD_START_PERIOD=3600s` in `install.conf` prima del flash. Vedi [TROUBLESHOOTING.it.md — Install marcata come fallita ma i container girano](TROUBLESHOOTING.it.md#installazione-marcata-come-fallita-ma-i-container-girano).
- **Rate limit di Docker Hub** — `docker login` sul Pi prima del prossimo retry di firstboot.

La pagina HTTP `/status` sul server (`http://<server>.local:8083/status`) e il pacchetto diagnostico (`/usr/local/bin/save-diagnostics`) sono le due superfici di debug per l'operatore. Vedi [TROUBLESHOOTING.it.md](TROUBLESHOOTING.it.md) per la tabella completa delle modalità di errore.

## Vedi anche

- [INSTALL.it.md](INSTALL.it.md) — guida passo-passo per principianti.
- [ADVANCED.it.md](ADVANCED.it.md) — multi-room, libreria NFS/SMB, `.env` custom, deploy manuale, filesystem read-only, strategia di update.
- [USAGE.it.md](USAGE.it.md) — riferimento architetturale (servizi, porte, sicurezza, mDNS).
- [TROUBLESHOOTING.it.md](TROUBLESHOOTING.it.md) — modalità di errore + recupero dal pacchetto diagnostico.
- [HARDWARE.it.md](HARDWARE.it.md) — board e HAT supportati.
