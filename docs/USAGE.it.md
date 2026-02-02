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
│ Ingresso TCP    │──┘   ┌─────▶│  - MPD (FIFO)    │
│ (porta 4953)    │      │      │  - TCP-Input     │
└─────────────────┘      │      │  - AirPlay       │
                         │      │  - Spotify       │
┌─────────────────┐      │      │                  │
│ AirPlay         │──────┘  ┌──▶│                  │
│ (shairport-sync)│         │   └────────┬─────────┘
└─────────────────┘         │            │
                            │  ┌─────────┼─────────────┐
┌─────────────────┐         │  ▼         ▼             ▼
│ Spotify Connect │─────────┘ ┌────────┐ ┌────────┐ ┌────────┐
│ (librespot)     │           │Client 1│ │Client 2│ │Client 3│
└─────────────────┘           │(Snap)  │ │(Snap)  │ │(Snap)  │
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
- Formato campionamento: 48000:16:2
- Buffer: 2400ms (chunk_ms: 40)

### myMPD

| Porta | Protocollo | Scopo |
|-------|------------|-------|
| 8180 | HTTP | Interfaccia web (PWA, mobile-ready) |

**Configurazione**: variabili d'ambiente in `docker-compose.yml`
- Si connette a MPD su `localhost:6600`
- SSL disabilitato (rete locale)
- Dati: `mympd/workdir/`, cache: `mympd/cachedir/`

### MPD

| Porta | Protocollo | Scopo |
|-------|------------|-------|
| 6600 | TCP | Protocollo MPD (controllo client) |
| 8000 | HTTP | Stream audio (accesso diretto) |

**Configurazione**: `config/mpd.conf`
- Output: FIFO verso `/audio/snapcast_fifo`
- Directory musicale: `/music` (con sottodirectory `Lossless` e `Lossy` tramite mount dei volumi)
- Database: `/data/mpd.db`

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

Tre container necessitano di mDNS per la scoperta dei servizi: **snapserver** (scoperta client Snapcast), **shairport-sync** (annuncio AirPlay) e **librespot** (annuncio Spotify Connect). Tutti e tre usano il demone Avahi dell'host via D-Bus — nessun Avahi gira dentro i container.

Impostazioni docker-compose necessarie:

```yaml
network_mode: host                    # Necessario per i broadcast mDNS
security_opt:
  - apparmor:unconfined               # Necessario per accesso D-Bus (AppArmor lo blocca altrimenti)
volumes:
  - /run/dbus/system_bus_socket:/run/dbus/system_bus_socket  # Avahi dell'host
```

Tutti e tre i container (snapserver, shairport-sync, librespot) necessitano di tutte e tre le impostazioni sopra.

**Requisito host**: `avahi-daemon` deve essere in esecuzione sull'host (`systemctl status avahi-daemon`).

**NON eseguire `avahi-daemon` dentro i container** — andrà in conflitto con l'Avahi dell'host sulla porta 5353.

**Nota su librespot**: L'immagine è compilata da sorgente con il backend Zeroconf `with-avahi` (invece del default `libmdns`). Questo evita di richiedere il supporto socket IPv6 sull'host — `libmdns` fallisce su sistemi con `ipv6.disable=1`.

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
1. Controlla i log: `docker logs librespot | grep -i "discovery\|avahi\|error"`
2. Verifica il mount del socket D-Bus: `docker exec librespot ls -la /run/dbus/system_bus_socket`
3. Se errore `Address family not supported`: librespot è stato compilato senza backend Avahi — ricompilare l'immagine

**Errori comuni:**
- `"Failed to create client: Access denied"` → Manca `security_opt: [apparmor:unconfined]` (snapserver)
- `"couldn't create avahi client: Daemon not running!"` → Manca il mount del socket D-Bus o avahi-daemon non in esecuzione sull'host
- `"Address family not supported by protocol"` → librespot usa `libmdns` su host con IPv6 disabilitato — serve il backend Avahi
- `"Avahi already running"` → Rimuovi `avahi-daemon` dal comando del container
- Nessun servizio trovato → Verifica che `network_mode: host` sia impostato

