🇬🇧 [English](USAGE.md) | 🇮🇹 **Italiano**

# Guida all'Uso e alle Operazioni

Riferimento tecnico per snapMULTI — architettura, servizi, controllo MPD, autodiscovery, deployment e configurazione.

Per i tipi di sorgente audio e l'API JSON-RPC, vedi [SOURCES.it.md](SOURCES.it.md).

## Architettura

```
┌─────────────────┐
│  Libreria       │
│  Musicale       │
│  (percorsi host)│
└────────┬────────┘
         │
         ▼
┌─────────────────┐     ┌──────────────┐
│  Docker: MPD    │────▶│ /audio/fifo  │──┐
│ (localhost:6600)│     └──────────────┘  │
└────────▲────────┘                       │
         │                                ▼
┌─────────────────┐              ┌──────────────────┐
│ Docker: myMPD   │              │                  │
│ (localhost:8180)│  ┌──────────▶│ Docker: Snapcast │
└─────────────────┘  │          │ (porta 1704)     │
                     │          │                  │
┌─────────────────┐  │          │ Sorgenti:        │
│ AirPlay         │──┘   ┌─────▶│  - MPD (FIFO)    │
│ (shairport-sync)│      │      │  - Tidal (FIFO)  │
└─────────────────┘      │      │  - AirPlay       │
                         │      │  - Spotify       │
┌─────────────────┐      │      │                  │
│ Spotify Connect │──────┘  ┌──▶│                  │
│ (go-librespot)  │         │   └────────┬─────────┘
└─────────────────┘         │            │
                            │            │
┌─────────────────┐         │  ┌─────────────────────┐
│ Tidal Connect   │─────────┘  │ Docker: Metadata    │
│ (solo ARM)      │            │ (WS:8082, HTTP:8083)│
└─────────────────┘            │ copertine + info    │
                               │ tracce per i client │
                               └──────────┬──────────┘
                                          │
                            ┌─────────────┼─────────────┐
                            ▼             ▼             ▼
                          ┌────────┐ ┌────────┐ ┌────────┐
                          │Client 1│ │Client 2│ │Client 3│
                          │(Snap)  │ │(Snap)  │ │(Snap)  │
                          └────────┘ └────────┘ └────────┘
```

## Servizi e Porte

### Snapserver

| Porta | Protocollo | Scopo |
|-------|------------|-------|
| 1704 | TCP | Streaming audio verso i client |
| 1705 | TCP | Controllo JSON-RPC |
| 1780 | HTTP | Interfaccia web Snapweb (non installata) |

**Configurazione**: `config/snapserver.conf`
- Client massimi: 0 (illimitati, modificabile nel file di configurazione)
- Codec: FLAC
- Formato campionamento: 44100:16:2
- Buffer: 2400ms (chunk_ms: 40)

### myMPD

| Porta | Protocollo | Scopo |
|-------|------------|-------|
| 8180 | HTTP | Interfaccia web (PWA, mobile-ready) |

**Configurazione**: variabili d'ambiente in `docker-compose.yml`
- Si connette a MPD su `localhost:6600`
- SSL disabilitato (rete locale)
- Dati: `mympd/workdir/`, cache: `mympd/cachedir/`

### Servizio Metadata

| Porta | Protocollo | Scopo |
|-------|------------|-------|
| 8082 | WebSocket | Push metadati traccia (sottoscrizione con CLIENT_ID) |
| 8083 | HTTP | File copertine, JSON metadati, health check |

**Configurazione**: variabili d'ambiente (default: localhost per connessioni Snapserver/MPD)
- Interroga Snapserver JSON-RPC ogni 2s per i metadati degli stream
- Catena copertine: MPD embedded → iTunes → MusicBrainz → Radio-Browser
- I client si iscrivono via WebSocket con `{"subscribe": "CLIENT_ID"}` per ricevere i metadati del loro stream
- Copertine servite su `http://<server>:8083/artwork/<filename>`

