🇬🇧 [English](HARDWARE.md) | 🇮🇹 **Italiano**

# Guida Hardware e Rete

Requisiti hardware, configurazioni consigliate e considerazioni sulla rete per snapMULTI.

> **⚠️ Utenti Pi Zero 2 W — leggi prima questo.** L'installer si comporta diversamente sulla Zero 2 W perché la scheda ha solo 512 MB di RAM:
> - **Scelta 1 (Audio Player) di `prepare-sd.sh`** funziona, ma il profilo viene auto-promosso a `client-native`: snapclient nativo da `.deb`, niente Docker, niente display per la copertina, solo ruolo single-client. Lo stack Docker completo non sta in RAM
> - **Scelte 2 (Music Server) e 3 (Server + Player)** — il primo boot si interrompe con `Pi Zero 2W (512 MB RAM) cannot host the snapMULTI server stack` e si ferma. Il server richiede almeno un Pi 3 B+ con 1 GB di RAM. Riflashare l'SD con la scelta 1, oppure usare un Pi diverso
>
> Dettagli completi in [Note Pi Zero 2 W](#note-pi-zero-2-w) qui sotto.

## Se non sai cosa comprare/usare

Suggerimenti rapidi per chi non vuole leggere tutta la guida.

| Ruolo | Compra / usa | Perché |
|-------|--------------|--------|
| **Server + Player** (un Pi che fa tutto) | **Pi 4 4 GB**, SD A1/A2 di marca ≥ 16 GB, alimentatore ufficiale 15 W, **famiglia HiFiBerry DAC+** oppure **HAT InnoMaker PCM5122** | È il percorso validato per il lancio. Il modello 4 GB lascia margine per le scansioni MPD + i picchi di Spotify / Tidal; le card A1/A2 sono il fattore numero uno contro l'install che si appende |
| **Solo server** (gli altoparlanti stanno in altre stanze) | **Pi 4 2 GB+** oppure un mini PC / NAS con Docker | Lo stack server è ~1 GB di limiti container; 2 GB di RAM host bastano |
| **Altoparlante / client** | **Pi 3 B+ / Pi 4** con HiFiBerry DAC+/Digi+ o InnoMaker PCM5122, oppure **Pi Zero 2 W + InnoMaker PCM5122** headless (install nativa — niente Docker) | Sono i percorsi client validati per il lancio. Usa altri DAC solo se ti senti a tuo agio nel diagnosticare ALSA |
| **Evita** | Pi Zero 2 W come server o in both-mode (512 MB di RAM non bastano), Raspberry Pi OS 32-bit, SD card senza marca, hub USB-alimentati senza alimentatore proprio quando pilotano più Pi | Sono i fallimenti ricorrenti negli install reali |

Il resto di questa guida entra nei *perché* e nei casi limite.

## Policy supporto hardware

snapMULTI mantiene intenzionalmente piccola la matrice hardware di lancio. L'audio su Raspberry Pi è la zona dove nascono più problemi "quasi funziona", quindi la promessa pubblica si basa solo sui dispositivi che abbiamo davvero riflashato, avviato, verificato con test di salute e ascoltato in riproduzione.

| Livello | Significato | Aspettativa di supporto |
|---------|-------------|-------------------------|
| **Validato** | Testato end-to-end dal progetto: primo boot, reboot in read-only, smoke/fleet smoke e playback reale dall'uscita audio | Consigliato per prime installazioni e build reference/commerciali |
| **Atteso funzionante** | Stesso chipset o stesso percorso audio Linux di hardware validato, ma non ancora testato fisicamente dal progetto | Buono per utenti esperti; segnala i risultati |
| **Sperimentale / manuale** | Presente nel menu installer o configurabile via ALSA, ma non validato per il lancio | Nessuna promessa di compatibilità; usalo solo se sai diagnosticare dispositivi audio |

Uscite audio validate per il lancio:

| Famiglia uscita | Stato validazione |
|-----------------|-------------------|
| Famiglia HiFiBerry DAC+ / PCM5122 analogico | **Validato** |
| HAT InnoMaker PCM5122 analogici, incluso Pi Zero 2 W headless | **Validato** |
| Famiglia HiFiBerry Digi+ / WM8804 S/PDIF | **Validato** |
| Audio onboard/bcm2835 su client Pi 4 | **Validato, ma qualità limitata** |
| Uscita HDMI su client/display Pi 4 | **Validato per il percorso display/client** |
| DAC USB generici, HAT amplificati, IQaudio, JustBoom, Allo, Waveshare | **Sperimentale / manuale finché non validati fisicamente** |

## Requisiti del Server

Il server esegue tutti i servizi audio: Snapcast, MPD, shairport-sync (AirPlay), go-librespot (Spotify Connect) e — solo su `linux/arm64` — tidal-connect (Tidal), tutti dentro container Docker.

### Hardware Minimo del Server

| Componente | Minimo | Consigliato |
|------------|--------|-------------|
| CPU | 4 core, ARMv8 o x86_64 (Pi 3B+) | Pi 4 o x86_64 (single-core più veloce) |
| RAM | 2 GB | 4 GB+ |
| Storage | 32 GB microSD | 32 GB+ |
| Rete | Ethernet 100 Mbps o WiFi 5 GHz | Gigabit Ethernet |
| Architettura | `linux/amd64` o `linux/arm64` | Entrambe |

> **Perché 2 GB consigliati?** Un Pi 3 da 1 GB funziona ma ha margine limitato per i picchi (scansioni libreria MPD, streaming simultaneo + AirPlay / Spotify / Tidal attivi). Un Pi 4 con 2 GB offre un margine confortevole. Vedi [profili risorse](#profili-risorse) sotto per i limiti per-container applicati automaticamente.

### Cosa Determina i Requisiti del Server

- **shairport-sync** (ricevitore AirPlay): leggero; richiede un Pi 2 o superiore ([fonte](https://github.com/mikebrady/shairport-sync))
- **librespot** (Spotify Connect): leggero a riposo, sale durante lo streaming attivo ([fonte](https://github.com/librespot-org/librespot/issues/343))
- **MPD**: più pesante al primo avvio con libreria montata via NFS (scansione completa) — proporzionale alla dimensione della libreria
- **Snapserver**: scala linearmente con il numero di client connessi ([fonte](https://github.com/badaix/snapcast/issues/1336))
- **tidal-connect** (solo ARM): gira solo quando il profilo Compose `tidal` è abilitato; quasi sempre in idle

### Esempi di Server

**TL;DR**: Pi 4 (2+ GB) è la scelta sicura. Pi 3 B+ funziona ma stretto. Pi Zero 2 W non può fare il server — usalo come client.

| Hardware | Verdetto | Per cosa | Perché |
|----------|----------|----------|--------|
| Raspberry Pi 4 (4 GB+) | ✅ Consigliato | Qualsiasi setup, anche server + display | Gestisce tutte e 5 le sorgenti + 10 client + display copertine comodamente |
| Raspberry Pi 4 (2 GB) | ✅ Buono | Solo server o server + client headless | Stretto se vuoi anche il display copertine sullo stesso Pi |
| Raspberry Pi 3 B+ | ⚠️ Solo server | Server dedicato con 1-2 sorgenti streaming | 1 GB di RAM basta a riposo ma non lascia margine per i picchi delle scansioni MPD |
| Raspberry Pi Zero 2 W | ❌ Non supportato | — (usa solo come client) | 512 MB di RAM non bastano a contenere i container server |
| Intel NUC / mini PC | ✅ Eccellente | Librerie grandi, molti client | CPU e RAM in abbondanza, basso consumo |
| Vecchio laptop / desktop | ✅ Eccellente | Riuso di hardware esistente | Qualsiasi x86_64 con 2+ GB di RAM funziona |
| NAS con Docker | ✅ Buono | Sempre-attivo, appliance | Servono 2+ core, 2+ GB di RAM, supporto Docker |

> **Nota:** Il Pi 3B+ ha solo **1 GB di RAM**. Solo server funziona ma lascia margine limitato. Non consigliato per la modalità "entrambi" (server + client con display). Il Pi 2 è troppo lento per AirPlay + Spotify simultanei; evitare per uso server.

> **Principianti:** Se è la tua prima volta, usa un Raspberry Pi 4 (4 GB) e segui il [Quick start nel README](../README.it.md#quick-start). Gestisce tutto automaticamente — non serve esperienza di amministrazione Linux.

## Requisiti dei Client

I client Snapcast sono leggeri — ricevono audio e lo riproducono attraverso gli altoparlanti.

### Hardware Minimo del Client

| Componente | Minimo | Note |
|------------|--------|------|
| CPU | Qualsiasi ARMv6+ o x86_64 | Anche il Pi Zero W (originale) funziona |
| RAM | 256 MB | Snapclient usa pochissima memoria |
| Storage | 8 GB microSD | 16 GB consigliati |
| Uscita audio | HAT I2S validato, HDMI/onboard, o DAC USB manuale | Vedi policy supporto hardware e sezione uscita audio |

### Dispositivi Client

| Dispositivo | Uscita Audio | Consumo | Note |
|-------------|--------------|---------|------|
| **Raspberry Pi Zero 2 W** | HAT I2S validato | 0,75 W | Miglior opzione economica; solo WiFi 2,4 GHz; solo audio (senza display) |
| **Raspberry Pi Zero W** (v1) | DAC USB o HAT I2S | 0,5 W | Funziona ma lento; nessun GPIO audio; solo WiFi 2,4 GHz |
| **Raspberry Pi 3B/3B+** | HAT I2S validato, onboard/USB manuale | 2,5 W | WiFi 5 GHz + Ethernet; onboard/USB non sono il percorso consigliato per il lancio |
| **Raspberry Pi 4** (2 GB+) | HAT I2S validato, HDMI, onboard, USB manuale | 3–6 W | Necessario per client con display copertine (fb-display) |
| **Raspberry Pi 5** | HDMI, USB manuale | 4–8 W | Sovradimensionato per uso client; validazione di lancio più sottile rispetto a Pi 4 |
| **Vecchio telefono Android** | Altoparlante integrato | Batteria | Tramite [app Snapcast Android](https://github.com/badaix/snapdroid) |
| **Qualsiasi PC Linux** | Audio integrato | Varia | `apt install snapclient` |

### Note Pi Zero 2 W

Il Pi Zero 2 W è l'opzione client più economica ma ha requisiti specifici.

> **Cosa fa snapMULTI automaticamente sul Pi Zero 2 W:**
>
> | Scelta nel menu di `prepare-sd.sh` | Cosa succede al primo boot |
> |-----|-----|
> | **1) Audio Player** | Il profilo viene auto-promosso da `client` a `client-native`. Niente Docker, niente container display (fb-display / visualizer), ruolo single-client senza failover multi-server. Viene installato lo snapclient nativo da `.deb` |
> | **2) Music Server** | Il primo boot **si interrompe con un errore** che rimanda qui. 512 MB di RAM non bastano per lo stack server da 7 container. Riflashare l'SD con la scelta 1 |
> | **3) Server + Player** | Il primo boot **si interrompe con lo stesso errore**. Stesso vincolo di RAM della scelta 2 |
>
> Se hai scelto "Audio Player" aspettandoti lo stack Docker standard con display per la copertina — è il compromesso per stare dentro i 512 MB di RAM. Usa un Pi 3 B+ o un Pi 4 se ti servono display, failover multi-server o l'isolamento Docker completo.

Dettagli:

- **OS 64-bit obbligatorio** — Imager propone 32-bit come predefinito per questo modello. Seleziona esplicitamente "Raspberry Pi OS Lite (64-bit)"
- **Solo WiFi 2,4 GHz** — niente 5 GHz. Usa il tuo SSID 2,4 GHz quando configuri il WiFi in Imager
- **512 MB RAM** — solo audio headless (senza display). Non può eseguire fb-display o server
- **snapclient nativo (no Docker)** — `firstboot.sh` rileva il Pi Zero 2 W tramite `is_pi_zero_2w` (`scripts/common/device-detect.sh`), promuove il profilo da `client` a `client-native` e poi richiama `client/common/scripts/setup-zero2w.sh`. Lo script installa snapclient v0.35 dal `.deb` upstream di badaix e salta del tutto Docker, dockerd e fuse-overlayfs. Gli altri modelli client continuano a usare il path Docker standard
- **Hardware guard per server / both** — all'inizio di `firstboot.sh`, `_validate_profile_hardware()` rifiuta `INSTALL_TYPE=server` e `INSTALL_TYPE=both` su Pi Zero 2 W. Il primo boot si interrompe con `log_error` ed `exit 1`, segnalando subito il vincolo invece di fallire più tardi durante `docker compose pull` con un OOM oscuro. Per recuperare, riflashare l'SD scegliendo Audio Player
- **Zram swap disabilitato** — `tune_pi_zero_2w_swap_safety()` in `scripts/common/system-tune.sh` maschera `dev-zram0.swap` / `rpi-zram-writeback.service` e rimuove `/var/swap` al primo boot. Senza questa correzione, `rpi-zram-writeback` scrive sul file swap che vive nel layer alto tmpfs da 256 MB dell'overlay e il kernel va in panic quando il tmpfs si riempie (osservato il 2026-05-11)
- **Ruolo single-client, niente failover multi-server** — lo snapclient nativo usa direttamente l'autodiscovery di libavahi-client. La macchina a stati di failover multi-server di `discover-server.sh` (TCP probing, anti-flapping, scelta IPv4 intelligente) non è disponibile sul Pi Zero 2 W. Accettabile per i setup headless tipici a singola stanza; se serve failover usa un client Pi 3 B+ o Pi 4
- **Compatibilità HAT I2S** — la validazione di lancio copre HAT PCM5122 HiFiBerry/InnoMaker. Altre schede PCM5122 sono attese funzionanti ma restano non validate finché non testate. L'impostazione USB `otg_mode=1` di Imager interferisce con I2S — `prepare-sd.sh` e `setup.sh` lo correggono automaticamente
- **Modalità gadget USB** — per debug senza WiFi, collegare la porta USB dati al computer. Richiede `dtoverlay=dwc2` sotto `[all]` in config.txt (non sotto `[cm5]`)

### Qualità dell'Uscita Audio

| Metodo di Uscita | Qualità | Note |
|------------------|---------|------|
| **DAC HAT I2S** (HiFiBerry DAC+ / InnoMaker PCM5122 validati) | Eccellente | Migliore qualità analogica, uscita RCA, si collega direttamente al GPIO del Pi |
| **HAT S/PDIF I2S** (HiFiBerry Digi+ validato) | Eccellente | Uscita digitale ottica/coassiale verso ricevitore AV o DAC esterno; nessuna conversione analogica sul Pi |
| **DAC USB** | Molto buona se supportato da Linux | Manuale/sperimentale finché uno specifico modello non viene validato fisicamente |
| **HDMI** | Buona | Validato sul percorso client/display Pi 4. Il nome della card ALSA varia per kernel: `vc4-hdmi-0` (Bookworm/Trixie KMS), `HDMI` (legacy). Risolto automaticamente al primo boot via `aplay -L` |
| **Jack 3.5mm** (Pi 3/4) | Adeguata | Validato solo come fallback onboard. Rumore di fondo percepibile su alcuni modelli; va bene per ascolto casual. **Il Pi 5 non ha jack analogico** — scegliere "jack" nel menu installer ricade automaticamente su HDMI |

> **Suggerimento:** per la prima installazione usa HAT I2S validati per il lancio: famiglia HiFiBerry DAC+ o InnoMaker PCM5122 per analogico, famiglia HiFiBerry Digi+ per S/PDIF.

> **Override manuale:** `prepare-sd.sh` offre un menu *Uscita audio* (auto-detect, scegliere un HAT dalla lista, oppure scegliere HDMI/jack integrato). Le voci oltre la matrice validata sono aiuti di compatibilità, non una promessa di supporto per il lancio. Vedi [INSTALL.it.md — Menu 2 — Uscita audio](INSTALL.it.md#menu-2--uscita-audio-solo-audio-player-e-serverplayer).

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

Configurazione del firewall (regole `ufw`) e setup QoS / `cake` qdisc sono documentati in [ADVANCED.it.md — Regole firewall](ADVANCED.it.md#regole-firewall) e [Network QoS](ADVANCED.it.md#network-qos).

## Storage

### Immagini Docker

**Immagini server:**

| Immagine | Dimensione |
|----------|------------|
| `lollonet/snapmulti-server:latest` | ~80–120 MB |
| `lollonet/snapmulti-airplay:latest` | ~30–50 MB |
| `ghcr.io/devgianlu/go-librespot:v0.7.1` | ~30–50 MB |
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

> Il Pi 4 2 GB è sufficiente per solo server. Per server + client con display, il modello 4 GB è preferito.

### Entusiasta — 4+ stanze

| Nodo | Hardware | Connessione |
|------|----------|------------|
| Server | Intel NUC o mini PC (x86_64) | Ethernet |
| Client × 3+ | Pi Zero 2 W + HiFiBerry DAC+ Zero | WiFi (2,4 GHz) |

> I client Pi Zero si connettono via WiFi (nessuna porta Ethernet). Il server dovrebbe usare Ethernet per affidabilità. Uno switch gestito è utile se hai anche client cablati (Pi 3/4).

### Alternativa: S/PDIF verso Ricevitore AV

Se un nodo è collegato a un ricevitore AV via cavo ottico, usa HiFiBerry Digi+ al posto del DAC HAT. Questo sposta la conversione D/A al tuo ricevitore — qualità migliore se il tuo ricevitore ha un buon DAC.

## Combinazioni Testate

Queste combinazioni hardware sono state verificate end-to-end (firstboot → test di salute → playback audio) nelle date indicate. Considera questa tabella la fonte di verità per l'hardware validato al lancio. Il batch del 2026-04-27 è la validazione release-gate per v0.6.x: 6 device riflashati da `main`, test di salute PASS su ognuno, `hw_ptr` ALSA che avanza durante la riproduzione (audio che raggiunge davvero il DAC, non solo la FIFO).

| Hostname | Modello Pi | HAT Audio | Chip DAC | Modalità | Display | Sorgente Musica | Validato | Stato |
|---|---|---|---|---|---|---|---|---|
| pi-server | Pi 4 B (8 GB) | HiFiBerry DAC+ | PCM5122 (analogico) | both | HDMI 800×600 (display cover art) | locale | 2026-04-27 | Funzionante |
| pi4-test | Pi 4 B (2 GB) | HiFiBerry DAC+ Standard | PCM5122 (analogico) | both | headless | USB | 2026-04-27 | Funzionante |
| pi-display | Pi 4 B (2 GB) | HiFiBerry Digi+ | WM8804 (S/PDIF) | client | HDMI verso TV LG 50" | n/d | 2026-04-27 | Funzionante |
| pi4-2gb-cli | Pi 4 B (2 GB) | nessuno (bcm2835 onboard) | — | client | headless | n/d | 2026-04-27 | Funzionante |
| pi3-1gb-cli | Pi 3 B+ (1 GB) | InnoMaker HIFI DAC HAT | PCM5122 (analogico) | client | headless | n/d | 2026-04-27 | Funzionante |
| pi-zero | Pi Zero 2 W (512 MB) | InnoMaker DAC | PCM5122 (analogico) | client | headless | n/d | 2026-04-27 | Funzionante |

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

## Profili risorse

I limiti di memoria dei container vengono applicati automaticamente in base all'hardware rilevato (minimal / standard / performance). Tabelle complete per servizio e matrice di compatibilità hardware: [ADVANCED.it.md — Profili risorse](ADVANCED.it.md#profili-risorse).

---

## Build di riferimento — misurazioni reali

Due scenari di produzione catturati il **2026-05-13** con `docker stats --no-stream`, `free -h` e `vcgencmd measure_temp`. Pensati come limiti superiori realistici mentre il sistema sta attivamente trasmettendo, *non* come baseline a riposo.

### Scenario A — `pi-server` fan-out: 3 sorgenti → 3 gruppi di client

`pi-server` serve tre sorgenti audio diverse simultaneamente a tre client distinti, ognuno sul proprio gruppo Snapweb.

| Ruolo | Hostname | Scheda | RAM | Audio | Sorgente riprodotta |
|-------|----------|--------|-----|-------|---------------------|
| Server + display | `pi-server` | Pi 4 B Rev 1.4 | 8 GB | HiFiBerry DAC+ (analogico) | — (serve tutti e 3) |
| Client gruppo A | `pi3-1gb` | Pi 3 B+ Rev 1.4 | 1 GB | InnoMaker HIFI DAC HAT (PCM5122) | Libreria MPD |
| Client gruppo B | `pi-zero` | Pi Zero 2 W Rev 1.0 | 512 MB | InnoMaker DAC (PCM5122), snapclient nativo | Spotify |
| Client gruppo C | `pi-display` | Pi 4 B Rev 1.1 | 2 GB | HDMI verso LG 50" (con display copertine) | Tidal Connect |

**Carico server** (`pi-server`, uptime 6 h, load avg `1.62`):

| Container | CPU % | RAM | Note |
|-----------|-------|-----|------|
| snapserver | 13.32% | 91 MiB | Distribuisce l'audio a tutti e 3 i client |
| mpd | 11.23% | 255 MiB | Il gruppo A sta riproducendo dalla libreria locale |
| fb-display | 10.93% | 133 MiB | Server-con-display (copertine anche su questo Pi) |
| audio-visualizer | 7.53% | 54 MiB | Server-con-display |
| librespot (Spotify) | 3.02% | 58 MiB | Il gruppo B sta facendo cast da Spotify |
| metadata | 2.02% | 62 MiB | Serve copertina / brano in corso a client + display |
| snapclient (loopback) | 1.65% | 18 MiB | pi-server suona anche localmente |
| tidal-connect | 1.47% | 95 MiB | Il gruppo C sta facendo cast da Tidal |
| shairport-sync | 0.00% | 18 MiB | AirPlay a riposo (nessuno stream attivo) |
| mympd | 0.00% | 18 MiB | Web UI a riposo |
| **Totale server** | **~51% CPU** | **~803 MiB** | su 384+256+96+128+192+128+96+192+96+128 MiB di limiti |

Host: 2,8 GiB usati / 7,5 GiB totali, **4,6 GiB disponibili**. Temperatura **64,2 °C**.

**Carico client** (per gruppo, tutti verdi al test di salute):

| Client | CPU % snapclient | RAM snapclient | RAM host usata / totale | Temp |
|--------|------------------|----------------|--------------------------|------|
| `pi3-1gb` (Pi 3 B+ 1 GB, headless) | 1,36% | 18 MiB | 223 / 955 MiB | 49,4 °C |
| `pi-zero` (Pi Zero 2 W, install nativa) | 1,8% (processo) | 13 MiB RSS | 159 / 416 MiB | 44,0 °C |
| `pi-display` (Pi 4 2 GB + display HDMI 4K) | 1,80% | 9 MiB | 848 / 1,6 GiB | 59,9 °C |

Su `pi-display`, lo stack copertine aggiunge: `fb-display` **66,16% / 124 MiB** (il rendering 4K è il costo dominante) e `audio-visualizer` 8,92% / 33 MiB. snapclient di per sé resta trascurabile su ogni client.

> **Nota sul Pi Zero 2 W.** Esegue snapclient nativo da `.deb` (niente Docker, niente container display — vedi [Note Pi Zero 2 W](#note-pi-zero-2-w)). Il risultato è un singolo processo a 13 MiB RSS / 1,8% CPU, ed è per questo che una scheda da 512 MB lo sostiene a tempo indefinito. Lo stesso ruolo sotto Docker non starebbe in RAM.

### Scenario B — `pi4-test` both-mode single-host (solo libreria locale)

Un singolo Pi che esegue server + client simultaneamente, riproducendo dalla propria libreria MPD verso il proprio snapclient. Nessun fan-out, nessun client remoto.

| Container | CPU % | RAM |
|-----------|-------|-----|
| snapserver | 4,24% | 77 MiB |
| mpd | 3,12% | 182 MiB |
| tidal-connect | 4,31% | 20 MiB |
| metadata | 0,99% | 53 MiB |
| snapclient (loopback) | 1,09% | 18 MiB |
| librespot | 0,00% | 17 MiB |
| shairport-sync | 0,00% | 14 MiB |
| mympd | 0,00% | 10 MiB |
| **Totale** | **~18% CPU** | **~390 MiB** |

Scheda: Pi 4 B Rev 1.5 / **2 GB RAM**. Host: 798 / 1,9 GiB usati (1,1 GiB disponibili). Temperatura 53 °C. Uptime 5 h.

### Osservazioni

- **Il Pi 4 8 GB regge comodamente un fan-out 3 sorgenti × 3 gruppi** anche con il display copertine lato server attivo. ~51% CPU e ~800 MiB di RAM container lasciano il resto della scheda libero per i picchi (scansioni MPD, cambi simultanei Spotify / Tidal). Il costo dominante era lo streaming dalla libreria MPD, non il fan-out di snapserver in sé.
- **La CPU per client è dominata dallo stack display, non da `snapclient`.** Su `pi-display`, `fb-display` a 4K HDMI prende il 66% di CPU mentre `snapclient` resta sotto il 2%. I client headless costano praticamente nulla.
- **L'install nativo del Pi Zero 2 W è decisamente più leggero di Docker** — 13 MiB RSS / 1,8% CPU contro ~64 MiB e l'overhead del demone Docker. È questo che rende una scheda da 512 MB usabile per snapMULTI.
- **Un singolo Pi 4 2 GB regge comodamente la modalità both** quando non ci sono client in fan-out (Scenario B): ~18% CPU e ~390 MiB. Il modello da 2 GB ha margine evidente; 4 GB è sovradimensionato per questo caso d'uso.
- **Le temperature sono ampiamente sotto il margine** su tutte e cinque le schede — la più calda (`pi-server` a 64 °C) è lontana dalla soglia di throttling (80 °C). Il raffreddamento passivo è stato sufficiente.

> **Come è stato raccolto.** Su ogni dispositivo: `docker stats --no-stream` (o `ps -o pcpu,pmem,rss -C snapclient` per l'install nativa del Pi Zero 2 W), `free -h`, `vcgencmd measure_temp`. Il test di salute (`scripts/device-smoke.sh`) era verde su ogni dispositivo prima dello snapshot. Le percentuali CPU sono campioni puntuali e variano con l'attività di riproduzione.

---

## Termico

Le schede Pi 4 funzionano continuativamente senza throttling termico sotto il tipico carico domestico di streaming. Il raffreddamento passivo (case con dissipatore) è sufficiente; il raffreddamento attivo (ventola) non è necessario.
