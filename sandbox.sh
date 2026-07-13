#!/usr/bin/env bash
set -euo pipefail

# sandbox.sh — local kind cluster bootstrapped with Argo CD + Kargo + Istio
# ambient mesh, behind an Istio gateway. Idempotent: re-running 'up' is safe.

# ============================================================================
# Configuration
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIND_CONFIG="${SCRIPT_DIR}/kind-config.yaml"
SANDBOX_LIB_DIR="${SCRIPT_DIR}/lib"

WILDCARD_TLS_SECRET="${WILDCARD_TLS_SECRET:-sandbox-wildcard-tls}"
ROOT_CA_SECRET="${ROOT_CA_SECRET:-sandbox-root-ca}"

CLUSTER_NAME="${SANDBOX_CLUSTER_NAME:-sandboxctl}"
ARGOCD_NS="${ARGOCD_NS:-argocd}"
KARGO_NS="${KARGO_NS:-kargo}"
DEMO_NS="${DEMO_NS:-demo-app}"
REGISTRY_NS="${REGISTRY_NS:-sandboxctl-registry}"
ISTIO_SYSTEM_NS="${ISTIO_SYSTEM_NS:-istio-system}"
ISTIO_INGRESS_NS="${ISTIO_INGRESS_NS:-istio-ingress}"
LEGACY_INGRESS_NS="${LEGACY_INGRESS_NS:-ingress-nginx}"
LEGACY_TRAEFIK_NS="${LEGACY_TRAEFIK_NS:-traefik}"
LEGACY_GUESTBOOK_NS="${LEGACY_GUESTBOOK_NS:-guestbook}"

ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-10.1.3}"
KARGO_CHART_VERSION="${KARGO_CHART_VERSION:-1.10.8}"
REFLECTOR_NS="${REFLECTOR_NS:-reflector}"
REFLECTOR_CHART_VERSION="${REFLECTOR_CHART_VERSION:-10.0.58}"
RELOADER_NS="${RELOADER_NS:-reloader}"
RELOADER_CHART_VERSION="${RELOADER_CHART_VERSION:-2.2.14}"
CERT_MANAGER_NS="${CERT_MANAGER_NS:-cert-manager}"
CERT_MANAGER_CHART_VERSION="${CERT_MANAGER_CHART_VERSION:-v1.21.0}"
ISTIO_CHART_VERSION="${ISTIO_CHART_VERSION:-1.30.2}"
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-kindest/node:v1.35.0}"

# Number of kind worker nodes to spin up alongside the control-plane.
# Default 1 (single-node cluster, the historical behaviour). Range 1–3 —
# overrideable via env or the --workers flag on `up` / `bootstrap` /
# `restart --rebuild`. Anything outside the range fails fast at flag-
# parse time so a typo doesn't trigger a partial cluster build.
#
# Why capped at 3: each kind worker node is its own Docker container with
# its own image cache. On a 32 GB Mac three workers give ~3× the
# scheduling headroom without leaving the host short on memory; beyond
# that the Mac itself starts swapping and the dev loop gets slower, not
# faster. Open an issue if you have a real use case for more.
SANDBOX_WORKER_COUNT="${SANDBOX_WORKER_COUNT:-1}"
SANDBOX_WORKER_COUNT_MIN=1
SANDBOX_WORKER_COUNT_MAX=3

# kagent: install the controller + UI only. We deliberately do not wire a
# model provider here — no Ollama, no API-key providers, no model pulls.
# Users configure providers/models out-of-band after the install.
KAGENT_NS="${KAGENT_NS:-kagent}"
KAGENT_CHART_VERSION="${KAGENT_CHART_VERSION:-0.9.11}"

# arctl — the agentregistry CLI (https://aregistry.ai). Installed onto the
# *Mac* (not the cluster) by `up`/`bootstrap` when --with-arctl is passed,
# so the sandbox can build, publish, and run MCP servers, agents, skills
# + prompts; removed again by `down`/`purge`. We fetch the release binary
# directly and verify its sha256 rather than piping the upstream
# installer to a shell.
#   ARCTL_VERSION   tag to install (default 'latest' tracks the newest
#                   GitHub release; pin e.g. v0.3.3 for reproducibility)
#   INSTALL_ARCTL=1      install arctl during up/bootstrap (--with-arctl)
#   SANDBOX_KEEP_ARCTL=1 keep the binary on down/purge
ARCTL_REPO="${ARCTL_REPO:-agentregistry-dev/agentregistry}"
ARCTL_VERSION="${ARCTL_VERSION:-latest}"
ARCTL_INSTALL_DIR="${ARCTL_INSTALL_DIR:-/usr/local/bin}"
INSTALL_ARCTL="${INSTALL_ARCTL:-0}"

# agentregistry server — deployed *into* the cluster (when opted in) and
# exposed at https://aregistry.${SANDBOX_DOMAIN}:${SANDBOX_HTTPS_PORT}.
# Backed by a CloudNativePG-managed Postgres with the pgvector extension
# preloaded (so embeddings + semantic search work, unlike the chart's
# bundled postgres:18 which has no pgvector). All knobs live in
# lib/aregistry.sh; only the gate flag belongs here so cmd_up can read it
# before the lib is sourced.
#   INSTALL_AGENTREGISTRY=1   install agentregistry + CNPG (--with-agentregistry)
INSTALL_AGENTREGISTRY="${INSTALL_AGENTREGISTRY:-0}"

# AI Agentic Gateway — every gateway is opt-in so a plain `sandboxctl up`
# stays small on a laptop VM. Turn them on individually
# (--with-agentgateway / --with-portkey / --with-litellm / --with-mlflow /
# --with-tyk) or all at once with --with-ai-gateway. The gates live in
# their libs (lib/{agentgateway,litellm,portkey,mlflow,tyk}.sh) and are
# read at install time, so the flag parser below (or an env var) can
# flip any of them.
#   INSTALL_AGENTGATEWAY=1  install agentgateway          (--with-agentgateway)
#   INSTALL_PORTKEY=1       install Portkey AI gateway    (--with-portkey)
#   INSTALL_LITELLM=1       install LiteLLM proxy         (--with-litellm)
#   INSTALL_MLFLOW=1        install MLflow tracking + UI  (--with-mlflow)
#   INSTALL_TYK=1           install Tyk OSS API gateway   (--with-tyk)
INSTALL_AGENTGATEWAY="${INSTALL_AGENTGATEWAY:-0}"
INSTALL_LITELLM="${INSTALL_LITELLM:-0}"
INSTALL_PORTKEY="${INSTALL_PORTKEY:-0}"
INSTALL_MLFLOW="${INSTALL_MLFLOW:-0}"
INSTALL_TYK="${INSTALL_TYK:-0}"

# NATS + JetStream — opt-in. When enabled, installs the chart, issues a
# server cert, wires the TLS-passthrough route through the Istio gateway,
# and (on macOS) installs a LaunchAgent that port-forwards :4222 to the
# host. Skipped by default to keep `up` quick.
#   INSTALL_NATS=1   install NATS + JetStream + nats-portfwd (--with-nats)
INSTALL_NATS="${INSTALL_NATS:-0}"

# CloudNativePG operator — opt-in. The operator runs in cnpg-system and
# manages Postgres clusters declaratively (used by agentregistry's
# pgvector-enabled cluster, and reused by LiteLLM when both are enabled).
# --with-agentregistry implies this; turn it on stand-alone with
# --with-cnpg if you want a shared Postgres without agentregistry.
#   INSTALL_CNPG=1   install the cloudnative-pg operator (--with-cnpg)
INSTALL_CNPG="${INSTALL_CNPG:-0}"

# Gitea: in-cluster git server that backs `sandboxctl deploy`. The CLI
# pushes the local chart subtree to gitea-http.gitea.svc:3000 and Argo
# CD pulls from that URL — proper GitOps loop without needing external
# git creds. Chart pinned for reproducibility; rootless image + sqlite
# keeps the install footprint tiny (one Pod + a 1Gi PVC).
GITEA_NS="${GITEA_NS:-gitea}"
GITEA_CHART_VERSION="${GITEA_CHART_VERSION:-12.6.0}"
GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-sandbox}"
# Org under which `sandboxctl deploy` pushes chart repos. Must NOT
# collide with GITEA_ADMIN_USER — Gitea's API rejects org creation with
# 422 "user already exists" when the names match.
GITEA_ORG="${GITEA_ORG:-apps}"

SANDBOX_DOMAIN="${SANDBOX_DOMAIN:-sandbox.app}"

# Demo app: Argo CD watches this repo + path. Override to point at a fork.
DEMO_APP_REPO_URL="${DEMO_APP_REPO_URL:-https://github.com/tesserix/sandboxctl.git}"
DEMO_APP_REPO_REVISION="${DEMO_APP_REPO_REVISION:-main}"
ARGO_HOST="argo.${SANDBOX_DOMAIN}"
KARGO_HOST="kargo.${SANDBOX_DOMAIN}"
DEMO_HOST="demo-app.${SANDBOX_DOMAIN}"
KAGENT_HOST="kagent.${SANDBOX_DOMAIN}"
ROOT_CA_CN="${SANDBOX_DOMAIN} sandbox root CA"

# UI URLs use :8443 because binding :443 would need sudo on every launchd start.
SANDBOX_HTTPS_PORT="${SANDBOX_HTTPS_PORT:-8443}"
SANDBOX_HTTP_PORT="${SANDBOX_HTTP_PORT:-8080}"

# Registry: registry:2 Pod, reachable as `localhost:$SANDBOX_REGISTRY_PORT`
# from both Mac (via socat container on kind network) and in-cluster Pods
# (via containerd hosts.toml mirror). Default 5050 dodges Docker Desktop's
# :5001 mirror.
SANDBOX_REGISTRY_PORT="${SANDBOX_REGISTRY_PORT:-5050}"
SANDBOX_REGISTRY_STORAGE="${SANDBOX_REGISTRY_STORAGE:-12Gi}"
SANDBOX_STATE_DIR="${SANDBOX_STATE_DIR:-$HOME/.sandboxctl}"
SANDBOX_STATE_FILE="${SANDBOX_STATE_DIR}/setup.yaml"

# helm consults the Docker credential store even for anonymous public
# OCI pulls. A leftover credsStore (classically `osxkeychain` from an
# uninstalled Docker Desktop, with podman now in its place) makes every
# `helm … oci://` chart install fail with
#   exec: "docker-credential-osxkeychain": executable file not found
# Everything sandboxctl pulls is public, so pin helm to a
# sandboxctl-owned empty registry config — unless the user set their
# own HELM_REGISTRY_CONFIG, which always wins.
if [[ -z "${HELM_REGISTRY_CONFIG:-}" ]]; then
  mkdir -p "$SANDBOX_STATE_DIR"
  [[ -s "${SANDBOX_STATE_DIR}/helm-registry.json" ]] || printf '{}\n' > "${SANDBOX_STATE_DIR}/helm-registry.json"
  export HELM_REGISTRY_CONFIG="${SANDBOX_STATE_DIR}/helm-registry.json"
fi
# Persisted Podman VM sizing — written by `sandboxctl up`/`restart` when
# the user passes --podman-cpus/--podman-memory/--podman-disk, and read
# at script start so subsequent invocations remember the chosen size
# without re-passing the flag. Plain `KEY=VALUE` shell file so it's safe
# to source.
SANDBOX_PODMAN_CONFIG="${SANDBOX_PODMAN_CONFIG:-${SANDBOX_STATE_DIR}/podman.env}"
SANDBOX_LAUNCHAGENT_DIR="${SANDBOX_LAUNCHAGENT_DIR:-$HOME/Library/LaunchAgents}"
SANDBOX_LAUNCHAGENT_LABEL="${SANDBOX_LAUNCHAGENT_LABEL:-io.github.sandboxctl.portfwd}"
SANDBOX_LAUNCHAGENT_PLIST="${SANDBOX_LAUNCHAGENT_DIR}/${SANDBOX_LAUNCHAGENT_LABEL}.plist"
SANDBOX_PF_LOG="${SANDBOX_STATE_DIR}/portfwd.log"
# Pinned kubeconfig for the LaunchAgent. launchd jobs don't inherit the
# user's KUBECONFIG, so we can't rely on `kind` having written the
# context to ~/.kube/config — kind writes to whatever the first entry
# in $KUBECONFIG points to. Materialize a dedicated file we own.
SANDBOX_KUBECONFIG="${SANDBOX_STATE_DIR}/kubeconfig"

# socat container on kind network — bypass kubectl port-forward, which
# stalls on Docker's 16-way parallel layer uploads.
SANDBOX_REGISTRY_PROXY_CONTAINER="${SANDBOX_REGISTRY_PROXY_CONTAINER:-${CLUSTER_NAME}-registry-proxy}"
SANDBOX_REGISTRY_PROXY_IMAGE="${SANDBOX_REGISTRY_PROXY_IMAGE:-docker.io/alpine/socat:latest}"
SANDBOX_REGISTRY_NODEPORT="${SANDBOX_REGISTRY_NODEPORT:-30050}"
SANDBOX_HOSTS_MARKER="# managed by sandboxctl (${SANDBOX_DOMAIN})"
SANDBOX_SECRETS_FILE="${SANDBOX_STATE_DIR}/secrets.env"

SANDBOX_RUNTIME="${SANDBOX_RUNTIME:-podman}"
# Source persisted Podman sizing first so saved values become defaults.
# Anything the user already exported in their environment still wins via
# the `${VAR:-…}` fallbacks below — env > saved > built-in.
if [[ -f "$SANDBOX_PODMAN_CONFIG" ]]; then
  # shellcheck disable=SC1090
  . "$SANDBOX_PODMAN_CONFIG" 2>/dev/null || true
fi
PODMAN_MACHINE_CPUS="${PODMAN_MACHINE_CPUS:-4}"
PODMAN_MACHINE_MEMORY_MIB="${PODMAN_MACHINE_MEMORY_MIB:-6144}"
PODMAN_MACHINE_DISK_GIB="${PODMAN_MACHINE_DISK_GIB:-60}"

# ----- Build sizing -------------------------------------------------------
# `podman build` and the kind nodes share the same Podman VM. A burst-y
# Go compile (e.g. `go build` on a multi-module repo) can claim every CPU
# and most of the VM's RAM, at which point kubelet on the kind control-
# plane misses heartbeats and the cluster goes "down" mid-build. These
# defaults cap the build container at ~half of each axis so kind keeps
# headroom by default — set to empty / 0 to opt out, or override via
# --build-cpus / --build-memory / SANDBOX_BUILD_CPUS / SANDBOX_BUILD_MEMORY.
# Effective only for the podman builder (docker's daemon already has its
# own resource pool).
SANDBOX_BUILD_CPUS="${SANDBOX_BUILD_CPUS-auto}"
SANDBOX_BUILD_MEMORY="${SANDBOX_BUILD_MEMORY-auto}"
# Override the runtime used for `<runtime> build` (independent of
# SANDBOX_RUNTIME, which controls the runtime that hosts kind). The
# canonical use case: keep podman for kind, but build with docker so the
# compile runs in Docker Desktop's VM and never touches the Podman VM
# kind lives in. The push step already handles cross-runtime via the
# existing save|load handoff.
SANDBOX_BUILD_RUNTIME="${SANDBOX_BUILD_RUNTIME:-}"
case "$SANDBOX_RUNTIME" in
  podman) export KIND_EXPERIMENTAL_PROVIDER=podman ;;
  docker) ;;
  *) echo "ERROR: unsupported SANDBOX_RUNTIME=$SANDBOX_RUNTIME (use podman or docker)" >&2; exit 1 ;;
esac

# Per-install Kargo secrets — generated on first `up`, reused thereafter.
KARGO_ADMIN_PASSWORD=""
KARGO_ADMIN_PASSWORD_HASH=""
KARGO_TOKEN_SIGNING_KEY="${KARGO_TOKEN_SIGNING_KEY:-}"

# ============================================================================
# Utilities
# ============================================================================

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32mOK:\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1 (install via brew)"; }

# Resolve a *_CHART_VERSION variable set to the literal "latest" into a
# concrete version via `sandboxctl _resolve-latest <component>` (same
# opt-in channel ARCTL_VERSION=latest already provides). Pinned values
# pass through untouched — reproducible installs stay the default.
resolve_chart_version() {
  local var="$1" component="$2" resolved
  [[ "${!var}" == "latest" ]] || return 0
  command -v sandboxctl >/dev/null 2>&1 \
    || die "$var=latest needs the sandboxctl binary on PATH to resolve it"
  resolved="$(sandboxctl _resolve-latest "$component" 2>/dev/null)" \
    || die "could not resolve the latest $component chart version (offline? pin $var explicitly instead)"
  log "$var=latest → ${resolved}"
  printf -v "$var" '%s' "$resolved"
}

# Normalize a human memory string ("8g", "12gib", "8192", "8192m") into
# integer MiB. Returns empty + non-zero on a malformed input so callers
# can `die` with a flag-specific message.
_normalize_mem_to_mib() {
  local raw="${1:-}"
  [[ -n "$raw" ]] || return 1
  raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  case "$raw" in
    *gib) printf '%d' "$(( ${raw%gib} * 1024 ))"; return 0 ;;
    *gb)  printf '%d' "$(( ${raw%gb}  * 1024 ))"; return 0 ;;
    *g)   printf '%d' "$(( ${raw%g}   * 1024 ))"; return 0 ;;
    *mib) printf '%d' "${raw%mib}";               return 0 ;;
    *mb)  printf '%d' "${raw%mb}";                return 0 ;;
    *m)   printf '%d' "${raw%m}";                 return 0 ;;
    *)
      [[ "$raw" =~ ^[0-9]+$ ]] || return 1
      printf '%d' "$raw"; return 0 ;;
  esac
}

# ----- celebration / sad-trombone banners ----------------------------------
#
# Drop-in banners for the very end of cmd_up / cmd_bootstrap / cmd_restart.
# ASCII fallback when LANG isn't UTF-8 so they don't garble in CI logs.
celebrate() {
  local headline="${1:-sandbox is up}"
  local emoji='🎉 ✨ 🚀'
  case "${LANG:-}${LC_ALL:-}" in
    *UTF-8*|*utf8*|*UTF8*) ;;
    *) emoji='*** ' ;;
  esac
  printf '\n' >&2
  printf '\033[1;32m  %s  %s  %s\033[0m\n' "${emoji%% *}" "$headline" "${emoji##* }" >&2
  printf '\033[1;32m  ────────────────────────────────────────\033[0m\n' >&2
  printf '  \033[2mevery component is healthy and reachable from the Mac\033[0m\n' >&2
  printf '\n' >&2
}

# Used by traps when something fatal happens so the user gets one
# consistent failure card instead of a wall of red text scrolling by.
sad_trombone() {
  local headline="${1:-something went wrong}"
  printf '\n' >&2
  printf '\033[1;31m  ✗  %s\033[0m\n' "$headline" >&2
  printf '\033[1;31m  ────────────────────────────────────────\033[0m\n' >&2
  printf '  \033[2mscroll up for the failed step (look for ✗ rows).\033[0m\n' >&2
  printf '  \033[2mlogs:    %s/spinner-logs/\033[0m\n' "${SANDBOX_STATE_DIR:-$HOME/.sandboxctl}" >&2
  printf '  \033[2mre-run:  sandboxctl status   (then: sandboxctl restart)\033[0m\n' >&2
  printf '\n' >&2
}

# ----- spinner -------------------------------------------------------------
#
# with_spinner LABEL CMD [ARGS...]
#
# Run CMD ARGS while showing a spinner with LABEL on stderr. The spinner
# is suppressed when stderr isn't a TTY (CI logs stay clean) or when
# SANDBOXCTL_NO_SPINNER=1. Output of the wrapped command is captured to
# a per-run logfile under $SANDBOX_STATE_DIR/spinner-logs/ so failures
# can be inspected after the fact; on success the file is removed.
#
# bash 3.2 compatible: no `wait -n`, no associative arrays, no
# process-substitution requirements outside this block.
SANDBOXCTL_NO_SPINNER="${SANDBOXCTL_NO_SPINNER:-0}"
_SPINNER_FRAMES='⏳⌛'  # alternating; falls back to ASCII if locale is C
_spinner_loop() {
  # $1: label, $2: pid to watch, $3: start epoch
  local label="$1" pid="$2" start="$3" frames="$_SPINNER_FRAMES"
  case "${LANG:-}${LC_ALL:-}" in
    *UTF-8*|*utf8*|*UTF8*) ;;
    *) frames='|/-\\' ;;
  esac
  local i=0 now elapsed frame
  while kill -0 "$pid" 2>/dev/null; do
    now=$(date +%s)
    elapsed=$(( now - start ))
    # Pick a frame. Bash 3.2 lacks `${var:i:1}` index math friendliness
    # for some unicode strings, so we cycle by a per-call modulo.
    case $(( i % 2 )) in
      0) frame="${frames:0:1}" ;;
      *) frame="${frames:1:1}" ;;
    esac
    printf '\r\033[2K  %s %s ... \033[2m(%ds — please wait, do not Ctrl-C)\033[0m' "$frame" "$label" "$elapsed" >&2
    i=$(( i + 1 ))
    sleep 0.4
  done
}
with_spinner() {
  local label="$1"; shift
  # A caller (helm_install) can pin the capture file via $SPINNER_LOGFILE
  # so it can inspect helm's output afterwards; it then owns cleanup.
  local caller_log="${SPINNER_LOGFILE:-}"
  if [[ "$SANDBOXCTL_NO_SPINNER" == "1" || ! -t 2 ]]; then
    if [[ -n "$caller_log" ]]; then
      "$@" >"$caller_log" 2>&1
      local rc=$?
      cat "$caller_log" >&2
      return $rc
    fi
    "$@"
    return $?
  fi
  mkdir -p "${SANDBOX_STATE_DIR:-$HOME/.sandboxctl}/spinner-logs"
  local logfile
  if [[ -n "$caller_log" ]]; then
    logfile="$caller_log"
  else
    logfile="$(mktemp "${SANDBOX_STATE_DIR:-$HOME/.sandboxctl}/spinner-logs/$(date +%s).XXXXXX.log")"
  fi
  local start; start=$(date +%s)
  ( "$@" ) >"$logfile" 2>&1 &
  local pid=$!
  _spinner_loop "$label" "$pid" "$start"
  # `wait` propagates the child's exit. Under `set -e`, a nonzero exit
  # from `wait` would abort the function before we capture rc — disable
  # errexit transiently around it.
  local rc=0
  set +e
  wait "$pid"
  rc=$?
  set -e
  local elapsed=$(( $(date +%s) - start ))
  if (( rc == 0 )); then
    printf '\r\033[2K  \033[1;32m✓\033[0m %s \033[2m(%ds)\033[0m\n' "$label" "$elapsed" >&2
    [[ -n "$caller_log" ]] || rm -f "$logfile"
  else
    printf '\r\033[2K  \033[1;31m✗\033[0m %s \033[2m(%ds — log: %s)\033[0m\n' "$label" "$elapsed" "$logfile" >&2
    # Surface the last 20 lines so the user sees the failure inline —
    # unless the caller (helm_install) set SPINNER_QUIET_FAIL because it
    # means to recover and retry, and will surface the log itself if the
    # recovery ultimately fails.
    [[ "${SPINNER_QUIET_FAIL:-}" == "1" ]] || tail -20 "$logfile" >&2
  fi
  return $rc
}

# helm_install <spinner-label> helm upgrade --install <release> <chart> [flags...]
#
# Drop-in for `with_spinner <label> helm upgrade --install ...` with two
# behaviours layered on so every chart install survives a re-run and a
# half-finished previous run:
#
#   1. Idempotent fast-path — if the release is already `deployed` at the
#      requested --version, skip the install and continue. Re-running
#      `up` on a healthy cluster then costs one `helm list`, not a full
#      reconcile. A version mismatch (or any non-deployed state) falls
#      through to `helm upgrade --install`, so version bumps still apply.
#
#   2. Ownership self-heal — an interrupted earlier run can leave a
#      resource behind without Helm's ownership metadata, so the next
#      install aborts with `<Kind> "<name>" ... exists and cannot be
#      imported into the current release`. On that specific error this
#      stamps the Helm ownership annotations/label onto the named orphan
#      — a non-destructive adoption that never deletes data or PVCs — and
#      retries. It loops a few times because Helm reports such conflicts
#      one resource at a time. Any other failure is surfaced unchanged.
# Wait until cert-manager's validating webhook actually answers. helm
# --wait proves the webhook POD is Ready, not that the endpoint serves —
# upgrades and container-runtime blips (seen in the wild: all three
# cert-manager pods restarted with exit 255 mid-`up`) leave a window
# where every Certificate write gets connection-refused. A server-side
# dry-run Certificate exercises the exact call path consumers fail on.
wait_for_cert_manager_webhook() {
  local i
  for ((i=1; i<=40; i++)); do
    if kc apply --dry-run=server -f - >/dev/null 2>&1 <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: sandboxctl-webhook-probe
  namespace: ${CERT_MANAGER_NS}
spec:
  secretName: sandboxctl-webhook-probe-tls
  issuerRef:
    name: sandboxctl-webhook-probe
    kind: Issuer
  dnsNames: ["probe.invalid"]
EOF
    then
      ok "cert-manager webhook answering"
      return 0
    fi
    sleep 3
  done
  warn "cert-manager webhook still not answering after ~120s"
  return 1
}

helm_install() {
  local label="$1"; shift
  local -a cmd=("$@")

  # Pull the release name (token after --install), namespace (--namespace
  # / -n) and requested chart version (--version) out of the command so we
  # can short-circuit and target adoptions.
  local release="" ns="" want_ver="" i
  for ((i=0; i<${#cmd[@]}; i++)); do
    case "${cmd[i]}" in
      --install)       release="${cmd[i+1]:-}" ;;
      --namespace|-n)  ns="${cmd[i+1]:-}" ;;
      --version)       want_ver="${cmd[i+1]:-}" ;;
    esac
  done

  if [[ -n "$release" && -n "$ns" ]] && helm_release_satisfied "$release" "$ns" "$want_ver"; then
    log "${release} already installed — skipping (helm release ${ns}/${release} is deployed${want_ver:+ at ${want_ver}})"
    return 0
  fi

  # Pin the install to the kind cluster. Bare `helm` would follow the
  # user's ambient context onto the wrong cluster (see helmk), so swap a
  # leading `helm` for the pinned wrapper before running it.
  local -a run=("${cmd[@]}")
  [[ "${run[0]}" == "helm" ]] && run=(helmk "${run[@]:1}")

  mkdir -p "${SANDBOX_STATE_DIR:-$HOME/.sandboxctl}/spinner-logs" 2>/dev/null || true
  local logfile
  logfile="$(mktemp "${SANDBOX_STATE_DIR:-$HOME/.sandboxctl}/spinner-logs/helm.$(date +%s).XXXXXX.log" 2>/dev/null || mktemp)"
  local attempt rc=0
  # shellcheck disable=SC2034  # loop counter only bounds retries; value unused
  for attempt in 1 2 3 4 5 6; do
    rc=0
    SPINNER_LOGFILE="$logfile" SPINNER_QUIET_FAIL=1 with_spinner "$label" "${run[@]}" || rc=$?
    if (( rc == 0 )); then
      rm -f "$logfile"
      return 0
    fi
    if [[ -n "$release" && -n "$ns" ]] \
       && grep -q "cannot be imported into the current release" "$logfile" \
       && helm_adopt_conflict "$release" "$ns" "$logfile"; then
      continue
    fi
    # Transient cert-manager webhook outage (upgrade rollout or a
    # container-runtime blip): wait for the webhook to answer, retry.
    if grep -qE 'failed calling webhook.*cert-manager|webhook\.cert-manager\.io' "$logfile"; then
      warn "cert-manager's webhook was unavailable during '${label}' — waiting for it, then retrying"
      if wait_for_cert_manager_webhook; then
        continue
      fi
    fi
    break
  done

  # Unrecoverable: surface the tail with_spinner held back, then fail.
  tail -20 "$logfile" >&2
  rm -f "$logfile"
  return "$rc"
}

# True when <release> in <ns> is already `deployed`, and — when a version
# is given — at that chart version. Lets helm_install skip a redundant
# reinstall while still upgrading on a version bump.
helm_release_satisfied() {
  local release="$1" ns="$2" want_ver="$3"
  local list status chart have_ver
  list="$(helmk list -n "$ns" --filter "^${release}\$" -o json 2>/dev/null || true)"
  [[ -n "$list" && "$list" != "[]" ]] || return 1
  status="$(printf '%s' "$list" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)"
  [[ "$status" == "deployed" ]] || return 1
  [[ -n "$want_ver" ]] || return 0          # deployed, and no pin to match
  chart="$(printf '%s' "$list" | grep -o '"chart":"[^"]*"' | head -1 | cut -d'"' -f4)"
  have_ver="${chart##*-}"                    # "<name>-1.16.2" -> "1.16.2"
  [[ "${have_ver#v}" == "${want_ver#v}" ]]   # ignore a leading v on either side
}

# helm_adopt_conflict <release> <release-namespace> <helm-logfile>
# Read the resource Helm refused to import from its error output and stamp
# Helm's ownership metadata onto it, so a retry adopts it instead of
# colliding. Returns 0 if it adopted something, 1 if there was nothing to
# adopt (so the caller stops retrying).
helm_adopt_conflict() {
  local release="$1" rel_ns="$2" logfile="$3"
  local line
  line="$(grep -m1 'cannot be imported into the current release' "$logfile" 2>/dev/null || true)"
  [[ -n "$line" ]] || return 1

  # Helm v3 phrasings:
  #   ... : <Kind> "<name>" in namespace "<ns>" exists and cannot be ...   (namespaced)
  #   ... : <Kind> "<name>" exists and cannot be imported ...              (cluster-scoped)
  local prefix kind rest name res_ns
  prefix="${line%%\"*}"                            # text up to the first quote
  prefix="${prefix%"${prefix##*[![:space:]]}"}"    # right-trim the trailing space before the quote
  kind="${prefix##* }"                             # its last word = the Kind
  rest="${line#*\"}"                               # text after the first quote
  name="${rest%%\"*}"                              # = the resource name
  if [[ "$line" == *"in namespace \""* ]]; then
    res_ns="${line#*in namespace \"}"
    res_ns="${res_ns%%\"*}"
  else
    res_ns=""                                      # cluster-scoped
  fi
  [[ -n "$kind" && -n "$name" ]] || return 1

  log "adopting orphaned ${kind} \"${name}\"${res_ns:+ (ns: ${res_ns})} into Helm release ${rel_ns}/${release}"
  local -a nsflag=()
  [[ -n "$res_ns" ]] && nsflag=(-n "$res_ns")
  kc ${nsflag[@]+"${nsflag[@]}"} annotate "$kind" "$name" \
    "meta.helm.sh/release-name=${release}" \
    "meta.helm.sh/release-namespace=${rel_ns}" --overwrite >/dev/null 2>&1 || return 1
  kc ${nsflag[@]+"${nsflag[@]}"} label "$kind" "$name" \
    "app.kubernetes.io/managed-by=Helm" --overwrite >/dev/null 2>&1 || return 1
  return 0
}

# User-facing kubeconfig. We force kind's kubeconfig writes here
# regardless of any $KUBECONFIG the user has set in their shell, so
# `kubectl` "just works" in any new terminal without the user having
# to know where kind dropped the context. kind merges into this file
# rather than replacing it, so existing entries are preserved.
SANDBOX_USER_KUBECONFIG="${HOME}/.kube/config"

kctx() { echo "kind-$CLUSTER_NAME"; }
# Internal kubectl helper. Pins KUBECONFIG to the canonical user file
# we just wrote into, so sandbox.sh keeps working even if the caller
# has a custom $KUBECONFIG that doesn't include ~/.kube/config.
kc()   { KUBECONFIG="$SANDBOX_USER_KUBECONFIG" kubectl --context "$(kctx)" "$@"; }

# Internal helm helper — the helm analogue of kc(). This is not a
# convenience: bare `helm` reads the caller's ambient $KUBECONFIG and
# whatever context is selected there, so without pinning it will happily
# operate on a completely unrelated cluster the user has loaded (a real
# GKE/EKS cluster, docker-desktop, etc.). Forcing BOTH the kubeconfig file
# and --kube-context guarantees every release op lands on kind-$CLUSTER_NAME
# regardless of the user's environment, overriding any context they have
# set. All cluster-touching helm calls (upgrade/install/list/status/
# uninstall) MUST go through this; only context-free calls (`helm repo
# add/update`, which write ~/.config/helm) may use bare helm.
helmk() { KUBECONFIG="$SANDBOX_USER_KUBECONFIG" helm --kube-context "$(kctx)" "$@"; }

# kind_pinned runs `kind` with KUBECONFIG forced to the canonical
# user kubeconfig, so create/delete operations always touch the same
# file regardless of what the surrounding shell exported.
kind_pinned() {
  mkdir -p "$(dirname "$SANDBOX_USER_KUBECONFIG")"
  KUBECONFIG="$SANDBOX_USER_KUBECONFIG" kind "$@"
}

# Truth source for "is kagent installed in this cluster?" — checked
# at runtime against the live API rather than a flag in state, so
# `status` / `validate` / `down` / `install_routes` agree across
# upgrades and across re-runs that flip the toggle.
_kagent_present() {
  kc get ns "$KAGENT_NS" >/dev/null 2>&1
}

prime_sudo() {
  if ! sudo -n true 2>/dev/null; then
    sudo_prompt_banner
    sudo -v || die "sudo required to configure /etc/hosts and System keychain"
    printf '\033[1;32m  ✓ password accepted — continuing\033[0m\n' >&2
  fi
}

# Pre-prompt banner. macOS' sudo password prompt is a single line
# ("Password:") with no context. Without a banner ahead of it, users
# stare at the cursor wondering if sandboxctl froze. We make it
# obvious *what* is asking, *why*, and that the password is handled
# entirely by macOS' own sudo (never seen or stored by sandboxctl).
#
# Layout uses a left bar instead of a full box: rendering a perfectly-
# aligned right border across mixed-width unicode (em dashes, bullets,
# escape codes) is fiddly and wraps badly when terminals or fonts vary.
# The left bar is simple and always renders cleanly.
sudo_prompt_banner() {
  local bar='\033[1;33m│\033[0m '
  printf '\n' >&2
  printf "${bar}\033[1;37mmacOS sudo prompt — your login password is needed once\033[0m\n" >&2
  printf "${bar}\n" >&2
  printf "${bar}Used for:\n" >&2
  printf "${bar}  • adding *.%s to /etc/hosts\n" "${SANDBOX_DOMAIN:-sandbox.app}" >&2
  printf "${bar}  • installing the per-machine root CA in the System keychain\n" >&2
  printf "${bar}  • dropping arctl into /usr/local/bin\n" >&2
  printf "${bar}\n" >&2
  printf "${bar}\033[2mType your Mac login password and press Enter.\033[0m\n" >&2
  printf "${bar}\033[2mNothing is echoed as you type — that is normal.\033[0m\n" >&2
  printf "${bar}\n" >&2
  printf "${bar}\033[1;32m🔒 \033[0m\033[2mThe prompt is from macOS' own \`sudo\`. Your password is\033[0m\n" >&2
  printf "${bar}\033[2m   read directly into the kernel's auth cache (5-min TTL,\033[0m\n" >&2
  printf "${bar}\033[2m   per-tty). sandboxctl never sees it, never stores it,\033[0m\n" >&2
  printf "${bar}\033[2m   never sends it anywhere. Same model as 'brew', 'sudo apt',\033[0m\n" >&2
  printf "${bar}\033[2m   etc.\033[0m\n" >&2
  printf '\n' >&2
}

helm_uninstall_if_present() {
  local release="$1" ns="$2"
  if helmk status "$release" -n "$ns" >/dev/null 2>&1; then
    log "uninstalling helm release ${ns}/${release}"
    helmk uninstall "$release" -n "$ns" >/dev/null 2>&1 || true
  fi
}

# ============================================================================
# Container runtime + cluster predicates
# ============================================================================

# Toolchain auto-heal: a missing kind/kubectl/helm is brew-installed, a
# version below the tested floor is brew-upgraded, healthy tools are
# never touched. Rationale: host toolchains drift underneath users (a
# podman major upgrade broke kind's cluster listing in the wild) and
# "install via brew" errors push that drift onto them. Every action is
# logged; anything unexpected (no brew, unparseable version, failed
# upgrade) degrades to a warning and the run continues — this must
# never brick a working setup. Opt out: SANDBOX_NO_TOOL_AUTOFIX=1.
ensure_tools() {
  if [[ "${SANDBOX_NO_TOOL_AUTOFIX:-0}" == "1" ]]; then
    need kind; need kubectl; need helm
    return 0
  fi
  local line name installed floor action have_brew=0
  command -v brew >/dev/null 2>&1 && have_brew=1
  while IFS=' ' read -r name installed floor action; do
    [[ -n "$name" ]] || continue
    case "$action" in
      ok) ;;
      install)
        if (( have_brew )); then
          log "$name is missing — installing via brew"
          brew install "$name" >/dev/null 2>&1 \
            || die "auto-install of $name failed — install it manually (brew install $name)"
          ok "$name installed"
        else
          die "missing required command: $name (brew unavailable for auto-install)"
        fi
        ;;
      upgrade)
        if (( have_brew )); then
          log "$name $installed is below the tested floor $floor — upgrading via brew"
          if brew upgrade "$name" >/dev/null 2>&1 || brew install "$name" >/dev/null 2>&1; then
            ok "$name upgraded"
          else
            warn "could not auto-upgrade $name (installed: $installed, tested floor: $floor) — continuing anyway"
          fi
        else
          warn "$name $installed is below the tested floor $floor and brew is unavailable — continuing anyway"
        fi
        ;;
      *)
        warn "$name version could not be parsed — leaving it untouched"
        ;;
    esac
  done < <(command -v sandboxctl >/dev/null 2>&1 && sandboxctl _tool-check 2>/dev/null || true)
  # Whatever the auto-heal managed, the hard requirements still hold.
  need kind; need kubectl; need helm
}

require_tools() { ensure_tools; ensure_runtime; }

# _looks_like_product_repo <dir>
# A "product repo" for sandboxctl is anything with at least one
# Dockerfile, a Chart.yaml, or a sandboxctl.yaml within reasonable
# depth. Used to fail fast when the user runs build/deploy/bootstrap
# from an unrelated directory.
_looks_like_product_repo() {
  local target="$1"
  [[ -f "${target}/sandboxctl.yaml" || -f "${target}/sandboxctl.yml" ]] && return 0
  if find "$target" -maxdepth 5 -type d \
        \( -name node_modules -o -name vendor -o -name dist -o -name .git \) -prune \
      -o \( -type f \( -name Dockerfile -o -name Chart.yaml \) -print \) 2>/dev/null \
      | grep -q .; then
    return 0
  fi
  return 1
}

