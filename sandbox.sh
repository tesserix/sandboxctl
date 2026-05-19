#!/usr/bin/env bash
set -euo pipefail

# sandbox.sh — local kind cluster bootstrapped with Argo CD + Kargo + Istio
# ambient mesh, behind an Istio gateway. Idempotent: re-running 'up' is safe.

# ============================================================================
# Configuration
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIND_CONFIG="${SCRIPT_DIR}/kind-config.yaml"

WILDCARD_TLS_SECRET="${WILDCARD_TLS_SECRET:-sandbox-wildcard-tls}"
ROOT_CA_SECRET="${ROOT_CA_SECRET:-sandbox-root-ca}"

CLUSTER_NAME="${SANDBOX_CLUSTER_NAME:-sandboxctl}"
ARGOCD_NS="${ARGOCD_NS:-argocd}"
KARGO_NS="${KARGO_NS:-kargo}"
DEMO_NS="${DEMO_NS:-demo-app}"
ISTIO_SYSTEM_NS="${ISTIO_SYSTEM_NS:-istio-system}"
ISTIO_INGRESS_NS="${ISTIO_INGRESS_NS:-istio-ingress}"
LEGACY_INGRESS_NS="${LEGACY_INGRESS_NS:-ingress-nginx}"
LEGACY_TRAEFIK_NS="${LEGACY_TRAEFIK_NS:-traefik}"
LEGACY_GUESTBOOK_NS="${LEGACY_GUESTBOOK_NS:-guestbook}"

ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-9.5.13}"
KARGO_CHART_VERSION="${KARGO_CHART_VERSION:-1.1.1}"
CERT_MANAGER_NS="${CERT_MANAGER_NS:-cert-manager}"
CERT_MANAGER_CHART_VERSION="${CERT_MANAGER_CHART_VERSION:-v1.16.2}"
ISTIO_CHART_VERSION="${ISTIO_CHART_VERSION:-1.29.2}"
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-kindest/node:v1.35.0}"

# kagent: agentic-AI controller + UI. Defaults to Ollama on the Mac
# (host.docker.internal:11434) so no cloud API key is needed; user just
# needs `brew install ollama && ollama serve && ollama pull llama3.2`.
KAGENT_NS="${KAGENT_NS:-kagent}"
KAGENT_CHART_VERSION="${KAGENT_CHART_VERSION:-0.9.4}"
KAGENT_OLLAMA_HOST="${KAGENT_OLLAMA_HOST:-host.docker.internal:11434}"
KAGENT_OLLAMA_MODEL="${KAGENT_OLLAMA_MODEL:-llama3.2}"

SANDBOX_DOMAIN="${SANDBOX_DOMAIN:-sandbox.app}"

# Demo app source. Argo CD watches this repo + path and reconciles the
# Deployment/Service/Namespace into the cluster. Override DEMO_APP_REPO_URL
# to point at your fork if you want to tweak the demo without forking the
# whole tool.
DEMO_APP_REPO_URL="${DEMO_APP_REPO_URL:-https://github.com/tesserix/sandboxctl.git}"
DEMO_APP_REPO_REVISION="${DEMO_APP_REPO_REVISION:-main}"
ARGO_HOST="argo.${SANDBOX_DOMAIN}"
KARGO_HOST="kargo.${SANDBOX_DOMAIN}"
DEMO_HOST="demo-app.${SANDBOX_DOMAIN}"
KAGENT_HOST="kagent.${SANDBOX_DOMAIN}"
ROOT_CA_CN="${SANDBOX_DOMAIN} sandbox root CA"

