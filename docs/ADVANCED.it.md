🇮🇹 **Italiano** | 🇬🇧 [English](ADVANCED.md)

# Guida avanzata

Riferimento operativo e personalizzazioni per chi ha già una snapMULTI funzionante. Per l'installazione da zero vedi [INSTALL.it.md](INSTALL.it.md); per i fallimenti vedi [TROUBLESHOOTING.it.md](TROUBLESHOOTING.it.md).

Indice:

- [Multi-room — aggiungere altoparlanti](#multi-room--aggiungere-altoparlanti)
- [Libreria musicale in rete (NFS / SMB)](#libreria-musicale-in-rete)
- [Configurazione personalizzata — file `.env`](#configurazione-personalizzata--file-env)
- [Filesystem read-only](#filesystem-read-only)
- [Deploy senza `prepare-sd.sh`](#deploy-senza-prepare-sd)
- [MPD da riga di comando](#mpd-da-riga-di-comando)
- [Cambiare sorgente via JSON-RPC](#cambiare-sorgente-via-json-rpc)
- [Unit systemd](#unit-systemd)
- [Strategia di aggiornamento](#strategia-di-aggiornamento)

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

Se la tua libreria è su un NAS (Synology, QNAP, server Linux generico, condivisione Windows), il Menu 2 di `prepare-sd.sh` chiede il path della share durante l'installazione. Scegli il protocollo che corrisponde al tuo NAS:

| Protocollo | Quando | Note |
|------------|--------|------|
| NFS | NAS Linux / Synology / QNAP, allow-list per IP | `prepare-sd.sh` scrive una coppia `.mount`/`.automount` systemd; nessuna password |
| SMB / CIFS | Condivisione Windows, Synology / QNAP con username + password | Le credenziali restano su ext4 root-only, mai sulla partizione boot FAT32 |
| USB | Disco collegato al Pi | Auto-montato da `udisks2`; scegli l'UUID della partizione nel menu |
| Locale | File copiati in `/audio` sul Pi | Default per chi inizia |

Naming dei path: le share NAS con **spazi** vengono rifiutate all'installazione (Synology di default `Music Share` → rinomina sul NAS in `Music_Share`). Vedi [TROUBLESHOOTING.it.md](TROUBLESHOOTING.it.md) se il mount fallisce silenziosamente dopo l'installazione.

> **Rescan MPD su librerie grandi.** Una prima scansione di 10 k+ brani via NFS può richiedere ore di D-state. Usa `scripts/backup-from-sd.sh` sull'SD precedente prima di riflashare — estrae `mpd.db` così MPD fa scansioni incrementali veloci tra reflash.

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

- Server: `snapmulti-server.service`, `snapmulti-status.timer`, `snapmulti-backup.timer`
- Client: `snapclient.service`, `snapclient-discover.timer`, `snapclient-display.service` (solo client HDMI)
- Tutti: `snapmulti-boot-tune.service` (CPU governor, autosuspend USB, WiFi powersave)

Ispeziona con `systemctl cat <unit>`. I file di unit sono installati da `firstboot.sh`.

## Strategia di aggiornamento

- **Primaria** (consigliata): riflasha l'SD con l'ultima release. Prima fai il backup dell'indice della libreria MPD:

  ```bash
  ./scripts/backup-from-sd.sh         # estrae mpd.db dalla vecchia SD prima del flash
  ```

- **In-place** (avanzato, non supportato): `cd /opt/snapmulti && sudo docker compose pull && sudo docker compose up -d`. La deriva di config tra versioni è un tuo problema da risolvere.

Riflashare per primo è il default del progetto (DEC-003). Tutta la config si auto-rileva al primo boot — stesso hostname / stessa sorgente musica / stesso HAT.

Dopo ogni reflash o aggiornamento in-place, esegui lo smoke test sul device per confermare che la piattaforma sia tornata sana: `sudo bash /opt/snapmulti/scripts/device-smoke.sh --server` (oppure `--client` / `--both`). È lo stesso release gate (ADR-005) che `fleet-smoke.sh` esegue su più device. Descrizione completa in [TROUBLESHOOTING.it.md — Prima cosa da fare](TROUBLESHOOTING.it.md#prima-cosa-da-fare--esegui-lo-smoke-test).