# _resolve_product_repo <flag-value> <positional-value> <cmd-name>
# Pick the product repo directory: --repo flag, then positional path,
# then cwd. Validates the result is a directory and looks repo-shaped.
# Echoes the absolute path on stdout; dies on any problem.
_resolve_product_repo() {
  # Named cmd_name (not cmd) to avoid colliding with helm_install's array
  # parameter of the same name — shellcheck conflates the two scopes (SC2178).
  local flag_repo="$1" positional="$2" cmd_name="$3"
  if [[ -n "$flag_repo" && -n "$positional" ]]; then
    die "${cmd_name}: pass either --repo <dir> or a positional path, not both"
  fi
  local target="${flag_repo:-${positional:-.}}"
  local explicit=0
  [[ -n "$flag_repo" || -n "$positional" ]] && explicit=1

  [[ -d "$target" ]] || die "${cmd_name}: '${target}' is not a directory"
  target="$(cd "$target" && pwd)"

  if ! _looks_like_product_repo "$target"; then
    if (( explicit )); then
      die "${cmd_name}: '${target}' doesn't look like a product repo
       (no Dockerfile, Chart.yaml, or sandboxctl.yaml found)"
    else
      die "${cmd_name}: current directory doesn't look like a product repo
       (no Dockerfile, Chart.yaml, or sandboxctl.yaml found).
       cd into your product repo, or pass --repo <dir>"
    fi
  fi
  printf '%s\n' "$target"
}

# ensure_tooling brew-installs developer tools that are commonly needed by
# apps deployed onto the sandbox (Go, Node, mise for runtime versions,
# fswatch for hot-reload). Skips anything already on PATH.
ensure_tooling() {
  command -v brew >/dev/null 2>&1 || { warn "brew unavailable — skipping dev tooling install"; return 0; }
  local tool installed=()
  for tool in go node mise fswatch; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      log "installing $tool via brew"
      brew install "$tool" >/dev/null
      installed+=("$tool")
    fi
  done
  if (( ${#installed[@]} > 0 )); then
    ok "installed: ${installed[*]}"
  fi
}

# ----- arctl (agentregistry CLI) -------------------------------------------
# arctl is host-side tooling, installed alongside kind/kubectl/helm rather
# than into the cluster. We download the release binary and verify its
# sha256 ourselves (idempotent + version-aware) instead of piping the
# upstream get-arctl installer to a shell.

arctl_installed_version() {
  # Prefer the binary we manage; fall back to whatever is on PATH. Checking
  # $ARCTL_INSTALL_DIR directly keeps the idempotency check correct even when
  # that dir isn't on the caller's PATH.
  local bin="${ARCTL_INSTALL_DIR}/arctl"
  [[ -x "$bin" ]] || bin="$(command -v arctl 2>/dev/null || true)"
  [[ -n "$bin" && -x "$bin" ]] || return 1
  "$bin" version --json 2>/dev/null | jq -r '.arctl_version' 2>/dev/null
}

arctl_resolve_version() {
  if [[ "$ARCTL_VERSION" == "latest" ]]; then
    curl -fsSL "https://api.github.com/repos/${ARCTL_REPO}/releases/latest" 2>/dev/null \
      | jq -r '.tag_name' 2>/dev/null
  else
    echo "$ARCTL_VERSION"
  fi
}

install_arctl() {
  (( INSTALL_ARCTL )) || { log "skipping arctl install (INSTALL_ARCTL=0)"; return 0; }
  command -v curl >/dev/null 2>&1 || { warn "arctl: curl not found — skipping install"; return 0; }
  command -v jq   >/dev/null 2>&1 || { warn "arctl: jq not found (brew install jq) — skipping install"; return 0; }

  local arch
  case "$(uname -m)" in
    arm64|aarch64) arch=arm64 ;;
    x86_64|amd64)  arch=amd64 ;;
    *) warn "arctl: unsupported architecture $(uname -m) — skipping"; return 0 ;;
  esac
  local os; os="$(uname | tr '[:upper:]' '[:lower:]')"

  local want; want="$(arctl_resolve_version || true)"
  if [[ -z "$want" || "$want" == "null" ]]; then
    warn "arctl: could not resolve a release version (offline?) — skipping"; return 0
  fi

  local have; have="$(arctl_installed_version || true)"
  if [[ -n "$have" && "$have" == "$want" ]]; then
    ok "arctl ${have} already installed (${ARCTL_INSTALL_DIR}/arctl)"; return 0
  fi

  log "installing arctl ${want} -> ${ARCTL_INSTALL_DIR}/arctl"
  local dist="arctl-${os}-${arch}"
  local base="https://github.com/${ARCTL_REPO}/releases/download/${want}"
  local tmp; tmp="$(mktemp -d -t arctl.XXXXXX)"

  if ! with_spinner "downloading arctl ${want} (${dist})" \
       curl -fsSL "${base}/${dist}" -o "${tmp}/arctl"; then
    rm -rf "$tmp"; warn "arctl: download failed (${base}/${dist}) — skipping"; return 0
  fi
  # Verify the published sha256 when present; refuse to install on mismatch.
  if with_spinner "verifying arctl checksum" \
       curl -fsSL "${base}/${dist}.sha256" -o "${tmp}/sum"; then
    local want_sum have_sum
    want_sum="$(awk '{print $1}' "${tmp}/sum")"
    have_sum="$(shasum -a 256 "${tmp}/arctl" | awk '{print $1}')"
    if [[ -n "$want_sum" && "$want_sum" != "$have_sum" ]]; then
      rm -rf "$tmp"; warn "arctl: checksum mismatch — refusing to install"; return 0
    fi
  fi
  chmod +x "${tmp}/arctl"

  # /usr/local/bin is root-owned on macOS — use sudo only when the target
  # directory isn't already writable by the current user.
  if [[ -w "$ARCTL_INSTALL_DIR" ]]; then
    mv -f "${tmp}/arctl" "${ARCTL_INSTALL_DIR}/arctl"
  else
    prime_sudo
    sudo mkdir -p "$ARCTL_INSTALL_DIR"
    sudo install -m 0755 "${tmp}/arctl" "${ARCTL_INSTALL_DIR}/arctl"
  fi
  rm -rf "$tmp"
  ok "arctl ${want} installed — run 'arctl version', then open http://localhost:12121"
}

uninstall_arctl() {
  [[ "${SANDBOX_KEEP_ARCTL:-0}" == "1" ]] && { ok "keeping arctl (SANDBOX_KEEP_ARCTL=1)"; return 0; }
  local bin="${ARCTL_INSTALL_DIR}/arctl"
  if [[ -e "$bin" ]]; then
    log "removing arctl ($bin)"
    if [[ -w "$ARCTL_INSTALL_DIR" ]]; then rm -f "$bin"
    else prime_sudo; sudo rm -f "$bin"; fi
  fi
  ok "arctl removed (no-op if it wasn't installed)"
}

runtime_fallback() {
  local reason="$1" other
  case "$SANDBOX_RUNTIME" in podman) other=docker ;; docker) other=podman ;; esac
  command -v "$other" >/dev/null 2>&1 || return 1
  warn "$reason — falling back to $other"
  SANDBOX_RUNTIME="$other"
  if [[ "$SANDBOX_RUNTIME" == "podman" ]]; then export KIND_EXPERIMENTAL_PROVIDER=podman
  else unset KIND_EXPERIMENTAL_PROVIDER; fi
}

ensure_runtime() {
  # Auto-heal podman if unhealthy; fall back to docker only if podman
  # is missing. macOS docker daemon needs the GUI, so we don't try to
  # start it ourselves.
  # shellcheck disable=SC2034
  local _attempt
  for _attempt in 1 2; do
    case "$SANDBOX_RUNTIME" in
      podman)
        if ! command -v podman >/dev/null 2>&1; then
          runtime_fallback "podman not installed" || die "neither podman nor docker is available; install one and retry"
          continue
        fi
        if ! podman info >/dev/null 2>&1; then
          log "podman runtime not ready — auto-running setup-podman"
          cmd_setup_podman
        fi
        local rootful
        rootful="$(podman machine inspect --format '{{.Rootful}}' 2>/dev/null || echo false)"
        if [[ "$rootful" != "true" ]]; then
          log "podman machine not rootful — auto-running setup-podman"
          cmd_setup_podman
        fi
        if podman info >/dev/null 2>&1; then ok "using podman as kind provider"; return 0; fi
        runtime_fallback "podman is installed but unhealthy after setup-podman" || \
          die "podman unhealthy and docker unavailable; inspect 'podman machine list' / 'podman machine inspect'"
        ;;
      docker)
        if ! command -v docker >/dev/null 2>&1; then
          runtime_fallback "docker not installed" || die "neither docker nor podman is available; install one and retry"
          continue
        fi
        if ! docker info >/dev/null 2>&1; then
          runtime_fallback "docker daemon not running (start Docker Desktop, or use podman: 'sandboxctl setup-podman')" || \
            die "docker not running and podman unavailable; start Docker Desktop or run: sandboxctl setup-podman"
          continue
        fi
        ok "using docker as kind provider"; return 0
        ;;
    esac
  done
  die "could not select a working container runtime"
}

# Do NOT use `kind get clusters` here: kind's ListClusters template
# (`{{index .Labels "…"}}`) hard-errors on podman >= 6, where the ps
# template's .Labels changed from map to slice (same class as
# kubernetes-sigs/kind#3813). The runtime label query below is what the
# rest of this script already uses and works on docker + podman 5/6 —
# node containers count whether running or stopped. Without this, `up`
# on podman 6 believed no cluster existed and collided with its own
# nodes at create time.
cluster_registered()    { cluster_node_containers 2>/dev/null | grep -q .; }
cluster_api_reachable() { kc --request-timeout=3s cluster-info >/dev/null 2>&1; }
cluster_node_containers() {
  "$SANDBOX_RUNTIME" ps -a --filter "label=io.x-k8s.kind.cluster=$CLUSTER_NAME" --format '{{.Names}}'
}

cluster_uses_legacy_extra_port_mappings() {
  # Older configs bound :80/:443/:30080/:30443 on the kind container. Those
  # don't work on macOS+rootful podman; force a recreate if detected.
  local cp
  cp="$("$SANDBOX_RUNTIME" inspect "${CLUSTER_NAME}-control-plane" \
    --format '{{json .HostConfig.PortBindings}}' 2>/dev/null || echo '{}')"
  echo "$cp" | grep -qE '"(80|443|30080|30443)/tcp"'
}

start_stopped_cluster() {
  local containers
  containers="$(cluster_node_containers)"
  [[ -n "$containers" ]] || die "cluster '$CLUSTER_NAME' is registered but has no node containers — run: sandboxctl down && sandboxctl up"
  log "starting stopped kind nodes for '$CLUSTER_NAME'"
  echo "$containers" | xargs "$SANDBOX_RUNTIME" start >/dev/null
  log "waiting for kube-apiserver"
  local i
  for ((i=1; i<=60; i++)); do
    if cluster_api_reachable; then ok "cluster API ready"; return 0; fi
    sleep 2
  done
  die "kube-apiserver did not become reachable within 120s; try: sandboxctl down && sandboxctl up"
}

require_running_cluster() {
  cluster_registered    || die "no cluster named '$CLUSTER_NAME' — run 'sandboxctl up' first"
  cluster_api_reachable || die "cluster '$CLUSTER_NAME' is stopped — run 'sandboxctl up' to start it"
}

# ============================================================================
# Setup-podman
# ============================================================================

# Apply Podman VM sizing without going through cmd_setup_podman's full
# install/init pipeline. Used by `sandboxctl up`/`restart` when the user
# passes --podman-cpus/--podman-memory/--podman-disk: we just want to
# resize an existing rootful machine, write the persisted config, and
# keep going. cmd_setup_podman is still the right tool for first-time
# install or a full --recreate.
#
# Args (all optional, blank = leave alone): cpus, mem_mib, disk_gib.
_apply_podman_sizing() {
  [[ "$SANDBOX_RUNTIME" == "podman" ]] || {
    warn "--podman-* flags ignored: SANDBOX_RUNTIME=${SANDBOX_RUNTIME}"
    return 0
  }
  local cpus="${1:-}" mem_mib="${2:-}" disk_gib="${3:-}"

  # Feed the requested values into the env vars that the rest of the
  # script reads, so `setup-podman` (auto-invoked from bring_up_cluster
  # when needed) and `cmd_setup_podman` see the user's choice as the new
  # default for this run.
  [[ -n "$cpus"     ]] && PODMAN_MACHINE_CPUS="$cpus"
  [[ -n "$mem_mib"  ]] && PODMAN_MACHINE_MEMORY_MIB="$mem_mib"
  [[ -n "$disk_gib" ]] && PODMAN_MACHINE_DISK_GIB="$disk_gib"
  export PODMAN_MACHINE_CPUS PODMAN_MACHINE_MEMORY_MIB PODMAN_MACHINE_DISK_GIB

  # Persist before any podman command runs — even if a resize fails the
  # user's intent is recorded so the next `restart --rebuild` honours it.
  write_podman_config "$cpus" "$mem_mib" "$disk_gib"
  log "saved podman sizing → $SANDBOX_PODMAN_CONFIG (cpus=${PODMAN_MACHINE_CPUS:-unchanged}, memory=${PODMAN_MACHINE_MEMORY_MIB:-unchanged} MiB, disk=${PODMAN_MACHINE_DISK_GIB:-unchanged} GiB)"

  if ! command -v podman >/dev/null 2>&1; then
    log "podman not installed yet — skipping live resize; values will apply on next 'sandboxctl setup-podman'"
    return 0
  fi

  local machine_exists=0
  podman machine list --format '{{.Name}}' 2>/dev/null | grep -q . && machine_exists=1

  if (( ! machine_exists )); then
    log "no podman machine yet — values will apply on first 'sandboxctl setup-podman'"
    return 0
  fi

  local cur_disk_gib state
  cur_disk_gib="$(podman machine inspect --format '{{.Resources.DiskSize}}' 2>/dev/null || echo 0)"
  state="$(podman machine inspect --format '{{.State}}' 2>/dev/null || echo unknown)"

  # Live `podman machine set` only handles cpus/memory/rootful; disk
  # changes need --recreate, which is destructive. If the user asked for
  # a bigger disk, surface the exact command — never silently no-op.
  if [[ -n "$disk_gib" ]] && (( cur_disk_gib > 0 )) && (( cur_disk_gib < disk_gib )); then
    warn "podman machine disk is ${cur_disk_gib} GiB — requested ${disk_gib} GiB"
    warn "podman cannot grow a machine's disk in place. To resize disk:"
    warn "  sandboxctl setup-podman --disk-size ${disk_gib} --memory ${PODMAN_MACHINE_MEMORY_MIB} --cpus ${PODMAN_MACHINE_CPUS} --recreate"
    warn "  (this destroys all images/containers/kind clusters inside the VM — back up first)"
  fi

  if [[ -n "$cpus" || -n "$mem_mib" ]]; then
    if [[ "$state" == "running" ]]; then
      log "stopping podman machine to apply sizing changes"
      podman machine stop || warn "podman machine stop failed — continuing"
    fi
    local set_args=(--rootful)
    [[ -n "$cpus"    ]] && set_args+=(--cpus    "$cpus")
    [[ -n "$mem_mib" ]] && set_args+=(--memory  "$mem_mib")
    log "podman machine set ${set_args[*]}"
    podman machine set "${set_args[@]}" || warn "podman machine set failed — continuing"
    log "starting podman machine"
    podman machine start || die "podman machine start failed — inspect 'podman machine list'"
  fi
}

cmd_setup_podman() {
  [[ "$SANDBOX_RUNTIME" == "podman" ]] || die "SANDBOX_RUNTIME=$SANDBOX_RUNTIME — setup-podman only configures the podman runtime"

  # Per-invocation overrides for the env defaults. --disk-size is the
  # one that *can't* be applied to an existing machine (podman has no
  # way to grow the qcow2 in place); --recreate is the escape hatch that
  # tears the machine down and rebuilds it at the requested size.
  local opt_disk_gib="$PODMAN_MACHINE_DISK_GIB"
  local opt_mem_mib="$PODMAN_MACHINE_MEMORY_MIB"
  local opt_cpus="$PODMAN_MACHINE_CPUS"
  local opt_recreate=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --disk-size) opt_disk_gib="${2:-}"; shift 2 ;;
      --memory)    opt_mem_mib="${2:-}";  shift 2 ;;
      --cpus)      opt_cpus="${2:-}";     shift 2 ;;
      --recreate)  opt_recreate=1;        shift ;;
      -h|--help)
        cat <<EOF
sandboxctl setup-podman [--disk-size <GiB>] [--memory <MiB>] [--cpus <N>] [--recreate]

Install/configure a rootful podman machine sized for the sandbox.

  --disk-size <GiB>   reserve this much disk for the podman VM (default
                      ${PODMAN_MACHINE_DISK_GIB} or \$PODMAN_MACHINE_DISK_GIB).
                      podman cannot grow an existing machine's disk in
                      place — if the existing machine is smaller, this
                      command warns and prints the --recreate command
                      you can run to resize.
  --memory <MiB>      RAM for the podman VM (default ${PODMAN_MACHINE_MEMORY_MIB} or
                      \$PODMAN_MACHINE_MEMORY_MIB). Applied to an
                      existing machine without recreate.
  --cpus <N>          CPU count (default ${PODMAN_MACHINE_CPUS} or \$PODMAN_MACHINE_CPUS).
                      Applied to an existing machine without recreate.
  --recreate          stop + remove + re-init the podman machine at
                      the requested disk/memory/cpus. DESTRUCTIVE: any
                      images, containers, or kind clusters living
                      inside the VM are gone afterwards.
EOF
        return 0 ;;
      *) die "setup-podman: unknown flag: $1 (try --help)" ;;
    esac
  done

  [[ "$opt_disk_gib" =~ ^[0-9]+$ ]] || die "setup-podman: --disk-size must be a positive integer (GiB), got '${opt_disk_gib}'"
  [[ "$opt_mem_mib"  =~ ^[0-9]+$ ]] || die "setup-podman: --memory must be a positive integer (MiB), got '${opt_mem_mib}'"
  [[ "$opt_cpus"     =~ ^[0-9]+$ ]] || die "setup-podman: --cpus must be a positive integer, got '${opt_cpus}'"

  if ! command -v podman >/dev/null 2>&1; then
    command -v brew >/dev/null 2>&1 || die "podman not installed and brew is unavailable"
    log "installing podman via brew"
    brew install podman
  fi
  ok "podman: $(podman --version)"

  local machine_exists=0
  podman machine list --format '{{.Name}}' 2>/dev/null | grep -q . && machine_exists=1

  # --recreate: rip the machine out and rebuild from scratch at the
  # requested geometry. Only path that can grow disk-size; everything
  # inside the VM is forfeit.
  if (( opt_recreate )) && (( machine_exists )); then
    log "destroying existing podman machine to recreate at ${opt_cpus} CPU / ${opt_mem_mib} MiB / ${opt_disk_gib} GiB"
    podman machine stop 2>/dev/null || true
    podman machine rm -f 2>/dev/null || die "could not remove existing podman machine"
    machine_exists=0
  fi

  if (( ! machine_exists )); then
    log "creating podman-machine-default (rootful, ${opt_cpus} CPU, ${opt_mem_mib} MiB, ${opt_disk_gib} GiB disk)"
    podman machine init \
      --cpus "$opt_cpus" \
      --memory "$opt_mem_mib" \
      --disk-size "$opt_disk_gib" \
      --rootful
  fi

  local state rootful mem cur_disk_gib
  state="$(podman machine inspect --format '{{.State}}' 2>/dev/null || echo unknown)"
  rootful="$(podman machine inspect --format '{{.Rootful}}' 2>/dev/null || echo false)"
  mem="$(podman machine inspect --format '{{.Resources.Memory}}' 2>/dev/null || echo 0)"
  cur_disk_gib="$(podman machine inspect --format '{{.Resources.DiskSize}}' 2>/dev/null || echo 0)"

  local needs_apply=0
  [[ "$rootful" != "true" ]]               && needs_apply=1
  [[ "${mem:-0}" -lt "$opt_mem_mib" ]]     && needs_apply=1

  if [[ "$needs_apply" == "1" ]]; then
    if [[ "$state" == "running" ]]; then
      log "stopping podman machine to apply config changes"
      podman machine stop
      state="stopped"
    fi
    log "configuring podman machine: rootful=true, memory>=${opt_mem_mib} MiB"
    podman machine set --rootful --memory "$opt_mem_mib"
  fi

  # podman has no in-place disk grow. If the user asked for more than
  # what's there, tell them exactly which command to run instead of
  # silently keeping the smaller disk.
  if (( cur_disk_gib > 0 )) && (( cur_disk_gib < opt_disk_gib )); then
    warn "podman machine disk is ${cur_disk_gib} GiB, requested ${opt_disk_gib} GiB"
    warn "podman cannot grow a machine's disk in place. To resize:"
    warn "  sandboxctl setup-podman --disk-size ${opt_disk_gib} --memory ${opt_mem_mib} --cpus ${opt_cpus} --recreate"
    warn "  (this destroys all images/containers/kind clusters inside the VM — back up first if needed)"
  fi

  if [[ "$state" != "running" ]]; then
    log "starting podman machine"
    podman machine start
  fi
  ok "podman ready (kind will use KIND_EXPERIMENTAL_PROVIDER=podman)"
}

# ============================================================================
# Cluster bring-up + helm installs
# ============================================================================

# validate_worker_count refuses anything that isn't an integer in
# [SANDBOX_WORKER_COUNT_MIN, SANDBOX_WORKER_COUNT_MAX]. Called by every
# entry point that reads the --workers flag so a bad value fails before
# any cluster work starts.
validate_worker_count() {
  local v="$1" caller="${2:-sandboxctl}"
  if ! [[ "$v" =~ ^[0-9]+$ ]]; then
    die "${caller}: --workers must be an integer 1–${SANDBOX_WORKER_COUNT_MAX} (got '${v}')"
  fi
  if (( v < SANDBOX_WORKER_COUNT_MIN || v > SANDBOX_WORKER_COUNT_MAX )); then
    die "${caller}: --workers must be between ${SANDBOX_WORKER_COUNT_MIN} and ${SANDBOX_WORKER_COUNT_MAX} (got ${v}). Local dev caps at ${SANDBOX_WORKER_COUNT_MAX} workers — beyond that the Mac runs out of memory before the cluster does."
  fi
}

# kind_config_path returns a path to a kind config file matching the
# requested worker count. When the count is 1 we use the on-disk
# kind-config.yaml unchanged (preserves existing comments + the
# historical default). When the count is >1 we generate a temp file with
# the same control-plane block plus N worker entries.
kind_config_path() {
  local workers="${SANDBOX_WORKER_COUNT}"
  if [[ "$workers" == "1" ]]; then
    printf '%s' "$KIND_CONFIG"
    return
  fi
  local tmp
  tmp="$(mktemp -t sandboxctl-kind-XXXXXX.yaml)"
  {
    cat <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
# Generated by sandboxctl from --workers / SANDBOX_WORKER_COUNT.
# See ./kind-config.yaml for the canonical single-node config and the
# explanatory comments about extraPortMappings + registry mirror.
nodes:
  - role: control-plane
EOF
    local i
    for ((i = 0; i < workers; i++)); do
      printf '  - role: worker\n'
    done
  } > "$tmp"
  printf '%s' "$tmp"
}

bring_up_cluster() {
  if cluster_registered; then
    if cluster_uses_legacy_extra_port_mappings; then
      die "cluster '$CLUSTER_NAME' was created with the old kind port mappings — run: sandboxctl restart"
    fi
    if cluster_api_reachable; then
      ok "kind cluster '$CLUSTER_NAME' is already up"
    else
      warn "kind cluster '$CLUSTER_NAME' is registered but stopped — starting it"
      start_stopped_cluster
    fi
    # If the user asked for a worker count that doesn't match the live
    # cluster, tell them — kind can't add/remove nodes to an existing
    # cluster, so silently honouring the old count would be misleading.
    local live_workers
    live_workers="$("$SANDBOX_RUNTIME" ps --filter "label=io.x-k8s.kind.cluster=$CLUSTER_NAME" --format '{{.Names}}' 2>/dev/null \
      | grep -c -- '-worker' || true)"
    if [[ -n "$live_workers" ]] && (( live_workers != SANDBOX_WORKER_COUNT )); then
      warn "cluster has ${live_workers} worker$([[ "$live_workers" = "1" ]] || echo s), but --workers ${SANDBOX_WORKER_COUNT} was requested — keeping ${live_workers}"
      warn "to resize: 'sandboxctl restart --workers ${SANDBOX_WORKER_COUNT} --rebuild' (recreates the cluster)"
    fi
    write_pinned_kubeconfig
    return
  fi
  if ! "$SANDBOX_RUNTIME" image exists "$KIND_NODE_IMAGE" >/dev/null 2>&1; then
    log "pre-pulling $KIND_NODE_IMAGE (one-time, ~750 MB)"
    with_spinner "pulling kind node image (~750 MB, can take 2–4 min on first run)" \
      "$SANDBOX_RUNTIME" pull "$KIND_NODE_IMAGE" \
      || warn "pre-pull failed; kind will retry the pull itself"
  fi
  local config_file
  config_file="$(kind_config_path)"
  log "creating kind cluster '$CLUSTER_NAME' (1 control-plane + ${SANDBOX_WORKER_COUNT} worker$([ "$SANDBOX_WORKER_COUNT" = "1" ] || echo "s"))"
  with_spinner "kind create cluster (typically 1–3 min)" \
    kind_pinned create cluster --name "$CLUSTER_NAME" --image "$KIND_NODE_IMAGE" --config "$config_file"
  # Clean up the generated temp config — only the on-disk default is
  # preserved across runs (the temp file's only job was to feed kind).
  if [[ "$config_file" != "$KIND_CONFIG" ]]; then
    rm -f "$config_file"
  fi
  write_pinned_kubeconfig
  configure_node_registry_mirror
}

# Materialize a kubeconfig the LaunchAgent can use. We force kind to
# write the cluster's context to ~/.kube/config (see kind_pinned), so
# the user's `kubectl` works in any new shell without an env-var dance.
# But launchd jobs don't inherit $KUBECONFIG, so we ALSO pin a copy
# under $SANDBOX_STATE_DIR for the port-forward agent — that path is
# baked into the plist and immune to whatever the user later does to
# their shell environment.
write_pinned_kubeconfig() {
  mkdir -p "$SANDBOX_STATE_DIR"
  if ! kind_pinned get kubeconfig --name "$CLUSTER_NAME" > "${SANDBOX_KUBECONFIG}.tmp" 2>/dev/null; then
    rm -f "${SANDBOX_KUBECONFIG}.tmp"
    # kind subcommands can fail on runtime/CLI mismatches (e.g. the
    # podman 6 template break) even while the cluster itself is fine.
    # A pinned kubeconfig from an earlier run still points at the same
    # cluster endpoint + certs — reuse it rather than dying.
    if [[ -s "$SANDBOX_KUBECONFIG" ]] && kc --request-timeout=5s cluster-info >/dev/null 2>&1; then
      warn "kind get kubeconfig failed — reusing the existing pinned kubeconfig (cluster answers)"
      return 0
    fi
    die "kind get kubeconfig --name $CLUSTER_NAME failed — cluster may not be ready"
  fi
  chmod 600 "${SANDBOX_KUBECONFIG}.tmp"
  mv "${SANDBOX_KUBECONFIG}.tmp" "$SANDBOX_KUBECONFIG"
}

