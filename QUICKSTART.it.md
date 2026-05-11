# Guida Rapida

Trasforma un Raspberry Pi in un sistema audio multiroom. Riproduci da Spotify, AirPlay o dalla tua libreria musicale su altoparlanti in ogni stanza.

## Cosa Serve

- Raspberry Pi 4 o 5 (2 GB+ RAM)
- Scheda microSD (16 GB+)
- Un computer per preparare la SD — macOS, Linux o **Windows**

## Installazione (5 minuti)

### Passo 1 — Flasha la SD

Usa [Raspberry Pi Imager](https://www.raspberrypi.com/software/):

1. Scegli **Raspberry Pi OS Lite (64-bit)**.
2. Clicca sull'**icona dell'ingranaggio** (o `Ctrl/Cmd+Shift+X`) per aprire le opzioni avanzate.
3. Compila:
   - **Hostname** (es. `pi-audio` — il nome con cui raggiungerai il Pi sulla rete)
   - **Username + password** (utente di default; userai questi per il login)
   - **WiFi** (SSID + password, oppure lascia vuoto se usi Ethernet)
   - **☑ Abilita SSH** con autenticazione tramite password

> **Cosa fa "Abilita SSH"?** Attiva la shell remota sul Pi così gli script di installazione possono completare il setup via rete al primo boot. Senza, il Pi parte ma non puoi parlarci senza tastiera + monitor. Spunta sempre questa casella.
>
> *Hai già flashato senza abilitare SSH?* Crea un file vuoto chiamato `ssh` (senza estensione) sulla partizione `bootfs` della SD prima del primo boot — Raspberry Pi OS lo rileva e abilita SSH in automatico.

### Passo 2 — Scarica i file del progetto snapMULTI

Scegli una delle due. Entrambe producono una cartella `snapMULTI` accanto al tuo prompt.

**A. Scarica come ZIP** (no git richiesto, più facile per Windows / non sviluppatori):

1. Apri <https://github.com/lollonet/snapMULTI/releases/latest>
2. In **Assets**, scarica **`Source code (zip)`**
3. Scompatta. La cartella si chiamerà tipo `snapMULTI-0.7.3` — rinominala in **`snapMULTI`** così i comandi sotto funzionano senza modifiche.

**B. Clona con git** (consigliato se hai già git installato — aggiornamenti più facili):

```bash
git clone https://github.com/lollonet/snapMULTI.git
```

### Passo 3 — Esegui lo script di preparazione

Reinserisci la SD appena flashata così la partizione `bootfs` appare sul tuo computer, poi apri un terminale nella cartella che *contiene* `snapMULTI/`:

**macOS / Linux:**

```bash
./snapMULTI/scripts/prepare-sd.sh
```

**Windows (PowerShell):**

```powershell
.\snapMULTI\scripts\prepare-sd.ps1
```

> Prima volta che lanci uno script PowerShell? Windows blocca gli script non firmati per default. Autorizzali una volta per il tuo utente:
>
> ```powershell
> Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
> ```

Lo script chiede cosa installare:

1. **Audio Player** — un altoparlante che riproduce dal tuo server
2. **Music Server** — Spotify, AirPlay, Tidal, libreria musicale
3. **Server + Player** — entrambi su un unico Pi

### Passo 4 — Avvia il Pi

Espelli la SD, inseriscila nel Pi, accendi. Attendi ~10 minuti. Fatto.

## URL dopo l'installazione

Tutti sul Pi server — sostituisci `hostname` con quello impostato al Passo 1:

| URL | Cosa fa |
|-----|---------|
| `http://hostname.local:1780` | **Snapweb** — regola volumi delle stanze, mute, raggruppa/sposta altoparlanti, vedi cosa sta suonando |
| `http://hostname.local:8180` | **myMPD** — sfoglia e riproduci la libreria musicale (NFS / USB / file locali) |
| `http://hostname.local:8083/status` | **Pagina stato sistema** — salute container, presenza sorgenti, ultimi risultati smoke (aggiornata ogni 5 min) |
| `http://hostname.local:8083/health` | **Health check** — restituisce `{"status":"ok"}` quando il server è su; utile per probe di uptime / monitoring |

Salva `:1780` e `:8083/status` nei preferiti — coprono il 90% dell'uso quotidiano.

## Ascolta Musica

| Sorgente | Come |
|----------|------|
| **Spotify** | Apri l'app, seleziona dispositivo: "*hostname* Spotify" |
| **AirPlay** | Icona AirPlay, seleziona "*hostname* AirPlay" |
| **Libreria musicale** | Apri `http://hostname.local:8180` (myMPD) |

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
