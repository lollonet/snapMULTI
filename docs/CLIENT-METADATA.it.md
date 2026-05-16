# Guida all'integrazione metadata per i client

> **Per la motivazione architetturale** (perché la pipeline metadata è centralizzata lato server, trade-off, catena di lookup della cover-art) vedi [`docs/adr/ADR-004.metadata-architecture.md`](adr/ADR-004.metadata-architecture.md). Questo file è il contratto operativo di integrazione; l'ADR è il record di decisione congelato.

Come scrivere un client (UI, app mobile, kiosk display, controller secondario)
che consuma correttamente la pipeline metadata di snapMULTI. Inserire questo
file nel contesto dell'agente AI o del contributor umano che sta lavorando
sul client.

Stai scrivendo un client per snapMULTI, un appliance multiroom audio basato
su Snapcast. Il tuo compito è presentare "now playing" + cover art + controlli
di trasporto.

snapMULTI espone due servizi cooperanti sull'host server:

```
Snapserver       http://<SERVER>:1780/jsonrpc  stato/controllo Snapcast autoritativo
Metadata-service ws://<SERVER>:8082            push metadata live (snapshot completi, non delta)
                 http://<SERVER>:8083          snapshot metadata + bytes artwork
```

`<SERVER>` è l'hostname/IP/FQDN che l'utente ti ha fornito, oppure l'host
risolto da `_snapcast._tcp.local`. Mai hardcodare un IP. Mai assumere che
`.local` funzioni.

## Protocollo richiesto

1. All'avvio, apri:

   ```
   ws://<SERVER>:8082
   ```

   Poi sottoscrivi usando UNA di queste forme.

   Segui un client/stanza Snapcast (include volume/muted):

   ```json
   {"subscribe":"<snapcast-client-id-o-hostname>"}
   ```

   Segui direttamente uno stream (senza volume/muted):

   ```json
   {"subscribe_stream":"Tidal"}
   ```

   Esempi di stream validi: `"MPD"`, `"Spotify"`, `"AirPlay"`, `"Tidal"`. Per
   enumerare gli stream effettivamente configurati su questo server, chiama
   `Server.GetStatus` su Snapserver e leggi `streams[].id`.

2. Seed dello stato iniziale. La strategia di seed dipende dalla forma di
   sottoscrizione usata al passo 1.

   **UI legata a uno stream** (hai inviato `{"subscribe_stream":"Tidal"}`):
   fai seed via HTTP sullo stesso stream. È affidabile perché il query
   parameter ancora la risposta allo stream che ti interessa.

   ```
   GET http://<SERVER>:8083/metadata.json?stream=Tidal
   ```

   **UI legata a un client/stanza** (hai inviato `{"subscribe":"<client-id>"}`):
   il WS È la fonte di verità — segue lo stream attualmente assegnato alla
   stanza E lo mantiene corretto quando un operatore riassegna la stanza. Un
   fetch HTTP qui è best-effort:

   ```
   GET http://<SERVER>:8083/metadata.json       # senza ?stream
   ```

   Senza `?stream=...` il servizio restituisce il primo stream in
   riproduzione, oppure il primo stream noto — che NON è necessariamente
   quello assegnato al tuo client. Per le sottoscrizioni client-bound,
   preferisci non renderizzare nulla per i primi ~200 ms (oppure mostra un
   breve "connessione…") finché non arriva il primo messaggio WS, invece di
   rischiare un flash dei metadata della stanza sbagliata.

3. A ogni messaggio metadata WebSocket, trattalo come uno snapshot completo
   per quella sottoscrizione, non come un delta parziale. Sostituisci il tuo
   stato locale now-playing con l'oggetto ricevuto.

   Caso speciale: i messaggi con `"type":"server_info"` sono messaggi di
   stato server, non metadata di traccia. Gestiscili separatamente.

4. In caso di disconnessione WebSocket, riconnetti con backoff esponenziale
   (parti da 1 s, cap a 30 s). Dopo la riconnessione, ri-sottoscrivi e
   ripeti la richiesta HTTP di seed.

## Forma dei metadata

Esempio:

```json
{
  "playing": true,
  "stream_id": "Tidal",
  "source": "Tidal",
  "title": "Malibu",
  "artist": "Hole",
  "album": "Celebrity Skin",
  "artwork": "http://snapvideo:8083/artwork/artwork_<md5>.jpg",
  "artwork_source": "musicbrainz",
  "artist_image": "http://snapvideo:8083/artwork/artwork_<md5>.jpg",
  "codec": "FLAC",
  "sample_rate": 44100,
  "bit_depth": 16,
  "elapsed": 15,
  "duration": 230,
  "original_date": "1998-09-02",
  "genre": "rock",
  "volume": 72,
  "muted": false
}
```

`volume` e `muted` sono presenti solo quando sottoscrivi con
`{"subscribe":...}`, perché sono specifici del client/stanza. Non sono
presenti quando usi `{"subscribe_stream":...}`.

Le URL `artwork` / `artist_image` incorporano l'hostname che il
metadata-service vede di se stesso. Se il client vive su un segmento di rete
diverso e quell'hostname non risolve da lì, riscrivi la parte host dell'URL
con il `<SERVER>` a cui sei connesso. Non modificare il path.

## Campi mancanti

I campi possono essere mancanti, vuoti o null.

- `artwork` — il lookup dell'artwork può essere ancora in corso.
- `artist_image` — immagine di fallback opzionale.
- `elapsed` / `duration` — non tutti gli stream espongono una timeline.
- `date`, `original_date`, `genre`, `artwork_source` — solo informativi.

Se `playing: false`, mantieni i metadata ultimi noti visibili se utile, ma
mostra lo stato di trasporto/playback come idle.

