# shellcheck shell=bash
# lib/litellm.sh — LiteLLM proxy/gateway (part of the AI Agentic Gateway)
#
# LiteLLM is an OpenAI-compatible proxy that fronts 100+ LLM providers
# behind one API + key. This lib deploys it into the sandbox so the user
# has a working LLM gateway to point apps at on day one.
#
# What this lib installs (idempotent):
#   1. A Postgres for LiteLLM's key/spend/model store. By default it reuses
#      the CloudNativePG (CNPG) operator the platform already runs (the same
#      one lib/aregistry.sh installs): a CNPG-managed `Cluster` gives us one
#      operator-managed Postgres flavour instead of a second, bare
#      chart-deployed Postgres. When the CNPG operator isn't present (e.g.
#      `up --no-agentregistry`) it falls back to the chart's bundled
#      standalone Postgres (db.deployStandalone=true). Override the choice
#      with LITELLM_DB_MODE=cnpg|standalone|auto (default auto).
#   2. The official litellm-helm OCI chart, pointed at whichever Postgres
#      was provisioned above.
#   3. A random master key persisted to the state dir so it survives
#      reruns of `up` / `restart` (same convention as the Gitea password).
#   4. An Istio VirtualService at https://litellm.${SANDBOX_DOMAIN}.
#
# Sourced by sandbox.sh; assumes the common globals + helpers are set
# (SANDBOX_DOMAIN, ISTIO_INGRESS_NS, SANDBOX_STATE_DIR, kc, helm_install,
# with_spinner, log/ok/warn/die) and helm + kubectl + openssl are on PATH.
#
# Public functions called from sandbox.sh:
#   install_litellm          — full install (gated on INSTALL_LITELLM)
#   install_litellm_routes   — Istio VirtualService for the proxy
#   litellm_present          — predicate for route/host/status gating
#   litellm_status           — one-line status for cmd_status
#   litellm_print_creds      — connection details for cmd_creds

# ============================================================================
# Configuration
# ============================================================================

LITELLM_NS="${LITELLM_NS:-litellm}"
LITELLM_RELEASE="${LITELLM_RELEASE:-litellm}"
LITELLM_CHART="${LITELLM_CHART:-oci://ghcr.io/berriai/litellm-helm}"
# Empty by default: helm resolves the newest published OCI tag. Pin a
# specific chart version here for reproducibility (e.g. LITELLM_CHART_VERSION=0.1.x).
LITELLM_CHART_VERSION="${LITELLM_CHART_VERSION:-}"
LITELLM_HOST="${LITELLM_HOST:-litellm.${SANDBOX_DOMAIN}}"
LITELLM_PORT="${LITELLM_PORT:-4000}"

# Database backing. auto = use CNPG when the operator is available (the
# default-on platform state), else fall back to the chart's bundled
# standalone Postgres. Force either with cnpg / standalone.
LITELLM_DB_MODE="${LITELLM_DB_MODE:-auto}"
LITELLM_PG_CLUSTER="${LITELLM_PG_CLUSTER:-litellm-pg}"
LITELLM_DB_NAME="${LITELLM_DB_NAME:-litellm}"
LITELLM_DB_USER="${LITELLM_DB_USER:-litellm}"
LITELLM_PG_INSTANCES="${LITELLM_PG_INSTANCES:-1}"
LITELLM_PG_STORAGE="${LITELLM_PG_STORAGE:-2Gi}"
# Default to the same CNPG image lib/aregistry.sh uses, so the kind node's
# containerd already has it cached (no extra pull). LiteLLM needs no
# extensions, so any CNPG postgres image works.
LITELLM_PG_IMAGE="${LITELLM_PG_IMAGE:-${AREGISTRY_PG_IMAGE:-ghcr.io/cloudnative-pg/postgresql:17.9-standard-trixie}}"

# Master key persisted across reruns. LiteLLM expects an `sk-...` shape.
LITELLM_KEY_FILE="${LITELLM_KEY_FILE:-${SANDBOX_STATE_DIR}/litellm-master-key}"

# Gate: default-on as part of the AI Agentic Gateway. INSTALL_LITELLM=0
# (or `up --no-litellm` / `up --no-ai-gateway`) skips it.
INSTALL_LITELLM="${INSTALL_LITELLM:-1}"

# ============================================================================
# Predicate
# ============================================================================

litellm_present() {
  kc get ns "$LITELLM_NS" >/dev/null 2>&1
}

