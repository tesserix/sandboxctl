# shellcheck shell=bash
# lib/tyk.sh — Tyk OSS API Gateway (part of the AI Agentic Gateway)
#
# Tyk (https://tyk.io) is a full-featured open-source API gateway. In the
# AI Agentic Gateway line-up it's the "manage/secure my API surface"
# option — rate-limiting, auth, quotas, versioning in front of any
# upstream (including the LiteLLM / Portkey proxies above).
#
# What this lib installs (idempotent):
#   1. A lightweight redis:7-alpine Deployment + Service (tyk-redis-master)
#      in the Tyk namespace. Tyk requires Redis; rather than pull in the
#      Bitnami subchart (heavier + image-availability churn) we run a tiny
#      single-replica Redis with no auth — fine for a local sandbox.
#   2. The official tyk-helm/tyk-oss chart, pointed at that Redis, with a
#      persisted APISecret (the gateway admin/control-API secret).
#   3. An Istio VirtualService at https://tyk.${SANDBOX_DOMAIN} fronting
#      the gateway (Service gateway-svc-...-tyk-gateway, port 8080).
#
# NOTE on the UI: the Tyk *Dashboard* (the graphical control plane) is a
# licensed component and is NOT part of Tyk OSS. The OSS gateway is driven
# by its control API + API-definition files. This lib exposes the gateway
# (its /hello health surface answers on the host) so it can be tested
# alongside the other gateways; the licensed Dashboard can be layered on
# later by anyone with a Tyk license.
#
# Sourced by sandbox.sh; assumes the common globals + helpers are set.
#
# Public functions called from sandbox.sh:
#   install_tyk              — full install (gated on INSTALL_TYK)
#   install_tyk_routes       — Istio VirtualService for the gateway
#   tyk_present              — predicate for route/host/status gating
#   tyk_status               — one-line status for cmd_status
#   tyk_print_creds          — connection details for cmd_creds

# ============================================================================
# Configuration
# ============================================================================

TYK_NS="${TYK_NS:-tyk}"
TYK_RELEASE="${TYK_RELEASE:-tyk-oss}"
TYK_REPO_NAME="${TYK_REPO_NAME:-tyk-helm}"
TYK_REPO_URL="${TYK_REPO_URL:-https://helm.tyk.io/public/helm/charts/}"
TYK_CHART="${TYK_CHART:-tyk-helm/tyk-oss}"
# Empty by default: helm installs the newest chart in the repo. Pin for
# reproducibility (e.g. TYK_CHART_VERSION=3.x).
TYK_CHART_VERSION="${TYK_CHART_VERSION:-}"
TYK_HOST="${TYK_HOST:-tyk.${SANDBOX_DOMAIN}}"
# The tyk-oss chart names the gateway Service "gateway-svc-<release>-tyk-gateway".
TYK_GW_SVC="${TYK_GW_SVC:-gateway-svc-${TYK_RELEASE}-tyk-gateway}"
TYK_GW_PORT="${TYK_GW_PORT:-8080}"

# Bundled Redis (sandbox-only, no auth).
TYK_REDIS_NAME="${TYK_REDIS_NAME:-tyk-redis-master}"
TYK_REDIS_IMAGE="${TYK_REDIS_IMAGE:-redis:7-alpine}"

# APISecret (gateway control-API secret) persisted across reruns.
TYK_SECRET_FILE="${TYK_SECRET_FILE:-${SANDBOX_STATE_DIR}/tyk-api-secret}"

# Gate: opt-in (heavier add-on — gateway + bundled Redis). Enable with
# `up --with-tyk` or INSTALL_TYK=1.
INSTALL_TYK="${INSTALL_TYK:-0}"

# ============================================================================
# Predicate
# ============================================================================

tyk_present() {
  kc get ns "$TYK_NS" >/dev/null 2>&1
}

# Read-or-generate the persisted APISecret (one-shot openssl — see the
# SIGPIPE note in install_gitea for why not `tr | head`).
_tyk_api_secret() {
  if [[ ! -s "$TYK_SECRET_FILE" ]]; then
    mkdir -p "$SANDBOX_STATE_DIR"
    openssl rand -hex 16 > "$TYK_SECRET_FILE"
    chmod 600 "$TYK_SECRET_FILE"
  fi
  cat "$TYK_SECRET_FILE"
}

# Tiny single-replica Redis for the gateway's storage. No auth, no PVC —
# sandbox-only. Applied before the chart so global.redis.addrs resolves.
_install_tyk_redis() {
  kc apply -f - <<EOF >/dev/null 2>&1
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${TYK_REDIS_NAME}
  namespace: ${TYK_NS}
  labels: { app: ${TYK_REDIS_NAME} }
spec:
  replicas: 1
  selector:
    matchLabels: { app: ${TYK_REDIS_NAME} }
  template:
    metadata:
      labels: { app: ${TYK_REDIS_NAME} }
    spec:
      containers:
        - name: redis
          image: ${TYK_REDIS_IMAGE}
          imagePullPolicy: IfNotPresent
          ports:
            - { name: redis, containerPort: 6379 }
          readinessProbe:
            tcpSocket: { port: 6379 }
            initialDelaySeconds: 3
            periodSeconds: 5
          resources:
            requests: { cpu: 25m, memory: 32Mi }
            limits:   { cpu: 250m, memory: 256Mi }
---
apiVersion: v1
kind: Service
metadata:
  name: ${TYK_REDIS_NAME}
  namespace: ${TYK_NS}
  labels: { app: ${TYK_REDIS_NAME} }
spec:
  type: ClusterIP
  selector: { app: ${TYK_REDIS_NAME} }
  ports:
    - { name: redis, port: 6379, targetPort: 6379 }
EOF
}

