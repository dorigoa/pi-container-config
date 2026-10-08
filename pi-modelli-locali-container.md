# Pi con modelli locali, anche dentro un container (macOS e Ubuntu)

*Riepilogo della sessione dell'8 ottobre 2026 — Pi 1.1.0, Apple `container` 1.3.1, macOS 27.0.1 — `pi-box` 1.2*

---

## 0. Il quadro d'insieme

```
┌──────────────── host (Mac o PC Ubuntu) ─────────────────┐
│                                                         │
│  inference engine (llama.cpp, vLLM, …)                  │
│  in ascolto su 127.0.0.1:8080  ◄──────────┐             │
│                                           │ HTTP API    │
│  ┌──────── container (isolato) ────────┐  │ OpenAI-like │
│  │  Pi (coding agent)  ────────────────┼──┘             │
│  │  vede SOLO:                         │                │
│  │   /work               = cartella del progetto        │
│  │   /home/dev/.pi/agent = configurazione di Pi         │
│  └─────────────────────────────────────┘                │
└─────────────────────────────────────────────────────────┘
```

- **Pi** è l'"harness": il guscio che dà al modello quattro strumenti (read, write, edit, bash).
- **Il modello** gira fuori dal container, nella tua inference engine. Pi gli parla tramite l'API compatibile OpenAI.
- **Pi non ha un sistema di permessi**: qualunque comando decida di eseguire, lo esegue con i tuoi privilegi. Per questo conviene chiuderlo in un container.

File e cartelle usati in questa guida:

| Percorso | Contenuto |
|---|---|
| `~/.pi/agent/models.json` | configurazione dei modelli per Pi **senza** container |
| `~/pi-container/pi-box.conf` | parametri di default del launcher `pi-box` |
| `~/pi-container/agent/` | configurazione e sessioni di Pi **nel** container |
| `~/pi-container/image/Containerfile` | ricetta dell'immagine (la scrive `pi-box`) |
| `/usr/local/bin/pi-box` | il launcher (script in appendice) |

---

## 1. Pi direttamente sull'host (senza container)

### 1.1 Installazione (macOS e Linux)

Metodo consigliato dal progetto: l'installer fissa le versioni di tutte le dipendenze e, se serve, installa anche Node.js.

```bash
curl -fsSL https://pi.dev/install.sh | sh
pi --version
```

Alternativa con npm, che richiede Node.js **22.19 o successivo**:

```bash
npm install -g --ignore-scripts @earendil-works/pi-coding-agent
```

`--ignore-scripts` impedisce che gli script di installazione dei pacchetti npm vengano eseguiti, e riduce il rischio di dipendenze malevole. Pi funziona normalmente anche senza.

### 1.2 Trovare l'id del modello esposto dalla inference engine

```bash
curl -s http://127.0.0.1:8080/v1/models
```

Il valore del campo `"id"` va copiato in `models.json`. Su vLLM corrisponde a `--served-model-name`, su llama.cpp all'alias o al nome del file.

### 1.3 `~/.pi/agent/models.json`

```json
{
  "providers": {
    "local": {
      "baseUrl": "http://127.0.0.1:8080/v1",
      "api": "openai-completions",
      "apiKey": "local",
      "models": [
        {
          "id": "gemma-4-26b-a4b-it",
          "name": "Gemma 4 26B A4B (locale)",
          "reasoning": false,
          "input": ["text", "image"],
          "contextWindow": 32768,
          "maxTokens": 8192,
          "samplingParams": { "temperature": 1.0, "top_p": 0.95 }
        }
      ]
    }
  }
}
```

| Campo | Significato |
|---|---|
| `baseUrl` | indirizzo della inference engine, con `/v1` finale. Usa `127.0.0.1` e non `localhost`: Node può risolvere `localhost` su IPv6 (`::1`) e trovare la porta chiusa. |
| `api` | `openai-completions` va bene per llama.cpp, vLLM, Ollama, LM Studio e SGLang |
| `apiKey` | un valore fittizio è obbligatorio, altrimenti Pi considera il modello "non autenticato" e non lo mostra. Se il server richiede una chiave vera, mettila qui. |
| `id` | deve coincidere **esattamente** con quello restituito da `/v1/models` |
| `reasoning` | `true` se il modello ha la modalità "thinking" (ragionamento prima della risposta) |
| `input` | `["text"]` oppure `["text", "image"]` per i modelli multimodali |
| `contextWindow` | deve corrispondere al contesto del server (`-c` in llama.cpp, `--max-model-len` in vLLM) |
| `maxTokens` | lunghezza massima di una singola risposta |
| `samplingParams` | opzionale: `temperature`, `top_p`, `top_k`… passati così come sono al server |

La documentazione di Pi prevede anche `samplingParamsByThinkingLevel`, per usare parametri diversi a seconda del livello di thinking.

### 1.4 Avvio e scelta del modello

```bash
cd ~/progetti/mio-progetto
pi --provider local --model gemma-4-26b-a4b-it
```

Comandi utili dentro Pi:
- `/model` sceglie il modello; `Ctrl+S` sulla voce lo salva come default.
- `/thinking` imposta il livello di ragionamento. I valori sono `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`, e richiedono `"reasoning": true`.

Gli stessi valori si possono fissare da riga di comando (`--thinking high`) oppure in `~/.pi/agent/settings.json`:

```json
{
  "defaultProvider": "local",
  "defaultModel": "gemma-4-26b-a4b-it",
  "defaultThinkingLevel": "off",
  "enableInstallTelemetry": false
}
```

### 1.5 Alternativa per llama.cpp in modalità "router"

Se `llama-server` è avviato **senza** `-m`, cioè con `--models-dir`, Pi ha un'integrazione nativa e il `models.json` non serve:
- dentro Pi, `/login llama.cpp` collega il server;
- `/llama` carica e scarica i modelli.

---

## 2. Pi in un container

### 2.1 Cosa ottieni

- Pi vede e può modificare **solo** la cartella del progetto e la propria configurazione. Il resto della home, le chiavi SSH e i documenti restano fuori.
- Gira come utente **non-root** (`dev`), con lo stesso UID dell'utente dell'host. L'UID è il numero che identifica l'utente: averlo uguale fa sì che i file creati risultino tuoi.
- Su macOS ogni container è una **VM leggera** (macchina virtuale) separata: l'isolamento è più forte di Docker, dove i container condividono il kernel dell'host.

### 2.2 macOS: Apple `container` (una tantum)

`container` è lo strumento ufficiale di Apple, open source. **Non è preinstallato**, nemmeno su macOS 27. Richiede Apple silicon e macOS 26 o successivo.

**1. Scarica il pacchetto e verificane la firma:**

```bash
cd ~/Downloads
curl -fLO https://github.com/apple/container/releases/download/1.3.1/container-1.3.1-installer-signed.pkg
pkgutil --check-signature container-1.3.1-installer-signed.pkg
```

