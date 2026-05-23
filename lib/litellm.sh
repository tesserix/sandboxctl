# shellcheck shell=bash
# lib/litellm.sh — LiteLLM proxy/gateway (part of the AI Agentic Gateway)
#
# LiteLLM is an OpenAI-compatible proxy that fronts 100+ LLM providers
# behind one API + key. This lib deploys it into the sandbox so the user
# has a working LLM gateway to point apps at on day one.
#
# What this lib installs (idempotent):
#   1. A Postgres for LiteLLM's key/spend/model store. By default it REUSES
#      the CloudNativePG (CNPG) cluster the platform already runs for
#      agentregistry — it just provisions a `litellm` database + role on that
#      one cluster, so there's no second Postgres pod (lightest, and still
#      operator-managed). When that cluster isn't present (e.g.
#      `up --no-agentregistry`) it falls back to the chart's bundled
#      standalone Postgres (db.deployStandalone=true). Override the choice
#      with LITELLM_DB_MODE=auto|shared|standalone (default auto).
#   2. The official litellm-helm OCI chart (image tag pinned to one that
#      actually exists — see LITELLM_IMAGE_TAG), pointed at that Postgres.
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
# The chart derives its image tag from its appVersion (e.g. main-1.85.1),
# but that exact tag is frequently NOT published to ghcr (the chart's
# release cadence is out of sync with the image's) — which lands the pod
# in ImagePullBackOff -> a 503 at the route. Pin to a tag that always
# exists. `main-latest` self-heals as the chart floats; pin a specific
# `main-vX.Y.Z` for reproducibility. Applies to the litellm-database image
# the chart selects whenever a database is configured.
LITELLM_IMAGE_TAG="${LITELLM_IMAGE_TAG:-main-latest}"

# Database backing.
#   auto       (default) reuse the existing CNPG Postgres the platform
#              already runs for agentregistry — provision a `litellm`
#              database + role on that one cluster (no second Postgres pod,
#              lightest). Falls back to the chart's bundled standalone
#              Postgres when that cluster isn't present (e.g. --no-agentregistry).
#   shared     force the reuse path (warn + standalone fallback if absent).
#   standalone the chart's own bundled Postgres Deployment.
LITELLM_DB_MODE="${LITELLM_DB_MODE:-auto}"
LITELLM_DB_NAME="${LITELLM_DB_NAME:-litellm}"
LITELLM_DB_USER="${LITELLM_DB_USER:-litellm}"
# Password for the litellm role on the shared cluster, persisted across
# reruns (same convention as the Gitea admin password).
LITELLM_DB_PASS_FILE="${LITELLM_DB_PASS_FILE:-${SANDBOX_STATE_DIR}/litellm-db-pass}"
# Secret (in the LiteLLM namespace) the chart reads DB creds from. We mirror
# the role creds into it since the chart's secretKeyRef is namespace-local.
LITELLM_DB_SECRET="${LITELLM_DB_SECRET:-litellm-db}"

# Master key persisted across reruns. LiteLLM expects an `sk-...` shape.
LITELLM_KEY_FILE="${LITELLM_KEY_FILE:-${SANDBOX_STATE_DIR}/litellm-master-key}"

# Gate: opt-in (it pulls a ~700 MB image and wants ~1-2 GB RAM, so it's not
# in the default `up`). Enable with `up --with-litellm` / `--with-ai-gateway`,
# or INSTALL_LITELLM=1.
INSTALL_LITELLM="${INSTALL_LITELLM:-0}"

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
# Shared CNPG Postgres (preferred). Reuses the cluster lib/aregistry.sh
# already runs — we just add a `litellm` database + role to it, so there's
# no second Postgres pod. Coordinates come from aregistry.sh's globals
# (AREGISTRY_PG_CLUSTER / AREGISTRY_NS), available since both libs are sourced.
# ============================================================================