## Regole artwork

Usa l'URL `artwork` esattamente come fornito. Non costruire URL artwork da
artist/title/album.

Le URL artwork sono basate su hash:

```
/artwork/artwork_<md5>.jpg
```

Stessa URL significa stessi bytes. Se l'artwork cambia, cambia anche la URL.

Ordine di fallback:

```
artwork -> artist_image -> placeholder bundled
```

Su 404 per un artwork, trattalo come transiente: riprova una volta dopo
500 ms, poi cadi in fallback.

## Controllo trasporto

Per un nuovo client, usa Snapserver come API di controllo autoritativa:

```
POST http://<SERVER>:1780/jsonrpc
```

Usa `Server.GetStatus` per ispezionare gruppi, stream, client e proprietà
degli stream.

Prima di mostrare i pulsanti play/pause/next, controlla le proprietà dello
stream:

```
properties.canControl
properties.canPlay
properties.canPause
properties.canGoNext
properties.canGoPrevious
properties.canSeek
```

Molti stream sono controllati dalla loro app nativa e possono riportare
`canControl: false` o singole capability come false.

Il volume è specifico del client. Usa lo stato client/group Snapcast da
`Server.GetStatus` e i metodi Snapcast JSON-RPC per i cambi di volume.

Il metadata-service ha anche un supporto di controllo limitato e legacy via
WebSocket per i client sottoscritti, ma i nuovi client dovrebbero preferire
Snapserver JSON-RPC per un comportamento di controllo esplicito.

### Forma della risposta Server.GetStatus (subset)

```json
{
  "result": {
    "server": {
      "groups": [
        {
          "id": "<uuid>",
          "name": "",
          "muted": false,
          "stream_id": "Tidal",
          "clients": [
            {
              "id": "snapclient-<host>",
              "connected": true,
              "host": { "ip": "...", "mac": "...", "name": "<host>", "os": "..." },
              "config": { "volume": { "muted": false, "percent": 100 }, "latency": 0 }
            }
          ]
        }
      ],
      "streams": [
        {
          "id": "Tidal",
          "status": "playing",
          "properties": {
            "playbackStatus": "playing",
            "canControl": false, "canPlay": false, "canPause": false,
            "canGoNext": false, "canGoPrevious": false, "canSeek": false,
            "metadata": { "title": "...", "artist": ["..."], "album": "...", "duration": 230.0 }
          }
        }
      ]
    }
  }
}
```

Nota: `properties.metadata.artist` è un array JSON, non una stringa.
L'endpoint `/metadata.json` del metadata-service la appiattisce in stringa —
non dare per scontato che siano la stessa cosa.

### Metodi JSON-RPC che userai

```
Server.GetStatus                            snapshot completo
Stream.Control      { id, command }         command in { play, pause, playPause, next, previous, stop, seek }
Stream.SetProperty  { id, property, value } tipicamente `shuffle`, `loopStatus`, `volume`
Group.SetStream     { id, stream_id }       sposta una stanza su una sorgente diversa
Group.SetMute       { id, mute }            muta un'intera stanza
Group.SetClients    { id, clients: [...] }  riassegna client a un gruppo
Client.SetVolume    { id, volume }          volume = { percent: 0..100, muted: bool }
Client.SetLatency   { id, latency }
Client.SetName      { id, name }
```

Tutti accettano una busta JSON-RPC:
`{"jsonrpc":"2.0","id":<n>,"method":"...","params":{...}}`.

### Sequenza client end-to-end (pseudocodice)

```
server      = user_input  oppure  mdns_resolve("_snapcast._tcp.local")
status      = http_post("http://" + server + ":1780/jsonrpc",
                        { method: "Server.GetStatus", id: 1 })

stream_id   = pick_stream(status)        // es. lo stream_id del gruppo, oppure scelta utente
seed        = http_get("http://" + server + ":8083/metadata.json?stream=" + stream_id)
render(seed)

ws = ws_open("ws://" + server + ":8082")
ws.send({ subscribe_stream: stream_id })  // oppure { subscribe: client_id }

on ws.message(msg):
    if msg.type == "server_info":  update_server_status(msg); continue
    render(msg)                    // snapshot completo, non delta
    if msg.artwork != last_artwork:
        prefetch(msg.artwork)      // opzionale, evita un flash al renderer
        last_artwork = msg.artwork

on ws.close():
    backoff_sleep()
    goto reconnect (ri-sottoscrivi + ri-seed)
```

## Cosa NON fare

- Non fare polling di `/metadata.json` su timer per aggiornamenti live.
- Non riscaricare la cover art a ogni messaggio WebSocket.
- Non assumere che l'artwork sia pronto nello stesso istante in cui
  title/artist cambiano.
- Non assumere che la risoluzione `.local` esista.
- Non fare scraping diretto di MPD, Spotify, Tidal, AirPlay o degli interni
  di Snapserver per i dati now-playing.
- Non trattare i messaggi `server_info` come metadata di traccia.

## Gestione errori

- Chiusura WS: riconnetti con backoff e ri-sottoscrivi.
- `/metadata.json` 5xx: mantieni lo stato ultimo noto e riprova al prossimo
  push/riconnessione.
- Artwork 404: riprova una volta dopo 500 ms, poi fallback.
- Stream/client sconosciuto: mostra stato disconnesso/idle e continua a
  ritentare.

## Discovery

Il server pubblica `_snapcast._tcp` su mDNS. Su una piattaforma con supporto
mDNS, usalo per localizzare `<SERVER>`. Su piattaforme senza (alcune
versioni Android, alcune distribuzioni Linux senza `avahi-daemon`, certe
Wi-Fi aziendali) l'utente deve inserire manualmente l'hostname o l'IP del
server.
