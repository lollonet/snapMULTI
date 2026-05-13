# snapMULTI — Guida Completa all'Installazione

🇬🇧 [English](INSTALL.md) | 🇮🇹 **Italiano**

Questa guida ti porta da una scheda SD vuota a un sistema audio multiroom funzionante, passo dopo passo.

---

## Percorso rapido

Hai già dimestichezza con Raspberry Pi Imager e terminale? Questa è tutta l'installazione in una sola checklist:

1. Flasha **Raspberry Pi OS Lite (64-bit)** con Raspberry Pi Imager.
2. Nelle impostazioni di Imager, configura hostname, username/password, paese/rete WiFi e abilita SSH.
3. Quando la scrittura finisce, rimuovi e reinserisci la SD così la partizione `bootfs` viene montata.
4. Scarica lo ZIP dell'ultima release snapMULTI oppure esegui `git clone https://github.com/lollonet/snapMULTI.git`.
5. Dalla cartella snapMULTI, esegui `./scripts/prepare-sd.sh` su macOS/Linux oppure `.\scripts\prepare-sd.ps1` su Windows.
6. Scegli cosa deve fare questo Pi: **Audio Player**, **Music Server** o **Server + Player**.
7. Espelli la SD, avvia il Pi e attendi circa 10-15 minuti. Installa, verifica e poi riavvia una volta.
8. Apri `http://<hostname>.local:1780` per Snapweb oppure `http://<hostname>.local:8180` per myMPD.

