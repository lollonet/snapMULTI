🇬🇧 [English](HARDWARE.md) | 🇮🇹 **Italiano**

# Guida Hardware e Rete

Requisiti hardware, configurazioni consigliate e considerazioni sulla rete per snapMULTI.

## Requisiti del Server

Il server esegue tutti i servizi audio: Snapcast, MPD, shairport-sync (AirPlay) e go-librespot (Spotify Connect) all'interno di container Docker.

### Hardware Minimo del Server

| Componente | Minimo | Consigliato |
|------------|--------|-------------|
| CPU | 4 core, ARMv8 o x86_64 (Pi 3B+) | Pi 4 o x86_64 (single-core più veloce) |
| RAM | 2 GB | 4 GB+ |
| Storage | 32 GB microSD | 32 GB+ |
| Rete | Ethernet 100 Mbps o WiFi 5 GHz | Gigabit Ethernet |
| Architettura | `linux/amd64` o `linux/arm64` | Entrambe |

> **Perché 2 GB consigliati?** Tutti i container server combinati usano ~309 MiB di RAM a riposo. Aggiungendo l'overhead del SO (~200 MB) e il demone Docker, un Pi 3 da 1 GB funziona ma ha margine limitato per i picchi (scansioni libreria MPD, streaming simultaneo). Un Pi 4 2 GB offre un margine confortevole. Vedi [profili risorse](#profili-risorse) e [dati misurati](#build-di-riferimento-e-misurazioni-prestazioni) sotto.

### Cosa Determina i Requisiti del Server