Il primo certificato deve essere `Developer ID Installer: Apple Inc. - Containerization`, con notarizzazione Apple.

**2. Installa e verifica la versione:**

```bash
sudo installer -pkg ~/Downloads/container-1.3.1-installer-signed.pkg -target /
container --version
```

**3. Avvia il servizio.** Al primo avvio chiede di installare il kernel Linux predefinito: rispondi `Y`.

```bash
container system start
```

**4. Rendi raggiungibile dai container il `127.0.0.1` del Mac.** Lo fa anche `pi-box` in automatico, se manca.

```bash
sudo container system dns create host.container.internal --localhost 203.0.113.113
container system dns list
```

Avvertenze, documentate da Apple:
- il dominio **disattiva iCloud Private Relay**;
- la regola di rete **si perde a ogni riavvio** del Mac, e `pi-box` la ricrea chiedendoti la password di `sudo`;
- `203.0.113.113` è un indirizzo riservato alla documentazione, usato solo internamente, e non va in conflitto con la tua rete.

**5. Test** (con l'inference engine in esecuzione):

```bash
container run --rm alpine/curl curl -s http://host.container.internal:8080/v1/models
```

### 2.3 Ubuntu (Linux): podman (una tantum)

Podman è nei repository ufficiali e funziona **rootless**, cioè senza privilegi di amministratore. Su Linux è la scelta più sicura; `pi-box` usa Docker solo se Podman manca.

```bash
sudo apt update && sudo apt install -y podman
podman --version
```

Su Linux `pi-box` avvia il container con `--network host`: il container condivide la rete dell'host e raggiunge direttamente un server in ascolto su `127.0.0.1`, senza altre configurazioni. Il prezzo è che **la rete non è isolata** (vedi §4).

Con Docker al posto di Podman, l'utente deve far parte del gruppo `docker`. Quel gruppo equivale di fatto a root, ed è per questo che Podman è preferibile.

### 2.4 L'immagine: un ambiente di sviluppo completo

`pi-box` scrive la ricetta in `~/pi-container/image/Containerfile` e costruisce l'immagine da sola: al primo avvio, e ogni volta che cambiano la ricetta, l'immagine base o le liste di pacchetti. Il file viene riscritto a ogni build, quindi **non va modificato a mano**: i pacchetti in più vanno indicati in `pi-box.conf` (§3.3). Lo script completo è in appendice.

Contenuto, oltre a Node.js e Pi:

| Area | Pacchetti |
|---|---|
| Strumenti | `git`, `ripgrep`, `fd`, `curl`, `wget`, `jq`, `file`, `unzip`, `xz-utils` |
| C/C++: compilatori e build | `build-essential` (gcc, g++, make), `clang`, `cmake`, `ninja-build`, `pkg-config`, `ccache`, `autoconf`, `automake`, `libtool` |
| C/C++: debug e analisi | `gdb`, `lldb`, `valgrind`, `clang-format`, `clang-tidy` |
| C/C++: librerie | Boost (header), Eigen, fmt, spdlog, nlohmann/json, GoogleTest e GoogleMock, OpenSSL, zlib, libcurl, SQLite, SDL2 |
| Python (dai pacchetti Debian) | numpy, scipy, matplotlib, pandas, sympy, scikit-learn, seaborn, networkx, pygame, Pillow, requests, PyYAML, BeautifulSoup, lxml, pytest, logzero |
| Python (da pip, `PIP_PACKAGES`) | ruff, mypy, rich, tqdm, click, httpx, ipython |

Le scelte principali:
- **Librerie scientifiche da Debian, non da pip**: arrivano già compilate per arm64 (Mac, Raspberry Pi) e x86_64, quindi la build non compila mai nulla.
- **Ambiente virtuale `/opt/venv`**, creato con `--system-site-packages`: vede le librerie Debian e accetta `pip install`, che su Debian a livello di sistema è bloccato. È già nel `PATH`, quindi `python3` e `pip` puntano lì.
- **Pygame e matplotlib senza schermo**: il container non ha display, per cui pygame usa il driver video "dummy" e matplotlib salva su file (`MPLBACKEND=Agg`). Pi può eseguire e testare un gioco; per vederne la finestra lo lanci sull'host.
- **Utente `dev` con il tuo UID**: se l'UID è già occupato nell'immagine base (l'utente `node` ha UID 1000, lo stesso dell'utente tipico di Ubuntu), quell'utente viene rimosso.

Un pacchetto installato da Pi durante una sessione (`pip install …`) **si perde all'uscita**, perché il container viene cancellato. Per renderlo permanente va aggiunto a `PIP_PACKAGES` o `APT_EXTRA`.

L'immagine `pi-agent:latest` costruita a mano durante la sessione aveva `ENTRYPOINT ["pi"]` e non è compatibile con `pi-box`, che usa una nuova immagine `pi-box:latest`. Puoi rimuovere la vecchia.

---

## 3. Avvio immediato con `pi-box` (macOS e Ubuntu)

### 3.1 Installazione del launcher

```bash
sudo install -m 755 pi-box /usr/local/bin/pi-box
pi-box --help
```

Il primo avvio crea `~/pi-container/pi-box.conf` con i valori di default.

### 3.2 Cosa fa a ogni avvio

1. Legge `pi-box.conf`, poi applica le opzioni da riga di comando, che hanno la precedenza.
2. Se non indichi il modello, lo **rileva** interrogando `BASE_URL/models`.
3. Rigenera `~/pi-container/agent/models.json`. Su macOS sostituisce `127.0.0.1`/`localhost` con `host.container.internal`; su Linux sostituisce `localhost` con `127.0.0.1`.
4. Solo su macOS: avvia il servizio `container` se è spento e crea il dominio DNS se manca.
5. Solo su Linux: applica `--cpus` e `--memory` solo se il kernel concede i relativi controlli dei cgroup, altrimenti li salta con un avviso. Con `--memory` imposta anche `--memory-swap` allo stesso valore, cioè nessuno swap aggiuntivo.
6. Costruisce l'immagine se non esiste o se ricetta, immagine base o pacchetti sono cambiati.
7. Avvia il container con Pi già collegato al modello: `pi --provider local --model … --thinking …`.

### 3.3 Parametri

| Opzione | Chiave in `pi-box.conf` | Default |
|---|---|---|
| `-u, --base-url URL` | `BASE_URL` | `http://127.0.0.1:8080/v1` (visto **dall'host**) |
| `-m, --model ID` | `MODEL_ID` | rilevato automaticamente |
| `-n, --name NOME` | `MODEL_NAME` | = id |
| `-c, --ctx N` | `CONTEXT_WINDOW` | `32768` |
| `-o, --max-tokens N` | `MAX_TOKENS` | `8192` |
| `-r, --reasoning on\|off` | `REASONING` | `off` |
| `-t, --thinking LIVELLO` | `THINKING` | `off` |
| `-i, --images` / `--no-images` | `IMAGES` | `false` |
| `--temperature`, `--top-p`, `--top-k` | `TEMPERATURE`, `TOP_P`, `TOP_K` | quelli del server |
| `--api-key CHIAVE` | `API_KEY` | `local` |
| `-p, --project DIR` | — | cartella corrente |
| `--cpus N`, `--memory M` | `CPUS`, `MEMORY` | `4`, `4g` (`""` = nessun limite) |
| — | `PI_VERSION` | `latest` (versione npm di Pi nell'immagine) |
| — | `BASE_IMAGE` | `node:24-slim` (es. `node:24-trixie-slim` per fissare Debian 13) |
| — | `APT_EXTRA` | pacchetti Debian aggiuntivi, separati da spazi |
| — | `PIP_PACKAGES` | `ruff mypy rich tqdm click httpx ipython` |
| `--rebuild` | — | ricostruisce l'immagine **da zero** (senza cache), poi avvia |
| `--build-only` | — | costruisce l'immagine se serve ed esce |
| `--shell` | — | apre `bash` nel container invece di Pi |
| `--dry-run` | — | mostra `models.json`, argomenti di build e comando, senza eseguire |
| `--reset-config` | — | riscrive `pi-box.conf` con i default (salva una copia) ed esce |
| `-V, --version` | — | versione di `pi-box` |
| `-- …` | — | argomenti passati a Pi (es. `-- --continue`) |

Per sicurezza `pi-box` rifiuta di montare come progetto la home o `/`. Per forzarlo serve `--force`.

### 3.4 Esempi

```bash
# Nella cartella del progetto, con modello e parametri da pi-box.conf
cd ~/src/mio-progetto && pi-box

# MacBook Air: Gemma 4 multimodale, contesto 64K
pi-box -m gemma-4-26b-a4b-it -i -c 65536

# Modello con thinking servito dal PC Ubuntu via 10GbE
pi-box -u http://192.168.1.20:8000/v1 -m qwen3.6-27b -r on -t high -p ~/src/mio-progetto

# Riprende l'ultima sessione
pi-box -- --continue

# Controlla cosa verrebbe fatto, senza eseguire nulla
pi-box --dry-run -m gemma-4-26b-a4b-it -i

# Ricostruisce l'immagine da zero, senza avviare Pi
pi-box --rebuild --build-only
```

Per aggiungere librerie in modo permanente, in `pi-box.conf`:

```bash
APT_EXTRA="libopencv-dev"
PIP_PACKAGES="ruff mypy rich tqdm click httpx ipython polars"
```

Al lancio successivo `pi-box` si accorge del cambiamento e ricostruisce l'immagine. Le liste accettano solo lettere, cifre e i simboli delle specifiche di versione (`== >= < [ ]` …): virgolette, `;`, `$`, `|`, `&` e simili vengono rifiutati.

Le sessioni di Pi vengono salvate in `~/pi-container/agent/sessions/` sull'host e sopravvivono alla cancellazione del container.

---

## 4. Cosa protegge il container e cosa no

| | Protetto | Non protetto |
|---|---|---|
| **File** | Pi vede solo il progetto e la propria configurazione | il progetto stesso: Pi può cancellarlo o rovinarlo, quindi tienilo sotto `git` |
| **Privilegi** | utente non-root; su macOS anche VM separata | dentro il container Pi può installare ed eseguire qualunque cosa |
| **Rete (macOS)** | — | accesso a Internet e alla LAN (la rete locale). Con il dominio `host.container.internal` raggiunge **tutti** i servizi in ascolto su `127.0.0.1` del Mac, non solo la porta 8080 |
| **Rete (Linux)** | — | con `--network host` vede tutta la rete dell'host, servizi locali compresi |
| **Esfiltrazione** | — | il contenuto del progetto potrebbe essere inviato all'esterno (es. da un'estensione di Pi malevola) |

In pratica l'isolamento difende la tua home e il sistema da errori o comandi distruttivi dell'agente. Non è un isolamento di rete.

---

## 5. Problemi comuni

| Sintomo | Causa e rimedio |
|---|---|
| Il modello non compare in `/model` | `apiKey` mancante, oppure `id` diverso da quello di `/v1/models` |
| `connection refused` verso `localhost` | usa `127.0.0.1` (§1.3) |
| macOS, dopo un riavvio il container non raggiunge il server | il dominio DNS è stato perso: `pi-box` lo ricrea (chiede `sudo`) |
| macOS, `container: command not found` | pacchetto non installato o terminale aperto prima dell'installazione |
| Linux/podman: `container create failed (no logs from conmon)` oppure `runc … memory.max: no such file or directory` | il controllo della memoria dei *cgroup* (meccanismo del kernel per i limiti di risorse) non è disponibile. Sui Raspberry Pi il firmware aggiunge `cgroup_disable=memory` ai parametri di avvio: verifica con `cat /proc/cmdline`. Da `pi-box` 1.1 il limite viene saltato in automatico con un avviso; per non vederlo metti `MEMORY=""` in `pi-box.conf`. In alternativa aggiungi `cgroup_enable=memory cgroup_memory=1` in fondo all'unica riga di `/boot/firmware/cmdline.txt` (dopo averne fatto un backup) e riavvia. |
| Le risposte si troncano o il contesto si riempie presto | allinea `CONTEXT_WINDOW` al server. Pi riserva per default 16.384 token alla risposta (`compaction.reserveTokens` in `settings.json`): con contesti piccoli conviene ridurlo. |
| `pi --print` in uno script resta in attesa | Pi legge lo standard input finché non si chiude: aggiungi `</dev/null` |
| Modifiche manuali a `~/pi-container/agent/models.json` perse | il file viene rigenerato a ogni avvio: modifica `pi-box.conf` |

---

## 6. Stato di verifica

Per distinguere ciò che è stato **provato** da ciò che è solo **scritto**:

| Elemento | Stato |
|---|---|
| Apple `container` 1.3.1: firma, installazione, `system start`, dominio DNS, `curl` dal container al server sul Mac | **verificato** sul MacBook Air M5 |
| Build manuale dell'immagine `pi-agent` | eseguita sul Mac; avvio di Pi nel container **non ancora confermato** |
| `pi-box`: sintassi, `shellcheck`, validazione degli input, `--dry-run` per container/podman/docker, simulazione completa del flusso macOS con un runtime finto | **verificato** (Linux, bash 5.2) |
| `models.json` generato da `pi-box` accettato da Pi 1.1.0 (`pi --list-models`) | **verificato** |
| Pi 1.1.0 → server OpenAI simulato: endpoint, chiave, `max_tokens`, `samplingParams` e i 4 tool arrivano correttamente | **verificato** |
| `pi-box` con runtime reali (Apple `container`, podman, docker) | **non verificato** |
| Esecuzione con la bash 3.2 di macOS | scritto per essere compatibile, **non eseguito** |
| Raspberry Pi 5, podman 5.4.2 (runc): container di base e `--userns=keep-id` | **verificato** |
| Raspberry Pi 5: `--memory` | **fallisce** per `cgroup_disable=memory`; `pi-box` 1.1 lo rileva e lo salta |
| `pi-box` 1.2: build, salto della build se nulla è cambiato, ricostruzione automatica, `--rebuild` senza cache, validazione delle liste, `--reset-config` (runtime finti); comando di avvio identico alla 1.1 | **verificato** (Linux, bash 5.2) |
| Pacchetti dell'immagine: esistenza dei nomi negli archivi di Ubuntu 24.04 (derivata da Debian) e wheel pip per arm64/x86_64 con Python 3.11 e 3.13 | **verificato** |
| Stack Python (venv con librerie di sistema, `pip install`, numpy/scipy/pandas/matplotlib, pygame senza schermo, logzero) | **verificato** su Ubuntu 24.04, non nell'immagine |
| Stack C/C++: progetto CMake con fmt, spdlog, Eigen, nlohmann/json, Boost, SDL2 e GoogleTest compilato con g++ e clang++ | **verificato** su Ubuntu 24.04, non nell'immagine |
| Build reale dell'immagine 1.2 | **non verificata** |
| `pi-box` 1.1: rilevamento dei controller (podman, docker, lettura diretta da `/sys/fs/cgroup`) con runtime finti; comportamento su macOS identico alla 1.0 | **verificato** (Linux, bash 5.2) |

---

## 7. Riferimenti

- Pi — https://pi.dev · https://github.com/earendil-works/pi
- Pi: modelli e `models.json` — https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/models.md
- Pi: riga di comando — https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/cli.md
- Pi: impostazioni — https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/settings.md
- Pi: llama.cpp — https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/llama-cpp.md
- Apple `container` — https://github.com/apple/container
- Apple `container`: accesso ai servizi dell'host — https://github.com/apple/container/blob/main/docs/host-integration.md

---

## Appendice — script `pi-box`

Salvalo come `pi-box` (o `pi-box.sh`) e installalo come in §3.1.

```bash
#!/usr/bin/env bash
# pi-box — avvia Pi (coding agent) dentro un container isolato, collegato a un
# modello locale servito da una inference engine compatibile OpenAI
# (llama.cpp, vLLM, Ollama, LM Studio, ...).
#
# Runtime supportati:
#   macOS  -> Apple `container` (https://github.com/apple/container)
#   Linux  -> podman (preferito) oppure docker
#
# Compatibile con la bash 3.2 di macOS.
#
# Versione 1.2 (2026-10-08)
#   - Immagine di sviluppo completa: C/C++ (gcc, clang, cmake, gdb, valgrind,
#     librerie comuni) e Python (numpy, scipy, pygame, logzero, ...) in un
#     ambiente virtuale che accetta anche `pip install`.
#   - APT_EXTRA e PIP_PACKAGES in pi-box.conf per aggiungere pacchetti.
#   - L'immagine viene ricostruita da sola quando cambiano Containerfile,
#     immagine base o liste di pacchetti; --rebuild la ricostruisce da zero.
#   - --reset-config riscrive pi-box.conf con i valori di default.
# Versione 1.1
#   - Linux: --cpus/--memory solo se il kernel concede i controller dei cgroup;
#     --memory-swap uguale a --memory. "localhost" -> 127.0.0.1.
set -euo pipefail

PI_BOX_VERSION="1.2"
PI_BOX_HOME="${PI_BOX_HOME:-$HOME/pi-container}"
CGROUP_ROOT="${PI_BOX_CGROUP_ROOT:-/sys/fs/cgroup}"   # sovrascrivibile solo per i test
CONF_FILE="$PI_BOX_HOME/pi-box.conf"
AGENT_DIR="$PI_BOX_HOME/agent"
IMAGE_DIR="$PI_BOX_HOME/image"
STAMP_FILE="$IMAGE_DIR/.build-stamp"

die()  { printf 'pi-box: ERRORE: %s\n' "$*" >&2; exit 1; }
info() { printf 'pi-box: %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# Valori di default (sovrascritti da pi-box.conf, poi dalle opzioni CLI)
# ---------------------------------------------------------------------------
BASE_URL="http://127.0.0.1:8080/v1"   # URL della inference engine VISTO DALL'HOST
MODEL_ID=""                           # vuoto = rilevamento automatico da /v1/models
MODEL_NAME=""                         # nome mostrato in Pi (default = MODEL_ID)
API_KEY="local"                       # fittizia per server locali senza autenticazione
CONTEXT_WINDOW=32768                  # deve coincidere con il contesto del server
MAX_TOKENS=8192                       # token massimi per risposta
REASONING=false                       # true se il modello supporta il "thinking"
THINKING=off                          # off|minimal|low|medium|high|xhigh|max
IMAGES=false                          # true se il modello accetta immagini
TEMPERATURE=""                        # vuoto = default del server
TOP_P=""
TOP_K=""
CPUS=4                                # vuoto = nessun limite
MEMORY=4g                             # vuoto = nessun limite
OFFLINE=true                          # disattiva l'attività di rete automatica di Pi
IMAGE="pi-box:latest"
PI_VERSION="latest"                   # versione npm di Pi da installare nell'immagine
BASE_IMAGE="node:24-slim"             # immagine di partenza (Debian + Node.js)
APT_EXTRA=""                          # pacchetti Debian aggiuntivi
PIP_PACKAGES="ruff mypy rich tqdm click httpx ipython"   # pacchetti pip aggiuntivi

write_default_conf() {
  mkdir -p "$PI_BOX_HOME"
  cat > "$CONF_FILE" <<'EOF'
# Configurazione di pi-box (sintassi bash). Le opzioni da riga di comando
# hanno la precedenza su questi valori.

# --- Modello e inference engine ---------------------------------------------
BASE_URL="http://127.0.0.1:8080/v1"   # URL della inference engine visto dall'host
MODEL_ID=""                           # vuoto = rilevamento automatico
MODEL_NAME=""
API_KEY="local"
CONTEXT_WINDOW=32768
MAX_TOKENS=8192
REASONING=false                       # true per modelli con thinking
THINKING=off                          # off|minimal|low|medium|high|xhigh|max
IMAGES=false
TEMPERATURE=""
TOP_P=""
TOP_K=""

# --- Container ----------------------------------------------------------------
CPUS=4                                # "" = nessun limite
MEMORY=4g                             # "" = nessun limite
OFFLINE=true

# --- Immagine (una modifica qui provoca la ricostruzione automatica) ---------
IMAGE="pi-box:latest"
PI_VERSION="latest"
BASE_IMAGE="node:24-slim"             # es. node:24-trixie-slim per fissare Debian 13
# Pacchetti Debian aggiuntivi, separati da spazi (es. "libopencv-dev octave")
APT_EXTRA=""
# Pacchetti pip aggiuntivi, installati in /opt/venv (es. "polars torch==2.5.1")
PIP_PACKAGES="ruff mypy rich tqdm click httpx ipython"
EOF
  info "scritto il file di configurazione $CONF_FILE"
}

usage() {
  cat <<'EOF'
Uso: pi-box [opzioni] [-- argomenti aggiuntivi per pi]

Modello e inference engine
  -u, --base-url URL      URL della inference engine visto dall'host
                          (es. http://127.0.0.1:8080/v1, http://192.168.1.20:8000/v1)
  -m, --model ID          id del modello (default: rilevato da URL/models)
  -n, --name NOME         nome mostrato in Pi
  -c, --ctx N             context window in token
  -o, --max-tokens N      token massimi per risposta
  -r, --reasoning on|off  il modello supporta il thinking
  -t, --thinking LIVELLO  off|minimal|low|medium|high|xhigh|max
  -i, --images            il modello accetta immagini
      --no-images         solo testo
      --temperature X     parametri di campionamento (opzionali)
      --top-p X
      --top-k N
      --api-key CHIAVE    se il server richiede una chiave

Container
  -p, --project DIR       cartella del progetto montata in /work (default: cartella corrente)
      --cpus N            limite CPU ("" = nessuno)
      --memory M          limite RAM, es. 4g ("" = nessuno)
      --rebuild           ricostruisce l'immagine da zero (senza cache) e poi avvia
      --build-only        (ri)costruisce l'immagine se serve ed esce
      --shell             apre una shell bash nel container invece di Pi
      --dry-run           mostra configurazione e comando senza eseguire nulla
      --reset-config      riscrive pi-box.conf con i default (salva una copia) ed esce
      --force             consente di montare la home o / (sconsigliato)
  -V, --version           versione di pi-box
  -h, --help              questo aiuto

Esempi
  pi-box
  pi-box -m gemma-4-26b-a4b-it -i -c 65536
  pi-box -u http://192.168.1.20:8000/v1 -m qwen3.6-27b -r on -t high -p ~/src/progetto
  pi-box --rebuild --build-only
  pi-box -- --continue
EOF
}

# --version, --help e --reset-config vengono gestiti prima di leggere (o creare)
# il file di configurazione, che potrebbe anche essere rotto
for a in "$@"; do
  [ "$a" = "--" ] && break
  case "$a" in
    -V|--version) printf 'pi-box %s\n' "$PI_BOX_VERSION"; exit 0 ;;
    -h|--help)    NEED_HELP=true ;;
  esac
  if [ "$a" = "--reset-config" ]; then
    if [ -f "$CONF_FILE" ]; then
      bak="$CONF_FILE.bak-$(date +%Y%m%d-%H%M%S)"
      cp -p "$CONF_FILE" "$bak"
      info "copia di sicurezza della configurazione precedente: $bak"
    fi
    write_default_conf
    exit 0
  fi
done

if [ "${NEED_HELP:-false}" = true ]; then usage; exit 0; fi

if [ -f "$CONF_FILE" ]; then
  # shellcheck source=/dev/null
  . "$CONF_FILE"
else
  write_default_conf
fi


need_arg() { [ "$#" -ge 2 ] && [ -n "$2" ] || die "l'opzione $1 richiede un valore"; }

PROJECT="$PWD"
DO_REBUILD=false
BUILD_ONLY=false
DO_SHELL=false
DRY_RUN=false
FORCE=false
PI_ARGS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    -u|--base-url)   need_arg "$@"; BASE_URL="$2"; shift 2 ;;
    -m|--model)      need_arg "$@"; MODEL_ID="$2"; shift 2 ;;
    -n|--name)       need_arg "$@"; MODEL_NAME="$2"; shift 2 ;;
    -c|--ctx)        need_arg "$@"; CONTEXT_WINDOW="$2"; shift 2 ;;
    -o|--max-tokens) need_arg "$@"; MAX_TOKENS="$2"; shift 2 ;;
    -r|--reasoning)  need_arg "$@"; REASONING="$2"; shift 2 ;;
    -t|--thinking)   need_arg "$@"; THINKING="$2"; shift 2 ;;
    -i|--images)     IMAGES=true; shift ;;
    --no-images)     IMAGES=false; shift ;;
    --temperature)   need_arg "$@"; TEMPERATURE="$2"; shift 2 ;;
    --top-p)         need_arg "$@"; TOP_P="$2"; shift 2 ;;
    --top-k)         need_arg "$@"; TOP_K="$2"; shift 2 ;;
    --api-key)       need_arg "$@"; API_KEY="$2"; shift 2 ;;
    -p|--project)    need_arg "$@"; PROJECT="$2"; shift 2 ;;
    --cpus)          [ "$#" -ge 2 ] || die "--cpus richiede un valore"; CPUS="$2"; shift 2 ;;
    --memory)        [ "$#" -ge 2 ] || die "--memory richiede un valore"; MEMORY="$2"; shift 2 ;;
    --rebuild)       DO_REBUILD=true; shift ;;
    --build-only)    BUILD_ONLY=true; shift ;;
    --shell)         DO_SHELL=true; shift ;;
    --dry-run)       DRY_RUN=true; shift ;;
    --force)         FORCE=true; shift ;;
    -V|--version)    printf 'pi-box %s\n' "$PI_BOX_VERSION"; exit 0 ;;
    -h|--help)       usage; exit 0 ;;
    --)              shift; PI_ARGS=("$@"); break ;;
    *)               die "opzione sconosciuta: $1 (vedi --help)" ;;
  esac
done

# ---------------------------------------------------------------------------
# Validazione (i valori finiscono in JSON e nel Containerfile: niente
# caratteri pericolosi)
# ---------------------------------------------------------------------------
re_url='^https?://[^"\\[:space:]]+$'
re_int='^[0-9]+$'
re_num='^[0-9]+(\.[0-9]+)?$'
re_id='^[A-Za-z0-9._:/@+-]+$'
re_mem='^[0-9]+[kKmMgG]?$'
re_safe='^[^"\\]*$'
re_image='^[A-Za-z0-9._/:@-]+$'
re_pkgs='^[]A-Za-z0-9._+=<>!~,:@/ [-]*$'

[[ $BASE_URL =~ $re_url ]]       || die "base URL non valido: $BASE_URL"
[[ $CONTEXT_WINDOW =~ $re_int ]] || die "--ctx deve essere un intero"
[[ $MAX_TOKENS =~ $re_int ]]     || die "--max-tokens deve essere un intero"
[ "$MAX_TOKENS" -lt "$CONTEXT_WINDOW" ] || die "--max-tokens deve essere minore di --ctx"
[[ $API_KEY =~ $re_safe ]]       || die "la API key non può contenere \" o \\"
[ -z "$TEMPERATURE" ] || [[ $TEMPERATURE =~ $re_num ]] || die "--temperature non valida"
[ -z "$TOP_P" ]       || [[ $TOP_P =~ $re_num ]]       || die "--top-p non valido"
[ -z "$TOP_K" ]       || [[ $TOP_K =~ $re_int ]]       || die "--top-k non valido"
[ -z "$CPUS" ]        || [[ $CPUS =~ $re_int ]]        || die "--cpus deve essere un intero"
[ -z "$MEMORY" ]      || [[ $MEMORY =~ $re_mem ]]      || die "--memory non valido (es. 4g)"
[[ $IMAGE =~ $re_image ]]        || die "IMAGE non valido: $IMAGE"
[[ $BASE_IMAGE =~ $re_image ]]   || die "BASE_IMAGE non valido: $BASE_IMAGE"
[[ $PI_VERSION =~ $re_id ]]      || die "PI_VERSION non valido: $PI_VERSION"
[[ $APT_EXTRA =~ $re_pkgs ]]     || die "APT_EXTRA contiene caratteri non ammessi"
[[ $PIP_PACKAGES =~ $re_pkgs ]]  || die "PIP_PACKAGES contiene caratteri non ammessi"

case "$REASONING" in
  on|true|yes|1)   REASONING=true ;;
  off|false|no|0)  REASONING=false ;;
  *) die "--reasoning accetta on|off" ;;
esac
case "$THINKING" in
  off|minimal|low|medium|high|xhigh|max) ;;
  *) die "--thinking accetta off|minimal|low|medium|high|xhigh|max" ;;
esac
if [ "$REASONING" = false ] && [ "$THINKING" != off ]; then
  info "attenzione: thinking=$THINKING ma reasoning=off -> Pi lo ridurrà a 'off'"
fi

if [ "$BUILD_ONLY" = false ]; then
  [ -d "$PROJECT" ] || die "la cartella del progetto non esiste: $PROJECT"
  PROJECT="$(cd "$PROJECT" && pwd -P)"
  HOME_REAL="$(cd "$HOME" && pwd -P)"
  if [ "$FORCE" = false ]; then
    case "$PROJECT" in
      /|"$HOME_REAL") die "montare $PROJECT annullerebbe l'isolamento; usa una sottocartella o --force" ;;
    esac
  fi
fi

# ---------------------------------------------------------------------------
# Runtime dei container
# ---------------------------------------------------------------------------
if [ -n "${PI_BOX_RUNTIME:-}" ]; then
  RT="$PI_BOX_RUNTIME"
else
  case "$(uname -s)" in
    Darwin) RT=container ;;
    Linux)
      if command -v podman >/dev/null 2>&1; then RT=podman
      elif command -v docker >/dev/null 2>&1; then RT=docker
      else die "nessun runtime trovato: installa podman (sudo apt install podman) o docker"
      fi ;;
    *) die "sistema operativo non supportato: $(uname -s)" ;;
  esac
fi
case "$RT" in container|podman|docker) ;; *) die "runtime non supportato: $RT" ;; esac
if [ "$DRY_RUN" = false ]; then
  command -v "$RT" >/dev/null 2>&1 || die "comando '$RT' non trovato"
fi

# Su macOS il container non vede il localhost del Mac: si usa il dominio
# host.container.internal. Su Linux si usa la rete dell'host (--network host);
# "localhost" diventa 127.0.0.1 perché Node potrebbe risolverlo in ::1 (IPv6)
# e non trovare un server in ascolto solo su IPv4.
CONTAINER_BASE_URL="$BASE_URL"
if [ "$RT" = container ]; then
  re_loop='^(https?://)(127\.0\.0\.1|localhost|\[::1\])([:/].*)?$'
  if [[ $BASE_URL =~ $re_loop ]]; then
    CONTAINER_BASE_URL="${BASH_REMATCH[1]}host.container.internal${BASH_REMATCH[3]}"
  fi
else
  re_lh='^(https?://)localhost([:/].*)?$'
  if [[ $BASE_URL =~ $re_lh ]]; then
    CONTAINER_BASE_URL="${BASH_REMATCH[1]}127.0.0.1${BASH_REMATCH[2]}"
  fi
fi

# ---------------------------------------------------------------------------
# Modello: rilevamento automatico se non specificato
# ---------------------------------------------------------------------------
detect_model() {
  command -v curl >/dev/null 2>&1 || return 1
  local body
  body="$(curl -fsS --max-time 5 "${BASE_URL%/}/models")" || return 1
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$body" | jq -r '.data[0].id // empty'
  else
    printf '%s' "$body" | tr ',' '\n' | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
  fi
}

if [ "$BUILD_ONLY" = false ]; then
  if [ -z "$MODEL_ID" ]; then
    MODEL_ID="$(detect_model || true)"
    [ -n "$MODEL_ID" ] || die "impossibile rilevare il modello da ${BASE_URL%/}/models: indicalo con --model"
    info "modello rilevato: $MODEL_ID"
  fi
  [[ $MODEL_ID =~ $re_id ]] || die "id del modello non valido: $MODEL_ID"
  [ -n "$MODEL_NAME" ] || MODEL_NAME="$MODEL_ID"
  [[ $MODEL_NAME =~ $re_safe ]] || die "il nome del modello non può contenere \" o \\"
fi

# ---------------------------------------------------------------------------
# File di configurazione di Pi (rigenerati a ogni avvio)
# ---------------------------------------------------------------------------
models_json() {
  local input='["text"]' sampling="" extra=""
  if [ "$IMAGES" = true ]; then input='["text", "image"]'; fi
  if [ -n "$TEMPERATURE" ]; then sampling="${sampling:+$sampling, }\"temperature\": $TEMPERATURE"; fi
  if [ -n "$TOP_P" ];       then sampling="${sampling:+$sampling, }\"top_p\": $TOP_P"; fi
  if [ -n "$TOP_K" ];       then sampling="${sampling:+$sampling, }\"top_k\": $TOP_K"; fi
  if [ -n "$sampling" ]; then
    extra=",
          \"samplingParams\": { $sampling }"
  fi
  cat <<EOF
{
  "providers": {
    "local": {
      "baseUrl": "$CONTAINER_BASE_URL",
      "api": "openai-completions",
      "apiKey": "$API_KEY",
      "models": [
        {
          "id": "$MODEL_ID",
          "name": "$MODEL_NAME",
          "reasoning": $REASONING,
          "input": $input,
          "contextWindow": $CONTEXT_WINDOW,
          "maxTokens": $MAX_TOKENS$extra
        }
      ]
    }
  }
}
EOF
}

write_agent_config() {
  mkdir -p "$AGENT_DIR"
  local tmp="$AGENT_DIR/.models.json.tmp"
  models_json > "$tmp"
  if command -v jq >/dev/null 2>&1; then
    jq empty "$tmp" 2>/dev/null || { rm -f "$tmp"; die "models.json generato non valido (bug dello script)"; }
  fi
  mv -f "$tmp" "$AGENT_DIR/models.json"
  if [ ! -f "$AGENT_DIR/settings.json" ]; then
    printf '{\n  "enableInstallTelemetry": false\n}\n' > "$AGENT_DIR/settings.json"
  fi
}

# ---------------------------------------------------------------------------
# Immagine del container
# ---------------------------------------------------------------------------
containerfile() {
  cat <<'EOF'
# Generato da pi-box: NON modificare a mano, viene riscritto a ogni build.
# Per aggiungere pacchetti usa APT_EXTRA e PIP_PACKAGES in pi-box.conf.
ARG BASE_IMAGE=node:24-slim
FROM ${BASE_IMAGE}
ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8

# --- Strumenti di base --------------------------------------------------------
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git ripgrep fd-find curl wget ca-certificates less procps file \
      unzip xz-utils jq \
 && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
 && rm -rf /var/lib/apt/lists/*

# --- C / C++: compilatori, build system, debugger, analisi, librerie comuni ---
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential gdb cmake ninja-build pkg-config ccache \
      clang clang-format clang-tidy lldb valgrind \
      autoconf automake libtool \
      libboost-dev libeigen3-dev libfmt-dev libspdlog-dev nlohmann-json3-dev \
      libgtest-dev libgmock-dev libssl-dev zlib1g-dev libcurl4-openssl-dev \
      libsqlite3-dev libsdl2-dev \
 && rm -rf /var/lib/apt/lists/*

# --- Python con le librerie precompilate di Debian (nessuna compilazione) -----
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      python3 python3-dev python3-venv python3-pip \
      python3-numpy python3-scipy python3-matplotlib python3-pandas \
      python3-sympy python3-sklearn python3-seaborn python3-networkx \
      python3-pygame python3-pil python3-requests python3-yaml \
      python3-bs4 python3-lxml python3-pytest python3-logzero \
 && rm -rf /var/lib/apt/lists/*

# --- Pacchetti Debian aggiuntivi (APT_EXTRA) ------------------------------------
ARG APT_EXTRA=""
RUN set -f; if [ -n "$APT_EXTRA" ]; then \
      apt-get update \
      && apt-get install -y --no-install-recommends $APT_EXTRA \
      && rm -rf /var/lib/apt/lists/*; \
    fi

# --- Pi (--ignore-scripts: nessuno script di installazione npm eseguito) -------
ARG PI_VERSION=latest
RUN npm install -g --ignore-scripts "@earendil-works/pi-coding-agent@${PI_VERSION}" \
 && npm cache clean --force

# --- Utente non-root con lo stesso UID dell'utente dell'host ------------------
# Se l'UID è già usato (es. l'utente "node" con UID 1000), quell'utente viene rimosso.
ARG USER_UID=1000
RUN set -e; \
    old="$(getent passwd "$USER_UID" | cut -d: -f1)" || true; \
    if [ -n "$old" ] && [ "$old" != root ]; then userdel -r "$old" >/dev/null 2>&1 || true; fi; \
    if getent passwd "$USER_UID" >/dev/null; then \
      echo "UID $USER_UID ancora occupato" >&2; exit 1; \
    fi; \
    useradd -u "$USER_UID" -m -s /bin/bash dev

# --- Ambiente virtuale Python: vede le librerie Debian e accetta pip install ---
RUN python3 -m venv --system-site-packages /opt/venv \
 && chown -R dev:dev /opt/venv \
 && printf '%s\n' 'export PATH="/opt/venv/bin:$PATH"' > /etc/profile.d/venv.sh

USER dev
ENV HOME=/home/dev \
    PATH=/opt/venv/bin:$PATH \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    MPLBACKEND=Agg \
    SDL_VIDEODRIVER=dummy \
    SDL_AUDIODRIVER=dummy \
    PYGAME_HIDE_SUPPORT_PROMPT=1

# --- Pacchetti pip aggiuntivi (PIP_PACKAGES) ------------------------------------
ARG PIP_PACKAGES=""
RUN set -f; if [ -n "$PIP_PACKAGES" ]; then pip install --no-cache-dir $PIP_PACKAGES; fi

WORKDIR /work
CMD ["pi"]
EOF
}

IMAGE_UID="$(id -u)"
if [ "$IMAGE_UID" -eq 0 ]; then
  IMAGE_UID=1000   # mai creare l'utente del container con UID 0 (root)
fi

build_args() {
  printf '%s\n' \
    "BASE_IMAGE=$BASE_IMAGE" \
    "APT_EXTRA=$APT_EXTRA" \
    "PI_VERSION=$PI_VERSION" \
    "USER_UID=$IMAGE_UID" \
    "PIP_PACKAGES=$PIP_PACKAGES"
}

# Impronta di tutto ciò che determina l'immagine
build_stamp() {
  { containerfile; build_args; printf 'runtime=%s image=%s\n' "$RT" "$IMAGE"; } | cksum | awk '{print $1 "-" $2}'
}

image_exists() {
  case "$RT" in
    container) container image inspect "$IMAGE" >/dev/null 2>&1 ;;
    podman)    podman image exists "$IMAGE" ;;
    docker)    docker image inspect "$IMAGE" >/dev/null 2>&1 ;;
  esac
}

# Stampa il motivo per cui serve una build, oppure niente
build_reason() {
  if [ "$DO_REBUILD" = true ]; then echo "richiesta con --rebuild (da zero, senza cache)"; return; fi
  if ! image_exists; then echo "immagine $IMAGE assente"; return; fi
  if [ ! -f "$STAMP_FILE" ] || [ "$(cat "$STAMP_FILE")" != "$(build_stamp)" ]; then
    echo "Containerfile o pacchetti cambiati"
  fi
}

build_image() {
  mkdir -p "$IMAGE_DIR"
  containerfile > "$IMAGE_DIR/Containerfile"
  local args=(build --tag "$IMAGE" --file "$IMAGE_DIR/Containerfile") line
  while IFS= read -r line; do args+=(--build-arg "$line"); done < <(build_args)
  if [ "$DO_REBUILD" = true ]; then
    local help
    help="$("$RT" build --help 2>&1 || true)"
    case "$help" in
      *--no-cache*) args+=(--no-cache) ;;
      *) info "attenzione: '$RT build' non supporta --no-cache, uso la cache" ;;
    esac
    case "$RT" in
      podman) args+=(--pull=always) ;;
      docker) args+=(--pull) ;;
    esac
  fi
  args+=("$IMAGE_DIR")
  info "costruisco l'immagine $IMAGE con $RT: può richiedere parecchi minuti..."
  rm -f "$STAMP_FILE"
  "$RT" "${args[@]}"
  build_stamp > "$STAMP_FILE"
  info "immagine $IMAGE pronta"
}

# ---------------------------------------------------------------------------
# Preparazione specifica di macOS
# ---------------------------------------------------------------------------
macos_prepare() {
  if ! container list >/dev/null 2>&1; then
    info "avvio del servizio container..."
    container system start
  fi
  case "$CONTAINER_BASE_URL" in
    *://host.container.internal*)
      local domains
      domains="$(container system dns list 2>/dev/null || true)"
      if ! printf '%s\n' "$domains" | grep -Eq '^host\.container\.internal[[:space:]]*$'; then
        info "creo il dominio host.container.internal (richiede sudo; va ricreato dopo ogni riavvio del Mac)"
        sudo container system dns create host.container.internal --localhost 203.0.113.113
      fi ;;
  esac
}

# ---------------------------------------------------------------------------
# Limiti di risorse su Linux
# ---------------------------------------------------------------------------
# Stampa i controller dei cgroup v2 utilizzabili dai container, separati da
# spazi; non stampa nulla se non è possibile determinarli.
linux_cgroup_controllers() {
  local out="" f uid
  uid="$(id -u)"
  case "$RT" in
    podman)
      out="$(podman info --format '{{.Host.CgroupControllers}}' 2>/dev/null || true)"
      out="$(printf '%s' "$out" | tr -d '[]')"
      ;;
    docker)
      local mem cpu
      if read -r mem cpu < <(docker info --format '{{.MemoryLimit}} {{.CPUCfsQuota}}' 2>/dev/null) \
         && [ -n "${cpu:-}" ]; then
        out="pids"
        if [ "$mem" = true ]; then out="$out memory"; fi
        if [ "$cpu" = true ]; then out="$out cpu"; fi
      fi
      ;;
  esac
  if [ -z "$out" ]; then
    # podman senza root usa i controller delegati da systemd all'utente
    if [ "$RT" = podman ] && [ "$uid" -ne 0 ]; then
      f="$CGROUP_ROOT/user.slice/user-$uid.slice/user@$uid.service/cgroup.controllers"
    else
      f="$CGROUP_ROOT/cgroup.controllers"
    fi
    if [ -r "$f" ]; then out="$(cat "$f")"; fi
  fi
  printf '%s' "$out" | tr -s '[:space:]' ' '
}

add_linux_limits() {
  [ -n "$CPUS" ] || [ -n "$MEMORY" ] || return 0
  local ctrls
  ctrls=" $(linux_cgroup_controllers) "
  if [ -z "${ctrls// /}" ]; then
    info "attenzione: impossibile verificare i cgroup, applico comunque i limiti richiesti"
    if [ -n "$CPUS" ];   then RUN_ARGS+=(--cpus "$CPUS"); fi
    if [ -n "$MEMORY" ]; then RUN_ARGS+=(--memory "$MEMORY" --memory-swap "$MEMORY"); fi
    return 0
  fi
  if [ -n "$CPUS" ]; then
    case "$ctrls" in
      *" cpu "*) RUN_ARGS+=(--cpus "$CPUS") ;;
      *) info "attenzione: il controller 'cpu' dei cgroup non è disponibile: avvio senza limite di CPU (per non vedere l'avviso: CPUS=\"\" in $CONF_FILE)" ;;
    esac
  fi
  if [ -n "$MEMORY" ]; then
    case "$ctrls" in
      *" memory "*) RUN_ARGS+=(--memory "$MEMORY" --memory-swap "$MEMORY") ;;
      *) info "attenzione: il controller 'memory' dei cgroup non è disponibile: avvio senza limite di memoria (per non vedere l'avviso: MEMORY=\"\" in $CONF_FILE)" ;;
    esac
  fi
}

# ---------------------------------------------------------------------------
# Comando di avvio
# ---------------------------------------------------------------------------
RUN_ARGS=(run -it --rm)
if [ "$BUILD_ONLY" = false ]; then
  case "$RT" in
    podman) RUN_ARGS+=(--network host --userns=keep-id) ;;
    docker) RUN_ARGS+=(--network host) ;;
  esac
  if [ "$RT" = container ]; then
    # macOS: ogni container è una VM leggera, i limiti si applicano sempre
    if [ -n "$CPUS" ];   then RUN_ARGS+=(--cpus "$CPUS"); fi
    if [ -n "$MEMORY" ]; then RUN_ARGS+=(--memory "$MEMORY"); fi
  else
    add_linux_limits
  fi
  RUN_ARGS+=(--volume "$AGENT_DIR:/home/dev/.pi/agent" --volume "$PROJECT:/work")
  if [ "$OFFLINE" = true ]; then RUN_ARGS+=(--env PI_OFFLINE=1); fi
  RUN_ARGS+=("$IMAGE")
  if [ "$DO_SHELL" = true ]; then
    RUN_ARGS+=(bash -l)
  else
    RUN_ARGS+=(pi --provider local --model "$MODEL_ID" --thinking "$THINKING")
    RUN_ARGS+=(${PI_ARGS[@]+"${PI_ARGS[@]}"})
  fi
fi

if [ "$DRY_RUN" = true ]; then
  info "pi-box $PI_BOX_VERSION, runtime: $RT"
  if [ "$BUILD_ONLY" = false ]; then
    info "progetto: $PROJECT -> /work"
    info "models.json che verrebbe scritto in $AGENT_DIR:"
    models_json
  fi
  printf '\nargomenti di build:\n'
  build_args | sed 's/^/  /'
  if command -v "$RT" >/dev/null 2>&1; then
    reason="$(build_reason)"
    printf 'build: %s\n' "${reason:-non necessaria}"
  fi
  if [ "$BUILD_ONLY" = false ]; then
    printf '\ncomando:\n  %q' "$RT"
    for a in "${RUN_ARGS[@]}"; do printf ' %q' "$a"; done
    printf '\n'
  fi
  exit 0
fi

if [ "$RT" = container ]; then macos_prepare; fi

reason="$(build_reason)"
if [ -n "$reason" ]; then
  info "build necessaria: $reason"
  build_image
elif [ "$BUILD_ONLY" = true ]; then
  info "immagine $IMAGE già aggiornata"
fi
if [ "$BUILD_ONLY" = true ]; then exit 0; fi

write_agent_config
info "avvio di Pi ($MODEL_ID) su $PROJECT"
exec "$RT" "${RUN_ARGS[@]}"
```