configure_node_registry_mirror() {
  # hosts.toml mechanism (modern). The legacy `mirrors` block crashes
  # containerd v2's CRI plugin with "mirrors cannot be set when
  # config_path is provided" — see commit 4c68caa.
  local nodes node host_dir
  nodes="$("$SANDBOX_RUNTIME" ps --filter "label=io.x-k8s.kind.cluster=$CLUSTER_NAME" --format '{{.Names}}')"
  [[ -n "$nodes" ]] || { warn "no kind nodes found to configure registry mirror"; return 0; }

  log "configuring containerd registry mirror localhost:${SANDBOX_REGISTRY_PORT} → in-cluster registry"
  host_dir="/etc/containerd/certs.d/localhost:${SANDBOX_REGISTRY_PORT}"
  # Two notes:
  #  1. `podman exec` (and `docker exec`) require `-i` for stdin to flow
  #     into the in-container `sh -c "cat > …"`. Without it the heredoc
  #     hits EOF immediately and writes a zero-byte hosts.toml.
  #  2. The mirror endpoint must be a host the kind node's containerd
  #     can resolve. Cluster-DNS Service names (registry.<ns>.svc.cluster.local)
  #     fail because the kind node's resolver doesn't go through
  #     CoreDNS. Use 127.0.0.1:<NodePort> instead — `install_registry`
  #     pins the Service to NodePort 30050 inside the kind node.
  local registry_endpoint="http://127.0.0.1:${SANDBOX_REGISTRY_NODEPORT}"
  for node in $nodes; do
    "$SANDBOX_RUNTIME" exec "$node" mkdir -p "$host_dir"
    "$SANDBOX_RUNTIME" exec -i "$node" sh -c "cat > '$host_dir/hosts.toml'" <<EOF
server = "https://registry-1.docker.io"

[host."${registry_endpoint}"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF
  done
  ok "registry mirror configured on $(echo "$nodes" | wc -w | tr -d ' ') node(s) → ${registry_endpoint}"
}

install_cert_manager() {
  log "installing cert-manager (ns: $CERT_MANAGER_NS, chart $CERT_MANAGER_CHART_VERSION)"
  helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
  helm repo update jetstack >/dev/null
  # helm_install skips when already deployed, and self-heals the ownership
  # conflict an interrupted earlier run leaves on cert-manager's RBAC
  # (the classic Role "cert-manager-tokenrequest" ... cannot be imported).
  helm_install "cert-manager helm install (typically 1–2 min)" \
    helm upgrade --install cert-manager jetstack/cert-manager \
      --namespace "$CERT_MANAGER_NS" --create-namespace \
      --version "$CERT_MANAGER_CHART_VERSION" \
      --set crds.enabled=true \
      --set 'resources.requests.cpu=10m'           --set 'resources.requests.memory=64Mi' \
      --set 'webhook.resources.requests.cpu=10m'   --set 'webhook.resources.requests.memory=32Mi' \
      --set 'cainjector.resources.requests.cpu=10m' --set 'cainjector.resources.requests.memory=64Mi' \
      --wait --timeout 5m
  # Post-install/upgrade settle: the webhook Deployment being Ready is
  # not the same as the webhook answering — prove the call path before
  # anything downstream creates Certificates.
  wait_for_cert_manager_webhook || true
  ok "cert-manager ready"
}

install_pki() {
  # selfsigned-bootstrap → sandbox-root-ca → sandbox-ca → sandbox-wildcard.
  # The wildcard secret lives in $ISTIO_INGRESS_NS so the gateway can mount
  # it via credentialName.
  log "installing local PKI (CA chain + *.${SANDBOX_DOMAIN} wildcard)"
  kc create namespace "$ISTIO_INGRESS_NS" --dry-run=client -o yaml | kc apply -f - >/dev/null

  kc apply -f - <<EOF >/dev/null
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: { name: selfsigned-bootstrap }
spec: { selfSigned: {} }
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: { name: sandbox-root-ca, namespace: ${CERT_MANAGER_NS} }
spec:
  isCA: true
  commonName: ${ROOT_CA_CN}
  secretName: ${ROOT_CA_SECRET}
  duration: 87600h    # 10 years
  privateKey: { algorithm: ECDSA, size: 256 }
  issuerRef: { name: selfsigned-bootstrap, kind: ClusterIssuer, group: cert-manager.io }
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: { name: sandbox-ca }
spec:
  ca: { secretName: ${ROOT_CA_SECRET} }
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: sandbox-wildcard
  namespace: ${ISTIO_INGRESS_NS}
spec:
  secretName: ${WILDCARD_TLS_SECRET}
  duration: 8760h
  renewBefore: 720h
  commonName: "*.${SANDBOX_DOMAIN}"
  dnsNames: ["${SANDBOX_DOMAIN}", "*.${SANDBOX_DOMAIN}"]
  issuerRef:
    name: sandbox-ca
    kind: ClusterIssuer
    group: cert-manager.io
EOF

  log "waiting for sandbox-root-ca + wildcard cert to be issued"
  kc -n "$CERT_MANAGER_NS"  wait --for=condition=Ready --timeout=180s certificate/sandbox-root-ca >/dev/null
  kc -n "$ISTIO_INGRESS_NS" wait --for=condition=Ready --timeout=180s certificate/sandbox-wildcard >/dev/null
  ok "PKI ready"
}

install_argocd() {
  resolve_chart_version ARGOCD_CHART_VERSION argo-cd
  log "installing Argo CD (ns: $ARGOCD_NS, chart $ARGOCD_CHART_VERSION)"
  helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
  helm repo update argo >/dev/null
  # server.insecure=true makes argocd-server speak HTTP on :80 so the gateway
  # can terminate TLS without re-encrypting upstream.
  #
  # Full-featured profile minus SSO: applicationset (needed by the
  # scaffold-generated GitOps wiring) and notifications stay enabled;
  # only dex is dropped — a single-user sandbox has no SSO to broker.
  # Every component gets a small request so the scheduler packs them
  # tightly and the control plane keeps its memory.
  helm_install "Argo CD helm install (typically 2–5 min)" \
    helm upgrade --install argocd argo/argo-cd \
      --namespace "$ARGOCD_NS" --create-namespace \
      --version "$ARGOCD_CHART_VERSION" \
      --set 'configs.params.server\.insecure=true' \
      --set 'dex.enabled=false' \
      --set 'applicationSet.resources.requests.cpu=25m'   --set 'applicationSet.resources.requests.memory=64Mi' \
      --set 'notifications.resources.requests.cpu=10m'    --set 'notifications.resources.requests.memory=64Mi' \
      --set 'controller.replicas=1' \
      --set 'controller.resources.requests.cpu=50m'      --set 'controller.resources.requests.memory=256Mi' \
      --set 'repoServer.resources.requests.cpu=25m'      --set 'repoServer.resources.requests.memory=128Mi' \
      --set 'server.resources.requests.cpu=25m'          --set 'server.resources.requests.memory=128Mi' \
      --set 'redis.resources.requests.cpu=25m'           --set 'redis.resources.requests.memory=64Mi' \
      --wait --timeout 10m
  ok "Argo CD ready (applicationset + notifications on; dex off)"
}

install_reflector() {
  # Mirrors annotated Secrets/ConfigMaps across namespaces. Used by the
  # fiber chart to push fiber-secrets into github-mcp without touching
  # sandboxctl. Inert until something is actually annotated.
  log "installing reflector (ns: $REFLECTOR_NS, chart $REFLECTOR_CHART_VERSION)"
  helm repo add emberstack https://emberstack.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update emberstack >/dev/null
  helm_install "reflector helm install (typically 30–60s)" \
    helm upgrade --install reflector emberstack/reflector \
      --namespace "$REFLECTOR_NS" --create-namespace \
      --version "$REFLECTOR_CHART_VERSION" \
      --set 'resources.requests.cpu=10m' --set 'resources.requests.memory=32Mi' \
      --set 'resources.limits.memory=128Mi' \
      --wait --timeout 5m
  ok "reflector ready"
}

install_reloader() {
  # stakater/Reloader watches Secrets + ConfigMaps and rolls the
  # workloads that consume them whenever a value changes. Workloads opt
  # in via either:
  #   reloader.stakater.com/auto: "true"            (rolls on any used CM/Secret change)
  #   secret.reloader.stakater.com/reload: "<name>" (only when <name> changes)
  # No further configuration needed — chart defaults watch all
  # namespaces.
  log "installing stakater/Reloader (ns: $RELOADER_NS, chart $RELOADER_CHART_VERSION)"
  helm repo add stakater https://stakater.github.io/stakater-charts >/dev/null 2>&1 || true
  helm repo update stakater >/dev/null
  helm_install "Reloader helm install (typically 30–60s)" \
    helm upgrade --install reloader stakater/reloader \
      --namespace "$RELOADER_NS" --create-namespace \
      --version "$RELOADER_CHART_VERSION" \
      --set 'reloader.deployment.resources.requests.cpu=10m' \
      --set 'reloader.deployment.resources.requests.memory=32Mi' \
      --set 'reloader.deployment.resources.limits.memory=128Mi' \
      --wait --timeout 5m
  ok "reloader ready (annotate workloads with reloader.stakater.com/auto: \"true\")"
}

install_kargo() {
  resolve_chart_version KARGO_CHART_VERSION kargo
  # Scaffold-generated Kargo manifests use the yaml-update promotion
  # vocabulary, which needs Kargo >= 1.3 (helm-update-image was removed
  # there). Warn early when an operator override pins something older.
  if command -v sandboxctl >/dev/null 2>&1 \
      && sandboxctl _semver-lt "$KARGO_CHART_VERSION" 1.3.0 2>/dev/null; then
    warn "KARGO_CHART_VERSION=$KARGO_CHART_VERSION is below 1.3.0 — scaffold-generated promotion manifests will not work on it"
  fi
  log "installing Kargo (ns: $KARGO_NS, chart $KARGO_CHART_VERSION)"
  helm_install "Kargo helm install (typically 2–4 min)" \
    helm upgrade --install kargo oci://ghcr.io/akuity/kargo-charts/kargo \
      --namespace "$KARGO_NS" --create-namespace \
      --version "$KARGO_CHART_VERSION" \
      --set api.adminAccount.passwordHash="$KARGO_ADMIN_PASSWORD_HASH" \
      --set api.adminAccount.tokenSigningKey="$KARGO_TOKEN_SIGNING_KEY" \
      --set controller.argocd.namespace="$ARGOCD_NS" \
      --set 'api.resources.requests.cpu=25m'        --set 'api.resources.requests.memory=128Mi' \
      --set 'controller.resources.requests.cpu=25m' --set 'controller.resources.requests.memory=128Mi' \
      --wait --timeout 10m
  ok "Kargo ready"
}

install_demo_app() {
  log "registering demo app with Argo CD (sync from ${DEMO_APP_REPO_URL}@${DEMO_APP_REPO_REVISION})"
  # Deployed via Argo CD so the UI demonstrates GitOps end-to-end.
  kc apply -f - <<EOF >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: demo-app
  namespace: ${ARGOCD_NS}
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: ${DEMO_APP_REPO_URL}
    targetRevision: ${DEMO_APP_REPO_REVISION}
    path: manifests/demo-app
  destination:
    server: https://kubernetes.default.svc
    namespace: ${DEMO_NS}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ApplyOutOfSyncOnly=true
      - ServerSideApply=true
EOF

  log "waiting for Argo CD to sync the demo app (Healthy)"
  local i sync health
  for ((i=1; i<=60; i++)); do
    sync="$(kc -n "$ARGOCD_NS" get application demo-app -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    health="$(kc -n "$ARGOCD_NS" get application demo-app -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    if [[ "$sync" == "Synced" && "$health" == "Healthy" ]]; then
      ok "demo app synced and healthy (${sync}/${health})"
      return 0
    fi
    sleep 3
  done
  warn "demo app did not become Healthy within 180s — check Argo CD UI at https://${ARGO_HOST}:${SANDBOX_HTTPS_PORT}"
  warn "current state: sync=${sync:-unknown} health=${health:-unknown}"
}

install_registry() {
  # Mac pushes via the socat proxy on $SANDBOX_REGISTRY_PORT; in-cluster
  # Pods pull via the containerd hosts.toml mirror configured at cluster
  # create. Image name is identical from both sides.
  log "installing in-cluster registry (ns: ${REGISTRY_NS}, host port: ${SANDBOX_REGISTRY_PORT}, storage: ${SANDBOX_REGISTRY_STORAGE})"
  kc create namespace "$REGISTRY_NS" --dry-run=client -o yaml | kc apply -f - >/dev/null

  kc apply -f - <<EOF >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: registry
  namespace: ${REGISTRY_NS}
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: ${SANDBOX_REGISTRY_STORAGE}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: registry
  namespace: ${REGISTRY_NS}
  labels:
    app: registry
spec:
  replicas: 1
  selector:
    matchLabels: { app: registry }
  strategy:
    type: Recreate     # only one writer at a time on the PVC
  template:
    metadata:
      labels: { app: registry }
    spec:
      containers:
        - name: registry
          image: registry:2
          ports:
            - { name: http, containerPort: 5000 }
          env:
            - { name: REGISTRY_STORAGE_DELETE_ENABLED, value: "true" }
          readinessProbe:
            httpGet: { path: /, port: http }
            periodSeconds: 5
          resources:
            requests: { cpu: 10m, memory: 32Mi }
            limits:   { memory: 256Mi }
          volumeMounts:
            - { name: data, mountPath: /var/lib/registry }
      volumes:
        - name: data
          persistentVolumeClaim: { claimName: registry }
---
apiVersion: v1
kind: Service
metadata:
  name: registry
  namespace: ${REGISTRY_NS}
spec:
  type: NodePort
  selector: { app: registry }
  ports:
    # nodePort fixed so install_registry_proxy can target a stable
    # kind-node:port. 30050 mirrors the host-side default 5050.
    - { name: http, port: 5000, targetPort: http, nodePort: 30050 }
---
# Tilt / Skaffold / etc. read this ConfigMap to discover the registry.
# https://github.com/kubernetes/enhancements/tree/master/keps/sig-cluster-lifecycle/generic/1755-communicating-a-local-registry
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${SANDBOX_REGISTRY_PORT}"
    hostFromContainerRuntime: "registry.${REGISTRY_NS}.svc.cluster.local:5000"
    hostFromClusterNetwork: "registry.${REGISTRY_NS}.svc.cluster.local:5000"
    help: "https://github.com/tesserix/sandboxctl#registry"
EOF

  kc -n "$REGISTRY_NS" rollout status deploy/registry --timeout=180s >/dev/null
  ok "registry ready (push: localhost:${SANDBOX_REGISTRY_PORT}/<image>:<tag>)"
}

install_kagent() {
  # Install only the kagent controller + UI. No model provider is wired
  # here (no Ollama, no API-key providers, no model pulls); users hook a
  # provider up themselves after the install.
  log "installing kagent (ns: $KAGENT_NS, chart $KAGENT_CHART_VERSION) — controller + UI only, no model provider"

  # CRDs ship as a separate chart, must land first.
  helm_install "kagent CRDs helm install (typically 30s)" \
    helm upgrade --install kagent-crds oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds \
      --namespace "$KAGENT_NS" --create-namespace \
      --version "$KAGENT_CHART_VERSION" \
      --wait --timeout 5m

  helm_install "kagent helm install (typically 3–5 min)" \
    helm upgrade --install kagent oci://ghcr.io/kagent-dev/kagent/helm/kagent \
      --namespace "$KAGENT_NS" \
      --version "$KAGENT_CHART_VERSION" \
      --wait --timeout 10m

  with_spinner "waiting for kagent UI pod to become Ready" \
    kc -n "$KAGENT_NS" wait --for=condition=ready --timeout=180s \
      pod -l app.kubernetes.io/component=ui
  ok "kagent ready (UI: https://${KAGENT_HOST}:${SANDBOX_HTTPS_PORT})"
}

# In-cluster Gitea — the GitOps source for `sandboxctl deploy`.
#
# Why in-cluster instead of GitHub: Argo CD pulls the chart from this
# repo, so the URL has to be reachable from argocd-repo-server. Using
# an external host (GitHub, etc.) would mean either making every test
# repo public or wiring credentials through argocd-repo-server. With
# Gitea inside the cluster, both sandboxctl (host side) and Argo (in-
# cluster) can push/pull anonymously over the cluster network.
#
# Layout: rootless image + sqlite + a single 1Gi PVC. No HTTP route
# is created (this is the GitOps backend, not a UI surface). sandboxctl
# reaches Gitea by `kubectl exec`-ing the pod for git ops; Argo reaches
# it via http://gitea-http.gitea.svc.cluster.local:3000.
install_gitea() {
  log "installing Gitea (ns: $GITEA_NS, chart $GITEA_CHART_VERSION) — GitOps source for 'sandboxctl deploy'"

  # `helm repo add` is silent on success but can return 1 with a stale
  # ~/.cache/helm directory. Force-update so the index is fresh, and
  # let the next `helm upgrade --install` resolve the chart correctly.
  helm repo add gitea-charts https://dl.gitea.com/charts/ >/dev/null 2>&1 || true
  if ! helm repo update gitea-charts >/dev/null 2>&1; then
    warn "helm repo update gitea-charts failed — retrying with full refresh"
    helm repo update >/dev/null
  fi

  # Random admin password persisted to ~/.sandboxctl/gitea-admin-pass.
  # Read once during initial install; subsequent `sandboxctl up` calls
  # reuse the file so existing repos remain accessible.
  mkdir -p "$SANDBOX_STATE_DIR"
  local pass_file="${SANDBOX_STATE_DIR}/gitea-admin-pass"
  if [[ ! -s "$pass_file" ]]; then
    # NB: do NOT use `tr -dc … < /dev/urandom | head -c 32` here. Under
    # `set -euo pipefail`, `head -c` closes the pipe after 32 bytes,
    # `tr` gets SIGPIPE (status 141), and pipefail propagates that as
    # the function's exit — silently aborting `up` between
    # "installing Gitea" and the helm install. Generate via openssl
    # instead, which produces a fixed-length string in one shot.
    openssl rand -hex 16 > "$pass_file"
    chmod 600 "$pass_file"
  fi
  local admin_pass; admin_pass="$(cat "$pass_file")"

  # Single-Pod gitea: sqlite + in-process queue/cache/session, no
  # subchart dependencies (valkey-cluster + postgresql-ha are enabled
  # by default in the gitea helm chart and are overkill for a one-user
  # sandbox).
  log "running helm upgrade --install gitea"
  if ! helm_install "Gitea helm install (typically 2–4 min)" \
        helm upgrade --install gitea gitea-charts/gitea \
          --namespace "$GITEA_NS" --create-namespace \
          --version "$GITEA_CHART_VERSION" \
          --set "gitea.admin.username=${GITEA_ADMIN_USER}" \
          --set "gitea.admin.password=${admin_pass}" \
          --set 'gitea.admin.email=sandbox@local' \
          --set 'gitea.config.database.DB_TYPE=sqlite3' \
          --set 'gitea.config.cache.ADAPTER=memory' \
          --set 'gitea.config.session.PROVIDER=memory' \
          --set 'gitea.config.queue.TYPE=level' \
          --set 'gitea.config.indexer.ISSUE_INDEXER_TYPE=bleve' \
          --set 'valkey-cluster.enabled=false' \
          --set 'valkey.enabled=false' \
          --set 'postgresql-ha.enabled=false' \
          --set 'postgresql.enabled=false' \
          --set 'redis-cluster.enabled=false' \
          --set 'redis.enabled=false' \
          --set 'memcached.enabled=false' \
          --set 'persistence.size=1Gi' \
          --set 'replicaCount=1' \
          --set 'service.http.port=3000' \
          --set 'resources.requests.cpu=25m' --set 'resources.requests.memory=128Mi' \
          --set 'resources.limits.memory=512Mi' \
          --wait --timeout 8m; then
    die "gitea helm install failed — see 'helm -n ${GITEA_NS} status gitea' and 'kc -n ${GITEA_NS} get events --sort-by=.lastTimestamp'"
  fi

  kc -n "$GITEA_NS" rollout status deploy/gitea --timeout=180s >/dev/null

  # Sanity-poke the API once before declaring ready. Use `</dev/null`
  # on every `kc exec` to guarantee stdin closes — without it,
  # kubectl-exec can hang indefinitely on some podman/containerd
  # builds (the symptom in v1.5.x: cmd_up froze silently mid-`up`
  # right after kagent finished).
  if ! kc -n "$GITEA_NS" exec deploy/gitea -c gitea -- \
        sh -c "curl -sf --max-time 5 -u '${GITEA_ADMIN_USER}:${admin_pass}' \
          http://127.0.0.1:3000/api/v1/version" </dev/null >/dev/null 2>&1; then
    warn "gitea API didn't respond to a quick auth probe — first 'sandboxctl deploy' will retry"
  fi

  # Org create is best-effort: missing org just means the first
  # `sandboxctl deploy` will create it on demand inside
  # gitea_push_chart. Skipping a hard failure here keeps `up` robust
  # against a slow Gitea startup.
  kc -n "$GITEA_NS" exec deploy/gitea -c gitea -- \
    sh -c "curl -sf --max-time 5 -u '${GITEA_ADMIN_USER}:${admin_pass}' \
      -H 'Content-Type: application/json' \
      -d '{\"username\":\"${GITEA_ORG}\",\"visibility\":\"public\"}' \
      http://127.0.0.1:3000/api/v1/orgs" </dev/null >/dev/null 2>&1 \
    || true

  ok "gitea ready (in-cluster: http://gitea-http.${GITEA_NS}.svc.cluster.local:3000)"
}

# Push (or refresh) a chart subtree to Gitea over a kubectl-exec'd git
# session. Returns the in-cluster repo URL on stdout.
#
# Args: $1 = repo name (e.g. <chart>-chart); $2 = local source dir.
gitea_push_chart() {
  local repo_name="$1" src_dir="$2"
  [[ -d "$src_dir" ]] || die "gitea_push_chart: source dir not found: $src_dir"

  local pass_file="${SANDBOX_STATE_DIR}/gitea-admin-pass"
  [[ -s "$pass_file" ]] || die "gitea password file missing — run 'sandboxctl up' first"
  local admin_pass; admin_pass="$(cat "$pass_file")"

  # Ensure the org exists (best-effort — install_gitea attempts it but
  # may have skipped on a slow Gitea startup). 422 means "already
  # exists", which is fine.
  kc -n "$GITEA_NS" exec deploy/gitea -c gitea -- \
    sh -c "curl -sf --max-time 5 -u '${GITEA_ADMIN_USER}:${admin_pass}' \
      -H 'Content-Type: application/json' \
      -d '{\"username\":\"${GITEA_ORG}\",\"visibility\":\"public\"}' \
      http://127.0.0.1:3000/api/v1/orgs" </dev/null >/dev/null 2>&1 || true

  # Create the repo via Gitea API if it doesn't exist. Idempotent.
  if ! kc -n "$GITEA_NS" exec deploy/gitea -c gitea -- \
        sh -c "curl -sf --max-time 5 -u '${GITEA_ADMIN_USER}:${admin_pass}' \
          http://127.0.0.1:3000/api/v1/repos/${GITEA_ORG}/${repo_name}" \
        </dev/null >/dev/null 2>&1; then
    kc -n "$GITEA_NS" exec deploy/gitea -c gitea -- \
      sh -c "curl -sf --max-time 10 -u '${GITEA_ADMIN_USER}:${admin_pass}' \
        -H 'Content-Type: application/json' \
        -d '{\"name\":\"${repo_name}\",\"auto_init\":true,\"default_branch\":\"main\"}' \
        http://127.0.0.1:3000/api/v1/orgs/${GITEA_ORG}/repos" \
      </dev/null >/dev/null \
      || die "could not create gitea repo ${GITEA_ORG}/${repo_name}"
  fi

  # Push the chart via host-side git over a port-forward.
  local pf_pid="" tmp
  tmp="$(mktemp -d -t sandboxctl-gitea.XXXXXX)"
  # shellcheck disable=SC2064  # intentional now-expansion of $tmp; pf_pid is set later
  trap 'rm -rf "$tmp"; [[ -n "$pf_pid" ]] && kill "$pf_pid" 2>/dev/null || true' RETURN

  kc -n "$GITEA_NS" port-forward svc/gitea-http 13000:3000 >/dev/null 2>&1 &
  pf_pid=$!
  # Wait for port-forward to bind. lsof -i is faster than nc-style polling.
  local i
  for ((i=0; i<30; i++)); do
    curl -sf "http://127.0.0.1:13000/api/v1/version" >/dev/null 2>&1 && break
    sleep 0.5
  done

  local push_url="http://${GITEA_ADMIN_USER}:${admin_pass}@127.0.0.1:13000/${GITEA_ORG}/${repo_name}.git"

  with_spinner "[${repo_name}] pushing chart to gitea" \
    _gitea_git_push "$src_dir" "$tmp" "$push_url" \
    || die "git push to gitea failed"

  echo "http://gitea-http.${GITEA_NS}.svc.cluster.local:3000/${GITEA_ORG}/${repo_name}.git"
}

# Slow inner of gitea_push_chart, factored out so with_spinner can
# wrap it. Subshelled to keep `cd` from leaking when with_spinner
# is bypassed (SANDBOXCTL_NO_SPINNER=1 or stderr not a TTY).
_gitea_git_push() {
  local src_dir="$1" tmp="$2" push_url="$3"
  (
    set -e
    cp -R "${src_dir}/." "$tmp/"
    cd "$tmp"
    git init -q -b main
    git config user.email "sandbox@local"
    git config user.name  "sandboxctl"
    git add -A
    git commit -q -m "sandboxctl: chart snapshot $(date -u +%Y-%m-%dT%H:%M:%SZ)" --allow-empty
    git remote add origin "$push_url"
    git push -q -f origin main
  )
}

helm_istio() {
  # $1 release, $2 chart, rest passed verbatim to helm.
  local release="$1" chart="$2"; shift 2
  helm_install "${release} helm install (typically 30–90s)" \
    helm upgrade --install "$release" "istio/$chart" \
      --namespace "$ISTIO_SYSTEM_NS" --create-namespace \
      --version "$ISTIO_CHART_VERSION" \
      --wait --timeout 5m \
      "$@"
}

install_istio_ambient() {
  log "installing Istio ambient (chart $ISTIO_CHART_VERSION)"
  helm repo add istio https://istio-release.storage.googleapis.com/charts >/dev/null 2>&1 || true
  helm repo update istio >/dev/null

  helm_istio istio-base base
  helm_istio istio-cni  cni    --set profile=ambient
  # istiod's pilot is the chunkiest Istio component — give it a small request
  # so it's scheduled lean (it self-sizes its cache to load, not the request).
  helm_istio istiod     istiod --set profile=ambient \
    --set 'pilot.resources.requests.cpu=50m' --set 'pilot.resources.requests.memory=128Mi'
  helm_istio ztunnel    ztunnel \
    --set 'resources.requests.cpu=25m' --set 'resources.requests.memory=64Mi'

  # Ingress gateway. ClusterIP only — Mac reaches it via the LaunchAgent
  # port-forward. Ports are 8080/8443 (not 80/443) so Envoy can bind without
  # the unprivileged-port-start sysctl tweak. Gateway selector in
  # manifests/ingress.yaml is `istio: ingress` (the Helm chart's pod label).
  helm_install "istio-ingress gateway helm install (typically 1–2 min)" \
    helm upgrade --install istio-ingress istio/gateway \
      --namespace "$ISTIO_INGRESS_NS" --create-namespace \
      --version "$ISTIO_CHART_VERSION" \
      --set service.type=ClusterIP \
      --set 'service.ports[0].name=status-port'  --set 'service.ports[0].port=15021' --set 'service.ports[0].targetPort=15021' --set 'service.ports[0].protocol=TCP' \
      --set 'service.ports[1].name=http2'        --set 'service.ports[1].port=8080'  --set 'service.ports[1].targetPort=8080'  --set 'service.ports[1].protocol=TCP' \
      --set 'service.ports[2].name=https'        --set 'service.ports[2].port=8443'  --set 'service.ports[2].targetPort=8443'  --set 'service.ports[2].protocol=TCP' \
      --set 'resources.requests.cpu=25m' --set 'resources.requests.memory=64Mi' \
      --wait --timeout 5m

  with_spinner "waiting for istio-ingress gateway pod to become Ready" \
    kc -n "$ISTIO_INGRESS_NS" wait --for=condition=ready --timeout=180s pod -l app=istio-ingress
  ok "Istio ambient ready (istiod + ztunnel + ingress gateway)"
}

install_routes() {
  log "applying Istio Gateway + VirtualServices for ${SANDBOX_DOMAIN}"
  # Generated inline so the domain follows $SANDBOX_DOMAIN without YAML edits.
  kc apply -f - <<EOF >/dev/null
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: sandbox-gateway
  namespace: ${ISTIO_INGRESS_NS}
spec:
  # The istio/gateway Helm chart labels its pod 'istio: ingress' (NOT the
  # legacy 'ingressgateway' value). Match that selector so Envoy receives
  # the listener config from istiod.
  selector: { istio: ingress }
  servers:
    - port: { number: 8080, name: http,  protocol: HTTP }
      hosts: ["*.${SANDBOX_DOMAIN}"]
      tls: { httpsRedirect: true }
    - port: { number: 8443, name: https, protocol: HTTPS }
      hosts: ["*.${SANDBOX_DOMAIN}"]
      tls:
        mode: SIMPLE
        credentialName: ${WILDCARD_TLS_SECRET}
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata: { name: argocd, namespace: ${ARGOCD_NS} }
spec:
  hosts: ["${ARGO_HOST}"]
  gateways: ["${ISTIO_INGRESS_NS}/sandbox-gateway"]
  http:
    - route: [{ destination: { host: argocd-server.${ARGOCD_NS}.svc.cluster.local, port: { number: 80 } } }]
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata: { name: kargo, namespace: ${KARGO_NS} }
spec:
  hosts: ["${KARGO_HOST}"]
  gateways: ["${ISTIO_INGRESS_NS}/sandbox-gateway"]
  http:
    - route: [{ destination: { host: kargo-api.${KARGO_NS}.svc.cluster.local, port: { number: 443 } } }]
---
# Kargo's API serves HTTPS with a self-signed cert; tell upstream to use TLS
# without verifying.
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata: { name: kargo-api, namespace: ${KARGO_NS} }
spec:
  host: kargo-api.${KARGO_NS}.svc.cluster.local
  trafficPolicy:
    tls: { mode: SIMPLE, insecureSkipVerify: true }
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata: { name: demo-app, namespace: ${DEMO_NS} }
spec:
  hosts: ["${DEMO_HOST}"]
  gateways: ["${ISTIO_INGRESS_NS}/sandbox-gateway"]
  http:
    - route: [{ destination: { host: demo-app.${DEMO_NS}.svc.cluster.local, port: { number: 80 } } }]
EOF

  # Kagent VS only when the namespace exists (i.e. user opted in via
  # --with-kagent). Without this gate, Istio still accepts the VS but
  # routes 503 because the destination Service doesn't resolve.
  if _kagent_present; then
    kc apply -f - <<EOF >/dev/null
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata: { name: kagent, namespace: ${KAGENT_NS} }
spec:
  hosts: ["${KAGENT_HOST}"]
  gateways: ["${ISTIO_INGRESS_NS}/sandbox-gateway"]
  http:
    - route: [{ destination: { host: kagent-ui.${KAGENT_NS}.svc.cluster.local, port: { number: 8080 } } }]
EOF
  fi

  # agentregistry route is owned by lib/aregistry.sh so the chart's
  # service name + port don't have to be duplicated here. Same gating
  # rationale as kagent: skip when the namespace doesn't exist.
  if declare -F install_aregistry_routes >/dev/null; then
    install_aregistry_routes
  fi

  # AI Agentic Gateway routes — owned by each lib (service name + port live
  # there). Same gating rationale as kagent/aregistry: each is a no-op when
  # its namespace doesn't exist, so --no-* runs leave no dangling 503 route.
  if declare -F install_agentgateway_routes >/dev/null; then install_agentgateway_routes; fi
  if declare -F install_litellm_routes      >/dev/null; then install_litellm_routes;      fi
  if declare -F install_portkey_routes      >/dev/null; then install_portkey_routes;      fi
  if declare -F install_mlflow_routes       >/dev/null; then install_mlflow_routes;       fi
  if declare -F install_tyk_routes          >/dev/null; then install_tyk_routes;          fi
  ok "routes applied"
}

# ============================================================================
# /etc/hosts management
# ============================================================================

_managed_hosts() {
  # Hostnames sandboxctl manages on the marker line. Each opt-in
  # component is gated on its presence helper so an `up` that didn't
  # enable it never leaks the hostname into /etc/hosts (and never
  # triggers a noisy URL validation failure for something the user
  # never asked to install).
  local out=("$ARGO_HOST" "$KARGO_HOST" "$DEMO_HOST")
  if _kagent_present; then out+=("$KAGENT_HOST"); fi
  if declare -F nats_present         >/dev/null && nats_present;         then out+=("$NATS_HOST");         fi
  if declare -F aregistry_present    >/dev/null && aregistry_present;    then out+=("$AREGISTRY_HOST");    fi
  if declare -F agentgateway_present >/dev/null && agentgateway_present; then out+=("$AGENTGATEWAY_HOST"); fi
  if declare -F litellm_present      >/dev/null && litellm_present;      then out+=("$LITELLM_HOST");      fi
  if declare -F portkey_present      >/dev/null && portkey_present;      then out+=("$PORTKEY_HOST");      fi
  if declare -F mlflow_present       >/dev/null && mlflow_present;       then out+=("$MLFLOW_HOST");       fi
  if declare -F tyk_present          >/dev/null && tyk_present;          then out+=("$TYK_HOST");          fi
  printf '%s\n' "${out[@]}"
}

hosts_line_present() {
  local h
  while IFS= read -r h; do
    grep -qE "^[[:space:]]*127\.0\.0\.1[[:space:]].*\b${h}\b" /etc/hosts || return 1
  done < <(_managed_hosts)
}

install_dnsmasq() {
  # Wildcard *.${SANDBOX_DOMAIN} → 127.0.0.1 via macOS's per-domain
  # resolver. Lets product charts add VirtualServices on any subdomain
  # (mcp.fiber.sandbox.app, foo.fiber.sandbox.app, …) without touching
  # /etc/hosts. install_hosts still maintains the named entries as a
  # fallback in case dnsmasq is uninstalled.
  if [[ "$(uname -s)" != "Darwin" ]]; then return 0; fi
  if ! command -v brew >/dev/null 2>&1; then
    warn "brew unavailable — skipping dnsmasq wildcard DNS"
    return 0
  fi

  log "configuring dnsmasq wildcard *.${SANDBOX_DOMAIN} → 127.0.0.1"

  local brew_prefix; brew_prefix="$(brew --prefix)"
  local dnsmasq_conf="${brew_prefix}/etc/dnsmasq.d/sandbox-${SANDBOX_DOMAIN}.conf"
  local dnsmasq_dir; dnsmasq_dir="$(dirname "$dnsmasq_conf")"
  local resolver_file="/etc/resolver/${SANDBOX_DOMAIN}"
  local desired_addr="address=/.${SANDBOX_DOMAIN}/127.0.0.1"

  if ! brew list --formula dnsmasq >/dev/null 2>&1; then
    log "installing dnsmasq via brew"
    brew install dnsmasq >/dev/null
  fi

  mkdir -p "$dnsmasq_dir"
  if [[ ! -f "$dnsmasq_conf" ]] || ! grep -qxF "$desired_addr" "$dnsmasq_conf"; then
    printf '%s\n' "$desired_addr" > "$dnsmasq_conf"
  fi

  prime_sudo
  if [[ ! -f "$resolver_file" ]] || ! grep -q "^nameserver 127.0.0.1" "$resolver_file" 2>/dev/null; then
    sudo mkdir -p /etc/resolver
    local tmp; tmp="$(mktemp -t sandbox-resolver.XXXXXX)"
    printf 'nameserver 127.0.0.1\nport 53\n' > "$tmp"
    sudo install -m 0644 "$tmp" "$resolver_file"
    rm -f "$tmp"
  fi

  # dnsmasq must run with privileges to bind :53. The standard pattern is
  # `sudo brew services start dnsmasq`, which loads it under launchd's
  # system domain. Idempotent — no-op if already loaded.
  if ! sudo brew services list 2>/dev/null | awk '$1=="dnsmasq" && $2=="started" {found=1} END {exit !found}'; then
    log "starting dnsmasq under sudo brew services"
    sudo brew services restart dnsmasq >/dev/null 2>&1 || sudo brew services start dnsmasq >/dev/null 2>&1 || true
  fi

  # Smoke-test: resolve a guaranteed-fake subdomain and confirm 127.0.0.1.
  local probe; probe="$(dscacheutil -q host -a name "probe.${SANDBOX_DOMAIN}" 2>/dev/null | awk '/ip_address:/ {print $2; exit}')"
  if [[ "$probe" == "127.0.0.1" ]]; then
    ok "wildcard DNS *.${SANDBOX_DOMAIN} → 127.0.0.1"
  else
    warn "dnsmasq installed but probe returned '${probe:-<empty>}' — /etc/hosts entries still cover known subdomains"
  fi
}

uninstall_dnsmasq() {
  if [[ "$(uname -s)" != "Darwin" ]]; then return 0; fi
  command -v brew >/dev/null 2>&1 || return 0
  local brew_prefix; brew_prefix="$(brew --prefix)"
  local dnsmasq_conf="${brew_prefix}/etc/dnsmasq.d/sandbox-${SANDBOX_DOMAIN}.conf"
  local resolver_file="/etc/resolver/${SANDBOX_DOMAIN}"

  if [[ ! -f "$dnsmasq_conf" && ! -f "$resolver_file" ]]; then
    return 0
  fi

  log "removing dnsmasq wildcard for ${SANDBOX_DOMAIN}"
  prime_sudo
  [[ -f "$dnsmasq_conf"  ]] && rm -f      "$dnsmasq_conf"  2>/dev/null || true
  [[ -f "$resolver_file" ]] && sudo rm -f "$resolver_file" 2>/dev/null || true

  # Reload dnsmasq so it forgets *.${SANDBOX_DOMAIN}. Leave the brew
  # service running — other domains may still use it.
  if sudo brew services list 2>/dev/null | awk '$1=="dnsmasq" && $2=="started" {found=1} END {exit !found}'; then
    sudo brew services restart dnsmasq >/dev/null 2>&1 || true
  fi
  ok "dnsmasq wildcard removed"
}

install_hosts() {
  log "configuring /etc/hosts entries for ${SANDBOX_DOMAIN}"
  if hosts_line_present; then
    ok "/etc/hosts already maps $(_managed_hosts | paste -sd ',' -) to 127.0.0.1"
    return
  fi
  prime_sudo
  # /etc/hosts is world-readable, so the read doesn't need sudo. Only the
  # final `install` does.
  local tmp; tmp="$(mktemp -t sandbox-hosts.XXXXXX)"
  grep -v "${SANDBOX_HOSTS_MARKER}" /etc/hosts > "$tmp" || true
  printf '127.0.0.1\t%s\t%s\n' "$(_managed_hosts | paste -sd ' ' -)" "$SANDBOX_HOSTS_MARKER" >> "$tmp"
  sudo install -m 0644 "$tmp" /etc/hosts
  rm -f "$tmp"
  ok "/etc/hosts updated"
}

uninstall_hosts() {
  if [[ -f /etc/hosts ]] && grep -qF "$SANDBOX_HOSTS_MARKER" /etc/hosts 2>/dev/null; then
    prime_sudo
    log "removing sandboxctl entries from /etc/hosts"
    local tmp; tmp="$(mktemp -t sandbox-hosts.XXXXXX)"
    grep -v "${SANDBOX_HOSTS_MARKER}" /etc/hosts > "$tmp" || true
    sudo install -m 0644 "$tmp" /etc/hosts
    rm -f "$tmp"
  fi
  ok "/etc/hosts cleaned (no-op if nothing was set)"
}

# ============================================================================
# LaunchAgent (kubectl port-forward)
# ============================================================================

portfwd_running() {
  launchctl list 2>/dev/null | awk -v label="$SANDBOX_LAUNCHAGENT_LABEL" '$3==label {print $1}' | grep -qE '^[0-9]+$'
}

# Old labels uninstall_portfwd cleans up so upgrades don't fight stale listeners.
LEGACY_LAUNCHAGENT_LABELS=(
  com.zendesk.sandboxctl.portfwd
)

# Add-on lib LaunchAgents — listed here so `cmd_down` can sweep them
# even when the relevant lib/<tool>.sh isn't sourced (older binary,
# manual `bash sandbox.sh down`, etc.). Each entry is a label →
# corresponding plist filename pair. lib files that own these labels
# also call launchagent_stop directly, so this is belt-and-braces.
SANDBOX_ADDON_LAUNCHAGENT_LABELS=(
  io.github.sandboxctl.nats-portfwd
  # Future: io.github.sandboxctl.knative-portfwd
)

# Sweep every add-on LaunchAgent by label, regardless of plist
# presence. Safe to call even when nothing is loaded — each step is
# guarded.
sweep_addon_launchagents() {
  local label
  for label in "${SANDBOX_ADDON_LAUNCHAGENT_LABELS[@]}"; do
    local plist="${SANDBOX_LAUNCHAGENT_DIR}/${label}.plist"
    if [[ -f "$plist" ]] || \
       launchctl list 2>/dev/null | awk '{print $3}' | grep -qx "$label"; then
      log "removing add-on LaunchAgent ${label}"
      launchagent_stop "$label" "$plist"
    fi
  done
}

# Stop a LaunchAgent and remove its plist. KeepAlive=true makes launchd
# respawn the child immediately if we just `launchctl unload`, so the
# child kubectl can be in a tight loop and unload appears to hang.
# Order: bootout (preferred on macOS 10.11+), then unload, then remove
# by label, then remove the plist file. Each step is bounded by a
# timeout so a wedged launchd never blocks the script.
launchagent_stop() {
  local label="$1" plist="$2"
  local uid; uid="$(id -u)"
  # gtimeout (coreutils) preferred; falls back to a perl alarm wrapper.
  local timeout
  if command -v gtimeout >/dev/null 2>&1; then timeout=(gtimeout 10)
  else timeout=(perl -e 'alarm shift; exec @ARGV' 10); fi

  "${timeout[@]}" launchctl bootout "gui/${uid}/${label}" >/dev/null 2>&1 || true
  if [[ -f "$plist" ]]; then
    "${timeout[@]}" launchctl unload "$plist" >/dev/null 2>&1 || true
  fi
  "${timeout[@]}" launchctl remove "$label" >/dev/null 2>&1 || true
  rm -f "$plist"
}

uninstall_portfwd() {
  # Kill child kubectl processes first, regardless of plist state.
  # This unblocks `launchctl unload` if the child is in a respawn
  # loop (e.g. after a previous run with a missing kube context).
  pkill -f "port-forward.*svc/istio-ingress" >/dev/null 2>&1 || true

  if [[ -f "$SANDBOX_LAUNCHAGENT_PLIST" ]] || \
     launchctl list 2>/dev/null | awk '{print $3}' | grep -qx "$SANDBOX_LAUNCHAGENT_LABEL"; then
    log "unloading + removing LaunchAgent ${SANDBOX_LAUNCHAGENT_LABEL}"
    launchagent_stop "$SANDBOX_LAUNCHAGENT_LABEL" "$SANDBOX_LAUNCHAGENT_PLIST"
  fi
  local legacy
  for legacy in "${LEGACY_LAUNCHAGENT_LABELS[@]}"; do
    local legacy_plist="${SANDBOX_LAUNCHAGENT_DIR}/${legacy}.plist"
    if [[ -f "$legacy_plist" ]] || \
       launchctl list 2>/dev/null | awk '{print $3}' | grep -qx "$legacy"; then
      log "removing legacy LaunchAgent ${legacy}"
      launchagent_stop "$legacy" "$legacy_plist"
    fi
  done
  pkill -f "port-forward.*svc/istio-ingress" >/dev/null 2>&1 || true
}

uninstall_registry_portfwd() {
  # Tear down both: the new socat proxy container and any leftover
  # LaunchAgent / kubectl port-forward from older sandboxctl versions.
  if "$SANDBOX_RUNTIME" inspect "$SANDBOX_REGISTRY_PROXY_CONTAINER" >/dev/null 2>&1; then
    log "removing registry proxy container ${SANDBOX_REGISTRY_PROXY_CONTAINER}"
    "$SANDBOX_RUNTIME" rm -f "$SANDBOX_REGISTRY_PROXY_CONTAINER" >/dev/null 2>&1 || true
  fi
  # Legacy registry-portfwd LaunchAgent (v1.3.0 / v1.3.1) — still installed
  # on machines that upgraded mid-stream.
  local legacy_label="io.github.sandboxctl.registry-portfwd"
  local legacy_plist="${SANDBOX_LAUNCHAGENT_DIR}/${legacy_label}.plist"
  pkill -f "port-forward.*svc/registry" >/dev/null 2>&1 || true
  if [[ -f "$legacy_plist" ]] || \
     launchctl list 2>/dev/null | awk '{print $3}' | grep -qx "$legacy_label"; then
    log "removing legacy registry LaunchAgent"
    launchagent_stop "$legacy_label" "$legacy_plist"
  fi
  pkill -f "port-forward.*svc/registry" >/dev/null 2>&1 || true
}

# Trailing `|| true` is required: lsof exits 1 on no match, pipefail
# propagates that through head, and set -e would kill the script at the
# next assignment site.
port_listener_pid() {
  local port="$1"
  lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | head -1 || true
}

# Identity check — is the listener a sandboxctl-owned kubectl
# port-forward we can safely kill? The legacy registry-portfwd pattern
# is also recognised so v1.3.0/1 leftovers get cleaned up.
port_listener_is_ours() {
  local port="$1" pid cmdline
  pid="$(port_listener_pid "$port")"
  [[ -n "$pid" ]] || return 1
  cmdline="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [[ "$cmdline" == *"port-forward"*"svc/istio-ingress"* ]] || \
    [[ "$cmdline" == *"port-forward"*"svc/registry"* ]]
}

free_port_or_die() {
  # The registry port is bound by a podman socat container; that's
  # already removed by uninstall_registry_portfwd before we get here.
  _check_port_or_die HTTP     "$SANDBOX_HTTP_PORT"
  _check_port_or_die HTTPS    "$SANDBOX_HTTPS_PORT"
  _check_registry_port_or_die "$SANDBOX_REGISTRY_PORT"
}

_check_registry_port_or_die() {
  # If something is holding the registry port after uninstall_registry_portfwd,
  # it's foreign. Fail with a clear message.
  local port="$1" pid cmdline
  pid="$(port_listener_pid "$port")"
  [[ -z "$pid" ]] && return 0
  cmdline="$(ps -p "$pid" -o command= 2>/dev/null || echo unknown)"
  local alt_port=$(( port + 100 ))
  die "REGISTRY port :${port} is in use by an unrelated process (pid ${pid}: ${cmdline}).
       Either stop that process, or pick a different port and re-run.
       Example:  SANDBOX_REGISTRY_PORT=${alt_port} sandboxctl up"
}

_check_port_or_die() {
  local label="$1" port="$2" pid cmdline
  pid="$(port_listener_pid "$port")"
  if [[ -z "$pid" ]]; then
    return 0   # port is free, nothing to do
  fi
  if port_listener_is_ours "$port"; then
    log "${label} port :${port} held by a stale sandboxctl port-forward (pid ${pid}) — killing"
    kill "$pid" 2>/dev/null || true
    # Wait briefly for the kernel to release the port. lsof -nP -iTCP:<port>
    # -sTCP:LISTEN is the fastest reliable check.
    local i
    for ((i=1; i<=10; i++)); do
      [[ -z "$(port_listener_pid "$port")" ]] && return 0
      sleep 1
    done
    die "killed stale sandboxctl listener on :${port} but the port is still occupied — try 'sandboxctl restart'"
  fi
  cmdline="$(ps -p "$pid" -o command= 2>/dev/null || echo unknown)"
  # Suggest a concrete alternative port. Add 100 to dodge the typical
  # tools (8543 vs 8443, 5150 vs 5050, 8180 vs 8080).
  local alt_port=$(( port + 100 ))
  die "${label} port :${port} is in use by an unrelated process (pid ${pid}: ${cmdline}).
       Either stop that process, or pick a different port and re-run.
       Example:  SANDBOX_${label}_PORT=${alt_port} sandboxctl up"
}

write_portfwd_plist() {
  local kubectl_path
  kubectl_path="$(command -v kubectl)" || die "kubectl not found on PATH"
  mkdir -p "$SANDBOX_LAUNCHAGENT_DIR" "$SANDBOX_STATE_DIR"
  # write_pinned_kubeconfig already ran via install_portfwd; this guard
  # only catches the case where someone calls write_portfwd_plist
  # directly without going through the install path.
  [[ -f "$SANDBOX_KUBECONFIG" ]] || \
    die "pinned kubeconfig ${SANDBOX_KUBECONFIG} missing — run 'sandboxctl restart'"
  cat > "$SANDBOX_LAUNCHAGENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTD/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${SANDBOX_LAUNCHAGENT_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${kubectl_path}</string>
    <string>--kubeconfig</string><string>${SANDBOX_KUBECONFIG}</string>
    <string>--context</string><string>$(kctx)</string>
    <string>port-forward</string>
    <string>--address</string><string>127.0.0.1</string>
    <string>-n</string><string>${ISTIO_INGRESS_NS}</string>
    <string>svc/istio-ingress</string>
    <string>${SANDBOX_HTTP_PORT}:8080</string>
    <string>${SANDBOX_HTTPS_PORT}:8443</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>StandardOutPath</key><string>${SANDBOX_PF_LOG}</string>
  <key>StandardErrorPath</key><string>${SANDBOX_PF_LOG}</string>
</dict>
</plist>
EOF
}

install_portfwd() {
  log "installing kubectl port-forward LaunchAgent (Mac :${SANDBOX_HTTP_PORT}/:${SANDBOX_HTTPS_PORT} → svc/istio-ingress)"
  uninstall_portfwd
  uninstall_registry_portfwd
  free_port_or_die        # fail fast on foreign conflicts; clean up our own stale state

  # Self-heal: regenerate the pinned kubeconfig and validate it works
  # BEFORE handing it to launchd. Without this, an earlier failed run
  # could leave a stale or missing $SANDBOX_KUBECONFIG, kubectl would
  # crash on every respawn, and `KeepAlive=true` would burn CPU in a
  # tight loop while emitting `context "kind-..." does not exist`.
  write_pinned_kubeconfig
  if ! kubectl --kubeconfig "$SANDBOX_KUBECONFIG" --context "$(kctx)" \
        cluster-info >/dev/null 2>&1; then
    die "kubectl can't reach the cluster with ${SANDBOX_KUBECONFIG} (context $(kctx)) — refusing to install a LaunchAgent that will respawn-loop. Try: sandboxctl restart"
  fi

  write_portfwd_plist
  launchctl load "$SANDBOX_LAUNCHAGENT_PLIST" || \
    die "launchctl load failed for ${SANDBOX_LAUNCHAGENT_PLIST} — check the file then 'sandboxctl restart'"

  # Wait for both UI ports to bind. The registry port is wired separately
  # via install_registry_proxy (a socat container) because kubectl
  # port-forward chokes on Docker's parallel layer uploads.
  local i
  for ((i=1; i<=30; i++)); do
    if nc -z 127.0.0.1 "$SANDBOX_HTTPS_PORT" 2>/dev/null && \
       nc -z 127.0.0.1 "$SANDBOX_HTTP_PORT"  2>/dev/null; then
      ok "port-forward ready on 127.0.0.1:${SANDBOX_HTTP_PORT}/${SANDBOX_HTTPS_PORT}"
      install_registry_proxy
      return
    fi
    sleep 1
  done
  warn "LaunchAgent loaded but :${SANDBOX_HTTP_PORT}/:${SANDBOX_HTTPS_PORT} did not bind within 30s"
  warn "last lines of ${SANDBOX_PF_LOG}:"
  tail -5 "$SANDBOX_PF_LOG" 2>&1 | sed 's/^/    /' >&2
  die "port-forward failed to bind — fix the cause above and run 'sandboxctl restart'"
}

install_registry_proxy() {
  # socat container on the kind network: host:$SANDBOX_REGISTRY_PORT →
  # kind-node:30050. Persistent TCP — handles Docker's parallel layer
  # uploads, which kubectl port-forward stalls.
  #
  # Cleanup any stale container left over from a previous machine
  # session. Without this, `podman run` would refuse with "container
  # name already in use" the second time `up` runs.
  "$SANDBOX_RUNTIME" rm -f "$SANDBOX_REGISTRY_PROXY_CONTAINER" >/dev/null 2>&1 || true

  local node_ip
  node_ip="$("$SANDBOX_RUNTIME" inspect "${CLUSTER_NAME}-control-plane" \
    --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)"
  [[ -n "$node_ip" ]] || die "could not determine kind node IP for registry proxy"

  log "starting registry proxy container (Mac :${SANDBOX_REGISTRY_PORT} → kind-node:${SANDBOX_REGISTRY_NODEPORT})"
  "$SANDBOX_RUNTIME" run -d --restart=unless-stopped \
    --name "$SANDBOX_REGISTRY_PROXY_CONTAINER" \
    --network kind \
    -p "${SANDBOX_REGISTRY_PORT}:5000" \
    "$SANDBOX_REGISTRY_PROXY_IMAGE" \
    -d TCP-LISTEN:5000,fork,reuseaddr "TCP:${node_ip}:${SANDBOX_REGISTRY_NODEPORT}" >/dev/null

  # Wait for the registry to be reachable through the proxy.
  local i
  for ((i=1; i<=15; i++)); do
    if curl -sf --max-time 2 "http://localhost:${SANDBOX_REGISTRY_PORT}/v2/" >/dev/null 2>&1; then
      ok "registry proxy ready (push: docker push localhost:${SANDBOX_REGISTRY_PORT}/<image>:<tag>)"
      return
    fi
    sleep 1
  done
  warn "registry proxy container started but :${SANDBOX_REGISTRY_PORT} not reachable after 15s"
  "$SANDBOX_RUNTIME" logs --tail=10 "$SANDBOX_REGISTRY_PROXY_CONTAINER" 2>&1 | sed 's/^/    /' >&2
  die "registry proxy failed to forward — check 'podman logs ${SANDBOX_REGISTRY_PROXY_CONTAINER}'"
}

# Make sure `localhost:$SANDBOX_REGISTRY_PORT` is push-reachable from
# the Mac. This fails on a fresh `up` only if the registry pod itself
# isn't ready yet — but on every subsequent run it can fail because
# the host-side proxy container (socat on the kind network) was
# stopped or removed (machine reboot, podman machine restart, prior
# `down` left it dead).
#
# Self-heal: if the cluster is up + the registry pod is running but
# the proxy container isn't reachable, restart it. Only `die` if
# something more fundamental is broken.
_ensure_registry_reachable() {
  if nc -z 127.0.0.1 "$SANDBOX_REGISTRY_PORT" 2>/dev/null; then
    return 0
  fi

  if ! cluster_registered || ! cluster_api_reachable; then
    die "registry not reachable on localhost:${SANDBOX_REGISTRY_PORT} — run 'sandboxctl up' first"
  fi

  if ! kc -n "$REGISTRY_NS" get deploy registry >/dev/null 2>&1; then
    die "in-cluster registry not installed — run 'sandboxctl up' to provision it"
  fi

  log "registry reachable check failed — (re)starting host-side proxy container"
  install_registry_proxy

  if ! nc -z 127.0.0.1 "$SANDBOX_REGISTRY_PORT" 2>/dev/null; then
    die "registry still not reachable on localhost:${SANDBOX_REGISTRY_PORT} after starting the proxy — see 'podman logs ${SANDBOX_REGISTRY_PROXY_CONTAINER}'"
  fi
}

# ============================================================================
# Root CA trust (macOS keychain)
# ============================================================================

ca_pem_from_cluster() {
  kc -n "$CERT_MANAGER_NS" get secret "$ROOT_CA_SECRET" \
    -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d 2>/dev/null || true
}

ca_already_trusted() {
  local ca_pem fp
  ca_pem="$(ca_pem_from_cluster)"
  [[ -n "$ca_pem" ]] || return 1
  fp="$(echo "$ca_pem" | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | tr -d ':')"
  [[ -n "$fp" ]] || return 1
  security find-certificate -a -Z /Library/Keychains/System.keychain 2>/dev/null \
    | grep -qi "SHA-256 hash: $fp"
}

trust_root_ca() {
  log "installing sandbox root CA into macOS System keychain"
  require_running_cluster
  local ca_pem; ca_pem="$(ca_pem_from_cluster)"
  if [[ -z "$ca_pem" ]]; then
    warn "root CA secret '$ROOT_CA_SECRET' not yet populated — skipping trust step"
    return 0
  fi
  if ca_already_trusted; then ok "root CA already trusted in System keychain"; return; fi
  prime_sudo
  local tmp_pem; tmp_pem="$(mktemp -t sandbox-root-ca.XXXXXX.pem)"
  printf '%s\n' "$ca_pem" > "$tmp_pem"
  with_spinner "trusting sandbox root CA in System keychain" \
    sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$tmp_pem"
  rm -f "$tmp_pem"
  ok "root CA trusted — browsers will accept *.${SANDBOX_DOMAIN} as valid"
}

untrust_root_ca() {
  log "removing sandbox root CA from macOS System keychain (if present)"
  prime_sudo
  sudo security delete-certificate -c "$ROOT_CA_CN" /Library/Keychains/System.keychain 2>/dev/null || true
  ok "untrust requested (no error if it wasn't installed)"
}

# ============================================================================
# Per-install secrets (~/.sandboxctl/secrets.env)
# ============================================================================

# Generates random Kargo password + JWT signing key on first run into
# $SANDBOX_SECRETS_FILE (0600), reuses them thereafter.
load_or_generate_secrets() {
  mkdir -p "$SANDBOX_STATE_DIR"
  if [[ -f "$SANDBOX_SECRETS_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$SANDBOX_SECRETS_FILE"
  fi

  local generated=0
  local sandboxctl_bin
  sandboxctl_bin="$(command -v sandboxctl 2>/dev/null || true)"
  [[ -n "$sandboxctl_bin" ]] || die "sandboxctl binary not on PATH (run ./install.sh first)"

  if [[ -z "${KARGO_ADMIN_PASSWORD:-}" ]]; then
    log "generating random Kargo admin password (saved to $SANDBOX_SECRETS_FILE, chmod 600)"
    KARGO_ADMIN_PASSWORD="$("$sandboxctl_bin" secret rand 16)"   # 32 hex chars
    generated=1
  fi
  if [[ -z "${KARGO_ADMIN_PASSWORD_HASH:-}" ]]; then
    KARGO_ADMIN_PASSWORD_HASH="$(printf %s "$KARGO_ADMIN_PASSWORD" | "$sandboxctl_bin" secret bcrypt)"
    generated=1
  fi
  if [[ -z "${KARGO_TOKEN_SIGNING_KEY:-}" ]]; then
    log "generating random Kargo JWT signing key"
    KARGO_TOKEN_SIGNING_KEY="$("$sandboxctl_bin" secret rand 32)"   # 64 hex chars
    generated=1
  fi

  if (( generated )); then
    umask 077
    cat > "$SANDBOX_SECRETS_FILE" <<EOF
# Per-install secrets generated by sandboxctl. DO NOT COMMIT.
# Re-running 'up' reuses these. 'purge' deletes them. To rotate any value,
# delete its line and run 'sandboxctl up' (or 'restart').
KARGO_ADMIN_PASSWORD='${KARGO_ADMIN_PASSWORD}'
KARGO_ADMIN_PASSWORD_HASH='${KARGO_ADMIN_PASSWORD_HASH}'
KARGO_TOKEN_SIGNING_KEY='${KARGO_TOKEN_SIGNING_KEY}'
EOF
    chmod 600 "$SANDBOX_SECRETS_FILE"
  fi
}

# ============================================================================
# State file (~/.sandboxctl/setup.yaml)
# ============================================================================

# Persist the chosen Podman VM sizing so subsequent invocations re-apply
# it without the user passing flags again. Sourced at the top of the
# script (SANDBOX_PODMAN_CONFIG); env vars still win when set explicitly.
# Only writes keys that have a value, so it doesn't leak `unset` over a
# previously-saved value when the user only updates one dimension.
write_podman_config() {
  mkdir -p "$SANDBOX_STATE_DIR"
  local cpus="${1:-${PODMAN_MACHINE_CPUS:-}}"
  local mem_mib="${2:-${PODMAN_MACHINE_MEMORY_MIB:-}}"
  local disk_gib="${3:-${PODMAN_MACHINE_DISK_GIB:-}}"

  # Merge with whatever's already saved so a partial update preserves
  # untouched dimensions (e.g. saving only --podman-disk shouldn't
  # forget a previously-saved --podman-memory).
  if [[ -f "$SANDBOX_PODMAN_CONFIG" ]]; then
    local prev_cpus prev_mem prev_disk
    prev_cpus="$(awk -F= '$1=="PODMAN_MACHINE_CPUS"{print $2; exit}' "$SANDBOX_PODMAN_CONFIG" 2>/dev/null || true)"
    prev_mem="$(awk -F= '$1=="PODMAN_MACHINE_MEMORY_MIB"{print $2; exit}' "$SANDBOX_PODMAN_CONFIG" 2>/dev/null || true)"
    prev_disk="$(awk -F= '$1=="PODMAN_MACHINE_DISK_GIB"{print $2; exit}' "$SANDBOX_PODMAN_CONFIG" 2>/dev/null || true)"
    [[ -z "$cpus"     && -n "$prev_cpus" ]] && cpus="$prev_cpus"
    [[ -z "$mem_mib"  && -n "$prev_mem"  ]] && mem_mib="$prev_mem"
    [[ -z "$disk_gib" && -n "$prev_disk" ]] && disk_gib="$prev_disk"
  fi

  {
    printf '# managed by sandboxctl — Podman VM sizing remembered between runs\n'
    [[ -n "$cpus" ]]     && printf 'PODMAN_MACHINE_CPUS=%s\n' "$cpus"
    [[ -n "$mem_mib" ]]  && printf 'PODMAN_MACHINE_MEMORY_MIB=%s\n' "$mem_mib"
    [[ -n "$disk_gib" ]] && printf 'PODMAN_MACHINE_DISK_GIB=%s\n' "$disk_gib"
  } > "$SANDBOX_PODMAN_CONFIG"
}

write_state_file() {
  mkdir -p "$SANDBOX_STATE_DIR"
  cat > "$SANDBOX_STATE_FILE" <<EOF
# managed by sandboxctl — describes the live sandbox so 'restart' brings
# back the same topology. Edit at your own risk.
domain: ${SANDBOX_DOMAIN}
cluster: ${CLUSTER_NAME}
runtime: ${SANDBOX_RUNTIME}
ports:
  http: ${SANDBOX_HTTP_PORT}
  https: ${SANDBOX_HTTPS_PORT}
hosts:
$(while IFS= read -r h; do printf '  - %s\n' "$h"; done < <(_managed_hosts))
launch_agent: ${SANDBOX_LAUNCHAGENT_LABEL}
created_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}

# ============================================================================
# Validation
# ============================================================================

# True if $1 is a live AI Agentic Gateway host. Used by validate_urls to
# accept a 4xx (route-works, upstream-answered) as a pass for the gateways
# that serve 404 at "/".
_is_ai_gateway_host() {
  local h="$1"
  [[ -n "${LITELLM_HOST:-}" && "$h" == "$LITELLM_HOST" ]] && return 0
  [[ -n "${PORTKEY_HOST:-}" && "$h" == "$PORTKEY_HOST" ]] && return 0
  [[ -n "${MLFLOW_HOST:-}"  && "$h" == "$MLFLOW_HOST"  ]] && return 0
  [[ -n "${TYK_HOST:-}"     && "$h" == "$TYK_HOST"     ]] && return 0
  return 1
}

validate_urls() {
  log "validating URLs reachable from the Mac"
  local failed=0 host url code
  while IFS= read -r host; do
    url="https://${host}:${SANDBOX_HTTPS_PORT}/"
    # -k: curl's bundle doesn't know our local CA (browser does post-trust).
    # tail -c 3: --retry prints one code per attempt; we want the final one.
    code="$(curl -sk -o /dev/null -w '%{http_code}' \
      --max-time 8 --retry 8 --retry-delay 2 --retry-connrefused \
      "$url" 2>/dev/null | tail -c 3 || echo 000)"
    # The WSS endpoint accepts only WebSocket-upgrade traffic; a plain
    # GET returns 400 Bad Request from nats-server. Treat that as a
    # successful proof-of-life — the connection reached upstream.
    local ok_code=0
    if [[ "$code" =~ ^(2|3)[0-9][0-9]$ ]]; then
      ok_code=1
    elif declare -F nats_present >/dev/null && nats_present \
         && [[ "$host" == "$NATS_HOST" && "$code" == "400" ]]; then
      ok_code=1
    elif _is_ai_gateway_host "$host" && [[ "$code" =~ ^4[0-9][0-9]$ ]]; then
      # Tyk/Portkey answer 404 at "/" with no API mounted — that 4xx still
      # proves the route + upstream are alive (a dead route would be 503/000).
      ok_code=1
    fi
    if (( ok_code )); then
      printf '  %-50s OK (%s)\n' "$url" "$code"
    else
      printf '  %-50s FAIL (%s)\n' "$url" "$code"
      failed=1
    fi
  done < <(_managed_hosts)
  # NATS TCP is on a separate port so it doesn't share the loop above.
  # Only check it when NATS was actually opted into — otherwise a
  # core-only `up` (no --with-nats) would always FAIL on a port that
  # was never meant to be bound.
  local nats_failed=0
  if declare -F nats_present >/dev/null && nats_present \
     && [[ -n "${NATS_HOST:-}" && -n "${SANDBOX_NATS_PORT:-}" ]]; then
    local ntag="nats://${NATS_HOST}:${SANDBOX_NATS_PORT}"
    if nc -z 127.0.0.1 "$SANDBOX_NATS_PORT" 2>/dev/null; then
      printf '  %-50s OK (tcp)\n' "$ntag"
    else
      printf '  %-50s FAIL (tcp)\n' "$ntag"
      failed=1
      nats_failed=1
    fi
  fi
  if (( failed )); then
    warn "one or more URLs are not reachable from the Mac — see ${SANDBOX_PF_LOG} and 'sandboxctl status'"
    if (( nats_failed )); then
      # Common cause: an earlier `up` ran without --with-nats but the
      # cluster still has NATS, so /etc/hosts maps nats.${SANDBOX_DOMAIN}
      # to 127.0.0.1 with nothing listening. cmd_restart re-runs
      # install_nats_portfwd because it auto-detects in-cluster NATS.
      warn "  NATS TCP is bound by a LaunchAgent (${NATS_LAUNCHAGENT_LABEL:-io.github.sandboxctl.nats-portfwd})."
      warn "  If this is a fresh sandbox or after a reboot, run: sandboxctl restart"
    fi
    return 1
  fi
  ok "all URLs reachable"
}

# ============================================================================
# Legacy artifact cleanup (for users upgrading from older sandboxctl versions)
# ============================================================================

clean_legacy_state() {
  # In-cluster: prior versions installed nginx-ingress, traefik (during the
  # public-mode experiment) or an Argo-managed guestbook Application. Remove
  # all of those before installing the current topology.
  helm_uninstall_if_present ingress-nginx "$LEGACY_INGRESS_NS"
  kc delete namespace "$LEGACY_INGRESS_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  helm_uninstall_if_present traefik "$LEGACY_TRAEFIK_NS"
  kc delete namespace "$LEGACY_TRAEFIK_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true

  kc -n "$ARGOCD_NS"        delete ingress argocd-server --ignore-not-found >/dev/null 2>&1 || true
  kc -n "$KARGO_NS"         delete ingress kargo-api     --ignore-not-found >/dev/null 2>&1 || true
  kc -n "$DEMO_NS"          delete ingress demo-app      --ignore-not-found >/dev/null 2>&1 || true
  kc -n "$LEGACY_GUESTBOOK_NS" delete ingress demo-app   --ignore-not-found >/dev/null 2>&1 || true

  # Traefik route resources from the public-mode experiment.
  kc -n "$ARGOCD_NS"        delete ingressroute argocd   --ignore-not-found >/dev/null 2>&1 || true
  kc -n "$KARGO_NS"         delete ingressroute kargo    --ignore-not-found >/dev/null 2>&1 || true
  kc -n "$KARGO_NS"         delete serverstransport kargo-insecure-transport --ignore-not-found >/dev/null 2>&1 || true
  kc -n "$DEMO_NS"          delete ingressroute demo-app --ignore-not-found >/dev/null 2>&1 || true
  kc -n "$LEGACY_GUESTBOOK_NS" delete ingressroute demo-app --ignore-not-found >/dev/null 2>&1 || true

  # Old Argo-managed guestbook Application + namespace from earlier versions.
  if kc -n "$ARGOCD_NS" get application guestbook >/dev/null 2>&1; then
    log "removing legacy Argo CD 'guestbook' Application"
    kc -n "$ARGOCD_NS" patch application guestbook --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
    kc -n "$ARGOCD_NS" delete application guestbook --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
  if kc get namespace "$LEGACY_GUESTBOOK_NS" >/dev/null 2>&1 && [[ "$LEGACY_GUESTBOOK_NS" != "$DEMO_NS" ]]; then
    kc delete namespace "$LEGACY_GUESTBOOK_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi

  # Host-side: stale socat forwarder containers, orphan kubectl port-forward.
  local proto
  for proto in http https; do
    "$SANDBOX_RUNTIME" rm -f "${CLUSTER_NAME}-portfwd-${proto}" >/dev/null 2>&1 || true
  done
  pkill -f "port-forward.*svc/(istio-ingress|traefik)" >/dev/null 2>&1 || true
}

# ============================================================================
# up_needs_sudo / sudo keepalive
# ============================================================================

up_needs_sudo() {
  hosts_line_present || return 0
  ca_already_trusted || return 0
  # Resolver file under /etc/resolver/ is owned by root and so is
  # `sudo brew services` (system-domain launchd). If either is missing,
  # install_dnsmasq will need a sudo prompt.
  [[ -f "/etc/resolver/${SANDBOX_DOMAIN}" ]] || return 0
  return 1
}

start_sudo_keepalive() {
  ( while true; do sudo -n true 2>/dev/null || exit 0; sleep 60; done ) &
  SUDO_KEEPALIVE_PID=$!
  trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT
}

# ============================================================================
# Command handlers
# ============================================================================

cmd_up() {
  # All add-ons are opt-in. A plain `sandboxctl up` brings up only the
  # core: kind + cert-manager + PKI + Argo CD + Kargo + reflector +
  # reloader + in-cluster registry (NodePort 30050) + Gitea + Istio
  # ambient + routes + /etc/hosts + dnsmasq + LaunchAgent port-forward +
  # demo app. Toggle add-ons individually (--with-X) or all at once
  # (--install all).
  INSTALL_KAGENT=0
  local opt_podman_cpus="" opt_podman_memory_mib="" opt_podman_disk_gib=""
  local podman_resize_requested=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --with-kagent)        INSTALL_KAGENT=1; shift ;;
      --with-arctl)         INSTALL_ARCTL=1; shift ;;
      --with-cnpg)          INSTALL_CNPG=1; shift ;;
      --with-agentregistry) INSTALL_AGENTREGISTRY=1; INSTALL_CNPG=1; shift ;;
      --with-nats)          INSTALL_NATS=1; shift ;;
      --with-agentgateway)  INSTALL_AGENTGATEWAY=1; shift ;;
      --with-portkey)       INSTALL_PORTKEY=1; shift ;;
      --with-litellm)       INSTALL_LITELLM=1; shift ;;
      --with-mlflow)        INSTALL_MLFLOW=1; shift ;;
      --with-tyk)           INSTALL_TYK=1; shift ;;
      --with-ai-gateway)    INSTALL_AGENTGATEWAY=1; INSTALL_LITELLM=1; INSTALL_PORTKEY=1; INSTALL_MLFLOW=1; INSTALL_TYK=1; shift ;;
      --no-nats-cli)        INSTALL_NATS_CLI=0; shift ;;
      # Deprecated --no-* flags. The named components are now opt-in by
      # default, so passing --no-X is a no-op kept only so older docs and
      # scripts keep working. They will be removed once nothing in the
      # team's muscle memory relies on them.
      --no-arctl|--no-agentregistry|--no-agentgateway|--no-litellm|--no-portkey|--no-mlflow|--no-tyk|--no-ai-gateway|--no-nats|--no-cnpg)
        shift ;;
      --workers)
        SANDBOX_WORKER_COUNT="${2:-}"
        validate_worker_count "$SANDBOX_WORKER_COUNT" "sandboxctl up"
        shift 2 ;;
      --podman-cpus)
        opt_podman_cpus="${2:-}"
        [[ "$opt_podman_cpus" =~ ^[0-9]+$ ]] || die "--podman-cpus must be a positive integer (got '${opt_podman_cpus}')"
        podman_resize_requested=1
        shift 2 ;;
      --podman-memory)
        # Accept '<N>g' / '<N>G' / '<N>gib' (GiB) or '<N>m' / '<N>mib' (MiB)
        # or a bare integer in MiB to mirror PODMAN_MACHINE_MEMORY_MIB.
        local _mem_in="${2:-}"
        opt_podman_memory_mib="$(_normalize_mem_to_mib "$_mem_in")" \
          || die "--podman-memory must look like '8g', '12gib', '8192' or '8192m' (got '${_mem_in}')"
        podman_resize_requested=1
        shift 2 ;;
      --podman-disk)
        # GiB only — that's what `podman machine init --disk-size` takes.
        local _disk_in="${2:-}"
        # Allow trailing 'g' / 'gib' for clarity ("80g", "80gib").
        _disk_in="$(printf '%s' "$_disk_in" | tr '[:upper:]' '[:lower:]' | sed 's/gib$//;s/g$//')"
        [[ "$_disk_in" =~ ^[0-9]+$ ]] || die "--podman-disk must be a positive integer in GiB (e.g. 80, 80g)"
        opt_podman_disk_gib="$_disk_in"
        podman_resize_requested=1
        shift 2 ;;
      --install)
        case "${2:-}" in
          all)
            INSTALL_KAGENT=1
            INSTALL_ARCTL=1
            INSTALL_CNPG=1
            INSTALL_AGENTREGISTRY=1
            INSTALL_NATS=1
            INSTALL_AGENTGATEWAY=1
            INSTALL_LITELLM=1
            INSTALL_PORTKEY=1
            INSTALL_MLFLOW=1
            INSTALL_TYK=1
            shift 2 ;;
          *) die "--install: expected 'all' (got '${2:-}')" ;;
        esac ;;
      -h|--help)
        cat <<EOF