- **shairport-sync** è leggero in termini di CPU: misurato a **0,0% CPU, 18 MiB RAM** su Pi 4 (streaming idle) — richiede un Pi 2 o superiore ([fonte](https://github.com/mikebrady/shairport-sync))
- **librespot** (Spotify Connect): misurato a **0,0% CPU, 22 MiB RAM** a riposo; può raggiungere ~180 MiB durante lo streaming attivo su Spotify ([fonte](https://github.com/librespot-org/librespot/issues/343))
- **MPD**: misurato a **6,4% CPU, 90 MiB RAM** (libreria di 6.418 brani) — più pesante al primo avvio con libreria montata via NFS (scansione completa)
- **Snapserver** con 2 client attivi: misurato a **6,0% CPU, 87 MiB RAM** su Pi 4; scala linearmente per client ([fonte](https://github.com/badaix/snapcast/issues/1336))
- **metadata-service**: misurato a **0,6% CPU, 52 MiB RAM** (dopo ottimizzazione PR #95)

### Esempi di Server

| Hardware | Idoneità | Note |
|----------|----------|------|
| Raspberry Pi 4 (4 GB+) | ✅ Consigliato | Gestisce tutte le sorgenti + 10 client + display comodamente |
| Raspberry Pi 4 (2 GB) | ✅ Buono | Solo server o server + client headless; stretto con display |
| Raspberry Pi 3B+ | ⚠️ Stretto | 1 GB RAM — funziona solo server ma senza margine per i picchi |
| Raspberry Pi Zero 2 W | ❌ Non supportato | 512 MB RAM — non può contenere i container server |
| Intel NUC / mini PC | ✅ Eccellente | Ideale per grandi installazioni o librerie musicali |
| Vecchio laptop / desktop | ✅ Eccellente | Qualsiasi macchina x86_64 con 2+ GB di RAM funziona bene |
| NAS con Docker | ✅ Buono | Se supporta Docker e ha 2+ core e 2+ GB di RAM |

> **Nota:** Il Pi 3B+ ha solo **1 GB di RAM**. Solo server funziona (misurato ~309 MiB di utilizzo effettivo) ma lascia margine limitato. Non consigliato per la modalità "entrambi" (server + client con display). Il Pi 2 è troppo lento per AirPlay + Spotify simultanei; evitare per uso server.

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

| Dispositivo | Prezzo (IT) | Uscita Audio | Consumo | Note |
|-------------|-------------|--------------|---------|------|
| **Raspberry Pi Zero 2 W** | ~€20 | DAC USB o HAT I2S | 0,75 W | Miglior opzione economica; solo WiFi 2,4 GHz; solo audio (senza display) |
| **Raspberry Pi Zero W** (v1) | ~€15 | DAC USB o HAT I2S | 0,5 W | Funziona ma lento; nessun GPIO audio; solo WiFi 2,4 GHz |
| **Raspberry Pi 3B/3B+** | ~€35 | Jack 3.5mm, HDMI, DAC USB | 2,5 W | Uscita audio integrata, WiFi 5 GHz + Ethernet |
| **Raspberry Pi 4** (2 GB+) | ~€45–60 | Jack 3.5mm, HDMI, DAC USB | 3–6 W | Necessario per client con display copertine (fb-display) |
| **Raspberry Pi 5** | ~€65–85 | HDMI, DAC USB | 4–8 W | Sovradimensionato per uso client |
| **Vecchio telefono Android** | Gratis | Altoparlante integrato | Batteria | Tramite [app Snapcast Android](https://github.com/badaix/snapdroid) |
| **Qualsiasi PC Linux** | Varia | Audio integrato | Varia | `apt install snapclient` |

### Note Pi Zero 2 W

Il Pi Zero 2 W è l'opzione client più economica ma ha requisiti specifici:

- **OS 64-bit obbligatorio** — Imager propone 32-bit come predefinito per questo modello. Seleziona esplicitamente "Raspberry Pi OS Lite (64-bit)"
- **Solo WiFi 2,4 GHz** — niente 5 GHz. Usa il tuo SSID 2,4 GHz quando configuri il WiFi in Imager
- **512 MB RAM** — solo audio headless (senza display). Non può eseguire fb-display o server
- **Compatibilità HAT I2S** — funziona con HAT basati su PCM5122 (HiFiBerry DAC+, InnoMaker Mini). L'impostazione USB `otg_mode=1` di Imager interferisce con I2S — `prepare-sd.sh` e `setup.sh` lo correggono automaticamente
- **Modalità gadget USB** — per debug senza WiFi, collegare la porta USB dati al computer. Richiede `dtoverlay=dwc2` sotto `[all]` in config.txt (non sotto `[cm5]`)

### Qualità dell'Uscita Audio

| Metodo di Uscita | Qualità | Costo | Note |
|------------------|---------|-------|------|
| **DAC HAT I2S** (HiFiBerry DAC+, DAC2 Pro) | Eccellente | €20–45 | Migliore qualità analogica, uscita RCA, si collega direttamente al GPIO del Pi |
| **HAT S/PDIF I2S** (HiFiBerry Digi+) | Eccellente | €25–35 | Uscita digitale ottica/coassiale verso ricevitore AV o DAC esterno; nessuna conversione analogica sul Pi |
| **DAC USB** | Molto buona | €10–80 | Ampia gamma di opzioni; funziona con Pi Zero (nessun header GPIO necessario) |
| **HDMI** | Buona | Gratis | Usa il tuo TV/ricevitore AV come dispositivo di uscita |
| **Jack 3.5mm** (Pi 3/4) | Adeguata | Gratis | Rumore di fondo percepibile su alcuni modelli; va bene per ascolto casual |

> **Suggerimento:** Usa un HAT I2S per la migliore qualità. [HiFiBerry DAC+ Zero](https://www.hifiberry.com/shop/boards/dacplus-zero/) (~€20) per i nodi client, [HiFiBerry DAC2 Pro](https://www.hifiberry.com/shop/boards/dac2-pro/) (~€45) o [HiFiBerry Digi+](https://www.hifiberry.com/shop/boards/hifiberry-digi/) (~€30) per nodi collegati a ricevitori AV.

### Metodo di Installazione Client

snapMULTI usa **Docker Compose per il deploy dei client** tramite la directory [client](../client/). Questo fornisce uno stack autocontenuto che include snapclient, display copertine e visualizzatore audio — tutto gestito insieme.

Lo stack Docker client esegue tre container:
- `lollonet/snapclient-pi:latest` — Player audio Snapcast
- `lollonet/snapclient-pi-fb-display:latest` — Display copertine (framebuffer)
- `lollonet/snapclient-pi-visualizer:latest` — Visualizzatore audio

Vedi [README.md](../README.md) per la procedura di installazione completa (percorso SD card o manuale).

Per configurazioni minimali o manuali senza la directory client completa, snapclient può essere installato nativamente:

```bash
sudo apt install snapclient
```

Docker è consigliato per il **server** e per i nodi client completi con display; l'installazione nativa via `apt` è adeguata per un client solo audio su hardware molto limitato.

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
| 5000 | TCP | In entrata | AirPlay (shairport-sync RTSP) |
| 5858 | TCP | In entrata | Copertine AirPlay (meta_shairport.py) |
| 2019 | TCP | In entrata | Tidal Connect discovery (solo ARM) |
| 6600 | TCP | Bidirezionale | Protocollo MPD (controllo client) |
| 8000 | HTTP | Server → Client | Stream audio HTTP MPD |
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

### Network QoS (Quality of Service)

Per prestazioni ottimali dello streaming audio, specialmente su reti congestionate o con trasferimenti di file di grandi dimensioni, `deploy.sh` configura il QoS di rete:

**CAKE + DSCP EF**: I pacchetti audio Snapcast sono marcati con DSCP EF (Expedited Forwarding) per la gestione prioritaria. Il qdisc CAKE (Common Applications Kept Enhanced) fornisce code a bassa latenza e gestione automatica della banda.

```bash
# Applicato automaticamente da deploy.sh su sistemi compatibili
tc qdisc add dev eth0 root cake bandwidth 100mbit
# Snapcast usa marcatura DSCP EF per la priorità audio real-time
```

Questo garantisce uno streaming audio consistente anche durante la congestione di rete causata da trasferimenti di file, aggiornamenti o altro traffico di grandi dimensioni.

## Storage

### Immagini Docker

**Immagini server:**

| Immagine | Dimensione |
|----------|------------|
| `lollonet/snapmulti-server:latest` | ~80–120 MB |
| `lollonet/snapmulti-airplay:latest` | ~30–50 MB |
| `ghcr.io/devgianlu/go-librespot:v0.7.0` | ~30–50 MB |
| `lollonet/snapmulti-mpd:latest` | ~50–80 MB |
| `lollonet/snapmulti-metadata:latest` | ~60–80 MB |
| `ghcr.io/jcorporation/mympd/mympd:latest` | ~30–50 MB |
| `lollonet/snapmulti-tidal:latest` | ~200–300 MB |

**Immagini client** (dalla directory [client](../client/)):

| Immagine | Dimensione |
|----------|------------|
| `lollonet/snapclient-pi:latest` | ~30–50 MB |
| `lollonet/snapclient-pi-fb-display:latest` | ~80–120 MB |
| `lollonet/snapclient-pi-visualizer:latest` | ~50–80 MB |

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

### Starter — 2 stanze

| Nodo | Hardware | Uscita audio |
|------|----------|-------------|
| Server + Client | Pi 4 (4 GB) + HiFiBerry DAC2 Pro | RCA analogico |
| Client (headless) | Pi Zero 2 W + HiFiBerry DAC+ Zero | RCA analogico |

> Il Pi Zero 2 W richiede di saldare un header GPIO (oppure comprare la variante WH con header pre-saldato). **Solo WiFi** — nessuna porta Ethernet, solo 2,4 GHz.

### Budget — 2 stanze (tutto disponibile su Amazon)

| Nodo | Hardware | Uscita audio |
|------|----------|-------------|
| Server + Client | Pi 4 (2 GB) + InnoMaker HiFi DAC HAT (PCM5122) | RCA + 3.5mm |
| Client (headless) | Pi 3 B+ + InnoMaker DAC Mini HAT (PCM5122) | RCA + 3.5mm |

> Il Pi 4 2 GB è sufficiente per solo server (~309 MiB RAM a riposo). Per server + client con display, il modello 4 GB è preferito.

### Entusiasta — 4+ stanze

| Nodo | Hardware | Connessione |
|------|----------|------------|
| Server | Intel NUC o mini PC (x86_64) | Ethernet |
| Client × 3+ | Pi Zero 2 W + HiFiBerry DAC+ Zero | WiFi (2,4 GHz) |

> I client Pi Zero si connettono via WiFi (nessuna porta Ethernet). Il server dovrebbe usare Ethernet per affidabilità. Uno switch gestito è utile se hai anche client cablati (Pi 3/4).

### Alternativa: S/PDIF verso Ricevitore AV

Se un nodo è collegato a un ricevitore AV via cavo ottico, usa HiFiBerry Digi+ al posto del DAC HAT. Questo sposta la conversione D/A al tuo ricevitore — qualità migliore se il tuo ricevitore ha un buon DAC.

## Combinazioni Testate

Queste combinazioni hardware sono state verificate end-to-end (firstboot → smoke test → playback audio) nelle date indicate. Il batch del 2026-04-27 è la validazione release-gate per v0.6.x: 6 device riflashati da `main`, smoke test PASS su ognuno, `hw_ptr` ALSA che avanza durante la riproduzione (audio che raggiunge davvero il DAC, non solo la FIFO).

| Hostname | Modello Pi | HAT Audio | Chip DAC | Modalità | Display | Sorgente Musica | Validato | Stato |
|---|---|---|---|---|---|---|---|---|
| snapvideo | Pi 4 B (8 GB) | HiFiBerry DAC+ | PCM5122 (analogico) | both | HDMI 800×600 (display cover art) | locale | 2026-04-27 | Funzionante |
| moniaserver | Pi 4 B (2 GB) | HiFiBerry DAC+ Standard | PCM5122 (analogico) | both | headless | USB | 2026-04-27 | Funzionante |
| snapdigi | Pi 4 B (2 GB) | HiFiBerry Digi+ | WM8804 (S/PDIF) | client | HDMI verso TV LG 50" | n/d | 2026-04-27 | Funzionante |
| piotto | Pi 4 B (2 GB) | nessuno (bcm2835 onboard) | — | client | headless | n/d | 2026-04-27 | Funzionante |
| moniaclient | Pi 3 B+ (1 GB) | InnoMaker HIFI DAC HAT | PCM5122 (analogico) | client | headless | n/d | 2026-04-27 | Funzionante |
| pizero | Pi Zero 2 W (512 MB) | InnoMaker DAC | PCM5122 (analogico) | client | headless | n/d | 2026-04-27 | Funzionante |

**Copertura raggiunta il 2026-04-27**:

- 3 famiglie di Pi: Pi Zero 2 W, Pi 3 B+, Pi 4 B (4 revisioni diverse di Pi 4: 1.1, 1.2, 1.4, 1.5)
- 2 famiglie di chip DAC: PCM5122 (analogico, 4 schede tra brand HiFiBerry e InnoMaker) e WM8804 (S/PDIF digitale)
- Più 1 device con `bcm2835` onboard (senza HAT)
- Entrambi i path mixer: hardware (`hardware:Digital` su PCM5122) e software fallback (S/PDIF + onboard)
- Entrambe le modalità di install (`--both`, `--client`) e `--server` esercitate nei round precedenti
- Varianti headless e con display HDMI
- Filesystem read-only (overlayroot + fuse-overlayfs) attivo su ogni device
- Auto-detect via I2C bus 1 per PCM5122 EEPROM-less funziona su tutti e quattro i DAC HAT

## Limitazioni Note

| Limitazione | Dettagli |
|-------------|----------|
| **Pi Zero 2 W come server** | 512 MB di RAM non possono contenere i container server (limiti 592M nel profilo minimal). Usare solo come client headless |
| **Pi Zero 2 W con display** | 512 MB di RAM troppo stretti per fb-display + visualizer (limiti 352M). Usare Pi 3+ per client con display |
| **Pi 3 1 GB — modalità entrambi con display** | Server (592M) + client display (352M) = limiti 944M su 1 GB — non supportato. Usare solo server o solo client, non entrambi |
| **Pi Zero W (v1) come server** | Troppo lento per shairport-sync + librespot contemporaneamente |
| **librespot su ARMv6** | Non ufficialmente supportato su Pi Zero v1 / Pi 1 ([dettagli](https://github.com/librespot-org/librespot/pull/1457)). Cross-compilazione possibile ma non supportata |
| **Audio 3.5mm su Pi** | Rumore di fondo percepibile; usa DAC HAT o DAC USB per qualità |
| **WiFi 2,4 GHz** | Funziona ma soggetto a interferenze; 5 GHz preferito per >10 client |
| **Docker su Pi OS 32-bit** | In via di deprecazione; usa Pi OS 64-bit per deployment Docker |

---

## Profili Risorse

`deploy.sh` (server) e `setup.sh` (client) rilevano automaticamente l'hardware e applicano uno dei tre profili: **minimal**, **standard** o **performance**. I limiti possono essere sovrascritti in `.env`.

### Selezione Profilo

| Hardware | RAM | Profilo |
|----------|-----|---------|
| Pi Zero 2 W, Pi 3 | < 2 GB | minimal |
| Pi 4 2 GB | 2–4 GB | standard |
| Pi 4 4 GB+, Pi 5, x86_64 | 4 GB+ | performance |

### Limiti Memoria Server per Profilo

| Servizio | Misurato | minimal | standard | performance |
|----------|----------|---------|----------|-------------|
| snapserver | 87 MiB | 128M | 192M | 256M |
| shairport-sync | 18 MiB | 48M | 64M | 96M |
| librespot | 22 MiB | 96M | 256M | 256M |
| mpd | 90 MiB | 128M | 256M | 384M |
| mympd | 8 MiB | 32M | 64M | 128M |
| metadata | 52 MiB | 96M | 128M | 128M |
| tidal-connect | 32 MiB | 64M | 96M | 128M |
| **Totale** | **~309 MiB** | **592M** | **1.056M** | **1.376M** |

> I valori misurati sono baseline a riposo da snapvideo (Pi 4 8 GB) con tutti i servizi attivi e 2 client collegati. L'utilizzo effettivo aumenta durante la riproduzione attiva (librespot può raggiungere ~180 MiB durante lo streaming Spotify) e le scansioni della libreria MPD (proporzionale alla dimensione della libreria — 90 MiB a riposo con 6.418 brani).

### Limiti Memoria Client per Profilo

| Servizio | Misurato | minimal | standard | performance |
|----------|----------|---------|----------|-------------|
| snapclient | 18 MiB | 64M | 64M | 96M |
| audio-visualizer | 36–51 MiB | 96M | 128M | 192M |
| fb-display | 89–114 MiB | 192M | 256M | 384M |
| **Totale** | **~168 MiB** | **352M** | **448M** | **672M** |

> La memoria di fb-display scala con la risoluzione: ~89 MiB a 1080p, ~114 MiB a 4K (3840x2160). Anche l'uso CPU scala: ~12% a 1080p, ~66% a 4K. I client headless (senza display) eseguono solo snapclient (~18 MiB, ~2% CPU).

### Matrice Compatibilità Hardware

Si assume ~200 MB di overhead SO + Docker. "Disp" = RAM rimanente dopo i limiti dei container.

**Solo server** (tutti i servizi, incluso Tidal su ARM):

| Hardware | RAM | Profilo | Limiti | % RAM | Stato |
|----------|-----|---------|--------|-------|-------|
| Pi Zero 2W | 512M | minimal | 592M | 190% | **Non supportato** |
| Pi 3 1GB | 1024M | minimal | 592M | 72% | Stretto — funziona, nessun margine per picchi |
| Pi 4 2GB | 2048M | standard | 1.056M | 57% | OK |
| Pi 4 4GB+ | 4096M | performance | 1.376M | 35% | OK |
| Pi 5 | 4–8 GB | performance | 1.376M | 17–35% | OK |

**Client con display:**

| Hardware | RAM | Profilo | Limiti | % RAM | Stato |
|----------|-----|---------|--------|-------|-------|
| Pi Zero 2W | 512M | minimal | 352M | 113% | **Non supportato** |
| Pi 3 1GB | 1024M | minimal | 352M | 43% | OK |
| Pi 4 2GB | 2048M | standard | 448M | 24% | OK |
| Pi 4 4GB+ | 4096M | performance | 672M | 17% | OK |

**Client headless** (solo snapclient — senza display):

| Hardware | RAM | Profilo | Limiti | Stato |
|----------|-----|---------|--------|-------|
| Pi Zero 2W | 512M | minimal | 64M | OK |
| Pi 3 1GB | 1024M | minimal | 64M | OK |
| Qualsiasi 2GB+ | 2GB+ | standard+ | 64–96M | OK |

**Modalità entrambi** (server + client con display sullo stesso Pi):

| Hardware | RAM | Profilo | Server | Client | Totale | % RAM | Stato |
|----------|-----|---------|--------|--------|--------|-------|-------|
| Pi Zero 2W | 512M | minimal | 592M | 352M | 944M | 303% | **Non supportato** |
| Pi 3 1GB | 1024M | minimal | 592M | 352M | 944M | 115% | **Non supportato** |
| Pi 4 2GB | 2048M | standard | 1.056M | 448M | 1.504M | 81% | Stretto — funziona, margine limitato |
| Pi 4 4GB+ | 4096M | performance | 1.376M | 672M | 2.048M | 53% | OK |

**Modalità entrambi** (server + client headless sullo stesso Pi):

| Hardware | RAM | Profilo | Server | Client | Totale | % RAM | Stato |
|----------|-----|---------|--------|--------|--------|-------|-------|
| Pi Zero 2W | 512M | minimal | 592M | 64M | 656M | 210% | **Non supportato** |
| Pi 3 1GB | 1024M | minimal | 592M | 64M | 656M | 80% | Stretto — funziona, margine limitato |
| Pi 4 2GB | 2048M | standard | 1.056M | 64M | 1.120M | 61% | OK |
| Pi 4 4GB+ | 4096M | performance | 1.376M | 96M | 1.472M | 38% | OK |

> **Importante:** Queste percentuali rappresentano i *limiti* (tetti massimi), non l'utilizzo effettivo. L'utilizzo totale misurato su tutti e 10 i servizi è ~468 MiB a riposo. I servizi raramente raggiungono i loro limiti simultaneamente — i limiti esistono per impedire ai processi fuori controllo di esaurire le risorse del sistema. Un rapporto limiti/RAM del 74% su Pi 4 2 GB è sicuro nella pratica.

---

## Build di Riferimento e Misurazioni Prestazioni

Due sistemi di produzione misurati a marzo 2026. Entrambi su WiFi 5 GHz, Pi OS 64-bit, nessun throttling.

> Le percentuali CPU sono campioni puntuali e variano con l'attività di riproduzione. I valori RAM sono più stabili. I totali sotto rappresentano un tipico stato idle con streaming e tutti i servizi attivi.

### snapvideo — Server + Client in Co-locazione

| Attributo | Valore |
|-----------|--------|
| Scheda | Raspberry Pi 4 Model B Rev 1.4 — **8 GB RAM** |
| Audio | [HiFiBerry DAC+](https://www.hifiberry.com/shop/boards/hifiberry-dacplus/) (`snd_rpi_hifiberry_dacplus`, pcm512x) — uscita analogica RCA |
| Rete | WiFi 5 GHz |
| Profilo | performance (server + client) |

**Carico container Docker** (tutti i servizi attivi, streaming idle, 2 client collegati):

| Container | CPU % | RAM usata | Limite RAM |
|-----------|-------|-----------|------------|
| snapserver | 6,0% | 87 MiB | 512 MiB |
| fb-display | 11,7% | 89 MiB | 384 MiB |
| audio-visualizer | 7,8% | 51 MiB | 384 MiB |
| librespot (Spotify) | 0,0% | 22 MiB | 256 MiB |
| mpd | 6,4% | 90 MiB | 512 MiB |
| mympd | 0,0% | 8 MiB | 256 MiB |
| metadata | 0,6% | 52 MiB | 192 MiB |
| shairport-sync (AirPlay) | 0,0% | 18 MiB | 256 MiB |
| tidal-connect | 4,7% | 32 MiB | 192 MiB |
| snapclient | 1,2% | 18 MiB | 192 MiB |
| **Totale** | **~38%** | **~468 MiB** | |

**RAM sistema:** 787 MiB usati / 7645 MiB totali (6,7 GiB disponibili)

> I servizi senza display (fb-display + audio-visualizer) ridurrebbero la CPU a ~19% e la RAM a ~327 MiB — un Pi 4 2 GB è poi utilizzabile come server.

---

### snapdigi — Solo Client (Display 4K)

| Attributo | Valore |
|-----------|--------|
| Scheda | Raspberry Pi 4 Model B Rev 1.1 — **2 GB RAM** |
| Audio | [HiFiBerry Digi+](https://www.hifiberry.com/shop/boards/hifiberry-digi/) (`snd_rpi_hifiberry_digi`, WM8804) — **uscita S/PDIF ottica/coassiale** |
| Display | 3840x2160 (4K) |
| Rete | WiFi 5 GHz |
| Profilo | personalizzato (ottimizzato per display 4K) |

**Carico container Docker** (client con display copertine 4K attivo):

| Container | CPU % | RAM usata | Limite RAM |
|-----------|-------|-----------|------------|
| fb-display | **66,1%** | 114 MiB | 384 MiB |
| audio-visualizer | 8,6% | 36 MiB | 128 MiB |
| snapclient | 1,8% | 18 MiB | 96 MiB |
| **Totale** | **~77%** | **~168 MiB** | |

**RAM sistema:** 1,1 GiB usati / 1,6 GiB totali (547 MiB disponibili)

> fb-display a risoluzione 4K usa significativamente più CPU (~66%) e RAM (~114 MiB) rispetto a 1080p (~12% CPU, ~89 MiB). Il limite di 384 MiB fornisce un margine sicuro. Per display 4K, Pi 4 2 GB è il minimo; Pi 4 4 GB+ è consigliato.

---

### Hardware Minimo — Conclusioni

| Caso d'Uso | Scheda Minima | RAM | Motivo |
|------------|---------------|-----|--------|
| Solo server | Pi 3 **1 GB** | 1 GB | ~309 MiB di utilizzo effettivo; stretto ma funziona. Pi 4 2 GB consigliato |
| Server + Client headless | Pi 3 **1 GB** | 1 GB | snapclient aggiunge solo 18 MiB |
| Server + Client con display | Pi 4 **2 GB** | 2 GB | fb-display + visualizer aggiungono ~140 MiB |
| Solo client, headless | **Pi Zero 2 W** | 512 MB | snapclient: ~2% CPU, 18 MiB RAM |
| Solo client, con display (1080p) | Pi 3 **1 GB** | 1 GB | fb-display + visualizer: ~140 MiB |
| Solo client, con display (4K) | Pi 4 **2 GB** | 2 GB | fb-display a 4K: ~114 MiB, ~66% CPU |

**Termico:** Entrambe le schede Pi 4 hanno funzionato continuativamente per giorni a 58–65°C senza throttling termico (snapvideo 57,9°C, snapdigi 64,7°C). Il raffreddamento passivo (case con dissipatore) è sufficiente; il raffreddamento attivo (ventola) non è necessario per l'uso domestico tipico.
