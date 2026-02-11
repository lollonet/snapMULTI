🇬🇧 [English](SOURCES.md) | 🇮🇹 **Italiano**

# Riferimento Sorgenti Audio

Riferimento tecnico per tutti i tipi di sorgente audio Snapcast supportati da snapMULTI.
Progettato per applicazioni di gestione remota e configurazione avanzata.

## Panoramica

| # | Sorgente | Tipo | Stream ID | Stato | Binario/Dipendenza |
|---|----------|------|-----------|-------|---------------------|
| 1 | MPD | `pipe` | `MPD` | Attiva | — (FIFO) |
| 2 | Tidal Connect | `pipe` | `Tidal` | Attiva | `tidal-connect` (container separato, solo ARM) |
| 3 | AirPlay | `pipe` | `AirPlay` | Attiva | `shairport-sync` (container separato) |
| 4 | Spotify Connect | `pipe` | `Spotify` | Attiva | `librespot` (container separato) |
| 5 | Cattura ALSA | `alsa` | `LineIn` | Disponibile | Dispositivo ALSA |
| 6 | Meta Stream | `meta` | `AutoSwitch` | Disponibile | — (integrato) |
| 7 | Riproduzione File | `file` | `Alert` | Disponibile | — (integrato) |
| 8 | Client TCP | `tcp` (client) | `Remote` | Disponibile | — (integrato) |

**Legenda stati:**
- **Attiva** — Abilitata in `config/snapserver.conf`, in esecuzione in produzione
- **Disponibile** — Esempio commentato nel file di configurazione, pronta da abilitare

---

## Sorgenti Attive

### 1. MPD (pipe)

Legge audio PCM da una pipe FIFO con nome. MPD scrive il suo output su `/audio/snapcast_fifo` e Snapserver lo legge.

**Configurazione:**
```ini
source = pipe:////audio/snapcast_fifo?name=MPD&controlscript=meta_mpd.py
```

**Parametri:**

| Parametro | Valore | Descrizione |
|-----------|--------|-------------|
| `name` | `MPD` | ID dello stream per uso client/API |
| `mode` | `create` (predefinito) | Snapserver crea la FIFO se mancante |
| `controlscript` | `meta_mpd.py` | Recupera metadati in riproduzione (titolo, artista, album, copertina) da MPD |

**Formato campionamento:** Ereditato dal globale `sampleformat = 44100:16:2`

