🇮🇹 **Italiano** | 🇬🇧 [English](ADVANCED.md)

# Guida avanzata

Riferimento operativo e personalizzazioni per chi ha già una snapMULTI funzionante. Per l'installazione da zero vedi [INSTALL.it.md](INSTALL.it.md); per i fallimenti vedi [TROUBLESHOOTING.it.md](TROUBLESHOOTING.it.md).

Indice:

- [Multi-room — aggiungere altoparlanti](#multi-room--aggiungere-altoparlanti)
- [Libreria musicale in rete (NFS / SMB)](#libreria-musicale-in-rete)
- [Configurazione personalizzata — file `.env`](#configurazione-personalizzata--file-env)
- [Filesystem read-only](#filesystem-read-only)
- [Deploy senza `prepare-sd`](#deploy-senza-prepare-sd)
- [MPD da riga di comando](#mpd-da-riga-di-comando)
- [Cambiare sorgente via JSON-RPC](#cambiare-sorgente-via-json-rpc)
- [Unit systemd](#unit-systemd)
- [Strategia di aggiornamento](#strategia-di-aggiornamento)
- [Profili risorse](#profili-risorse)
- [Regole firewall](#regole-firewall)
- [Network QoS](#network-qos)

## Multi-room — aggiungere altoparlanti

Per ogni altoparlante aggiuntivo:

1. Flasha una nuova SD con Raspberry Pi Imager
   - Imposta un **hostname unico** (es. `cucina`, `camera`, `giardino`)
   - Stesso user/password del server è comodo ma non obbligatorio
2. Reinserisci → esegui `prepare-sd.sh` → scegli **1) Audio Player**
3. Boot → il Pi speaker scopre il server via mDNS

Il nuovo speaker compare in Snapweb (`http://<server>.local:1780`) entro ~30 secondi dal boot. Raggruppalo con le stanze esistenti via drag-and-drop nella web UI.

> **Linux box come speaker:** qualsiasi macchina Linux sulla LAN può fare da snapclient — `sudo apt install snapclient`, poi `systemctl edit snapclient` e imposta `--host=<server>.local`. Nessun reflash necessario.

## Libreria musicale in rete

Se la tua libreria è su un NAS (Synology, QNAP, server Linux generico, condivisione Windows), il Menu 3 di `prepare-sd.sh` chiede il path della share durante l'installazione. Scegli il protocollo che corrisponde al tuo NAS:

| Protocollo | Quando | Note |
|------------|--------|------|
| NFS | NAS Linux / Synology / QNAP, allow-list per IP | `prepare-sd.sh` scrive una coppia `.mount`/`.automount` systemd; nessuna password |
| SMB / CIFS | Condivisione Windows, Synology / QNAP con username + password | `prepare-sd.sh` scrive temporaneamente le credenziali in `install.conf` sulla partizione FAT32. Al primo boot, `firstboot.sh` le copia in `/etc/snapmulti-smb-credentials` con permessi root-only e poi le rimuove da `install.conf` |
| USB | Disco collegato al Pi | Auto-montato da `udisks2`; scegli l'UUID della partizione nel menu |
| Locale | File copiati in `/audio` sul Pi | Default per chi inizia |

Naming dei path: le share NAS con **spazi** vengono rifiutate all'installazione (Synology di default `Music Share` → rinomina sul NAS in `Music_Share`). Vedi [TROUBLESHOOTING.it.md](TROUBLESHOOTING.it.md) se il mount fallisce silenziosamente dopo l'installazione.

> **Librerie grandi (>10 k tracce) — alza `MPD_START_PERIOD` PRIMA di riflashare.**
> Il budget healthcheck dell'install di default (`max(MPD_START_PERIOD, 180s)`) NON copre una prima scansione a freddo di una libreria NFS/SMB grande. Se MPD non aggancia la porta 6600 in tempo, il verificatore dell'install ritorna non-zero, `firstboot.sh` scrive `/var/lib/snapmulti-installer/.install-failed`, e lo step `[finalize]` (che attiverebbe `overlayroot=tmpfs`) **non viene mai eseguito**. Il dispositivo riparte su ext4 normale — i container alla fine salgono comunque (systemd `Restart=on-failure` li recupera), ma manca la protezione read-only del root. Imposta sempre `MPD_START_PERIOD=3600s` in `install.conf` PRIMA di flashare la SD quando la sorgente musica è NFS/SMB con più di ~10 k tracce. Vedi [TROUBLESHOOTING.it.md — Install marcato fallito ma i container girano](TROUBLESHOOTING.it.md#install-marcato-fallito-ma-i-container-girano) per sintomi + recovery.

> **Rescan MPD su librerie grandi.** Una prima scansione di 10 k+ brani via NFS può richiedere ore di D-state. Usa `scripts/backup-from-sd.sh` sull'SD precedente prima di riflashare — estrae `mpd.db` così MPD fa scansioni incrementali veloci tra reflash. Salta il bump di `MPD_START_PERIOD` qui sopra solo se hai un backup `mpd.db` da un'installazione precedente (il db cached si carica in secondi).

### `MPD_START_PERIOD` — estendere la finestra healthcheck MPD all'install <a id="mpd_start_period"></a>

Il verificatore di install poll-a l'healthcheck di MPD per `max(MPD_START_PERIOD, 180s)` (una grace esplicita di stabilità healthcheck è in programma per una patch successiva). Se MPD non aggancia la porta 6600 in quella finestra l'install viene marcato fallito.

Default:

| Impostazione | Default | Origine |
|--------------|---------|---------|
| `MPD_START_PERIOD` | `30s` | Dimensionato per librerie locali USB / `/audio` — copre una scansione a freddo Pi 4 di ~5 k tracce |
| floor verificatore install | `180s` | Hardcoded in `verify_services` |

```ini
# install.conf — scritto sulla SD boot da prepare-sd.sh
MPD_START_PERIOD=3600s   # 1 ora — copre scan NFS a freddo di librerie grandi
```

Si propaga da `firstboot.sh` → `deploy.sh` → docker-compose dentro lo `start_period` dell'healthcheck di MPD. **Modalità di fallimento se salti il bump**: `verify_services` esce non-zero → marker `.install-failed` → `setup_readonly_fs` non viene mai eseguito → overlay non si attiva al boot 2. Il `Restart=on-failure` di systemd porta comunque su i container autonomamente dopo che l'install si è arreso, quindi il dispositivo SEMBRA sano dalla rete — ma l'install è incompleto. Recovery: riflasha con la variabile ambiente impostata, OPPURE segui il percorso di completamento manuale in [TROUBLESHOOTING.it.md — Install marcato fallito ma i container girano](TROUBLESHOOTING.it.md#install-marcato-fallito-ma-i-container-girano).

## Configurazione personalizzata — file `.env`

| Path | Cosa controlla |
|------|----------------|
| `/opt/snapmulti/.env` | Server: hostname, sorgente musica, limiti risorse container, override opzionali nomi Tidal / Spotify |
| `/opt/snapclient/.env` | Client: override sound card, latenza, profilo display, hostname del server (per fallback IP statico) |

Per ricaricare dopo aver modificato:

```bash
sudo nano /opt/snapmulti/.env
cd /opt/snapmulti && sudo docker compose up -d   # NON restart — restart non rilegge .env
```

Personalizza i nomi dei dispositivi per sorgente senza modificare i file di config:

```bash
SPOTIFY_NAME="Soggiorno Spotify"
TIDAL_NAME="Soggiorno Tidal"
```

Riferimento inline completo: [`config/snapserver.conf`](../config/snapserver.conf) è la schema autoritativa dei parametri di snapserver.

## Filesystem read-only

Dopo che l'installazione si completa, il rootfs viene montato in sola lettura via overlayroot + fuse-overlayfs. Le modifiche a `/etc`, `/opt`, ecc. sopravvivono fino al riavvio, poi vengono cancellate. Per maintenance:

```bash
sudo /opt/snapmulti/scripts/ro-mode.sh disable   # poi reboot
# fai le modifiche (apt install, modifiche fuori da /opt/snapmulti e /opt/snapclient)
sudo /opt/snapmulti/scripts/ro-mode.sh enable    # poi reboot
```

> **Eccezioni — stato che sopravvive alla pulizia overlayroot:** `snapmulti-state-backup.path` fa snapshot di snapserver `server.json` (stato gruppi) + sottodirectory `state/` di myMPD su `/boot/firmware/snapmulti-backup/` quando quei path cambiano. `snapmulti-backup.timer` salva separatamente MPD `mpd.db` al boot e su cadenza giornaliera. Ad ogni boot, `restore-snapmulti-state` (wired come `ExecStartPre` su `snapmulti-server.service`) ricopia il backup in `/opt/snapmulti/` prima che i container partano. L'approccio bind-mount di `snapmulti-data-persistence.service` di v0.7.9 è stato rimosso in v0.7.9.1 (vedi #527) — era un no-op su overlayroot in modalità tmpfs.

`/boot/firmware/cmdline.txt` è di proprietà di `scripts/common/cmdline-manager.sh` — non modificarlo a mano. Vedi ADR-003 per il razionale.

## Deploy senza `prepare-sd`

Usato per installare su un host Linux esistente (non via flash). Richiede Docker + Docker Compose + git.

```bash
git clone https://github.com/lollonet/snapMULTI.git
cd snapMULTI
sudo bash scripts/deploy.sh        # interattivo: rileva hardware, scrive .env, fa pull delle immagini
```

Per controllo manuale completo:

```bash
cp .env.example .env
nano .env                          # come minimo: PUID/PGID, MUSIC_PATH, MUSIC_SOURCE
sudo docker compose up -d
```

Il push di un tag (`v*`) innesca la build multi-arch in CI (runner nativi amd64 + arm64) → Docker Hub `:latest`. Riflasha per prendere le nuove immagini.

## MPD da riga di comando

```bash
sudo apt install mpc
mpc -h <server> play | pause | next | volume 50 | status
mpc -h <server> add "Artista/Album"
mpc -h <server> update                # rescan libreria — vedi note sopra per NFS
```

## Cambiare sorgente via JSON-RPC

```bash
# elenca gli stream
curl -s http://<server>:1780/jsonrpc -d \
  '{"id":1,"jsonrpc":"2.0","method":"Server.GetStatus"}' | jq '.result.server.streams[].id'

# cambia la sorgente di un gruppo a Spotify
curl -s http://<server>:1780/jsonrpc -d \
  '{"id":1,"jsonrpc":"2.0","method":"Group.SetStream","params":{"id":"<GROUP_ID>","stream_id":"Spotify"}}'
```

Schema completo: [Snapcast JSON-RPC v2.0.0](https://github.com/badaix/snapcast/blob/master/doc/json_rpc_api/v2_0_0.md).

## Unit systemd

Dopo l'installazione, systemd controlla il ciclo di vita dei container (ADR-005). Docker `restart: unless-stopped` gestisce i crash, systemd gestisce il boot.

- Server: `snapmulti-server.service`, `snapmulti-status.timer`, `snapmulti-backup.timer`, `snapmulti-state-backup.path`
- Client: `snapclient.service`, `snapclient-discover.timer`, `snapclient-display.service` (solo client HDMI)
- Tutti: `snapmulti-boot-tune.service` (CPU governor, autosuspend USB, WiFi powersave)

Ispeziona con `systemctl cat <unit>`. I file di unit sono installati da `firstboot.sh`.

## Strategia di aggiornamento

- **Primaria** (consigliata): riflasha l'SD con l'ultima release. Prima fai il backup dell'indice della libreria MPD:

  ```bash
  ./scripts/backup-from-sd.sh         # estrae mpd.db dalla vecchia SD prima del flash
  ```

- **In-place** (avanzato, non supportato): `cd /opt/snapmulti && sudo docker compose pull && sudo docker compose up -d`. La deriva di config tra versioni è un tuo problema da risolvere.

Riflashare per primo è il default del progetto ([DEC-003](decisions/DEC-003-reflash-only-updates.md)). Tutta la config si auto-rileva al primo boot — stesso hostname / stessa sorgente musica / stesso HAT.

Dopo ogni reflash o aggiornamento in-place, esegui il test di salute sul device per confermare che la piattaforma sia tornata sana: `sudo bash /opt/snapmulti/scripts/device-smoke.sh --server` (oppure `--client` / `--both`). È lo stesso release gate (ADR-005) che `fleet-smoke.sh` esegue su più device. Descrizione completa in [TROUBLESHOOTING.it.md — Prima cosa da fare](TROUBLESHOOTING.it.md#prima-cosa-da-fare--esegui-il-test-di-salute).

## Strategia release & pinning image-set

> Razionale architetturale: [ADR-006](adr/ADR-006.release-identity-script-only-patches.md).

snapMULTI separa due concetti di versione, così una release di soli script (CHANGELOG, docs, fix nell'installer) non costringe a ricostruire e ripubblicare le immagini Docker:

- **`SNAPMULTI_RELEASE`** — il tag git della release (es. `v0.7.8.16`). Quello che `gh release view` mostra.
- **`SNAPMULTI_IMAGE_SET`** — il tag Docker delle immagini a cui la release si aggancia (es. `0.7.7`). Quello che `docker compose pull` scarica.

La maggior parte delle release incrementa entrambi. Una release di soli script incrementa `SNAPMULTI_RELEASE` e mantiene `SNAPMULTI_IMAGE_SET` all'ultimo valore pubblicato. La fonte di verità è `release-manifest.json` alla radice del repo, copiato sulla SD da `prepare-sd.sh`.

### Catena di precedenza

Da v0.7.8.10 (consolidamento SSOT), `install.conf` non porta più la release identity — `release-manifest.json` sulla SD è l'unica fonte. `IMAGE_TAG` resta in `install.conf` come unico legittimo operator override.

- **`SNAPMULTI_RELEASE`** = `manifest snapmulti_release` > `""`
- **`SNAPMULTI_IMAGE_SET`** = `manifest image_set` > `""`
- **`IMAGE_TAG`** (tag Docker effettivamente caricato) = `install.conf IMAGE_TAG` (override operatore — `dev`, un tag specifico) > `manifest image_set` > `latest`

Implementata una sola volta in `scripts/common/release-manifest.sh::derive_image_tag()` e consumata da `firstboot.sh`, `deploy.sh`, e dal `setup.sh` del client.

### Tabella di compatibilità

| install.conf | manifest | `IMAGE_TAG` risultante |
|--------------|----------|------------------------|
| solo `IMAGE_TAG=0.7.4` | — | `0.7.4` (SD legacy da v0.7.4) |
| solo `IMAGE_TAG=latest` | — | `latest` (default legacy) |
| vuoto | assente | `latest` |
| vuoto | `image_set=0.7.7` | `0.7.7` |
| `IMAGE_TAG=dev` | `image_set=0.7.7` | `dev` (override operatore vince) |

Riprodotta in `tests/test_firstboot_image_tag_derivation.sh`.

### Tagliare una release di soli script

1. Modifica `release-manifest.json`:
   - Incrementa `snapmulti_release` al nuovo tag (es. `v0.7.8`)
   - Mantieni `image_set` all'ultimo valore pubblicato (es. `0.7.7`)
   - Imposta `requires_image_rebuild` a `false`
2. Aggiorna `CHANGELOG.md` `[Unreleased]` → nuovo header di versione.
3. Apri la PR, fai merge, fai push del tag (`git tag v0.7.8 && git push v0.7.8`).
4. Il gate di `build-push.yml` legge il manifest, vede `requires_image_rebuild=false`, verifica che tutte e 5 le immagini di produzione esistano su Docker Hub al tag `:0.7.7`, e **salta la matrice di build**. Viene pubblicata una nuova GitHub Release; gli utenti fanno `docker compose pull` e continuano con le stesse immagini.

### Tagliare una release che cambia i container

1. Modifica `release-manifest.json`:
   - Incrementa `snapmulti_release` al nuovo tag (es. `v0.8.0`)
   - Incrementa `image_set` a corrispondere (es. `0.8.0`)
   - Imposta `requires_image_rebuild` a `true`
2. Aggiorna `CHANGELOG.md`, apri PR, fai merge, fai tag.
3. Il gate vede `requires_image_rebuild=true` e fa girare la matrice completa, pubblicando le immagini `:0.8.0` su Docker Hub.

### Override d'emergenza — `force_rebuild`

Se l'image-set pubblicato su Docker Hub è mancante o corrotto (CVE di sicurezza in un'immagine base, cancellazione accidentale di un tag, incidente su GitHub Container Registry), lancia `build-push.yml` a mano con `force_rebuild=true`:

```text
GitHub → Actions → Build and Push Images → Run workflow
  force_rebuild: ☑ true
```

Il gate bypassa sia `requires_image_rebuild=false` sia il check di esistenza su Docker Hub; la matrice gira e ripubblica l'`image_set` che il manifest dichiara (NON il tag appena tagliato).

### Ispezionare l'identità della release live

Dopo deploy / reflash:

- Riga info del test di salute: `device-smoke.sh` → sezione `System` → `Release v0.7.8.16 (images 0.7.7)`
- Pacchetto diagnostico: `scripts/diagnostic.sh` produce `meta.txt` con `snapmulti_release=...` e `snapmulti_image_set=...`; il pacchetto include anche il `release-manifest.json` (scrubbato) dalla partizione di boot.
- `.env` del server: `grep ^SNAPMULTI_ /opt/snapmulti/.env`
- `.env` del client: `grep ^SNAPMULTI_ /opt/snapclient/.env`

## Profili risorse

`deploy.sh` (server) e `setup.sh` (client) rilevano automaticamente l'hardware e applicano uno dei tre profili — **minimal**, **standard** o **performance**. I limiti possono essere sovrascritti in `.env`.

### Selezione del profilo

| Hardware | RAM | Profilo |
|----------|-----|---------|
| Pi Zero 2 W, Pi 3 | < 2 GB | minimal |
| Pi 4 2 GB | 2–4 GB | standard |
| Pi 4 4 GB+, Pi 5, x86_64 | 4 GB+ | performance |

### Limiti memoria server

| Servizio | minimal | standard | performance |
|----------|---------|----------|-------------|
| snapserver | 128M | 192M | 256M |
| shairport-sync | 48M | 64M | 96M |
| librespot | 96M | 256M | 256M |
| mpd | 128M | 256M | 384M |
| mympd | 32M | 64M | 128M |
| metadata | 96M | 128M | 128M |
| tidal-connect | 64M | 96M | 128M |
| **Totale** | **592M** | **1.056M** | **1.376M** |

### Limiti memoria client

| Servizio | minimal | standard | performance |
|----------|---------|----------|-------------|
| snapclient | 64M | 64M | 96M |
| audio-visualizer | 96M | 128M | 192M |
| fb-display | 192M | 256M | 384M |
| **Totale** | **352M** | **448M** | **672M** |

Il footprint di fb-display scala con la risoluzione — 4K è notevolmente più pesante del 1080p. I client headless (senza display) eseguono solo `snapclient` e restano leggeri.

### Matrice compatibilità hardware

Si assume ~200 MB di overhead SO + Docker. Le percentuali rappresentano i *limiti massimi*, non l'utilizzo effettivo.

**Solo server** (tutti i servizi, incluso Tidal su ARM):

| Hardware | RAM | Profilo | Limiti | % RAM | Stato |
|----------|-----|---------|--------|-------|-------|
| Pi Zero 2 W | 512M | minimal | 592M | 190% | **Non supportato** |
| Pi 3 1 GB | 1024M | minimal | 592M | 72% | Stretto — funziona, niente margine per picchi |
| Pi 4 2 GB | 2048M | standard | 1.056M | 57% | OK |
| Pi 4 4 GB+ | 4096M | performance | 1.376M | 35% | OK |
| Pi 5 | 4–8 GB | performance | 1.376M | 17–35% | OK |

**Client con display:**

| Hardware | RAM | Profilo | Limiti | % RAM | Stato |
|----------|-----|---------|--------|-------|-------|
| Pi Zero 2 W | 512M | minimal | 352M | 113% | **Non supportato** |
| Pi 3 1 GB | 1024M | minimal | 352M | 43% | OK |
| Pi 4 2 GB | 2048M | standard | 448M | 24% | OK |
| Pi 4 4 GB+ | 4096M | performance | 672M | 17% | OK |

**Client headless** (solo snapclient):

| Hardware | RAM | Profilo | Limiti | Stato |
|----------|-----|---------|--------|-------|
| Pi Zero 2 W | 512M | minimal | 64M | OK |
| Pi 3 1 GB | 1024M | minimal | 64M | OK |
| Qualsiasi 2 GB+ | 2 GB+ | standard+ | 64–96M | OK |

**Modalità entrambi** (server + client con display sullo stesso Pi):

| Hardware | RAM | Profilo | Server | Client | Totale | % RAM | Stato |
|----------|-----|---------|--------|--------|--------|-------|-------|
| Pi Zero 2 W | 512M | minimal | 592M | 352M | 944M | 303% | **Non supportato** |
| Pi 3 1 GB | 1024M | minimal | 592M | 352M | 944M | 115% | **Non supportato** |
| Pi 4 2 GB | 2048M | standard | 1.056M | 448M | 1.504M | 81% | Stretto — funziona, margine limitato |
| Pi 4 4 GB+ | 4096M | performance | 1.376M | 672M | 2.048M | 53% | OK |

**Modalità entrambi** (server + client headless sullo stesso Pi):

| Hardware | RAM | Profilo | Server | Client | Totale | % RAM | Stato |
|----------|-----|---------|--------|--------|--------|-------|-------|
| Pi Zero 2 W | 512M | minimal | 592M | 64M | 656M | 210% | **Non supportato** |
| Pi 3 1 GB | 1024M | minimal | 592M | 64M | 656M | 80% | Stretto — funziona, margine limitato |
| Pi 4 2 GB | 2048M | standard | 1.056M | 64M | 1.120M | 61% | OK |
| Pi 4 4 GB+ | 4096M | performance | 1.376M | 96M | 1.472M | 38% | OK |

> I servizi raramente raggiungono i loro limiti simultaneamente — i limiti esistono per impedire ai processi fuori controllo di esaurire le risorse del sistema. Un rapporto limiti/RAM del 74% su Pi 4 2 GB è sicuro nella pratica.

## Regole firewall

Se l'host usa `ufw` o equivalente, apri queste porte sul **server**:

```bash
# Snapcast core
sudo ufw allow 1704/tcp   # Streaming audio
sudo ufw allow 1705/tcp   # Controllo JSON-RPC
sudo ufw allow 1780/tcp   # API HTTP + Snapweb UI

# Sorgenti audio
sudo ufw allow 4953/tcp   # Ingresso audio TCP (ffmpeg / Android streaming)
sudo ufw allow 5000/tcp   # AirPlay (shairport-sync RTSP)
sudo ufw allow 5858/tcp   # Copertine AirPlay
sudo ufw allow 2019/tcp   # Tidal Connect discovery (solo ARM)
# Spotify Connect usa una porta TCP casuale per il discovery zeroconf —
# consenti il range effimero o usa connection tracking:
# sudo ufw allow proto tcp from 192.168.0.0/16 to any port 30000:65535

# Libreria musicale
sudo ufw allow 6600/tcp   # Protocollo MPD
sudo ufw allow 8000/tcp   # Stream HTTP MPD
sudo ufw allow 8180/tcp   # Interfaccia web myMPD

# Metadata
sudo ufw allow 8082/tcp   # Servizio metadata (WebSocket)
sudo ufw allow 8083/tcp   # Servizio metadata (HTTP / copertine)

# Discovery
sudo ufw allow 5353/udp   # mDNS (Avahi / Bonjour)
```

Tabella completa delle porte (con direzione e scopo): [USAGE.it.md](USAGE.it.md).

## IPv6 disattivato per default

snapMULTI disabilita IPv6 per default per evitare fallimenti di discovery mDNS / Snapcast in dual-stack su LAN domestiche. IPv4 è il percorso supportato. Il disable viene aggiunto a `/boot/firmware/cmdline.txt` come `ipv6.disable=1` da `prepare-sd.sh` / `prepare-sd.ps1` ed entra in vigore nel momento più precoce possibile della sequenza di boot (il kernel legge cmdline.txt prima che parta qualsiasi unit).

Utenti avanzati possono ri-abilitare IPv6 impostando `DISABLE_IPV6=false` prima di preparare la SD:

```bash
DISABLE_IPV6=false ./scripts/prepare-sd.sh /Volumes/bootfs
```

```powershell
$env:DISABLE_IPV6='false'; .\scripts\prepare-sd.ps1 -Boot E:\
```

Per ri-abilitare IPv6 su un device già installato senza reflash: monta la partizione di boot, rimuovi `ipv6.disable=1` da `cmdline.txt`, riavvia. `/boot/firmware/` è FAT32 e scrivibile da qualunque host. Vedi ADR-007 per la motivazione completa.

## Network QoS

Per reti congestionate o installazioni dove lo stesso Pi vede trasferimenti di file pesanti, `deploy.sh` configura il qdisc `cake` con marcatura DSCP EF sulle porte snapcast (1704/1705) così i pacchetti audio mantengono la priorità a bassa latenza durante la contesa:

```bash
# Applicato automaticamente da deploy.sh sui kernel supportati
tc qdisc add dev eth0 root cake bandwidth 100mbit
```

Si può disabilitare o modulare via `.env` (`QOS_ENABLE=false`). Su una LAN domestica tranquilla l'effetto non si nota; sotto trasferimenti paralleli pesanti è la differenza fra audio senza glitch e dropout.

## 4K @ 60Hz HDMI su display client Pi 4

Pi 4 ha di default un clock GPU conservativo che si ferma a 4K @ 30Hz. Quando il Pi client pilota una TV/monitor 4K, il kernel logga:

```
vc4-drm gpu: [drm] The core clock cannot reach frequencies high enough to support 4k @ 60Hz.
vc4-drm gpu: [drm] Please change your config.txt file to add hdmi_enable_4kp60.
```

Il container `fb-display` di snapMULTI funziona a qualsiasi modalità HDMI — il frame rate non influisce sul contenuto renderizzato. Ma la TV 4K mostra un segnale degradato 1080p @ 60Hz o 4K @ 30Hz finché non abiliti il boost del clock GPU.

### Fix (niente dance overlayroot — `/boot/firmware` è FAT32, fuori da overlayroot)

```bash
ssh <client-host>
sudo mount -o remount,rw /boot/firmware
sudo sh -c 'echo "hdmi_enable_4kp60=1" >> /boot/firmware/config.txt'
sudo mount -o remount,ro /boot/firmware
sudo reboot
```

Dopo il reboot:
- Warning `vc4-drm` spariti da `journalctl -p warning`
- Framebuffer riporta `3840x2160`
- Temperatura SoC sale di ~1-2 °C a regime (dentro la finestra termica del Pi 4)

Validato su snapdigi (Pi 4 2GB + TV LG 50" 4K) il 2026-05-21.

## Topologia split server+client — `EXTERNAL_HOST`

Quando il server snapMULTI gira su un host e i client su host diversi (es. server su NAS, player in ogni stanza), `metadata-service` deve annunciare un indirizzo raggiungibile dall'esterno così i client possono scaricare le copertine via HTTP `:8083`.

Dalla v0.7.8.1 il servizio rileva automaticamente l'IP LAN dell'host tramite la tabella di routing del kernel — nessuna configurazione necessaria per la maggior parte degli installi. Il log di startup mostra il valore risolto:

```
INFO  External host: 192.168.1.10
```

Sovrascrivi solo quando l'autodetect sceglie l'interfaccia sbagliata (host multi-homed, route VPN, configurazioni container insolite). Imposta `EXTERNAL_HOST=<lan-ip>` in `/opt/snapmulti/.env` e riavvia `metadata`. Un warning di startup parte solo se sia l'autodetect SIA il tuo valore esplicito risolvono a loopback — è il caso in cui i client remoti davvero non possono raggiungere gli URL delle copertine.
