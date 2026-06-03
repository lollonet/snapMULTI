🇮🇹 **Italiano** | 🇬🇧 [English](USAGE.md)

# Riferimento architettura

Il riferimento "come è fatto" — servizi, porte, sorgenti audio, modello di sicurezza, mDNS, unit systemd. Questo file **non è un how-to**. Per le procedure operative (multi-room, NFS, `.env` personalizzato, deploy manuale, MPD CLI, JSON-RPC) vedi [ADVANCED.it.md](ADVANCED.it.md). Per la prima installazione vedi [INSTALL.it.md](INSTALL.it.md). Per la pipeline tecnica dietro l'installazione (host `prepare-sd.sh` → cloud-init → `firstboot.sh` → riavvio) vedi [INSTALL-FLOW.it.md](INSTALL-FLOW.it.md). Per i fallimenti vedi [TROUBLESHOOTING.it.md](TROUBLESHOOTING.it.md). Per la compatibilità hardware vedi [HARDWARE.it.md](HARDWARE.it.md).

## Architettura

> I razionali architetturali sono registrati in [`docs/adr/`](adr/ADR-INDEX.md). Più rilevanti per questa sezione: [ADR-001](adr/ADR-001.host-networking.md) (host networking — perché ogni container usa `network_mode: host`) e [ADR-002](adr/ADR-002.fifo-audio-routing.md) (named pipe in `/audio/` per il routing source → snapserver).

Stack server (7 container, host networking):

| Container | Ruolo | Porta |
|-----------|-------|-------|
| `snapserver` | Streaming audio + controllo JSON-RPC | 1704, 1705, 1780, 4953 |
| `mpd` | Riproduzione libreria musicale (output FIFO) | 6600, 8000 |
| `mympd` | Web UI per MPD | 8180 |
| `shairport-sync` | Ricevitore AirPlay (output FIFO) | 5000, 5858 |
| `librespot` | Spotify Connect (output FIFO) | 24879 + porta effimera |
| `tidal-connect` | Tidal Connect, solo ARM (output FIFO) | 2019 |
| `metadata` | Copertine + info brano | 8082 (WS), 8083 (HTTP) — vedi [CLIENT-METADATA.md](CLIENT-METADATA.md) per i pattern di integrazione |

Catena audio: sorgente → pipe FIFO in `/audio/` → snapserver → FLAC sulla rete → snapclient → uscita ALSA. Formato unificato `44100:16:2` (44,1 kHz / 16-bit / stereo) su tutte le sorgenti, niente resampling.

Stack client (3 container su Pi 3/4/5; snapclient nativo da `.deb` su Pi Zero 2W):
`snapclient` + `audio-visualizer` (porta 8081) + `fb-display` (copertine HDMI).

## Modello di sicurezza dei container

Default applicati a ogni container in `docker-compose.yml`:

| Impostazione | Valore | Perché |
|--------------|--------|--------|
| `cap_drop` | `ALL` | I container non hanno bisogno di capability root per instradare l'audio |
| `read_only` | `true` + tmpfs su `/tmp` / `/run` | Un processo compromesso non può scrivere sull'image né persistere codice |
| `no-new-privileges` | `true` | I binari setuid dentro il container non possono escalare |
| `user` | `PUID:PGID` (default `1000:1000`) | Processo non-root dentro il container |
| Limiti risorse | mem + CPU per servizio in `deploy.resources` | Un container fuori controllo non può affamare gli altri |

**Eccezione 1 — container D-Bus / Avahi** (`snapserver`, `shairport-sync`, `librespot`): hanno bisogno di `apparmor:unconfined` per accedere al socket D-Bus dell'host per l'annuncio mDNS (Avahi) e di `cap_add: DAC_OVERRIDE` per scrivere sulle named-pipe FIFO possedute dall'utente `PUID` dell'host. AppArmor nel profilo Ubuntu default blocca la connessione D-Bus altrimenti. `mpd` monta gli stessi socket Avahi/D-Bus ma mantiene il profilo AppArmor di default — non richiede `apparmor:unconfined`. Tutto il resto resta dropped.