# Mac↔cluster routing: a LaunchAgent runs `kubectl port-forward` to the
# istio-ingress Service. URLs use :8443 because binding :443 on macOS would
# need sudo on every launchd start.
SANDBOX_HTTPS_PORT="${SANDBOX_HTTPS_PORT:-8443}"
SANDBOX_HTTP_PORT="${SANDBOX_HTTP_PORT:-8080}"
SANDBOX_STATE_DIR="${SANDBOX_STATE_DIR:-$HOME/.sandboxctl}"
SANDBOX_STATE_FILE="${SANDBOX_STATE_DIR}/setup.yaml"
SANDBOX_LAUNCHAGENT_DIR="${SANDBOX_LAUNCHAGENT_DIR:-$HOME/Library/LaunchAgents}"
SANDBOX_LAUNCHAGENT_LABEL="${SANDBOX_LAUNCHAGENT_LABEL:-io.github.sandboxctl.portfwd}"
SANDBOX_LAUNCHAGENT_PLIST="${SANDBOX_LAUNCHAGENT_DIR}/${SANDBOX_LAUNCHAGENT_LABEL}.plist"
SANDBOX_PF_LOG="${SANDBOX_STATE_DIR}/portfwd.log"
SANDBOX_HOSTS_MARKER="# managed by sandboxctl (${SANDBOX_DOMAIN})"
SANDBOX_SECRETS_FILE="${SANDBOX_STATE_DIR}/secrets.env"

# Container runtime: podman (default — no Docker Desktop required) or docker.
SANDBOX_RUNTIME="${SANDBOX_RUNTIME:-podman}"
PODMAN_MACHINE_CPUS="${PODMAN_MACHINE_CPUS:-4}"
PODMAN_MACHINE_MEMORY_MIB="${PODMAN_MACHINE_MEMORY_MIB:-6144}"
PODMAN_MACHINE_DISK_GIB="${PODMAN_MACHINE_DISK_GIB:-60}"
case "$SANDBOX_RUNTIME" in
  podman) export KIND_EXPERIMENTAL_PROVIDER=podman ;;
  docker) ;;
  *) echo "ERROR: unsupported SANDBOX_RUNTIME=$SANDBOX_RUNTIME (use podman or docker)" >&2; exit 1 ;;
esac

# Per-install Kargo secrets. Generated on first `up` into $SANDBOX_SECRETS_FILE
# (chmod 600) and reused on subsequent runs so the password sticks across
# restarts. Set KARGO_TOKEN_SIGNING_KEY to pin the JWT signing key.
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

kctx() { echo "kind-$CLUSTER_NAME"; }
kc()   { kubectl --context "$(kctx)" "$@"; }

prime_sudo() {
  if ! sudo -n true 2>/dev/null; then
    log "sudo required for /etc/hosts + macOS keychain trust — you'll be prompted once"
    sudo -v || die "sudo required to configure /etc/hosts and System keychain"
  fi
}

helm_uninstall_if_present() {
  local release="$1" ns="$2"
  if helm status "$release" -n "$ns" >/dev/null 2>&1; then
    log "uninstalling helm release ${ns}/${release}"
    helm uninstall "$release" -n "$ns" >/dev/null 2>&1 || true
  fi
}

# ============================================================================
# Container runtime + cluster predicates
# ============================================================================

require_tools() { need kind; need kubectl; need helm; ensure_runtime; }

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
  # Auto-heal podman if installed-but-unhealthy; only fall back to docker if
  # podman is genuinely absent. macOS docker daemon needs the GUI, so we
  # surface a clear error there rather than trying to start it.
  # shellcheck disable=SC2034  # _attempt is a sentinel loop variable
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

cluster_registered()    { kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; }
cluster_api_reachable() { kc --request-timeout=3s cluster-info >/dev/null 2>&1; }
cluster_node_containers() {
  "$SANDBOX_RUNTIME" ps -a --filter "label=io.x-k8s.kind.cluster=$CLUSTER_NAME" --format '{{.Names}}'
}

