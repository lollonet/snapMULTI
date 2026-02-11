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
| **Tidal** | Apri l'app Tidal → Cast → "snapMULTI Tidal" (solo ARM/Pi) |
| **AirPlay** | iPhone/iPad/Mac → AirPlay → "snapMULTI" |
| **Libreria musicale** | Usa l'interfaccia web [myMPD](http://ip-del-server:8180), oppure un'app MPD ([Cantata](https://github.com/CDrummond/cantata), [MPDroid](https://play.google.com/store/apps/details?id=com.namelessdev.mpdroid)) → connettiti al server |
| **Qualsiasi app** | Aggiungi sorgente TCP al config, trasmetti via ffmpeg (vedi [Sorgenti](docs/SOURCES.it.md)) |
| **Android / Tidal** | Vedi la [guida allo streaming](docs/SOURCES.it.md#streaming-da-android) |

Altre sorgenti disponibili — vedi il [Riferimento Sorgenti Audio](docs/SOURCES.it.md).

## Avvio Rapido

### Principianti: Plug-and-Play (Raspberry Pi)

Nessuna competenza tecnica richiesta. Prepara una scheda SD, inseriscila, accendi — fatto.

**Ti serve:**
- Raspberry Pi 4 (2GB+ RAM consigliati)
- Scheda microSD (16GB+)
- Chiavetta USB o NAS con la tua musica
- Un altro computer per preparare la scheda SD

**Sul tuo computer:**
```bash
# 1. Scrivi la scheda SD con Raspberry Pi Imager
#    - Scegli: Raspberry Pi OS Lite (64-bit)
#    - Configura: hostname, utente/password, WiFi, SSH

# 2. Mantieni la SD montata, esegui:
git clone https://github.com/lollonet/snapMULTI.git
./snapMULTI/scripts/prepare-sd.sh

# 3. Espelli la SD, inseriscila nel Pi, accendi
```

Il primo avvio installa Docker e snapMULTI automaticamente. Accedi a `http://snapmulti.local:8180`.

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
TZ=Europe/Rome               # Il tuo fuso orario
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

Dovresti vedere cinque container in esecuzione: `snapserver`, `shairport-sync`, `librespot`, `mpd` e `mympd`. Su ARM (Raspberry Pi), vedrai anche `tidal-connect`.

---

### Controlla la tua musica

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
