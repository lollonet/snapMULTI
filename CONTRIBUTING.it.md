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
   for f in tests/test_*.sh; do bash "$f" || break; done   # test shell
   pytest tests/                                            # test Python (metadata service + plugin)
   docker compose config --quiet
   ```
   La CI (`validate.yml` + `build-test.yml`) è la fonte di verità — i comandi locali sono best-effort.
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
| `docs/CLIENT-METADATA.md` | Guida integrazione client — contratti Snapserver JSON-RPC + metadata-service WS/HTTP, forme di subscribe, regole artwork, controllo trasporto, anti-pattern (per chi scrive una UI / dashboard / controller esterno) |
| `config/snapserver.conf` | Schema autorevole dei parametri sorgente (commenti inline) |

I mirror italiani (`*.it.md`) seguono i file inglesi 1:1 — aggiornali nella stessa PR quando modifichi la documentazione inglese. Correttezza diacritica completa (usa `à è é ì ò ù`, mai gli equivalenti ASCII).

## Convenzioni di codice

**Script shell** — `set -euo pipefail` in testa, devono passare `shellcheck -S warning`, usa `scripts/common/unified-log.sh` (`info` / `warn` / `error` / `log_info` / `log_warn` / `log_error`). Solo ASCII in output su `/dev/tty1` (i font PSF non hanno simboli Unicode).

**Docker** — pinna versioni specifiche delle base-image (`alpine:3.23`, non `:latest`). I container girano in read-only con `cap_drop: ALL` + `no-new-privileges` dove possibile; l'unica eccezione è `tidal-connect` (binario proprietario necessita di `DAC_OVERRIDE`). Ogni container ha una healthcheck. Le build multi-arch supportano `linux/amd64` + `linux/arm64`.

**Formato audio** — `44100:16:2` su tutte le sorgenti, niente resampling. Non cambiarlo senza discussione in una issue prima.

**Config** — `.env` per i valori configurabili dall'utente (documentati in `.env.example`), config sorgenti in `config/`, script in `scripts/` (librerie condivise in `scripts/common/`).

## Licenza

Contribuendo accetti che i tuoi contributi siano rilasciati sotto `GPL-3.0-only` (vedi [LICENSE](LICENSE)).

## Governance

snapMULTI è attualmente mantenuto da un singolo maintainer principale (decisioni architetturali, code review, release). Le PR esterne passano dai CI gate (shellcheck, smoke gate per ADR-005, review automatica) e da una review umana prima del merge. Le PR Dependabot vengono chiuse via admin-squash dopo review del diff + release notes.

Il progetto ha forma intenzionalmente da appliance — vedi la sezione `## Non-goals` in [CLAUDE.md](CLAUDE.md) per cosa NON accettiamo come scope. Un "no" a una feature non è personale; di solito significa che il cambiamento appartiene a un layer diverso (l'amplificatore, Home Assistant, un deployment custom di snapclient) e non a snapMULTI stesso.

### Path verso co-maintainership

Aperto alla considerazione dopo che un contributor dimostra coinvolgimento sostenuto: diverse PR significative mergate, partecipazione attiva nella triage delle issue, comprensione del modello di update reflash-first ([DEC-003](docs/decisions/DEC-003-reflash-only-updates.md)) + smoke gate (ADR-005). Non è un automatismo — il maintainer principale decide. Se sei interessato, parti dalle issue aperte con label `help wanted`.

### Exit strategy

Se il maintainer principale si ritira, il progetto è progettato per essere auto-verificabile in modo che un successore possa continuare senza conoscenza tribale: `device-smoke.sh` + `fleet-smoke.sh` + `release-manifest.json` + la documentazione bilingue + la test suite permettono collettivamente a un nuovo contributor di rilevare regressioni e confermare che un deploy sia sano. Il percorso di fork è tecnicamente aperto. La continuità non è garantita ma le fondamenta ci sono.
