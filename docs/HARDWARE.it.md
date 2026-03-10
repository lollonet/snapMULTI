🇬🇧 [English](HARDWARE.md) | 🇮🇹 **Italiano**

# Guida Hardware e Rete

Requisiti hardware, configurazioni consigliate e considerazioni sulla rete per snapMULTI.

## Requisiti del Server

Il server esegue tutti i servizi audio: Snapcast, MPD, shairport-sync (AirPlay) e go-librespot (Spotify Connect) all'interno di container Docker.

### Hardware Minimo del Server

| Componente | Minimo | Consigliato |
|------------|--------|-------------|
| CPU | 2 core, ARMv7+ o x86_64 | 4 core |
| RAM | 1 GB | 2 GB+ |
| Storage | 16 GB (SO + Docker) | 32 GB+ |
| Rete | Ethernet 100 Mbps | Gigabit Ethernet |
| Architettura | `linux/amd64` o `linux/arm64` | Entrambe |

### Cosa Determina i Requisiti del Server

- **shairport-sync** è il componente più esigente — richiede almeno una CPU di livello Raspberry Pi 2 o Pi Zero 2 W ([fonte](https://github.com/mikebrady/shairport-sync))
- **librespot** usa ~20% della CPU su un Pi 3 con backend ALSA ([fonte](https://github.com/librespot-org/librespot/issues/343))
- **MPD** usa 2–3 MB di RAM a riposo; la decodifica FLAC è leggera, ma il ricampionamento è intensivo per la CPU ([fonte](https://mpd.readthedocs.io/en/stable/user.html))
- **Snapserver** usa <2% della CPU su un Pi 4 a riposo ([fonte](https://github.com/badaix/snapcast/issues/1336))
- L'uso della CPU scala linearmente con il numero di client connessi

### Esempi di Server

| Hardware | Idoneità | Note |
|----------|----------|------|
| Raspberry Pi 4 (4 GB) | Buono | Gestisce tutte e 4 le sorgenti + 10 client comodamente |
| Raspberry Pi 3B+ | Adeguato | Funziona ma potrebbe avere difficoltà con tutte le sorgenti attive contemporaneamente |
| Intel NUC / mini PC | Eccellente | Sovradimensionato ma ideale per installazioni grandi |
| Vecchio laptop / desktop | Eccellente | Qualsiasi macchina x86_64 con 2+ GB di RAM funziona bene |
| NAS con Docker | Buono | Se supporta Docker e ha 2+ core |

> **Nota:** Raspberry Pi 2 e Pi Zero 2 W possono eseguire il server ma sono al limite. Un Pi 3B+ o superiore è consigliato per tutte e quattro le sorgenti audio.

> **Principianti:** Se è la tua prima volta, usa un Raspberry Pi 4 (4GB) con il [setup zero-touch SD](../README.it.md#principianti-plug-and-play-raspberry-pi). Gestisce tutto automaticamente — nessun terminale richiesto.

## Requisiti dei Client

I client Snapcast sono leggeri — ricevono audio e lo riproducono attraverso gli altoparlanti.

### Hardware Minimo del Client

| Componente | Minimo | Note |
|------------|--------|------|
| CPU | Qualsiasi ARMv6+ o x86_64 | Anche il Pi Zero W (originale) funziona |
| RAM | 256 MB | Snapclient usa pochissima memoria |
| Storage | 8 GB microSD | 16 GB consigliati |
| Uscita audio | 3.5mm, HDMI, DAC USB o HAT I2S | Vedi sezione uscita audio |

### Dispositivi Client

| Dispositivo | Prezzo Indicativo | Uscita Audio | Consumo | Note |
|-------------|-------------------|--------------|---------|------|
| **Raspberry Pi Zero 2 W** | ~15€ | DAC USB o HAT I2S | 0,75 W | Miglior opzione economica, WiFi integrato |
| **Raspberry Pi Zero W** (v1) | ~10€ | DAC USB o HAT I2S | 0,5 W | Funziona ma più lento; nessun jack audio integrato |
| **Raspberry Pi 3B/3B+** | ~35€ | Jack 3.5mm, HDMI, DAC USB | 2,5 W | Uscita audio integrata, WiFi + Ethernet |
| **Raspberry Pi 4** | ~35–55€ | Jack 3.5mm, HDMI, DAC USB | 3–6 W | Più potenza del necessario per un client |
| **Raspberry Pi 5** | ~60–80€ | HDMI, DAC USB | 4–8 W | Sovradimensionato per uso client |
| **Vecchio telefono Android** | Gratis | Altoparlante integrato | Batteria | Tramite app Snapcast Android |
| **Qualsiasi PC Linux** | Varia | Audio integrato | Varia | `apt install snapclient` |

### Qualità dell'Uscita Audio

| Metodo di Uscita | Qualità | Costo | Note |
|------------------|---------|-------|------|
| **DAC HAT I2S** (HiFiBerry, IQAudio) | Eccellente | 20–50€ | Migliore qualità audio, si collega direttamente al GPIO del Pi |
| **DAC USB** | Molto buona | 10–100€ | Ampia gamma di opzioni, funziona con Pi Zero |
| **HDMI** | Buona | Gratis | Usa il tuo TV/ricevitore come altoparlante |
| **Jack 3.5mm** (Pi 3/4) | Adeguata | Gratis | Fruscio percepibile su alcuni modelli; va bene per ascolto casual |

> **Suggerimento:** Per la migliore esperienza audio su Raspberry Pi, usa un HiFiBerry DAC+ Zero (~20€) o qualsiasi DAC USB. Il jack 3.5mm integrato nel Pi 3/4 è adeguato ma non di qualità audiofila.

### Docker vs Installazione Nativa (Client)

Per i dispositivi **client**, l'installazione nativa è consigliata rispetto a Docker:

- Minor overhead sui dispositivi con risorse limitate
- Accesso diretto all'hardware audio
- Configurazione più semplice

```bash
# Installazione nativa (consigliata per i client)
sudo apt install snapclient

# Docker (solo se preferisci la containerizzazione)
docker run -d --name snapclient --network host --device /dev/snd ghcr.io/badaix/snapcast:latest snapclient
```

Docker è consigliato per il **server** dove si beneficia della gestione container e della riproducibilità.

## Requisiti di Rete

### Banda

Formato audio: 44100 Hz, 16-bit, stereo (codec FLAC predefinito).

| Metrica | Valore |
|---------|--------|
| Bitrate PCM grezzo | 1,536 Mbps (192 KB/s) |
| FLAC compresso (tipico) | ~0,9 Mbps (~115 KB/s) |
| Overhead protocollo per client | ~14 kbps (trascurabile) |

**Banda totale per numero di client:**

| Client | Banda FLAC | Rete Necessaria |
|--------|------------|-----------------|
| 5 | ~4,5 Mbps | Qualsiasi rete moderna |
| 10 | ~9 Mbps | Qualsiasi rete moderna |
| 20 | ~18 Mbps | Ethernet 100 Mbps o WiFi 5 GHz |
| 50 | ~45 Mbps | Gigabit Ethernet consigliato |

> **La banda NON è un collo di bottiglia** per le tipiche configurazioni domestiche. Anche il WiFi 2,4 GHz (throughput pratico ~20–50 Mbps) gestisce 10+ client.

### WiFi vs Ethernet

| Fattore | WiFi (2,4 GHz) | WiFi (5 GHz) | Ethernet |
|---------|-----------------|---------------|----------|
| Banda | 20–50 Mbps pratica | 150–400 Mbps | 100–1000 Mbps |
| Latenza | 2–10 ms | 1–5 ms | <1 ms |
| Affidabilità | Variabile (interferenze) | Buona | Eccellente |
| Capacità client | 10–15 client | 20+ client | 50+ client |
| Ideale per | Client in stanze senza Ethernet | Client che necessitano affidabilità | Server, client critici |

**Raccomandazioni:**
- **Server**: Ethernet quando possibile
- **Client**: il WiFi funziona bene; usa 5 GHz se disponibile
- **Configurazioni sensibili alla latenza**: Ethernet riduce il jitter di sincronizzazione

### Sincronizzazione

- Snapcast raggiunge una **sincronizzazione sub-millisecondo** tra i client
- Buffer predefinito: 2400 ms (configurabile in `snapserver.conf`)
- Buffer più grande = più stabile su reti scadenti, ma aggiunge ritardo alla riproduzione
- Il jitter WiFi è compensato automaticamente — i client regolano la velocità di riproduzione

### Configurazione di Rete

**Porte necessarie:**

| Porta | Protocollo | Direzione | Scopo |
|-------|------------|-----------|-------|
| 1704 | TCP | Server → Client | Streaming audio |
| 1705 | TCP | Bidirezionale | Controllo JSON-RPC |
| 1780 | HTTP | Bidirezionale | Interfaccia Snapweb + API HTTP |
| 4953 | TCP | In entrata | Ingresso audio TCP (streaming ffmpeg/Android) |
| 6600 | TCP | Bidirezionale | Protocollo MPD (controllo client) |
| 8000 | HTTP | Bidirezionale | Stream audio HTTP MPD |
| 8082 | WebSocket | Server → Client | Servizio metadata (push info tracce) |
| 8083 | HTTP | Server → Client | Servizio metadata (copertine, health) |
| 8180 | HTTP | Bidirezionale | Interfaccia web myMPD |
| 5353 | UDP | Multicast | Autodiscovery mDNS |

**Requisiti del router:**
- Client e server devono essere sulla stessa sottorete (o mDNS deve essere inoltrato)
- Supporto IGMP snooping consigliato per reti più grandi
- Nessuna funzionalità speciale del router necessaria per l'uso domestico tipico

### Regole Firewall

```bash
# Snapcast core
sudo ufw allow 1704/tcp   # Streaming audio
sudo ufw allow 1705/tcp   # Controllo JSON-RPC
sudo ufw allow 1780/tcp   # API HTTP + Snapweb UI

# Sorgenti audio — necessarie per trasmettere da telefono/app
sudo ufw allow 4953/tcp   # Ingresso audio TCP (streaming ffmpeg/Android)
sudo ufw allow 5000/tcp   # AirPlay (shairport-sync RTSP)
sudo ufw allow 5858/tcp   # Copertine AirPlay (meta_shairport.py)
sudo ufw allow 2019/tcp   # Tidal Connect discovery (solo ARM)
# Spotify Connect usa una porta TCP casuale per il discovery zeroconf;
# se ufw è abilitato, consentire il range effimero o usare connection tracking:
# sudo ufw allow proto tcp from 192.168.0.0/16 to any port 30000:65535

# Libreria musicale
sudo ufw allow 6600/tcp   # Protocollo MPD
sudo ufw allow 8000/tcp   # Stream HTTP MPD
sudo ufw allow 8180/tcp   # Interfaccia web myMPD

# Metadata
sudo ufw allow 8082/tcp   # Servizio metadata (WebSocket)
sudo ufw allow 8083/tcp   # Servizio metadata (HTTP/copertine)

# Discovery
sudo ufw allow 5353/udp   # mDNS (Avahi/Bonjour)
```

## Storage

### Immagini Docker

| Immagine | Dimensione |
|----------|------------|
| `lollonet/snapmulti-server:latest` | ~80–120 MB |
| `lollonet/snapmulti-airplay:latest` | ~30–50 MB |
| `ghcr.io/devgianlu/go-librespot:v0.7.0` | ~30–50 MB |
| `lollonet/snapmulti-mpd:latest` | ~50–80 MB |
| `lollonet/snapmulti-metadata:latest` | ~60–80 MB |
| `lollonet/snapmulti-tidal:latest` | ~200–300 MB |

### Libreria Musicale

| Formato | Dimensione Album Tipica | 1000 Album |
|---------|-------------------------|------------|
| FLAC (lossless) | 300–500 MB | 300–500 GB |
| MP3 320 kbps | 80–120 MB | 80–120 GB |
| MP3 192 kbps | 50–80 MB | 50–80 GB |

**Consigli per lo storage:**
- Librerie FLAC: disco USB esterno o mount NAS
- Librerie MP3: microSD 256 GB+ o disco interno
- File database MPD: <100 MB indipendentemente dalla dimensione della libreria

## Configurazioni Consigliate

### Configurazione Economica (~50€)

| Ruolo | Hardware | Costo |
|-------|----------|-------|
| Server | Raspberry Pi 3B+ (usato) | ~25€ |
| Client (1 stanza) | Raspberry Pi Zero 2 W + DAC USB | ~25€ |

### Configurazione Media (~150€)

| Ruolo | Hardware | Costo |
|-------|----------|-------|
| Server | Raspberry Pi 4 (4 GB) | ~55€ |
| Client (3 stanze) | 3× Raspberry Pi Zero 2 W + HiFiBerry DAC+ Zero | ~105€ |

### Configurazione Entusiasta (~300€+)

| Ruolo | Hardware | Costo |
|-------|----------|-------|
| Server | Intel NUC o mini PC | ~150€+ |
| Client (5 stanze) | Mix di Pi Zero 2 W con HAT HiFiBerry | ~175€ |
| Rete | Switch gestito + Ethernet al server | ~30€ |

## Limitazioni Note

| Limitazione | Dettagli |
|-------------|----------|
| **Pi Zero W (v1) come server** | Troppo lento per shairport-sync + librespot contemporaneamente |
| **librespot su ARMv6** | Non ufficialmente supportato su Pi Zero v1 / Pi 1 ([dettagli](https://github.com/librespot-org/librespot/pull/1457)). Cross-compilazione possibile ma non supportata |
| **Audio 3.5mm su Pi** | Rumore di fondo percepibile; usa DAC HAT o DAC USB per qualità |
| **WiFi 2,4 GHz** | Funziona ma soggetto a interferenze; 5 GHz preferito per >10 client |
| **Docker su Pi OS 32-bit** | In via di deprecazione; usa Pi OS 64-bit per deployment Docker |
