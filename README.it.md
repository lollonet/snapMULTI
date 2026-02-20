🇬🇧 [English](README.md) | 🇮🇹 **Italiano**

# snapMULTI - Server Audio Multiroom

[![CI/CD](https://github.com/lollonet/snapMULTI/actions/workflows/deploy.yml/badge.svg)](https://github.com/lollonet/snapMULTI/actions/workflows/deploy.yml)
[![SnapForge](https://img.shields.io/badge/part%20of-SnapForge-blue)](https://github.com/lollonet/snapforge)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Riproduci musica sincronizzata in ogni stanza. Trasmetti da Spotify, AirPlay, la tua libreria musicale o qualsiasi app — tutti gli altoparlanti suonano insieme.

## Come Funziona

snapMULTI gira su un server domestico e trasmette l'audio agli altoparlanti in tutta la rete. Invia musica da una di queste sorgenti:

| Sorgente | Come usarla |
|----------|-------------|
| **Spotify** | Apri l'app Spotify → Connetti a un dispositivo → "<hostname> Spotify" (richiede Premium) |
| **Tidal** | Apri l'app Tidal → Cast → "<hostname> Tidal" (solo ARM/Pi) |
| **AirPlay** | iPhone/iPad/Mac → AirPlay → "<hostname> AirPlay" |
| **Libreria musicale** | Usa l'interfaccia web [myMPD](http://ip-del-server:8180), oppure un'app MPD ([Cantata](https://github.com/CDrummond/cantata), [MPDroid](https://play.google.com/store/apps/details?id=com.namelessdev.mpdroid)) → connettiti al server |
| **Qualsiasi app** | Aggiungi sorgente TCP al config, trasmetti via ffmpeg (vedi [Sorgenti](docs/SOURCES.it.md)) |
| **Android** | Vedi la [guida allo streaming](docs/SOURCES.it.md#streaming-da-android) |

Altre sorgenti disponibili — vedi il [Riferimento Sorgenti Audio](docs/SOURCES.it.md).

## Avvio Rapido

### Principianti: Plug-and-Play (Raspberry Pi)

Nessuna competenza tecnica richiesta. Prepara una scheda SD, rispondi a una domanda, inseriscila, accendi — fatto.

**Ti serve:**
- Raspberry Pi 4 (2GB+ RAM consigliati)
- Scheda microSD (16GB+)
- Un altro computer per preparare la scheda SD

**Sul tuo computer (macOS/Linux):**
```bash
# 1. Scrivi la scheda SD con Raspberry Pi Imager
#    - Scegli: Raspberry Pi OS Lite (64-bit)
#    - Configura: hostname, utente/password, WiFi, SSH

# 2. Mantieni la SD montata, esegui:
git clone --recurse-submodules https://github.com/lollonet/snapMULTI.git
./snapMULTI/scripts/prepare-sd.sh

# 3. Scegli cosa installare:
#    1) Audio Player   — riproduci musica dal server sugli altoparlanti
#    2) Music Server   — hub centrale per Spotify, AirPlay, ecc.
#    3) Server+Player  — entrambi sullo stesso Pi

# 4. Espelli la SD, inseriscila nel Pi, accendi
```

**Su Windows (PowerShell):**
```powershell
git clone --recurse-submodules https://github.com/lollonet/snapMULTI.git
.\snapMULTI\scripts\prepare-sd.ps1
```

Il primo avvio installa tutto automaticamente (~5-10 min). L'HDMI mostra una schermata di progresso. Il Pi si riavvia quando ha finito.

#### Collega la Tua Musica

Quando scegli Music Server o Server+Player, l'installer chiede dove si trova la tua musica:

| Opzione | Ideale per | Cosa succede |
|---------|-----------|-------------|
| **Solo streaming** | Utenti Spotify, AirPlay, Tidal | Nessun file locale necessario — trasmetti dal telefono |
| **Drive USB** | Collezioni portatili | Collega il drive al Pi prima di accenderlo |
| **Condivisione di rete** | NAS o altro computer | Inserisci l'indirizzo del server NFS o SMB durante il setup |
| **Configura dopo** | Non sei sicuro | Configura manualmente dopo l'installazione (vedi [USAGE.it.md](docs/USAGE.it.md)) |

> **Nota**: Per le condivisioni di rete con credenziali, la password viene temporaneamente salvata nella partizione boot della SD durante il setup. Viene automaticamente rimossa dopo il primo avvio del Pi. Tieni la SD al sicuro fino a quel momento.

---

### Avanzati: Qualsiasi Server Linux

Per utenti che sanno usare terminale e Docker. Funziona su **Raspberry Pi, x86_64, VM, NAS** — qualsiasi cosa esegua Linux e Docker.

**Ti serve:**
- Una macchina Linux (Pi4, Intel NUC, vecchio laptop, VM, NAS con supporto Docker)
- Docker e Docker Compose installati
- Una cartella con i tuoi file musicali

Scegli il tuo metodo:

#### Opzione A: Automatico (`deploy.sh`)

Rileva l'hardware, crea le directory, imposta i permessi, avvia i servizi.

```bash
git clone https://github.com/lollonet/snapMULTI.git
cd snapMULTI
sudo ./scripts/deploy.sh
```

Lo script cerca file audio in `/media/*`, `/mnt/*` e `~/Music`. Se non trovati, monta prima la tua musica:
```bash
sudo mount /dev/sdX1 /media/music   # Chiavetta USB, NAS, ecc.
```

#### Opzione B: Manuale

Controllo totale — clona, configura, avvia.

```bash
git clone https://github.com/lollonet/snapMULTI.git
cd snapMULTI
cp .env.example .env
```

Modifica `.env` con le tue impostazioni:

```bash
MUSIC_PATH=/media/music      # Percorso della tua libreria musicale
TZ=Your/Timezone             # es. Europe/Rome
PUID=1000                    # Il tuo user ID (esegui: id -u)
PGID=1000                    # Il tuo group ID (esegui: id -g)
```

Avvia:

```bash
docker compose up -d
```

Verifica:

```bash
docker ps
```

Dovresti vedere sei container in esecuzione: `snapserver`, `shairport-sync`, `librespot`, `mpd`, `mympd` e `metadata`. Su ARM (Raspberry Pi), vedrai anche `tidal-connect`.

---

### Controlla la tua musica

Apri `http://<ip-del-server>:8180` nel browser — myMPD ti permette di sfogliare e riprodurre la tua libreria da qualsiasi dispositivo.

## Ascolta sui Tuoi Altoparlanti

### Opzione A: Pi Dedicato come Altoparlante (consigliato)

Usa `prepare-sd.sh` e scegli "Audio Player" per trasformare un altro Pi in un altoparlante. Trova automaticamente il server, mostra le copertine sull'HDMI (servite dal servizio metadata del server) e supporta HAT audio.

### Opzione B: Snapclient Manuale

Installa un client Snapcast su qualsiasi dispositivo Linux:

```bash
# Debian/Ubuntu
sudo apt install snapclient

# Arch Linux
sudo pacman -S snapcast
```

Poi esegui:

```bash
snapclient
```

Trova automaticamente il server sulla rete locale. Per connetterti manualmente:

```bash
snapclient --host <ip-del-server>
```

## Risoluzione Problemi

| Problema | Soluzione |
|----------|----------|
| **Spotify/AirPlay non visibile** | Controlla mDNS: `avahi-browse -r _spotify-connect._tcp` — assicurati che l'host abbia `avahi-daemon` in esecuzione |
| **Nessuna uscita audio** | Verifica che il FIFO esista: `ls -la audio/*_fifo` — deploy.sh li crea automaticamente |
| **I container si riavviano** | Controlla i log: `docker compose logs -f` — causa comune: file di configurazione mancanti |
| **I client non si connettono** | Verifica le porte: `ss -tlnp \| grep 1704` — assicurati che il firewall consenta le porte 1704, 1705, 1780 |
| **myMPD mostra libreria vuota** | Aggiorna il database: `echo 'update' \| nc localhost 6600` — attendi il completamento della scansione |
| **Audio non sincronizzato** | Aumenta il buffer in `config/snapserver.conf`: `buffer = 3000` (default: 2400) |

Per la risoluzione dettagliata, vedi [Guida all'Uso — Autodiscovery](docs/USAGE.it.md#autodiscovery-mdns).

## Aggiornamento

Git viene installato automaticamente durante il setup, quindi puoi aggiornare direttamente sul Pi:

```bash
# Server
cd /opt/snapmulti
git pull
docker compose pull
docker compose up -d

# Client (se installato)
cd /opt/snapclient
git pull
docker compose pull
docker compose up -d
```

Per aggiornamenti di versioni maggiori, controlla [CHANGELOG.md](CHANGELOG.md) per le modifiche incompatibili.

## Documentazione

| Guida | Contenuto |
|-------|-----------|
| [Hardware e Rete](docs/HARDWARE.it.md) | Requisiti server/client, configurazioni Raspberry Pi, banda di rete, setup consigliati |
| [Uso e Operazioni](docs/USAGE.it.md) | Architettura, servizi, controllo MPD, configurazione mDNS, deployment, CI/CD |
| [Sorgenti Audio](docs/SOURCES.it.md) | Tutti i tipi di sorgente, parametri, API JSON-RPC, streaming da Android/Tidal |
| [Changelog](CHANGELOG.md) | Cronologia delle versioni |
