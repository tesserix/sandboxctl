# shellcheck shell=bash
# lib/mlflow.sh — MLflow tracking server + UI (part of the AI Agentic Gateway)
#
# MLflow (https://github.com/mlflow/mlflow) is the experiment-tracking,
# model-registry and observability layer for the AI stack. Its web UI is
# the surface most users want, so this lib stands up a tracking server and
# routes its UI at https://mlflow.${SANDBOX_DOMAIN}.
#
# What this lib installs (idempotent):
#   1. The community-charts/mlflow Helm chart. It defaults to a SQLite
#      backend + filesystem artifact store, so it runs standalone with no
#      external Postgres/S3 — perfect for a try-it sandbox. (Tracking data
#      is ephemeral by default; set MLFLOW_* / chart values for a durable
#      Postgres + object-store backend when you outgrow the sandbox.)
#   2. An Istio VirtualService fronting the UI (chart Service port 80 ->
#      container 5000).
#
# Sourced by sandbox.sh; assumes the common globals + helpers are set.
#
# Public functions called from sandbox.sh:
#   install_mlflow           — full install (gated on INSTALL_MLFLOW)
#   install_mlflow_routes    — Istio VirtualService for the UI
#   mlflow_present           — predicate for route/host/status gating
#   mlflow_status            — one-line status for cmd_status
#   mlflow_print_creds       — connection details for cmd_creds

# ============================================================================
# Configuration
# ============================================================================

MLFLOW_NS="${MLFLOW_NS:-mlflow}"
MLFLOW_RELEASE="${MLFLOW_RELEASE:-mlflow}"
MLFLOW_REPO_NAME="${MLFLOW_REPO_NAME:-community-charts}"
MLFLOW_REPO_URL="${MLFLOW_REPO_URL:-https://community-charts.github.io/helm-charts}"
MLFLOW_CHART="${MLFLOW_CHART:-community-charts/mlflow}"
# Empty by default: helm installs the newest chart in the repo. Pin for
# reproducibility (e.g. MLFLOW_CHART_VERSION=0.7.x).
MLFLOW_CHART_VERSION="${MLFLOW_CHART_VERSION:-}"
MLFLOW_HOST="${MLFLOW_HOST:-mlflow.${SANDBOX_DOMAIN}}"
# chart Service listens on 80 and forwards to the container's 5000.
MLFLOW_SVC_PORT="${MLFLOW_SVC_PORT:-80}"

# Gate: default-on as part of the AI Agentic Gateway.
INSTALL_MLFLOW="${INSTALL_MLFLOW:-1}"

# ============================================================================
# Predicate
# ============================================================================

mlflow_present() {
  kc get ns "$MLFLOW_NS" >/dev/null 2>&1
}

# ============================================================================
# Installer — called from cmd_up. NON-FATAL.
# ============================================================================

install_mlflow() {
  (( ${INSTALL_MLFLOW:-1} )) || { log "skipping MLflow (INSTALL_MLFLOW=0)"; return 0; }

  log "installing MLflow tracking server + UI (ns: $MLFLOW_NS, chart ${MLFLOW_CHART}${MLFLOW_CHART_VERSION:+ @ $MLFLOW_CHART_VERSION})"

  helm repo add "$MLFLOW_REPO_NAME" "$MLFLOW_REPO_URL" >/dev/null 2>&1 || true
  if ! helm repo update "$MLFLOW_REPO_NAME" >/dev/null 2>&1; then
    warn "helm repo update ${MLFLOW_REPO_NAME} failed — retrying with full refresh"
    helm repo update >/dev/null 2>&1 || true
  fi

  local -a args=(
    helm upgrade --install "$MLFLOW_RELEASE" "$MLFLOW_CHART"
      --namespace "$MLFLOW_NS" --create-namespace
      --set "replicaCount=1"
      --set "service.type=ClusterIP"
      --set "service.port=${MLFLOW_SVC_PORT}"
  )
  [[ -n "$MLFLOW_CHART_VERSION" ]] && args+=(--version "$MLFLOW_CHART_VERSION")

  if ! helm_install "MLflow helm install (typically 1-3 min)" "${args[@]}"; then
    warn "MLflow helm install failed — skipping; the rest of the sandbox is unaffected."
    warn "debug: helm -n ${MLFLOW_NS} status ${MLFLOW_RELEASE} ; kc -n ${MLFLOW_NS} get pods"
    return 0
  fi

  if with_spinner "waiting for MLflow to become Ready" \
       kc -n "$MLFLOW_NS" wait --for=condition=available --timeout=240s deployment --all; then
    ok "MLflow ready (UI: https://${MLFLOW_HOST}:${SANDBOX_HTTPS_PORT})"
  else
    warn "MLflow not Ready within 4 min — check 'kc -n ${MLFLOW_NS} get pods'"
  fi
}

# ============================================================================
# Istio route — fronts the MLflow web UI (served at the host root).
# ============================================================================

install_mlflow_routes() {
  mlflow_present || return 0
  kc apply -f - <<EOF >/dev/null
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: mlflow
  namespace: ${MLFLOW_NS}
spec:
  hosts: ["${MLFLOW_HOST}"]
  gateways: ["${ISTIO_INGRESS_NS}/sandbox-gateway"]
  http:
    - route:
        - destination:
            host: ${MLFLOW_RELEASE}.${MLFLOW_NS}.svc.cluster.local
            port: { number: ${MLFLOW_SVC_PORT} }
EOF
}

# ============================================================================
# Status reporter
# ============================================================================

mlflow_status() {
  mlflow_present || { echo "mlflow: not installed"; return; }
  local ready
  ready="$(kc -n "$MLFLOW_NS" get deploy "$MLFLOW_RELEASE" \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
  if [[ "$ready" == "True" ]]; then
    echo "mlflow: ok (https://${MLFLOW_HOST}:${SANDBOX_HTTPS_PORT}, experiment tracking + UI)"
  else
    echo "mlflow: installed but not Ready — kc -n ${MLFLOW_NS} get pods"
  fi
}

# ============================================================================
# Mac-side connection hint
# ============================================================================

mlflow_print_creds() {
  mlflow_present || return 0
  cat <<EOF
MLflow (experiment tracking + model registry + UI)
  UI:           https://${MLFLOW_HOST}:${SANDBOX_HTTPS_PORT}
  Tracking URI: https://${MLFLOW_HOST}:${SANDBOX_HTTPS_PORT}
  In-cluster:   http://${MLFLOW_RELEASE}.${MLFLOW_NS}.svc.cluster.local:${MLFLOW_SVC_PORT}
  Auth:         none by default (open UI) — enable basic auth via chart values.
  Note:         default backend is SQLite + filesystem artifacts (ephemeral).
                Point at a durable Postgres + object store via chart values.
  Try it:       export MLFLOW_TRACKING_INSECURE_TLS=true
                export MLFLOW_TRACKING_URI=https://${MLFLOW_HOST}:${SANDBOX_HTTPS_PORT}
                mlflow experiments search
EOF
}