# ============================================================================
# Installer — called from cmd_up. NON-FATAL.
# ============================================================================

install_tyk() {
  (( ${INSTALL_TYK:-1} )) || { log "skipping Tyk OSS gateway (INSTALL_TYK=0)"; return 0; }

  log "installing Tyk OSS gateway (ns: $TYK_NS, chart ${TYK_CHART}${TYK_CHART_VERSION:+ @ $TYK_CHART_VERSION})"

  if ! kc create namespace "$TYK_NS" --dry-run=client -o yaml 2>/dev/null | kc apply -f - >/dev/null 2>&1; then
    warn "Tyk: could not ensure namespace ${TYK_NS} — skipping"
    return 0
  fi

  if ! _install_tyk_redis; then
    warn "Tyk: bundled Redis apply failed — skipping gateway install."
    return 0
  fi
  with_spinner "waiting for Tyk Redis to become Ready" \
    kc -n "$TYK_NS" rollout status deploy/"$TYK_REDIS_NAME" --timeout=120s || \
    warn "Tyk Redis not Ready yet — the gateway install will retry the connection"

  local secret; secret="$(_tyk_api_secret)"
  local redis_addr="${TYK_REDIS_NAME}.${TYK_NS}.svc.cluster.local:6379"

  helm repo add "$TYK_REPO_NAME" "$TYK_REPO_URL" >/dev/null 2>&1 || true
  if ! helm repo update "$TYK_REPO_NAME" >/dev/null 2>&1; then
    warn "helm repo update ${TYK_REPO_NAME} failed — retrying with full refresh"
    helm repo update >/dev/null 2>&1 || true
  fi

  local -a args=(
    helm upgrade --install "$TYK_RELEASE" "$TYK_CHART"
      --namespace "$TYK_NS" --create-namespace
      --set "global.secrets.APISecret=${secret}"
      --set "global.storageType=redis"
      --set "global.redis.addrs={${redis_addr}}"
      --set "tyk-gateway.gateway.resources.requests.cpu=25m"
      --set "tyk-gateway.gateway.resources.requests.memory=96Mi"
      --set "tyk-gateway.gateway.resources.limits.memory=256Mi"
  )
  [[ -n "$TYK_CHART_VERSION" ]] && args+=(--version "$TYK_CHART_VERSION")

  if ! helm_install "Tyk OSS helm install (typically 1-3 min)" "${args[@]}"; then
    warn "Tyk helm install failed — skipping; the rest of the sandbox is unaffected."
    warn "debug: helm -n ${TYK_NS} status ${TYK_RELEASE} ; kc -n ${TYK_NS} get pods"
    return 0
  fi

  if with_spinner "waiting for Tyk gateway to become Ready" \
       kc -n "$TYK_NS" wait --for=condition=available --timeout=240s deployment --all; then
    ok "Tyk ready (gateway: https://${TYK_HOST}:${SANDBOX_HTTPS_PORT})"
  else
    warn "Tyk not Ready within 4 min — check 'kc -n ${TYK_NS} get pods'"
  fi
}

# ============================================================================
# Istio route — fronts the Tyk gateway.
# ============================================================================

install_tyk_routes() {
  tyk_present || return 0
  kc apply -f - <<EOF >/dev/null
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: tyk
  namespace: ${TYK_NS}
spec:
  hosts: ["${TYK_HOST}"]
  gateways: ["${ISTIO_INGRESS_NS}/sandbox-gateway"]
  http:
    - route:
        - destination:
            host: ${TYK_GW_SVC}.${TYK_NS}.svc.cluster.local
            port: { number: ${TYK_GW_PORT} }
EOF
}

# ============================================================================
# Status reporter
# ============================================================================

tyk_status() {
  tyk_present || { echo "tyk: not installed"; return; }
  # Match any Available deployment that looks like the gateway; the chart's
  # deployment name is "gateway-<release>-tyk-gateway".
  local ready
  ready="$(kc -n "$TYK_NS" get deploy -l app.kubernetes.io/name=tyk-gateway \
    -o jsonpath='{.items[*].status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
  if [[ "$ready" == *"True"* ]]; then
    echo "tyk: ok (https://${TYK_HOST}:${SANDBOX_HTTPS_PORT}, OSS API gateway)"
  else
    echo "tyk: installed but not Ready — kc -n ${TYK_NS} get pods"
  fi
}

# ============================================================================
# Mac-side connection hint
# ============================================================================

tyk_print_creds() {
  tyk_present || return 0
  local secret=""; [[ -s "$TYK_SECRET_FILE" ]] && secret="$(cat "$TYK_SECRET_FILE")"
  cat <<EOF
Tyk OSS (open-source API gateway)
  Gateway:      https://${TYK_HOST}:${SANDBOX_HTTPS_PORT}
  Health:       https://${TYK_HOST}:${SANDBOX_HTTPS_PORT}/hello
  Control API:  send header  x-tyk-authorization: ${secret:-<run 'sandboxctl up'>}
  Secret file:  ${TYK_SECRET_FILE}
  In-cluster:   http://${TYK_GW_SVC}.${TYK_NS}.svc.cluster.local:${TYK_GW_PORT}
  UI:           the graphical Tyk Dashboard is a licensed (non-OSS) add-on.
                The OSS gateway is driven by its control API + API-definition files.
  Try it:       curl -sk https://${TYK_HOST}:${SANDBOX_HTTPS_PORT}/hello
EOF
}
