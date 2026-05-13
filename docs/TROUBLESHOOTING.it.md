🇮🇹 **Italiano** | 🇬🇧 [English](TROUBLESHOOTING.md)

# Risoluzione problemi

Guida per sintomi quando qualcosa di snapMULTI non funziona. Per l'installazione da zero vedi [INSTALL.it.md](INSTALL.it.md); per operazioni e personalizzazioni vedi [ADVANCED.it.md](ADVANCED.it.md).

## In caso di dubbio — prendi il bundle diagnostico

Se `firstboot.sh` si interrompe, la trap di cleanup scrive un tarball anonimizzato sulla **partizione FAT32 di boot** della SD — leggibile da qualsiasi computer senza SSH:

```
/boot/firmware/snapmulti-diag-install-failed-<UTC-ts>.tar.gz
```

Cosa contiene: l'ultima ora di log di installazione, l'output del rilevamento hardware (modello, HAT audio, rete), il nome dello step fallito, i log dei container. Il bundle è **anonimizzato** prima di finire sulla SD — niente MAC address, niente IP della LAN, niente SSID, niente password, niente token API — quindi è sicuro allegarlo a una [issue GitHub](https://github.com/lollonet/snapMULTI/issues/new/choose) pubblica. La partizione boot sopravvive all'attivazione di overlayroot e alla corruzione del rootfs; è per questo che scriviamo lì invece che in `/var/log`.

Lo puoi anche generare manualmente su un device in esecuzione per supporto:

```bash
sudo /opt/snapmulti/scripts/diagnostic.sh --reason crash --out-dir /tmp
```

Stesse regole di anonimizzazione.

## Prima cosa da fare — esegui lo smoke test

Prima di addentrarti nei singoli sintomi, esegui il controllo di salute generale sul device:

```bash
sudo bash /opt/snapmulti/scripts/device-smoke.sh --server   # oppure --client, o --both
```

Verifica stato mount root + overlayroot, storage driver Docker, unit systemd richieste, conteggio container previsti / attivi / healthy, annuncio mDNS, raggiungibilità TCP/RPC di Snapcast, moduli kernel audio rispetto all'HAT configurato, QoS, mount musica e salute dei timer (10 moduli in `scripts/smoke/`). Se tutte le sezioni sono verdi, la piattaforma è sana — concentrati a monte (rete, app di cast, account). Se qualcosa è rosso, il check fallito ti dice quale sottosistema controllare. Lo stesso script è il release gate (ADR-005) e quello che `fleet-smoke.sh` esegue su più device.

Output JSON per script / dashboard: `sudo bash /opt/snapmulti/scripts/device-smoke.sh --server --json`.

---

## L'installazione sembra ferma

**Sintomi.** L'HDMI mostra la schermata di progresso ma non avanza per diversi minuti, oppure lo schermo è nero e il Pi non è ancora raggiungibile.

**Causa probabile.** Il primo boot sta scaricando le immagini container dalla rete (la parte lenta, 2–6 minuti su WiFi domestico tipico). Anche le SD economiche / contraffatte sembrano "appendersi" — in realtà l'install sta aspettando il throughput in scrittura della SD.

**Cosa provare.**
1. Aspetta i 10–15 minuti completi prima di sospettare un problema — l'install gira come `cloud-init` → `snapmulti-firstboot.service`, entrambi headless.
2. Dal laptop: `ping <hostname>.local`. Se risponde, la rete è OK.
3. Se SSH funziona: `ssh <username>@<hostname>.local`, poi `sudo journalctl -u snapmulti-firstboot.service -f` per vedere l'install in tempo reale.

**Se è ancora bloccato.** Estrai la SD e cerca `snapmulti-diag-install-failed-*.tar.gz` sulla partizione boot — significa che l'install si è arreso. Allegalo a una issue GitHub. Se nessun bundle esiste e il Pi è completamente irraggiungibile dopo 20 minuti, la SD è la causa più comune (usa SanDisk / Samsung A1 o migliore — vedi [HARDWARE.it.md](HARDWARE.it.md#se-non-sai-cosa-comprareusare)).

## Il device non compare in rete / `.local` non risolve

**Sintomi.** `ping <hostname>.local` non risponde. Il Pi non appare mai nella lista client DHCP del router.

**Causa probabile.** Mismatch nella configurazione WiFi di Imager (country code sbagliato, SSID 5 GHz su una scheda solo 2,4 GHz, canale DFS che il Pi non riesce a usare al primo boot), oppure il telefono / laptop è su una rete diversa dal Pi (WiFi guest, VLAN separata), oppure il router non relay'a l'mDNS.

**Cosa provare.**
1. Usa l'IP direttamente. Lo trovi nella lista client DHCP del router, o collega l'HDMI: il Pi stampa l'IP sulla console dopo il boot.
2. Verifica che entrambi i device siano sulla stessa sottorete — `192.168.x.y` sul Pi vs `192.168.x.z` sul laptop, stessi primi tre ottetti.
3. Sul Pi Zero 2 W: conferma che Imager abbia un SSID 2,4 GHz, non 5 GHz (il radio del Zero 2 W non fa 5 GHz).
4. Su un Pi 4 / 5 bloccato su un canale 5 GHz DFS: riflasha con un SSID 2,4 GHz oppure un canale 5 GHz non-DFS (36–48).

**Se è ancora bloccato.** Se hai l'HDMI: fai login, esegui `ip addr` e `iwgetid -r` per verificare che il Pi sia in WiFi. Se `ip addr` non mostra un indirizzo su `wlan0`, le credenziali WiFi in Imager erano sbagliate — riflasha. Se `iwgetid` mostra l'SSID giusto ma `ip addr` non mostra l'indirizzo, hai un problema DHCP sul router.

## Console di emergenza / root bloccato

**Sintomi.** SSH viene rifiutato anche se Imager era configurato correttamente. Oppure hai impostato solo la chiave SSH e l'hai persa.

**Causa probabile.** Imager ha scritto lo username sbagliato, l'overlay read-only sta nascondendo le modifiche, o lo step cloud-init che installa la chiave SSH non è girato.

**Cosa provare.**
1. Collega display HDMI + tastiera USB al Pi per una console locale. Username e password sono quelli impostati in Imager.
2. Da lì: `sudo ro-mode disable && sudo reboot` se servono modifiche persistenti (vedi [ADVANCED.it.md — Filesystem read-only](ADVANCED.it.md#filesystem-read-only)).
3. Se il Pi non arriva mai al login: estrai la SD, apri la **partizione boot** sul laptop, modifica `user-data` per resettare le credenziali, reinserisci e accendi.

**Se è ancora bloccato.** Riflasha con Imager — snapMULTI è reflash-first by design (DEC-003), e l'install dura solo 10–15 min. Fai prima un backup di `/opt/snapmulti/mpd.db` con `scripts/backup-from-sd.sh` se vuoi preservare l'indice della libreria musicale.

## Niente audio

**Sintomi.** Tutti i container sono `healthy`, puoi fare cast da Spotify / AirPlay / Tidal e vedi lo stato "In riproduzione" in Snapweb, ma non esce suono.

**Causa probabile.** snapclient ha scelto la card ALSA sbagliata, l'overlay HAT è caricato ma il cablaggio fisico è errato, o il volume è muto sul mixer hardware.

**Cosa provare.**
1. Sul device client: `docker exec snapclient snapclient --list` (oppure `snapclient --list` sull'install nativa del Pi Zero 2 W) per elencare le card. Quella giusta è quella che corrisponde al tuo HAT (es. `sndrpihifiberry`).
2. Imposta `SOUND_CARD` in `/opt/snapclient/.env` con quel nome, poi `cd /opt/snapclient && sudo docker compose up -d` (NON `restart` — non rilegge `.env`).
3. Controlla il mixer hardware: `alsamixer -c 0`, F6 per scegliere la card, alza il master e tutti i controlli "Digital" / "Speaker".
4. Verifica che l'HAT sia rilevato: `aplay -l` deve mostrare il tuo DAC; `dmesg | grep -i 'snd\|hifiberry\|wm8'` deve mostrare il caricamento del driver.

**Se è ancora bloccato.** Esegui lo smoke test (ha un check `audio_modules` che segnala mismatch fra moduli kernel e HAT). Se `config.txt` non ha `dtoverlay=hifiberry-*` ecc., rilancia `setup.sh` e conferma che il rilevamento HAT scelga il modello giusto — le schede senza EEPROM richiedono una scelta manuale.

## Gli speaker non trovano il server (snapclient non si connette)

**Sintomi.** Un device client è completamente avviato ma non appare mai in Snapweb. `journalctl -u snapclient` sul client mostra tentativi di riconnessione ripetuti.

**Causa probabile.** L'mDNS non raggiunge il client (sottorete diversa, isolamento VLAN, router che non inoltra `_snapcast._tcp`), oppure l'`avahi-daemon` del server non sta annunciando.

**Cosa provare.**
1. Sul server: `systemctl is-active avahi-daemon` — deve dire `active`. Poi `avahi-browse -r _snapcast._tcp --terminate` — deve elencare l'hostname del server.
2. Sul client: `avahi-browse -r _snapcast._tcp --terminate` — deve elencare il server. Se non lo fa, l'mDNS non attraversa la rete.
3. Come workaround, imposta un server statico nel `.env` del client: `SNAPSERVER_HOST=<server-ip>` e `cd /opt/snapclient && sudo docker compose up -d`.

**Se è ancora bloccato.** La causa più comune è un router che non inoltra l'mDNS tra SSID / VLAN (mesh router e funzioni "guest network" sono tipiche). Metti server e client sullo stesso SSID, oppure installa un mDNS repeater sul router (DD-WRT, OpenWrt, UniFi lo supportano tutti).

## Spotify / AirPlay / Tidal non visibili nell'app di cast

**Sintomi.** Il server gira, Snapweb funziona, ma quando apri l'app Spotify / AirPlay / Tidal non c'è nessun device `<hostname> Spotify` / `<hostname> AirPlay` / `<hostname> Tidal` su cui fare cast.

**Causa probabile.** Stesso problema mDNS sopra — l'app di cast è su una rete diversa dal server, o il container in questione non è healthy.

**Cosa provare.**
1. Conferma che il container sia up: `cd /opt/snapmulti && docker compose ps` — `librespot` (Spotify), `shairport-sync` (AirPlay), `tidal-connect` (Tidal, solo ARM) tutti `healthy`.
2. Dal server: `avahi-browse -r _spotify-connect._tcp --terminate`, `avahi-browse -r _raop._tcp --terminate` (AirPlay) — deve elencare il server.
3. Telefono e server sullo stesso SSID WiFi? Le reti guest e le VLAN bloccano il discovery.
4. Tidal Connect è **opt-in** e solo ARM — vedi [USAGE.it.md — Nota sicurezza Tidal Connect](USAGE.it.md#nota-sicurezza-tidal-connect) per abilitarlo.
5. Spotify Connect richiede **Premium** — gli account Free non mostrano il device.

**Se è ancora bloccato.** Riavvia il container in questione: `cd /opt/snapmulti && sudo docker compose up -d --force-recreate librespot` (o `shairport-sync` / `tidal-connect`). Poi ri-controlla con `avahi-browse`. Vedi anche la sezione "Gli speaker non trovano il server" qui sopra per il triage mDNS dettagliato.

## Libreria NAS vuota o non si monta (NFS / SMB)

**Sintomi.** myMPD mostra zero tracce. `mount | grep music` sul server non mostra nulla. Oppure vedi "permission denied" / "no such directory" nel log di install.

**Causa probabile.** Path share NAS errato (snapMULTI rifiuta path con spazi — il default Synology `Music Share` va rinominato `Music_Share`), credenziali SMB sbagliate, export NFS non autorizzato per l'IP del Pi, o `.automount` systemd che non si è abilitato.

**Cosa provare.**
1. Sul server: `systemctl status music.mount music.automount` — lo stato dell'unit ti dice se il mount sta provando.
2. Prova un mount manuale con lo stesso path: `sudo mount -t nfs <nas>:<share> /mnt/test` o `sudo mount -t cifs ...`. Il messaggio d'errore è più informativo di quello di systemd.
3. Verifica che il path non abbia **spazi** lato NAS. Rinomina `Music Share` → `Music_Share`.
4. Per SMB, verifica le credenziali. Vivono in `/etc/credentials.smb` (root-only, ext4) dopo l'install — l'install le rimuove dalla partizione FAT32 per sicurezza.

**Se è ancora bloccato.** Rilancia l'install con il path corretto: riflasha oppure `sudo /opt/snapmulti/scripts/setup_music_source.sh` (dal repo). La scansione MPD su NFS è lenta alla prima esecuzione — vedi [ADVANCED.it.md — Libreria musicale](ADVANCED.it.md#libreria-musicale-in-rete) per il trucco del backup `mpd.db`.

## Docker / "no space left on device"

**Sintomi.** I container non partono con `no space left on device` in `docker compose logs`. `df -h` mostra il rootfs quasi pieno o l'overlay tmpfs pieno.

**Causa probabile.** Il layer alto del tmpfs overlayroot ha capacità finita. Se un processo dentro un container scrive molto in un path non-tmpfs sotto `/var/lib/docker`, mangia il layer alto. Il Pi Zero 2 W è particolarmente stretto (256 MB).

**Cosa provare.**
1. `df -h /` — se l'overlay è pieno, riavvia. Il layer alto si pulisce ad ogni boot (è esattamente lo scopo di overlayroot).
2. `docker system df` — vedi quali immagini / container / volumi stanno occupando spazio.
3. Se un container specifico fa danni: `docker compose logs <name>` per trovare il logger sfuggito di mano, poi `docker compose up -d --force-recreate <name>`.

**Se è ancora bloccato.** Sul Pi Zero 2 W, la funzione `tune_pi_zero_2w_swap_safety()` disabilita zram swap proprio per evitare che riempa l'overlay — se hai riabilitato zram manualmente, è probabilmente quello. Riflashare applica il fix.

## Shutdown / reboot lento

**Sintomi.** `sudo reboot` impiega più di 60 secondi. systemd mostra "A stop job is running".

**Causa probabile.** Uno snapclient o container con timeout di graceful-shutdown lungo (default 90 s in systemd), o `network-online.target` che aspetta un mount NAS irraggiungibile allo spegnimento.

**Cosa provare.**
1. Identifica l'unit lenta: `systemctl list-jobs` durante lo shutdown, oppure `journalctl -b -1 | grep -i 'timeout\|stop job'` dopo il reboot.
2. Se un mount NAS musica sta bloccando, `systemctl edit music.mount` e aggiungi `TimeoutStopSec=10s` sotto `[Mount]`.
3. Per lo shutdown dei container: le unit snapclient / snapserver usano `KillSignal=SIGTERM` + timeout 30 s — di solito graceful.

**Se è ancora bloccato.** Uno shutdown da 60–90 secondi non è di per sé un bug — il timeout default di una unit systemd è 90 s. Se tutto si completa comunque, ignoralo. Se lo shutdown davvero non finisce mai, è un blocco a livello hardware e un `dmesg` post-reboot di solito mostra la causa (device USB, timeout SD, ecc.).

## Casi specifici Pi Zero 2 W

**Sintomi.** L'install raggiunge il menu ma il primo boot si interrompe con `Pi Zero 2W (512 MB RAM) cannot host the snapMULTI server stack`. Oppure l'install va a buon fine ma non c'è Docker. Oppure l'HAT audio non viene rilevato.

**Causa probabile.** Lo Zero 2 W ha solo 512 MB di RAM. L'installer rispetta questo limite:

- **Scelta 1 del menu (Audio Player)** auto-promuove il profilo a `client-native` — snapclient nativo da `.deb`, niente Docker, niente display copertine.
- **Scelte 2 (Music Server) e 3 (Server + Player)** si interrompono al primo boot. Riflasha con la scelta 1, oppure usa un Pi diverso.

Il problema del rilevamento HAT di solito è `otg_mode=1` o `dr_mode=host` in `config.txt` che entra in conflitto con I2S. `prepare-sd.sh` lo corregge automaticamente; gli install manuali devono commentarli.

**Cosa provare.**
1. Per gli abort di modalità non supportata: estrai la SD, rilancia `prepare-sd.sh` e scegli Audio Player.
2. Per verifica install nativa: `systemctl status snapclient` (non `docker compose ps`, non c'è Docker).
3. Per problemi HAT: vedi [HARDWARE.it.md — Note Pi Zero 2 W](HARDWARE.it.md#note-pi-zero-2-w).

**Se è ancora bloccato.** Il Pi Zero 2 W è il device più vincolato che supportiamo. Se va in kernel-panic dopo il boot post-install: lo zram swap può aver saturato il tmpfs overlay (incidente 2026-05-11). `tune_pi_zero_2w_swap_safety()` dovrebbe mascherare zram; un reflash applica il fix.

---

## Log che servono

```bash
# server, log live
cd /opt/snapmulti && docker compose logs -f
docker compose logs -f snapserver shairport-sync librespot mpd

# salute container
docker compose ps
docker inspect --format='{{.State.Health.Status}}' snapserver

# install log (il layer scrivibile sopravvive fino al reboot)
cat /var/log/snapmulti-install.log

# pagina web di stato sistema
http://<server>:8083/status
```

Per un bundle portabile e anonimizzato da allegare a una bug report: `sudo /opt/snapmulti/scripts/diagnostic.sh --reason crash --out-dir /tmp`.

## Ancora bloccato?

- Problema specifico del Pi → [HARDWARE.it.md](HARDWARE.it.md)
- Personalizzazione / operazioni → [ADVANCED.it.md](ADVANCED.it.md)
- Architettura / domande a livello servizio → [USAGE.it.md](USAGE.it.md)
- Bug o comportamento poco chiaro → [apri una issue GitHub](https://github.com/lollonet/snapMULTI/issues/new/choose) e allega il bundle diagnostico.
