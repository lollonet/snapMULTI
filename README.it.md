🇮🇹 **Italiano** | 🇬🇧 [English](README.md)

# snapMULTI — Audio multi-room per Raspberry Pi

[![CI](https://github.com/lollonet/snapMULTI/actions/workflows/validate.yml/badge.svg)](https://github.com/lollonet/snapMULTI/actions/workflows/validate.yml)
[![release](https://img.shields.io/github/v/release/lollonet/snapMULTI?color=orange)](https://github.com/lollonet/snapMULTI/releases/latest)
[![Docker pulls](https://img.shields.io/docker/pulls/lollonet/snapmulti-server?color=green)](https://hub.docker.com/r/lollonet/snapmulti-server)
[![License GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)

snapMULTI è pensato per chi vuole un **sistema audio multi-room open source** senza costruirsi a mano tutto lo stack Linux audio. Devi comunque flashare Raspberry Pi OS, scaricare il software (uno ZIP, oppure git se hai dimestichezza con la riga di comando) e rispondere a poche domande sulla tua configurazione; snapMULTI automatizza la parte difficile — Snapcast, Docker, routing audio, discovery dei servizi (mDNS), boot read-only e diagnostica di recupero. Fai cast da **Spotify**, **AirPlay**, **Tidal** o dalla tua libreria; tutti gli altoparlanti suonano insieme con deriva inferiore al millisecondo. I servizi di streaming mantengono i loro requisiti di account.

<p align="center">
  <img src="docs/images/display-playing.png" alt="Display HDMI snapMULTI: copertina + spettro + info brano" width="640">
</p>

> **Uscita audio.** snapMULTI manda un segnale di linea dal Pi — non amplifica. Serve uno di:
> - una **cassa attiva** (amplificatore integrato, es. Edifier R1280T, Audioengine A2+),
> - un **DAC HAT validato** (famiglia HiFiBerry DAC+ o InnoMaker PCM5122) verso amplificatore esterno e casse passive,
> - un **HAT digitale validato** (famiglia HiFiBerry Digi+) verso un sintoamplificatore AV via S/PDIF, oppure
> - un'uscita configurata manualmente (DAC USB, HDMI, jack del Pi, HAT amplificato) se ti senti a tuo agio nel diagnosticare hardware audio.
>
> Esempi di setup completi, stato di validazione e uscite sperimentali: [docs/HARDWARE.it.md#configurazioni-consigliate](docs/HARDWARE.it.md#configurazioni-consigliate).

## Per chi è snapMULTI

| Pubblico | Adatto? | Cosa promettiamo |
|----------|---------|------------------|
| **Maker / self-hosted / Home Assistant** | Primario | Controllo locale, hardware economico, integrazione col resto del tuo stack self-hosted. A tuo agio con flash SD + terminale. |
| **Audio enthusiast Linux-friendly** | Secondario | Un sistema multi-room che non dipende da un'app vendor. Adatto se già usi MPD / Snapcast e vuoi orchestrare meglio. |
| **Piccoli ambienti professionali** (coworking, B&B, studi) | Opportunistico, non target | Realistico solo se hai un tecnico interno o un integratore — snapMULTI non fornisce SLA né supporto commerciale. |

snapMULTI non è "Sonos open-source". È un'appliance mantenuta dalla community per chi vuole il controllo completo del proprio audio locale.

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
- **Rete**: il 2,4 GHz funziona ma il 5 GHz o Ethernet sono più stabili.
- **Privacy**: snapMULTI non fa telemetria, non ha un servizio cloud snapMULTI e non richiede account snapMULTI. Gira nella tua LAN. Installazione e aggiornamenti scaricano comunque pacchetti e immagini Docker, e le integrazioni streaming contattano i rispettivi servizi esterni (Spotify, Tidal, Apple/AirPlay, sorgenti metadati/copertine).
- **I servizi di streaming hanno requisiti propri**: Spotify Connect richiede Premium. Tidal Connect funziona solo su ARM (l'architettura della CPU dei Raspberry Pi — quindi va su qualsiasi Pi, ma non su un server x86) ed è abilitato di default sugli install Pi (disabilitalo rimuovendo `tidal` da `COMPOSE_PROFILES`, vedi [nota sicurezza](docs/USAGE.it.md#nota-sicurezza-tidal-connect)). AirPlay richiede un dispositivo Apple.

## Configurazione consigliata per iniziare

Se è la tua prima installazione snapMULTI, scegli il percorso noioso: **Raspberry Pi 4 (4 GB)**, una **microSD A1/A2** buona, Ethernet se puoi, e un percorso DAC / amplificatore noto dalla pagina [Hardware](docs/HARDWARE.it.md). Evita di iniziare con un Pi Zero 2 W server, un esperimento con alimentatore debole o un setup NAS+WiFi+HAT sconosciuto. Prima ottieni un successo pulito, poi espandi.

## Limiti noti

- **Pi Zero 2 W** è supportato solo come Audio Player headless; non è un target server o "Server + Player".
- **Path NAS con spazi** vengono rifiutati. Rinomina `Music Share` in `Music_Share` lato NAS.
- **Tidal Connect** usa un componente proprietario upstream. È abilitato di default sugli install ARM; rimuovi `tidal` da `COMPOSE_PROFILES` in `/opt/snapmulti/.env` se vuoi uno stack interamente free software.
- **Gli aggiornamenti sono reflash-first**. Il filesystem è read-only: aggiorni riscrivendo l'SD con una nuova release (~10 min, le impostazioni si auto-rilevano), non applicando patch a un sistema in esecuzione.
- **La qualità hardware conta**. SD scadenti, alimentatori deboli e WiFi instabile causano la maggior parte dei fallimenti iniziali.

## Quick start

Checklist hardware (modello Pi, SD, uscita audio) da consultare prima: [docs/HARDWARE.it.md](docs/HARDWARE.it.md).

### 1. Flash dell'SD con [Raspberry Pi Imager](https://www.raspberrypi.com/software/)

snapMULTI dipende dai metadati cloud-init che Imager scrive quando imposti hostname, utente, WiFi e SSH qui sotto. **I flasher generici (Balena Etcher, `dd`) non funzionano** — copiano solo byte, niente metadati, e il Pi si avvia senza rete né login.

- OS: **Raspberry Pi OS Lite (64-bit)**
- Clicca l'icona ingranaggio (`Ctrl/Cmd+Shift+X`) e imposta: hostname, username + password, WiFi (o lascia vuoto per Ethernet), **☑ Abilita SSH (password)**

### 2. Scarica i file snapMULTI

Per una prima installazione, scarica ed estrai lo [ZIP dell'ultima release](https://github.com/lollonet/snapMULTI/releases/latest). Usa `git clone https://github.com/lollonet/snapMULTI.git` solo se usi già Git o vuoi contribuire. Il nome della cartella non importa — `prepare-sd.sh` risolve da solo il proprio path.

### 3. Reinserisci l'SD ed esegui lo script di preparazione

Reinserisci la SD appena flashata. Su macOS potrebbe comparire un pop-up *"Il disco inserito non è leggibile"* per la partizione Linux del Pi — clicca **Ignora**; la partizione `bootfs` viene montata comunque.

Se hai scaricato lo ZIP, estrailo prima. Apri un terminale (**Terminale** su macOS/Linux, **PowerShell** su Windows), entra con `cd` nella cartella snapMULTI che hai clonato o estratto, poi esegui:

```bash
# macOS / Linux:
./scripts/prepare-sd.sh
# permission denied? esegui: bash scripts/prepare-sd.sh

# Windows PowerShell:
.\scripts\prepare-sd.ps1
```

Lo script ti guida con poche domande: il ruolo (**Audio Player** / **Music Server** / **Server + Player**), la sorgente musicale (streaming / USB / NAS), l'uscita audio (auto-rilevamento o scelta dell'HAT), i dati di connessione al NAS se hai scelto una libreria di rete, e impostazioni avanzate opzionali (modalità read-only, tag immagine). I default sono sensati — puoi premere Invio sulla maggior parte.

> Prima esecuzione PowerShell su Windows? `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

### 4. Avvia il Pi

Espelli l'SD, inseriscila nel Pi, accendi. Aspetta circa 10-15 minuti — l'installer al primo boot gira da solo (niente SSH), mostra l'avanzamento su HDMI se hai uno schermo collegato, poi si riavvia una volta.

**Ha funzionato quando**: con uno schermo collegato, il display HDMI mostra la schermata "in riproduzione" di snapMULTI (copertina / spettro). In ogni caso, da un altro dispositivo apri `http://<hostname>.local:8083/status` — tutti i controlli devono essere verdi. Poi fai cast di qualcosa (vedi **Dopo l'installazione** più sotto).

> **Procedura dettagliata** con troubleshooting e percorso di recupero diagnostico: [docs/INSTALL.it.md](docs/INSTALL.it.md).
> **Policy hardware** (combinazioni Pi/audio validate vs sperimentali): [docs/HARDWARE.it.md](docs/HARDWARE.it.md).

## Dopo l'installazione

Sostituisci `hostname` con quello che hai impostato allo Step 1.

| URL | Cosa fa |
|-----|---------|
| `http://hostname.local:1780` | **Snapweb** — volume per stanza, raggruppa altoparlanti, cambia sorgente |
| `http://hostname.local:8180` | **myMPD** — sfoglia e riproduce la libreria musicale |
| `http://hostname.local:8083/status` | **Pagina di stato** — stato container + audio + NFS |

### Cast dalle tue app

| Sorgente | Come |
|----------|------|
| **Spotify** | Apri l'app → seleziona "*hostname* Spotify" (Premium) |
| **AirPlay** | Icona AirPlay → "*hostname* AirPlay" |
| **Tidal** | Cast su "*hostname* Tidal" (solo ARM/Pi, **abilitato di default** — vedi [nota sicurezza](docs/USAGE.it.md#nota-sicurezza-tidal-connect) per disabilitarlo) |
| **Qualsiasi app** | Stream PCM raw sulla porta 4953 ([dettagli](docs/USAGE.it.md#streaming-da-android-niente-cast-nativo)) |

## Aggiungere altoparlanti

Flasha un'altra SD → scegli **Audio Player** → inserisci in qualunque Pi. mDNS scopre automaticamente il server.

O su qualsiasi Linux: `sudo apt install snapclient`.

## Aggiornamento

snapMULTI si aggiorna riscrivendo l'SD, non applicando patch. Il Pi gira con un filesystem read-only (un blackout non può corromperlo), quindi non esiste un upgrade in-place: riscrivi l'ultima release sull'SD esattamente come la prima volta. Ci vogliono gli stessi ~10–15 min, e ogni impostazione (ruolo, HAT audio, path NAS, rete) si auto-rileva al primo boot, quindi non riconfiguri nulla.

Prima di riflashare, esegui `./scripts/backup-from-sd.sh` per conservare l'indice della libreria MPD — altrimenti la scansione della libreria riparte da zero.

## Se qualcosa fallisce

**Installato ma non lo raggiungi?** Se il Pi ha finito ma `http://<hostname>.local:1780` non si apre: cerca l'indirizzo IP del Pi nella lista dispositivi del router e usa quello. La risoluzione `.local` (mDNS) non funziona su alcune configurazioni Windows e su WiFi ospiti / mesh / VLAN che isolano i client — tieni il Pi e il telefono/laptop sulla stessa rete normale. Altro aiuto mDNS: [docs/TROUBLESHOOTING.it.md](docs/TROUBLESHOOTING.it.md).

Se è il primo boot a interrompersi: snapMULTI esegue l'installazione come servizio systemd e cattura tutto strada facendo. La trap di cleanup scrive un pacchetto diagnostico anonimizzato sulla **partizione boot** dell'SD (FAT32, leggibile da qualsiasi computer — niente SSH necessario):

```
/boot/firmware/snapmulti-diag-install-failed-<UTC-ts>.tar.gz
```

Estrai la SD, collegala al computer, allega il pacchetto diagnostico a una [issue GitHub](https://github.com/lollonet/snapMULTI/issues/new/choose). Il pacchetto è anonimizzato (niente MAC, niente IP della LAN, niente SSID, niente password, niente token API) — si può condividere pubblicamente in sicurezza. Sintomi comuni e test di salute (`scripts/device-smoke.sh`): [docs/TROUBLESHOOTING.it.md](docs/TROUBLESHOOTING.it.md).

## Glossario

Definizioni rapide dei termini che incontrerai in questo README e nella documentazione.

| Termine | Cos'è |
|---------|-------|
| **Server** | Il Raspberry Pi (o qualsiasi box Linux) che ospita le sorgenti musicali — Snapcast, MPD, Spotify Connect, AirPlay, Tidal — e distribuisce l'audio a uno o più altoparlanti |
| **Audio Player** *(o "client" / "altoparlante")* | Un Raspberry Pi che riceve l'audio dal server e lo riproduce attraverso un DAC / amplificatore / altoparlante collegato. Uno per stanza |
| **Snapcast** | Il motore open source di sincronizzazione multi-room su cui snapMULTI è costruito. Lato server: `snapserver`; lato client: `snapclient` |
| **HAT** | "Hardware Attached on Top" — una piccola scheda che si innesta sul GPIO del Pi. La validazione di lancio snapMULTI copre famiglie HAT audio specifiche; controlla la policy hardware prima di comprare |
| **mDNS** / `.local` | "Multicast DNS" — come i dispositivi si annunciano in LAN senza configurare IP manualmente. `pi-server.local` si risolve automaticamente sulla maggior parte delle reti |
| **NAS** | Network-attached storage — un box separato (Synology, QNAP, custom) che ospita la libreria musicale, montato da snapMULTI via NFS o SMB |
| **Filesystem read-only** | snapMULTI monta il root in sola lettura dopo l'install (overlayroot + fuse-overlayfs), così un blackout non può corrompere la SD. Le modifiche vengono cancellate al reboot a meno che tu non disattivi la modalità RO |
| **Pacchetto diagnostico** | Archivio `.tar.gz` anonimizzato sulla partizione boot della SD (`snapmulti-diag-*.tar.gz`) — scritto automaticamente quando un'installazione fallisce, allegabile a una issue GitHub senza far trapelare segreti |

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
