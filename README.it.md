🇮🇹 **Italiano** | 🇬🇧 [English](README.md)

# snapMULTI — Audio multi-room per Raspberry Pi

[![CI](https://github.com/lollonet/snapMULTI/actions/workflows/validate.yml/badge.svg)](https://github.com/lollonet/snapMULTI/actions/workflows/validate.yml)
[![release](https://img.shields.io/github/v/release/lollonet/snapMULTI?color=orange)](https://github.com/lollonet/snapMULTI/releases/latest)
[![Docker pulls](https://img.shields.io/docker/pulls/lollonet/snapmulti-server?color=green)](https://hub.docker.com/r/lollonet/snapmulti-server)
[![License GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)

snapMULTI è pensato per chi vuole un **sistema audio multi-room open source** senza costruirsi a mano tutto lo stack Linux audio. Devi comunque flashare Raspberry Pi OS e rispondere a poche domande; snapMULTI automatizza la parte difficile — Snapcast, Docker, routing audio, discovery dei servizi (mDNS), boot read-only e diagnostica di recupero. Fai cast da **Spotify**, **AirPlay**, **Tidal** o dalla tua libreria; tutti gli altoparlanti suonano insieme con deriva inferiore al millisecondo. Local-first: niente cloud o telemetria snapMULTI; i servizi di streaming mantengono i loro requisiti di account.

<p align="center">
  <img src="docs/images/display-playing.png" alt="Display HDMI snapMULTI: copertina + spettro + info brano" width="640">
</p>

> **Uscita audio.** snapMULTI manda un segnale di linea dal Pi — non amplifica. Serve uno di:
> - una **cassa attiva** (amplificatore integrato, es. Edifier R1280T, Audioengine A2+),
> - un **HAT con amplificatore integrato** (es. [HiFiBerry AMP2](https://www.hifiberry.com/shop/boards/hifiberry-amp2/)) che pilota casse passive,
> - un **DAC HAT** (es. HiFiBerry DAC+ / DAC2 Pro) verso amplificatore esterno e casse passive, oppure
> - un **HAT digitale** (es. HiFiBerry Digi+) verso un sintoamplificatore AV via S/PDIF.
>
> Esempi di setup completi e combinazioni testate: [docs/HARDWARE.it.md#configurazioni-consigliate](docs/HARDWARE.it.md#configurazioni-consigliate).

## Scegli il tuo setup

| La tua situazione | Cosa installare su ogni Pi | Note |
|-------------------|----------------------------|------|
| **Un altoparlante, una stanza** | Un Pi → scegli **Audio Player** | Va bene qualsiasi Pi 3 B+ / 4 / 5 / Zero 2 W |
| **Server + un altoparlante sullo stesso Pi** | Un Pi → scegli **Server + Player** | Pi 4 2 GB+ (Pi Zero 2 W non supporta questa modalità) |
| **Server centrale, altoparlanti in altre stanze** | Un Pi → **Music Server**. Ogni Pi altoparlante → **Audio Player** | mDNS scopre automaticamente — gli speaker trovano il server al primo boot |
| **La libreria musicale è su un NAS** | Scegli Music Server o Server + Player | `prepare-sd.sh` ti chiederà il path NFS / SMB. Tieni pronti user / password per SMB |
| **Hai solo un Pi Zero 2 W come client** | Scegli **Audio Player** | Viene auto-promosso a snapclient nativo — niente Docker, niente display copertine. Vedi [Note Pi Zero 2 W](docs/HARDWARE.it.md#note-pi-zero-2-w) |

## Aspettative realistiche

- **Tempo**: ~10–15 min dall'inserimento dell'SD al primo suono. Il primo boot installa via rete, poi si riavvia una volta.
- **Livello richiesto**: devi sapere flashare un'SD con Raspberry Pi Imager, trovare il Pi tramite hostname (`.local`) o IP, e copiare un piccolo file dalla SD card se qualcosa va storto. **Non** ti serve conoscere Docker, systemd, ALSA o Snapcast — li gestisce snapMULTI.
- **L'SD è importante**: le microSD economiche sono la prima causa di "install che si blocca". Usa una SanDisk / Samsung A1 (o migliore). Minimo 16 GB.
- **Rete**: il 2,4 GHz funziona ma il 5 GHz o Ethernet sono più stabili. L'mDNS (`*.local`) deve attraversare la LAN (una sola sottorete, niente isolamento VLAN).
- **I servizi di streaming hanno requisiti propri**: Spotify Connect richiede Premium. Tidal Connect è solo ARM ed è opt-in (vedi [nota sicurezza](docs/USAGE.it.md#nota-sicurezza-tidal-connect)). AirPlay richiede un dispositivo Apple.

## Quick start

Checklist hardware (modello Pi, SD, uscita audio) da consultare prima: [docs/HARDWARE.it.md](docs/HARDWARE.it.md).

### 1. Flash dell'SD con [Raspberry Pi Imager](https://www.raspberrypi.com/software/)

snapMULTI dipende dai metadati cloud-init che Imager scrive quando imposti hostname, utente, WiFi e SSH qui sotto. **I flasher generici (Balena Etcher, `dd`) non funzionano** — copiano solo byte, niente metadati, e il Pi si avvia senza rete né login.

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

## Se qualcosa fallisce

snapMULTI esegue l'installazione come servizio systemd e cattura tutto strada facendo. Se il primo boot si interrompe, la trap di cleanup scrive un bundle diagnostico anonimizzato sulla **partizione boot** dell'SD (FAT32, leggibile da qualsiasi computer — niente SSH necessario):

```
/boot/firmware/snapmulti-diag-install-failed-<UTC-ts>.tar.gz
```

Estrai la SD, collegala al laptop, allega il bundle a una [issue GitHub](https://github.com/lollonet/snapMULTI/issues/new/choose). Il bundle è anonimizzato (niente MAC, niente IP della LAN, niente SSID, niente password, niente token API) — si può condividere pubblicamente in sicurezza. Sintomi comuni e smoke test (`scripts/device-smoke.sh`): [docs/TROUBLESHOOTING.it.md](docs/TROUBLESHOOTING.it.md).

## Documentazione

| Guida | Quando aprirla |
|-------|----------------|
| [Installazione](docs/INSTALL.it.md) | Prima configurazione — flash, boot, ascolto. Il percorso base |
| [Avanzata](docs/ADVANCED.it.md) | Multi-room, libreria NFS / SMB, `.env` personalizzato, deploy manuale, fs read-only, MPD CLI, JSON-RPC |
| [Risoluzione problemi](docs/TROUBLESHOOTING.it.md) | Qualcosa è fallito — installazione, mDNS, audio, container in restart loop |
| [Hardware](docs/HARDWARE.it.md) | Modelli Pi, DAC HAT, requisiti di rete, dettagli Pi Zero 2 W |
| [Architettura](docs/USAGE.it.md) | Come è fatto — servizi, porte, sorgenti audio, modello di sicurezza |
| [Changelog](CHANGELOG.md) | Cronologia versioni |

## Contribuire e sicurezza

PR, segnalazioni di bug e post "show your setup" sono benvenuti — vedi [CONTRIBUTING.it.md](CONTRIBUTING.it.md). Per problemi di sicurezza usa il flusso privato in [SECURITY.md](SECURITY.md). [Codice di Condotta](CODE_OF_CONDUCT.md) · [Note third-party](THIRD-PARTY-NOTICES.md) · Licenza `GPL-3.0-only`.

## Ringraziamenti

Costruito su [Snapcast](https://github.com/badaix/snapcast) (Johannes Pohl), [go-librespot](https://github.com/devgianlu/go-librespot) (devgianlu), [shairport-sync](https://github.com/mikebrady/shairport-sync) (Mike Brady), [MPD](https://www.musicpd.org/), [myMPD](https://github.com/jcorporation/myMPD) (jcorporation), [tidal-connect](https://github.com/edgecrush3r/tidal-connect-docker) (edgecrush3r).
