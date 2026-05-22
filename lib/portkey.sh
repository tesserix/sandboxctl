# shellcheck shell=bash
# lib/portkey.sh — Portkey AI Gateway (part of the AI Agentic Gateway)
#
# Portkey's open-source gateway (https://github.com/portkey-ai/gateway) is
# a fast, OpenAI-compatible router for 250+ LLMs with retries, fallbacks,
# load-balancing and a built-in console UI. It's a single stateless Node
# service — no database — so we deploy it from a raw Deployment + Service
# rather than a Helm chart (upstream ships no chart).
#
# What this lib installs (idempotent):
#   1. A Deployment running portkeyai/gateway on container port 8787.
#   2. A ClusterIP Service in front of it.
#   3. An Istio VirtualService at https://portkey.${SANDBOX_DOMAIN}.
#      The interactive console UI is served at /public/, the API at /v1.
#
# Sourced by sandbox.sh; assumes the common globals + helpers are set.
#
# Public functions called from sandbox.sh:
#   install_portkey          — full install (gated on INSTALL_PORTKEY)
#   install_portkey_routes   — Istio VirtualService for the gateway + UI
#   portkey_present          — predicate for route/host/status gating
#   portkey_status           — one-line status for cmd_status
#   portkey_print_creds      — connection details for cmd_creds

# ============================================================================
# Configuration
# ============================================================================

PORTKEY_NS="${PORTKEY_NS:-portkey}"
PORTKEY_NAME="${PORTKEY_NAME:-portkey-gateway}"
PORTKEY_IMAGE="${PORTKEY_IMAGE:-portkeyai/gateway:latest}"
PORTKEY_HOST="${PORTKEY_HOST:-portkey.${SANDBOX_DOMAIN}}"
PORTKEY_PORT="${PORTKEY_PORT:-8787}"

# Gate: default-on as part of the AI Agentic Gateway.
INSTALL_PORTKEY="${INSTALL_PORTKEY:-1}"

# ============================================================================
# Predicate
# ============================================================================

portkey_present() {
  kc get ns "$PORTKEY_NS" >/dev/null 2>&1
}

# ============================================================================
# Installer — called from cmd_up. NON-FATAL.
# ============================================================================

install_portkey() {
  (( ${INSTALL_PORTKEY:-1} )) || { log "skipping Portkey gateway (INSTALL_PORTKEY=0)"; return 0; }

  log "installing Portkey AI Gateway (ns: $PORTKEY_NS, image $PORTKEY_IMAGE)"

  if ! kc create namespace "$PORTKEY_NS" --dry-run=client -o yaml 2>/dev/null | kc apply -f - >/dev/null 2>&1; then
    warn "Portkey: could not ensure namespace ${PORTKEY_NS} — skipping"
    return 0
  fi

  # Stateless Deployment + Service. A TCP readiness probe (not httpGet) so
  # we don't couple readiness to a specific health path that may change
  # between gateway releases.
  if ! kc apply -f - <<EOF >/dev/null 2>&1
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${PORTKEY_NAME}
  namespace: ${PORTKEY_NS}
  labels: { app: ${PORTKEY_NAME} }
spec:
  replicas: 1
  selector:
    matchLabels: { app: ${PORTKEY_NAME} }
  template:
    metadata:
      labels: { app: ${PORTKEY_NAME} }
    spec:
      containers:
        - name: gateway
          image: ${PORTKEY_IMAGE}
          imagePullPolicy: IfNotPresent
          ports:
            - { name: http, containerPort: ${PORTKEY_PORT} }
          readinessProbe:
            tcpSocket: { port: ${PORTKEY_PORT} }
            initialDelaySeconds: 5
            periodSeconds: 5
          livenessProbe:
            tcpSocket: { port: ${PORTKEY_PORT} }
            initialDelaySeconds: 15
            periodSeconds: 20
          resources:
            requests: { cpu: 25m, memory: 96Mi }
            limits:   { cpu: 300m, memory: 256Mi }
---
apiVersion: v1
kind: Service
metadata:
  name: ${PORTKEY_NAME}
  namespace: ${PORTKEY_NS}
  labels: { app: ${PORTKEY_NAME} }
spec:
  type: ClusterIP
  selector: { app: ${PORTKEY_NAME} }
  ports:
    - { name: http, port: ${PORTKEY_PORT}, targetPort: ${PORTKEY_PORT} }
EOF
  then
    warn "Portkey: applying Deployment/Service failed — skipping; the rest of the sandbox is unaffected."
    return 0
  fi

  if with_spinner "waiting for Portkey gateway to become Ready" \
       kc -n "$PORTKEY_NS" rollout status deploy/"$PORTKEY_NAME" --timeout=180s; then
    ok "Portkey ready (UI: https://${PORTKEY_HOST}:${SANDBOX_HTTPS_PORT}/public/)"
  else
    warn "Portkey not Ready within 3 min — check 'kc -n ${PORTKEY_NS} get pods'"
  fi
}

# ============================================================================
# Istio route — host root serves both the /public/ console UI and the /v1 API.
# ============================================================================

install_portkey_routes() {
  portkey_present || return 0
  kc apply -f - <<EOF >/dev/null
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: portkey
  namespace: ${PORTKEY_NS}
spec:
  hosts: ["${PORTKEY_HOST}"]
  gateways: ["${ISTIO_INGRESS_NS}/sandbox-gateway"]
  http:
    - route:
        - destination:
            host: ${PORTKEY_NAME}.${PORTKEY_NS}.svc.cluster.local
            port: { number: ${PORTKEY_PORT} }
EOF
}

# ============================================================================
# Status reporter
# ============================================================================

portkey_status() {
  portkey_present || { echo "portkey: not installed"; return; }
  local ready
  ready="$(kc -n "$PORTKEY_NS" get deploy "$PORTKEY_NAME" \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
  if [[ "$ready" == "True" ]]; then
    echo "portkey: ok (https://${PORTKEY_HOST}:${SANDBOX_HTTPS_PORT}/public/, OSS AI gateway)"
  else
    echo "portkey: installed but not Ready — kc -n ${PORTKEY_NS} get pods"
  fi
}

# ============================================================================
# Mac-side connection hint
# ============================================================================

portkey_print_creds() {
  portkey_present || return 0
  cat <<EOF
Portkey AI Gateway (OSS — routing, retries, fallbacks for 250+ LLMs)
  Console UI:   https://${PORTKEY_HOST}:${SANDBOX_HTTPS_PORT}/public/
  API base:     https://${PORTKEY_HOST}:${SANDBOX_HTTPS_PORT}/v1
  Auth:         none in the OSS gateway — provider creds are passed per-request
                via headers (x-portkey-provider + Authorization).
  In-cluster:   http://${PORTKEY_NAME}.${PORTKEY_NS}.svc.cluster.local:${PORTKEY_PORT}
  Try it:       curl -sk https://${PORTKEY_HOST}:${SANDBOX_HTTPS_PORT}/v1/chat/completions \\
                  -H 'x-portkey-provider: openai' \\
                  -H 'Authorization: Bearer \$OPENAI_API_KEY' \\
                  -H 'Content-Type: application/json' \\
                  -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"hi"}]}'
EOF
}