**Eccezione 2 — `tidal-connect`** (solo ARM): gira come root perché il binario proprietario upstream lo richiede. **Abilitato di default sugli install ARM** — `deploy.sh` scrive `COMPOSE_PROFILES=tidal` in `/opt/snapmulti/.env` quindi il profilo `tidal` è attivo subito su Pi 3/4/5. Per **disabilitarlo** (es. per uno stack completamente free-software), rimuovi `tidal` da `COMPOSE_PROFILES` in `/opt/snapmulti/.env` e fai `sudo systemctl restart snapmulti-server.service`. Vedi [Nota sicurezza Tidal Connect](#nota-sicurezza-tidal-connect) per la disclosure completa.

**Privacy / telemetria**: snapMULTI in sé non "chiama casa". Non esistono un servizio cloud snapMULTI, un piano di controllo ospitato, endpoint di telemetria, SDK di analisi o account snapMULTI. Le API di controllo e metadati girano sulla LAN locale. Traffico esterno esiste comunque per dipendenze e integrazioni scelte: download OS/Docker durante installazione o aggiornamento, scaricamento immagini da Docker Hub, traffico dei servizi Spotify/Tidal/AirPlay e ricerche di metadati/copertine.

**Threat model**: snapMULTI è progettato per una LAN fidata — server e client sulla stessa sottorete dietro un router residenziale. Fuori scope: esposizione WAN (niente autenticazione su JSON-RPC, Snapweb o myMPD), scenari multi-tenant, client malevoli sulla LAN. Se ti serve uno di questi casi, metti davanti un reverse proxy con auth e usa `bind 127.0.0.1` in `config/snapserver.conf`.

## Sorgenti audio

9 sorgenti definite in `config/snapserver.conf` (5 attive, 4 disponibili come esempi commentati):

| # | Stream ID | Tipo | Come riprodurre |
|---|-----------|------|-----------------|
| 1 | `MPD` | pipe | Web UI myMPD su `:8180`, o qualsiasi client MPD (`mpc`, Cantata, MPDroid) sulla porta `6600` |
| 2 | `Tidal` | pipe (solo ARM) | Cast dall'app Tidal — appare come `<hostname> Tidal` |
| 3 | `AirPlay` | pipe | Cast da iOS / macOS — appare con l'hostname del server |
| 4 | `Spotify` | pipe | Cast da qualsiasi app Spotify Premium — appare come `<hostname> Spotify` |
| 5 | `TCP-Input` | tcp (server, :4953) | Stream PCM raw da qualunque sorgente: `ffmpeg ... tcp://<server>:4953` |
| 6 | `LineIn` | alsa | Cattura da dispositivo ALSA. Scommenta in `snapserver.conf` |
| 7 | `AutoSwitch` | meta | Failover automatico fra altri stream. Scommenta in `snapserver.conf` |
| 8 | `Alert` | file | Riproduce un file audio fisso a richiesta. Scommenta in `snapserver.conf` |
| 9 | `Remote` | tcp (client) | Pull da un altro server TCP. Scommenta in `snapserver.conf` |

I parametri specifici (path FIFO, controlscript, formato campione) vivono inline in `config/snapserver.conf` — quel file è il riferimento autorevole.

### Livelli di supporto delle sorgenti

snapMULTI non garantisce lo stesso impegno a lungo termine per tutte le sorgenti. Leggi prima di costruire un workflow che dipende da una di esse.

| Sorgente | Livello | Nota |
|----------|---------|------|
| Snapcast, MPD, AirPlay (shairport-sync), TCP-Input | Prima classe | Dipendenze open-source, impegno a lungo termine di snapMULTI a mantenerle funzionanti |
| Spotify Connect | Best-effort | Richiede Premium. Dipende dall'upstream reverse-engineered `go-librespot`; crash storici tracciati per release |
| Tidal Connect | Best-effort, sunset previsto | Binario proprietario `ifi-companion` su immagine base Raspbian Stretch EOL. Migrazione a Bookworm verificata non fattibile (2026-05-06). Verrà rimosso quando il container upstream si rompe. **Non costruire workflow che dipendano da Tidal nel lungo periodo.** |

### Personalizzare i nomi device

Spotify e Tidal usano per default `<hostname> Spotify` / `<hostname> Tidal`. Override tramite `SPOTIFY_NAME` / `TIDAL_NAME` in `.env` — vedi [ADVANCED.it.md — Configurazione personalizzata](ADVANCED.it.md#configurazione-personalizzata--file-env).

### Nota sicurezza Tidal Connect

<a id="nota-sicurezza-tidal-connect"></a>
Tidal Connect è **abilitato di default sugli install ARM** (`deploy.sh` scrive `COMPOSE_PROFILES=tidal` in `/opt/snapmulti/.env` su Pi 3/4/5). Per disabilitarlo per uno stack completamente free-software, rimuovi `tidal` da `COMPOSE_PROFILES` in `/opt/snapmulti/.env` e riavvia `snapmulti-server.service`. Il container upstream è costruito su Raspbian Stretch (EOL 2019), prende i pacchetti da `archive.debian.org` con `trusted=yes`, e contiene un binario proprietario non manutenuto. Solo ARM (non esiste una build x86_64). Leggi il blocco di disclosure in `docker-compose.yml` prima di tenerlo abilitato.

### Streaming da Android (niente cast nativo)

| Metodo | App | Qualità | Setup |
|--------|-----|---------|-------|
| Mittente AirPlay | AirMusic, AllStream | Buona | Installa app → seleziona target AirPlay = hostname del server |
| TCP via BubbleUPnP | BubbleUPnP + rilancio con ffmpeg | Buona | Cattura in BubbleUPnP, rilancia con `ffmpeg ... tcp://server:4953` |
| TCP diretto | Termux + ffmpeg | Lossless | `ffmpeg -f pulse -i default -f s16le -ar 44100 -ac 2 tcp://server:4953` |

## Interfacce di controllo

| Interfaccia | URL | Cosa fa |
|-------------|-----|---------|
| **Snapweb** | `http://<server>:1780` | Cambia sorgente per altoparlante, raggruppa/separa, volume per stanza |
| **myMPD** | `http://<server>:8180` | Sfoglia libreria musicale, code, playlist, copertine |
| **Stato sistema** | `http://<server>:8083/status` | Salute container + audio + NFS (auto-refresh) |
| **App Snapcast per Android** | [Play Store](https://play.google.com/store/apps/details?id=de.badaix.snapcast) | Equivalente mobile di Snapweb |

Regole rapide:
- Riprodurre dalla libreria → myMPD
- Cambiare sorgente di un altoparlante → Snapweb o app Android
- Cast da Spotify/AirPlay/Tidal → l'app della sorgente sceglie l'altoparlante
- Health check → pagina `/status`

Comandi avanzati (MPD CLI, switch sorgente via JSON-RPC, `.env` personalizzato): [ADVANCED.it.md](ADVANCED.it.md).

## Autodiscovery (mDNS)

Snapcast, AirPlay, Spotify e Tidal si annunciano sulla LAN tramite l'`avahi-daemon` **dell'host** (socket D-Bus bind-mounted nei container che lo richiedono). Requisito host: `systemctl is-active avahi-daemon` deve restituire `active`. **Non eseguire avahi-daemon dentro i container** — la porta 5353 va in conflitto con l'host.

Snapcast 0.35.x esce dal suo poll loop Avahi su `AVAHI_CLIENT_FAILURE` senza retry. A partire da v0.7.5 le unit systemd non usano più `PartOf=avahi-daemon.service` — quel cascade era troppo aggressivo (qualunque restart di avahi sull'host smontava l'intero stack Compose). Il recovery è ora esplicito e operator-driven: `scripts/common/system-tune.sh::tune_avahi_daemon` riavvia `avahi-daemon` e poi esplicitamente `snapmulti-server.service` + `snapclient.service` così le connessioni libavahi-client dentro snapcast vengono ristabilite. `ExecStop` di routine è `docker compose stop -t 5` (non distruttivo), così un ciclo clean start è 2–5 s invece dei 30–40 s di teardown del precedente modello `compose down`.

Verifica rapida:

```bash
avahi-browse -r _snapcast._tcp --terminate
avahi-browse -r _raop._tcp --terminate
ss -tlnp | grep -E '1704|1705|1780'
```

Quando la discovery non funziona, vedi [TROUBLESHOOTING.it.md](TROUBLESHOOTING.it.md) — le sezioni rilevanti sono "Il device non compare in rete / `.local` non risolve" (il Pi non è visibile dai client), "Gli speaker non trovano il server (snapclient non si connette)" (discovery snapclient) e "Spotify / AirPlay / Tidal non visibili nell'app di cast" (discovery lato app).

## Unit systemd

Dopo l'installazione systemd possiede il ciclo di vita dei container (ADR-005). `restart: unless-stopped` di Docker gestisce i crash, systemd gestisce il boot.

- Server: `snapmulti-server.service` (con `ExecStartPre=restore-snapmulti-state` per ripristinare gruppi snapcast + stato myMPD da `/boot/firmware/snapmulti-backup/` — vedi [ADVANCED.it.md](ADVANCED.it.md#filesystem-read-only)), `snapmulti-status.timer`, `snapmulti-backup.timer` (backup database MPD), `snapmulti-state-backup.path` (backup event-driven dell'intera workdir di myMPD), `snapmulti-state-backup.timer` (rete di sicurezza ogni 5 min — cattura periodicamente `server.json` di snapserver; gli heartbeat `lastSeen` ogni ~3 s escludono un trigger event-driven su quel file)
- Client: `snapclient.service`, `snapclient-discover.timer`, `snapclient-display.service` (solo client HDMI)
- Tutti: `snapmulti-boot-tune.service`, `snapmulti-auto-boot-smoke.service` (segnale audio del test di salute al boot — vedi [TROUBLESHOOTING.it.md](TROUBLESHOOTING.it.md#toni-test-salute) per vocabolario e opt-out)

Ispeziona con `systemctl cat <unit>`. Path di deployment e strategie di aggiornamento: [ADVANCED.it.md](ADVANCED.it.md#deploy-senza-prepare-sd).

## Log e diagnostica

```bash
# log live server
cd /opt/snapmulti && docker compose logs -f
docker compose logs -f snapserver shairport-sync librespot mpd

# salute container
docker compose ps
docker inspect --format='{{.State.Health.Status}}' snapserver

# pagina stato sistema (browser)
http://<server>:8083/status
```

Fallimenti all'install e post-install (con la procedura del pacchetto diagnostico): [TROUBLESHOOTING.it.md](TROUBLESHOOTING.it.md).
