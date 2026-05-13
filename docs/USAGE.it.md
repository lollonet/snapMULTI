🇮🇹 **Italiano** | 🇬🇧 [English](USAGE.md)

# Guida operativa

Riferimento operativo per un'installazione snapMULTI già in funzione. Per la prima installazione vedi [INSTALL.it.md](INSTALL.it.md). Per la compatibilità hardware vedi [HARDWARE.it.md](HARDWARE.it.md).

## Architettura

Stack server (7 container, host networking):

| Container | Ruolo | Porta |
|-----------|-------|-------|
| `snapserver` | Streaming audio + controllo JSON-RPC | 1704, 1705, 1780, 4953 |
| `mpd` | Riproduzione libreria musicale (output FIFO) | 6600, 8000 |
| `mympd` | Web UI per MPD | 8180 |
| `shairport-sync` | Ricevitore AirPlay (output FIFO) | 5000, 5858 |
| `librespot` | Spotify Connect (output FIFO) | 24879 + porta effimera |
| `tidal-connect` | Tidal Connect, solo ARM (output FIFO) | 2019 |
| `metadata` | Copertine + info brano | 8082 (WS), 8083 (HTTP) |

Catena audio: sorgente → pipe FIFO in `/audio/` → snapserver → FLAC sulla rete → snapclient → uscita ALSA. Formato unificato `44100:16:2` (44,1 kHz / 16-bit / stereo) su tutte le sorgenti, niente resampling.

Stack client (3 container su Pi 3/4/5; snapclient nativo da `.deb` su Pi Zero 2W):
`snapclient` + `audio-visualizer` (porta 8081) + `fb-display` (copertine HDMI).

## Sorgenti audio

9 sorgenti definite in `config/snapserver.conf` (5 attive, 4 disponibili come esempi commentati):

| # | Stream ID | Tipo | Come riprodurre |
|---|-----------|------|-----------------|
| 1 | `MPD` | pipe | Web UI myMPD su `:8180`, o qualsiasi client MPD (`mpc`, Cantata, MPDroid) sulla porta `6600` |
| 2 | `Tidal` | pipe (solo ARM) | Cast dall'app Tidal — appare come `<hostname> Tidal` |
| 3 | `AirPlay` | pipe | Cast da iOS / macOS — appare con l'hostname del server |
| 4 | `Spotify` | pipe | Cast da qualsiasi app Spotify Premium — appare come `<hostname> Spotify` |
| 5 | `TCP-Input` | tcp (server, :4953) | Stream PCM raw da qualunque sorgente: `ffmpeg ... tcp://<server>:4953` |
| 6 | `LineIn` | alsa | Cattura da dispositivo ALSA. Scommenta in `snapserver.conf` |
| 7 | `AutoSwitch` | meta | Failover automatico fra altri stream. Scommenta in `snapserver.conf` |
| 8 | `Alert` | file | Riproduce un file audio fisso a richiesta. Scommenta in `snapserver.conf` |
| 9 | `Remote` | tcp (client) | Pull da un altro server TCP. Scommenta in `snapserver.conf` |

I parametri specifici (path FIFO, controlscript, formato campione) vivono inline in `config/snapserver.conf` — quel file è il riferimento autorevole.

### Personalizzare i nomi device

Spotify e Tidal usano per default `<hostname> Spotify` / `<hostname> Tidal`. Override via `.env`:

```bash
SPOTIFY_NAME="Spotify Soggiorno"
TIDAL_NAME="Tidal Soggiorno"
```

### Nota sicurezza Tidal Connect

<a id="nota-sicurezza-tidal"></a>
Tidal Connect è **opt-in** (abilita il profilo Compose `tidal`). Il container upstream è costruito su Raspbian Stretch (EOL 2019), prende i pacchetti da `archive.debian.org` con `trusted=yes`, e contiene un binario proprietario non manutenuto. Solo ARM (non esiste una build x86_64). Leggi il blocco di disclosure in `docker-compose.yml` prima di abilitarlo.

### Streaming da Android (niente cast nativo)

| Metodo | App | Qualità | Setup |
|--------|-----|---------|-------|
| Mittente AirPlay | AirMusic, AllStream | Buona | Installa app → seleziona target AirPlay = hostname del server |
| TCP via BubbleUPnP | BubbleUPnP + relay ffmpeg | Buona | Cattura in BubbleUPnP, rilancia con `ffmpeg ... tcp://server:4953` |
| TCP diretto | Termux + ffmpeg | Lossless | `ffmpeg -f pulse -i default -f s16le -ar 44100 -ac 2 tcp://server:4953` |