sandboxctl up [--workers N]
              [--podman-cpus N] [--podman-memory SIZE] [--podman-disk GiB]
              [--with-arctl] [--with-cnpg] [--with-agentregistry] [--with-nats] [--with-kagent]
              [--with-agentgateway | --with-ai-gateway | --with-portkey | --with-litellm | --with-mlflow | --with-tyk]
              [--install all]

Bring the local sandbox cluster up. Default install (no flags) is the
small core: kind + cert-manager + PKI + Argo CD + Kargo + reflector +
reloader + Istio ambient + in-cluster registry (NodePort 30050) + Gitea
+ a demo app, all wired behind https://*.${SANDBOX_DOMAIN}:${SANDBOX_HTTPS_PORT}
via dnsmasq (/etc/resolver/${SANDBOX_DOMAIN}). Add-ons are opt-in.

Cluster topology:
  --workers N      Number of kind worker nodes (default 1, max ${SANDBOX_WORKER_COUNT_MAX}).
                   1 — single node, fastest start, lowest memory (~5 GB).
                   2 — comfortable for ~6 concurrent sandbox pods on 16 GB.
                   3 — recommended for 32 GB+ Macs running heavy workloads.
                   Higher values fail fast: a 4-worker kind cluster on a
                   Mac runs out of host memory before the cluster does.
                   Env override: SANDBOX_WORKER_COUNT=N sandboxctl up.

Podman VM sizing (remembered between runs in ${SANDBOX_PODMAN_CONFIG}):
  --podman-cpus N        CPUs allocated to the rootful Podman VM.
  --podman-memory SIZE   RAM allocated to the Podman VM. Accepts '8g',
                         '12gib', '8192m', or a bare integer (MiB).
  --podman-disk GiB      Disk size, e.g. 80 (or '80g'). Growing disk
                         requires a destructive recreate — sandboxctl
                         will print the exact 'setup-podman --recreate'
                         command instead of silently downgrading.

  All three are persisted, so 'sandboxctl up --podman-disk 80' once is
  enough — future 'up'/'restart' invocations remember 80 GiB without
  the flag. To inspect current sizing: 'cat ${SANDBOX_PODMAN_CONFIG}'.

Default-on (always installed):
  Argo CD          https://argo.${SANDBOX_DOMAIN}:${SANDBOX_HTTPS_PORT}
  Kargo            https://kargo.${SANDBOX_DOMAIN}:${SANDBOX_HTTPS_PORT}
  Demo app         Argo Application syncing manifests/demo-app
  Gitea            in-cluster git server backing 'sandboxctl deploy'
                   https://gitea.${SANDBOX_DOMAIN}:${SANDBOX_HTTPS_PORT}
  Registry         in-cluster registry (NodePort 30050, host-side :5050)
  dnsmasq + DNS    /etc/resolver/${SANDBOX_DOMAIN} → 127.0.0.1 (wildcard)

Opt-in add-ons (flag required to enable):
  --with-arctl         agentregistry CLI on the Mac (build/publish/run
                       MCP servers, agents, skills + prompts). Pin with
                       ARCTL_VERSION; SANDBOX_KEEP_ARCTL=1 keeps it on down/purge.
  --with-cnpg          CloudNativePG operator (Postgres-as-a-CRD).
                       Implied by --with-agentregistry.
  --with-agentregistry agentregistry server in the cluster, backed by
                       a CNPG Postgres with pgvector. Reached at
                       https://aregistry.${SANDBOX_DOMAIN}:${SANDBOX_HTTPS_PORT}.
                       Implies --with-cnpg.
  --with-nats          NATS + JetStream + LaunchAgent port-forward (:4222).
                       Reached at nats://${NATS_HOST:-nats.${SANDBOX_DOMAIN}}:${SANDBOX_NATS_PORT:-4222}.
  --with-kagent        kagent (agentic AI controller + UI).
                       https://kagent.${SANDBOX_DOMAIN}:${SANDBOX_HTTPS_PORT}

AI Agentic Gateway add-ons (each in its own namespace):
  --with-agentgateway  Linux-Foundation Gateway-API-native proxy for AI
                       traffic (MCP / A2A / agent-to-LLM). Drop in
                       HTTPRoutes from any namespace.
                       https://agentgateway.${SANDBOX_DOMAIN}:${SANDBOX_HTTPS_PORT}
  --with-portkey       Portkey OSS gateway + console UI (/public/).
                       https://portkey.${SANDBOX_DOMAIN}:${SANDBOX_HTTPS_PORT}
  --with-litellm       OpenAI-compatible LLM proxy (UI at /ui). Reuses
                       a shared CNPG Postgres (requires --with-agentregistry).
                       https://litellm.${SANDBOX_DOMAIN}:${SANDBOX_HTTPS_PORT}
  --with-mlflow        MLflow experiment tracking + model registry UI.
                       https://mlflow.${SANDBOX_DOMAIN}:${SANDBOX_HTTPS_PORT}
  --with-tyk           Tyk OSS API gateway (+ bundled Redis).
                       https://tyk.${SANDBOX_DOMAIN}:${SANDBOX_HTTPS_PORT}
  --with-ai-gateway    All five gateways at once.

Convenience:
  --install all        Enable every add-on (full demo install).
EOF
        return 0 ;;
      *) die "unknown flag: $1 (try 'sandboxctl up --help')" ;;
    esac
  done
  # Re-validate in case SANDBOX_WORKER_COUNT came from the environment
  # rather than the flag — silent acceptance of a bad env var would lead
  # to a confusing kind error 30s later.
  validate_worker_count "$SANDBOX_WORKER_COUNT" "sandboxctl up"
  export INSTALL_KAGENT
  # INSTALL_NATS_CLI is consumed by lib/nats.sh (shellcheck can't see
  # the cross-file reference, hence the explicit export).
  export INSTALL_NATS_CLI
  # Add-on gates consumed by lib/* installers, or by their wrappers below.
  export INSTALL_ARCTL INSTALL_AGENTREGISTRY INSTALL_NATS INSTALL_CNPG
  export INSTALL_AGENTGATEWAY INSTALL_LITELLM INSTALL_PORTKEY INSTALL_MLFLOW INSTALL_TYK

  require_tools
  ensure_tooling

  if up_needs_sudo; then
    sudo_prompt_banner
    sudo -v || die "sudo required to configure /etc/hosts and System keychain"
    printf '\033[1;32m  ✓ password accepted — continuing\033[0m\n' >&2
    start_sudo_keepalive
  fi

  if (( INSTALL_ARCTL )); then
    install_arctl
  else
    log "skipping arctl (pass --with-arctl or --install all to enable)"
  fi

  # Apply Podman VM sizing before kind starts, so the cluster comes up
  # against the right resources. Persist the chosen sizes so future
  # `up`/`restart`/`setup-podman` invocations remember them without the
  # user re-passing flags.
  if (( podman_resize_requested )); then
    _apply_podman_sizing "$opt_podman_cpus" "$opt_podman_memory_mib" "$opt_podman_disk_gib"
  fi

  bring_up_cluster
  # Set current-context in the canonical user kubeconfig so plain
  # `kubectl` (no flags) targets the sandbox in any new shell. Pinning
  # to ~/.kube/config matches where kind_pinned writes the context.
  KUBECONFIG="$SANDBOX_USER_KUBECONFIG" kubectl config use-context "$(kctx)" >/dev/null
  kc cluster-info >/dev/null

  load_or_generate_secrets
  install_cert_manager
  install_pki
  clean_legacy_state
  install_argocd
  install_reflector
  install_reloader
  install_kargo
  install_registry
  install_demo_app
  if (( INSTALL_KAGENT )); then
    install_kagent
  else
    log "skipping kagent (pass --with-kagent or --install all to enable)"
  fi
  if (( INSTALL_CNPG )) && declare -F install_cnpg >/dev/null; then
    install_cnpg
  fi
  if (( INSTALL_AGENTREGISTRY )) && declare -F install_aregistry >/dev/null; then
    install_aregistry
  else
    log "skipping agentregistry (pass --with-agentregistry or --install all to enable)"
  fi
  # AI Agentic Gateway: each installer self-gates on its INSTALL_* flag
  # and is non-fatal, so a slow/broken add-on never aborts `up`.
  # Installed before install_routes so the present-gated VirtualServices
  # are created. agentgateway runs first because it brings up the
  # upstream Gateway API CRDs, which any future opt-in lib (or product
  # chart) can reuse.
  if declare -F install_agentgateway >/dev/null; then install_agentgateway; fi
  if declare -F install_litellm      >/dev/null; then install_litellm;      fi
  if declare -F install_portkey      >/dev/null; then install_portkey;      fi
  if declare -F install_mlflow       >/dev/null; then install_mlflow;       fi
  if declare -F install_tyk          >/dev/null; then install_tyk;          fi
  install_gitea
  install_istio_ambient
  install_routes
  # Self-heal pattern (matches cmd_restart): if NATS is already in the
  # cluster from a previous run, treat it as installed even when the
  # caller did not pass --with-nats. Without this, a second `up` without
  # the flag leaves NATS pods running, nats.${SANDBOX_DOMAIN} still in
  # /etc/hosts (via _managed_hosts → nats_present), but no LaunchAgent
  # → validate_urls reports `nats://nats.sandbox.app:4222 FAIL (tcp)`.
  local up_nats_present=0
  if declare -F nats_present >/dev/null && nats_present; then up_nats_present=1; fi
  if (( INSTALL_NATS )); then
    install_nats
  elif (( up_nats_present )); then
    log "NATS already present in-cluster — re-applying chart + LaunchAgent (pass --with-nats to make this explicit)"
    INSTALL_NATS=1
    install_nats
  else
    log "skipping NATS (pass --with-nats or --install all to enable)"
  fi
  install_hosts
  install_dnsmasq
  install_portfwd
  if (( INSTALL_NATS )) && declare -F install_nats_portfwd >/dev/null; then
    install_nats_portfwd
  fi
  trust_root_ca
  if (( INSTALL_NATS )) && declare -F trust_nats_ca >/dev/null; then
    trust_nats_ca
  fi
  write_state_file
  validate_urls

  cmd_status
  echo
  echo "next:"
  printf '  open https://%s:%s\n' "$ARGO_HOST"  "$SANDBOX_HTTPS_PORT"
  printf '  open https://%s:%s\n' "$KARGO_HOST" "$SANDBOX_HTTPS_PORT"
  printf '  open https://%s:%s\n' "$DEMO_HOST"  "$SANDBOX_HTTPS_PORT"
  if (( INSTALL_KAGENT )); then
    printf '  open https://%s:%s\n' "$KAGENT_HOST" "$SANDBOX_HTTPS_PORT"
  fi
  if (( ${INSTALL_NATS:-0} )) && [[ -n "${NATS_HOST:-}" ]]; then
    printf '  nats:  nats://%s:%s   (or wss://%s)\n' "$NATS_HOST" "$SANDBOX_NATS_PORT" "$NATS_HOST"
  fi
  if declare -F aregistry_present >/dev/null && aregistry_present; then
    printf '  open https://%s:%s\n' "$AREGISTRY_HOST" "$SANDBOX_HTTPS_PORT"
  fi
  if declare -F agentgateway_present >/dev/null && agentgateway_present; then printf '  open https://%s:%s          # agentgateway (AI Agentic Gateway)\n' "$AGENTGATEWAY_HOST" "$SANDBOX_HTTPS_PORT"; fi
  if declare -F litellm_present      >/dev/null && litellm_present;      then printf '  open https://%s:%s/ui      # LiteLLM admin UI\n' "$LITELLM_HOST" "$SANDBOX_HTTPS_PORT"; fi
  if declare -F portkey_present      >/dev/null && portkey_present;      then printf '  open https://%s:%s/public/  # Portkey gateway console\n' "$PORTKEY_HOST" "$SANDBOX_HTTPS_PORT"; fi
  if declare -F mlflow_present       >/dev/null && mlflow_present;       then printf '  open https://%s:%s          # MLflow UI\n' "$MLFLOW_HOST" "$SANDBOX_HTTPS_PORT"; fi
  if declare -F tyk_present          >/dev/null && tyk_present;          then printf '  open https://%s:%s/hello    # Tyk gateway health\n' "$TYK_HOST" "$SANDBOX_HTTPS_PORT"; fi
  echo "  sandboxctl creds   # full login details"
  celebrate "sandbox is up"

  [[ "${SANDBOXCTL_SKIP_ONBOARD_CHECK:-0}" == "1" ]] || _up_onboarding_check "$PWD"
}

