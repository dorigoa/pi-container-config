# Pi con modelli locali, anche dentro un container (macOS e Ubuntu)

*Riepilogo della sessione dell'8 ottobre 2026 — Pi 1.1.0, Apple `container` 1.3.1, macOS 27.0.1*

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

### 2.4 L'immagine

`pi-box` la scrive in `~/pi-container/image/Containerfile` e la costruisce automaticamente al primo avvio. Per ricostruirla, per esempio per aggiornare Pi, usa `pi-box --rebuild`.

```dockerfile
FROM node:24-slim
ARG UID=1000
ARG PI_VERSION=latest

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git ripgrep fd-find curl ca-certificates less procps \
 && rm -rf /var/lib/apt/lists/*

# --ignore-scripts: non esegue gli script di installazione dei pacchetti npm
RUN npm install -g --ignore-scripts "@earendil-works/pi-coding-agent@${PI_VERSION}" \
 && npm cache clean --force

# Utente non-root con lo stesso UID dell'utente dell'host
RUN useradd -u "${UID}" -o -m -s /bin/bash dev
USER dev
ENV HOME=/home/dev
WORKDIR /work
CMD ["pi"]
```

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
3. Rigenera `~/pi-container/agent/models.json`. Su macOS sostituisce `127.0.0.1`/`localhost` con `host.container.internal`.
4. Solo su macOS: avvia il servizio `container` se è spento e crea il dominio DNS se manca.
5. Costruisce l'immagine se non esiste.
6. Avvia il container con Pi già collegato al modello: `pi --provider local --model … --thinking …`.

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
| `--cpus N`, `--memory M` | `CPUS`, `MEMORY` | `4`, `2g` (`""` = nessun limite) |
| — | `PI_VERSION` | `latest` (versione npm di Pi nell'immagine) |
| `--rebuild` | — | ricostruisce l'immagine |
| `--shell` | — | apre `bash` nel container invece di Pi |
| `--dry-run` | — | mostra `models.json` e il comando, senza eseguire |
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
```

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
| Linux/podman, errore sui *cgroup* (meccanismo del kernel per i limiti di risorse) con `--cpus`/`--memory` | il controller non è delegato all'utente: metti `CPUS=""` e `MEMORY=""` in `pi-box.conf` |
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
| Parte Ubuntu/podman | **non provata** |

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

Salvalo come `pi-box` e installalo come in §3.1.

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
set -euo pipefail

PI_BOX_HOME="${PI_BOX_HOME:-$HOME/pi-container}"
CONF_FILE="$PI_BOX_HOME/pi-box.conf"
AGENT_DIR="$PI_BOX_HOME/agent"
IMAGE_DIR="$PI_BOX_HOME/image"

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
MEMORY=2g                             # vuoto = nessun limite
OFFLINE=true                          # disattiva l'attività di rete automatica di Pi
IMAGE="pi-box:latest"
PI_VERSION="latest"                   # versione npm di Pi da installare nell'immagine

write_default_conf() {
  mkdir -p "$PI_BOX_HOME"
  cat > "$CONF_FILE" <<'EOF'
# Configurazione di pi-box (sintassi bash). Le opzioni da riga di comando
# hanno la precedenza su questi valori.

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
CPUS=4                                # "" = nessun limite
MEMORY=2g                             # "" = nessun limite
OFFLINE=true
IMAGE="pi-box:latest"
PI_VERSION="latest"
EOF
  info "creato il file di configurazione $CONF_FILE"
}

if [ -f "$CONF_FILE" ]; then
  # shellcheck source=/dev/null
  . "$CONF_FILE"
else
  write_default_conf
fi

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
      --memory M          limite RAM, es. 2g ("" = nessuno)
      --rebuild           ricostruisce l'immagine prima di avviare
      --shell             apre una shell bash nel container invece di Pi
      --dry-run           mostra configurazione e comando senza eseguire nulla
      --force             consente di montare la home o / (sconsigliato)
  -h, --help              questo aiuto

Esempi
  pi-box
  pi-box -m gemma-4-26b-a4b-it -i -c 65536
  pi-box -u http://192.168.1.20:8000/v1 -m qwen3.6-27b -r on -t high -p ~/src/progetto
  pi-box -- --continue
EOF
}

need_arg() { [ "$#" -ge 2 ] && [ -n "$2" ] || die "l'opzione $1 richiede un valore"; }

PROJECT="$PWD"
DO_REBUILD=false
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
    --shell)         DO_SHELL=true; shift ;;
    --dry-run)       DRY_RUN=true; shift ;;
    --force)         FORCE=true; shift ;;
    -h|--help)       usage; exit 0 ;;
    --)              shift; PI_ARGS=("$@"); break ;;
    *)               die "opzione sconosciuta: $1 (vedi --help)" ;;
  esac
done

# ---------------------------------------------------------------------------
# Validazione (i valori finiscono in un file JSON: niente caratteri pericolosi)
# ---------------------------------------------------------------------------
re_url='^https?://[^"\\[:space:]]+$'
re_int='^[0-9]+$'
re_num='^[0-9]+(\.[0-9]+)?$'
re_id='^[A-Za-z0-9._:/@+-]+$'
re_mem='^[0-9]+[kKmMgG]?$'
re_safe='^[^"\\]*$'

[[ $BASE_URL =~ $re_url ]]       || die "base URL non valido: $BASE_URL"
[[ $CONTEXT_WINDOW =~ $re_int ]] || die "--ctx deve essere un intero"
[[ $MAX_TOKENS =~ $re_int ]]     || die "--max-tokens deve essere un intero"
[ "$MAX_TOKENS" -lt "$CONTEXT_WINDOW" ] || die "--max-tokens deve essere minore di --ctx"
[[ $API_KEY =~ $re_safe ]]       || die "la API key non può contenere \" o \\"
[ -z "$TEMPERATURE" ] || [[ $TEMPERATURE =~ $re_num ]] || die "--temperature non valida"
[ -z "$TOP_P" ]       || [[ $TOP_P =~ $re_num ]]       || die "--top-p non valido"
[ -z "$TOP_K" ]       || [[ $TOP_K =~ $re_int ]]       || die "--top-k non valido"
[ -z "$CPUS" ]        || [[ $CPUS =~ $re_int ]]        || die "--cpus deve essere un intero"
[ -z "$MEMORY" ]      || [[ $MEMORY =~ $re_mem ]]      || die "--memory non valido (es. 2g)"

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

[ -d "$PROJECT" ] || die "la cartella del progetto non esiste: $PROJECT"
PROJECT="$(cd "$PROJECT" && pwd -P)"
HOME_REAL="$(cd "$HOME" && pwd -P)"
if [ "$FORCE" = false ]; then
  case "$PROJECT" in
    /|"$HOME_REAL") die "montare $PROJECT annullerebbe l'isolamento; usa una sottocartella o --force" ;;
  esac
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
# host.container.internal. Su Linux si usa la rete dell'host (--network host).
CONTAINER_BASE_URL="$BASE_URL"
if [ "$RT" = container ]; then
  re_loop='^(https?://)(127\.0\.0\.1|localhost|\[::1\])([:/].*)?$'
  if [[ $BASE_URL =~ $re_loop ]]; then
    CONTAINER_BASE_URL="${BASH_REMATCH[1]}host.container.internal${BASH_REMATCH[3]}"
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

if [ -z "$MODEL_ID" ]; then
  MODEL_ID="$(detect_model || true)"
  [ -n "$MODEL_ID" ] || die "impossibile rilevare il modello da ${BASE_URL%/}/models: indicalo con --model"
  info "modello rilevato: $MODEL_ID"
fi
[[ $MODEL_ID =~ $re_id ]] || die "id del modello non valido: $MODEL_ID"
[ -n "$MODEL_NAME" ] || MODEL_NAME="$MODEL_ID"
[[ $MODEL_NAME =~ $re_safe ]] || die "il nome del modello non può contenere \" o \\"

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
write_containerfile() {
  mkdir -p "$IMAGE_DIR"
  cat > "$IMAGE_DIR/Containerfile" <<'EOF'
FROM node:24-slim
ARG UID=1000
ARG PI_VERSION=latest

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git ripgrep fd-find curl ca-certificates less procps \
 && rm -rf /var/lib/apt/lists/*

# --ignore-scripts: non esegue gli script di installazione dei pacchetti npm
RUN npm install -g --ignore-scripts "@earendil-works/pi-coding-agent@${PI_VERSION}" \
 && npm cache clean --force

# Utente non-root con lo stesso UID dell'utente dell'host
RUN useradd -u "${UID}" -o -m -s /bin/bash dev
USER dev
ENV HOME=/home/dev
WORKDIR /work
CMD ["pi"]
EOF
}

image_exists() {
  case "$RT" in
    container) container image inspect "$IMAGE" >/dev/null 2>&1 ;;
    podman)    podman image exists "$IMAGE" ;;
    docker)    docker image inspect "$IMAGE" >/dev/null 2>&1 ;;
  esac
}

build_image() {
  write_containerfile
  info "costruisco l'immagine $IMAGE con $RT (Pi $PI_VERSION)..."
  "$RT" build --tag "$IMAGE" \
    --build-arg "UID=$(id -u)" --build-arg "PI_VERSION=$PI_VERSION" \
    --file "$IMAGE_DIR/Containerfile" "$IMAGE_DIR"
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
      if ! container system dns list 2>/dev/null | grep -Eq '^host\.container\.internal[[:space:]]*$'; then
        info "creo il dominio host.container.internal (richiede sudo; va ricreato dopo ogni riavvio del Mac)"
        sudo container system dns create host.container.internal --localhost 203.0.113.113
      fi ;;
  esac
}

# ---------------------------------------------------------------------------
# Comando di avvio
# ---------------------------------------------------------------------------
RUN_ARGS=(run -it --rm)
case "$RT" in
  podman) RUN_ARGS+=(--network host --userns=keep-id) ;;
  docker) RUN_ARGS+=(--network host) ;;
esac
if [ -n "$CPUS" ];   then RUN_ARGS+=(--cpus "$CPUS"); fi
if [ -n "$MEMORY" ]; then RUN_ARGS+=(--memory "$MEMORY"); fi
RUN_ARGS+=(--volume "$AGENT_DIR:/home/dev/.pi/agent" --volume "$PROJECT:/work")
if [ "$OFFLINE" = true ]; then RUN_ARGS+=(--env PI_OFFLINE=1); fi
RUN_ARGS+=("$IMAGE")
if [ "$DO_SHELL" = true ]; then
  RUN_ARGS+=(bash)
else
  RUN_ARGS+=(pi --provider local --model "$MODEL_ID" --thinking "$THINKING")
  RUN_ARGS+=(${PI_ARGS[@]+"${PI_ARGS[@]}"})
fi

if [ "$DRY_RUN" = true ]; then
  info "runtime: $RT"
  info "progetto: $PROJECT -> /work"
  info "models.json che verrebbe scritto in $AGENT_DIR:"
  models_json
  printf '\ncomando:\n  %q' "$RT"
  for a in "${RUN_ARGS[@]}"; do printf ' %q' "$a"; done
  printf '\n'
  exit 0
fi

if [ "$RT" = container ]; then macos_prepare; fi
write_agent_config
if [ "$DO_REBUILD" = true ] || ! image_exists; then build_image; fi

info "avvio di Pi ($MODEL_ID) su $PROJECT"
exec "$RT" "${RUN_ARGS[@]}"
```
