🇬🇧 [English](README.md) | 🇮🇹 **Italiano**

# snapMULTI - Server Audio Multiroom

[![CI](https://github.com/lollonet/snapMULTI/actions/workflows/validate.yml/badge.svg)](https://github.com/lollonet/snapMULTI/actions/workflows/validate.yml)
[![release](https://img.shields.io/github/v/release/lollonet/snapMULTI?color=orange)](https://github.com/lollonet/snapMULTI/releases/latest)
[![downloads](https://img.shields.io/docker/pulls/lollonet/snapmulti-server?color=green)](https://hub.docker.com/r/lollonet/snapmulti-server)
[![Donate](https://img.shields.io/badge/Donate-PayPal-yellowgreen)](https://paypal.me/lolettic)
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
| **Qualsiasi app** | Trasmetti via ffmpeg alla porta 4953 (vedi [Sorgenti](docs/SOURCES.it.md#5-tcp-input-tcp-server)) |
| **Android** | Vedi la [guida allo streaming](docs/SOURCES.it.md#streaming-da-android) |

Altre sorgenti disponibili — vedi il [Riferimento Sorgenti Audio](docs/SOURCES.it.md).

### Cambio Sorgente

Due interfacce web sono disponibili:

| Interfaccia | URL | Scopo |
|-------------|-----|-------|
| **Snapweb** | `http://<ip-del-server>:1780` | Gestisci altoparlanti: cambia sorgente, regola volume, raggruppa/separa |
| **myMPD** | `http://<ip-del-server>:8180` | Sfoglia e riproduci la tua libreria musicale (sorgente MPD) |

Puoi anche usare l'[app Snapcast per Android](https://play.google.com/store/apps/details?id=de.badaix.snapcast).

## Avvio Rapido

### Principianti: Plug-and-Play (Raspberry Pi)

Prepara una scheda SD, esegui un breve script, inseriscila, accendi — fatto. Devi solo copiare e incollare due comandi sul tuo computer (non serve accedere al Pi).

**Ti serve:**
- Raspberry Pi 4 (2GB+ RAM consigliati)
- Scheda microSD (16GB+)
- Un altro computer per preparare la scheda SD

**Sul tuo computer (macOS/Linux):**
```bash
# 1. Scrivi la scheda SD con Raspberry Pi Imager (https://www.raspberrypi.com/software/)
#    - Scegli: Raspberry Pi OS Lite (64-bit)
#    - Configura: hostname, utente/password, WiFi, SSH

# 2. Mantieni la SD montata, esegui (richiede Git — vedi docs/INSTALL.it.md Passo 3 se non installato):
git clone https://github.com/lollonet/snapMULTI.git
./snapMULTI/scripts/prepare-sd.sh

# 3. Scegli cosa installare:
#    1) Audio Player   — riproduci musica dal server sugli altoparlanti
#    2) Music Server   — hub centrale per Spotify, AirPlay, ecc.
#    3) Server+Player  — entrambi sullo stesso Pi

# 4. Espelli la SD, inseriscila nel Pi, accendi
```

**Su Windows (PowerShell):**
```powershell
# Richiede Git per Windows: https://git-scm.com/download/win
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
git clone https://github.com/lollonet/snapMULTI.git
.\snapMULTI\scripts\prepare-sd.ps1
```

Il primo avvio installa tutto automaticamente (~5-10 min). L'HDMI mostra una schermata di progresso. Il Pi si riavvia quando ha finito.

> **Istruzioni passo-passo complete** (screenshot di Imager, punti di montaggio SD, tutti e tre i SO): **[docs/INSTALL.it.md](docs/INSTALL.it.md)**

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

Dovresti vedere sei container in esecuzione: `snapserver`, `shairport-sync`, `librespot`, `mpd`, `mympd` e `metadata`. Su ARM (Raspberry Pi), vedrai anche `tidal-connect` (sette in totale).

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
| **Spotify/AirPlay non visibile** | Assicurati che il Pi e il telefono siano sulla stessa rete WiFi. Riavvia il Pi se necessario |
| **Nessuna uscita audio** | Collegati via SSH ed esegui `docker compose logs -f` per controllare gli errori |
| **I container si riavviano** | Collegati via SSH ed esegui `docker compose logs -f` — causa comune: file di configurazione mancanti |
| **I client non si connettono** | Assicurati che il firewall consenta le porte 1704, 1705, 1780 (vedi [Regole Firewall](docs/HARDWARE.it.md#regole-firewall)) |
| **myMPD mostra libreria vuota** | La libreria musicale potrebbe essere ancora in scansione — attendi qualche minuto e ricarica la pagina |
| **Audio non sincronizzato** | Aumenta il buffer in `config/snapserver.conf`: `buffer = 3000` (default: 2400) |

Per la risoluzione dettagliata (mDNS, log, diagnostica), vedi [Guida all'Uso](docs/USAGE.it.md#log-e-diagnostica).

## Aggiornamento

Il metodo consigliato è il **reflash della scheda SD** — tutta la configurazione è auto-rilevata, quindi una nuova installazione equivale a un aggiornamento.

```bash
# 1. Estrai il database MPD dalla vecchia SD (preserva l'indice della libreria musicale):
./scripts/backup-from-sd.sh

# 2. Flasha con Pi Imager, poi:
./scripts/prepare-sd.sh          # include il database MPD automaticamente

# 3. Inserisci la SD e accendi — pronto in ~10 minuti
```

> **Utenti avanzati:** Watchtower (opt-in) e `update.sh` sono disponibili per aggiornamenti in-place via SSH. Vedi [Guida all'Uso — Aggiornamento](docs/USAGE.it.md#aggiornamento).

## Documentazione

| Guida | Contenuto |
|-------|-----------|
| [**Installazione**](docs/INSTALL.it.md) | Passo-passo completo: Raspberry Pi Imager, preparazione SD, primo avvio, verifica — macOS/Linux/Windows |
| [Hardware e Rete](docs/HARDWARE.it.md) | Requisiti server/client, configurazioni Raspberry Pi, banda di rete, setup consigliati |
| [Uso e Operazioni](docs/USAGE.it.md) | Architettura, servizi, controllo MPD, configurazione mDNS, deployment, CI/CD |
| [Sorgenti Audio](docs/SOURCES.it.md) | Tutti i tipi di sorgente, parametri, API JSON-RPC, streaming da Android/Tidal |
| [Changelog](CHANGELOG.md) | Cronologia delle versioni |

## Ecosistema snapMULTI

| Componente | Percorso | Descrizione |
|------------|----------|-------------|
| Server | `/` | Server audio multiroom (Snapcast, Spotify, AirPlay, MPD, Tidal) |
| Client | `client/` | Player audio con display copertine (snapclient + visualizer + fb-display) |

## Ringraziamenti

snapMULTI è costruito su questi progetti open source:

- **[Snapcast](https://github.com/badaix/snapcast)** di Johannes Pohl — il motore di streaming audio multiroom al cuore di questo progetto
- **[go-librespot](https://github.com/devgianlu/go-librespot)** di devgianlu — implementazione Spotify Connect
- **[shairport-sync](https://github.com/mikebrady/shairport-sync)** di Mike Brady — ricevitore audio AirPlay
- **[MPD](https://www.musicpd.org/)** — Music Player Daemon
- **[myMPD](https://github.com/jcorporation/myMPD)** di jcorporation — client web per MPD
- **[tidal-connect](https://github.com/edgecrush3r/tidal-connect-docker)** di edgecrush3r — Tidal Connect per Raspberry Pi
