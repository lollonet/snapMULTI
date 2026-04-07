# snapMULTI — Guida Completa all'Installazione

🇬🇧 [English](INSTALL.md) | 🇮🇹 **Italiano**

Questa guida ti porta da una scheda SD vuota a un sistema audio multiroom funzionante, passo dopo passo.

---

## Di cosa hai bisogno

| Elemento | Note |
|----------|------|
| Raspberry Pi 4 (2 GB+ RAM) | Pi 5 dovrebbe funzionare; Pi 3B+ è supportato e testato (profilo minimal) |
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

### 1b. Scegliere la scheda SD

Clicca **Choose Storage** → seleziona la tua scheda SD.

> Se non vedi la tua scheda: assicurati che sia inserita. Su Windows, Imager mostra solo le unità rimovibili — non mostrerà i dischi fissi.

### 1c. Configurare il SO (importante)

Clicca **Next** → Imager chiede **"Would you like to apply OS customisation settings?"** → clicca **Edit Settings**.

Compila la tab **General**:

| Campo | Cosa inserire |
|-------|---------------|
| **Set hostname** | Un nome per questo Pi — es. `snapvideo` (server), `snapdigi` (speaker) |
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

## Passo 3 — Clonare il repository

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

### Clone

```bash
git clone --recurse-submodules https://github.com/lollonet/snapMULTI.git
cd snapMULTI
```

> `--recurse-submodules` è richiesto — scarica anche il software client (speaker). Se lo dimentichi, lo script lo scaricherà automaticamente quando necessario.

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
| **4 — Configurare dopo** | Salta la configurazione musicale. Aggiungi la tua libreria a `/opt/snapmulti/.env` dopo l'installazione (vedi [USAGE.it.md](USAGE.it.md)) |

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

> Se l'HDMI rimane vuoto per tutto il tempo: il Pi sta ancora installando via SSH in background. Aspetta 10 minuti prima di presumere che qualcosa sia andato storto.

---

## Passo 6 — Verificare che funzioni

### Trovare il Pi sulla tua rete

Dal tuo computer, fai ping al Pi usando il suo hostname:

```bash
ping snapvideo.local     # sostituisci con l'hostname che hai scelto in Imager
```

Se il ping funziona, collegati via SSH:

```bash
ssh <username>@snapvideo.local
```

> **Utenti Windows:** Usa Windows Terminal, PowerShell o [PuTTY](https://putty.org) con `snapvideo.local` come host.

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
http://snapvideo.local:8180
```

Questo è **myMPD** — naviga la tua libreria musicale, crea playlist, controlla la riproduzione.

L'**interfaccia web Snapcast** (controlla quale speaker riproduce cosa) è a:

```
http://snapvideo.local:1780
```

---

## Collegare le sorgenti musicali

| Sorgente | Cosa fare dopo l'installazione |
|----------|--------------------------------|
| **Spotify** | Apri l'app Spotify → Dispositivi → seleziona **"snapvideo Spotify"** (Premium richiesto) |
| **AirPlay** | iPhone/iPad/Mac → icona AirPlay → seleziona **"snapvideo AirPlay"** |
| **Tidal** | Apri l'app Tidal → Cast → seleziona **"snapvideo Tidal"** (solo ARM/Pi) |
| **Libreria musicale** | Apri `http://snapvideo.local:8180` e naviga i tuoi file |
| **App Snapcast** | [Android](https://play.google.com/store/apps/details?id=de.badaix.snapcast) — connetti a `snapvideo.local` |

---

## Aggiungere più Pi speaker

Per ogni speaker aggiuntivo:

1. Flasha una nuova scheda SD con Raspberry Pi Imager
   - Imposta un **hostname unico** (es. `snapdigi`, `kitchen`, `bedroom`)
   - Stesso user/password del tuo server è comodo ma non richiesto
2. Reinserisci → esegui `prepare-sd.sh` → scegli **1) Audio Player**
3. Avvia → il Pi speaker trova automaticamente il server tramite mDNS

Il nuovo speaker appare nell'interfaccia web Snapcast a `http://snapvideo.local:1780` entro ~30 secondi dall'avvio.

---

## Risoluzione problemi primo avvio

| Sintomo | Causa probabile | Soluzione |
|---------|-----------------|-----------|
| HDMI vuoto, nessun progresso | Normale su avvio headless | Aspetta 10 min; controlla con `ping snapvideo.local` |
| `ping snapvideo.local` fallisce | Pi non ancora in rete | Aspetta 2 min; se ancora fallisce, controlla impostazione paese WiFi in Imager. I canali 5 GHz 100+ (DFS) possono fallire al primo avvio — prova il 2.4 GHz o un canale 5 GHz non-DFS (36–48) |
| `.local` si risolve ma SSH rifiutato | SSH non ancora avviato | Aspetta altri 1–2 min |
| SSH funziona ma container mancanti | Installazione ancora in corso | Esegui `sudo journalctl -u cloud-init -f` per guardare il progresso |
| Container in loop di restart | Download immagini fallito (rete) | Esegui `sudo docker compose logs -f` in `/opt/snapmulti` |
| Hostname sbagliato | Valore sbagliato impostato in Imager | Reflasha SD, ricomincia dal Passo 1 |
| `prepare-sd.sh`: partizione boot non trovata | SD non reinserita dopo Imager | Rimuovi SD, reinserisci, esegui di nuovo lo script |
| Windows: script non si avvia | Execution policy | Esegui prima `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` |
| HAT audio non rilevato (client) | Scheda senza EEPROM | Collegati via SSH ed esegui `sudo bash /opt/snapclient/common/scripts/setup.sh` per selezionare il tuo HAT manualmente |

Per problemi post-installazione vedi [Risoluzione problemi in USAGE.it.md](USAGE.it.md#risoluzione-problemi).

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
