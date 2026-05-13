🇬🇧 [English](README.md) | 🇮🇹 **Italiano**

# snapMULTI - Server Audio Multiroom

[![CI](https://github.com/lollonet/snapMULTI/actions/workflows/validate.yml/badge.svg)](https://github.com/lollonet/snapMULTI/actions/workflows/validate.yml)
[![release](https://img.shields.io/github/v/release/lollonet/snapMULTI?color=orange)](https://github.com/lollonet/snapMULTI/releases/latest)
[![downloads](https://img.shields.io/docker/pulls/lollonet/snapmulti-server?color=green)](https://hub.docker.com/r/lollonet/snapmulti-server)
[![Donate](https://img.shields.io/badge/Donate-PayPal-yellowgreen)](https://paypal.me/lolettic)
[![License](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)

Licenza: `GPL-3.0-only` · [Codice di condotta](CODE_OF_CONDUCT.md) · [Note di terze parti](THIRD-PARTY-NOTICES.md)

Riproduci musica in sincronia in ogni stanza. Streaming da Spotify, AirPlay, la tua libreria musicale o qualsiasi app — tutti gli altoparlanti suonano insieme.

**Cos'è**: un sistema audio multiroom in stile Sonos che ti costruisci da solo con Raspberry Pi (~60 € per stanza con un DAC HAT). Tutto open source, niente cloud, niente abbonamento, niente telemetria. Flash della SD, boot, fatto.

<p align="center">
  <img src="docs/images/display-playing.png" alt="snapMULTI in riproduzione — copertina, analizzatore di spettro, info brano" width="720">
  <br>
  <em>Display HDMI: copertina, analizzatore di spettro, metadati brano — rendering diretto su framebuffer, nessun desktop</em>
</p>

## Come funziona

```text
   Spotify   AirPlay   Tidal   myMPD web UI   qualsiasi app TCP audio
      │         │        │           │                │
      └─────────┴────────┴───────────┴────────────────┘
                              │
                              ▼
                    ┌───────────────────┐
                    │  Server (Pi / NUC)│  miscela le sorgenti, codifica
                    │  snapserver       │  una volta, distribuisce uno stream
                    └───────────────────┘
                              │  Snapcast su LAN (TCP/UDP)
                              ▼
              ┌───────────┬───────────┬──────────────┐
              │  Pi #1    │  Pi #2    │  Pi #N       │  ognuno esegue snapclient
              │  Soggiorno│  Cucina   │  Camera      │  + un DAC HAT o USB DAC
              └───────────┴───────────┴──────────────┘
                              │
                              ▼
                          🔊 Altoparlanti
```

Tutti i client suonano in lock-step (~5 ms di drift tra stanze). Aggiungi un client flashando un'altra SD e inserendola in qualsiasi Pi — niente IP da configurare, niente pairing, mDNS trova il server da solo. Server e un client possono girare sullo stesso Pi (modalità `both`).

## Perché snapMULTI

| | snapMULTI | Sonos | Volumio | MoOde |
|---|---|---|---|---|
| **Costo per stanza** | ~60 € (Pi 4 + DAC HAT) | 200 €+ (One SL) | ~60 € hardware + abbonamento Volumio Plus per multi-stanza | ~60 € hardware |
| **Open source** | ✅ GPL-3.0 | ❌ proprietario | Parziale (multi-stanza è a pagamento) | ✅ |
| **Sync multi-stanza** | ✅ Snapcast (~5 ms) | ✅ proprietario | ✅ (con Plus) | ❌ singolo dispositivo |
| **Senza cloud** | ✅ tutto locale | ❌ richiede cloud Sonos | Parziale | ✅ |
| **Telemetria** | ❌ nessuna, nessuna prevista | ✅ raccolta di default | Parziale | ❌ |
| **Spotify Connect** | ✅ Premium | ✅ | ✅ (Plus) | ✅ |
| **AirPlay** | ✅ AirPlay 1 | ✅ AirPlay 2 | ✅ (Plus) | ✅ |
| **Tidal Connect** | ✅ (solo ARM, opt-in) | ✅ | ✅ (Plus) | ✅ |
| **Display HDMI copertina** | ✅ fb-display integrato | ❌ | ❌ | ❌ |
| **Setup** | flash SD → boot → fatto (~10 min) | setup app | wizard (~30 min) | wizard |
| **Hardware proprietario** | nessuno — porti il tuo Pi | richiesto | nessuno | nessuno |

Scegli snapMULTI se vuoi **multi-stanza + Pi-DIY + zero cloud + zero abbonamento** in un solo pacchetto. Scegli Sonos se vuoi plug-and-play e non ti dispiace il prezzo e il vincolo cloud. Scegli Volumio Plus se hai già il loro hardware e l'abbonamento multi-stanza ti sta bene.

## Sorgenti

| Sorgente | Come |
|----------|------|
| **Spotify** | Apri l'app → seleziona "*hostname* Spotify" (Premium) |
| **AirPlay** | Icona AirPlay → seleziona "*hostname* AirPlay" |
| **Tidal** | Apri l'app → cast su "*hostname* Tidal" (solo ARM/Pi, **opt-in** — vedi [nota sicurezza](docs/USAGE.it.md#nota-sicurezza-tidal-connect)) |
| **Libreria musicale** | Naviga su `http://hostname.local:8180` |
| **Qualsiasi app** | Stream sulla porta 4953 ([dettagli](docs/USAGE.it.md#streaming-da-android-niente-cast-nativo)) |

Gestisci gli altoparlanti su `http://hostname.local:1780`
Verifica lo stato del sistema su `http://hostname.local:8083`

> **Riferimento completo delle porte**: vedi [`docs/USAGE.it.md#servizi-e-porte`](docs/USAGE.it.md#servizi-e-porte) per l'elenco completo di porte, protocolli e cosa espone ogni container.

## Avvio Rapido

**[QUICKSTART.it.md](QUICKSTART.it.md)** — da zero alla musica in 5 minuti.

### Raspberry Pi (principianti)

```bash
# Flasha la SD con Pi Imager (64-bit Lite, imposta hostname/WiFi/SSH)
# Reinserisci la SD, poi:
git clone https://github.com/lollonet/snapMULTI.git
./snapMULTI/scripts/prepare-sd.sh
# Inserisci la SD nel Pi, accendi, attendi ~10 min
```

### Qualsiasi Linux (avanzato)

```bash
git clone https://github.com/lollonet/snapMULTI.git && cd snapMULTI
sudo ./scripts/deploy.sh   # oppure: cp .env.example .env && docker compose up -d
```

## Aggiungi Altoparlanti

Flasha un'altra SD → scegli "Audio Player" → inseriscila in un altro Pi. Trova il server automaticamente.

Oppure installa snapclient su qualsiasi Linux: `sudo apt install snapclient`

## Aggiornamento

Riflasha la SD con l'ultima versione — tutta la configurazione viene auto-rilevata.

Per preservare l'indice della libreria musicale: `./scripts/backup-from-sd.sh` prima del flash.
Vedi [Guida all'Uso — Aggiornamento](docs/USAGE.it.md#aggiornamento) per opzioni avanzate.

## Documentazione

| Guida | Contenuto |
|-------|-----------|
| **[Guida Rapida](QUICKSTART.it.md)** | Installazione in una pagina — da zero alla musica in 5 minuti |
| [Installazione](docs/INSTALL.it.md) | Passo-passo completo con risoluzione problemi |
| [Hardware](docs/HARDWARE.it.md) | Modelli Pi, DAC HAT, rete, combinazioni testate |
| [Uso e Operazioni](docs/USAGE.it.md) | Architettura, sorgenti audio, MPD, mDNS, deployment, troubleshooting |
| [Changelog](CHANGELOG.md) | Cronologia versioni |

## Contribuire

PR, segnalazioni di bug e post "mostra il tuo setup" sono benvenuti — vedi [CONTRIBUTING.it.md](CONTRIBUTING.it.md).

Per problemi di sicurezza, segui il flusso di disclosure privato in [SECURITY.md](SECURITY.md).

## Ringraziamenti

Costruito su [Snapcast](https://github.com/badaix/snapcast) (Johannes Pohl), [go-librespot](https://github.com/devgianlu/go-librespot) (devgianlu), [shairport-sync](https://github.com/mikebrady/shairport-sync) (Mike Brady), [MPD](https://www.musicpd.org/), [myMPD](https://github.com/jcorporation/myMPD) (jcorporation), [tidal-connect](https://github.com/edgecrush3r/tidal-connect-docker) (edgecrush3r).
