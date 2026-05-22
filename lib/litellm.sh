# shellcheck shell=bash
# lib/litellm.sh — LiteLLM proxy/gateway (part of the AI Agentic Gateway)
#
# LiteLLM is an OpenAI-compatible proxy that fronts 100+ LLM providers
# behind one API + key. This lib deploys it into the sandbox so the user
# has a working LLM gateway to point apps at on day one.
#
# What this lib installs (idempotent):
#   1. The official litellm-helm OCI chart, with its bundled standalone
#      PostgreSQL enabled (db.deployStandalone=true) — LiteLLM needs a DB
#      for its key/spend/model store, so we let the chart manage one
#      rather than wiring it to the platform's CNPG (keeps the add-on
#      self-contained and removable with its namespace).
#   2. A random master key persisted to the state dir so it survives
#      reruns of `up` / `restart` (same convention as the Gitea password).
#   3. An Istio VirtualService at https://litellm.${SANDBOX_DOMAIN}.
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
# Installer — called from cmd_up. NON-FATAL: a slow image pull or a flaky
# chart must never abort `up`, so every failure path warns and returns 0.
# ============================================================================

install_litellm() {
  (( ${INSTALL_LITELLM:-1} )) || { log "skipping LiteLLM (INSTALL_LITELLM=0)"; return 0; }

  local key; key="$(_litellm_master_key)"

  log "installing LiteLLM proxy (ns: $LITELLM_NS, chart ${LITELLM_CHART}${LITELLM_CHART_VERSION:+ @ $LITELLM_CHART_VERSION})"

  # No --wait on the helm step: the image + bundled Postgres can take a
  # few minutes on first pull. We bound readiness explicitly below.
  local -a args=(
    helm upgrade --install "$LITELLM_RELEASE" "$LITELLM_CHART"
      --namespace "$LITELLM_NS" --create-namespace
      --set "masterkey=${key}"
      --set "db.deployStandalone=true"
      --set "db.useExisting=false"
      --set "service.type=ClusterIP"
      --set "service.port=${LITELLM_PORT}"
  )
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

litellm_status() {
  litellm_present || { echo "litellm: not installed"; return; }
  local ready
  ready="$(kc -n "$LITELLM_NS" get deploy "$LITELLM_RELEASE" \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
  if [[ "$ready" == "True" ]]; then
    echo "litellm: ok (https://${LITELLM_HOST}:${SANDBOX_HTTPS_PORT}, OpenAI-compatible proxy)"
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
  cat <<EOF
LiteLLM (OpenAI-compatible LLM proxy)
  URL:          https://${LITELLM_HOST}:${SANDBOX_HTTPS_PORT}
  Admin UI:     https://${LITELLM_HOST}:${SANDBOX_HTTPS_PORT}/ui
  Master key:   ${key:-<run 'sandboxctl up' to generate>}
  Key file:     ${LITELLM_KEY_FILE}
  In-cluster:   http://${LITELLM_RELEASE}.${LITELLM_NS}.svc.cluster.local:${LITELLM_PORT}
  Try it:       curl -sk https://${LITELLM_HOST}:${SANDBOX_HTTPS_PORT}/v1/models \\
                  -H "Authorization: Bearer ${key:-<master-key>}"
  Add models:   via the Admin UI, or set proxy_config.model_list and re-run 'sandboxctl up'.
EOF
}