# End-of-up onboarding check: is the directory the user launched from
# already onboarded to the sandbox structure (a chart per buildable
# app)? Prints the related commands either way; when the repo is not
# onboarded, shows the exact command + a scaffold dry-run of what it
# would create, and offers to run it on the spot. Also reachable as
# `sandboxctl _onboard-check [dir]` (no cluster needed) so the check is
# testable and re-runnable by hand.
_up_onboarding_check() {
  local dir="${1:-$PWD}"
  command -v sandboxctl >/dev/null 2>&1 || return 0

  local status_line status
  status_line="$(sandboxctl _onboard-status "$dir" 2>/dev/null)" || return 0
  status="${status_line%% *}"

  echo
  log "your app, next"
  case "$status" in
    onboarded)
      ok "this repo is onboarded (${status_line#* })"
      cat <<EOF
  sandboxctl deploy      build + deploy it to the sandbox
  sandboxctl scaffold    re-check generated files (safe: never clobbers your edits)
EOF
      ;;
    needs-onboarding)
      warn "this repo is not onboarded to the sandbox structure yet (${status_line#* })"
      echo
      echo "  Onboarding would run:   sandboxctl scaffold ${dir} --yes"
      echo "  which generates the following (dry-run):"
      echo
      sandboxctl scaffold "$dir" --dry-run 2>/dev/null | sed 's/^/    /'
      echo
      if [[ ! -t 0 ]]; then
        log "no TTY — run 'sandboxctl scaffold' yourself when ready"
        return 0
      fi
      printf '  Onboard this repo now? [y/N] '
      local answer=""
      read -r answer
      case "$answer" in
        y|Y|yes|YES)
          sandboxctl scaffold "$dir" --yes \
            && ok "repo onboarded — 'sandboxctl deploy' (or 'bootstrap') runs it"
          ;;
        *) log "skipped — 'sandboxctl scaffold' any time you're ready" ;;
      esac
      ;;
    *)
      # Not a product repo (or nothing buildable) — just point the way.
      cat <<EOF
  cd <your-product-repo>, then:
    sandboxctl scaffold    generate chart(s), secrets template + Kargo pipeline
    sandboxctl bootstrap   build + deploy + https://<app>.${SANDBOX_DOMAIN}:${SANDBOX_HTTPS_PORT}
EOF
      ;;
  esac
}

# `sandboxctl bootstrap` — one-shot wrapper for first-time users:
#   1. brings the platform up (skipping `up` if the cluster is already
#      running so re-runs are cheap)
#   2. deploys whatever charts live in the current product directory
#
# Run this from your product repo root — the dir that holds your
# Dockerfile(s), chart, k8s/secrets.yaml, and (optionally) sandboxctl.yaml.
# All `up` and `deploy` flags are accepted and forwarded to the right
# sub-step. Path argument follows the same convention as `cmd_deploy`.
#
# Why a separate command instead of an alias? `up` and `deploy` need
# different sudo-priming windows and different working-dir semantics
# (`up` is product-agnostic; `deploy` needs to be run *in* the product
# dir so it can find the Dockerfile / chart / secrets). Bootstrapping
# wraps them so a fresh-checkout user runs one command instead of
# remembering the order.
cmd_bootstrap() {
  local positional="" repo_flag="" up_args=() deploy_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)
        repo_flag="${2:-}"; shift 2 ;;
      --with-kagent|--with-arctl|--with-cnpg|--with-agentregistry|--with-nats|\
      --with-agentgateway|--with-ai-gateway|--with-portkey|--with-litellm|--with-mlflow|--with-tyk|\
      --no-arctl|--no-cnpg|--no-agentregistry|--no-nats|--no-agentgateway|--no-ai-gateway|\
      --no-litellm|--no-portkey|--no-mlflow|--no-tyk|\
      --install)
        # `--install` takes a value (today: "all"). Forward both forms.
        if [[ "$1" == "--install" ]]; then
          up_args+=("$1" "${2:-}"); shift 2
        else
          up_args+=("$1"); shift
        fi ;;
      --workers)
        # Validate up-front so `bootstrap --workers 5` fails before the
        # platform install starts, not 90 seconds in.
        validate_worker_count "${2:-}" "sandboxctl bootstrap"
        up_args+=("$1" "$2"); shift 2 ;;
      --env|--chart|--values|--name)
        deploy_args+=("$1" "${2:-}"); shift 2 ;;
      --no-build|--redeploy|--purge-old-tags|--no-purge-old-tags)
        deploy_args+=("$1"); shift ;;
      -h|--help)
        cat <<EOF
sandboxctl bootstrap [path] [--repo <dir>] [up flags] [deploy flags]

One-shot for first-time users: brings the sandbox cluster up if it
isn't already, then deploys the chart in the product repo. The
product repo is selected by:
  --repo <dir>   explicit pointer to the repo root
  [path]         positional form of the same
  (default)      current working directory (must contain Dockerfile/
                 Chart.yaml/sandboxctl.yaml)

  sandboxctl bootstrap                       # cwd = product dir
  sandboxctl bootstrap path/to/repo
  sandboxctl bootstrap --repo path/to/repo
  sandboxctl bootstrap --workers 2           # forwarded to 'up' (1–${SANDBOX_WORKER_COUNT_MAX})
  sandboxctl bootstrap --with-kagent          # forwarded to 'up'
  sandboxctl bootstrap --with-arctl           # forwarded to 'up'
  sandboxctl bootstrap --with-agentregistry   # forwarded to 'up' (implies --with-cnpg)
  sandboxctl bootstrap --with-nats            # forwarded to 'up'
  sandboxctl bootstrap --with-ai-gateway      # forwarded to 'up' (agentgateway+litellm+portkey+mlflow+tyk)
  sandboxctl bootstrap --install all          # forwarded to 'up' (every add-on)
  sandboxctl bootstrap --chart custom/chart   # forwarded to 'deploy'
  sandboxctl bootstrap --no-build             # forwarded to 'deploy'
  sandboxctl bootstrap --redeploy             # forwarded to 'deploy' (chart-only sync, reuses existing image)

If the cluster is already up the platform install is skipped — only
the deploy half runs, so this is also fine to use as your every-day
"redeploy this app" shortcut.
EOF
        return 0 ;;
      -*) die "unknown flag: $1 (try 'sandboxctl bootstrap --help')" ;;
      *)
        if [[ -z "$positional" ]]; then positional="$1"; shift
        else die "unexpected argument: $1"
        fi ;;
    esac
  done
  local target
  target="$(_resolve_product_repo "$repo_flag" "$positional" bootstrap)" || return 1

  # Print a final status panel even if bootstrap aborts midway. Users
  # reported that earlier failures left them with no signal about what
  # was up vs. broken — the panel mirrors what `up` and `deploy` print
  # at success so they can either recover or re-run.
  trap '_bootstrap_failure_panel' ERR

  # Bring the platform up only if it isn't already. This is what makes
  # bootstrap safe to re-run as a "redeploy my app" shortcut — no
  # 5-minute helm dance on every invocation.
  if cluster_registered && cluster_api_reachable; then
    log "cluster '${CLUSTER_NAME}' is already up — skipping platform install"
    # The cluster being up doesn't guarantee the host-side registry
    # proxy container is still alive — it can disappear after a
    # machine reboot or a podman-machine restart. Heal it up-front so
    # cmd_build below doesn't fail at the first push attempt.
    _ensure_registry_reachable
  else
    log "bringing the sandbox platform up (first run takes ~5–8 min)"
    SANDBOXCTL_SKIP_ONBOARD_CHECK=1 cmd_up ${up_args[@]+"${up_args[@]}"}
  fi

  # Deploy the product's chart. cmd_deploy is responsible for
  # validating that <target> actually contains something deployable.
  log "deploying from product dir: ${target}"
  cmd_deploy "$target" ${deploy_args[@]+"${deploy_args[@]}"}

  trap - ERR
  celebrate "sandbox bootstrapped + product deployed"
}

# Loud failure panel for bootstrap — print what's up vs. what's broken
# so the user can act, instead of leaving them with just an ERROR line
# and no signal.
_bootstrap_failure_panel() {
  local rc=$?
  trap - ERR
  echo
  warn "bootstrap aborted (exit ${rc}) — current state:"
  echo
  if cluster_registered && cluster_api_reachable; then
    cmd_status 2>&1 | sed 's/^/  /' || true
    echo
    echo "  recover by re-running:"
    echo "    sandboxctl bootstrap"
  else
    echo "  • kind cluster '${CLUSTER_NAME}': not running"
    echo
    echo "  recover by:"
    echo "    sandboxctl up"
    echo "    sandboxctl bootstrap   # then re-run the deploy half"
  fi
  sad_trombone "bootstrap aborted"
  exit "$rc"
}

cmd_down() {
  need kind

  # Determine sudo need up-front: only prompt if there's actually root work
  # to do (hosts entries to remove or keychain CA to untrust).
  local need_sudo=0
  hosts_line_present 2>/dev/null && need_sudo=1
  if security find-certificate -c "$ROOT_CA_CN" /Library/Keychains/System.keychain >/dev/null 2>&1; then
    need_sudo=1
  fi
  # arctl lives in (root-owned) /usr/local/bin — fold its removal into the
  # single up-front sudo prompt instead of prompting again mid-teardown.
  if [[ "${SANDBOX_KEEP_ARCTL:-0}" != "1" && -e "${ARCTL_INSTALL_DIR}/arctl" && ! -w "$ARCTL_INSTALL_DIR" ]]; then
    need_sudo=1
  fi
  (( need_sudo )) && prime_sudo

  log "tearing down sandbox '$CLUSTER_NAME'"
  uninstall_portfwd
  uninstall_registry_portfwd
  # Lib-aware cleanup: each add-on lib registers an uninstaller. If the
  # lib was sourced, prefer its tool-specific path (kills child procs,
  # specific log lines, etc.). Otherwise fall through to the generic
  # sweep below by label, which always runs.
  if declare -F uninstall_nats_portfwd >/dev/null; then
    uninstall_nats_portfwd
  fi
  if declare -F uninstall_knative >/dev/null; then
    uninstall_knative
  fi
  sweep_addon_launchagents
  clean_legacy_state

  if cluster_registered; then
    log "deleting kind cluster '$CLUSTER_NAME'"
    if ! with_spinner "kind delete cluster (typically 30–60s)" \
        kind_pinned delete cluster --name "$CLUSTER_NAME"; then
      # kind subcommands can break on runtime/CLI drift (the podman 6
      # template change) while the containers are perfectly deletable.
      # Tear the nodes down at the runtime level so `down` never
      # strands a cluster.
      warn "kind delete failed — removing the node containers directly"
      local _containers
      _containers="$(cluster_node_containers)"
      [[ -n "$_containers" ]] && echo "$_containers" | xargs "$SANDBOX_RUNTIME" rm -f >/dev/null 2>&1 || true
      "$SANDBOX_RUNTIME" network rm kind >/dev/null 2>&1 || true
    fi
  else
    ok "no kind cluster named '$CLUSTER_NAME' to delete"
  fi
  rm -f "$SANDBOX_KUBECONFIG"

  uninstall_hosts
  uninstall_dnsmasq
  if declare -F untrust_nats_ca >/dev/null; then
    untrust_nats_ca
  fi
  untrust_root_ca
  uninstall_arctl
  if declare -F uninstall_nats_cli >/dev/null; then
    uninstall_nats_cli
  fi

  ok "sandbox down (cluster, LaunchAgent, /etc/hosts, dnsmasq config, root CA trust, arctl removed)"
  echo "Preserved: ${SANDBOX_STATE_DIR} (logs/state) — use 'sandboxctl purge' to also remove it."
  echo "Leaves alone: kindest/node image cache, podman machine."
}

cmd_purge() {
  cat <<EOF
This will do everything 'sandboxctl down' does, plus:
  • remove ${SANDBOX_STATE_DIR}

EOF
  if [[ "${SANDBOX_PURGE_ASSUME_YES:-}" != "1" ]]; then
    local reply=""
    read -r -p "Proceed? [y/N] " reply
    case "${reply:-N}" in
      y|Y|yes|YES) ;;
      *) ok "purge cancelled"; return 0 ;;
    esac
  fi
  cmd_down
  if [[ -d "$SANDBOX_STATE_DIR" ]]; then
    log "removing $SANDBOX_STATE_DIR"
    rm -rf "$SANDBOX_STATE_DIR"
  fi
  ok "purge complete"
}

# `sandboxctl restart` — non-destructive re-apply.
#
# Earlier versions did `cmd_down && cmd_up` which deleted the kind
# cluster and rebuilt it from scratch (5–8 min, lost stream state,
# lost in-cluster registry blobs, lost user secrets). The new behaviour
# keeps the cluster + PVCs + Argo apps intact and just reapplies
# everything that's idempotent: helm upgrades, Istio routes, /etc/hosts,
# dnsmasq, LaunchAgents.
#
# When you genuinely want a wipe-and-rebuild, use:
#   sandboxctl down && sandboxctl up
# or:
#   sandboxctl restart --rebuild   (alias for down + up)
cmd_restart() {
  local rebuild=0
  local up_args=()
  local opt_podman_cpus="" opt_podman_memory_mib="" opt_podman_disk_gib=""
  local podman_resize_requested=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --rebuild|--full) rebuild=1; shift ;;
      --workers)
        validate_worker_count "${2:-}" "sandboxctl restart"
        up_args+=("$1" "$2"); shift 2 ;;
      --podman-cpus)
        opt_podman_cpus="${2:-}"
        [[ "$opt_podman_cpus" =~ ^[0-9]+$ ]] || die "--podman-cpus must be a positive integer (got '${opt_podman_cpus}')"
        podman_resize_requested=1
        up_args+=("$1" "$2")
        shift 2 ;;
      --podman-memory)
        local _mem_in="${2:-}"
        opt_podman_memory_mib="$(_normalize_mem_to_mib "$_mem_in")" \
          || die "--podman-memory must look like '8g', '12gib', '8192' or '8192m' (got '${_mem_in}')"
        podman_resize_requested=1
        up_args+=("$1" "$2")
        shift 2 ;;
      --podman-disk)
        local _disk_in="${2:-}"
        _disk_in="$(printf '%s' "$_disk_in" | tr '[:upper:]' '[:lower:]' | sed 's/gib$//;s/g$//')"
        [[ "$_disk_in" =~ ^[0-9]+$ ]] || die "--podman-disk must be a positive integer in GiB (e.g. 80, 80g)"
        opt_podman_disk_gib="$_disk_in"
        podman_resize_requested=1
        up_args+=("$1" "$2")
        shift 2 ;;
      -h|--help)
        cat <<EOF
sandboxctl restart [--rebuild] [--workers N]
                   [--podman-cpus N] [--podman-memory SIZE] [--podman-disk GiB]

Non-destructive: keeps the kind cluster, all PVCs (incl. NATS JetStream
state and the in-cluster registry), Argo Apps, and Gitea repos.
Re-runs every helm install (idempotent), reapplies Istio routes,
refreshes /etc/hosts and dnsmasq, and reloads the LaunchAgents.

  --rebuild       wipe-and-rebuild: equivalent to 'sandboxctl down && sandboxctl up'.
                  Use only when you suspect cluster-level corruption — recreating
                  kind takes 5–8 min and erases stream state.
  --workers N     Resize the cluster (1–${SANDBOX_WORKER_COUNT_MAX} workers). Implies --rebuild
                  because kind doesn't support adding nodes to an existing
                  cluster — the cluster is recreated with the new worker count.

Podman VM sizing (remembered between runs in ${SANDBOX_PODMAN_CONFIG}):
  --podman-cpus N        Live-resize CPUs on the rootful Podman VM.
  --podman-memory SIZE   Live-resize RAM. '8g' / '12gib' / '8192' (MiB).
  --podman-disk GiB      Disk grow needs a recreate — sandboxctl prints
                         the exact destructive command instead of
                         silently downgrading.
  All three are persisted so future 'up'/'restart' inherits the size.
EOF
        return 0 ;;
      *) die "unknown flag: $1 (try 'sandboxctl restart --help')" ;;
    esac
  done

  # Resizing requires recreation. Promote --workers to --rebuild so the
  # behaviour matches what the help text promises.
  if (( ${#up_args[@]} > 0 )); then
    rebuild=1
  fi

  if (( rebuild )); then
    log "restart --rebuild: full down + up (this will take 5–8 min)"
    cmd_down
    SANDBOXCTL_SKIP_ONBOARD_CHECK=1 cmd_up ${up_args[@]+"${up_args[@]}"}
    return
  fi

  if ! cluster_registered; then
    warn "no kind cluster to restart — running full 'up' instead"
    cmd_up
    return
  fi

  log "restart: keeping kind cluster '$CLUSTER_NAME', re-applying everything else"
  require_tools
  ensure_tooling

  # Apply Podman sizing changes before talking to the cluster, since
  # `podman machine set` requires the machine to be stopped (and
  # restarting it bounces kind anyway, which we'll bring back below).
  if (( podman_resize_requested )); then
    _apply_podman_sizing "$opt_podman_cpus" "$opt_podman_memory_mib" "$opt_podman_disk_gib"
  fi

  # The cluster might be stopped (machine reboot). Bring it back to
  # Ready before any kc/helm calls.
  if ! cluster_api_reachable; then
    log "kind cluster '$CLUSTER_NAME' is registered but stopped — starting it"
    start_stopped_cluster
  fi
  write_pinned_kubeconfig
  KUBECONFIG="$SANDBOX_USER_KUBECONFIG" kubectl config use-context "$(kctx)" >/dev/null
  kc cluster-info >/dev/null

  load_or_generate_secrets
  install_cert_manager
  install_pki
  clean_legacy_state
  install_argocd
  install_reflector
  install_reloader
  install_kargo
  install_registry
  install_demo_app
  if (( ${INSTALL_KAGENT:-0} )) || _kagent_present; then
    install_kagent
  fi
  # On restart, re-assert any add-on that's already in the cluster even
  # if its flag wasn't passed — restart should never silently undo what
  # `up --with-X` previously installed. Each lib function is idempotent.
  if (( ${INSTALL_CNPG:-0} )) || (declare -F cnpg_present >/dev/null && cnpg_present); then
    if declare -F install_cnpg >/dev/null; then INSTALL_CNPG=1 install_cnpg; fi
  fi
  if (( ${INSTALL_AGENTREGISTRY:-0} )) || (declare -F aregistry_present >/dev/null && aregistry_present); then
    if declare -F install_aregistry >/dev/null; then INSTALL_AGENTREGISTRY=1 INSTALL_CNPG=1 install_aregistry; fi
  fi
  if (( ${INSTALL_AGENTGATEWAY:-0} )) || (declare -F agentgateway_present >/dev/null && agentgateway_present); then
    if declare -F install_agentgateway >/dev/null; then INSTALL_AGENTGATEWAY=1 install_agentgateway; fi
  fi
  if (( ${INSTALL_LITELLM:-0} )) || (declare -F litellm_present >/dev/null && litellm_present); then
    if declare -F install_litellm >/dev/null; then INSTALL_LITELLM=1 install_litellm; fi
  fi
  if (( ${INSTALL_PORTKEY:-0} )) || (declare -F portkey_present >/dev/null && portkey_present); then
    if declare -F install_portkey >/dev/null; then INSTALL_PORTKEY=1 install_portkey; fi
  fi
  if (( ${INSTALL_MLFLOW:-0} )) || (declare -F mlflow_present >/dev/null && mlflow_present); then
    if declare -F install_mlflow >/dev/null; then INSTALL_MLFLOW=1 install_mlflow; fi
  fi
  if (( ${INSTALL_TYK:-0} )) || (declare -F tyk_present >/dev/null && tyk_present); then
    if declare -F install_tyk >/dev/null; then INSTALL_TYK=1 install_tyk; fi
  fi
  install_gitea
  install_istio_ambient
  install_routes
  local nats_present=0
  if kc get namespace "${NATS_NS:-nats}" >/dev/null 2>&1; then nats_present=1; fi
  if (( ${INSTALL_NATS:-0} )) || (( nats_present )); then
    if declare -F install_nats >/dev/null; then install_nats; fi
  fi
  install_hosts
  install_dnsmasq
  install_portfwd
  if (( ${INSTALL_NATS:-0} )) || (( nats_present )); then
    if declare -F install_nats_portfwd >/dev/null; then install_nats_portfwd; fi
  fi
  trust_root_ca
  if (( ${INSTALL_NATS:-0} )) || (( nats_present )); then
    if declare -F trust_nats_ca >/dev/null; then trust_nats_ca; fi
  fi
  write_state_file
  validate_urls

  ok "restart complete (cluster preserved)"
  cmd_status
  celebrate "sandbox restarted"
}

# ----- Status -----

workload_summary() {
  local ns="$1" label="$2" total ready
  if ! kc get namespace "$ns" >/dev/null 2>&1; then
    printf '  %-10s %s\n' "$label:" "(not installed)"; return
  fi
  total=$(kc -n "$ns" get pods --no-headers 2>/dev/null | wc -l | tr -d ' ')
  ready=$(kc -n "$ns" get pods --no-headers 2>/dev/null | awk '$3=="Running" || $3=="Completed"' | wc -l | tr -d ' ')
  printf '  %-10s %s/%s pods ready\n' "$label:" "$ready" "$total"
}

cmd_status() {
  if ! cluster_registered; then echo "cluster:  not present"; return; fi
  if ! cluster_api_reachable; then
    echo "cluster:  $CLUSTER_NAME (stopped — run 'sandboxctl up' to start it)"
    return
  fi
  local node
  node="$(kc get nodes --no-headers 2>/dev/null | awk '{print $1" ("$2")"}' | head -1)"
  echo "cluster:   $CLUSTER_NAME (running) — $node"
  if hosts_line_present; then echo "hosts:     ok (/etc/hosts maps the three hostnames)"
  else                        echo "hosts:     not configured (run 'sandboxctl up')"; fi
  if portfwd_running; then
    if nc -z 127.0.0.1 "$SANDBOX_HTTPS_PORT" 2>/dev/null
      then echo "portfwd:   ok (LaunchAgent active, :${SANDBOX_HTTPS_PORT} bound)"
      else echo "portfwd:   loaded but :${SANDBOX_HTTPS_PORT} not yet bound — see ${SANDBOX_PF_LOG}"; fi
  else
    echo "portfwd:   not running (LaunchAgent not loaded)"
  fi
  echo
  echo "workloads:"
  workload_summary "$ISTIO_SYSTEM_NS"  "istio-sys"
  workload_summary "$ISTIO_INGRESS_NS" "istio-gw"
  workload_summary "$CERT_MANAGER_NS"  "cert-mgr"
  workload_summary "$ARGOCD_NS"        "argocd"
  workload_summary "$RELOADER_NS"      "reloader"
  workload_summary "$KARGO_NS"         "kargo"
  workload_summary "$REGISTRY_NS"      "registry"
  workload_summary "$DEMO_NS"          "demo-app"
  if _kagent_present; then
    workload_summary "$KAGENT_NS"      "kagent"
  fi
  if [[ -n "${NATS_NS:-}" ]] && kc get namespace "$NATS_NS" >/dev/null 2>&1; then
    workload_summary "$NATS_NS"        "nats"
  fi
  if declare -F aregistry_present >/dev/null && aregistry_present; then
    workload_summary "$AREGISTRY_NS"   "aregistry"
  fi
  if declare -F agentgateway_present >/dev/null && agentgateway_present; then workload_summary "$AGENTGATEWAY_NS" "agentgw"; fi
  if declare -F litellm_present      >/dev/null && litellm_present;      then workload_summary "$LITELLM_NS"      "litellm"; fi
  if declare -F portkey_present      >/dev/null && portkey_present;      then workload_summary "$PORTKEY_NS"      "portkey"; fi
  if declare -F mlflow_present       >/dev/null && mlflow_present;       then workload_summary "$MLFLOW_NS"       "mlflow";  fi
  if declare -F tyk_present          >/dev/null && tyk_present;          then workload_summary "$TYK_NS"          "tyk";     fi
  if declare -F nats_present >/dev/null && nats_present \
     && declare -F nats_status >/dev/null; then
    echo
    nats_status | sed 's/^/  /'
  fi
  if declare -F aregistry_status >/dev/null; then
    aregistry_status | sed 's/^/  /'
  fi
  if declare -F agentgateway_status >/dev/null; then agentgateway_status | sed 's/^/  /'; fi
  if declare -F litellm_status      >/dev/null; then litellm_status      | sed 's/^/  /'; fi
  if declare -F portkey_status      >/dev/null; then portkey_status      | sed 's/^/  /'; fi
  if declare -F mlflow_status       >/dev/null; then mlflow_status       | sed 's/^/  /'; fi
  if declare -F tyk_status          >/dev/null; then tyk_status          | sed 's/^/  /'; fi
  echo
  echo "apps & URLs:"
  printf '  %-12s https://%s:%s\n' "argocd"   "$ARGO_HOST"   "$SANDBOX_HTTPS_PORT"
  printf '  %-12s https://%s:%s\n' "kargo"    "$KARGO_HOST"  "$SANDBOX_HTTPS_PORT"
  printf '  %-12s https://%s:%s\n' "demo-app" "$DEMO_HOST"   "$SANDBOX_HTTPS_PORT"
  if _kagent_present; then
    printf '  %-12s https://%s:%s\n' "kagent" "$KAGENT_HOST" "$SANDBOX_HTTPS_PORT"
  fi
  if declare -F nats_present >/dev/null && nats_present; then
    printf '  %-12s nats://%s:%s   (also wss: https://%s)\n' \
      "nats" "$NATS_HOST" "$SANDBOX_NATS_PORT" "$NATS_HOST"
  fi
  if declare -F aregistry_present >/dev/null && aregistry_present; then
    printf '  %-12s https://%s:%s\n' "aregistry" "$AREGISTRY_HOST" "$SANDBOX_HTTPS_PORT"
  fi
  if declare -F agentgateway_present >/dev/null && agentgateway_present; then printf '  %-12s https://%s:%s\n' "agentgateway" "$AGENTGATEWAY_HOST" "$SANDBOX_HTTPS_PORT"; fi
  if declare -F litellm_present      >/dev/null && litellm_present;      then printf '  %-12s https://%s:%s\n' "litellm" "$LITELLM_HOST" "$SANDBOX_HTTPS_PORT"; fi
  if declare -F portkey_present      >/dev/null && portkey_present;      then printf '  %-12s https://%s:%s/public/\n' "portkey" "$PORTKEY_HOST" "$SANDBOX_HTTPS_PORT"; fi
  if declare -F mlflow_present       >/dev/null && mlflow_present;       then printf '  %-12s https://%s:%s\n' "mlflow" "$MLFLOW_HOST" "$SANDBOX_HTTPS_PORT"; fi
  if declare -F tyk_present          >/dev/null && tyk_present;          then printf '  %-12s https://%s:%s\n' "tyk" "$TYK_HOST" "$SANDBOX_HTTPS_PORT"; fi
  printf '  %-12s localhost:%s    (push: docker push localhost:%s/<image>:<tag>)\n' "registry" "$SANDBOX_REGISTRY_PORT" "$SANDBOX_REGISTRY_PORT"
}

# ----- Creds -----

argocd_admin_password() {
  kc -n "$ARGOCD_NS" get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true
}

load_kargo_secret_for_display() {
  if [[ -f "$SANDBOX_SECRETS_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$SANDBOX_SECRETS_FILE"
  fi
}

cmd_creds() {
  require_running_cluster
  local argo_pw kargo_pw
  argo_pw="$(argocd_admin_password)"
  load_kargo_secret_for_display
  kargo_pw="${KARGO_ADMIN_PASSWORD:-}"
  cat <<EOF
Argo CD
  URL:       https://${ARGO_HOST}:${SANDBOX_HTTPS_PORT}
  username:  admin
  password:  ${argo_pw:-<argocd-initial-admin-secret not found; retry shortly>}
  CLI:       argocd login ${ARGO_HOST}:${SANDBOX_HTTPS_PORT} --username admin --password '${argo_pw:-<password>}' --grpc-web

Kargo
  URL:       https://${KARGO_HOST}:${SANDBOX_HTTPS_PORT}
  username:  admin
  password:  ${kargo_pw:-<run 'sandboxctl up' to generate>}
  CLI:       kargo login https://${KARGO_HOST}:${SANDBOX_HTTPS_PORT} --admin --password '${kargo_pw:-<password>}'

Demo app
  URL:       https://${DEMO_HOST}:${SANDBOX_HTTPS_PORT}
EOF
  if _kagent_present; then
    cat <<EOF

kagent
  URL:       https://${KAGENT_HOST}:${SANDBOX_HTTPS_PORT}
  Note:      controller + UI only — no model provider is configured.
             Wire a provider/model in the kagent UI (or via CRDs) before agents can answer.
EOF
  fi
  if declare -F aregistry_print_creds >/dev/null && aregistry_present; then
    echo
    aregistry_print_creds
  fi
  if declare -F agentgateway_print_creds >/dev/null && agentgateway_present; then echo; agentgateway_print_creds; fi
  if declare -F litellm_print_creds      >/dev/null && litellm_present;      then echo; litellm_print_creds;      fi
  if declare -F portkey_print_creds      >/dev/null && portkey_present;      then echo; portkey_print_creds;      fi
  if declare -F mlflow_print_creds       >/dev/null && mlflow_present;       then echo; mlflow_print_creds;       fi
  if declare -F tyk_print_creds          >/dev/null && tyk_present;          then echo; tyk_print_creds;          fi
  printf '\nkubectl context: %s\n' "$(kctx)"
}

cmd_argocd_ui() {
  require_running_cluster
  local pw; pw="$(argocd_admin_password)"
  echo "URL:      https://${ARGO_HOST}:${SANDBOX_HTTPS_PORT}"
  echo "user:     admin"
  echo "password: ${pw:-<argocd-initial-admin-secret not yet created; retry in a moment>}"
}

cmd_kargo_ui() {
  require_running_cluster
  load_kargo_secret_for_display
  echo "URL:      https://${KARGO_HOST}:${SANDBOX_HTTPS_PORT}"
  echo "user:     admin"
  echo "password: ${KARGO_ADMIN_PASSWORD:-<run 'sandboxctl up' to generate>}"
}

# ----- Build + push (registry) -----

# Returns 0 when the `docker` CLI is talking to a *real* Docker engine
# (Docker Desktop / dockerd) rather than a podman daemon wearing a docker
# hat. On the latter, the `docker buildx` plugin is absent and
# DOCKER_BUILDKIT=0 doesn't help — `docker build` aborts with
# "BuildKit is enabled but the buildx component is missing".
#
# Heuristic: real Docker reports a 20+ server version on a Docker Desktop
# OS line; podman's docker-shim reports its podman version (e.g. 5.x) and
# the host distro (e.g. fedora). We probe both — anything that doesn't
# look unmistakably like Docker Engine is treated as a shim.
_docker_is_real_engine() {
  command -v docker >/dev/null 2>&1 || return 1
  docker info >/dev/null 2>&1 || return 1

  local server_ver os
  server_ver="$(docker info --format '{{.ServerVersion}}' 2>/dev/null || true)"
  os="$(docker info --format '{{.OperatingSystem}}' 2>/dev/null || true)"

  # Docker Desktop spells the OS line "Docker Desktop"; native dockerd
  # on Linux says e.g. "Ubuntu 22.04". Podman's shim says "fedora" (or
  # whatever distro the podman VM runs).
  case "$os" in
    *"Docker Desktop"*|*"Docker Engine"*) return 0 ;;
  esac

  # Fall back to version: real Docker is 18+ today; podman is 4.x/5.x.
  # A version starting with 18-29 plus an OS that doesn't look like a
  # podman VM distro is a reasonable "real docker" signal.
  case "$server_ver" in
    1[8-9].*|2[0-9].*|3[0-9].*) return 0 ;;
  esac
  return 1
}

# Default: build on the host's docker engine when it's a *real* Docker
# (Docker Desktop / dockerd) — that compile lands in a separate VM from
# kind so kubelet keeps its CPU/RAM. Otherwise use podman directly:
# either we don't have docker at all, or the `docker` CLI is a podman
# docker-shim that lacks buildx and would just fail with the BuildKit
# error. The save|load handoff in build_and_push handles cross-runtime
# pushes when needed.
#
# Override hierarchy:
#   1. SANDBOX_BUILD_RUNTIME / --build-runtime — explicit user choice.
#   2. real docker engine reachable            — host build, default.
#   3. podman                                  — everything else
#                                                (no Docker Desktop
#                                                required).
detect_builder() {
  if [[ -n "${SANDBOX_BUILD_RUNTIME:-}" ]]; then
    case "$SANDBOX_BUILD_RUNTIME" in
      podman)
        command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1 \
          || die "SANDBOX_BUILD_RUNTIME=podman but podman is not available"
        echo podman; return ;;
      docker)
        command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 \
          || die "SANDBOX_BUILD_RUNTIME=docker but docker daemon is not running"
        # Honour the user's explicit choice even when the CLI is a
        # podman shim — but warn so the BuildKit error isn't a surprise.
        if ! _docker_is_real_engine; then
          warn "SANDBOX_BUILD_RUNTIME=docker but the docker CLI is talking to podman (no real Docker engine detected)."
          warn "  buildx is unavailable on this shim — the build will likely fail with 'BuildKit is enabled but the buildx component is missing'."
          warn "  drop --build-runtime / unset SANDBOX_BUILD_RUNTIME to let sandboxctl pick podman directly."
        fi
        echo docker; return ;;
      *) die "SANDBOX_BUILD_RUNTIME must be 'podman' or 'docker', got '${SANDBOX_BUILD_RUNTIME}'" ;;
    esac
  fi
  if _docker_is_real_engine; then
    log "build runtime: docker (host engine, isolated from kind). Override with SANDBOX_BUILD_RUNTIME=podman." >&2
    echo docker; return
  fi
  if command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
    # Silent fall-through: this is the right default on a podman-only
    # box. Resource caps in build_and_push keep kind from starving.
    echo podman; return
  fi
  die "neither podman nor a usable docker engine is available — install podman ('sandboxctl setup-podman') to build images"
}

# Docker BuildKit needs the buildx CLI plugin. On hosts without Docker
# Desktop, buildx is often missing and `docker build` aborts with
# "BuildKit is enabled but the buildx component is missing". Falling back
# to the legacy builder via DOCKER_BUILDKIT=0 keeps builds working without
# pulling in Desktop. Caller-set DOCKER_BUILDKIT wins.
docker_build_env() {
  if [[ -n "${DOCKER_BUILDKIT-}" ]]; then return 0; fi
  if docker buildx version >/dev/null 2>&1; then return 0; fi
  warn "docker buildx not installed — falling back to legacy builder (DOCKER_BUILDKIT=0). Install buildx for faster builds: https://docs.docker.com/go/buildx/"
  export DOCKER_BUILDKIT=0
}

# Always podman: docker push from Docker Desktop's VM can't reach the
# Mac's gvproxy port-forward (different loopback) — the push hangs with
# layers stuck at "Waiting".
detect_pusher() {
  command -v podman >/dev/null 2>&1 && { echo podman; return; }
  die "podman is required for pushing — try 'sandboxctl setup-podman'"
}

# Delete the live manifest behind <repo>:<tag> in the in-cluster
# registry, if any. Used right before a push so the freshly-built
# manifest replaces the old one cleanly instead of leaving the prior
# digest as an orphaned blob (which would otherwise pile up on the
# registry PVC until `sandboxctl images gc`). Best-effort: any failure
# falls through and the push proceeds.
registry_drop_tag_if_present() {
  local image="$1"
  # Strip the host prefix to get <repo>:<tag>. We only manage tags that
  # live in OUR registry.
  case "$image" in
    "localhost:${SANDBOX_REGISTRY_PORT}/"*) ;;
    *) return 0 ;;
  esac
  local ref="${image#localhost:${SANDBOX_REGISTRY_PORT}/}"
  local repo="${ref%:*}" tag
  if [[ "$ref" == *:* ]]; then tag="${ref##*:}"; else tag="latest"; fi

  # Cheap reachability probe — if the registry isn't up we can't (and
  # shouldn't) try to delete; the upcoming push will surface the real
  # error.
  curl -sf --max-time 2 "http://localhost:${SANDBOX_REGISTRY_PORT}/v2/" >/dev/null 2>&1 || return 0

  local digest
  digest="$(registry_manifest_digest "$repo" "$tag" 2>/dev/null || true)"
  if [[ -n "$digest" ]]; then
    log "dropping previous ${repo}:${tag} (digest ${digest:0:19}...) before push"
    curl -s -X DELETE --max-time 5 \
      "http://localhost:${SANDBOX_REGISTRY_PORT}/v2/${repo}/manifests/${digest}" >/dev/null 2>&1 || true
    registry_filesystem_remove_tag "$repo" "$tag" >/dev/null 2>&1 || true
  fi
}

# registry_purge_repo_tags <repo>
#
# Wipe every tag of <repo> in our in-cluster registry. Used by
# --purge-old-tags so a fresh push leaves only the just-built tag behind
# instead of stacking new tags on top of every previous one (the case
# that quietly fills the registry PVC). Best-effort — failures fall
# through; the upcoming push will surface a real error if the registry
# is unreachable.
registry_purge_repo_tags() {
  local repo="$1"
  curl -sf --max-time 2 "http://localhost:${SANDBOX_REGISTRY_PORT}/v2/" >/dev/null 2>&1 || return 0
  local tags; tags="$(registry_tags "$repo" 2>/dev/null || true)"
  [[ -n "$tags" ]] || return 0
  log "purging existing tags of ${repo}: ${tags}"
  local t
  for t in $tags; do
    registry_images_rm "${repo}:${t}" >/dev/null 2>&1 || true
  done
}