### Risorse

- [Snapcast mDNS Setup](https://github.com/badaix/snapcast/wiki/Client-server-communication)
- [Configurazione Server](https://github.com/badaix/snapcast/blob/develop/server/snapserver.conf)

## Deployment

### Deployment Automatico (Consigliato)

Il push di un tag di versione (es. `git tag v1.1.0 && git push origin v1.1.0`) avvia l'intera pipeline CI/CD:

1. **Build** — Immagini Docker multi-architettura compilate nativamente su due runner self-hosted (amd64 + arm64)
2. **Manifest** — Le immagini per architettura vengono unite in tag multi-arch `:latest` su ghcr.io
3. **Deploy** — Le immagini vengono scaricate e tutti e cinque i container (`snapserver`, `shairport-sync`, `librespot`, `mpd`, `mympd`) riavviati sul server domestico via SSH

```
tag v* → build-push.yml → build (amd64 + arm64) → manifest (:latest + :versione) → deploy.yml → server aggiornato
```

### Deployment Manuale

```bash
cd /path/to/snapMULTI
docker compose pull
docker compose up -d
```

### Workflow CI/CD

| Workflow | Trigger | Scopo |
|----------|---------|-------|
| **Build & Push** | Push tag (`v*`) | Compila 4 immagini multi-arch con versione, push su ghcr.io, avvia deploy |
| **Deploy** | Chiamato da Build & Push | Scarica immagini e riavvia tutti i container (snapserver, shairport-sync, librespot, mpd, mympd) sul server via SSH |
| **Validate** | Push su qualsiasi branch, pull request | Verifica sintassi docker-compose e template environment |
| **Build Test** | Pull request | Valida che le immagini Docker si compilino correttamente (senza push) |

### Container Registry

Le immagini Docker sono ospitate su GitHub Container Registry:

| Immagine | Descrizione |
|----------|-------------|
| `ghcr.io/lollonet/snapmulti-server:latest` | Snapcast server (compilato da [santcasp](https://github.com/lollonet/santcasp)) |
| `ghcr.io/lollonet/snapmulti-airplay:latest` | Ricevitore AirPlay (shairport-sync) |
| `ghcr.io/lollonet/snapmulti-spotify:latest` | Spotify Connect (librespot) |
| `ghcr.io/lollonet/snapmulti-mpd:latest` | Music Player Daemon |

Tutte le immagini supportano le architetture `linux/amd64` e `linux/arm64`.

Vedi la scheda GitHub Actions per lo stato dei workflow e i log.

## Riferimento Configurazione

### docker-compose.yml

Definisce tutti i servizi con immagini pre-compilate e rete host per mDNS. Ogni sorgente audio gira nel proprio container, comunicando tramite named pipe nel volume condiviso `/audio`:

```yaml
services:
  snapserver:
    image: ghcr.io/lollonet/snapmulti-server:latest
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
    image: ghcr.io/lollonet/snapmulti-airplay:latest
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
    image: ghcr.io/lollonet/snapmulti-spotify:latest
    container_name: librespot
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

  mympd:
    image: ghcr.io/jcorporation/mympd/mympd:latest
    container_name: mympd
    restart: unless-stopped
    network_mode: host
    user: "${PUID:-1000}:${PGID:-1000}"
    volumes:
      - ./mympd/workdir:/var/lib/mympd
      - ./mympd/cachedir:/var/cache/mympd
      - ${MUSIC_LOSSLESS_PATH}:/music/Lossless:ro
      - ${MUSIC_LOSSY_PATH}:/music/Lossy:ro
      - ./mpd/playlists:/playlists:ro
    environment:
      - TZ=${TZ:-Europe/Berlin}
      - MYMPD_HTTP_PORT=8180
      - MYMPD_SSL=false

  mpd:
    image: ghcr.io/lollonet/snapmulti-mpd:latest
    container_name: mpd
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./audio:/audio
      - ${MUSIC_LOSSLESS_PATH}:/music/Lossless:ro
      - ${MUSIC_LOSSY_PATH}:/music/Lossy:ro
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
