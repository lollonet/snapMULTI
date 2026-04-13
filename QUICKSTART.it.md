# Guida Rapida

Trasforma un Raspberry Pi in un sistema audio multiroom. Riproduci da Spotify, AirPlay o dalla tua libreria musicale su altoparlanti in ogni stanza.

## Cosa Serve

- Raspberry Pi 4 o 5 (2 GB+ RAM)
- Scheda microSD (16 GB+)
- Un computer per preparare la SD

## Installazione (5 minuti)

**Passo 1** — Flasha la SD con [Raspberry Pi Imager](https://www.raspberrypi.com/software/):
- Scegli **Raspberry Pi OS Lite (64-bit)**
- Imposta hostname, username/password, WiFi, abilita SSH

**Passo 2** — Rimuovi la SD, reinserisci, poi esegui:

```bash
git clone https://github.com/lollonet/snapMULTI.git
./snapMULTI/scripts/prepare-sd.sh
```

Scegli cosa installare:
1. **Audio Player** — un altoparlante che riproduce dal tuo server
2. **Music Server** — Spotify, AirPlay, Tidal, libreria musicale
3. **Server + Player** — entrambi su un unico Pi

**Passo 3** — Inserisci la SD nel Pi, accendi. Attendi ~10 minuti. Fatto.

## Ascolta Musica

| Sorgente | Come |
|----------|------|
| **Spotify** | Apri l'app, seleziona dispositivo: "*hostname* Spotify" |
| **AirPlay** | Icona AirPlay, seleziona "*hostname* AirPlay" |
| **Libreria musicale** | Naviga su `http://hostname.local:8180` |

Gestisci gli altoparlanti su `http://hostname.local:1780`

## Aggiungi Altri Altoparlanti

Flasha un'altra SD, scegli "Audio Player", inseriscila in un altro Pi. Trova il server automaticamente.

## Aggiornamento

Riflasha la SD con l'ultima versione. Tutto qui.

Se hai una libreria musicale (NFS/USB), estrai prima il database per evitare la riscansione:
```bash
./scripts/backup-from-sd.sh    # legge il backup dalla vecchia SD
# flasha con Imager, poi:
./scripts/prepare-sd.sh        # include il database automaticamente
```

---

**Problemi?** Vedi la [guida completa](docs/INSTALL.it.md).
**Dettagli hardware?** Vedi la [guida hardware](docs/HARDWARE.it.md).
**Windows?** Usa `.\snapMULTI\scripts\prepare-sd.ps1` in PowerShell.