## Interfacce di controllo

| Interfaccia | URL | Cosa fa |
|-------------|-----|---------|
| **Snapweb** | `http://<server>:1780` | Cambia sorgente per altoparlante, raggruppa/separa, volume per stanza |
| **myMPD** | `http://<server>:8180` | Sfoglia libreria musicale, code, playlist, copertine |
| **Stato sistema** | `http://<server>:8083/status` | Salute container + audio + NFS (auto-refresh) |
| **App Snapcast per Android** | [Play Store](https://play.google.com/store/apps/details?id=de.badaix.snapcast) | Equivalente mobile di Snapweb |

Regole rapide:
- Riprodurre dalla libreria → myMPD
- Cambiare sorgente di un altoparlante → Snapweb o app Android
- Cast da Spotify/AirPlay/Tidal → l'app della sorgente sceglie l'altoparlante
- Health check → pagina `/status`

### MPD da riga di comando

```bash
sudo apt install mpc
mpc -h <server> play | pause | next | volume 50 | status
mpc -h <server> add "Artist/Album"
mpc -h <server> update                # rescansione libreria (usalo con cautela su NFS — vedi "Aggiornamento")
```

### Cambiare sorgente via JSON-RPC

```bash
# elenca stream
curl -s http://<server>:1780/jsonrpc -d \
  '{"id":1,"jsonrpc":"2.0","method":"Server.GetStatus"}' | jq '.result.server.streams[].id'

# cambia un gruppo
curl -s http://<server>:1780/jsonrpc -d \
  '{"id":1,"jsonrpc":"2.0","method":"Group.SetStream","params":{"id":"<GROUP_ID>","stream_id":"Spotify"}}'
```

Schema JSON-RPC completo: [wiki Snapcast](https://github.com/badaix/snapcast/blob/master/doc/json_rpc_api/v2_0_0.md).

## Autodiscovery (mDNS)

Snapcast, AirPlay, Spotify e Tidal si annunciano sulla LAN tramite l'`avahi-daemon` **dell'host** (socket D-Bus bind-mounted nei container che lo richiedono). Requisito host: `systemctl is-active avahi-daemon` deve restituire `active`. **Non eseguire avahi-daemon dentro i container** — la porta 5353 va in conflitto con l'host.

Snapcast 0.35.x esce dal suo poll loop Avahi su `AVAHI_CLIENT_FAILURE` senza retry. I systemd unit contengono `PartOf=avahi-daemon.service` quindi un riavvio dell'avahi host ricrea automaticamente gli stack Compose (~3 s di buco audio).

### Verifica

```bash
avahi-browse -r _snapcast._tcp --terminate   # annuncio snapcast
avahi-browse -r _raop._tcp --terminate       # AirPlay
ss -tlnp | grep -E '1704|1705|1780'          # porte snapserver in ascolto
```

### Quando la discovery non funziona

1. avahi-daemon host fermo → `sudo systemctl start avahi-daemon`
2. AppArmor blocca il container → conferma `apparmor:unconfined` in `docker-compose.yml`
3. Sottorete diversa → mDNS non attraversa VLAN; usa IP statico in `.env`
4. Firewall → vedi [HARDWARE.it.md — Regole firewall](HARDWARE.it.md#regole-firewall)

## Systemd unit

Dopo l'installazione, systemd possiede il ciclo di vita dei container. ADR-005 — `restart: unless-stopped` di Docker gestisce i crash, systemd gestisce il boot.

Server: `snapmulti-server.service`, `snapmulti-status.timer`, `snapmulti-backup.timer`
Client: `snapclient.service` (o `snapclient.service` nativo su Pi Zero 2W), `snapclient-discover.timer`, `snapclient-display.service` (client con HDMI)
Tutti: `snapmulti-boot-tune.service` (CPU governor, USB autosuspend, WiFi powersave)

I file unit vengono installati da `firstboot.sh`. Ispeziona con `systemctl cat <unit>`.

## Log e diagnostica

```bash
# log live (server)
cd /opt/snapmulti && docker compose logs -f
docker compose logs -f snapserver shairport-sync librespot mpd

# salute container
docker compose ps
docker inspect --format='{{.State.Health.Status}}' snapserver

# pagina stato sistema (browser)
http://<server>:8083/status
```

### Bundle diagnostico in caso di fallimento

Quando `firstboot.sh` si interrompe (qualsiasi step), la sua trap di cleanup scrive un tarball anonimizzato sulla partizione FAT32 di boot:

```
/boot/firmware/snapmulti-diag-install-failed-<UTC-ts>.tar.gz
```

Estrai la SD, montala su qualsiasi computer, allega a una [issue GitHub](https://github.com/lollonet/snapMULTI/issues/new/choose). Anonimizzato: niente MAC, niente IP RFC1918, niente SSID, niente token. Invocazione manuale per supporto:

```bash
sudo /opt/snapmulti/scripts/diagnostic.sh --reason crash --out-dir /tmp
```

Sorgente: [`scripts/diagnostic.sh`](../scripts/diagnostic.sh).

### Log di installazione (Pi)

`cat /var/log/snapmulti-install.log` (il layer scrivibile sopravvive fino al reboot — overlayroot lo cancella al reboot, il bundle sulla partizione di boot rimane).

## Deployment

snapMULTI è **reflash-first** (ADR-005, DEC-003). Tutta la config si auto-rileva al primo boot.

| Path | Utenza | Trigger |
|------|--------|---------|
| Zero-touch SD | Principianti | Flash + `prepare-sd.sh` + accensione |
| `deploy.sh` su host Linux esistente | Avanzati | `git clone` + `bash scripts/deploy.sh` |
| Manuale | Avanzati | `git clone` + modifica `.env` + `docker compose up -d` |
| Push tag CI | Maintainer | `git tag v* && git push --tags` |

Il push di un tag triggera `build-push.yml` → immagini multi-arch (amd64 + arm64 su runner nativi) → Docker Hub. I device prendono `:latest` al prossimo reflash.

### Strategia di aggiornamento

- **Primaria**: reflash dell'SD. `scripts/backup-from-sd.sh` estrae prima `mpd.db` così MPD fa rescan incrementale veloce, non ore di rescan NFS
- **In-place** (avanzato): `cd /opt/snapmulti && docker compose pull && docker compose up -d`. Non ufficialmente supportato — la deriva di config fra versioni è un problema tuo

### Immagini Docker

`lollonet/snapmulti-{server,airplay,mpd,metadata,tidal}:latest` (Docker Hub, build in CI) + `ghcr.io/devgianlu/go-librespot` (upstream) + `ghcr.io/jcorporation/mympd/mympd` (upstream). Tidal è solo ARM.

### Filesystem read-only

Dopo l'installazione, il rootfs è montato in sola lettura tramite overlayroot + fuse-overlayfs. Per la manutenzione:

```bash
sudo /opt/snapmulti/scripts/ro-mode.sh disable   # reboot
# modifiche
sudo /opt/snapmulti/scripts/ro-mode.sh enable    # reboot
```

`cmdline.txt` è di proprietà di `scripts/common/cmdline-manager.sh` — non editare `/boot/firmware/cmdline.txt` a mano. Vedi ADR-003 per il motivo.

## Troubleshooting rapido

| Sintomo | Prima verifica |
|---------|----------------|
| Nessun audio in uscita, tutti i container `healthy` | snapclient ha scelto la scheda audio sbagliata — `snapclient --list` sul client per trovare il nome, imposta `SOUND_CARD` nel `.env` client |
| Spotify/AirPlay/Tidal non appaiono nelle app | mDNS — vedi [Autodiscovery](#autodiscovery-mdns) |
| Database MPD vuoto, file visibili su NFS | `mpc -h <server> update`, controlla `mpc status | grep updating_db`. Se ore di D-state, copia invece un `mpd.db` pre-costruito |
| Container in restart loop | `docker compose logs <name>` — controlla prima la pagina stato sistema per capire quale |
| Pi Zero 2W boota poi va in panic | Zram swap ha saturato l'overlay — `tune_pi_zero_2w_swap_safety()` dovrebbe averlo mascherato. Riflashare per applicare il fix |
| L'installazione fallisce prima che SSH funzioni | Estrai la SD, cerca `snapmulti-diag-install-failed-*.tar.gz` sulla partizione di boot |
