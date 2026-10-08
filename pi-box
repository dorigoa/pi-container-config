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