# build_and_push <image> <dockerfile> <context> [extra build args]
build_and_push() {
  local image="$1" dockerfile="$2" context="$3"; shift 3
  local builder pusher
  builder="$(detect_builder)"
  pusher="$(detect_pusher)"

  # Build resource caps. Flag spelling differs across runtimes/frontends:
  #   podman build  : --cpuset-cpus 0-(N-1) , --memory <SIZE>
  #   docker build  : legacy builder rejects --cpus/--memory; BuildKit
  #                   doesn't expose them either. We skip caps for
  #                   docker — its daemon runs in a separate VM from
  #                   kind, so the starvation problem doesn't apply.
  # Resolve "auto" to half-the-VM caps that leave kind a working set.
  # Empty / 0 disables capping entirely (opt-out).
  local effective_cpus="${SANDBOX_BUILD_CPUS:-}"
  local effective_memory="${SANDBOX_BUILD_MEMORY:-}"
  if [[ "$builder" == "podman" ]]; then
    if [[ "$effective_cpus" == "auto" ]]; then
      local _vm_cpus _half
      _vm_cpus="$(podman machine inspect --format '{{.Resources.CPUs}}' 2>/dev/null || echo "")"
      if [[ "$_vm_cpus" =~ ^[0-9]+$ ]] && (( _vm_cpus >= 2 )); then
        _half=$(( _vm_cpus / 2 ))
        (( _half < 1 )) && _half=1
        effective_cpus="$_half"
      else
        effective_cpus=""
      fi
    fi
    if [[ "$effective_memory" == "auto" ]]; then
      local _vm_mem_str _vm_mem_mib _half_mib
      # podman reports memory as "8GiB" / "8192" depending on version
      _vm_mem_str="$(podman machine inspect --format '{{.Resources.Memory}}' 2>/dev/null || echo "")"
      _vm_mem_mib="$(_normalize_mem_to_mib "$_vm_mem_str" 2>/dev/null || echo "")"
      if [[ "$_vm_mem_mib" =~ ^[0-9]+$ ]] && (( _vm_mem_mib >= 2048 )); then
        _half_mib=$(( _vm_mem_mib / 2 ))
        effective_memory="${_half_mib}m"
      else
        effective_memory=""
      fi
    fi
  else
    # docker builder: caps don't apply
    if [[ "$effective_cpus"   == "auto" ]]; then effective_cpus=""; fi
    if [[ "$effective_memory" == "auto" ]]; then effective_memory=""; fi
    if [[ -n "$effective_cpus" || -n "$effective_memory" ]]; then
      log "build runtime is docker; --build-cpus/--build-memory ignored (docker runs in its own VM, isolated from kind)"
      effective_cpus=""
      effective_memory=""
    fi
  fi

  local resource_args=()
  if [[ "$builder" == "podman" ]]; then
    if [[ -n "$effective_cpus" && "$effective_cpus" != "0" ]]; then
      local _last=$(( effective_cpus - 1 ))
      (( _last < 0 )) && _last=0
      resource_args+=(--cpuset-cpus "0-${_last}")
    fi
    if [[ -n "$effective_memory" && "$effective_memory" != "0" ]]; then
      resource_args+=(--memory "$effective_memory")
    fi
  fi

  local _log_cpus="" _log_mem=""
  [[ -n "$effective_cpus"   && "$effective_cpus"   != "0" ]] && _log_cpus=", cpus=${effective_cpus}"
  [[ -n "$effective_memory" && "$effective_memory" != "0" ]] && _log_mem=", memory=${effective_memory}"
  log "building ${image}  (context: ${context}, builder: ${builder}${_log_cpus}${_log_mem})"
  if [[ "$builder" == "docker" ]]; then docker_build_env; fi
  "$builder" build ${resource_args[@]+"${resource_args[@]}"} -t "$image" "$@" -f "$dockerfile" "$context" || \
    die "build failed for ${image}"

  # docker save | podman load is the universal handoff — `podman pull
  # docker-daemon:` needs daemon-socket access podman's VM doesn't have.
  if [[ "$builder" != "$pusher" ]]; then
    log "transferring ${image} from ${builder} to ${pusher} for push"
    "$builder" save "$image" 2>/dev/null | "$pusher" load 2>&1 | tail -3 || \
      die "could not transfer ${image} from ${builder} to ${pusher}"
  fi

  if [[ "${BUILD_PURGE_OLD_TAGS:-0}" == "1" ]]; then
    case "$image" in
      "localhost:${SANDBOX_REGISTRY_PORT}/"*)
        local _ref="${image#localhost:${SANDBOX_REGISTRY_PORT}/}"
        registry_purge_repo_tags "${_ref%:*}"
        ;;
    esac
  fi

  registry_drop_tag_if_present "$image"

  log "pushing ${image}  (pusher: ${pusher})"
  "$pusher" push --tls-verify=false "$image" || die "push failed for ${image}"
  ok "${image}"
}

# slugify an arbitrary path component into a docker-image-name-safe form.
slugify() {
  printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed 's/^-*//;s/-*$//'
}

cmd_build() {
  # Manifest precedence:
  #   1. existing sandboxctl.yaml/.yml at <target> or cwd → use as-is
  #   2. no manifest but Dockerfile(s) exist → auto-generate one at
  #      <target>/sandboxctl.yaml (parses each Dockerfile's COPY/ADD
  #      sources and walks up to the smallest ancestor that resolves
  #      them all — fixes the "go.sum: not found" class of build
  #      failure where the Dockerfile lives nested but reads from the
  #      repo root). The generated file is committed-friendly with a
  #      header comment, so it lands in `git status` and can be edited.
  #   3. no Dockerfiles at all → fall through to the legacy auto-walk
  #      (which dies with a clear "no Dockerfile found" message).
  local repo_flag="" positional="" tag="latest"
  local purge_old_tags="${SANDBOX_BUILD_PURGE_OLD_TAGS:-0}"
  local opt_build_cpus="${SANDBOX_BUILD_CPUS:-}"
  local opt_build_memory="${SANDBOX_BUILD_MEMORY:-}"
  local opt_build_runtime="${SANDBOX_BUILD_RUNTIME:-}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo_flag="${2:-}"; shift 2 ;;
      --purge-old-tags) purge_old_tags=1; shift ;;
      --no-purge-old-tags) purge_old_tags=0; shift ;;
      --build-cpus) opt_build_cpus="${2:-}"; shift 2 ;;
      --build-memory) opt_build_memory="${2:-}"; shift 2 ;;
      --build-runtime) opt_build_runtime="${2:-}"; shift 2 ;;
      --on-host)
        # Convenience: pin to the host's docker daemon (Docker Desktop)
        # explicitly. Resource caps don't apply to docker (its daemon
        # already lives in its own VM, isolated from the Podman VM that
        # hosts kind), so we just set the runtime.
        opt_build_runtime="docker" ; shift ;;
      -h|--help)
        cat <<EOF
sandboxctl build [path] [--repo <dir>] [--purge-old-tags]
                         [--build-cpus N] [--build-memory SIZE]
                         [--build-runtime podman|docker] [--on-host]

Find Dockerfiles under the product repo, build them, and push to the
in-cluster registry. The product repo can be specified by:
  --repo <dir>   explicit pointer to the repo root
  [path]         positional form of the same
  (default)      current working directory

Build precedence inside the repo:
  1. existing sandboxctl.yaml/.yml — used as-is
  2. Dockerfiles only              — auto-generates sandboxctl.yaml

Resource caps (only meaningful for the podman runtime):
  --build-cpus N         pin the podman build to N cores (--cpuset-cpus
                         0..N-1). Default: half the Podman VM's CPUs so
                         kind keeps headroom during a hot compile. Pass
                         0 to disable. SANDBOX_BUILD_CPUS env equivalent.
                         Ignored when building with docker — its daemon
                         already runs in a separate VM from kind.
  --build-memory SIZE    cap the podman build's RAM (e.g. '4g',
                         '1500m'). Default: half the Podman VM's RAM.
                         Pass 0 to disable. SANDBOX_BUILD_MEMORY env
                         equivalent. Same docker-runtime caveat applies.
  --build-runtime R      pick 'podman' or 'docker'. Default: docker
                         when its daemon is reachable, else podman.
                         Note: on a podman-only host where 'docker' is
                         the podman CLI in disguise, both runtimes land
                         in the same VM and caps still matter.
                         SANDBOX_BUILD_RUNTIME env equivalent.
  --on-host              shorthand for '--build-runtime docker'.

Tag retention:
  --purge-old-tags     Before each push, delete every existing tag of the
                       repo being built and run a registry GC at the end,
                       so the registry only ever holds the just-pushed tag
                       per image. Useful when iterating with content-
                       addressed tags (sha-<commit>) that would otherwise
                       stack up on the PVC. Same effect as setting
                       SANDBOX_BUILD_PURGE_OLD_TAGS=1 in the environment.
EOF
        return 0 ;;
      -*) die "build: unknown flag: $1" ;;
      *)
        if [[ -z "$positional" ]]; then positional="$1"; shift
        elif [[ "$tag" == "latest" ]]; then tag="$1"; shift
        else die "build: unexpected argument: $1"
        fi ;;
    esac
  done

  if [[ -n "$opt_build_runtime" && "$opt_build_runtime" != "podman" && "$opt_build_runtime" != "docker" ]]; then
    die "build: --build-runtime must be 'podman' or 'docker', got '${opt_build_runtime}'"
  fi
  # "auto" / "0" / empty are sentinels handled by build_and_push.
  if [[ -n "$opt_build_cpus" && "$opt_build_cpus" != "auto" && "$opt_build_cpus" != "0" \
        && ! "$opt_build_cpus" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    die "build: --build-cpus must be a number (e.g. 2 or 1.5), 'auto', or '0' to disable; got '${opt_build_cpus}'"
  fi
  if [[ -n "$opt_build_memory" && "$opt_build_memory" != "auto" && "$opt_build_memory" != "0" \
        && ! "$opt_build_memory" =~ ^[0-9]+([bkmg])?$ ]]; then
    die "build: --build-memory must look like '4g' / '1500m' / '512m', 'auto', or '0' to disable; got '${opt_build_memory}'"
  fi

  local target
  target="$(_resolve_product_repo "$repo_flag" "$positional" build)" || return 1

  _ensure_registry_reachable

  export BUILD_PURGE_OLD_TAGS="$purge_old_tags"
  export SANDBOX_BUILD_CPUS="$opt_build_cpus"
  export SANDBOX_BUILD_MEMORY="$opt_build_memory"
  export SANDBOX_BUILD_RUNTIME="$opt_build_runtime"

  local manifest=""
  for candidate in "${target}/sandboxctl.yaml" "${target}/sandboxctl.yml" "$(pwd)/sandboxctl.yaml"; do
    [[ -f "$candidate" ]] && { manifest="$candidate"; break; }
  done

  if [[ -z "$manifest" ]]; then
    # Any Dockerfiles to autogen from? Use the same exclusions the
    # legacy walker uses so coverage matches.
    if find "$target" -type f -name Dockerfile \
        -not -path '*/node_modules/*' \
        -not -path '*/vendor/*' \
        -not -path '*/dist/*' \
        -not -path '*/.git/*' -print -quit 2>/dev/null | grep -q .; then
      local sandboxctl_bin
      sandboxctl_bin="$(command -v sandboxctl 2>/dev/null || true)"
      if [[ -n "$sandboxctl_bin" ]]; then
        log "no sandboxctl.yaml under ${target} — auto-generating from Dockerfiles"
        if manifest="$("$sandboxctl_bin" _autogen-manifest "$target")"; then
          log "wrote $manifest"
        else
          warn "auto-generation failed — falling back to legacy auto-walk"
          manifest=""
        fi
      else
        warn "sandboxctl binary not on PATH — cannot auto-generate manifest, using legacy auto-walk"
      fi
    fi
  fi

  if [[ -n "$manifest" ]]; then
    cmd_build_from_manifest "$manifest"
  else
    cmd_build_auto_walk "$target" "$tag"
  fi

  # When purge-old-tags ran during the push loop we marked old manifests
  # for deletion but the blobs they referenced still occupy the PVC
  # until the registry's GC sweeps them. Run gc once at the end so disk
  # usage stays flat across repeated builds (the whole point of the flag).
  if [[ "${BUILD_PURGE_OLD_TAGS:-0}" == "1" ]]; then
    log "running registry gc to reclaim blobs from purged tags"
    registry_images_gc || warn "registry gc failed — see output above"
  fi
}

cmd_build_auto_walk() {
  local target="$1" tag="$2"
  log "scanning ${target} for Dockerfiles (no sandboxctl.yaml found — using auto-walk)"
  local dockerfiles=()
  while IFS= read -r df; do
    dockerfiles+=("$df")
  done < <(
    find "$target" -type f -name Dockerfile \
      -not -path '*/node_modules/*' \
      -not -path '*/vendor/*' \
      -not -path '*/dist/*' \
      -not -path '*/.git/*' 2>/dev/null
  )
  if [[ ${#dockerfiles[@]} -eq 0 ]]; then
    die "no Dockerfile found under '${target}'"
  fi
  log "found ${#dockerfiles[@]} Dockerfile(s)"

  local df ctx name image
  for df in "${dockerfiles[@]}"; do
    ctx="$(dirname "$df")"
    name="$(slugify "$(basename "$(cd "$ctx" && pwd)")")"
    [[ -n "$name" ]] || name="image"
    image="localhost:${SANDBOX_REGISTRY_PORT}/${name}:${tag}"
    build_and_push "$image" "$df" "$ctx"
  done

  echo
  echo "Use these images in your Deployments:"
  for df in "${dockerfiles[@]}"; do
    name="$(slugify "$(basename "$(cd "$(dirname "$df")" && pwd)")")"
    [[ -n "$name" ]] || name="image"
    echo "  image: localhost:${SANDBOX_REGISTRY_PORT}/${name}:${tag}"
  done
}

cmd_build_from_manifest() {
  # YAML order IS the build order. depends_on validates the named dep
  # was built earlier in the file (no topo sort). Schema lives in README.
  local manifest="$1"
  local sandboxctl_bin
  sandboxctl_bin="$(command -v sandboxctl 2>/dev/null || true)"
  [[ -n "$sandboxctl_bin" ]] || die "sandboxctl binary not on PATH"

  log "building from $manifest"
  local entries
  entries="$("$sandboxctl_bin" _parse-build-manifest "$manifest")" || \
    die "failed to parse $manifest"

  if [[ -z "$entries" ]]; then
    die "no images parsed from $manifest (check the file format)"
  fi

  # Resolve paths relative to the manifest's directory.
  local manifest_dir; manifest_dir="$(cd "$(dirname "$manifest")" && pwd)"
  local built=()    # names of images we've already built (for depends_on check)

  while IFS=$'\t' read -r name ctx df tag aliases deps; do
    [[ -n "$name" ]] || continue
    local abs_ctx="${manifest_dir}/${ctx}"
    [[ "$ctx" == /* ]] && abs_ctx="$ctx"
    local abs_df="${manifest_dir}/${df}"
    [[ "$df" == /* ]] && abs_df="$df"

    # Validate depends_on: every dep must already be in $built.
    if [[ -n "$deps" ]]; then
      local dep
      for dep in ${deps//,/ }; do
        if [[ " ${built[*]:-} " != *" $dep "* ]]; then
          die "image '$name' depends_on '$dep' but '$dep' wasn't built earlier in $manifest"
        fi
      done
    fi

    local image="localhost:${SANDBOX_REGISTRY_PORT}/${name}:${tag}"
    # Aliases become extra -t flags so downstream Dockerfiles' FROMs
    # (e.g. `FROM my-base:latest`) resolve to the freshly-built image.
    local extra_tags=()
    if [[ -n "$aliases" ]]; then
      local alias
      for alias in ${aliases//,/ }; do
        extra_tags+=(-t "$alias")
      done
    fi

    # Bash 3.2 (macOS system bash) trips `set -u` on `"${arr[@]}"` when
    # the array is empty; the `${arr[@]+...}` guard expands to nothing
    # in that case and to the elements otherwise.
    build_and_push "$image" "$abs_df" "$abs_ctx" ${extra_tags[@]+"${extra_tags[@]}"}
    built+=("$name")
  done <<< "$entries"

  echo
  echo "Built and pushed ${#built[@]} image(s):"
  local n
  for n in "${built[@]}"; do
    echo "  image: localhost:${SANDBOX_REGISTRY_PORT}/${n}:latest    (or override per Deployment)"
  done
}

cmd_images() {
  # list / rm <ref> / prune / purge / gc — see usage block.
  # `purge` is an alias for `prune` (delete every image then GC) — same
  # behaviour, different name for users who came from podman/docker
  # where "prune" only sweeps dangling images.
  local sub="${1:-list}"; shift || true
  case "$sub" in
    list|"")        registry_images_list ;;
    rm)             [[ $# -ge 1 ]] || die "usage: sandboxctl images rm <image>[:tag]"
                    registry_images_rm "$1"; registry_images_gc ;;
    prune|purge)    registry_images_prune; registry_images_gc ;;
    gc)             registry_images_gc ;;
    *)              die "unknown 'images' subcommand: $sub (use list, rm, prune, purge, gc)" ;;
  esac
}

registry_must_be_reachable() {
  _ensure_registry_reachable
}

registry_repos() {
  curl -s --max-time 5 "http://localhost:${SANDBOX_REGISTRY_PORT}/v2/_catalog" 2>/dev/null \
    | python3 -c 'import sys, json; d=json.load(sys.stdin); print(" ".join(d.get("repositories") or []))' \
      2>/dev/null || true
}

registry_tags() {
  local repo="$1"
  curl -s --max-time 5 "http://localhost:${SANDBOX_REGISTRY_PORT}/v2/${repo}/tags/list" 2>/dev/null \
    | python3 -c 'import sys, json; d=json.load(sys.stdin); print(" ".join(d.get("tags") or []))' \
      2>/dev/null || true
}

registry_manifest_digest() {
  # Accept covers all four manifest types: Docker v2, OCI v1,
  # Docker manifest list, OCI image index. Empty return = caller decides.
  local repo="$1" tag="$2"
  curl -s -I --max-time 5 \
    -H 'Accept: application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.index.v1+json' \
    "http://localhost:${SANDBOX_REGISTRY_PORT}/v2/${repo}/manifests/${tag}" \
    2>/dev/null | awk -v IGNORECASE=1 '/^docker-content-digest:/ {print $2}' | tr -d '\r' | head -1 || true
}

# Fallback when the manifest blob has been GC'd but the tag→manifest
# link still exists (registry tag listing claims the tag is present
# while /manifests/<tag> 404s). Removes the link directly via kubectl.
registry_filesystem_remove_tag() {
  local repo="$1" tag="$2"
  local pod
  pod="$(kc -n "$REGISTRY_NS" get pod -l app=registry \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$pod" ]] || return 1
  kc -n "$REGISTRY_NS" exec "$pod" -- \
    rm -rf "/var/lib/registry/docker/registry/v2/repositories/${repo}/_manifests/tags/${tag}" \
    >/dev/null 2>&1
}

registry_images_list() {
  registry_must_be_reachable
  local repos; repos="$(registry_repos)"
  if [[ -z "$repos" ]]; then
    echo "no images pushed yet — try: sandboxctl build"
    return 0
  fi
  printf '%-40s  %s\n' "IMAGE" "TAGS"
  local repo
  for repo in $repos; do
    local tags; tags="$(registry_tags "$repo")"
    printf '%-40s  %s\n' "$repo" "${tags:-<none>}"
  done
}

registry_images_rm() {
  registry_must_be_reachable
  local ref="$1" repo tag
  if [[ "$ref" == *:* ]]; then
    repo="${ref%:*}"; tag="${ref##*:}"
  else
    repo="$ref"; tag=""
  fi

  if [[ -n "$tag" ]]; then
    log "deleting ${repo}:${tag}"
    local digest; digest="$(registry_manifest_digest "$repo" "$tag")"
    if [[ -n "$digest" ]]; then
      curl -s -X DELETE --max-time 5 \
        "http://localhost:${SANDBOX_REGISTRY_PORT}/v2/${repo}/manifests/${digest}" >/dev/null
      # Also remove the tag's link file. The DELETE above clears the
      # manifest blob but the registry's tag→manifest symlink may still
      # be listed by /tags/list until restarted (registry caches the
      # tag listing in memory).
      registry_filesystem_remove_tag "$repo" "$tag" || true
      ok "deleted ${repo}:${tag} (digest ${digest:0:19}...)"
    else
      # Manifest is already gone (orphaned tag link) — clean up the FS.
      if registry_filesystem_remove_tag "$repo" "$tag"; then
        ok "deleted orphaned tag ${repo}:${tag} (manifest was already GC'd)"
      else
        die "manifest not found for ${repo}:${tag} and could not access registry pod to clean tag link"
      fi
    fi
  else
    log "deleting all tags of ${repo}"
    local tags; tags="$(registry_tags "$repo")"
    [[ -n "$tags" ]] || { warn "no tags found for ${repo}"; return 0; }
    local t
    for t in $tags; do
      registry_images_rm "${repo}:${t}"
    done
  fi
}

registry_images_prune() {
  registry_must_be_reachable
  local repos; repos="$(registry_repos)"
  if [[ -z "$repos" ]]; then
    ok "registry already empty"
    return 0
  fi
  log "deleting all images (pruning the registry)"
  local repo
  for repo in $repos; do
    registry_images_rm "$repo"
  done
}

registry_images_gc() {
  # DELETE only marks blobs; the registry's built-in GC reclaims disk.
  # Bounce the pod afterwards to flush its in-memory tag cache.
  require_running_cluster
  local pod
  pod="$(kc -n "$REGISTRY_NS" get pod -l app=registry \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$pod" ]] || die "no registry pod found in ${REGISTRY_NS}"

  log "running garbage-collector inside the registry pod"
  local before after
  before="$(kc -n "$REGISTRY_NS" exec "$pod" -- du -sh /var/lib/registry 2>/dev/null | awk '{print $1}' || echo unknown)"
  kc -n "$REGISTRY_NS" exec "$pod" -- \
    registry garbage-collect -m /etc/docker/registry/config.yml 2>&1 | sed 's/^/    /'
  after="$(kc -n "$REGISTRY_NS" exec "$pod" -- du -sh /var/lib/registry 2>/dev/null | awk '{print $1}' || echo unknown)"
  ok "registry GC complete  (storage: ${before} → ${after})"

  log "restarting the registry pod so it picks up the cleaned filesystem"
  kc -n "$REGISTRY_NS" rollout restart deploy/registry >/dev/null
  kc -n "$REGISTRY_NS" rollout status  deploy/registry --timeout=60s >/dev/null
  ok "registry restarted"
}

# ============================================================================
# Deploy / undeploy (Argo-managed apps with auto-routed sandbox.app URLs)
# ============================================================================

# Walk <target> for every Helm chart and every directory of rendered
# manifests. Emits one tab-separated entry per discovered app:
#
#   <kind>\t<chart-name>\t<absolute-source-dir>\t<values-file>
#
# kind is "helm" (Chart.yaml present) or "directory" (rendered manifests).
# values-file is empty for "directory" entries; for helm entries it's a
# filename relative to the chart dir, picked from a fixed preference
# list (see _emit_chart_entry below).
#
# chart-name comes from Chart.yaml's `name:` field for helm entries, or
# from the directory basename for "directory" entries. That name becomes
# the Argo Application name and the routed hostname's left-half.
#
# Discovery scope (in <target>, recursive within reasonable depth):
#   1. <target>/chart/Chart.yaml             — single in-repo chart
#   2. <target>/helm/Chart.yaml              — single in-repo chart
#   3. <target>/charts/<svc>/Chart.yaml      — multi-service repo
#   4. Any other Chart.yaml within depth 5   — catch-alls (e.g.
#                                              manifests/<svc>/chart/)
#   5. <target>/deploy/, <target>/k8s/       — rendered manifests
#                                              (only when no chart was
#                                              found above)
#
# Callers can bypass discovery entirely by passing --chart and
# --values to cmd_deploy.
discover_app_charts() {
  local target="$1"
  local found=0

  # Pull every Chart.yaml under <target> within a sane depth. find's
  # -prune skips the heavy directories (vendor, node_modules, .git,
  # dist) so we don't walk through huge dependency trees.
  local chart_yml seen_dirs=""
  while IFS= read -r chart_yml; do
    [[ -n "$chart_yml" ]] || continue
    # De-dupe in case multiple finds catch the same dir.
    case ":$seen_dirs:" in *":$(dirname "$chart_yml"):"*) continue ;; esac
    seen_dirs="${seen_dirs}:$(dirname "$chart_yml")"
    _emit_chart_entry "$chart_yml" || continue
    found=1
  done < <(
    find "$target" -maxdepth 5 -type d \
        \( -name node_modules -o -name vendor -o -name dist -o -name .git \) -prune \
      -o -type f -name Chart.yaml -print 2>/dev/null
  )

  # Rendered-manifest dirs at the repo root. Only emit if no chart was
  # discovered (Helm wins) — chart + raw manifests in the same repo
  # would otherwise double-deploy the same workload.
  if (( found == 0 )); then
    local p base
    base="$(basename "$target")"
    for p in deploy k8s; do
      [[ -d "${target}/${p}" ]] && {
        printf 'directory\t%s\t%s\t\n' "$base" "${target}/${p}"
        found=1
        break
      }
    done
  fi

  (( found > 0 )) || return 1
  return 0
}

# Emit one helm row to stdout for the chart whose Chart.yaml is at $1.
# Resolves the chart's `name:` field and picks the best values file.
# Returns non-zero (and emits nothing) if the chart name is unreadable.
_emit_chart_entry() {
  local chart_yml="$1"
  local chart_dir name values=""
  chart_dir="$(cd "$(dirname "$chart_yml")" && pwd)"

  # Chart names tend to be a single token on a `name:` line — a
  # one-pass sed is enough; no need for a yaml parser here.
  name="$(sed -nE 's/^name:[[:space:]]*"?([^" ]+).*/\1/p' "$chart_yml" | head -n1)"
  [[ -n "$name" ]] || return 1

  values="$(_pick_sandbox_values_file "$chart_dir")"

  printf 'helm\t%s\t%s\t%s\n' "$name" "$chart_dir" "$values"
}

# Pick the first sandbox-flavour values file that already exists in a
# chart directory. Returns the filename (no path) on stdout, empty when
# none is present. The four names are checked in priority order so the
# CLI can adapt to whatever convention the chart author already uses
# without forcing them to rename anything:
#
#   1. sandbox-values.yaml   — favoured by Bitnami-style "sandbox first"
#   2. values-sandbox.yaml   — sandboxctl's historical default
#   3. sandbox.yaml          — short form some charts ship
#   4. values-local.yaml     — pre-sandboxctl convention; kept for back-compat
#
# Order is "most-specific first" so a chart that ships every variant
# gets the one most clearly authored for sandboxctl. If you want to
# add a fifth name, append it to this list — the deploy path picks up
# the change automatically.
_pick_sandbox_values_file() {
  local chart_dir="$1" name
  for name in sandbox-values.yaml values-sandbox.yaml sandbox.yaml values-local.yaml; do
    [[ -f "${chart_dir}/${name}" ]] && { printf '%s' "$name"; return 0; }
  done
  printf ''
}

# Emit a discover_app_charts-style entry for a single chart that the
# caller pointed at explicitly (via --chart, the k8s/chart convention,
# or the interactive prompt). Args:
#   $1 target dir (relative paths in $2 resolve here)
#   $2 chart path (absolute or relative to $1)
#   $3 values-file override ("" = pick best)
#   $4 chart-name override   ("" = read from Chart.yaml)
_emit_explicit_chart_entry() {
  local target="$1" chart_in="$2" values_in="$3" name_in="$4"
  local chart_dir
  if [[ "$chart_in" == /* ]]; then
    chart_dir="$chart_in"
  else
    chart_dir="${target}/${chart_in}"
  fi
  [[ -d "$chart_dir" ]] || die "chart directory not found: $chart_dir"
  chart_dir="$(cd "$chart_dir" && pwd)"
  [[ -f "${chart_dir}/Chart.yaml" ]] || die "no Chart.yaml in $chart_dir"

  local cname
  if [[ -n "$name_in" ]]; then
    cname="$name_in"
  else
    cname="$(sed -nE 's/^name:[[:space:]]*"?([^" ]+).*/\1/p' "${chart_dir}/Chart.yaml" | head -n1)"
    [[ -n "$cname" ]] || die "Chart.yaml at ${chart_dir} has no readable name; pass --name to override"
  fi

  local vfile=""
  if [[ -n "$values_in" ]]; then
    [[ -f "${chart_dir}/${values_in}" ]] || die "values file not found in chart: ${values_in}"
    vfile="$values_in"
  else
    vfile="$(_pick_sandbox_values_file "$chart_dir")"
  fi

  printf 'helm\t%s\t%s\t%s\n' "$cname" "$chart_dir" "$vfile"
}

ensure_secrets_for_namespace() {
  # If $target/k8s/secrets.yaml exists, apply it into $namespace.
  # If only secrets.example.yaml exists, copy → secrets.yaml, ensure
  # gitignore, prompt the user to fill it, then apply on Enter.
  local target="$1" namespace="$2"
  local k8s_dir="${target}/k8s"
  local secrets="${k8s_dir}/secrets.yaml"
  local example="${k8s_dir}/secrets.example.yaml"

  if [[ ! -d "$k8s_dir" ]]; then
    log "no k8s/ directory in ${target} — skipping secret management"
    return 0
  fi

  if [[ ! -f "$secrets" ]]; then
    [[ -f "$example" ]] || { warn "no k8s/secrets.yaml or k8s/secrets.example.yaml — skipping secret management"; return 0; }
    log "creating k8s/secrets.yaml from k8s/secrets.example.yaml"
    cp "$example" "$secrets"
    ensure_gitignore_entry "$target" "k8s/secrets.yaml"
    cat <<EOF

  k8s/secrets.yaml has been created from the example. Edit it now and
  set base64-encoded values for each key. To encode a value:

      echo -n 'your-secret' | base64

  Press Enter when you have finished editing the file (Ctrl+C to abort)…
EOF
    read -r _
  fi

  # Validate: refuse to apply if any obvious placeholder is left. Two
  # generations of template exist: hand-written examples used
  # <base64-encoded-*>; scaffold-generated ones use <required — …>
  # (stringData, filled in plain text).
  if grep -qE '<(base64-encoded-[a-z-]+|required[^>]*)>' "$secrets" 2>/dev/null; then
    die "k8s/secrets.yaml still contains unfilled placeholders (grep for '<required' or '<base64-encoded') — fill them in and re-run"
  fi

  log "applying k8s/secrets.yaml into namespace ${namespace}"
  kc create namespace "$namespace" --dry-run=client -o yaml | kc apply -f - >/dev/null
  # Force the namespace from the manifest to whatever we resolved (so a
  # secrets.yaml that hard-codes `namespace: <app>` still lands in
  # `<app>-staging` when the caller passed --env=staging).
  sed -E "s|^([[:space:]]*namespace:[[:space:]]*).*$|\1${namespace}|" "$secrets" \
    | kc apply -f - >/dev/null
  ok "secrets applied"
}

ensure_gitignore_entry() {
  local target="$1" entry="$2"
  local gi="${target}/.gitignore"
  if [[ ! -f "$gi" ]] || ! grep -qxF "$entry" "$gi"; then
    log "adding ${entry} to ${gi}"
    echo "$entry" >> "$gi"
  fi
}

# Compute the namespace + hostname for an app/env pair.
deploy_namespace_for() {
  local app="$1" env="$2"
  if [[ "$env" == "dev" ]]; then echo "$app"
  else echo "${app}-${env}"
  fi
}
deploy_hostname_for() {
  # Hostname is per-app (not per-env). The env still differentiates the
  # destination namespace via deploy_namespace_for, so dev/staging
  # don't collide on the cluster — but the URL stays stable, which is
  # what users actually want for browser bookmarks. Override at the
  # call site only when truly needed (no caller does today).
  local app="$1"
  echo "${app}.${SANDBOX_DOMAIN}"
}

# Add a VirtualService routing $hostname:$SANDBOX_HTTPS_PORT to the
# given Service in the given namespace. Idempotent.
add_app_route() {
  local hostname="$1" namespace="$2" svc_host="$3" svc_port="$4"
  local vs_name="sandboxctl-${hostname//./-}"
  log "adding Istio route ${hostname} → ${svc_host}:${svc_port}"
  kc apply -f - <<EOF >/dev/null
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata: { name: ${vs_name}, namespace: ${namespace} }
spec:
  hosts: ["${hostname}"]
  gateways: ["${ISTIO_INGRESS_NS}/sandbox-gateway"]
  http:
    - route: [{ destination: { host: ${svc_host}.${namespace}.svc.cluster.local, port: { number: ${svc_port} } } }]
EOF
}

remove_app_route() {
  local hostname="$1" namespace="$2"
  local vs_name="sandboxctl-${hostname//./-}"
  kc -n "$namespace" delete virtualservice "$vs_name" --ignore-not-found >/dev/null 2>&1 || true
}

# Add (or remove) a hostname to the sandboxctl-managed /etc/hosts line.
add_app_host() {
  local hostname="$1"
  if grep -qE "^[[:space:]]*127\.0\.0\.1[[:space:]].*\b${hostname}\b" /etc/hosts; then
    return 0
  fi
  prime_sudo
  local tmp; tmp="$(mktemp -t sandbox-hosts.XXXXXX)"

  # Rewrite via pure-bash string ops — never feed awk/sed a regex
  # built from $SANDBOX_HOSTS_MARKER, which contains parentheses
  # (e.g. "# managed by sandboxctl (sandbox.app)"). macOS BSD awk
  # treats `(...)` in `sub`'s pattern as an ERE group, so the prior
  # implementation silently no-op'd on every Mac and the deploy log
  # said "OK: /etc/hosts: …" while the file was untouched.
  #
  # The shape we maintain on the marker line is:
  #   127.0.0.1\t<host1> <host2> …\t# managed by sandboxctl (<domain>)
  # We splice <new-host> in just before the marker, separated by a
  # single space — matching cmd_up's install_hosts output.
  if grep -qF "$SANDBOX_HOSTS_MARKER" /etc/hosts; then
    local replaced=0 line prefix suffix
    while IFS= read -r line || [[ -n "$line" ]]; do
      if (( replaced == 0 )) && [[ "$line" == *"$SANDBOX_HOSTS_MARKER"* && "$line" != *"$hostname"* ]]; then
        # Bash parameter expansion: split the line on the marker.
        prefix="${line%%"$SANDBOX_HOSTS_MARKER"*}"
        suffix="${SANDBOX_HOSTS_MARKER}${line##*"$SANDBOX_HOSTS_MARKER"}"
        # `prefix` ends with whitespace before the marker — strip a
        # single trailing tab/space, append " <hostname>", then a tab
        # before the marker so the columns stay aligned.
        prefix="${prefix%[[:space:]]}"
        printf '%s %s\t%s\n' "$prefix" "$hostname" "$suffix" >> "$tmp"
        replaced=1
      else
        printf '%s\n' "$line" >> "$tmp"
      fi
    done < /etc/hosts
    if (( replaced == 0 )); then
      # Marker line didn't match the splice (e.g. odd whitespace) —
      # fall back to appending a fresh line so we never silently no-op.
      printf '127.0.0.1\t%s\t%s\n' "$hostname" "$SANDBOX_HOSTS_MARKER" >> "$tmp"
    fi
  else
    cp /etc/hosts "$tmp"
    printf '127.0.0.1\t%s\t%s\n' "$hostname" "$SANDBOX_HOSTS_MARKER" >> "$tmp"
  fi

  # Sanity-check we actually wrote the host before swapping /etc/hosts.
  # Without this, an unforeseen edge in the splice would still print
  # "OK" while leaving the system file unchanged.
  if ! grep -qE "^[[:space:]]*127\.0\.0\.1[[:space:]].*\b${hostname}\b" "$tmp"; then
    rm -f "$tmp"
    die "internal: failed to splice ${hostname} into /etc/hosts (marker shape unexpected — please file a bug)"
  fi

  if ! sudo install -m 0644 "$tmp" /etc/hosts 2>/dev/null; then
    rm -f "$tmp"
    die "failed to write /etc/hosts (sudo) — re-run from an interactive terminal so sudo can prompt"
  fi
  rm -f "$tmp"

  # macOS caches name lookups (including misses) for several seconds.
  # Flush it so the new entry resolves immediately — without this, the
  # browser keeps showing ERR_NAME_NOT_RESOLVED for a noticeable
  # window after the deploy says "OK".
  sudo dscacheutil -flushcache 2>/dev/null || true
  sudo killall -HUP mDNSResponder 2>/dev/null || true

  ok "/etc/hosts: ${hostname} → 127.0.0.1"
}

remove_app_host() {
  local hostname="$1"
  if ! grep -qE "^[[:space:]]*127\.0\.0\.1[[:space:]].*\b${hostname}\b" /etc/hosts; then
    return 0
  fi
  prime_sudo
  local tmp; tmp="$(mktemp -t sandbox-hosts.XXXXXX)"

  # Pure-bash splice for the same reason as add_app_host: avoid sed's
  # regex on a hostname that may contain dots (which match anything in
  # ERE). We strip exactly the literal " ${hostname}" token, leaving
  # the rest of the marker line intact.
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == *"$SANDBOX_HOSTS_MARKER"* && "$line" == *" ${hostname} "* ]]; then
      line="${line/ ${hostname} / }"
    elif [[ "$line" == *"$SANDBOX_HOSTS_MARKER"* && "$line" == *" ${hostname}"$'\t'* ]]; then
      line="${line/ ${hostname}/}"
    fi
    printf '%s\n' "$line" >> "$tmp"
  done < /etc/hosts

  if ! sudo install -m 0644 "$tmp" /etc/hosts 2>/dev/null; then
    rm -f "$tmp"
    warn "failed to write /etc/hosts (sudo) — leaving entry behind"
    return 0
  fi
  rm -f "$tmp"

  sudo dscacheutil -flushcache 2>/dev/null || true
  sudo killall -HUP mDNSResponder 2>/dev/null || true
}

cmd_deploy() {
  # Usage: sandboxctl deploy [path] [--repo <dir>] [--env <name>] [--chart <dir>]
  #                          [--values <file>] [--name <name>] [--no-build] [--redeploy]
  local positional="" repo_flag="" env="dev" do_build=1
  local chart_override="" values_override="" name_override=""
  local purge_old_tags="${SANDBOX_BUILD_PURGE_OLD_TAGS:-0}"
  local redeploy=0
  local opt_build_cpus="${SANDBOX_BUILD_CPUS:-}"
  local opt_build_memory="${SANDBOX_BUILD_MEMORY:-}"
  local opt_build_runtime="${SANDBOX_BUILD_RUNTIME:-}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)     repo_flag="$2"; shift 2 ;;
      --env)      env="$2"; shift 2 ;;
      --chart)    chart_override="$2"; shift 2 ;;
      --values)   values_override="$2"; shift 2 ;;
      --name)     name_override="$2"; shift 2 ;;
      --no-build) do_build=0; shift ;;
      --redeploy) redeploy=1; do_build=0; shift ;;
      --purge-old-tags)    purge_old_tags=1; shift ;;
      --no-purge-old-tags) purge_old_tags=0; shift ;;
      --build-cpus)    opt_build_cpus="${2:-}"; shift 2 ;;
      --build-memory)  opt_build_memory="${2:-}"; shift 2 ;;
      --build-runtime) opt_build_runtime="${2:-}"; shift 2 ;;
      --on-host)
        opt_build_runtime="docker" ; shift ;;
      -h|--help)
        cat <<EOF
