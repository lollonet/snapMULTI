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
| **Spotify** | Apri l'app Spotify → Connetti a un dispositivo → "snapMULTI" (richiede Premium) |
| **AirPlay** | iPhone/iPad/Mac → AirPlay → "snapMULTI" |
| **Libreria musicale** | Usa l'interfaccia web [myMPD](http://ip-del-server:8180), oppure un'app MPD ([Cantata](https://github.com/CDrummond/cantata), [MPDroid](https://play.google.com/store/apps/details?id=com.namelessdev.mpdroid)) → connettiti al server |
| **Qualsiasi app** | Trasmetti audio via TCP al server |
| **Android / Tidal** | Vedi la [guida allo streaming](docs/SOURCES.it.md#streaming-da-android) |

Altre sorgenti disponibili — vedi il [Riferimento Sorgenti Audio](docs/SOURCES.it.md).

## Avvio Rapido

### Requisiti

- Una macchina Linux (x86_64 o ARM64)
- Docker e Docker Compose installati
- Una cartella con i tuoi file musicali

### Opzione A: Deploy automatico (consigliato per Raspberry Pi)

```bash
git clone https://github.com/lollonet/snapMULTI.git
cd snapMULTI
sudo ./deploy.sh
```

Installa Docker se necessario, crea le directory, rileva le impostazioni automaticamente e avvia i servizi.

**Prima di avviare:** Monta la tua libreria musicale in `/media/music`:
```bash
sudo mount /dev/sdX1 /media/music   # Chiavetta USB, NAS, ecc.
```

### Opzione B: Configurazione manuale

#### 1. Scarica il progetto

```bash
git clone https://github.com/lollonet/snapMULTI.git
cd snapMULTI
```

#### 2. Configura

```bash
cp .env.example .env
```

Modifica `.env` con le tue impostazioni:

```bash
# Percorso libreria musicale — monta prima la tua musica qui
MUSIC_PATH=/media/music

# Fuso orario
TZ=Europe/Rome

# Utente/Gruppo per i processi nel container (corrispondente al tuo utente host)
PUID=1000
PGID=1000
```

Monta la tua musica prima di avviare:
```bash
sudo mount /dev/sdX1 /media/music   # Chiavetta USB, NAS, ecc.
```

#### 3. Avvia

```bash
docker compose up -d
```

#### 4. Verifica

```bash
docker ps
```

Dovresti vedere cinque container in esecuzione: `snapserver`, `shairport-sync`, `librespot`, `mpd` e `mympd`.

### 5. Controlla la tua musica

Apri `http://<ip-del-server>:8180` nel browser — myMPD ti permette di sfogliare e riprodurre la tua libreria da qualsiasi dispositivo.

## Ascolta sui Tuoi Altoparlanti

Installa un client Snapcast su ogni dispositivo dove vuoi l'audio.

**Debian / Ubuntu:**
```bash
sudo apt install snapclient
```

**Arch Linux:**
```bash
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

## Documentazione

| Guida | Contenuto |
|-------|-----------|
| [Hardware e Rete](docs/HARDWARE.it.md) | Requisiti server/client, configurazioni Raspberry Pi, banda di rete, setup consigliati |
| [Uso e Operazioni](docs/USAGE.it.md) | Architettura, servizi, controllo MPD, configurazione mDNS, deployment, CI/CD |
| [Sorgenti Audio](docs/SOURCES.it.md) | Tutti i tipi di sorgente, parametri, API JSON-RPC, streaming da Android/Tidal |
| [Changelog](CHANGELOG.md) | Cronologia delle versioni |