**Come funziona:**
1. MPD riproduce file musicali locali da `/music` (mappato a `MUSIC_PATH` sull'host)
2. MPD scrive audio PCM su `/audio/snapcast_fifo` (output FIFO in `mpd.conf`)
3. Snapserver legge dalla FIFO e distribuisce ai client

**Controllo:**
```bash
mpc play                    # Avvia riproduzione
mpc add "Artista/Album"     # Accoda musica
mpc status                  # Controlla stato
```

**Connessione a MPD:** `<ip-del-server>:6600`

---

### 2. Tidal Connect (pipe da tidal-connect)

Il container tidal-connect funziona come ricevitore Tidal Connect e scrive PCM grezzo su una named pipe tramite il plugin ALSA `file`. Snapserver legge dalla pipe.

**Configurazione:**
```ini
source = pipe:////audio/tidal_fifo?name=Tidal
```

**Parametri:**

| Parametro | Valore | Descrizione |
|-----------|--------|-------------|
| `name` | `Tidal` | ID dello stream |

**Impostazioni container tidal-connect** (docker-compose.yml):

| Variabile | Valore | Descrizione |
|-----------|--------|-------------|
| `FRIENDLY_NAME` | `snapMULTI Tidal` | Nome mostrato nell'app Tidal |
| `FORCE_PLAYBACK_DEVICE` | `default` | Usa la configurazione ALSA personalizzata |

**Formato campionamento:** 44100:16:2 (fisso)

**Piattaforme supportate:** Solo ARM (Raspberry Pi 3/4/5). Non funziona su x86_64.

**Connessione da Tidal:**
1. Apri **Tidal** su qualsiasi dispositivo
2. Avvia la riproduzione di un brano
3. Tocca l'icona **Cast**
4. Seleziona **"snapMULTI Tidal"**

**Come funziona:**
1. L'app Tidal si connette al container tidal-connect via rete locale
2. tidal-connect decodifica l'audio e lo invia all'output ALSA
3. La configurazione ALSA personalizzata (`tidal-asound.conf`) reindirizza l'audio alla FIFO
4. Snapserver legge dalla FIFO e distribuisce ai client

**Verifica visibilità:**
```bash
avahi-browse -r _tidal-connect._tcp --terminate
```

**Nota:** Tidal Connect non espone metadati (titolo, artista, copertina) — il binario è closed-source senza API di controllo.

---

### 3. AirPlay (pipe da shairport-sync)

Il container shairport-sync riceve audio AirPlay dai dispositivi Apple e scrive PCM grezzo su una named pipe. Snapserver legge dalla pipe.

**Configurazione:**
```ini
source = pipe:////audio/airplay_fifo?name=AirPlay
```

**Parametri:**

| Parametro | Valore | Descrizione |
|-----------|--------|-------------|
| `name` | `AirPlay` | ID dello stream |

**Configurazione shairport-sync** (`config/shairport-sync.conf`):

| Impostazione | Valore | Descrizione |
|--------------|--------|-------------|
| `general.name` | `snapMULTI` | Nome mostrato sui dispositivi Apple |
| `pipe.name` | `/audio/airplay_fifo` | Percorso della named pipe per l'output audio |

**Formato campionamento:** 44100:16:2 (fisso, impostato da shairport-sync)

**Connessione da iOS/macOS:**
1. Apri il **Centro di Controllo**
2. Tocca l'icona **AirPlay**
3. Seleziona **"snapMULTI"**

**Verifica visibilità:**
```bash
avahi-browse -r _raop._tcp --terminate
```

**Requisiti Docker:** Modalità rete host per mDNS. Volume `/audio` condiviso con snapserver.

---

### 4. Spotify Connect (pipe da librespot)

Il container librespot funziona come ricevitore Spotify Connect e scrive PCM grezzo su una named pipe. Snapserver legge dalla pipe.

**Configurazione:**
```ini
source = pipe:////audio/spotify_fifo?name=Spotify
```

**Parametri:**

| Parametro | Valore | Descrizione |
|-----------|--------|-------------|
| `name` | `Spotify` | ID dello stream |

**Impostazioni container librespot** (Dockerfile.librespot CMD):

| Flag | Valore | Descrizione |
|------|--------|-------------|
| `--name` | `snapMULTI` | Nome mostrato nell'app Spotify |
| `--bitrate` | `320` | Qualità audio: 96, 160 o 320 kbps |
| `--backend` | `pipe` | Output su named pipe |
| `--device` | `/audio/spotify_fifo` | Percorso della named pipe per l'output audio |

**Formato campionamento:** 44100:16:2 (fisso, impostato da librespot)

**Requisiti:** Account Spotify Premium (l'abbonamento gratuito non è supportato).

**Connessione da Spotify:**
1. Apri **Spotify** su qualsiasi dispositivo
2. Avvia la riproduzione di un brano
3. Tocca **Connetti a un dispositivo**
4. Seleziona **"snapMULTI"**

---

## Sorgenti Disponibili

Queste sorgenti sono incluse come esempi commentati in `config/snapserver.conf`. Decommentare per abilitarle.

### 5. Cattura ALSA (alsa)

Cattura audio da un dispositivo hardware ALSA. Usare per ingressi line-in, microfoni o dispositivi ALSA loopback.

**Configurazione:**
```ini
source = alsa:///?name=LineIn&device=hw:0,0
```

**Parametri:**

| Parametro | Valore | Descrizione |
|-----------|--------|-------------|
| `name` | `LineIn` | ID dello stream |
| `device` | `hw:0,0` | Identificativo dispositivo ALSA |
| `idle_threshold` | `100` (predefinito) | Passa a inattivo dopo N ms di silenzio |
| `silence_threshold_percent` | `0.0` (predefinito) | Soglia di ampiezza per il rilevamento del silenzio |
| `send_silence` | `false` (predefinito) | Invia audio quando lo stream è inattivo |

**Casi d'uso:**
- Giradischi in vinile o radio FM tramite interfaccia audio
- Ingresso microfono per annunci
- Dispositivo ALSA loopback per catturare l'audio del desktop

**Requisiti Docker:**
```yaml
# Aggiungere al servizio snapserver in docker-compose.yml:
devices:
  - /dev/snd:/dev/snd
```

**Elenco dispositivi ALSA disponibili:**
```bash
docker exec snapserver cat /proc/asound/cards
```

---

### 6. Meta Stream (meta)

Legge e mixa audio da altre sorgenti stream con commutazione basata su priorità. Riproduce l'audio dalla sorgente attiva con priorità più alta.

**Configurazione:**
```ini
source = meta:///MPD/Spotify/AirPlay?name=AutoSwitch
```

**Parametri:**

| Parametro | Valore | Descrizione |
|-----------|--------|-------------|
| `name` | `AutoSwitch` | ID dello stream |
| Sorgenti | `MPD/Spotify/AirPlay` | Ordine di priorità (sinistra = più alta) |

**Come funziona la priorità:**
- Le sorgenti sono elencate da sinistra a destra, priorità più alta prima
- Quando una sorgente a priorità più alta diventa attiva, prende il controllo
- Quando si ferma, la prossima sorgente attiva suona
- Esempio: `meta:///Spotify/AirPlay/MPD` — Spotify ha priorità su AirPlay, AirPlay su MPD

**Casi d'uso:**
- Passaggio automatico a Spotify quando qualcuno inizia a trasmettere, ritorno a MPD
- Combinare avvisi campanello (priorità più alta) con musica di sottofondo (priorità più bassa)
- Creare uno stream "intelligente" che riproduce qualsiasi sorgente sia attiva

**Suggerimento:** Usa `codec=null` sulle sorgenti che servono solo come input meta per risparmiare overhead di codifica.

---

### 7. Riproduzione File (file)

Legge audio PCM grezzo da un file. Utile per avvisi, suoni campanello o annunci TTS.

**Configurazione:**
```ini
source = file:///audio/alert.pcm?name=Alert
```

**Parametri:**

| Parametro | Valore | Descrizione |
|-----------|--------|-------------|
| `name` | `Alert` | ID dello stream |
| Percorso | `/audio/alert.pcm` | Percorso assoluto al file PCM |

**Formato campionamento:** Deve corrispondere al `sampleformat` globale (44100:16:2 come predefinito).

**Creare un file PCM da qualsiasi audio:**
```bash
ffmpeg -i campanello.mp3 \
  -f s16le -ar 44100 -ac 2 \
  /percorso/audio/alert.pcm
```

**Casi d'uso:**
- Suoni campanello o allarme
- Annunci text-to-speech (genera PCM tramite `espeak` o TTS cloud)
- Messaggi pre-registrati

**Requisiti Docker:** Il file PCM deve essere accessibile dentro il container tramite il mount del volume `/audio`.

---

### 8. Client TCP (tcp client)

Si connette a un server TCP remoto per ricevere audio. L'inverso della modalità server TCP — Snapserver preleva audio da una sorgente remota.

**Configurazione:**
```ini
source = tcp://192.168.1.100:4953?name=Remote&mode=client
```

**Parametri:**

| Parametro | Valore | Descrizione |
|-----------|--------|-------------|
| `name` | `Remote` | ID dello stream |
| `mode` | `client` | Snapserver si connette all'host remoto |
| Host | `192.168.1.100` | IP della sorgente audio remota |
| Porta | `4953` | Porta di connessione |

**Formato campionamento:** 44100:16:2 (deve corrispondere alla sorgente remota).

**Casi d'uso:**
- Prelevare audio da un altro Snapserver o sorgente audio sulla rete
- Concatenare più server insieme
- Ricevere audio da un dispositivo di streaming dedicato

---

## Streaming da Android

Android non ha un equivalente integrato di AirPlay di Apple per la trasmissione audio verso ricevitori arbitrari. Ecco i metodi per trasmettere audio da app Android (incluso Tidal) a snapMULTI.

### Metodo 1: Ingresso TCP tramite BubbleUPnP (Consigliato per Tidal)

[BubbleUPnP](https://play.google.com/store/apps/details?id=com.bubblesoft.android.bubbleupnp) ha una funzione **Audio Cast** che cattura l'output audio di qualsiasi app Android e lo trasmette sulla rete.

**Configurazione:**
1. Installa **BubbleUPnP** da Google Play
2. Apri BubbleUPnP, vai su **Impostazioni > Audio Cast**
3. Configura l'output per trasmettere audio PCM grezzo
4. Su una macchina con `ffmpeg`, imposta un relay per inoltrare a snapMULTI:

```bash
# Relay audio da BubbleUPnP (renderer UPnP) all'ingresso TCP di Snapcast
# Esegui su una macchina che funge da renderer UPnP/DLNA
ffmpeg -i <stream-audio-upnp> \
  -f s16le -ar 44100 -ac 2 \
  tcp://<ip-server-snapmulti>:4953
```

**Trasmettere Tidal:**
1. Apri **Tidal** su Android, avvia la riproduzione
2. Apri **BubbleUPnP**, usa Audio Cast per catturare l'output di Tidal
3. L'audio viene inoltrato a snapMULTI tramite l'ingresso TCP
4. Tutti i client Snapcast ricevono lo stream Tidal

### Metodo 2: AirPlay da Android

Diverse app Android possono emulare l'invio AirPlay, permettendo di usare la sorgente AirPlay esistente.

**App:**
- **AirMusic** — Trasmette audio Android verso ricevitori AirPlay
- **AllStream** — Cattura l'audio di sistema e lo trasmette via AirPlay

**Configurazione:**
1. Installa un'app che emula AirPlay
2. Seleziona **"snapMULTI"** come destinazione AirPlay
3. Riproduci Tidal (o qualsiasi app) — l'audio passa attraverso AirPlay verso Snapcast

### Metodo 3: Streaming TCP Diretto

Per app che possono produrre audio grezzo (o con un relay `ffmpeg` locale):

```bash
# Su Android (tramite Termux) o una macchina relay:
ffmpeg -f pulse -i default \
  -f s16le -ar 44100 -ac 2 \
  tcp://<ip-server-snapmulti>:4953
```

Questo cattura tutto l'audio di sistema e lo invia alla sorgente TCP Input.

### Confronto

| Metodo | App Necessaria | Supporto Tidal | Qualità Audio | Complessità |
|--------|---------------|----------------|---------------|-------------|
| BubbleUPnP | BubbleUPnP | Sì | Buona (dipende dal relay) | Media |
| App AirPlay | AirMusic / AllStream | Sì (qualsiasi app) | Buona (44100:16:2) | Bassa |
| TCP Diretto | Termux + ffmpeg | Sì (audio di sistema) | Lossless (44100:16:2) | Alta |

---

## Riferimento API JSON-RPC

Snapserver espone un'API JSON-RPC sulla porta 1780 (HTTP) e porta 1705 (TCP). Usa questi endpoint per gestire le sorgenti programmaticamente da un'app di gestione.

**URL Base:** `http://<ip-del-server>:1780/jsonrpc`

### Elenco di Tutti gli Stream

```bash
curl -s http://<ip-del-server>:1780/jsonrpc \
  -H "Content-Type: application/json" \
  -d '{"id":1,"jsonrpc":"2.0","method":"Server.GetStatus"}' \
  | jq '.result.server.streams'
```

**Campi della risposta per stream:**

| Campo | Tipo | Descrizione |
|-------|------|-------------|
| `id` | stringa | ID dello stream (es. `"MPD"`, `"Spotify"`) |
| `status` | stringa | `"playing"`, `"idle"` o `"unknown"` |
| `uri` | oggetto | URI sorgente e parametri |
| `properties` | oggetto | Metadati (nome, codec, formato campionamento) |

### Cambiare lo Stream di un Gruppo

```bash
curl -s http://<ip-del-server>:1780/jsonrpc \
  -H "Content-Type: application/json" \
  -d '{
    "id":1,
    "jsonrpc":"2.0",
    "method":"Group.SetStream",
    "params":{"id":"<GROUP_ID>","stream_id":"Spotify"}
  }'
```

### Aggiungere uno Stream a Runtime

```bash
curl -s http://<ip-del-server>:1780/jsonrpc \
  -H "Content-Type: application/json" \
  -d '{
    "id":1,
    "jsonrpc":"2.0",
    "method":"Stream.AddStream",
    "params":{"streamUri":"tcp://0.0.0.0:5000?name=NewStream&mode=server"}
  }'
```

### Rimuovere uno Stream a Runtime

```bash
curl -s http://<ip-del-server>:1780/jsonrpc \
  -H "Content-Type: application/json" \
  -d '{
    "id":1,
    "jsonrpc":"2.0",
    "method":"Stream.RemoveStream",
    "params":{"id":"NewStream"}
  }'
```

### Impostare il Volume di un Client

```bash
curl -s http://<ip-del-server>:1780/jsonrpc \
  -H "Content-Type: application/json" \
  -d '{
    "id":1,
    "jsonrpc":"2.0",
    "method":"Client.SetVolume",
    "params":{"id":"<CLIENT_ID>","volume":{"muted":false,"percent":80}}
  }'
```

### Stato Completo del Server

```bash
curl -s http://<ip-del-server>:1780/jsonrpc \
  -H "Content-Type: application/json" \
  -d '{"id":1,"jsonrpc":"2.0","method":"Server.GetStatus"}' \
  | jq '.'
```

Restituisce: tutti i gruppi, client, stream e informazioni sul server.

---

## Schema Tipi di Sorgente

Riferimento leggibile da macchina per ogni tipo di sorgente. Usare per costruire interfacce di configurazione o API di gestione.

### pipe

| Proprietà | Valore |
|-----------|--------|
| **Formato** | `pipe:///<percorso>?name=<id>[&mode=create]` |
| **Binari richiesti** | Nessuno |
| **Requisiti Docker** | Mount del volume per il percorso FIFO |
| **Formato campionamento** | Configurabile (predefinito: globale) |
| **Parametri** | `name` (obbligatorio), `mode` (create\|read), `controlscript` (opzionale) |

### tcp

| Proprietà | Valore |
|-----------|--------|
| **Formato (server)** | `tcp://<bind>:<porta>?name=<id>&mode=server` |
| **Formato (client)** | `tcp://<host>:<porta>?name=<id>&mode=client` |
| **Binari richiesti** | Nessuno |
| **Requisiti Docker** | Porta esposta (modalità server) |
| **Formato campionamento** | Configurabile (predefinito: globale) |
| **Parametri** | `name` (obbligatorio), `mode` (server\|client), `port` |

### airplay (non usato — snapMULTI usa pipe)

Il tipo sorgente `airplay://` integrato in Snapcast avvia shairport-sync come processo figlio. snapMULTI esegue shairport-sync in un container separato e usa `pipe://` per leggerne l'output.

| Proprietà | Valore |
|-----------|--------|
| **Formato** | `airplay:///<binario>?name=<id>&devicename=<nome>[&port=5000]` |
| **Binari richiesti** | `shairport-sync` (nello stesso container) |
| **Requisiti Docker** | Rete host + socket D-Bus + Avahi |
| **Formato campionamento** | 44100:16:2 (fisso) |
| **Parametri** | `name`, `devicename`, `port` (5000\|7000), `password` |

### librespot (non usato — snapMULTI usa pipe)

Il tipo sorgente `librespot://` integrato in Snapcast avvia librespot come processo figlio. snapMULTI esegue librespot in un container separato e usa `pipe://` per leggerne l'output.

| Proprietà | Valore |
|-----------|--------|
| **Formato** | `librespot:///<binario>?name=<id>&devicename=<nome>[&bitrate=320]` |
| **Binari richiesti** | `librespot` (nello stesso container) |
| **Requisiti Docker** | Accesso rete per API Spotify |
| **Formato campionamento** | 44100:16:2 (fisso) |
| **Parametri** | `name`, `devicename`, `bitrate` (96\|160\|320), `volume`, `normalize`, `username`, `password`, `cache`, `killall` |

### alsa

| Proprietà | Valore |
|-----------|--------|
| **Formato** | `alsa:///?name=<id>&device=<dispositivo-alsa>` |
| **Binari richiesti** | Nessuno (usa libreria ALSA) |
| **Requisiti Docker** | `devices: [/dev/snd:/dev/snd]` |
| **Formato campionamento** | Configurabile (predefinito: globale) |
| **Parametri** | `name`, `device` (es. hw:0,0), `idle_threshold`, `silence_threshold_percent`, `send_silence` |

### meta

| Proprietà | Valore |
|-----------|--------|
| **Formato** | `meta:///<sorgente1>/<sorgente2>/...?name=<id>` |
| **Binari richiesti** | Nessuno |
| **Requisiti Docker** | Nessuno |
| **Formato campionamento** | Corrisponde alle sorgenti di input |
| **Parametri** | `name`, elenco sorgenti (per stream ID, separati da `/`, sinistra=priorità più alta) |

### file

| Proprietà | Valore |
|-----------|--------|
| **Formato** | `file:///<percorso>?name=<id>` |
| **Binari richiesti** | Nessuno |
| **Requisiti Docker** | Mount del volume per il percorso del file |
| **Formato campionamento** | Deve corrispondere al sampleformat globale |
| **Parametri** | `name`, percorso del file |

### Parametri Globali (tutti i tipi di sorgente)

| Parametro | Predefinito | Descrizione |
|-----------|-------------|-------------|
| `codec` | `flac` | Codifica: flac, ogg, opus, pcm |
| `sampleformat` | (globale) | Formato: `<frequenza>:<bit>:<canali>` |
| `chunk_ms` | (auto) | Dimensione chunk di lettura in ms |
| `controlscript` | — | Percorso allo script di metadati/controllo |