sandboxctl deploy [path] [--repo <dir>] [--env <name>]
                  [--chart <dir>] [--values <file>] [--name <name>]
                  [--no-build] [--redeploy] [--purge-old-tags]

Builds + pushes images, applies secrets, pushes the chart to the
in-cluster Gitea, creates one Argo CD Application per chart, and
routes a stable URL to each. The product repo is selected by:
  --repo <dir>   explicit pointer to the repo root
  [path]         positional form of the same
  (default)      current working directory

Pipeline (per chart):
  1. Build + push every Dockerfile listed in <repo>/sandboxctl.yaml,
     or auto-walk Dockerfiles when no manifest exists. Skip with
     --no-build (useful when iterating only on chart edits).
  2. Apply <repo>/k8s/secrets.yaml to each chart's target namespace,
     prompting to fill placeholders on first run.
  3. Push the chart to the in-cluster Gitea, create one Argo CD
     Application per chart syncing from Gitea, and route
     <chart>.${SANDBOX_DOMAIN}:${SANDBOX_HTTPS_PORT} to the
     chart's primary Service. The chart's image is auto-pinned via
     Argo helm parameters to the registry image just built
     (localhost:${SANDBOX_REGISTRY_PORT}/<name>:<tag>) when a manifest
     image maps to the chart by name (or is the repo's sole image), so
     the deployed image always matches the build — no need to hardcode
     the registry path in values.yaml.

Chart resolution order (no --chart):
  1. <repo>/k8s/chart/Chart.yaml         the recommended layout
  2. Auto-discovery walks <repo> for any Chart.yaml within depth 5
     (skipping vendor / node_modules / dist / .git).
  3. Interactive prompt asks for an absolute or relative chart path
     when nothing is found.

Override flags (skip auto-discovery and deploy a single chart):
  --chart <dir>     Path to a chart directory containing Chart.yaml.
                    Relative paths resolve from <repo>.
  --values <file>   Values file inside <chart>. Defaults to
                    values-sandbox.yaml, then values-local.yaml.
  --name <name>     Override the Argo Application + routed hostname
                    name. Defaults to the chart's "name:" field.

Mode flags:
  --no-build        Skip the build step. Image pins still resolve from
                    the existing registry contents, so the chart deploys
                    against the last-pushed tag.
  --redeploy        Skip the build step (same as --no-build) AND push
                    the chart subtree to Gitea, then force Argo CD to
                    refresh the Application immediately so it picks up
                    the just-pushed commit instead of waiting for the
                    next poll. Use this when only the chart/values
                    changed and the existing image is fine — the same
                    built image is reused, the helm overrides are
                    re-pushed to Gitea, Argo syncs, and the workloads
                    are restarted.

Defaults:
  --env  dev   (namespace = <chart>; URL = <chart>.${SANDBOX_DOMAIN})
               # --env=staging puts the chart in <chart>-staging while
               # the URL stays <chart>.${SANDBOX_DOMAIN}, so each env
               # is one app slot — re-deploy with --env=<other> swaps
               # which namespace the same hostname routes to.
EOF
        return 0
        ;;
      -*) die "unknown flag: $1" ;;
      *)
        if [[ -z "$positional" ]]; then positional="$1"; shift
        else die "unexpected argument: $1"
        fi ;;
    esac
  done
  require_running_cluster
  local target
  target="$(_resolve_product_repo "$repo_flag" "$positional" deploy)" || return 1

  local entries
  if [[ -n "$chart_override" ]]; then
    entries="$(_emit_explicit_chart_entry "$target" "$chart_override" "$values_override" "$name_override")" || return 1
  else
    [[ -z "$values_override" && -z "$name_override" ]] \
      || die "--values and --name require --chart"

    # Convention: <target>/k8s/chart is the recommended layout. Resolve
    # in this order:
    #   1. <target>/k8s/chart/Chart.yaml          — implicit chart
    #   2. discover_app_charts, helm entries only — multi-chart repos
    #   3. interactive prompt for a chart path    — keeps the user in-flow
    #
    # We deliberately don't fall back to discover_app_charts's "directory"
    # mode (rendered manifests under k8s/ or deploy/). That fallback was
    # correct in theory but in practice repos like this one have a
    # deploy/ holding misc infra (operator CRDs, ad-hoc YAML), and Argo
    # would happily try to apply all of it as the app's manifests.
    if [[ -f "${target}/k8s/chart/Chart.yaml" ]]; then
      log "found chart at ${target}/k8s/chart (the recommended layout)"
      entries="$(_emit_explicit_chart_entry "$target" "k8s/chart" "" "")" || return 1
    else
      local discovered=""
      discovered="$(discover_app_charts "$target" 2>/dev/null || true)"
      # Strip any "directory" rows — those are manifest dirs, not charts,
      # and silently picking them up is what caused earlier deploys to
      # apply unrelated infra (e.g. operator CRDs sitting under deploy/).
      local helm_only=""
      helm_only="$(printf '%s\n' "$discovered" | awk -F'\t' 'NF>=2 && $1=="helm"')"

      if [[ -n "$helm_only" ]]; then
        entries="$helm_only"
      else
        # Nothing chart-shaped under <target> — offer to scaffold one
        # (chart + sandbox values + secrets template + Kargo pipeline)
        # instead of dead-ending. --chart still bypasses everything.
        if [[ ! -t 0 ]]; then
          die "no chart found under ${target} — run 'sandboxctl scaffold ${target}', or pass --chart <dir> (no TTY available for the interactive offer)"
        fi
        echo
        echo "  No chart found at ${target}/k8s/chart (the recommended layout)"
        echo "  and no other Helm chart was discovered under ${target}."
        echo
        printf '  Generate chart(s) + GitOps pipeline now with '\''sandboxctl scaffold'\''? [Y/n] '
        local scaffold_answer=""
        read -r scaffold_answer
        case "$scaffold_answer" in
          n|N|no|NO) die "deploy aborted — add a chart or pass --chart <dir>" ;;
        esac
        command -v sandboxctl >/dev/null 2>&1 \
          || die "the sandboxctl binary is not on PATH — cannot scaffold"
        sandboxctl scaffold "$target" \
          || die "scaffold did not complete — fix the reported issue and re-run deploy"

        # Re-discover with the freshly generated charts.
        if [[ -f "${target}/k8s/chart/Chart.yaml" ]]; then
          entries="$(_emit_explicit_chart_entry "$target" "k8s/chart" "" "")" || return 1
        else
          entries="$(discover_app_charts "$target" 2>/dev/null | awk -F'\t' 'NF>=2 && $1=="helm"')"
          [[ -n "$entries" ]] || die "scaffold ran but no chart was generated (see its skip reasons above)"
        fi
      fi
    fi
  fi

  log "discovered $(echo "$entries" | wc -l | tr -d ' ') app(s) under ${target}"

  # Prime sudo once up-front (only if /etc/hosts will need new lines).
  # add_app_host runs once per chart at the end and needs sudo to write
  # /etc/hosts; primer here means a single prompt instead of one per
  # chart later in the pipeline.
  local needs_sudo=0
  while IFS=$'\t' read -r kind cname _src _vals; do
    [[ -n "$cname" ]] || continue
    local _h; _h="$(deploy_hostname_for "$cname" "$env")"
    if ! grep -qE "^[[:space:]]*127\.0\.0\.1[[:space:]].*\b${_h}\b" /etc/hosts; then
      needs_sudo=1
    fi
  done <<<"$entries"

  # When at least one /etc/hosts entry needs writing, prime sudo now
  # and keep it alive for the rest of the pipeline. cmd_build can take
  # several minutes (multi-stage docker builds), and macOS's default
  # sudo timestamp lifetime (~5 min) would otherwise expire before
  # add_app_host runs at the end — turning the host write into a
  # silent failure.
  if (( needs_sudo )); then
    prime_sudo
    start_sudo_keepalive
  fi

  if (( redeploy )); then
    log "redeploy mode — skipping build, pushing chart to Gitea, and forcing an Argo CD hard refresh per app"
  fi

  # Always rebuild + push every Dockerfile listed in sandboxctl.yaml so
  # the registry matches what the just-pushed chart references. Skipped
  # on --no-build (or --redeploy, which implies --no-build) when only
  # chart/values edits are in flight. cmd_build is a no-op if there's
  # no manifest and no Dockerfiles under <target>.
  if (( do_build )); then
    if [[ -f "${target}/sandboxctl.yaml" || -f "${target}/sandboxctl.yml" ]] \
        || find "$target" -type f -name Dockerfile -not -path '*/.git/*' \
             -not -path '*/node_modules/*' -not -path '*/vendor/*' \
             -not -path '*/dist/*' -print -quit 2>/dev/null | grep -q .; then
      local build_args=("$target")
      [[ "$purge_old_tags" == "1" ]] && build_args+=(--purge-old-tags)
      [[ -n "$opt_build_cpus" ]]    && build_args+=(--build-cpus    "$opt_build_cpus")
      [[ -n "$opt_build_memory" ]]  && build_args+=(--build-memory  "$opt_build_memory")
      [[ -n "$opt_build_runtime" ]] && build_args+=(--build-runtime "$opt_build_runtime")
      log "running 'sandboxctl build ${build_args[*]}' first (use --no-build to skip)"
      cmd_build "${build_args[@]}"
    else
      log "no Dockerfiles or sandboxctl.yaml under ${target} — skipping build step"
    fi
  fi

  # Resolve the build manifest once (same precedence as cmd_build) so the
  # per-chart loop can pin each chart's image to the registry coordinates
  # cmd_build just pushed. chart_count gates the "sole image" fallback in
  # _image_ref_for_chart — a single-image, single-chart repo maps even
  # when image and chart names differ.
  local deploy_manifest=""
  for candidate in "${target}/sandboxctl.yaml" "${target}/sandboxctl.yml"; do
    [[ -f "$candidate" ]] && { deploy_manifest="$candidate"; break; }
  done
  local chart_count
  chart_count="$(printf '%s\n' "$entries" | grep -c . || true)"

  # Iterate every discovered chart. Each becomes one Argo Application
  # synced from a dedicated Gitea repo (apps/<chart>-chart.git).
  local kind cname src_dir values_file
  while IFS=$'\t' read -r kind cname src_dir values_file; do
    [[ -n "$cname" ]] || continue
    cname="$(slugify "$cname")"

    local namespace hostname
    namespace="$(deploy_namespace_for "$cname" "$env")"
    hostname="$(deploy_hostname_for  "$cname" "$env")"

    log "[${cname}] ${kind} at ${src_dir} → ns ${namespace}, host ${hostname}"

    # Apply secrets from the target repo to the chart's namespace.
    # Convention: a single <target>/k8s/secrets.yaml at the repo root
    # feeds every chart in the repo, applied separately into each
    # chart's namespace. Repos that want per-chart secrets can keep
    # the file empty and apply their own out-of-band.
    ensure_secrets_for_namespace "$target" "$namespace"

    kc create namespace "$namespace" --dry-run=client -o yaml | kc apply -f - >/dev/null

    if [[ "$kind" == "helm" && -z "$values_file" ]]; then
      values_file="$(_ensure_sandbox_values_file "$cname" "$src_dir" "$deploy_manifest")"
    fi

    [[ "$kind" == "helm" && -n "$values_file" ]] && \
      log "[${cname}] using values file: ${values_file}"

    local repo_name="${cname}-chart"
    local gitea_url
    gitea_url="$(gitea_push_chart "$repo_name" "$src_dir")"
    log "[${cname}] pushed chart → ${gitea_url}"

    # All chart adaptation (image pins, chart-shipped Ingress override, …)
    # happens inside _apply_argo_app via _chart_helm_overrides — it reads
    # the chart's values.yaml + the repo's sandboxctl.yaml directly, so
    # there's nothing to precompute here.
    # Scaffold-generated pipelines carry their own Applications (dev +
    # staging, Kargo-annotated) — apply those instead of the inline
    # single-app heredoc. Everything downstream (health wait, restart,
    # route) keys off the dev app, which keeps the plain <app> name.
    local gitops_dir="${target}/k8s/gitops/${cname}"
    if [[ "$kind" == "helm" && -f "${gitops_dir}/application.yaml" ]]; then
      apply_gitops_pipeline "$cname" "$gitops_dir"
    else
      _apply_argo_app "$cname" "$kind" "$gitea_url" "$values_file" "$namespace" "$src_dir" "$deploy_manifest" "$chart_count"
    fi

    # --redeploy short-circuits Argo's reconcile poll so the chart push
    # we just made hits the cluster within seconds. The annotation is a
    # no-op on a brand-new Application (the apply above already triggers
    # a sync), so it's safe to fire unconditionally when the flag is set.
    if (( redeploy )); then
      _argo_refresh_app "$cname"
    fi

    _wait_argo_health "$cname"

    _restart_app_workloads "$cname" "$namespace"

    _route_app_service "$cname" "$namespace" "$hostname" "$deploy_manifest"
  done <<<"$entries"

  _print_deploy_summary "$entries" "$env"
}

# End-of-deploy summary table. One row per app: name, namespace, Argo
# sync/health, pods ready, URL. Reads live cluster state so it reflects
# what actually came up — including charts that timed out before
# becoming Healthy.
_print_deploy_summary() {
  local entries="$1" env="$2"
  echo
  log "deploy summary"
  printf '  %-20s %-22s %-12s %-12s %-10s %s\n' \
    "APP" "NAMESPACE" "SYNC" "HEALTH" "PODS" "URL"
  printf '  %-20s %-22s %-12s %-12s %-10s %s\n' \
    "---" "---------" "----" "------" "----" "---"

  while IFS=$'\t' read -r _kind cname _src _vals; do
    [[ -n "$cname" ]] || continue
    cname="$(slugify "$cname")"
    local ns hostname url sync health pods_ready pods_total
    ns="$(deploy_namespace_for "$cname" "$env")"
    hostname="$(deploy_hostname_for "$cname" "$env")"
    url="https://${hostname}:${SANDBOX_HTTPS_PORT}"

    sync="$(kc -n "$ARGOCD_NS" get application "$cname" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    health="$(kc -n "$ARGOCD_NS" get application "$cname" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    sync="${sync:--}"
    health="${health:--}"

    # Count Pods that report Ready=True against total Pods in the
    # namespace. `wc -l` after filtering with awk avoids needing jq.
    pods_total="$(kc -n "$ns" get pods --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    pods_ready="$(kc -n "$ns" get pods --no-headers 2>/dev/null \
      | awk '$2 ~ /^[0-9]+\/[0-9]+$/ { split($2, a, "/"); if (a[1] == a[2]) c++ } END { print c+0 }')"

    printf '  %-20s %-22s %-12s %-12s %-10s %s\n' \
      "$cname" "$ns" "$sync" "$health" "${pods_ready}/${pods_total}" "$url"
  done <<<"$entries"

  echo
  echo "next:"
  while IFS=$'\t' read -r _kind cname _src _vals; do
    [[ -n "$cname" ]] || continue
    cname="$(slugify "$cname")"
    printf '  open https://%s:%s\n' "$(deploy_hostname_for "$cname" "$env")" "${SANDBOX_HTTPS_PORT}"
  done <<<"$entries"
  echo "  open https://${ARGO_HOST}:${SANDBOX_HTTPS_PORT}    # Argo CD UI"
  echo "  sandboxctl undeploy --name <app> --env ${env}    # tear one down"
}

# Echo "<repository>\t<tag>" for the registry image that backs chart
# <cname>, or nothing when no built image maps to it. <cname> is the
# (already-slugified) chart name; <manifest> is the repo's sandboxctl.yaml.
#
# Mapping rules, in order:
#   1. exact match — a manifest image whose slugified name equals <cname>
#      (the common case: chart `sandbox-demo` ↔ image `sandbox-demo`).
#   2. sole image — when the manifest declares exactly one image AND the
#      repo deploys exactly one chart (<chart_count> == 1), assume that
#      image backs the chart even if the names differ.
#
# Anything else (multi-image repos with no name match) returns nothing,
# so the chart's own values.yaml image is left untouched — we never guess
# which of several images a chart wants.
_image_ref_for_chart() {
  local cname="$1" manifest="$2" chart_count="${3:-1}"
  [[ -f "$manifest" ]] || return 0
  local sandboxctl_bin
  sandboxctl_bin="$(command -v sandboxctl 2>/dev/null || true)"
  [[ -n "$sandboxctl_bin" ]] || return 0
  local entries
  entries="$("$sandboxctl_bin" _parse-build-manifest "$manifest" 2>/dev/null)" || return 0
  [[ -n "$entries" ]] || return 0

  local count=0 only_name="" only_tag="" name ctx df tag aliases deps
  while IFS=$'\t' read -r name ctx df tag aliases deps; do
    [[ -n "$name" ]] || continue
    count=$((count + 1))
    only_name="$name"; only_tag="$tag"
    if [[ "$(slugify "$name")" == "$cname" ]]; then
      printf '%s\t%s\n' "localhost:${SANDBOX_REGISTRY_PORT}/${name}" "${tag:-latest}"
      return 0
    fi
  done <<<"$entries"

  if [[ "$count" -eq 1 && "$chart_count" -eq 1 ]]; then
    printf '%s\t%s\n' "localhost:${SANDBOX_REGISTRY_PORT}/${only_name}" "${only_tag:-latest}"
  fi
}

# When the chart ships a values.yaml but no sandbox-flavour values file,
# generate one (values-sandbox.yaml, next to Chart.yaml) by mimicking the
# default values.yaml with two non-destructive edits:
#
#   • every `*.ingress.enabled` / `*.ingress.create` toggle flipped to false
#     (sandboxctl owns external routing via the per-app Istio VirtualService);
#   • every `{ repository, tag }` image group rewritten to the in-cluster
#     registry whenever the build manifest names a matching image.
#
# Idempotent: re-running deploy regenerates the file with the latest pins,
# but never touches a chart that already has a sandbox-flavour file the
# user has hand-tuned. Designed so an arbitrary third-party chart can be
# deployed without the user authoring sandboxctl-specific YAML.
#
# Echoes the relative filename on success ("values-sandbox.yaml"), empty
# string on no-op (chart has no values.yaml or generation failed). The
# caller treats empty as "no sandbox values file" — Argo will fall back
# to the chart's vendored values.yaml plus the helm.parameters pins.
_ensure_sandbox_values_file() {
  local cname="$1" src_dir="$2" deploy_manifest="${3:-}"
  local sandboxctl_bin
  sandboxctl_bin="$(command -v sandboxctl 2>/dev/null || true)"
  [[ -n "$sandboxctl_bin" ]] || { printf ''; return 0; }
  [[ -d "$src_dir" ]] || { printf ''; return 0; }
  [[ -f "${src_dir}/values.yaml" ]] || { printf ''; return 0; }

  # Resolve build-manifest images to chart-values slots. Each chart slot
  # is claimed at most once: the resolver returns one
  # `<path>\t<kind>\t<image>\t<tag>` row per claim, and we forward those
  # to the mimic helper as `--by-path` pins. Slots can be of kind:
  #   • keys   — `{ repository, tag }` group; mimic writes both fields
  #   • string — inline image scalar; mimic overwrites the value
  local pins=() pin_count=0
  if [[ -n "$deploy_manifest" && -f "$deploy_manifest" ]]; then
    local rpath rkind rimg rtag
    while IFS=$'\t' read -r rpath rkind rimg rtag; do
      [[ -n "$rpath" && -n "$rkind" && -n "$rimg" ]] || continue
      pins+=("--by-path" "${rpath}=${rkind}:localhost:${SANDBOX_REGISTRY_PORT}/${rimg}:${rtag:-latest}")
      pin_count=$((pin_count + 1))
    done < <("$sandboxctl_bin" _chart-resolve-image-pins "$src_dir" "$deploy_manifest" "$cname" 2>/dev/null || true)
  fi

  local out_path="${src_dir}/values-sandbox.yaml"
  if "$sandboxctl_bin" _chart-mimic-values "$src_dir" "$out_path" \
       ${pins[@]+"${pins[@]}"} >/dev/null 2>&1; then
    if [[ -f "$out_path" ]]; then
      log "[${cname}] mimicked values.yaml → values-sandbox.yaml (Ingress disabled, ${pin_count} image pin(s))" >&2
      printf 'values-sandbox.yaml'
      return 0
    fi
  else
    warn "[${cname}] could not mimic values.yaml — Argo will fall back to chart defaults + helm.parameters pins"
  fi
  printf ''
}

# Compute the full set of Argo helm parameters the chart should be deployed
# with. Output is one `name=value` line per parameter (sorted, deterministic).
# Combines two independent passes — each is opt-in and skips silently when
# its inputs are missing:
#
#   1. Ingress auto-disable.  Any `*.ingress.enabled = true` (or `.create = true`)
#      key found in the chart's values.yaml is flipped to `false`. sandboxctl
#      owns external routing via the per-app Istio VirtualService, so a
#      chart-shipped Ingress would either fight that VirtualService or stall
#      forever waiting for an IngressClass that this cluster doesn't ship.
#
#   2. Image pinning. The Go helper `_chart-resolve-image-pins` walks the
#      chart's values.yaml for both `{ repository, tag }` groups AND inline
#      image-string scalars (e.g. `agentImages.sdk: ghcr.io/.../foo@sha256:…`),
#      then matches each build-manifest image to one chart slot. The
#      one-pin-per-slot invariant prevents the bug where N build images all
#      collapsed onto a single `image.repository` (last-write-wins), which
#      caused charts to deploy with the wrong image. Build images that find
#      no slot are skipped — duplicating onto a wrong slot is *worse* than
#      not pinning at all.
#
# Per-pin emission shape:
#   • kind=keys    →  `<path>.repository=…` + `<path>.tag=…`
#   • kind=string  →  `<path>=<repo>:<tag>`  (Argo helm parameter overwriting
#                     the inline scalar; helm/Argo accept arbitrary key paths)
#
# Diagnostics: each decision is logged with its reason so the deploy
# transcript shows *why* a particular parameter was injected.
_chart_helm_overrides() {
  local cname="$1" src_dir="$2" deploy_manifest="${3:-}" chart_count="${4:-1}"
  local sandboxctl_bin
  sandboxctl_bin="$(command -v sandboxctl 2>/dev/null || true)"
  [[ -n "$sandboxctl_bin" ]] || return 0
  [[ -d "$src_dir" ]] || return 0

  # Stage 1 — chart-shipped Ingress auto-disable.
  while IFS= read -r toggle; do
    [[ -n "$toggle" ]] || continue
    printf '%s=false\n' "$toggle"
    log "[${cname}] auto-disabling chart toggle ${toggle}=false (sandboxctl owns external routing)" >&2
  done < <("$sandboxctl_bin" _chart-ingress-overrides "$src_dir" 2>/dev/null)

  # Stage 2 — image pinning. Resolver guarantees one pin per chart slot.
  local pinned_any=0
  if [[ -n "$deploy_manifest" && -f "$deploy_manifest" ]]; then
    local rpath rkind rimg rtag
    while IFS=$'\t' read -r rpath rkind rimg rtag; do
      [[ -n "$rpath" && -n "$rkind" && -n "$rimg" ]] || continue
      case "$rkind" in
        keys)
          printf '%s.repository=localhost:%s/%s\n' "$rpath" "$SANDBOX_REGISTRY_PORT" "$rimg"
          printf '%s.tag=%s\n' "$rpath" "${rtag:-latest}"
          ;;
        string)
          printf '%s=localhost:%s/%s:%s\n' "$rpath" "$SANDBOX_REGISTRY_PORT" "$rimg" "${rtag:-latest}"
          ;;
        *) continue ;;
      esac
      log "[${cname}] pinning ${rpath} (${rkind}) → localhost:${SANDBOX_REGISTRY_PORT}/${rimg}:${rtag:-latest}" >&2
      pinned_any=1
    done < <("$sandboxctl_bin" _chart-resolve-image-pins "$src_dir" "$deploy_manifest" "$cname" 2>/dev/null || true)
  fi

  # Stage 2 fallback — legacy single-image behaviour. Only fires when the
  # resolver returned nothing (chart with no image surfaces, or no build
  # manifest images matched), to preserve the `_image_ref_for_chart`
  # contract for charts written before the resolver existed.
  if [[ "$pinned_any" == "0" && -n "$deploy_manifest" ]]; then
    local legacy_ref
    legacy_ref="$(_image_ref_for_chart "$cname" "$deploy_manifest" "$chart_count")"
    if [[ -n "$legacy_ref" ]]; then
      local lrepo ltag
      IFS=$'\t' read -r lrepo ltag <<<"$legacy_ref"
      printf 'image.repository=%s\n' "$lrepo"
      printf 'image.tag=%s\n' "${ltag:-latest}"
      log "[${cname}] pinning image → ${lrepo}:${ltag:-latest} (single-image fallback)" >&2
    fi
  fi
}

# Apply (or update) one Argo CD Application. Helper for cmd_deploy so
# the per-chart loop body stays readable.
#
# Helm parameters (image pins, ingress overrides) come from
# `_chart_helm_overrides`, which inspects the chart's values.yaml and the
# repo's sandboxctl.yaml. Argo applies parameters *after* valueFiles, so
# the deployed image always matches the freshly-built one regardless of
# what the chart's values.yaml hardcodes — and chart-shipped Ingress
# resources stay dormant when sandboxctl owns external routing.
# Apply a scaffold-generated Kargo pipeline (k8s/gitops/<app>/): the
# Project first (its controller creates the project namespace), then
# the git-credentials Secret the promotion steps need to push to the
# in-cluster Gitea, then Warehouse + Stages + the stage-annotated Argo
# Applications. Idempotent — plain applies, controllers reconcile.
apply_gitops_pipeline() {
  local cname="$1" gitops_dir="$2"
  local project="${cname}-kargo"

  log "[${cname}] applying Kargo pipeline from ${gitops_dir}"
  kc apply -f "${gitops_dir}/project.yaml" >/dev/null

  local i
  for ((i=0; i<30; i++)); do
    kc get namespace "$project" >/dev/null 2>&1 && break
    sleep 1
  done
  kc get namespace "$project" >/dev/null 2>&1 \
    || die "[${cname}] Kargo project namespace ${project} did not appear — is Kargo running? ('sandboxctl status')"

  local pass_file="${SANDBOX_STATE_DIR}/gitea-admin-pass"
  [[ -s "$pass_file" ]] || die "gitea password file missing — run 'sandboxctl up' first"
  local admin_pass; admin_pass="$(cat "$pass_file")"
  kc apply -f - <<EOF >/dev/null
apiVersion: v1
kind: Secret
metadata:
  name: gitea-creds
  namespace: ${project}
  labels:
    kargo.akuity.io/cred-type: git
type: Opaque
stringData:
  repoURL: http://gitea-http.${GITEA_NS}.svc.cluster.local:3000/${GITEA_ORG}/${cname}-chart.git
  username: ${GITEA_ADMIN_USER}
  password: ${admin_pass}
EOF

  kc apply -f "${gitops_dir}/warehouse.yaml" >/dev/null
  kc apply -f "${gitops_dir}/stages.yaml"    >/dev/null
  kc apply -f "${gitops_dir}/application.yaml" >/dev/null
  ok "[${cname}] pipeline applied — registry → dev → staging (promote via 'sandboxctl kargo-ui')"
}

_apply_argo_app() {
  local cname="$1" kind="$2" gitea_url="$3" values_file="$4" namespace="$5"
  local src_dir="${6:-}" deploy_manifest="${7:-}" chart_count="${8:-1}"

  log "[${cname}] creating Argo CD Application (source: ${gitea_url}@main)"
  if [[ "$kind" == "helm" ]]; then
    # Collect helm parameters (image pins + ingress overrides + …) into an
    # array; render the helm block from whatever survived the walks.
    local -a helm_params=()
    local _line
    while IFS= read -r _line; do
      # Only accept well-formed `name=value` lines. Defends the rendered
      # Argo Application against any stray stdout pollution (ANSI-coloured
      # log lines, helm command output, …) from `_chart_helm_overrides` —
      # kubectl rejects YAML with control characters, and a single bad
      # line would otherwise break the entire deploy.
      [[ "$_line" =~ ^[A-Za-z_][A-Za-z0-9_.-]*= ]] || continue
      helm_params+=("$_line")
    done < <(_chart_helm_overrides "$cname" "$src_dir" "$deploy_manifest" "$chart_count")

    local helm_block=""
    if [[ -n "$values_file" || "${#helm_params[@]}" -gt 0 ]]; then
      helm_block="    helm:"$'\n'
      [[ -n "$values_file" ]] && \
        helm_block+="      valueFiles: [\"${values_file}\"]"$'\n'
      if [[ "${#helm_params[@]}" -gt 0 ]]; then
        helm_block+="      parameters:"$'\n'
        local kv pname pval
        for kv in "${helm_params[@]}"; do
          pname="${kv%%=*}"
          pval="${kv#*=}"
          helm_block+="        - { name: ${pname}, value: \"${pval}\" }"$'\n'
        done
      fi
    fi
    kc apply -f - <<EOF >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${cname}
  namespace: ${ARGOCD_NS}
  finalizers: [resources-finalizer.argocd.argoproj.io]
spec:
  project: default
  source:
    repoURL: ${gitea_url}
    targetRevision: main
    path: .
${helm_block}  destination:
    server: https://kubernetes.default.svc
    namespace: ${namespace}
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
EOF
  else
    kc apply -f - <<EOF >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${cname}
  namespace: ${ARGOCD_NS}
  finalizers: [resources-finalizer.argocd.argoproj.io]
spec:
  project: default
  source:
    repoURL: ${gitea_url}
    targetRevision: main
    path: .
    directory: { recurse: true }
  destination:
    server: https://kubernetes.default.svc
    namespace: ${namespace}
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
EOF
  fi
}

# Force Argo CD to refresh + re-sync an Application immediately instead
# of waiting for the next reconcile poll (default ~3 min).
#
# The hard refresh annotation tells argocd-application-controller to
# drop its cached manifest and re-pull from the source repo (here:
# the in-cluster Gitea) right now. We pair it with the operation.sync
# annotation so a Synced-but-stale Application also gets a fresh
# kubectl apply pass — this is what makes `--redeploy` deterministic
# even when the helm parameters render to byte-identical manifests.
#
# Both annotations are stamped with the current epoch so they look
# different to the controller every call (Argo de-dupes on value).
# Best-effort: a missing Application or RBAC denial is logged but
# doesn't fail the deploy — the caller's _wait_argo_health pass will
# surface a real problem.
_argo_refresh_app() {
  local cname="$1"
  local stamp; stamp="$(date -u +%s)"
  if ! kc -n "$ARGOCD_NS" annotate application "$cname" \
        --overwrite \
        "argocd.argoproj.io/refresh=hard" \
        "sandboxctl.io/refresh-stamp=${stamp}" \
        >/dev/null 2>&1; then
    warn "[${cname}] could not annotate Argo Application for hard refresh (continuing)"
    return 0
  fi
  log "[${cname}] requested Argo CD hard refresh (stamp ${stamp})"
}

# Poll Argo CD for an Application to become Synced + Healthy with a
# single 180s attempt — retries are deliberately disabled. In practice
# the workload is serving long before the top-level Application flips
# Healthy, so extra 180s windows just delay the deploy without
# changing the outcome.
#
# When the wait window times out we check per-resource health (read
# straight from k8s via .status.resources[*].health.status). If every
# workload reports Healthy, the Application is just lagging and we
# log it as healthy. Otherwise we log the live sync/health values and
# let the deploy continue — the deploy summary surfaces the final
# state for verification, and the user can inspect the Argo CD UI.
#
# The previous 3-attempt loop with an interactive [retry/skip/abort]
# prompt is retained below as commented-out code in case slow links
# or CRD-heavy installs ever need it back; re-enable by replacing
# the body with that block and bumping ARGO_HEALTH_ATTEMPTS.
ARGO_HEALTH_ATTEMPTS="${ARGO_HEALTH_ATTEMPTS:-1}"            # retained for env-var compat; loop is single-shot
ARGO_HEALTH_PROMPT_TIMEOUT="${ARGO_HEALTH_PROMPT_TIMEOUT:-15}" # retained for env-var compat; prompt is disabled
_wait_argo_health() {
  local cname="$1"
  local label="[${cname}] waiting for Argo CD to sync (Healthy, up to 180s)"
  if with_spinner "$label" _wait_argo_health_poll "$cname"; then
    return 0
  fi
  if _argo_app_resources_healthy "$cname"; then
    ok "[${cname}] all workloads report Healthy — Argo status lagging, continuing without further waits"
    return 0
  fi
  local sync health
  sync="$(kc -n "$ARGOCD_NS" get application "$cname" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  health="$(kc -n "$ARGOCD_NS" get application "$cname" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  warn "[${cname}] not Synced+Healthy after 180s (sync=${sync:-unknown} health=${health:-unknown}) — continuing with deploy; check Argo CD UI for details"
  return 0

  # --- legacy retry loop (disabled — kept for reference) ---
  # local attempt
  # for (( attempt=1; attempt<=ARGO_HEALTH_ATTEMPTS; attempt++ )); do
  #   local loop_label
  #   if (( ARGO_HEALTH_ATTEMPTS == 1 )); then
  #     loop_label="[${cname}] waiting for Argo CD to sync (Healthy, up to 180s)"
  #   else
  #     loop_label="[${cname}] waiting for Argo CD to sync (Healthy, up to 180s — attempt ${attempt}/${ARGO_HEALTH_ATTEMPTS})"
  #   fi
  #   if with_spinner "$loop_label" _wait_argo_health_poll "$cname"; then
  #     return 0
  #   fi
  #   if _argo_app_resources_healthy "$cname"; then
  #     ok "[${cname}] all workloads report Healthy — Argo status lagging, continuing without further waits"
  #     return 0
  #   fi
  #   if (( attempt < ARGO_HEALTH_ATTEMPTS )); then
  #     case "$(_argo_health_retry_choice "$cname" "$attempt")" in
  #       skip)  warn "[${cname}] skipping remaining Argo health waits — continuing with deploy"; return 0 ;;
  #       abort) die  "[${cname}] aborted by user during Argo health wait" ;;
  #       retry|*) ;;
  #     esac
  #   fi
  # done
  # local total=$(( ARGO_HEALTH_ATTEMPTS * 180 ))
  # warn "[${cname}] did not become Healthy in ${total}s across ${ARGO_HEALTH_ATTEMPTS} attempts (sync=${sync:-unknown} health=${health:-unknown}) — check Argo CD UI"
}

# Returns 0 when every workload Argo tracks for <cname> currently
# reports Healthy. Reads `.status.resources[*].health.status` directly
# from the Argo Application — those per-resource values come from k8s
# without the reconciliation lag of the top-level health field, so a
# True here means the app IS serving even when Argo's overall status
# hasn't caught up. Returns 1 when no resource statuses are visible or
# any one of them is not yet Healthy.
_argo_app_resources_healthy() {
  local cname="$1"
  local healths s
  healths="$(kc -n "$ARGOCD_NS" get application "$cname" \
    -o jsonpath='{.status.resources[*].health.status}' 2>/dev/null || true)"
  [[ -n "$healths" ]] || return 1
  for s in $healths; do
    [[ "$s" == "Healthy" ]] || return 1
  done
  return 0
}

# Interactive [retry/skip/abort] prompt — disabled along with the retry
# loop above. Function definition kept commented out so the previous
# behaviour can be restored from a single file rather than git history.
# _argo_health_retry_choice() {
#   local cname="$1" attempt="$2"
#   local remaining=$(( ARGO_HEALTH_ATTEMPTS - attempt ))
#   local sync health
#   sync="$(kc -n "$ARGOCD_NS" get application "$cname" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
#   health="$(kc -n "$ARGOCD_NS" get application "$cname" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
#   if [[ ! -t 0 || ! -t 2 ]]; then
#     echo skip; return
#   fi
#   local plural="ies"; (( remaining == 1 )) && plural="y"
#   printf '\n  \033[1;33m[%s]\033[0m attempt %d/%d not healthy yet (sync=%s health=%s) — %d retr%s remaining.\n' \
#     "$cname" "$attempt" "$ARGO_HEALTH_ATTEMPTS" "${sync:-unknown}" "${health:-unknown}" \
#     "$remaining" "$plural" >&2
#   printf '  \033[2mIf the app is already serving traffic in your browser, it is safe to skip remaining waits.\033[0m\n' >&2
#   local reply=""
#   if read -r -t "$ARGO_HEALTH_PROMPT_TIMEOUT" \
#        -p "  > [s]kip remaining waits / [r]etry / [a]bort  (default: skip in ${ARGO_HEALTH_PROMPT_TIMEOUT}s) " \
#        reply
#   then
#     case "${reply:-s}" in
#       r|R|retry|RETRY) echo retry ;;
#       a|A|abort|ABORT) echo abort ;;
#       *)               echo skip  ;;
#     esac
#   else
#     printf '\n  \033[2m> no answer in %ss — skipping remaining waits\033[0m\n' "$ARGO_HEALTH_PROMPT_TIMEOUT" >&2
#     echo skip
#   fi
# }

_wait_argo_health_poll() {
  local cname="$1"
  local i sync health
  for ((i=1; i<=60; i++)); do
    sync="$(kc -n "$ARGOCD_NS" get application "$cname" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    health="$(kc -n "$ARGOCD_NS" get application "$cname" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    [[ "$sync" == "Synced" && "$health" == "Healthy" ]] && return 0
    sleep 3
  done
  return 1
}

# Roll the workloads Argo owns for this app so pods pick up rebuilt
# images even when the manifest is byte-identical. Sources workloads
# from status.resources because our Argo install tracks via annotation,
# not the legacy app.kubernetes.io/instance label.
_restart_app_workloads() {
  local cname="$1" fallback_ns="$2"
  local resources
  resources="$(kc -n "$ARGOCD_NS" get application "$cname" \
    -o jsonpath='{range .status.resources[?(@.group=="apps")]}{.kind}{"\t"}{.namespace}{"\t"}{.name}{"\n"}{end}' \
    2>/dev/null || true)"
  if [[ -z "$resources" ]]; then
    warn "[${cname}] no workloads found in Argo Application status — skipping rollout restart"
    return 0
  fi

  local kind ns name lower_kind rolled_any=0
  while IFS=$'\t' read -r kind ns name; do
    [[ -n "$kind" && -n "$name" ]] || continue
    case "$kind" in
      Deployment|StatefulSet|DaemonSet) ;;
      *) continue ;;
    esac
    [[ -n "$ns" ]] || ns="$fallback_ns"
    lower_kind="$(printf '%s' "$kind" | tr '[:upper:]' '[:lower:]')"
    log "[${cname}] rollout restart ${lower_kind}/${name} (ns ${ns})"
    kc -n "$ns" rollout restart "${lower_kind}/${name}" >/dev/null 2>&1 || \
      warn "[${cname}] failed to restart ${lower_kind}/${name} in ${ns}"
    rolled_any=1
  done <<<"$resources"

  (( rolled_any )) || return 0

  while IFS=$'\t' read -r kind ns name; do
    [[ -n "$kind" && -n "$name" ]] || continue
    case "$kind" in
      Deployment|StatefulSet|DaemonSet) ;;
      *) continue ;;
    esac
    [[ -n "$ns" ]] || ns="$fallback_ns"
    lower_kind="$(printf '%s' "$kind" | tr '[:upper:]' '[:lower:]')"
    with_spinner "[${cname}] waiting for ${lower_kind}/${name} rollout (up to 180s)" \
      kc -n "$ns" rollout status "${lower_kind}/${name}" --timeout=180s \
      || warn "[${cname}] ${lower_kind}/${name} in ${ns} did not finish rolling within 180s"
  done <<<"$resources"
  ok "[${cname}] workloads restarted"
}