# Read-or-generate the persisted master key. Generated with openssl in one
# shot (NOT `tr -dc … | head -c`, which trips SIGPIPE under pipefail — see
# the long note in install_gitea).
_litellm_master_key() {
  if [[ ! -s "$LITELLM_KEY_FILE" ]]; then
    mkdir -p "$SANDBOX_STATE_DIR"
    printf 'sk-%s\n' "$(openssl rand -hex 20)" > "$LITELLM_KEY_FILE"
    chmod 600 "$LITELLM_KEY_FILE"
  fi
  cat "$LITELLM_KEY_FILE"
}

# ============================================================================
# CNPG-backed Postgres (preferred). Reuses the operator + conventions from
# lib/aregistry.sh; works standalone of it too.
# ============================================================================

# True when the CNPG operator's CRD is registered (operator installed).
_cnpg_available() {
  kc get crd clusters.postgresql.cnpg.io >/dev/null 2>&1
}

# Ensure the CNPG operator is present. Fast-returns when its CRD already
# exists (the default case — lib/aregistry.sh installs it before us). When
# absent, borrow aregistry.sh's idempotent installer if it's sourced, then
# wait for the CRD to register. Returns 1 if CNPG can't be made available.
_litellm_ensure_cnpg() {
  _cnpg_available && return 0
  declare -F install_cnpg_operator >/dev/null || return 1
  install_cnpg_operator || return 1
  local i
  for ((i=0; i<30; i++)); do _cnpg_available && return 0; sleep 2; done
  return 1
}

# Provision a CNPG Cluster for LiteLLM in the LiteLLM namespace, so the
# operator-generated "<cluster>-app" secret is reachable by the LiteLLM pod
# via a namespace-local secretKeyRef. No pgvector — LiteLLM doesn't need it.
_install_litellm_pg() {
  kc create namespace "$LITELLM_NS" --dry-run=client -o yaml 2>/dev/null | kc apply -f - >/dev/null 2>&1
  kc apply -f - <<EOF >/dev/null 2>&1 || return 1
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ${LITELLM_PG_CLUSTER}
  namespace: ${LITELLM_NS}
spec:
  instances: ${LITELLM_PG_INSTANCES}
  imageName: ${LITELLM_PG_IMAGE}
  primaryUpdateStrategy: unsupervised
  bootstrap:
    initdb:
      database: ${LITELLM_DB_NAME}
      owner: ${LITELLM_DB_USER}
  storage:
    size: ${LITELLM_PG_STORAGE}
  monitoring:
    enablePodMonitor: false
EOF
  with_spinner "waiting for CNPG cluster '${LITELLM_PG_CLUSTER}' to be ready (typically 1-3 min)" \
    kc -n "$LITELLM_NS" wait --for=condition=Ready --timeout=300s \
      cluster.postgresql.cnpg.io/"$LITELLM_PG_CLUSTER"
}

# ============================================================================
# Installer — called from cmd_up. NON-FATAL: a slow image pull or a flaky
# chart must never abort `up`, so every failure path warns and returns 0.
# ============================================================================

install_litellm() {
  (( ${INSTALL_LITELLM:-1} )) || { log "skipping LiteLLM (INSTALL_LITELLM=0)"; return 0; }

  local key; key="$(_litellm_master_key)"

  # Decide the DB backend. auto/cnpg try CNPG first; both fall back to the
  # chart's bundled standalone Postgres if CNPG can't be provisioned, so
  # `up` never aborts on the DB choice.
  local use_cnpg=0
  case "$LITELLM_DB_MODE" in
    standalone) ;;
    cnpg|auto|*)
      if _litellm_ensure_cnpg && _install_litellm_pg; then
        use_cnpg=1
      elif [[ "$LITELLM_DB_MODE" == "cnpg" ]]; then
        warn "LiteLLM: CNPG requested but unavailable — falling back to the chart's standalone Postgres"
      else
        log "LiteLLM: CNPG operator not available — using the chart's bundled standalone Postgres"
      fi ;;
  esac

  log "installing LiteLLM proxy (ns: $LITELLM_NS, chart ${LITELLM_CHART}${LITELLM_CHART_VERSION:+ @ $LITELLM_CHART_VERSION}, db: $( ((use_cnpg)) && echo CNPG || echo standalone))"

  # No --wait on the helm step: the image + Postgres can take a few minutes
  # on first pull. We bound readiness explicitly below.
  local -a args=(
    helm upgrade --install "$LITELLM_RELEASE" "$LITELLM_CHART"
      --namespace "$LITELLM_NS" --create-namespace
      --set "masterkey=${key}"
      --set "service.type=ClusterIP"
      --set "service.port=${LITELLM_PORT}"
  )
  if (( use_cnpg )); then
    # Point LiteLLM at the CNPG cluster via its operator-generated app
    # secret. db.endpoint carries the host only — the chart assumes 5432,
    # which is the CNPG -rw service port.
    args+=(
      --set "db.deployStandalone=false"
      --set "db.useExisting=true"
      --set "db.endpoint=${LITELLM_PG_CLUSTER}-rw.${LITELLM_NS}.svc.cluster.local"
      --set "db.database=${LITELLM_DB_NAME}"
      --set "db.secret.name=${LITELLM_PG_CLUSTER}-app"
      --set "db.secret.usernameKey=username"
      --set "db.secret.passwordKey=password"
    )
  else
    args+=(
      --set "db.deployStandalone=true"
      --set "db.useExisting=false"
    )
  fi
  [[ -n "$LITELLM_CHART_VERSION" ]] && args+=(--version "$LITELLM_CHART_VERSION")

  if ! helm_install "LiteLLM helm install (image + bundled Postgres; first run can take a few min)" "${args[@]}"; then
    warn "LiteLLM helm install failed — skipping; the rest of the sandbox is unaffected."
    warn "debug: helm -n ${LITELLM_NS} status ${LITELLM_RELEASE} ; kc -n ${LITELLM_NS} get pods"
    return 0
  fi

  if with_spinner "waiting for LiteLLM proxy to become Ready" \
       kc -n "$LITELLM_NS" wait --for=condition=available --timeout=300s deployment --all; then
    ok "LiteLLM ready (https://${LITELLM_HOST}:${SANDBOX_HTTPS_PORT})"
  else
    warn "LiteLLM not Ready within 5 min — check 'kc -n ${LITELLM_NS} get pods'"
    warn "the route goes live at https://${LITELLM_HOST}:${SANDBOX_HTTPS_PORT} once the pod is Ready"
  fi
}