Se un passaggio non è chiaro, continua con la procedura dettagliata qui sotto. Se il primo boot fallisce, recupera il bundle diagnostico dalla SD come descritto in [TROUBLESHOOTING.it.md — Recupero del bundle diagnostico](TROUBLESHOOTING.it.md#recupero-del-bundle-diagnostico).

---

## Di cosa hai bisogno

| Elemento | Note |
|----------|------|
| Raspberry Pi 4 o 5 (2 GB+ RAM) | Pi 5 completamente supportato; Pi 3B+ testato (profilo minimal) |
| Scheda microSD (16 GB+) | Classe 10 / A1 o migliore. 32 GB consigliati |
| Alimentatore | Ufficiale 15W USB-C per Pi 4 |
| Un secondo computer | macOS, Linux o Windows — per preparare la scheda SD |
| Connessione di rete | Ethernet (consigliato) o WiFi |
| Uscita audio | DAC USB, HAT HiFiBerry o HDMI |

Per un Pi speaker (modalità Audio Player): come sopra più un modo per collegare gli altoparlanti (HAT o dispositivo audio USB).

---

## Passo 1 — Flashare la scheda SD

Usa **[Raspberry Pi Imager](https://www.raspberrypi.com/software/)** (download gratuito per macOS, Windows, Linux).

### 1a. Scegliere il SO

1. Apri Raspberry Pi Imager
2. Clicca **Choose Device** → seleziona **Raspberry Pi 4** (o il tuo modello)
3. Clicca **Choose OS** → scorri fino a **Raspberry Pi OS (other)** → seleziona **Raspberry Pi OS Lite (64-bit)**

> **Perché Lite?** snapMULTI funziona interamente in Docker. L'ambiente desktop spreca RAM e storage. Usa Lite.

> **Importante: la versione 64-bit è obbligatoria.** Non selezionare la versione 32-bit — le immagini Docker di snapMULTI sono compilate solo per `arm64`. Questo vale per tutti i modelli di Pi, incluso il Pi Zero 2 W (Imager potrebbe proporre 32-bit come predefinito — assicurati di selezionare 64-bit).

### 1b. Scegliere la scheda SD

Clicca **Choose Storage** → seleziona la tua scheda SD.

> Se non vedi la tua scheda: assicurati che sia inserita. Su Windows, Imager mostra solo le unità rimovibili — non mostrerà i dischi fissi.

### 1c. Configurare il SO (importante)

Clicca **Next** → Imager chiede **"Would you like to apply OS customisation settings?"** → clicca **Edit Settings**.

Compila la tab **General**:

| Campo | Cosa inserire |
|-------|---------------|
| **Set hostname** | Un nome per questo Pi — es. `pi-server` (server), `pi-display` (speaker) |
| **Set username and password** | Qualsiasi username/password — li userai per SSH |
| **Configure wireless LAN** | Il tuo SSID WiFi, password e **paese** (richiesto per le bande 5 GHz) |
| **Set locale** | Il tuo fuso orario e layout tastiera |

Passa alla tab **Services**:

- Seleziona **Enable SSH**
- Seleziona **Use password authentication**

Clicca **Save**, poi **Yes** per applicare le impostazioni.

> **Suggerimento:** Se ti connetti via Ethernet, puoi saltare il WiFi — il Pi otterrà un IP automaticamente via DHCP.

### 1d. Scrivere l'immagine

Clicca **Yes** per cancellare e scrivere. Ci vogliono 3–8 minuti a seconda della velocità della tua scheda SD.

Quando Imager mostra "Write Successful" — **non cliccare ancora il pulsante Eject** (vedi passo successivo).

---

## Passo 2 — Reinserire la scheda SD

Imager potrebbe smontare la scheda SD dopo la scrittura. Hai bisogno che sia montata per eseguire lo script di setup.

**macOS:** Rimuovi e reinserisci la scheda SD. Appare nel Finder come **bootfs**.

**Linux:** Rimuovi e reinserisci. Si monta automaticamente, di solito in `/media/$USER/bootfs`. Verifica con:
```bash
lsblk -o NAME,LABEL,MOUNTPOINT | grep bootfs
```

**Windows:** Rimuovi e reinserisci. Appare in File Explorer come un piccolo drive (~250 MB) etichettato **bootfs** — tipicamente `E:\` o `F:\`. Ignora la partizione più grande se ne appaiono due; serve solo quella FAT32 piccola.

---

## Passo 3 — Scaricare i file snapMULTI

Scegli una delle due opzioni. Entrambe producono una cartella `snapMULTI/` che il passo successivo si aspetta.

### Opzione A — Scaricare lo ZIP (senza Git)

1. Apri [https://github.com/lollonet/snapMULTI/releases/latest](https://github.com/lollonet/snapMULTI/releases/latest) nel browser
2. Sotto **Assets**, clicca **Source code (zip)** per scaricare l'ultima release
3. Estrai lo ZIP — ottieni una cartella chiamata `snapMULTI-<versione>` (per es. `snapMULTI-0.7.4`). Il nome della cartella non è vincolante — `prepare-sd.sh` ricava la project root dalla propria posizione
4. Apri un terminale dentro quella cartella estratta

> Preferisci lo ZIP della release taggata al pulsante verde **Code → Download ZIP** della home page del repo — quest'ultimo scarica il branch `main`, che può contenere lavori non rilasciati.
>
> Gli esempi nel README e in `INSTALL.it.md` mostrano comandi tipo `./snapMULTI/scripts/prepare-sd.sh` per coerenza con `git clone` (che crea sempre una cartella `snapMULTI`). Se la tua cartella ha un altro nome, adatta il path (o entra nella cartella con `cd` ed esegui `./scripts/prepare-sd.sh`).

### Opzione B — Clone con Git (consigliato se vuoi aggiornare)

Hai bisogno di Git installato sul tuo computer.

**macOS** — Git viene con gli Xcode Command Line Tools:
```bash
xcode-select --install
```
O installa tramite [Homebrew](https://brew.sh): `brew install git`

**Linux (Debian/Ubuntu):**
```bash
sudo apt install git
```

**Windows** — Installa [Git for Windows](https://git-scm.com/download/win). Accetta tutte le impostazioni predefinite durante l'installazione. Poi apri **Git Bash** (non PowerShell) per i prossimi passi, o usa PowerShell con i comandi sottostanti.

Poi:
```bash
git clone https://github.com/lollonet/snapMULTI.git
cd snapMULTI
```

> Il repository include sia il software server che client in un unico monorepo.

---

## Passo 4 — Preparare la scheda SD

Esegui lo script di preparazione. Rileva automaticamente la tua scheda SD e ti guida attraverso un breve menu.

### macOS / Linux

```bash
./scripts/prepare-sd.sh
```

Se il rilevamento automatico fallisce (più schede SD, punto di mount insolito):
```bash
./scripts/prepare-sd.sh /Volumes/bootfs        # macOS
./scripts/prepare-sd.sh /media/$USER/bootfs    # Linux
```

### Windows (PowerShell)

Apri PowerShell come utente normale (non Amministratore). Se non hai mai eseguito script prima:
```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

Poi:
```powershell
.\scripts\prepare-sd.ps1
```

Se il rilevamento automatico fallisce:
```powershell
.\scripts\prepare-sd.ps1 -Boot E:\    # sostituisci E: con la lettera del drive della tua scheda SD
```

---

### Menu 1 — Cosa dovrebbe fare questo Pi?

> **Nota:** I menu di `prepare-sd.sh` sono in inglese. Le descrizioni in italiano qui sotto ti aiutano a scegliere l'opzione giusta.

```
  +---------------------------------------------+
  |        snapMULTI -- SD Card Setup            |
  |                                              |
  |  What should this Pi do?                     |
  |                                              |
  |  1) Audio Player                             |
  |     Play music from your server on speakers  |
  |                                              |
  |  2) Music Server                             |
  |     Central hub for Spotify, AirPlay, etc.   |
  |                                              |
  |  3) Server + Player                          |
  |     Both server and local speaker output     |
  |                                              |
  +---------------------------------------------+
```

| Opzione | Quando usarla |
|---------|---------------|
| **1 — Audio Player** | Questo Pi sarà solo uno speaker. Riproduce l'audio da un server snapMULTI altrove sulla tua rete |
| **2 — Music Server** | Hub centrale. Ospita Spotify Connect, AirPlay, Tidal, MPD. Nessuna uscita speaker locale |
| **3 — Server + Player** | Un Pi fa tutto — server e speaker locale. Buono per iniziare con un singolo dispositivo |

> **Utenti Pi Zero 2 W:** l'installer si comporta diversamente perché la scheda ha solo 512 MB di RAM:
> - **Scelta 1 (Audio Player)** — funziona, ma il profilo viene auto-promosso a `client-native`: snapclient nativo da `.deb`, niente Docker, niente display per la copertina, solo ruolo single-client. Lo stack Docker completo non sta in RAM
> - **Scelte 2 e 3** — il primo boot si interrompe con `Pi Zero 2W (512 MB RAM) cannot host the snapMULTI server stack` e si ferma. Il server richiede almeno un Pi 3 B+ con 1 GB di RAM. Riflashare l'SD con la scelta 1, oppure usare un Pi diverso
>
> Vedi [HARDWARE.it.md — Note Pi Zero 2 W](HARDWARE.it.md#note-pi-zero-2-w) per la lista completa dei vincoli.

---

### Menu 2 — Dov'è la tua musica? *(Solo Music Server e Server+Player)*

```
  +---------------------------------------------+
  |        Where is your music?                  |
  |                                              |
  |  1) Streaming only                           |
  |     Spotify, AirPlay, Tidal (no local files) |
  |                                              |
  |  2) USB drive                                |
  |     Plug in before powering on the Pi        |
  |                                              |
  |  3) Network share (NFS/SMB)                  |
  |     Music on a NAS or another computer       |
  |                                              |
  |  4) I'll set it up later                     |
  |     Mount music dir manually after install   |
  |                                              |
  +---------------------------------------------+
```

| Opzione | Note |
|---------|------|
| **1 — Solo streaming** | Nessuna libreria musicale locale. Spotify, AirPlay e Tidal funzionano senza file |
| **2 — Drive USB** | Collega il tuo drive USB al Pi *prima* di accenderlo. Si monta automaticamente |
| **3 — Condivisione di rete** | Ti verranno chiesti hostname/IP del server e percorso di condivisione. NFS per Linux/Mac/NAS; SMB per condivisioni Windows. Le credenziali sono memorizzate sulla scheda SD temporaneamente e rimosse dopo il primo avvio |
| **4 — Configurare dopo** | Salta la configurazione musicale. Aggiungi la tua libreria a `/opt/snapmulti/.env` dopo l'installazione (vedi [ADVANCED.it.md — Libreria musicale in rete](ADVANCED.it.md#libreria-musicale-in-rete)) |

Se scegli **Condivisione di rete**, dovrai quindi inserire:
- **NFS:** hostname o IP del server (es. `nas.local`) e percorso di export (es. `/volume1/music`)
- **SMB:** hostname o IP del server, nome condivisione (es. `Music`) e username/password opzionali

---

### Cosa fa lo script

Dopo aver risposto ai menu, `prepare-sd.sh` / `prepare-sd.ps1`:

1. Copia l'installer e i file di configurazione sulla partizione di boot
2. Modifica il meccanismo di primo avvio del Pi (`user-data` su Bookworm) per eseguire l'installer automaticamente
3. Imposta una risoluzione temporanea di 800×600 per la schermata di progresso dell'installazione
4. Verifica che tutti i file siano presenti
5. Smonta / espelle la scheda SD

Dovresti vedere **"All checks passed."** e **"SD card ready!"** alla fine.

---

## Passo 5 — Avviare il Pi

1. **Rimuovi la scheda SD** dal tuo computer
2. Inseriscila nel Pi
3. Collega l'alimentazione
4. **Aspetta ~5–10 minuti** — il Pi installa Docker, scarica le immagini e avvia tutti i servizi

### Cosa vedrai sull'HDMI

Se hai un monitor o TV collegato, il Pi mostra una visualizzazione di progresso testuale:

```
snapMULTI Auto-Install
======================

[ ] Waiting for network...
[>] Installing Docker...          [=====>          ] 40%
[ ] Pulling images...
[ ] Starting services...
[ ] Verifying health...
```

Il Pi **si riavvia automaticamente** quando l'installazione è completa. Dopo il riavvio, il display diventa scuro (normale — nessun desktop su Lite OS).

> Se l'HDMI rimane nero per tutto il tempo: l'installazione continua comunque in background — `firstboot.sh` gira come servizio systemd e non ha bisogno del display. Aspetta 10 minuti; per controllare lo stato senza schermo, fai `ssh <username>@<hostname>.local` ed esegui `sudo journalctl -u snapmulti-firstboot.service -f`.

---

## Passo 6 — Verificare che funzioni

> **Placeholder hostname.** Da qui in avanti, `<hostname>.local` significa l'hostname che hai impostato in Imager al Passo 1c. Se hai impostato `myradio`, usa `myradio.local` ovunque appaia `<hostname>.local` qui sotto.

### Trovare il Pi sulla tua rete

Dal tuo computer, fai ping al Pi usando il suo hostname:

```bash
ping <hostname>.local
```

Se il ping funziona, collegati via SSH:

```bash
ssh <username>@<hostname>.local
```

> **Utenti Windows:** Usa Windows Terminal, PowerShell o [PuTTY](https://putty.org) con `<hostname>.local` come host.

> **Se `.local` non si risolve:** Usa l'indirizzo IP invece. Trovalo nella lista client DHCP del tuo router, o controlla l'output HDMI dopo il riavvio — il Pi stampa il suo IP sulla console.

### Controllare i container in esecuzione

```bash
sudo docker ps --format 'table {{.Names}}\t{{.Status}}'
```

**Music Server (opzione 2 o 3)** — output atteso:
```
NAMES              STATUS
snapserver         Up X minutes (healthy)
shairport-sync     Up X minutes (healthy)
librespot          Up X minutes (healthy)
mpd                Up X minutes (healthy)
mympd              Up X minutes (healthy)
metadata           Up X minutes (healthy)
```
Su Raspberry Pi (ARM): appare anche `tidal-connect` se hai un Pi 4/5.

**Audio Player (opzione 1)** — output atteso:
```
NAMES              STATUS
snapclient         Up X minutes (healthy)
audio-visualizer   Up X minutes (healthy)
fb-display         Up X minutes (healthy)
```
`audio-visualizer` e `fb-display` appaiono solo se un display HDMI era collegato al primo avvio.

### Aprire l'interfaccia web (solo server)

Apri il tuo browser e vai a:

```
http://<hostname>.local:8180
```

Questo è **myMPD** — naviga la tua libreria musicale, crea playlist, controlla la riproduzione.

L'**interfaccia web Snapcast** (controlla quale speaker riproduce cosa) è a:

```
http://<hostname>.local:1780
```

---

## Collegare le sorgenti musicali

| Sorgente | Cosa fare dopo l'installazione |
|----------|--------------------------------|
| **Spotify** | Apri l'app Spotify → Dispositivi → seleziona **"`<hostname>` Spotify"** (Premium richiesto) |
| **AirPlay** | iPhone/iPad/Mac → icona AirPlay → seleziona **"`<hostname>` AirPlay"** |
| **Tidal** | Apri l'app Tidal → Cast → seleziona **"`<hostname>` Tidal"** (solo ARM/Pi) |
| **Libreria musicale** | Apri `http://<hostname>.local:8180` e naviga i tuoi file |
| **App Snapcast** | [Android](https://play.google.com/store/apps/details?id=de.badaix.snapcast) — connetti a `<hostname>.local` |

---

## Prossimi passi

| Obiettivo | Dove |
|-----------|------|
| Aggiungere un altro altoparlante (multi-room), collegare un NAS, personalizzare `.env`, deploy manuale | [ADVANCED.it.md](ADVANCED.it.md) |
| Qualcosa è fallito (primo boot, post-install, mDNS, audio) | [TROUBLESHOOTING.it.md](TROUBLESHOOTING.it.md) |
| Matrice hardware, requisiti di rete, dettagli Pi Zero 2 W | [HARDWARE.it.md](HARDWARE.it.md) |
| Architettura, sorgenti audio, modello di sicurezza | [USAGE.it.md](USAGE.it.md) |

---

## Cosa è installato dove

| Percorso | Contenuto |
|----------|-----------|
| `/opt/snapmulti/` | Server: file Docker Compose, config, dati |
| `/opt/snapclient/` | Client: file Docker Compose, config audio |
| `/opt/snapmulti/.env` | Impostazioni server (modifica per cambiare config) |
| `/opt/snapclient/.env` | Impostazioni client (modifica per cambiare config) |

Per cambiare impostazioni dopo l'installazione:
```bash
sudo nano /opt/snapmulti/.env      # o /opt/snapclient/.env per Pi speaker
cd /opt/snapmulti
sudo docker compose up -d           # NON restart — restart non ricarica .env
```

---

## Requisiti di rete

- Il Pi e il tuo telefono/computer devono essere sulla **stessa subnet** (stesso router) perché mDNS (hostname `.local`) e auto-discovery funzionino
- La maggior parte delle reti domestiche funziona senza modifiche — nessun port forwarding o firewall necessario
- Per la lista completa delle porte e le regole firewall, vedi [Guida Hardware e Rete — Regole Firewall](HARDWARE.it.md#regole-firewall)
- mDNS usa UDP 5353 — se hai più VLAN, avrai bisogno di un ripetitore mDNS o imposta IP statici in `.env`