cluster_uses_legacy_extra_port_mappings() {
  # Pre-Istio kind-config.yaml mapped host :80/:443/:30080/:30443 via
  # extraPortMappings. Those don't work on macOS+rootful podman; current
  # config has none. Force a recreate if a stale binding is detected.
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

cmd_setup_podman() {
  [[ "$SANDBOX_RUNTIME" == "podman" ]] || die "SANDBOX_RUNTIME=$SANDBOX_RUNTIME — setup-podman only configures the podman runtime"

  if ! command -v podman >/dev/null 2>&1; then
    command -v brew >/dev/null 2>&1 || die "podman not installed and brew is unavailable"
    log "installing podman via brew"
    brew install podman
  fi
  ok "podman: $(podman --version)"

  if ! podman machine list --format '{{.Name}}' 2>/dev/null | grep -q .; then
    log "creating podman-machine-default (rootful, ${PODMAN_MACHINE_CPUS} CPU, ${PODMAN_MACHINE_MEMORY_MIB} MiB, ${PODMAN_MACHINE_DISK_GIB} GiB disk)"
    podman machine init \
      --cpus "$PODMAN_MACHINE_CPUS" \
      --memory "$PODMAN_MACHINE_MEMORY_MIB" \
      --disk-size "$PODMAN_MACHINE_DISK_GIB" \
      --rootful
  fi

  local state rootful mem
  state="$(podman machine inspect --format '{{.State}}' 2>/dev/null || echo unknown)"
  rootful="$(podman machine inspect --format '{{.Rootful}}' 2>/dev/null || echo false)"
  mem="$(podman machine inspect --format '{{.Resources.Memory}}' 2>/dev/null || echo 0)"

  local needs_apply=0
  [[ "$rootful" != "true" ]]                          && needs_apply=1
  [[ "${mem:-0}" -lt "$PODMAN_MACHINE_MEMORY_MIB" ]]  && needs_apply=1

  if [[ "$needs_apply" == "1" ]]; then
    if [[ "$state" == "running" ]]; then
      log "stopping podman machine to apply config changes"
      podman machine stop
      state="stopped"
    fi
    log "configuring podman machine: rootful=true, memory>=${PODMAN_MACHINE_MEMORY_MIB} MiB"
    podman machine set --rootful --memory "$PODMAN_MACHINE_MEMORY_MIB"
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
    return
  fi
  if ! "$SANDBOX_RUNTIME" image exists "$KIND_NODE_IMAGE" >/dev/null 2>&1; then
    log "pre-pulling $KIND_NODE_IMAGE (one-time, ~750 MB — progress below)"
    "$SANDBOX_RUNTIME" pull "$KIND_NODE_IMAGE" || warn "pre-pull failed; kind will retry the pull itself"
  fi
  log "creating kind cluster '$CLUSTER_NAME'"
  kind create cluster --name "$CLUSTER_NAME" --image "$KIND_NODE_IMAGE" --config "$KIND_CONFIG"
}

install_cert_manager() {
  log "installing cert-manager (ns: $CERT_MANAGER_NS, chart $CERT_MANAGER_CHART_VERSION)"
  helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
  helm repo update jetstack >/dev/null
  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace "$CERT_MANAGER_NS" --create-namespace \
    --version "$CERT_MANAGER_CHART_VERSION" \
    --set crds.enabled=true \
    --wait --timeout 5m
  ok "cert-manager ready"
}

install_pki() {
  # PKI bootstrap (all generated inline so the CN tracks $SANDBOX_DOMAIN):
  #
  #   selfsigned-bootstrap → sandbox-root-ca → sandbox-ca → sandbox-wildcard
  #
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
  log "installing Argo CD (ns: $ARGOCD_NS, chart $ARGOCD_CHART_VERSION)"
  helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
  helm repo update argo >/dev/null
  # server.insecure=true makes argocd-server speak HTTP on :80 so the gateway
  # can terminate TLS without re-encrypting upstream.
  helm upgrade --install argocd argo/argo-cd \
    --namespace "$ARGOCD_NS" --create-namespace \
    --version "$ARGOCD_CHART_VERSION" \
    --set 'configs.params.server\.insecure=true' \
    --wait --timeout 10m
  ok "Argo CD ready"
}

install_kargo() {
  log "installing Kargo (ns: $KARGO_NS, chart $KARGO_CHART_VERSION)"
  helm upgrade --install kargo oci://ghcr.io/akuity/kargo-charts/kargo \
    --namespace "$KARGO_NS" --create-namespace \
    --version "$KARGO_CHART_VERSION" \
    --set api.adminAccount.passwordHash="$KARGO_ADMIN_PASSWORD_HASH" \
    --set api.adminAccount.tokenSigningKey="$KARGO_TOKEN_SIGNING_KEY" \
    --wait --timeout 10m
  ok "Kargo ready"
}

install_demo_app() {
  log "registering demo app with Argo CD (sync from ${DEMO_APP_REPO_URL}@${DEMO_APP_REPO_REVISION})"
  # The demo app is deployed *only* via Argo CD so the UI shows GitOps in
  # action. The Application points at this repo's manifests/demo-app
  # directory; Argo clones, applies, and self-heals. CreateNamespace=true
  # lets Argo own the demo namespace too.
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

install_kagent() {
  # kagent — agentic AI controller + UI. Defaults to Ollama as the LLM
  # provider so the install is self-contained: no cloud API key required,
  # just `ollama serve` running on the Mac. The pod reaches the host's
  # Ollama via the kind/podman-injected `host.docker.internal` DNS name.
  log "installing kagent (ns: $KAGENT_NS, chart $KAGENT_CHART_VERSION) — provider: Ollama at ${KAGENT_OLLAMA_HOST}"

  # CRDs ship as a separate chart and must land before the main chart.
  helm upgrade --install kagent-crds oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds \
    --namespace "$KAGENT_NS" --create-namespace \
    --version "$KAGENT_CHART_VERSION" \
    --wait --timeout 5m

  helm upgrade --install kagent oci://ghcr.io/kagent-dev/kagent/helm/kagent \
    --namespace "$KAGENT_NS" \
    --version "$KAGENT_CHART_VERSION" \
    --set 'providers.default=ollama' \
    --set "providers.ollama.model=${KAGENT_OLLAMA_MODEL}" \
    --set "providers.ollama.config.host=${KAGENT_OLLAMA_HOST}" \
    --wait --timeout 10m

  # The pods are part of the controller chart; wait for the UI specifically.
  kc -n "$KAGENT_NS" wait --for=condition=ready --timeout=180s \
    pod -l app.kubernetes.io/component=ui >/dev/null
  ok "kagent ready (UI: https://${KAGENT_HOST}:${SANDBOX_HTTPS_PORT})"

  if ! ollama_reachable_from_host; then
    warn "kagent's default LLM is Ollama at ${KAGENT_OLLAMA_HOST}, but it doesn't appear to be running on your Mac."
    warn "Install + start it: 'brew install ollama && ollama serve' (in another terminal)"
    warn "Pull the default model:                      'ollama pull ${KAGENT_OLLAMA_MODEL}'"
    warn "Until then the UI is reachable but agents will fail to invoke the model."
  fi
}

ollama_reachable_from_host() {
  # The kagent pod talks to host.docker.internal:11434 (= Mac's :11434).
  # We verify reachability from the Mac itself as a proxy for the pod path.
  curl -s --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1
}

helm_istio() {
  # $1 release, $2 chart, rest passed verbatim to helm.
  local release="$1" chart="$2"; shift 2
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
  helm_istio istiod     istiod --set profile=ambient
  helm_istio ztunnel    ztunnel

  # Ingress gateway. ClusterIP only — Mac reaches it via the LaunchAgent
  # port-forward. Ports are 8080/8443 (not 80/443) so Envoy can bind without
  # the unprivileged-port-start sysctl tweak. Gateway selector in
  # manifests/ingress.yaml is `istio: ingress` (the Helm chart's pod label).
  helm upgrade --install istio-ingress istio/gateway \
    --namespace "$ISTIO_INGRESS_NS" --create-namespace \
    --version "$ISTIO_CHART_VERSION" \
    --set service.type=ClusterIP \
    --set 'service.ports[0].name=status-port'  --set 'service.ports[0].port=15021' --set 'service.ports[0].targetPort=15021' --set 'service.ports[0].protocol=TCP' \
    --set 'service.ports[1].name=http2'        --set 'service.ports[1].port=8080'  --set 'service.ports[1].targetPort=8080'  --set 'service.ports[1].protocol=TCP' \
    --set 'service.ports[2].name=https'        --set 'service.ports[2].port=8443'  --set 'service.ports[2].targetPort=8443'  --set 'service.ports[2].protocol=TCP' \
    --wait --timeout 5m

  log "waiting for istio-ingress gateway pod"
  kc -n "$ISTIO_INGRESS_NS" wait --for=condition=ready --timeout=180s pod -l app=istio-ingress >/dev/null
  ok "Istio ambient ready (istiod + ztunnel + ingress gateway)"
}

install_routes() {
  log "applying Istio Gateway + VirtualServices for ${SANDBOX_DOMAIN}"
  # Generated inline so the domain (and namespaces) follow $SANDBOX_DOMAIN /
  # $DEMO_NS without anyone editing a static YAML.
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
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata: { name: kagent, namespace: ${KAGENT_NS} }
spec:
  hosts: ["${KAGENT_HOST}"]
  gateways: ["${ISTIO_INGRESS_NS}/sandbox-gateway"]
  http:
    - route: [{ destination: { host: kagent-ui.${KAGENT_NS}.svc.cluster.local, port: { number: 8080 } } }]
EOF
  ok "routes applied"
}

# ============================================================================
# /etc/hosts management
# ============================================================================

hosts_line_present() {
  local h
  for h in "$ARGO_HOST" "$KARGO_HOST" "$DEMO_HOST" "$KAGENT_HOST"; do
    grep -qE "^[[:space:]]*127\.0\.0\.1[[:space:]].*\b${h}\b" /etc/hosts || return 1
  done
}

install_hosts() {
  log "configuring /etc/hosts entries for ${SANDBOX_DOMAIN}"
  if hosts_line_present; then
    ok "/etc/hosts already maps ${ARGO_HOST}, ${KARGO_HOST}, ${DEMO_HOST}, ${KAGENT_HOST} to 127.0.0.1"
    return
  fi
  prime_sudo
  # /etc/hosts is world-readable, so the read doesn't need sudo. Only the
  # final `install` does.
  local tmp; tmp="$(mktemp -t sandbox-hosts.XXXXXX)"
  grep -v "${SANDBOX_HOSTS_MARKER}" /etc/hosts > "$tmp" || true
  printf '127.0.0.1\t%s %s %s %s\t%s\n' "$ARGO_HOST" "$KARGO_HOST" "$DEMO_HOST" "$KAGENT_HOST" "$SANDBOX_HOSTS_MARKER" >> "$tmp"
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

uninstall_portfwd() {
  if [[ -f "$SANDBOX_LAUNCHAGENT_PLIST" ]]; then
    log "unloading + removing LaunchAgent ${SANDBOX_LAUNCHAGENT_LABEL}"
    launchctl unload "$SANDBOX_LAUNCHAGENT_PLIST" >/dev/null 2>&1 || true
    rm -f "$SANDBOX_LAUNCHAGENT_PLIST"
  fi
  pkill -f "port-forward.*svc/istio-ingress" >/dev/null 2>&1 || true
}

write_portfwd_plist() {
  local kubectl_path
  kubectl_path="$(command -v kubectl)" || die "kubectl not found on PATH"
  mkdir -p "$SANDBOX_LAUNCHAGENT_DIR" "$SANDBOX_STATE_DIR"
  cat > "$SANDBOX_LAUNCHAGENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTD/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${SANDBOX_LAUNCHAGENT_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${kubectl_path}</string>
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
  write_portfwd_plist
  launchctl load "$SANDBOX_LAUNCHAGENT_PLIST"
  local i
  for ((i=1; i<=15; i++)); do
    if nc -z 127.0.0.1 "$SANDBOX_HTTPS_PORT" 2>/dev/null; then
      ok "port-forward ready on 127.0.0.1:${SANDBOX_HTTP_PORT} + :${SANDBOX_HTTPS_PORT}"
      return
    fi
    sleep 1
  done
  warn "LaunchAgent loaded but :${SANDBOX_HTTPS_PORT} did not bind within 15s — check ${SANDBOX_PF_LOG}"
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

# load_or_generate_secrets sets KARGO_ADMIN_PASSWORD / _HASH and
# KARGO_TOKEN_SIGNING_KEY. On first run it generates random values, hashes
# the password via the Go CLI's `secret bcrypt`, and writes everything to a
# 0600 file the user owns. Subsequent runs just source the file so the
# password stays the same across restarts.
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
  - ${ARGO_HOST}
  - ${KARGO_HOST}
  - ${DEMO_HOST}
  - ${KAGENT_HOST}
launch_agent: ${SANDBOX_LAUNCHAGENT_LABEL}
created_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}

# ============================================================================
# Validation
# ============================================================================

validate_urls() {
  log "validating URLs reachable from the Mac"
  local failed=0 host url code
  for host in "$ARGO_HOST" "$KARGO_HOST" "$DEMO_HOST" "$KAGENT_HOST"; do
    url="https://${host}:${SANDBOX_HTTPS_PORT}/"
    # -k: curl's bundle doesn't know our local CA; the browser does after
    # trust_root_ca. Browsers send SNI from the URL host — curl too, since
    # /etc/hosts maps the host to 127.0.0.1.
    # --retry can print one code per attempt; tail -c 3 keeps the final.
    code="$(curl -sk -o /dev/null -w '%{http_code}' \
      --max-time 8 --retry 8 --retry-delay 2 --retry-connrefused \
      "$url" 2>/dev/null | tail -c 3 || echo 000)"
    if [[ "$code" =~ ^(2|3)[0-9][0-9]$ ]]; then
      printf '  %-50s OK (%s)\n' "$url" "$code"
    else
      printf '  %-50s FAIL (%s)\n' "$url" "$code"
      failed=1
    fi
  done
  if (( failed )); then
    warn "one or more URLs are not reachable from the Mac — see ${SANDBOX_PF_LOG} and 'sandboxctl status'"
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

  # Host-side: stale socat forwarder containers, orphan kubectl port-forward,
  # leftover dnsmasq config from earlier architectures.
  local proto
  for proto in http https; do
    "$SANDBOX_RUNTIME" rm -f "${CLUSTER_NAME}-portfwd-${proto}" >/dev/null 2>&1 || true
  done
  pkill -f "port-forward.*svc/(istio-ingress|traefik)" >/dev/null 2>&1 || true
  local brew_prefix dnsmasq_conf="" resolver_file="/etc/resolver/${SANDBOX_DOMAIN}"
  brew_prefix="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
  dnsmasq_conf="${brew_prefix}/etc/dnsmasq.d/sandbox-${SANDBOX_DOMAIN}.conf"
  [[ -f "$dnsmasq_conf"  ]] && rm -f      "$dnsmasq_conf"  2>/dev/null || true
  [[ -f "$resolver_file" ]] && sudo rm -f "$resolver_file" 2>/dev/null || true
}

# ============================================================================
# up_needs_sudo / sudo keepalive
# ============================================================================

up_needs_sudo() {
  hosts_line_present || return 0
  ca_already_trusted || return 0
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
  require_tools

  if up_needs_sudo; then
    log "sudo required for /etc/hosts + System keychain — prompting once now"
    sudo -v || die "sudo required to configure /etc/hosts and System keychain"
    start_sudo_keepalive
  fi

  bring_up_cluster
  kubectl config use-context "$(kctx)" >/dev/null
  kc cluster-info >/dev/null

  load_or_generate_secrets
  install_cert_manager
  install_pki
  clean_legacy_state
  install_argocd
  install_kargo
  install_demo_app
  install_kagent
  install_istio_ambient
  install_routes
  install_hosts
  install_portfwd
  trust_root_ca
  write_state_file
  validate_urls

  log "sandbox is up"
  cmd_status
  echo
  echo "next:"
  printf '  open https://%s:%s\n' "$ARGO_HOST"   "$SANDBOX_HTTPS_PORT"
  printf '  open https://%s:%s\n' "$KARGO_HOST"  "$SANDBOX_HTTPS_PORT"
  printf '  open https://%s:%s\n' "$DEMO_HOST"   "$SANDBOX_HTTPS_PORT"
  printf '  open https://%s:%s\n' "$KAGENT_HOST" "$SANDBOX_HTTPS_PORT"
  echo "  sandboxctl creds   # full login details"
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
  (( need_sudo )) && prime_sudo

  log "tearing down sandbox '$CLUSTER_NAME'"
  uninstall_portfwd
  clean_legacy_state

  if cluster_registered; then
    log "deleting kind cluster '$CLUSTER_NAME'"
    kind delete cluster --name "$CLUSTER_NAME"
  else
    ok "no kind cluster named '$CLUSTER_NAME' to delete"
  fi

  uninstall_hosts
  untrust_root_ca

  ok "sandbox down (cluster, LaunchAgent, /etc/hosts, root CA trust removed)"
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
  workload_summary "$KARGO_NS"         "kargo"
  workload_summary "$DEMO_NS"          "demo-app"
  workload_summary "$KAGENT_NS"        "kagent"
  echo
  echo "apps & URLs:"
  printf '  %-12s https://%s:%s\n' "argocd"   "$ARGO_HOST"   "$SANDBOX_HTTPS_PORT"
  printf '  %-12s https://%s:%s\n' "kargo"    "$KARGO_HOST"  "$SANDBOX_HTTPS_PORT"
  printf '  %-12s https://%s:%s\n' "demo-app" "$DEMO_HOST"   "$SANDBOX_HTTPS_PORT"
  printf '  %-12s https://%s:%s\n' "kagent"   "$KAGENT_HOST" "$SANDBOX_HTTPS_PORT"
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

kagent
  URL:       https://${KAGENT_HOST}:${SANDBOX_HTTPS_PORT}
  LLM:       Ollama at ${KAGENT_OLLAMA_HOST} (model: ${KAGENT_OLLAMA_MODEL})
  Note:      run \`brew install ollama && ollama serve && ollama pull ${KAGENT_OLLAMA_MODEL}\`
             on the Mac for the agents to actually answer queries.

kubectl context: $(kctx)
EOF
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

# ============================================================================
# Usage + dispatcher
# ============================================================================

usage() {
  cat <<EOF
sandbox.sh — local kind sandbox with Argo CD + Kargo + Istio ambient

usage:
  sandbox.sh setup-podman   install/configure rootful podman machine (one-time)
  sandbox.sh trust-ca       trust the sandbox root CA in macOS System keychain (sudo)
  sandbox.sh untrust-ca     remove the sandbox root CA from System keychain (sudo)
  sandbox.sh up             create cluster + install argocd/kargo/demo + ingress + PKI + hosts + portfwd
  sandbox.sh down           remove cluster + LaunchAgent + /etc/hosts + keychain CA (keeps ~/.sandbox)
  sandbox.sh purge          down + remove ~/.sandbox (prompts for confirmation)
  sandbox.sh restart        down + up
  sandbox.sh status         cluster + workload status + URLs
  sandbox.sh validate       curl each URL from the Mac and print HTTP codes
  sandbox.sh creds          print login details (URLs + admin creds)
  sandbox.sh argocd-ui      print Argo CD URL + admin creds
  sandbox.sh kargo-ui       print Kargo URL + admin creds

env overrides:
  SANDBOX_RUNTIME             podman (default) or docker
  SANDBOX_CLUSTER_NAME        cluster name (default: sandboxctl)
  SANDBOX_DOMAIN              local DNS suffix (default: sandbox.app)
  SANDBOX_HTTP_PORT           host port for HTTP (default: 8080)
  SANDBOX_HTTPS_PORT          host port for HTTPS (default: 8443)
  PODMAN_MACHINE_CPUS         CPUs for podman machine init (default: 4)
  PODMAN_MACHINE_MEMORY_MIB   RAM in MiB for podman machine (default: 6144)
  PODMAN_MACHINE_DISK_GIB     disk in GiB for podman machine init (default: 60)
  KIND_NODE_IMAGE             kind node image (default: kindest/node:v1.35.0)
  ARGOCD_CHART_VERSION        pin argo-cd helm chart version
  KARGO_CHART_VERSION         pin kargo helm chart version
  CERT_MANAGER_CHART_VERSION  pin cert-manager chart version
  ISTIO_CHART_VERSION         pin istio version
  KAGENT_CHART_VERSION        pin kagent helm chart version
  KAGENT_OLLAMA_HOST          Ollama endpoint kagent connects to (default: host.docker.internal:11434)
  KAGENT_OLLAMA_MODEL         model kagent will pull from Ollama (default: llama3.2)
  KARGO_TOKEN_SIGNING_KEY     pin Kargo JWT signing key (default: random per install)
EOF
}

main() {
  case "${1:-}" in
    setup-podman)       cmd_setup_podman ;;
    trust-ca)           trust_root_ca ;;
    untrust-ca)         untrust_root_ca ;;
    up)                 cmd_up ;;
    down)               cmd_down ;;
    purge)              cmd_purge ;;
    status)             cmd_status ;;
    restart)            cmd_down; cmd_up ;;
    validate)           require_running_cluster; validate_urls ;;
    creds)              cmd_creds ;;
    argocd-ui)          cmd_argocd_ui ;;
    kargo-ui)           cmd_kargo_ui ;;
    ""|-h|--help|help)  usage ;;
    *) die "unknown subcommand: $1 (try --help)" ;;
  esac
}

main "$@"