# _wait_services_stable polls Services in $namespace until two consecutive
# reads return the same set (or the cap is hit). Argo applies Services
# over a few seconds and the routing picker is otherwise racy: the first
# `kc get svc` on a fresh deploy can land before the chart's primary
# Service exists, picking a sibling and baking the wrong VS until next
# deploy. Polling makes the picker correct without operator action.
#
# Cap: 30s by default — enough for an Argo sync to settle on a healthy
# cluster, short enough not to block deploys when nothing is racing.
# Override via SANDBOXCTL_SVC_STABLE_TIMEOUT.
_wait_services_stable() {
  local namespace="$1"
  local cap="${SANDBOXCTL_SVC_STABLE_TIMEOUT:-30}"
  local prev="" cur="" stable_for=0 elapsed=0
  while (( elapsed < cap )); do
    cur="$(kc -n "$namespace" get svc -o name 2>/dev/null | sort | tr '\n' ',' || true)"
    if [[ -n "$cur" && "$cur" == "$prev" ]]; then
      (( stable_for++ ))
      # Two consecutive identical reads, ~2s apart, is enough.
      (( stable_for >= 1 )) && return 0
    else
      stable_for=0
    fi
    prev="$cur"
    sleep 2
    (( elapsed += 2 ))
  done
  # Caller continues even if cap expired — failing closed here would
  # block deploys for charts that never settle. The picker will still
  # warn loudly via _probe_route below if it landed on a bad upstream.
  return 0
}

# _probe_route validates that the just-applied VirtualService actually
# routes traffic to a working upstream. Spawns a one-shot Pod inside
# the cluster (so we hit the gateway over its real ClusterIP rather
# than relying on the operator's host DNS / kind port-forward), curls
# https://$hostname:$SANDBOX_HTTPS_PORT/, and prints the response code.
# Empty output ⇒ unreachable.
_probe_route() {
  local hostname="$1"
  local svc_addr="istio-ingress.${ISTIO_INGRESS_NS}.svc.cluster.local"
  # `kubectl run --rm` is the simplest way; we use curlimages/curl which
  # is small (~5MB) and guaranteed to have curl. Failures are silent —
  # the caller decides what an empty/non-2xx result means.
  local code=""
  code="$(kc run -n "$ISTIO_INGRESS_NS" --rm -i --restart=Never --quiet \
    --image=curlimages/curl:8.10.1 --image-pull-policy=IfNotPresent \
    "sandboxctl-probe-$RANDOM" -- \
    curl -sk --max-time 5 -o /dev/null -w "%{http_code}" \
    --resolve "${hostname}:${SANDBOX_HTTPS_PORT}:$(kc -n "$ISTIO_INGRESS_NS" get svc istio-ingress -o jsonpath='{.spec.clusterIP}' 2>/dev/null)" \
    "https://${hostname}:${SANDBOX_HTTPS_PORT}/" 2>/dev/null || true)"
  # Strip anything that isn't a 3-digit code (kubectl wrapper noise on
  # some platforms emits "pod/... deleted" lines).
  code="$(printf '%s' "$code" | grep -oE '[0-9]{3}' | tail -n1 || true)"
  printf '%s\n' "${code:-unreachable}"
  # Suppress the unused-var warning shellcheck would otherwise emit
  # for svc_addr (we keep it for readability of the hostname split).
  : "$svc_addr"
}

# Wire one Istio VirtualService + /etc/hosts entry for the app's primary
# Service. Selection order, first match wins:
#
#   1. Explicit override — `primary_service: <name>` in sandboxctl.yaml.
#      Authoritative; sandboxctl never second-guesses an explicit pick.
#   2. Annotation override — any Service in the namespace carrying
#      `sandboxctl.io/primary: "true"`. Lets per-chart authors mark the
#      entrypoint without touching sandboxctl.yaml.
#   3. Scored heuristic — `_score-services` ranks every Service by:
#        • exact name match with chart (+100)
#        • web port (80/8080/3000/8081/5000/8000 or named http/web; +30/+25)
#        • user-facing name keyword (ui/web/frontend/app/client; +20)
#        • penalty for backend/api/worker-style names (-30)
#      Ties break alphabetically. The reasons are logged so chart authors
#      can debug why a particular Service got picked.
#   4. Fallback — first Service in the namespace, preserving the old
#      behaviour when scoring yields nothing useful.
#
# Sandboxctl is *deliberately* opinionated here: the chart already
# encodes intent (which Service exposes port 80, which one is named
# "ui", which one is annotated), so the heuristic just reads that
# intent rather than asking the user to learn a new convention.
#
# Observability contract: every line is prefixed `[cname/namespace]` so
# multi-chart deploys (sandboxctl walks every app it discovered) are
# unambiguous in the log. When the scored heuristic fires, the full
# ranked candidate table is printed alongside a one-line hint telling
# the operator how to make the choice deterministic for next deploy.
# After the route applies, we probe it from inside the cluster and warn
# loudly with a remediation pointer when the upstream returns a non-OK
# code — that's the safety net for charts where the heuristic guessed
# wrong, so the operator finds out at deploy time, not in the browser.
_route_app_service() {
  local cname="$1" namespace="$2" hostname="$3" deploy_manifest="${4:-}"
  local sandboxctl_bin="" svc="" svc_port="" pick_reason=""
  local tag="[${cname}/${namespace}]"

  sandboxctl_bin="$(command -v sandboxctl 2>/dev/null || true)"

  # 1. Explicit override from sandboxctl.yaml
  local manifest_primary=""
  if [[ -n "$sandboxctl_bin" && -n "$deploy_manifest" && -f "$deploy_manifest" ]]; then
    while IFS='=' read -r key val; do
      [[ "$key" == "primary_service" ]] && manifest_primary="$val"
    done < <("$sandboxctl_bin" _manifest-extras "$deploy_manifest" 2>/dev/null)
  fi
  if [[ -n "$manifest_primary" ]] && \
     kc -n "$namespace" get svc "$manifest_primary" >/dev/null 2>&1; then
    svc="$manifest_primary"
    pick_reason="sandboxctl.yaml primary_service"
  fi

  # If we have an explicit pick, skip the stability wait — the operator
  # told us exactly which Service to use, no scanning is needed. For
  # the heuristic and fallback paths, wait briefly so a still-syncing
  # Argo doesn't fool us into picking the wrong sibling.
  if [[ -z "$svc" ]]; then
    _wait_services_stable "$namespace"
  fi

  # 2. Annotation override
  if [[ -z "$svc" ]]; then
    svc="$(kc -n "$namespace" get svc \
      -o jsonpath="{range .items[?(@.metadata.annotations.sandboxctl\\.io/primary=='true')]}{.metadata.name}{'\n'}{end}" \
      2>/dev/null | head -n1 || true)"
    [[ -n "$svc" ]] && pick_reason="annotation sandboxctl.io/primary=true"
  fi

  # 3. Scored heuristic
  if [[ -z "$svc" && -n "$sandboxctl_bin" ]]; then
    local svc_json=""
    svc_json="$(kc -n "$namespace" get svc -o json 2>/dev/null || true)"
    if [[ -n "$svc_json" ]]; then
      local scored=""
      scored="$(printf '%s' "$svc_json" | "$sandboxctl_bin" _score-services "$cname" 2>/dev/null || true)"
      if [[ -n "$scored" ]]; then
        # Surface the full ranked candidate table so the operator can
        # tell at a glance whether the picker chose what they expected.
        log "${tag} primary Service candidates:"
        local sname="" sport="" sscore="" sreasons=""
        while IFS=$'\t' read -r sname sport sscore sreasons; do
          [[ -n "$sname" ]] || continue
          printf '  %-32s %-6s %5s  %s\n' "$sname" "$sport" "$sscore" "$sreasons"
          if [[ -z "$svc" ]]; then
            svc="$sname"
            svc_port="$sport"
            pick_reason="scored ${sscore} (${sreasons})"
          fi
        done <<<"$scored"
        # shellcheck disable=SC2016 # backticks are literal in this help text.
        printf '%s hint: set `deploy.primary_service: <name>` in sandboxctl.yaml,\n' "$tag"
        # shellcheck disable=SC2016
        printf '%s       or annotate the chosen Service with `sandboxctl.io/primary: "true"`,\n' "$tag"
        printf '%s       to skip the heuristic on next deploy.\n' "$tag"
      fi
    fi
  fi

  # 4. Fallback (preserves pre-smarts behaviour)
  if [[ -z "$svc" ]]; then
    svc="$(kc -n "$namespace" get svc -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    [[ -n "$svc" ]] && pick_reason="first Service in namespace (fallback)"
  fi

  if [[ -n "$svc" ]]; then
    if [[ -z "$svc_port" ]]; then
      svc_port="$(kc -n "$namespace" get svc "$svc" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo 80)"
    fi
    [[ -z "$svc_port" ]] && svc_port=80
    log "${tag} primary Service: svc/${svc}:${svc_port} (${pick_reason})"
    add_app_route "$hostname" "$namespace" "$svc" "$svc_port"
    add_app_host  "$hostname"
    ok "${tag} routed https://${hostname}:${SANDBOX_HTTPS_PORT} → svc/${svc}:${svc_port}"

    # Sanity check: if the chosen upstream isn't actually serving the
    # app's HTTP surface (e.g. the heuristic raced and picked a sibling
    # that 404s on `/`), warn now with a remediation pointer rather
    # than letting the operator discover it in a browser later.
    if [[ "${SANDBOXCTL_SKIP_ROUTE_PROBE:-}" != "1" ]]; then
      local code=""
      code="$(_probe_route "$hostname")"
      case "$code" in
        2??|3??)
          ok "${tag} probe ${hostname} → HTTP ${code}"
          ;;
        unreachable|"")
          warn "${tag} route applied but the gateway probe could not reach https://${hostname}:${SANDBOX_HTTPS_PORT}/."
          warn "${tag} the chosen Service may not be serving on the picked port, or the gateway may still be programming the route."
          warn "${tag} re-run 'sandboxctl deploy' shortly, or set 'deploy.primary_service: <name>' in sandboxctl.yaml to pin the choice."
          ;;
        *)
          warn "${tag} route applied but https://${hostname}:${SANDBOX_HTTPS_PORT}/ returned HTTP ${code}."
          warn "${tag} svc/${svc}:${svc_port} may not host the app's HTTP entrypoint."
          warn "${tag} pin the right Service via 'deploy.primary_service: <name>' in sandboxctl.yaml,"
          warn "${tag} or annotate it with 'sandboxctl.io/primary: \"true\"', then re-run 'sandboxctl deploy'."
          ;;
      esac
    fi
  else
    warn "${tag} no Service found in ${namespace} yet — Argo may still be syncing. Re-run 'sandboxctl deploy' once pods are up to wire the route."
  fi
}

cmd_undeploy() {
  require_running_cluster
  local env="dev" name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env)  env="$2"; shift 2 ;;
      --name) name="$2"; shift 2 ;;
      *) die "unexpected argument: $1" ;;
    esac
  done
  [[ -n "$name" ]] || die "usage: sandboxctl undeploy --name <appname> [--env <name>]"

  local namespace hostname
  namespace="$(deploy_namespace_for "$name" "$env")"
  hostname="$(deploy_hostname_for "$name" "$env")"

  log "removing Argo Application + route for ${name} (env=${env})"
  if kc -n "$ARGOCD_NS" get application "$name" >/dev/null 2>&1; then
    kc -n "$ARGOCD_NS" patch application "$name" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
    kc -n "$ARGOCD_NS" delete application "$name" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
  remove_app_route "$hostname" "$namespace"
  remove_app_host  "$hostname"

  # Scaffold-generated pipeline resources, when present: the staging
  # Application and the Kargo Project (whose deletion cascades to the
  # project namespace, Warehouse, Stages, and credentials Secret).
  if kc -n "$ARGOCD_NS" get application "${name}-staging" >/dev/null 2>&1; then
    kc -n "$ARGOCD_NS" patch application "${name}-staging" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
    kc -n "$ARGOCD_NS" delete application "${name}-staging" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
  kc delete project.kargo.akuity.io "${name}-kargo" --ignore-not-found --wait=false >/dev/null 2>&1 || true

  ok "undeployed ${name} (namespace ${namespace} preserved — delete manually if desired)"
}

# ============================================================================
# Disk diagnose + prune
# ============================================================================
#
# `sandboxctl prune` (alias: `cleanup`) walks the four storage surfaces that
# typically obstruct a sandboxctl workflow when something refuses to push or
# build with "no space left on device":
#
#   1. macOS host disk            (read-only diagnosis — never auto-cleaned)
#   2. mounted DMG installers     (`/Volumes/*` — eject-only)
#   3. container-runtime VM disk  (podman machine / docker daemon)
#   4. in-cluster registry blobs  (registry GC + optional full prune)
#
# Each surface is explained out loud BEFORE any destructive step, and every
# destructive step is gated on an explicit y/N prompt (or `--yes` to take
# the recommended action everywhere). Read-only when invoked with `--dry-run`.

# Bytes -> human (GiB, MiB, KiB). Avoids depending on numfmt (not on stock macOS).
_prune_human_bytes() {
  awk -v b="$1" 'BEGIN{
    split("B KiB MiB GiB TiB", u, " ");
    i=1; v=b+0;
    while (v>=1024 && i<5) { v/=1024; i++ }
    printf "%.1f %s", v, u[i];
  }'
}

# y/N prompt that auto-accepts when SANDBOX_PRUNE_ASSUME_YES=1 (set by --yes).
# Returns 0 on yes, 1 on no. Never reads from stdin if it's not a TTY — that
# avoids hangs when prune is invoked from a script without --yes.
_prune_confirm() {
  local question="$1"
  if [[ "${SANDBOX_PRUNE_ASSUME_YES:-0}" == "1" ]]; then
    printf '  \033[2m> %s — auto-yes (--yes)\033[0m\n' "$question" >&2
    return 0
  fi
  if [[ ! -t 0 ]]; then
    printf '  \033[2m> %s — skipped (no TTY; pass --yes to accept)\033[0m\n' "$question" >&2
    return 1
  fi
  local reply=""
  read -r -p "  > ${question} [y/N] " reply
  case "${reply:-N}" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# Section banner used to keep the four prune stages visually distinct.
_prune_section() {
  printf '\n\033[1;36m━━━ %s ━━━\033[0m\n' "$1" >&2
}

_prune_explain() {
  printf '  \033[2m%s\033[0m\n' "$1" >&2
}

# ----- stage 1: Mac host disk ----------------------------------------------
#
# We never touch the user's real disk. The output is a reassurance card so
# the user can tell whether a generic macOS "disk full" alert is about
# their actual SSD or about something we *can* clean (DMG, podman VM,
# in-cluster registry).
_prune_stage_host_disk() {
  _prune_section "1/4 macOS host disk (your real SSD)"
  _prune_explain "What: the volume backing your home directory + apps."
  _prune_explain "Why we look: macOS shows a single 'disk full' alert that doesn't say *which* disk. We rule the host out first."
  _prune_explain "Action: read-only — sandboxctl never deletes user files."

  if ! command -v df >/dev/null 2>&1; then
    warn "df not found — skipping host disk check"
    return 0
  fi

  local line size used avail capacity
  line="$(df -H / 2>/dev/null | awk 'NR==2 {print $2, $3, $4, $5}')"
  if [[ -z "$line" ]]; then
    warn "could not read host disk usage"
    return 0
  fi
  read -r size used avail capacity <<<"$line"

  printf '  /  %s used of %s (%s free, %s)\n' "$used" "$size" "$avail" "$capacity" >&2

  # Strip trailing % for arithmetic.
  local pct="${capacity%\%}"
  if [[ "$pct" =~ ^[0-9]+$ ]] && (( pct >= 90 )); then
    warn "host disk is ${capacity} full — sandboxctl can't help with that, but Finder > About This Mac > Storage can."
  else
    ok "host disk has plenty of room — any 'disk full' alert is about something else below."
  fi
}

# ----- stage 2: mounted DMGs / external volumes ----------------------------
#
# Every mounted DMG appears as a 100%-full disk in `df` (it's sized to its
# contents). They commonly trigger the macOS "disk full" alert when the user
# leaves an installer mounted. We list them and offer to detach.
_prune_stage_mounted_dmgs() {
  _prune_section "2/4 mounted DMG installers (under /Volumes)"
  _prune_explain "What: each line below is a separate filesystem mounted under /Volumes — usually an unejected installer DMG."
  _prune_explain "Why they look 'full': DMGs are sized exactly to their contents, so df always reports 100%. That's normal — not a problem to fix."
  _prune_explain "Action: offered as eject-only (hdiutil detach). Your apps are *not* uninstalled by ejecting."

  if ! command -v df >/dev/null 2>&1; then
    warn "df not found — skipping DMG check"
    return 0
  fi

  # Collect the list of /Volumes/* mounts (excluding the boot volume).
  local mounts=() mount
  while IFS= read -r mount; do
    [[ -n "$mount" ]] || continue
    mounts+=("$mount")
  done < <(df 2>/dev/null | awk '$NF ~ "^/Volumes/" {for (i=9; i<=NF; i++) printf "%s%s", $i, (i==NF ? RS : OFS); }' OFS=' ')

  if (( ${#mounts[@]} == 0 )); then
    ok "nothing extra mounted under /Volumes — skipping."
    return 0
  fi

  printf '\n  found %d extra volume(s) mounted:\n' "${#mounts[@]}" >&2
  local m
  for m in "${mounts[@]}"; do
    printf '    • %s\n' "$m" >&2
  done

  if ! command -v hdiutil >/dev/null 2>&1; then
    warn "hdiutil not found — cannot eject (manually drag the volume to Trash to eject)"
    return 0
  fi

  if ! _prune_confirm "Eject all of the above? (Safe — they're installer DMGs, not your real disk.)"; then
    _prune_explain "skipped — leaving volumes mounted."
    return 0
  fi

  for m in "${mounts[@]}"; do
    if hdiutil detach "$m" >/dev/null 2>&1; then
      ok "ejected $m"
    else
      warn "could not eject $m — it may be in use by a Finder window or a running installer"
    fi
  done
}

# ----- stage 3: container runtime VM (podman / docker) ---------------------
#
# This is the surface most likely to bite — `podman build` and `podman push`
# both fail with "no space left on device" when the *VM* fills up, even if
# the Mac disk has 200 GiB free. We diagnose, then offer a graduated cleanup
# (dangling-only first, then optionally include unused tagged images).
_prune_stage_runtime_vm() {
  _prune_section "3/4 container runtime VM (the disk podman/docker actually use)"

  case "$SANDBOX_RUNTIME" in
    podman)
      _prune_explain "What: podman runs Linux containers inside a small VM. That VM has its own virtual disk — typically ${PODMAN_MACHINE_DISK_GIB} GiB."
      _prune_explain "Why it fills: every 'podman build' / 'podman pull' writes layers into the VM, not your Mac SSD. Old build artifacts stack up fast."
      _prune_explain "Action: 'podman system prune' removes stopped containers + dangling images + build cache. Tagged images you still use are NOT touched."

      if ! command -v podman >/dev/null 2>&1; then
        warn "podman not installed — skipping runtime check"
        return 0
      fi

      local machine_running=0
      if podman machine inspect --format '{{.State}}' 2>/dev/null | grep -qx running; then
        machine_running=1
      fi
      if (( ! machine_running )); then
        warn "podman machine not running — start it with 'podman machine start' to run prune"
        return 0
      fi

      printf '\n  podman VM disk usage:\n' >&2
      podman machine ssh -- df -h / 2>/dev/null | sed 's/^/    /' >&2 || warn "could not read VM disk usage"

      printf '\n  podman storage breakdown:\n' >&2
      podman system df 2>/dev/null | sed 's/^/    /' >&2 || true

      if ! _prune_confirm "Run 'podman system prune -f' (dangling images + stopped containers + build cache)?"; then
        _prune_explain "skipped — leaving runtime storage untouched."
        return 0
      fi

      log "running: podman system prune -f"
      podman system prune -f 2>&1 | tail -3 | sed 's/^/    /' >&2 || true
      ok "podman pruned"

      if _prune_confirm "Also prune *unused tagged* images? (Removes images with no running container — re-pulled on next use.)"; then
        log "running: podman image prune -af"
        podman image prune -af 2>&1 | tail -3 | sed 's/^/    /' >&2 || true
        ok "podman tagged-but-unused images removed"
      fi

      printf '\n  podman VM disk after prune:\n' >&2
      podman machine ssh -- df -h / 2>/dev/null | sed 's/^/    /' >&2 || true
      ;;

    docker)
      _prune_explain "What: Docker Desktop runs containers inside a Linux VM that has its own raw disk image (~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw)."
      _prune_explain "Why it fills: every 'docker build' / 'docker pull' writes layers into the VM, not your Mac SSD."
      _prune_explain "Action: 'docker system prune' removes stopped containers + dangling images + build cache. Tagged images you still use are NOT touched."

      if ! command -v docker >/dev/null 2>&1; then
        warn "docker not installed — skipping runtime check"
        return 0
      fi
      if ! docker info >/dev/null 2>&1; then
        warn "docker daemon not reachable — start Docker Desktop to run prune"
        return 0
      fi

      printf '\n  docker storage breakdown:\n' >&2
      docker system df 2>/dev/null | sed 's/^/    /' >&2 || true

      if ! _prune_confirm "Run 'docker system prune -f' (dangling images + stopped containers + build cache)?"; then
        _prune_explain "skipped — leaving runtime storage untouched."
        return 0
      fi

      log "running: docker system prune -f"
      docker system prune -f 2>&1 | tail -3 | sed 's/^/    /' >&2 || true
      ok "docker pruned"

      if _prune_confirm "Also prune *unused tagged* images?"; then
        log "running: docker image prune -af"
        docker image prune -af 2>&1 | tail -3 | sed 's/^/    /' >&2 || true
        ok "docker tagged-but-unused images removed"
      fi
      ;;
    *)
      warn "unknown SANDBOX_RUNTIME=$SANDBOX_RUNTIME — skipping runtime check"
      ;;
  esac
}

# ----- stage 4: in-cluster registry blobs ----------------------------------
#
# The kind cluster ships a registry:2 Pod backed by a PVC inside the VM.
# `sandboxctl build` pushes here, and over time GC'd manifests can leave
# dangling blobs. We always offer the safe option (gc only); a full prune
# is gated behind a separate confirmation.
_prune_stage_cluster_registry() {
  _prune_section "4/4 in-cluster registry (sandboxctl build / images)"
  _prune_explain "What: a registry:2 Pod inside the kind cluster, backed by a ${SANDBOX_REGISTRY_STORAGE} PVC. 'sandboxctl build' pushes layers here."
  _prune_explain "Why it fills: deleted/replaced image tags leave their blobs behind until the registry's garbage-collector runs."
  _prune_explain "Action offered: 'gc' (safe — only reclaims orphaned blobs). 'prune all' is asked separately and removes every image."

  if ! cluster_registered; then
    _prune_explain "no kind cluster registered — skipping (run 'sandboxctl up' first if you wanted to clean it)."
    return 0
  fi
  if ! cluster_api_reachable; then
    _prune_explain "kind cluster registered but not reachable — skipping."
    return 0
  fi

  if _prune_confirm "Run registry GC (reclaim orphaned blobs only — keeps every tagged image)?"; then
    cmd_images gc || warn "registry gc failed — see output above"
  else
    _prune_explain "skipped registry gc."
  fi

  if _prune_confirm "Also delete *every* image from the cluster registry? (You'll need to 'sandboxctl build' again to redeploy.)"; then
    cmd_images prune || warn "registry prune failed — see output above"
  else
    _prune_explain "skipped full registry prune — tagged images preserved."
  fi
}

cmd_prune() {
  local assume_yes=0 only=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes)            assume_yes=1; shift ;;
      --only)              only="${2:-}"; shift 2 ;;
      host|dmgs|runtime|registry)
                           only="$1"; shift ;;
      -h|--help)
        cat <<EOF
sandboxctl prune  (alias: cleanup)

Walks the four storage surfaces that typically obstruct sandboxctl
when builds/pushes start failing with "no space left on device":

  1. macOS host disk            (read-only diagnosis)
  2. mounted DMG installers     (offers hdiutil detach)
  3. container runtime VM       (podman/docker system prune)
  4. in-cluster registry        (registry GC, optional full prune)

Each stage explains what it is, why it fills, and prompts before
any destructive step.

flags:
  -y, --yes            accept the recommended action at every prompt
  --only <stage>       run a single stage: host | dmgs | runtime | registry
  host|dmgs|runtime|registry
                       positional shorthand for --only

examples:
  sandboxctl prune                  # interactive, all four stages
  sandboxctl prune --yes            # accept every prompt (CI / scripted)
  sandboxctl prune runtime          # just clean podman/docker
  sandboxctl prune --only registry  # just GC the in-cluster registry
EOF
        return 0 ;;
      *) die "unknown flag for prune: $1 (try 'sandboxctl prune --help')" ;;
    esac
  done

  export SANDBOX_PRUNE_ASSUME_YES="$assume_yes"

  log "sandboxctl prune — diagnosing the four storage surfaces"
  _prune_explain "Each stage prints what it is and why it fills before asking. Nothing is deleted without your y/N."

  case "$only" in
    "")        _prune_stage_host_disk
               _prune_stage_mounted_dmgs
               _prune_stage_runtime_vm
               _prune_stage_cluster_registry ;;
    host)      _prune_stage_host_disk ;;
    dmgs)      _prune_stage_mounted_dmgs ;;
    runtime)   _prune_stage_runtime_vm ;;
    registry)  _prune_stage_cluster_registry ;;
    *)         die "unknown stage: $only (use host | dmgs | runtime | registry)" ;;
  esac

  printf '\n' >&2
  ok "prune complete"
}

# ============================================================================
# Optional add-on libs. Sourced after every helper above so the libs can
# call into log/ok/die, the kc helper, launchagent_stop, etc. without
# worrying about ordering. Each lib is responsible for its own idempotency.
# ============================================================================

# shellcheck source=lib/nats.sh
[[ -f "${SANDBOX_LIB_DIR}/nats.sh" ]] && . "${SANDBOX_LIB_DIR}/nats.sh"

# shellcheck source=lib/aregistry.sh
[[ -f "${SANDBOX_LIB_DIR}/aregistry.sh" ]] && . "${SANDBOX_LIB_DIR}/aregistry.sh"

# AI Agentic Gateway — agentgateway is the default-on, Gateway-API-native
# proxy for AI traffic; the four legacy alternatives (Portkey, LiteLLM,
# MLflow, Tyk) are opt-in and live side-by-side so users can test each.
# Each lib is fully self-contained, matching the nats.sh / aregistry.sh
# pattern above.
# shellcheck source=lib/agentgateway.sh
[[ -f "${SANDBOX_LIB_DIR}/agentgateway.sh" ]] && . "${SANDBOX_LIB_DIR}/agentgateway.sh"
# shellcheck source=lib/litellm.sh
[[ -f "${SANDBOX_LIB_DIR}/litellm.sh" ]] && . "${SANDBOX_LIB_DIR}/litellm.sh"
# shellcheck source=lib/portkey.sh
[[ -f "${SANDBOX_LIB_DIR}/portkey.sh" ]] && . "${SANDBOX_LIB_DIR}/portkey.sh"
# shellcheck source=lib/mlflow.sh
[[ -f "${SANDBOX_LIB_DIR}/mlflow.sh" ]] && . "${SANDBOX_LIB_DIR}/mlflow.sh"
# shellcheck source=lib/tyk.sh
[[ -f "${SANDBOX_LIB_DIR}/tyk.sh" ]] && . "${SANDBOX_LIB_DIR}/tyk.sh"

# ============================================================================
# Usage + dispatcher
# ============================================================================

usage() {
  cat <<EOF
sandbox.sh — local kind sandbox with Argo CD + Kargo + Istio ambient

usage:
  sandbox.sh setup-podman [--disk-size <GiB>] [--memory <MiB>] [--cpus <N>] [--recreate]
                            install/configure rootful podman machine; --recreate is required
                            to grow an existing machine's disk-size (podman can't grow it in place)
  sandbox.sh trust-ca       trust the sandbox root CA in macOS System keychain (sudo)
  sandbox.sh untrust-ca     remove the sandbox root CA from System keychain (sudo)
  sandbox.sh up [--workers N] [--with-arctl] [--with-cnpg] [--with-agentregistry] [--with-nats] [--with-kagent]
                [--with-agentgateway | --with-ai-gateway | --with-portkey | --with-litellm | --with-mlflow | --with-tyk] [--install all]
                            create cluster + install core (argocd/kargo/demo/gitea/registry/PKI/Istio/dnsmasq).
                            Add-ons are opt-in:
                              --with-arctl / --with-cnpg / --with-agentregistry / --with-nats / --with-kagent
                              --with-agentgateway (or --with-ai-gateway for all five AI gateways)
                              --with-portkey / --with-litellm / --with-mlflow / --with-tyk
                              --install all  (every add-on)
                            --workers N picks the kind worker count (1–3, default 1)
  sandbox.sh down           remove cluster + LaunchAgent + /etc/hosts + keychain CA (keeps ~/.sandbox)
  sandbox.sh purge          down + remove ~/.sandbox (prompts for confirmation)
  sandbox.sh restart        re-apply installers, keep kind cluster + state (use 'restart --rebuild' for full wipe)
  sandbox.sh status         cluster + workload status + URLs
  sandbox.sh validate       curl each URL from the Mac and print HTTP codes
  sandbox.sh creds          print login details (URLs + admin creds)
  sandbox.sh argocd-ui      print Argo CD URL + admin creds
  sandbox.sh kargo-ui       print Kargo URL + admin creds
  sandbox.sh build [path] [--repo <dir>] [--purge-old-tags]
                                     find Dockerfiles under the product repo (path/--repo/cwd),
                                     build + push to the cluster registry; --purge-old-tags
                                     wipes prior tags of each repo before pushing (and runs
                                     a registry GC at the end) so disk stays flat
  sandbox.sh images                  list images in the cluster registry
  sandbox.sh images rm <ref>         delete an image (e.g. 'myapp:v1' or 'myapp' for all tags)
  sandbox.sh images prune            delete every image, then GC blobs (alias: 'purge')
  sandbox.sh images gc               run registry garbage-collector to reclaim disk now
  sandbox.sh deploy [path] [--repo <dir>] [--env <name>] [--no-build] [--redeploy] [--purge-old-tags]
                                     auto-discover every chart under the product repo,
                                     build + push every Dockerfile, apply k8s/secrets.yaml, push each chart
                                     to in-cluster Gitea, create one Argo CD Application per chart, and
                                     route <chart>.${SANDBOX_DOMAIN} per app.
                                     --redeploy skips the build, re-pushes the chart to Gitea, and forces
                                     Argo CD to hard-refresh so the existing image is reused with the
                                     new chart/values without waiting for the next reconcile poll.
  sandbox.sh undeploy --name <appname> [--env <name>]
                                     remove the Argo Application, route, and hosts entry (namespace preserved)
  sandbox.sh bootstrap [path] [--repo <dir>] [up flags] [deploy flags]
                                     run 'up' (if not already up) + 'deploy' in one shot — handy first-run wrapper
  sandbox.sh prune [host|dmgs|runtime|registry] [--yes]
                                     diagnose + clean the four disk surfaces that obstruct sandboxctl
                                     (host disk, mounted DMGs, container runtime VM, in-cluster registry).
                                     Always prompts before destructive actions — alias: 'cleanup'.

env overrides:
  SANDBOX_RUNTIME             podman (default) or docker
  SANDBOX_CLUSTER_NAME        cluster name (default: sandboxctl)
  SANDBOX_DOMAIN              local DNS suffix (default: sandbox.app)
  SANDBOX_HTTP_PORT           host port for HTTP (default: 8080)
  SANDBOX_HTTPS_PORT          host port for HTTPS (default: 8443)
  SANDBOX_REGISTRY_PORT       host port for the in-cluster registry (default: 5050)
  SANDBOX_REGISTRY_STORAGE    PVC size for the registry (default: 12Gi)
  PODMAN_MACHINE_CPUS         CPUs for podman machine init (default: 4)
  PODMAN_MACHINE_MEMORY_MIB   RAM in MiB for podman machine (default: 6144)
  PODMAN_MACHINE_DISK_GIB     disk in GiB for podman machine init (default: 60)
  KIND_NODE_IMAGE             kind node image (default: kindest/node:v1.35.0)
  SANDBOX_WORKER_COUNT        number of kind worker nodes — integer 1–3 (default: 1).
                              Same as 'sandboxctl up --workers N'.
  ARGOCD_CHART_VERSION        pin argo-cd helm chart version
  RELOADER_CHART_VERSION      pin stakater/reloader helm chart version (default: 2.2.11)
  KARGO_CHART_VERSION         pin kargo helm chart version
  CERT_MANAGER_CHART_VERSION  pin cert-manager chart version
  ISTIO_CHART_VERSION         pin istio version
  KAGENT_CHART_VERSION        pin kagent helm chart version
  KARGO_TOKEN_SIGNING_KEY     pin Kargo JWT signing key (default: random per install)
  GITEA_CHART_VERSION         pin gitea helm chart version (default: 12.5.0)
  GITEA_ADMIN_USER            admin user created in Gitea (default: sandbox)
  GITEA_ORG                   org chart repos are pushed under (default: sandbox)
  NATS_CHART_VERSION          pin nats helm chart version (default: 2.14.0)
  NATS_HOST                   user-facing NATS hostname (default: nats.\${SANDBOX_DOMAIN})
  NATS_JETSTREAM_SIZE         PVC size for JetStream file store (default: 2Gi)
  SANDBOX_NATS_PORT           Mac-side TCP port for nats:// (default: 4222)
  INSTALL_ARCTL               set to 1 (or pass --with-arctl) to install the arctl CLI on the Mac
  INSTALL_CNPG                set to 1 (or pass --with-cnpg) to install the CloudNativePG operator
  INSTALL_AGENTREGISTRY       set to 1 (or pass --with-agentregistry) to install agentregistry + CNPG
  AREGISTRY_CHART_VERSION     pin agentregistry helm chart version (default: 0.3.3)
  AREGISTRY_IMAGE_TAG         pin agentregistry server image tag (default: v0.3.3)
  AREGISTRY_PG_IMAGE          CNPG postgres image with pgvector (default: ghcr.io/cloudnative-pg/postgresql:17.9-standard-trixie)
  AREGISTRY_PG_STORAGE        PVC size for the CNPG cluster (default: 2Gi)
  CNPG_CHART_VERSION          pin cloudnative-pg operator chart version (default: 0.28.2)
  INSTALL_NATS                set to 1 (or pass --with-nats) to install NATS + JetStream
  INSTALL_KAGENT              set to 1 (or pass --with-kagent) to install kagent
  INSTALL_AGENTGATEWAY        set to 1 (or pass --with-agentgateway) to install the agentgateway proxy
  INSTALL_LITELLM             set to 1 (or pass --with-litellm) to install the LiteLLM proxy
  INSTALL_PORTKEY             set to 1 (or pass --with-portkey) to install the Portkey AI gateway
  INSTALL_MLFLOW              set to 1 (or pass --with-mlflow) to install MLflow
  INSTALL_TYK                 set to 1 (or pass --with-tyk) to install the Tyk OSS gateway
  AGENTGATEWAY_CHART_VERSION  pin agentgateway OCI chart version (default: v1.2.0)
  GATEWAY_API_VERSION         pin upstream Kubernetes Gateway API CRDs version (default: v1.5.0)
  LITELLM_CHART_VERSION       pin litellm-helm OCI chart version (default: latest)
  LITELLM_IMAGE_TAG           LiteLLM image tag (default: main-latest — the chart's version-derived default is often unpublished)
  LITELLM_DB_MODE             LiteLLM Postgres: auto|shared (reuse agentregistry's CNPG cluster) | standalone (default: auto)
  MLFLOW_CHART_VERSION        pin community-charts/mlflow chart version (default: latest)
  TYK_CHART_VERSION           pin tyk-helm/tyk-oss chart version (default: latest)
  PORTKEY_IMAGE               Portkey gateway image (default: portkeyai/gateway:latest)
EOF
}

main() {
  case "${1:-}" in
    setup-podman)       shift; cmd_setup_podman "$@" ;;
    trust-ca)           trust_root_ca ;;
    untrust-ca)         untrust_root_ca ;;
    up)                 shift; cmd_up "$@" ;;
    _onboard-check)     shift; _up_onboarding_check "${1:-$PWD}" ;;
    _ensure-tools)      ensure_tools ;;
    down)               cmd_down ;;
    purge)              cmd_purge ;;
    status)             cmd_status ;;
    restart)            shift; cmd_restart "$@" ;;
    validate)           require_running_cluster; validate_urls ;;
    creds)              cmd_creds ;;
    argocd-ui)          cmd_argocd_ui ;;
    kargo-ui)           cmd_kargo_ui ;;
    build)              shift; cmd_build "$@" ;;
    images)             shift; cmd_images "$@" ;;
    deploy)             shift; cmd_deploy "$@" ;;
    undeploy)           shift; cmd_undeploy "$@" ;;
    bootstrap)          shift; cmd_bootstrap "$@" ;;
    prune|cleanup)      shift; cmd_prune "$@" ;;
    ""|-h|--help|help)  usage ;;
    *) die "unknown subcommand: $1 (try --help)" ;;
  esac
}

main "$@"
