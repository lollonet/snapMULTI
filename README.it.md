🇮🇹 **Italiano** | 🇬🇧 [English](README.md)

# snapMULTI — Alternativa open-source a Sonos su Raspberry Pi

[![CI](https://github.com/lollonet/snapMULTI/actions/workflows/validate.yml/badge.svg)](https://github.com/lollonet/snapMULTI/actions/workflows/validate.yml)
[![release](https://img.shields.io/github/v/release/lollonet/snapMULTI?color=orange)](https://github.com/lollonet/snapMULTI/releases/latest)
[![Docker pulls](https://img.shields.io/docker/pulls/lollonet/snapmulti-server?color=green)](https://hub.docker.com/r/lollonet/snapmulti-server)
[![License GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)

Suona musica in sincronia in ogni stanza. Cast da **Spotify**, **AirPlay**, **Tidal** o dalla tua libreria — tutti gli altoparlanti suonano insieme con deriva inferiore al millisecondo. Flasha un'SD, accendi, fatto. Il core gira in locale, niente cloud o telemetria snapMULTI; i servizi di streaming (Spotify Premium, Tidal, AirPlay) mantengono i loro requisiti di account/dispositivo.

<p align="center">
  <img src="docs/images/display-playing.png" alt="Display HDMI snapMULTI: copertina + spettro + info brano" width="640">
</p>

## Perché snapMULTI

| | snapMULTI | Sonos | Volumio | MoOde |
|---|---|---|---|---|
| **Costo per stanza** | ~€60 (Pi 4 + DAC HAT) | €200+ | ~€60 + abbonamento Plus per multi-room | ~€60 |
| **Open source** | ✅ GPL-3.0 | ❌ | Parziale | ✅ |
| **Sincronia multi-room** | ✅ ~5 ms di deriva | ✅ proprietaria | ✅ (solo Plus) | ❌ singolo device |
| **Senza cloud** | ✅ tutto locale | ❌ | Parziale | ✅ |
| **Spotify / AirPlay / Tidal** | ✅ / ✅ / ✅ (ARM, opt-in) | ✅ | ✅ (Plus) | ✅ |
| **Display HDMI con copertina** | ✅ integrato | ❌ | ❌ | ❌ |
| **Tempo di setup** | ~10 min (SD zero-touch) | wizard app | ~30 min wizard | wizard |

Scegli snapMULTI quando vuoi multi-room **e** Pi-DIY **e** zero cloud **e** zero abbonamento, in un solo pacchetto.

## Quick start

Ti serve: un Raspberry Pi 4 o 5 (2 GB+), una microSD da 16 GB+ e un computer (macOS / Linux / Windows) per preparare la card.

### 1. Flash dell'SD con Raspberry Pi Imager

- OS: **Raspberry Pi OS Lite (64-bit)**
- Clicca l'icona ingranaggio (`Ctrl/Cmd+Shift+X`) e imposta: hostname, username + password, WiFi (o lascia vuoto per Ethernet), **☑ Abilita SSH (password)**

### 2. Scarica i file snapMULTI

Con `git clone https://github.com/lollonet/snapMULTI.git`, oppure scarica lo [ZIP dell'ultima release](https://github.com/lollonet/snapMULTI/releases/latest) e rinomina la cartella in `snapMULTI/`.

### 3. Reinserisci l'SD ed esegui lo script di preparazione

Reinserisci la SD appena flashata in modo che la partizione `bootfs` compaia sul computer, poi nella cartella che *contiene* `snapMULTI/`:

```bash
# macOS / Linux:
./snapMULTI/scripts/prepare-sd.sh

# Windows PowerShell:
.\snapMULTI\scripts\prepare-sd.ps1
```

Lo script chiede: **Audio Player** (solo altoparlante) / **Music Server** (Spotify+AirPlay+Tidal+libreria) / **Server + Player** (entrambi sullo stesso Pi).

> Prima esecuzione PowerShell su Windows? `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

### 4. Avvia il Pi

Espelli l'SD, inseriscila nel Pi, accendi. Aspetta ~10 minuti. L'installer al primo boot gira senza SSH, mostra l'avanzamento su HDMI se hai uno schermo collegato. Fatto.

> **Procedura dettagliata** con screenshot e troubleshooting: [docs/INSTALL.it.md](docs/INSTALL.it.md).
> **Matrice di compatibilità** (modelli Pi, DAC HAT, setup di rete): [docs/HARDWARE.it.md](docs/HARDWARE.it.md).

## Dopo l'installazione

Sostituisci `hostname` con quello che hai impostato allo Step 1.

| URL | Cosa fa |
|-----|---------|
| `http://hostname.local:1780` | **Snapweb** — volume per stanza, raggruppa altoparlanti, cambia sorgente |
| `http://hostname.local:8180` | **myMPD** — sfoglia e riproduce la libreria musicale |
| `http://hostname.local:8083/status` | **Pagina di salute** — stato container + audio + NFS |

### Cast dalle tue app

| Sorgente | Come |
|----------|------|
| **Spotify** | Apri l'app → seleziona "*hostname* Spotify" (Premium) |
| **AirPlay** | Icona AirPlay → "*hostname* AirPlay" |
| **Tidal** | Cast su "*hostname* Tidal" (solo ARM/Pi, **opt-in** — vedi [nota sicurezza](docs/USAGE.it.md#nota-sicurezza-tidal-connect)) |
| **Qualsiasi app** | Stream PCM raw sulla porta 4953 ([dettagli](docs/USAGE.it.md#streaming-da-android-niente-cast-nativo)) |

## Aggiungere altoparlanti

Flasha un'altra SD → scegli **Audio Player** → inserisci in qualunque Pi. mDNS scopre automaticamente il server.

O su qualsiasi Linux: `sudo apt install snapclient`.

## Aggiornamento

Riflasha l'SD con l'ultima release — tutta la config si auto-rileva al primo boot. Per mantenere l'indice della libreria MPD fra reflash: `./scripts/backup-from-sd.sh` prima di riflashare.

## Documentazione

| Guida | Contenuto |
|-------|-----------|
| [Installazione](docs/INSTALL.it.md) | Passo-passo con risoluzione problemi e recupero bundle diagnostico |
| [Hardware](docs/HARDWARE.it.md) | Modelli Pi, DAC HAT, rete, eccezioni Pi Zero 2 W |
| [Uso e Operazioni](docs/USAGE.it.md) | Architettura, sorgenti audio, MPD, mDNS, deployment, recupero log/diagnostica |
| [Changelog](CHANGELOG.md) | Cronologia versioni |

## Contribuire e sicurezza

PR, segnalazioni di bug e post "show your setup" sono benvenuti — vedi [CONTRIBUTING.it.md](CONTRIBUTING.it.md). Per problemi di sicurezza usa il flusso privato in [SECURITY.md](SECURITY.md). [Codice di Condotta](CODE_OF_CONDUCT.md) · [Note third-party](THIRD-PARTY-NOTICES.md) · Licenza `GPL-3.0-only`.

## Ringraziamenti

Costruito su [Snapcast](https://github.com/badaix/snapcast) (Johannes Pohl), [go-librespot](https://github.com/devgianlu/go-librespot) (devgianlu), [shairport-sync](https://github.com/mikebrady/shairport-sync) (Mike Brady), [MPD](https://www.musicpd.org/), [myMPD](https://github.com/jcorporation/myMPD) (jcorporation), [tidal-connect](https://github.com/edgecrush3r/tidal-connect-docker) (edgecrush3r).