# ============================================================================
# Istio route — called from sandbox.sh's install_routes (present-gated so a
# --no-litellm run doesn't leave a 503 route behind).
# ============================================================================

install_litellm_routes() {
  litellm_present || return 0
  kc apply -f - <<EOF >/dev/null
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: litellm
  namespace: ${LITELLM_NS}
spec:
  hosts: ["${LITELLM_HOST}"]
  gateways: ["${ISTIO_INGRESS_NS}/sandbox-gateway"]
  http:
    - route:
        - destination:
            host: ${LITELLM_RELEASE}.${LITELLM_NS}.svc.cluster.local
            port: { number: ${LITELLM_PORT} }
EOF
}

# ============================================================================
# Status reporter — one line for cmd_status
# ============================================================================

# "CNPG" when a CNPG-managed cluster backs LiteLLM, else "standalone".
_litellm_db_backend() {
  if kc -n "$LITELLM_NS" get cluster.postgresql.cnpg.io/"$LITELLM_PG_CLUSTER" >/dev/null 2>&1; then
    echo "CNPG"
  else
    echo "standalone"
  fi
}

litellm_status() {
  litellm_present || { echo "litellm: not installed"; return; }
  local ready db
  ready="$(kc -n "$LITELLM_NS" get deploy "$LITELLM_RELEASE" \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
  db="$(_litellm_db_backend)"
  if [[ "$ready" == "True" ]]; then
    echo "litellm: ok (https://${LITELLM_HOST}:${SANDBOX_HTTPS_PORT}, OpenAI-compatible proxy, db=${db})"
  else
    echo "litellm: installed but not Ready — kc -n ${LITELLM_NS} get pods"
  fi
}

# ============================================================================
# Mac-side connection hint, called from cmd_creds
# ============================================================================

litellm_print_creds() {
  litellm_present || return 0
  local key=""; [[ -s "$LITELLM_KEY_FILE" ]] && key="$(cat "$LITELLM_KEY_FILE")"
  local db; db="$(_litellm_db_backend)"
  cat <<EOF
LiteLLM (OpenAI-compatible LLM proxy)
  URL:          https://${LITELLM_HOST}:${SANDBOX_HTTPS_PORT}
  Admin UI:     https://${LITELLM_HOST}:${SANDBOX_HTTPS_PORT}/ui
  Master key:   ${key:-<run 'sandboxctl up' to generate>}
  Key file:     ${LITELLM_KEY_FILE}
  In-cluster:   http://${LITELLM_RELEASE}.${LITELLM_NS}.svc.cluster.local:${LITELLM_PORT}
  Database:     ${db}$( [[ "$db" == "CNPG" ]] && echo " — cluster ${LITELLM_PG_CLUSTER} (db ${LITELLM_DB_NAME}), creds in secret ${LITELLM_PG_CLUSTER}-app" )
  Try it:       curl -sk https://${LITELLM_HOST}:${SANDBOX_HTTPS_PORT}/v1/models \\
                  -H "Authorization: Bearer ${key:-<master-key>}"
  Add models:   via the Admin UI, or set proxy_config.model_list and re-run 'sandboxctl up'.
EOF
}
