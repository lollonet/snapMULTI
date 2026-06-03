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
   ├─ install-deps + Docker quando il profilo lo richiede
   │   (Docker CE: docker-ce, docker-ce-cli, containerd.io,
   │   docker-compose-plugin — SALTATO sul path client-native /
   │   Pi Zero 2 W, che esegue snapclient direttamente come unit
   │   systemd)
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
├─ snapmulti-state-backup.{path,timer}  (persistenza server.json + directory di lavoro myMPD)
└─ snapmulti-auto-boot-smoke.service    (tono acustico dell'esito del test di
                                          salute al post-riavvio — pass/warn/
                                          fail/skip; opt-out con
                                          SNAPMULTI_BOOT_SMOKE_TONES=off)
```

## Differenze per modalità

Le quattro modalità di installazione condividono lo stesso framework `firstboot.sh`; cambia solo quale step di deploy gira e quali container / servizi finiscono sul dispositivo.

| Modalità | Quando | Cosa gira al primo boot | Stack finale |
|---------|--------|--------------------------|--------------|
| **server** | Pi 3 / 4 / 5 cablato o WiFi, senza speaker locali | `deploy.sh` (solo server) | 7 container server (snapserver, mpd, mympd, metadata, shairport-sync, librespot, tidal-connect su ARM) |
| **client** | Pi 3 / 4 / 5 con altoparlante / DAC collegato, server altrove sulla LAN | `setup.sh` (stack Docker) | 1–3 container client: `snapclient` sempre; `audio-visualizer` + `fb-display` solo quando `/dev/fb0` è presente (le installazioni senza display saltano il profilo `framebuffer`) |
| **both** | Singolo Pi 4 / 5 come server + altoparlante locale | `deploy.sh` poi `setup.sh` | 7 server + 1–3 client container sullo stesso host (server in host networking + client in bridge networking; il numero di client dipende dal rilevamento del display) |
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
- Il progresso è renderizzato su `/dev/tty1` (console HDMI) tramite `scripts/common/progress.sh` — TUI a schermo intero, solo ASCII, senza effetti quando lanciato via SSH.
- Resiliente a fallimenti parziali: ogni fase scrive un file di stato (`.done-<fase>`) in `/var/lib/snapmulti-installer/` così un firstboot interrotto riprende invece di ripartire da zero al riavvio. Il completamento riuscito crea `/var/lib/snapmulti-installer/.auto-installed`; un fallimento parziale crea invece `.install-failed` — entrambi nella stessa directory, NON sulla partizione boot.

### 3. Pi: path server — `deploy.sh`

Modalità server-only / both. Step:

- Hardware detection → resource profile (minimal / standard / performance) scrive le env var `*_MEM_LIMIT` in `.env`.
- Layout directory sotto `/opt/snapmulti/`.
- `docker compose pull` + `up -d` per i 7 servizi server.
- Valida `verify_services` (container healthy entro la finestra di grazia `MPD_START_PERIOD + 120s`).

### 4. Pi: path client — `setup.sh`

Modalità client / both (Pi 3 / 4 / 5). Step:

- Rilevamento HAT audio (EEPROM → scansione I²C → ripiego su USB).
- ALSA `/etc/asound.conf` scritta in base all'HAT rilevato.
- **Tono di conferma HAT** — subito dopo il rilevamento, `setup.sh` riproduce un singolo tono da 1 secondo a 440 Hz (la nota "LA") sull'uscita ALSA appena configurata. È il primo segnale acustico che l'utente sente: conferma in un colpo solo che il DAC è stato rilevato, che ALSA è configurata e che l'amplificatore è acceso col volume ragionevole. Disattivabile con `TEST_TONE=false` in `install.conf` prima del flash.
- Scoperta del server tramite mDNS (oppure forzatura con `SNAPSERVER_HOST`).
- Durante firstboot, `docker compose up -d` avvia SOLO `snapclient` con `COMPOSE_PROFILES=""`. Il profilo `framebuffer` (audio-visualizer + fb-display) è rinviato al `snapclient.service` post-riavvio, così la TUI di installazione su `/dev/tty3` non viene calpestata da fb-display che disegna su `/dev/fb0`. Dopo il riavvio, `snapclient.service` legge `.env` con `COMPOSE_PROFILES=framebuffer` e lo stack client completo parte.

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

`firstboot.sh` scrive `/var/lib/snapmulti-installer/.install-failed` se una fase aborta (NON sulla partizione boot — `/boot/firmware/` ospita gli artefatti diagnostici e di backup, non il marker). Cosa si avvia dopo dipende da **dove** nella pipeline è abortito: un fallimento PRIMA di `deploy.sh` / `setup.sh` (es. wait-network, install-deps, install Docker) lascia un dispositivo senza servizi snapMULTI installati e overlayroot disattivo — il dispositivo è raggiungibile via SSH ma non fa nulla. Un fallimento tardivo DOPO che `deploy.sh` ha wired lo stack server (es. timeout di `verify_services`, abort di finalize) lascia `snapmulti-server.service` già installato: il `Restart=on-failure` di systemd porta su i container in modo autonomo dopo che l'install si è arreso, mascherando il finalize mancato — un dispositivo che sembra sano sulla LAN ma in realtà ha overlayroot DISATTIVO. Le due cause comuni di fallimento tardivo:

- **Libreria NFS / SMB grande eccede la finestra di healthcheck di `verify_services`** — `deploy.sh` deriva `MPD_START_PERIOD` da `MUSIC_SOURCE` (300 s per `nfs`/`smb`/`network`, 30 s altrimenti) e lo scrive in `.env`, ignorando qualsiasi valore pre-impostato in `install.conf`. Il recupero è una procedura a 3 step: (1) modifica `/opt/snapmulti/.env` direttamente per alzare il valore (`sudo sed -i 's/^MPD_START_PERIOD=.*/MPD_START_PERIOD=3600s/' /opt/snapmulti/.env`); (2) cancella il failure marker (`sudo rm /var/lib/snapmulti-installer/.install-failed`); (3) rilancia l'installer dalla copia sulla partizione boot (`sudo bash /boot/firmware/snapmulti/firstboot.sh`). `firstboot.sh` è idempotente — salta gli step che la run precedente ha completato e riprende dal punto di fallimento. Vedi [TROUBLESHOOTING.it.md — Install marcato fallito ma i container girano](TROUBLESHOOTING.it.md#install-marcato-fallito-ma-i-container-girano) per la procedura di recupero completa.
- **Rate limit di Docker Hub** — `docker login` sul Pi prima del prossimo retry di firstboot.

La pagina HTTP `/status` sul server (`http://<server>.local:8083/status`) e il pacchetto diagnostico (`/usr/local/bin/save-diagnostics`) sono le due superfici di debug per l'operatore. Vedi [TROUBLESHOOTING.it.md](TROUBLESHOOTING.it.md) per la tabella completa delle modalità di errore.

## Vedi anche

- [INSTALL.it.md](INSTALL.it.md) — guida passo-passo per principianti.
- [ADVANCED.it.md](ADVANCED.it.md) — multi-room, libreria NFS/SMB, `.env` custom, deploy manuale, filesystem read-only, strategia di update.
- [USAGE.it.md](USAGE.it.md) — riferimento architetturale (servizi, porte, sicurezza, mDNS).
- [TROUBLESHOOTING.it.md](TROUBLESHOOTING.it.md) — modalità di errore + recupero dal pacchetto diagnostico.
- [HARDWARE.it.md](HARDWARE.it.md) — board e HAT supportati.