### AirPlay (shairport-sync)

| Porta | Protocollo | Scopo |
|-------|------------|-------|
| 5858 | HTTP | Server copertine (usato dal controlscript `meta_shairport.py`) |

### Spotify Connect (go-librespot)

| Porta | Protocollo | Scopo |
|-------|------------|-------|
| 24879 | HTTP/WS | API WebSocket (usata dal controlscript `meta_go-librespot.py`) |

### Tidal Connect

| Porta | Protocollo | Scopo |
|-------|------------|-------|
| 8888 | WebSocket | API eventi riproduzione (usata dal controlscript `meta_tidal.py`) |

> **Nota:** Le porte 5858, 8888 e 24879 sono interne (solo localhost) — usate per lo scambio di metadati tra container. Non servono regole firewall.

### MPD

| Porta | Protocollo | Scopo |
|-------|------------|-------|
| 6600 | TCP | Protocollo MPD (controllo client) |
| 8000 | HTTP | Stream audio (accesso diretto) |

**Configurazione**: `config/mpd.conf`
- Output: FIFO verso `/audio/snapcast_fifo`
- Directory musicale: `/music` (mappata a `MUSIC_PATH` sull'host)
- Database: `/data/mpd.db`

## Libreria Musicale

### Setup per principianti (SD card)

Durante `prepare-sd.sh`, scegli la sorgente musicale:

| Opzione | Valore config | Cosa succede al primo avvio |
|---------|--------------|----------------------------|
| Solo streaming | `streaming` | Cartella `/media/music` vuota, scansione saltata |
| Drive USB | `usb` | `deploy.sh` rileva automaticamente in `/media/*` |
| Condivisione NFS | `nfs` | Montaggio read-only in `/media/nfs-music`, aggiunto a `/etc/fstab` |
| Condivisione SMB | `smb` | Montaggio read-only in `/media/smb-music`, credenziali in `/etc/snapmulti-smb-credentials` |
| Manuale | `manual` | Nessun setup automatico — configura dopo l'installazione |

### Setup avanzato

Per configurazione manuale NFS/SMB dopo l'installazione:

**NFS** (Linux/Mac/NAS):
```bash
sudo apt install nfs-common
sudo mkdir -p /media/nfs-music
sudo mount -t nfs nas.local:/volume1/music /media/nfs-music -o ro,soft,timeo=50,_netdev
# Persistere tra i riavvii:
echo "nas.local:/volume1/music /media/nfs-music nfs ro,soft,timeo=50,_netdev 0 0" | sudo tee -a /etc/fstab
```

**SMB/CIFS** (Windows/NAS):
```bash
sudo apt install cifs-utils
sudo mkdir -p /media/smb-music
# Accesso guest:
sudo mount -t cifs //mynas/Music /media/smb-music -o ro,guest,_netdev,iocharset=utf8
# Con credenziali:
printf 'username=utente\npassword=password\n' | sudo tee /etc/snapmulti-smb-credentials
sudo chmod 600 /etc/snapmulti-smb-credentials
sudo mount -t cifs //mynas/Music /media/smb-music -o ro,_netdev,iocharset=utf8,credentials=/etc/snapmulti-smb-credentials
```

Poi aggiorna `.env`:
```bash
MUSIC_PATH=/media/nfs-music   # oppure /media/smb-music
```

Riavvia MPD per aggiornare la libreria:
```bash
cd /opt/snapmulti && docker compose restart mpd
```

## Controllare MPD

### Tramite myMPD (Interfaccia Web — Consigliato)

Apri `http://<ip-del-server>:8180` in qualsiasi browser. myMPD è una PWA completa che funziona su desktop e mobile — sfoglia la libreria, gestisci playlist, controlla la riproduzione e visualizza le copertine degli album.

### Tramite mpc (Riga di Comando)

```bash
# Installa mpc
sudo apt install mpc

# Comandi base
mpc play                    # Avvia riproduzione
mpc pause                   # Pausa
mpc next                    # Brano successivo
mpc prev                    # Brano precedente
mpc stop                    # Ferma riproduzione
mpc volume 50               # Imposta volume al 50%

# Esplora la libreria
mpc listall                 # Elenca tutti i brani (molto lungo!)
mpc list artist             # Elenca tutti gli artisti
mpc list album "Artista"    # Elenca gli album di un artista
mpc search title "brano"    # Cerca un brano

# Gestione coda
mpc add "Artista/Album"     # Aggiungi album alla coda
mpc clear                   # Svuota la coda
mpc playlist                # Mostra la coda corrente

# Stato
mpc status                  # Mostra stato riproduzione
mpc current                 # Mostra brano corrente
```

### Client Desktop

**Cantata** (consigliato):
1. Installa: `sudo apt install cantata`
2. Configura la connessione a `<ip-del-server>:6600`
3. Esplora e riproduci la musica

**Altri client**:
- **ncmpcpp**: Client da terminale
- **Ario**: Client basato su Qt
- **GMPC**: Gnome Music Player Client

### App Mobile

- **MPDroid** (Android)
- **MPD Remote** (iOS)
- Connettiti a `<ip-del-server>:6600`

### Aggiornare il Database MPD

```bash
# Avvia aggiornamento del database
printf 'update\n' | nc localhost 6600

# Controlla lo stato dell'aggiornamento
printf 'status\n' | nc localhost 6600 | grep updating_db
```

## Cambiare Sorgente Audio

```bash
# Elenca gli stream disponibili
curl -s http://<ip-del-server>:1780/jsonrpc \
  -d '{"id":1,"jsonrpc":"2.0","method":"Server.GetStatus"}' | jq '.result.server.streams'

# Cambia lo stream di un gruppo
curl -s http://<ip-del-server>:1780/jsonrpc \
  -d '{"id":1,"jsonrpc":"2.0","method":"Group.SetStream","params":{"id":"<GROUP_ID>","stream_id":"Spotify"}}'
```

Per il riferimento completo dell'API JSON-RPC, vedi [SOURCES.it.md — API JSON-RPC](SOURCES.it.md#riferimento-api-json-rpc).

## Autodiscovery (mDNS)

Snapcast usa **mDNS/Bonjour tramite Avahi** per la scoperta automatica dei client sulla rete locale.

### Requisiti Critici

Tre container necessitano di mDNS per la scoperta dei servizi: **snapserver** (scoperta client Snapcast), **shairport-sync** (annuncio AirPlay) e **go-librespot** (annuncio Spotify Connect). Tutti e tre usano il demone Avahi dell'host via D-Bus — nessun Avahi gira dentro i container.

Impostazioni docker-compose necessarie:

```yaml
network_mode: host                    # Necessario per i broadcast mDNS
security_opt:
  - apparmor:unconfined               # Necessario per accesso D-Bus (AppArmor lo blocca altrimenti)
volumes:
  - /run/dbus/system_bus_socket:/run/dbus/system_bus_socket  # Avahi dell'host (snapserver, shairport-sync)
  # oppure
  - /var/run/dbus:/var/run/dbus       # Avahi dell'host (go-librespot, tidal-connect)
```

Tutti e tre i container (snapserver, shairport-sync, librespot) necessitano di rete host e accesso D-Bus.

**Requisito host**: `avahi-daemon` deve essere in esecuzione sull'host (`systemctl status avahi-daemon`).

**NON eseguire `avahi-daemon` dentro i container** — andrà in conflitto con l'Avahi dell'host sulla porta 5353.

**Nota su go-librespot**: Zeroconf è configurato tramite `zeroconf_backend: avahi` in `config/go-librespot.yml`. Nessun flag di compilazione necessario.

### Verifica

```bash
# Controlla se Snapserver pubblica i servizi mDNS
avahi-browse -r _snapcast._tcp --terminate

# Controlla la modalità di rete del container
docker inspect snapserver | grep NetworkMode  # Deve essere "host"

# Controlla l'accesso al socket D-Bus
docker exec snapserver ls -la /run/dbus/system_bus_socket

# Verifica le porte in ascolto
ss -tlnp | grep -E "1704|1705|1780"
```

### Risoluzione Problemi

**Nessun servizio mDNS visibile:**
1. Verifica che docker-compose abbia tutti i requisiti critici sopra elencati
2. Controlla Avahi sull'host: `systemctl status avahi-daemon`
3. Controlla i log: `docker logs snapserver | grep -i "avahi"`
4. Prova la connessione diretta: `snapclient --host <ip_del_server>`
5. Consenti le porte nel firewall (vedi [HARDWARE.it.md — Regole Firewall](HARDWARE.it.md#regole-firewall))

**AirPlay non visibile:**
1. Controlla i log: `docker logs shairport-sync | grep -i "avahi\|dbus\|fatal"`
2. Verifica il mount del socket D-Bus: `docker exec shairport-sync ls -la /run/dbus/system_bus_socket`

**Spotify Connect non visibile:**
1. Controlla i log: `docker logs librespot | grep -i "zeroconf\|avahi\|error"`
2. Verifica l'accesso D-Bus: `docker exec librespot ls -la /var/run/dbus/`
3. Verifica la configurazione: `docker exec librespot cat /tmp/config.yml | grep zeroconf`

**Errori comuni:**
- `"Failed to create client: Access denied"` → Manca `security_opt: [apparmor:unconfined]` (snapserver)
- `"couldn't create avahi client: Daemon not running!"` → Manca il mount del socket D-Bus o avahi-daemon non in esecuzione sull'host
- `"Avahi already running"` → Rimuovi `avahi-daemon` dal comando del container
- Nessun servizio trovato → Verifica che `network_mode: host` sia impostato

### Risorse

- [Snapcast mDNS Setup](https://github.com/badaix/snapcast/wiki/Client-server-communication)
- [Configurazione Server](https://github.com/badaix/snapcast/blob/develop/server/snapserver.conf)

## Deployment

### Metodi di Deployment

| Metodo | Destinatari | Hardware | Cosa fa |
|--------|-------------|----------|---------|
| **SD Zero-touch** | Principianti | Raspberry Pi | Scrivi SD, inserisci, accendi — completamente automatico |
| **`deploy.sh`** | Avanzati | Pi o x86_64 | Rileva hardware, crea directory, avvia servizi |
| **Manuale** | Avanzati | Pi o x86_64 | Clona, modifica `.env`, `docker compose up` |
| **CI/CD (tag push)** | Manutentori | N/A | Compila immagini, deploya su server via SSH |

### Deployment Automatico (Consigliato)

Il push di un tag di versione (es. `git tag v1.1.0 && git push origin v1.1.0`) avvia l'intera pipeline CI/CD:

1. **Build** — Immagini Docker compilate su runner self-hosted (amd64 nativo + arm64 via cross-compilazione QEMU)
2. **Manifest** — Le immagini per architettura vengono unite in tag multi-arch `:latest` su ghcr.io
3. **Deploy** — Le immagini vengono scaricate e tutti i container (`snapserver`, `shairport-sync`, `librespot`, `mpd`, `mympd`, `metadata`, `tidal-connect`) riavviati sul server domestico via SSH

```
tag v* → build-push.yml → build (amd64 + arm64) → manifest (:latest + :versione) → deploy.yml → server aggiornato
```

### Scheda SD Zero-Touch (Raspberry Pi)

Prepara una scheda SD che installa automaticamente snapMULTI al primo avvio. Nessun SSH necessario.

**Sul tuo computer (macOS/Linux):**

1. Scrivi la SD con **Raspberry Pi Imager**:
   - Scegli: Raspberry Pi OS Lite (64-bit)
   - Configura (icona ingranaggio): hostname, utente/password, WiFi, abilita SSH

2. Mantieni la SD montata ed esegui:
   ```bash
   git clone --recurse-submodules https://github.com/lollonet/snapMULTI.git
   ./snapMULTI/scripts/prepare-sd.sh
   ```

3. Scegli cosa installare:
   - **1) Audio Player** — snapclient + display HDMI opzionale (copertine, visualizer)
   - **2) Music Server** — Spotify, AirPlay, MPD, Tidal Connect
   - **3) Server + Player** — entrambi sullo stesso Pi

4. Espelli la SD, inserisci nel Pi, accendi

**Su Windows (PowerShell):**
```powershell
git clone --recurse-submodules https://github.com/lollonet/snapMULTI.git
.\snapMULTI\scripts\prepare-sd.ps1
```

Il primo avvio installa tutto automaticamente (~5-10 min). L'HDMI mostra una schermata di progresso. Il Pi si riavvia quando ha finito.

Log di installazione salvato in `/var/log/snapmulti-install.log`.

#### Modalita "Server + Player" (Entrambi)

Selezionando l'opzione 3, il Pi esegue sia il music server che un audio player locale sullo stesso dispositivo. I due stack coesistono senza conflitti di porte:

| Componente | Percorso | Rete | Porte |
|------------|----------|------|-------|
| Server | `/opt/snapmulti/` | Host networking | 1704, 1705, 1780, 6600, 8082, 8083, 8180 |
| Client | `/opt/snapclient/` | Bridge networking | 8080, 8081 |

Il client si connette automaticamente al server locale (`SNAPSERVER_HOST=127.0.0.1`) e usa l'uscita audio locale del Pi (HAT o DAC USB).

### Deployment Automatico (deploy.sh)

```bash
git clone https://github.com/lollonet/snapMULTI.git
cd snapMULTI
sudo ./scripts/deploy.sh
```

`deploy.sh` gestisce tutto: installa Docker se necessario, crea le directory, **rileva automaticamente la libreria musicale** (scansiona `/media/*`, `/mnt/*`, `~/Music`), genera `.env`, scarica le immagini e avvia i servizi. Completamente non interattivo.

Se non viene rilevata alcuna libreria musicale, lo script usa `MUSIC_PATH=/media/music` come fallback e avvisa l'utente. È necessario montare la musica in quella posizione o modificare `.env` manualmente prima che MPD possa accedervi.

### Deployment Manuale

```bash
cd /path/to/snapMULTI
docker compose pull
docker compose up -d
```

### Workflow CI/CD

| Workflow | Trigger | Scopo |
|----------|---------|-------|
| **Build & Push** | Push tag (`v*`) | Compila 5 immagini (4 multi-arch + 1 solo ARM), push su Docker Hub, avvia deploy |
| **Deploy** | Chiamato da Build & Push | Scarica immagini e riavvia 7 container principali sul server via SSH |
| **Validate** | Push su qualsiasi branch, pull request | Verifica sintassi docker-compose e template environment |
| **Build Test** | Pull request | Valida che le immagini Docker si compilino correttamente (senza push) |

### Container Registry

Le immagini Docker sono ospitate su Docker Hub:

| Immagine | Descrizione |
|----------|-------------|
| `lollonet/snapmulti-server:latest` | Snapcast server (compilato da [santcasp](https://github.com/lollonet/santcasp)) |
| `lollonet/snapmulti-airplay:latest` | Ricevitore AirPlay (shairport-sync) |
| `ghcr.io/devgianlu/go-librespot:v0.7.0` | Spotify Connect (upstream, nessuna build personalizzata) |
| `lollonet/snapmulti-mpd:latest` | Music Player Daemon |
| `lollonet/snapmulti-metadata:latest` | Servizio Metadata (copertine + info tracce) |
| `ghcr.io/jcorporation/mympd/mympd:latest` | Interfaccia Web (immagine di terze parti) |
| `lollonet/snapmulti-tidal:latest` | Tidal Connect (solo ARM) |

Le immagini supportano `linux/amd64` e `linux/arm64` tranne Tidal Connect (solo ARM).

Vedi la scheda GitHub Actions per lo stato dei workflow e i log.

## Riferimento Configurazione

### docker-compose.yml

Definisce tutti i servizi con immagini pre-compilate e rete host per mDNS. Ogni sorgente audio gira nel proprio container, comunicando tramite named pipe nel volume condiviso `/audio`:

```yaml
services:
  snapserver:
    image: lollonet/snapmulti-server:latest
    container_name: snapserver
    hostname: snapmulti
    restart: unless-stopped
    network_mode: host
    security_opt:
      - apparmor:unconfined
    user: "${PUID:-1000}:${PGID:-1000}"
    volumes:
      - ./config/snapserver.conf:/etc/snapserver.conf:ro
      - ./config:/config
      - ./data:/data
      - ./audio:/audio
      - /run/dbus/system_bus_socket:/run/dbus/system_bus_socket
    environment:
      - TZ=${TZ:-Europe/Berlin}
    command: ["snapserver", "-c", "/etc/snapserver.conf"]

  shairport-sync:
    image: lollonet/snapmulti-airplay:latest
    container_name: shairport-sync
    restart: unless-stopped
    network_mode: host
    security_opt:
      - apparmor:unconfined
    user: "${PUID:-1000}:${PGID:-1000}"
    volumes:
      - ./audio:/audio
      - /run/dbus/system_bus_socket:/run/dbus/system_bus_socket
    environment:
      - TZ=${TZ:-Europe/Berlin}
    depends_on:
      - snapserver

  librespot:
    image: ghcr.io/devgianlu/go-librespot:v0.7.0
    container_name: librespot
    restart: unless-stopped
    network_mode: host
    security_opt:
      - apparmor:unconfined
    user: "${PUID:-1000}:${PGID:-1000}"
    volumes:
      - ./config/go-librespot.yml:/config/config.yml:ro
      - ./audio:/audio
      - /var/run/dbus:/var/run/dbus
    environment:
      - TZ=${TZ:-Europe/Berlin}
    depends_on:
      - snapserver

  mympd:
    image: ghcr.io/jcorporation/mympd/mympd:latest
    container_name: mympd
    restart: unless-stopped
    network_mode: host
    user: "${PUID:-1000}:${PGID:-1000}"
    volumes:
      - ./mympd/workdir:/var/lib/mympd
      - ./mympd/cachedir:/var/cache/mympd
      - ${MUSIC_PATH:-/media/music}:/music:ro
      - ./mpd/playlists:/playlists:ro
    environment:
      - TZ=${TZ:-Europe/Berlin}
      - MYMPD_HTTP_PORT=8180
      - MYMPD_SSL=false

  mpd:
    image: lollonet/snapmulti-mpd:latest
    container_name: mpd
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./audio:/audio
      - ${MUSIC_PATH:-/media/music}:/music:ro
      - ./config/mpd.conf:/etc/mpd.conf:ro
      - ./mpd/playlists:/playlists
      - ./mpd/data:/data
    environment:
      - TZ=${TZ:-Europe/Berlin}
```

### Opzioni di Connessione Snapclient

**Scoperta automatica** (consigliata):
```bash
snapclient
```

**Connessione manuale**:
```bash
snapclient --host <ip-del-server>
snapclient --host <ip-del-server> --port 1704
```

**Elenco schede audio disponibili**:
```bash
snapclient --list
```

**Esecuzione come daemon**:
```bash
snapclient --host <ip-del-server> --daemon
```

**Tramite Docker**:
```bash
docker run -d --name snapclient \
  --network host \
  --device /dev/snd \
  ghcr.io/badaix/snapcast:latest snapclient
```

**Browser come client** (solo stream HTTP di MPD):
```
http://<ip-del-server>:8000
```