# Read-or-generate the persisted litellm DB role password (one-shot openssl).
_litellm_db_password() {
  if [[ ! -s "$LITELLM_DB_PASS_FILE" ]]; then
    mkdir -p "$SANDBOX_STATE_DIR"
    openssl rand -hex 24 > "$LITELLM_DB_PASS_FILE"
    chmod 600 "$LITELLM_DB_PASS_FILE"
  fi
  cat "$LITELLM_DB_PASS_FILE"
}

# True when the shared (agentregistry) CNPG cluster exists and is Ready.
_litellm_shared_pg_ready() {
  [[ -n "${AREGISTRY_PG_CLUSTER:-}" && -n "${AREGISTRY_NS:-}" ]] || return 1
  local s
  s="$(kc -n "$AREGISTRY_NS" get cluster.postgresql.cnpg.io/"$AREGISTRY_PG_CLUSTER" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  [[ "$s" == "True" ]]
}

# Name of the shared cluster's primary pod (instances=1 -> "<cluster>-1";
# fall back to the role=primary label after a failover).
_litellm_shared_primary_pod() {
  local p
  p="$(kc -n "$AREGISTRY_NS" get pod -l "cnpg.io/cluster=${AREGISTRY_PG_CLUSTER}" \
    -o jsonpath='{.items[?(@.metadata.labels.role=="primary")].metadata.name}' 2>/dev/null \
    | awk '{print $1}')"
  [[ -n "$p" ]] && { echo "$p"; return 0; }
  echo "${AREGISTRY_PG_CLUSTER}-1"
}

# Create (idempotently) the litellm role + database on the shared cluster and
# mirror the creds into a Secret in the LiteLLM namespace for the chart.
# psql runs inside the primary pod as the local postgres superuser (peer auth
# over the unix socket — works even with CNPG superuser TCP access disabled).
# Returns 1 if the DB couldn't be provisioned (caller falls back).
_litellm_provision_shared_db() {
  local pass pri exists
  pass="$(_litellm_db_password)"
  pri="$(_litellm_shared_primary_pod)"

  # Connectivity check first — a real failure (not "already exists") aborts
  # the shared path so the caller can fall back to standalone.
  kc -n "$AREGISTRY_NS" exec -i "$pri" -c postgres -- \
    psql -tAc 'SELECT 1' </dev/null >/dev/null 2>&1 || return 1

  # Role: create if absent, always (re)assert the password so the persisted
  # secret and the role stay in sync across reruns. ON_ERROR_STOP=0 so the
  # "already exists" notice on CREATE doesn't fail the call.
  kc -n "$AREGISTRY_NS" exec -i "$pri" -c postgres -- \
    psql -v ON_ERROR_STOP=0 \
      -c "CREATE ROLE \"${LITELLM_DB_USER}\" LOGIN PASSWORD '${pass}';" \
      -c "ALTER ROLE \"${LITELLM_DB_USER}\" WITH LOGIN PASSWORD '${pass}';" \
    </dev/null >/dev/null 2>&1 || true

  # Database: CREATE DATABASE can't run inside a transaction/DO block, so
  # guard with an existence check.
  exists="$(kc -n "$AREGISTRY_NS" exec -i "$pri" -c postgres -- \
    psql -tAc "SELECT 1 FROM pg_database WHERE datname='${LITELLM_DB_NAME}'" </dev/null 2>/dev/null | tr -d '[:space:]')"
  if [[ "$exists" != "1" ]]; then
    kc -n "$AREGISTRY_NS" exec -i "$pri" -c postgres -- \
      psql -c "CREATE DATABASE \"${LITELLM_DB_NAME}\" OWNER \"${LITELLM_DB_USER}\";" \
      </dev/null >/dev/null 2>&1 || return 1
  fi

  # Mirror the creds into a namespace-local Secret for the chart.
  kc create namespace "$LITELLM_NS" --dry-run=client -o yaml 2>/dev/null | kc apply -f - >/dev/null 2>&1
  kc -n "$LITELLM_NS" create secret generic "$LITELLM_DB_SECRET" \
    --from-literal=username="$LITELLM_DB_USER" \
    --from-literal=password="$pass" \
    --dry-run=client -o yaml 2>/dev/null | kc apply -f - >/dev/null 2>&1 || return 1
}

