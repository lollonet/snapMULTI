# Contribuire a snapMULTI

Grazie per il tuo interesse per snapMULTI! Che si tratti di correggere un bug, aggiungere una funzionalità, migliorare la documentazione o semplicemente condividere il tuo setup — ogni contributo conta.

## Link rapidi

- [Issues](https://github.com/lollonet/snapMULTI/issues) — Segnalazioni di bug e richieste di funzionalità
- [Discussions](https://github.com/lollonet/snapMULTI/discussions) — Domande, idee, mostra il tuo setup
- [Security](SECURITY.md) — Segnalazione privata di vulnerabilità

## Come contribuire

### Segnalare un bug

Usa il [template Bug Report](https://github.com/lollonet/snapMULTI/issues/new?template=bug_report.yml). Includi:

- Il tuo hardware (modello Pi, x86_64, ecc.)
- Output di `docker compose ps` e `docker compose logs <servizio>`
- Passi per riprodurre il problema

### Suggerire una funzionalità

Usa il [template Feature Request](https://github.com/lollonet/snapMULTI/issues/new?template=feature_request.yml). Descrivi cosa vuoi, perché è utile e quali alternative hai considerato.

### Inviare codice

1. **Fai il fork** del repository e crea un branch da `main`:
   ```bash
   git checkout -b feature/mio-miglioramento
   ```

2. **Apporta le tue modifiche** — mantieni i commit focalizzati e atomici.

3. **Testa in locale:**
   ```bash
   # Script shell: lint con shellcheck
   shellcheck scripts/*.sh scripts/**/*.sh

   # Test bash (34 suite, 500+ assert)
   bash tests/run-all-tests.sh

   # Test Python dei plugin (pytest auto-discovera test_*.py sotto tests/)
   pytest tests/ -v

   # Docker: verifica la sintassi compose
   docker compose config --quiet

   # Stack completo: build e run
   docker compose build
   docker compose up -d
   docker compose ps   # tutti i container devono essere healthy
   ```

4. **Apri una Pull Request** verso `main`. La CI partirà automaticamente:
   - `validate.yml` — shellcheck + sintassi docker-compose
   - `build-test.yml` — validazione build Docker (no push)

### Migliorare la documentazione

La documentazione vive in:

| File | Contenuto |
|------|-----------|
| `README.md` | Cosa fa, come installare, come connettersi |
| `docs/INSTALL.md` | Procedura di prima installazione |
| `docs/HARDWARE.md` | Requisiti hardware, rete, setup consigliati |
| `docs/USAGE.md` | Architettura, servizi, sorgenti audio, deployment, CI/CD |
| `config/snapserver.conf` | Schema autorevole dei parametri sorgente (commenti inline) |

Le traduzioni italiane (`*.it.md`) rispecchiano i documenti inglesi. Se aggiorni la documentazione inglese, segnalalo nella PR così che le traduzioni possano essere sincronizzate.

### Condividere il tuo setup

Posta su [GitHub Discussions — Show Your Setup](https://github.com/lollonet/snapMULTI/discussions). Adoriamo vedere come la gente usa snapMULTI — foto del tuo setup di altoparlanti, configurazioni personalizzate, integrazioni Home Assistant o instradamenti audio creativi.

## Convenzioni di codice

### Script shell

- **Sicurezza prima**: tutti gli script iniziano con `set -euo pipefail`
- **Lint**: devono passare `shellcheck -S warning`
- **Logging**: usa le funzioni di `scripts/common/logging.sh` (`info`, `warn`, `error`)
- **Output console**: solo ASCII per `/dev/tty1` — i font PSF non hanno simboli Unicode

### Docker

- **Immagini base**: pinna versioni specifiche (es. `alpine:3.23`, non `alpine:latest`)
- **Sicurezza**: filesystem root in sola lettura, drop di tutte le capabilities, no-new-privileges
- **Healthcheck**: ogni container deve avere un health check
- **Multi-arch**: supporta sia `linux/amd64` che `linux/arm64`

### Configurazione

- **Formato audio**: 44100:16:2 (44.1kHz, 16-bit, stereo) — non cambiarlo senza discussione
- **File di config**: tutti in `config/`, tutti gli script in `scripts/`
- **Environment**: usa `.env` per i valori configurabili dall'utente, documenta in `.env.example`

### Documentazione

Segui il principio [Single Source of Truth](CLAUDE.md) — ogni argomento ha UN file autoritativo. Non duplicare contenuto tra documenti.

### Commit

- Scrivi messaggi di commit chiari che spiegano il **perché**, non solo cosa
- Cita le issue correlate: `Fix audio dropout su Pi 3 (#42)`
- Mantieni i commit focalizzati — un cambiamento logico per commit

## Setup di sviluppo

```bash
# Clona il monorepo (include server + client)
git clone https://github.com/lollonet/snapMULTI.git
cd snapMULTI

# Copia il template environment
cp .env.example .env
# Modifica .env con i tuoi path locali

# Avvia lo stack
docker compose up -d

# Guarda i log
docker compose logs -f
```

## Ottenere aiuto

- **Domande?** Apri una [Discussion](https://github.com/lollonet/snapMULTI/discussions)
- **Bug?** Apri una [Issue](https://github.com/lollonet/snapMULTI/issues)
- **Problema di sicurezza?** Vedi [SECURITY.md](SECURITY.md)

## Licenza

Contribuendo, accetti che i tuoi contributi siano rilasciati sotto `GPL-3.0-only` (vedi [LICENSE](LICENSE)).
