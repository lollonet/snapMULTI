# Contribuire a snapMULTI

Bug fix, feature, miglioramenti alla documentazione e post "show your setup" sono tutti benvenuti.

- [Issues](https://github.com/lollonet/snapMULTI/issues) — segnalazioni di bug + richieste feature (usa i template)
- [Discussions](https://github.com/lollonet/snapMULTI/discussions) — domande, idee, show your setup
- [SECURITY.md](SECURITY.md) — disclosure privata di vulnerabilità

## Contributi non-code

I contributi community più utili spesso non sono codice:

- report di validazione hardware per modelli Pi, DAC HAT, amplificatori, SD e alimentatori
- log di installazione o bundle diagnostici da primi boot falliti
- correzioni alle traduzioni italiane
- miglioramenti documentali dove un passaggio non era chiaro
- foto o screenshot di setup funzionanti per futuri esempi hardware

Per un report hardware, includi: modello Pi + RAM, modello/classe SD se nota, alimentatore, HAT/DAC/uscita audio, tipo installazione (`server`, `client`, `both`), rete (Ethernet/WiFi/NAS), versione snapMULTI e output di `device-smoke.sh` o `fleet-smoke.sh` se disponibile.

## Inviare codice

1. Fork + branch da `main` (`feature/<nome-corto>` o `fix/<nome-corto>`).
2. Fai commit atomici e focalizzati. Referenzia le issue collegate (`Fix audio dropout on Pi 3 (#42)`).
3. Testa in locale:
   ```bash
   shellcheck scripts/*.sh scripts/**/*.sh
   bash tests/run-all-tests.sh
   docker compose config --quiet
   ```
4. Apri una PR su `main`. CI esegue `validate.yml` (shellcheck + sintassi docker-compose) e `build-test.yml` (build Docker).

## Documentazione

Ogni argomento ha UN solo file autorevole (tabella SSOT completa in [CLAUDE.md](CLAUDE.md)). Non duplicare contenuto tra docs.

| File | Contenuto |
|------|-----------|
| `README.md` | Panoramica, quick start, aspettative realistiche, "scegli il tuo setup" |
| `docs/INSTALL.md` | Procedura di prima installazione (percorso base lineare) |
| `docs/TROUBLESHOOTING.md` | Supporto per sintomi, triage mDNS / audio / fallimento install, recupero bundle diagnostico |
| `docs/ADVANCED.md` | Personalizzazioni operative — multi-room, NAS (NFS / SMB), `.env` personalizzato, deploy manuale, fs read-only, strategia di aggiornamento, MPD CLI, JSON-RPC |
| `docs/HARDWARE.md` | Modelli Pi supportati, uscite audio, scelta SD / rete / hardware, note Pi Zero 2 W |
| `docs/USAGE.md` | Riferimento architettura — servizi, porte, sorgenti audio, modello di sicurezza |
| `config/snapserver.conf` | Schema autorevole dei parametri sorgente (commenti inline) |

I mirror italiani (`*.it.md`) seguono i file inglesi 1:1 — aggiornali nella stessa PR quando modifichi la documentazione inglese. Correttezza diacritica completa (usa `à è é ì ò ù`, mai gli equivalenti ASCII).

## Convenzioni di codice

**Script shell** — `set -euo pipefail` in testa, devono passare `shellcheck -S warning`, usa `scripts/common/unified-log.sh` (`info` / `warn` / `error` / `log_info` / `log_warn` / `log_error`). Solo ASCII in output su `/dev/tty1` (i font PSF non hanno simboli Unicode).

**Docker** — pinna versioni specifiche delle base-image (`alpine:3.23`, non `:latest`). I container girano in read-only con `cap_drop: ALL` + `no-new-privileges` dove possibile; l'unica eccezione è `tidal-connect` (binario proprietario necessita di `DAC_OVERRIDE`). Ogni container ha una healthcheck. Le build multi-arch supportano `linux/amd64` + `linux/arm64`.

**Formato audio** — `44100:16:2` su tutte le sorgenti, niente resampling. Non cambiarlo senza discussione in una issue prima.

**Config** — `.env` per i valori configurabili dall'utente (documentati in `.env.example`), config sorgenti in `config/`, script in `scripts/` (librerie condivise in `scripts/common/`).

## Licenza

Contribuendo accetti che i tuoi contributi siano rilasciati sotto `GPL-3.0-only` (vedi [LICENSE](LICENSE)).