# ============================================================================
# Installer — called from cmd_up. NON-FATAL: a slow image pull or a flaky
# chart must never abort `up`, so every failure path warns and returns 0.
# ============================================================================

install_litellm() {
  (( ${INSTALL_LITELLM:-1} )) || { log "skipping LiteLLM (INSTALL_LITELLM=0; pass --with-litellm or set INSTALL_LITELLM=1 to enable)"; return 0; }

  local key; key="$(_litellm_master_key)"

  # Decide the DB backend. auto/shared reuse the platform's existing CNPG
  # Postgres (a `litellm` db on the agentregistry cluster — no second pod);
  # both fall back to the chart's bundled standalone Postgres if that
  # cluster isn't available, so `up` never aborts on the DB choice.
  local use_shared=0
  case "$LITELLM_DB_MODE" in
    standalone) ;;
    shared|auto|*)
      if _litellm_shared_pg_ready && _litellm_provision_shared_db; then
        use_shared=1
      elif [[ "$LITELLM_DB_MODE" == "shared" ]]; then
        warn "LiteLLM: shared CNPG cluster unavailable — falling back to the chart's standalone Postgres"
      else
        log "LiteLLM: no shared CNPG cluster (agentregistry off?) — using the chart's bundled standalone Postgres"
      fi ;;
  esac

  log "installing LiteLLM proxy (ns: $LITELLM_NS, chart ${LITELLM_CHART}${LITELLM_CHART_VERSION:+ @ $LITELLM_CHART_VERSION}, db: $( ((use_shared)) && echo "CNPG (shared)" || echo standalone))"

  # No --wait on the helm step: the image can take a few minutes on first
  # pull. We bound readiness explicitly below.
  local -a args=(
    helm upgrade --install "$LITELLM_RELEASE" "$LITELLM_CHART"
      --namespace "$LITELLM_NS" --create-namespace
      --set "masterkey=${key}"
      --set "image.tag=${LITELLM_IMAGE_TAG}"
      --set "service.type=ClusterIP"
      --set "service.port=${LITELLM_PORT}"
      --set "replicaCount=1"
      --set "resources.requests.cpu=50m"
      --set "resources.requests.memory=512Mi"
      --set "resources.limits.memory=2Gi"
  )
  if (( use_shared )); then
    # Point LiteLLM at the litellm db on the shared CNPG cluster, with creds
    # from the namespace-local secret we mirrored. db.endpoint carries the
    # host only — the chart assumes 5432, which is the CNPG -rw service port.
    args+=(
      --set "db.deployStandalone=false"
      --set "db.useExisting=true"
      --set "db.endpoint=${AREGISTRY_PG_CLUSTER}-rw.${AREGISTRY_NS}.svc.cluster.local"
      --set "db.database=${LITELLM_DB_NAME}"
      --set "db.secret.name=${LITELLM_DB_SECRET}"
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

  if ! helm_install "LiteLLM helm install (first run can take a few min)" "${args[@]}"; then
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

# "CNPG (shared)" when LiteLLM points at the shared cluster (detected by the
# mirrored creds secret), else "standalone".
_litellm_db_backend() {
  if kc -n "$LITELLM_NS" get secret "$LITELLM_DB_SECRET" >/dev/null 2>&1; then
    echo "CNPG (shared)"
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
  Database:     ${db}$( [[ "$db" == "CNPG (shared)" ]] && echo " — db '${LITELLM_DB_NAME}' on the shared cluster ${AREGISTRY_PG_CLUSTER:-} (${AREGISTRY_NS:-}); creds in secret ${LITELLM_NS}/${LITELLM_DB_SECRET}" )
  Try it:       curl -sk https://${LITELLM_HOST}:${SANDBOX_HTTPS_PORT}/v1/models \\
                  -H "Authorization: Bearer ${key:-<master-key>}"
  Add models:   via the Admin UI, or set proxy_config.model_list and re-run 'sandboxctl up'.
EOF
}
