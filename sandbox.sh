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
REGISTRY_NS="${REGISTRY_NS:-sandboxctl-registry}"
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

# kagent: chart defaults its LLM provider to Ollama at host.docker.internal.
# sandboxctl does not install Ollama — the UI works either way; agents
# need a reachable Ollama (or remote KAGENT_OLLAMA_HOST) to answer.
KAGENT_NS="${KAGENT_NS:-kagent}"
KAGENT_CHART_VERSION="${KAGENT_CHART_VERSION:-0.9.4}"
KAGENT_OLLAMA_HOST="${KAGENT_OLLAMA_HOST:-host.docker.internal:11434}"
KAGENT_OLLAMA_MODEL="${KAGENT_OLLAMA_MODEL:-llama3.2}"

# Gitea: in-cluster git server that backs `sandboxctl deploy`. The CLI
# pushes the local chart subtree to gitea-http.gitea.svc:3000 and Argo
# CD pulls from that URL — proper GitOps loop without needing external
# git creds. Chart pinned for reproducibility; rootless image + sqlite
# keeps the install footprint tiny (one Pod + a 1Gi PVC).
GITEA_NS="${GITEA_NS:-gitea}"
GITEA_CHART_VERSION="${GITEA_CHART_VERSION:-12.5.0}"
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
SANDBOX_LAUNCHAGENT_DIR="${SANDBOX_LAUNCHAGENT_DIR:-$HOME/Library/LaunchAgents}"
SANDBOX_LAUNCHAGENT_LABEL="${SANDBOX_LAUNCHAGENT_LABEL:-io.github.sandboxctl.portfwd}"
SANDBOX_LAUNCHAGENT_PLIST="${SANDBOX_LAUNCHAGENT_DIR}/${SANDBOX_LAUNCHAGENT_LABEL}.plist"
SANDBOX_PF_LOG="${SANDBOX_STATE_DIR}/portfwd.log"

# socat container on kind network — bypass kubectl port-forward, which
# stalls on Docker's 16-way parallel layer uploads.
SANDBOX_REGISTRY_PROXY_CONTAINER="${SANDBOX_REGISTRY_PROXY_CONTAINER:-${CLUSTER_NAME}-registry-proxy}"
SANDBOX_REGISTRY_PROXY_IMAGE="${SANDBOX_REGISTRY_PROXY_IMAGE:-docker.io/alpine/socat:latest}"
SANDBOX_REGISTRY_NODEPORT="${SANDBOX_REGISTRY_NODEPORT:-30050}"
SANDBOX_HOSTS_MARKER="# managed by sandboxctl (${SANDBOX_DOMAIN})"
SANDBOX_SECRETS_FILE="${SANDBOX_STATE_DIR}/secrets.env"

SANDBOX_RUNTIME="${SANDBOX_RUNTIME:-podman}"
PODMAN_MACHINE_CPUS="${PODMAN_MACHINE_CPUS:-4}"
PODMAN_MACHINE_MEMORY_MIB="${PODMAN_MACHINE_MEMORY_MIB:-6144}"
PODMAN_MACHINE_DISK_GIB="${PODMAN_MACHINE_DISK_GIB:-60}"
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

kctx() { echo "kind-$CLUSTER_NAME"; }
kc()   { kubectl --context "$(kctx)" "$@"; }

# Truth source for "is kagent installed in this cluster?" — checked
# at runtime against the live API rather than a flag in state, so
# `status` / `validate` / `down` / `install_routes` agree across
# upgrades and across re-runs that flip the toggle.
_kagent_present() {
  kc get ns "$KAGENT_NS" >/dev/null 2>&1
}

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

cluster_registered()    { kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; }
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
  configure_node_registry_mirror
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
  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace "$CERT_MANAGER_NS" --create-namespace \
    --version "$CERT_MANAGER_CHART_VERSION" \
    --set crds.enabled=true \
    --wait --timeout 5m
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
  # The kagent UI works without an LLM. To actually answer queries, the
  # && ollama pull llama3.2` or set KAGENT_OLLAMA_HOST to a remote endpoint.
  log "installing kagent (ns: $KAGENT_NS, chart $KAGENT_CHART_VERSION) — provider: Ollama at ${KAGENT_OLLAMA_HOST}"

  # CRDs ship as a separate chart, must land first.
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

  kc -n "$KAGENT_NS" wait --for=condition=ready --timeout=180s \
    pod -l app.kubernetes.io/component=ui >/dev/null
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
  log "running helm upgrade --install gitea (this can take ~3 min on first run)"
  if ! helm upgrade --install gitea gitea-charts/gitea \
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
      --wait --timeout 8m 2>&1; then
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
  ) || die "git push to gitea failed"

  echo "http://gitea-http.${GITEA_NS}.svc.cluster.local:3000/${GITEA_ORG}/${repo_name}.git"
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
  ok "routes applied"
}

# ============================================================================
# /etc/hosts management
# ============================================================================

_managed_hosts() {
  # Hostnames sandboxctl manages on the marker line. Kagent appears
  # only when its namespace is live, so a default-off `up` doesn't
  # leak `kagent.sandbox.app` into /etc/hosts.
  local out=("$ARGO_HOST" "$KARGO_HOST" "$DEMO_HOST")
  if _kagent_present; then out+=("$KAGENT_HOST"); fi
  printf '%s\n' "${out[@]}"
}

hosts_line_present() {
  local h
  while IFS= read -r h; do
    grep -qE "^[[:space:]]*127\.0\.0\.1[[:space:]].*\b${h}\b" /etc/hosts || return 1
  done < <(_managed_hosts)
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

uninstall_portfwd() {
  if [[ -f "$SANDBOX_LAUNCHAGENT_PLIST" ]]; then
    log "unloading + removing LaunchAgent ${SANDBOX_LAUNCHAGENT_LABEL}"
    launchctl unload "$SANDBOX_LAUNCHAGENT_PLIST" >/dev/null 2>&1 || true
    rm -f "$SANDBOX_LAUNCHAGENT_PLIST"
  fi
  local legacy
  for legacy in "${LEGACY_LAUNCHAGENT_LABELS[@]}"; do
    local legacy_plist="${SANDBOX_LAUNCHAGENT_DIR}/${legacy}.plist"
    if [[ -f "$legacy_plist" ]]; then
      log "removing legacy LaunchAgent ${legacy}"
      launchctl unload "$legacy_plist" >/dev/null 2>&1 || true
      rm -f "$legacy_plist"
    fi
    launchctl remove "$legacy" >/dev/null 2>&1 || true
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
  local legacy_plist="${SANDBOX_LAUNCHAGENT_DIR}/io.github.sandboxctl.registry-portfwd.plist"
  if [[ -f "$legacy_plist" ]]; then
    log "removing legacy registry LaunchAgent"
    launchctl unload "$legacy_plist" >/dev/null 2>&1 || true
    rm -f "$legacy_plist"
  fi
  launchctl remove io.github.sandboxctl.registry-portfwd >/dev/null 2>&1 || true
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
  uninstall_registry_portfwd
  free_port_or_die        # fail fast on foreign conflicts; clean up our own stale state
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
    if [[ "$code" =~ ^(2|3)[0-9][0-9]$ ]]; then
      printf '  %-50s OK (%s)\n' "$url" "$code"
    else
      printf '  %-50s FAIL (%s)\n' "$url" "$code"
      failed=1
    fi
  done < <(_managed_hosts)
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
  # Optional add-ons. Off by default — they're useful for some users
  # but slow down `up` and pull a noticeable amount of disk. Toggle on
  # individually (--with-kagent) or all at once (--install all).
  INSTALL_KAGENT=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --with-kagent)    INSTALL_KAGENT=1; shift ;;
      --install)
        case "${2:-}" in
          all)          INSTALL_KAGENT=1; shift 2 ;;
          *) die "--install: expected 'all' (got '${2:-}')" ;;
        esac ;;
      -h|--help)
        cat <<EOF
sandboxctl up [--with-kagent] [--install all]

Bring the local sandbox cluster up: kind + cert-manager + Argo CD +
Kargo + Istio + in-cluster registry + Gitea + a demo app, all wired
behind https://*.${SANDBOX_DOMAIN}:${SANDBOX_HTTPS_PORT}.

Add-ons (off by default — they take longer and use more memory):
  --with-kagent    Install kagent (agentic AI controller + UI).
  --install all    Install every add-on. Today: kagent.
EOF
        return 0 ;;
      *) die "unknown flag: $1 (try 'sandboxctl up --help')" ;;
    esac
  done
  export INSTALL_KAGENT

  require_tools
  ensure_tooling

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
  install_registry
  install_demo_app
  if (( INSTALL_KAGENT )); then
    install_kagent
  else
    log "skipping kagent (pass --with-kagent or --install all to enable)"
  fi
  install_gitea
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
  printf '  open https://%s:%s\n' "$ARGO_HOST"  "$SANDBOX_HTTPS_PORT"
  printf '  open https://%s:%s\n' "$KARGO_HOST" "$SANDBOX_HTTPS_PORT"
  printf '  open https://%s:%s\n' "$DEMO_HOST"  "$SANDBOX_HTTPS_PORT"
  if (( INSTALL_KAGENT )); then
    printf '  open https://%s:%s\n' "$KAGENT_HOST" "$SANDBOX_HTTPS_PORT"
  fi
  echo "  sandboxctl creds   # full login details"
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
  local target="" up_args=() deploy_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --with-kagent|--install)
        # `--install` takes a value (today: "all"). Forward both forms.
        if [[ "$1" == "--install" ]]; then
          up_args+=("$1" "${2:-}"); shift 2
        else
          up_args+=("$1"); shift
        fi ;;
      --env|--chart|--values|--name)
        deploy_args+=("$1" "${2:-}"); shift 2 ;;
      --no-build)
        deploy_args+=("$1"); shift ;;
      -h|--help)
        cat <<EOF
sandboxctl bootstrap [path] [up flags] [deploy flags]

One-shot for first-time users: brings the sandbox cluster up if it
isn't already, then deploys the chart in the current product
directory.

Run this from your product repo root — the directory that holds your
Dockerfile(s), chart, and k8s/secrets.yaml.

  sandboxctl bootstrap                       # cwd = product dir
  sandboxctl bootstrap path/to/repo
  sandboxctl bootstrap --with-kagent         # forwarded to 'up'
  sandboxctl bootstrap --chart custom/chart  # forwarded to 'deploy'
  sandboxctl bootstrap --no-build            # forwarded to 'deploy'

If the cluster is already up the platform install is skipped — only
the deploy half runs, so this is also fine to use as your every-day
"redeploy this app" shortcut.
EOF
        return 0 ;;
      -*) die "unknown flag: $1 (try 'sandboxctl bootstrap --help')" ;;
      *)
        if [[ -z "$target" ]]; then target="$1"; shift
        else die "unexpected argument: $1"
        fi ;;
    esac
  done
  target="${target:-.}"

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
    cmd_up "${up_args[@]}"
  fi

  # Deploy the product's chart. cmd_deploy is responsible for
  # validating that <target> actually contains something deployable.
  log "deploying from product dir: ${target}"
  cmd_deploy "$target" "${deploy_args[@]}"

  trap - ERR
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
  (( need_sudo )) && prime_sudo

  log "tearing down sandbox '$CLUSTER_NAME'"
  uninstall_portfwd
  uninstall_registry_portfwd
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
  workload_summary "$REGISTRY_NS"      "registry"
  workload_summary "$DEMO_NS"          "demo-app"
  if _kagent_present; then
    workload_summary "$KAGENT_NS"      "kagent"
  fi
  echo
  echo "apps & URLs:"
  printf '  %-12s https://%s:%s\n' "argocd"   "$ARGO_HOST"   "$SANDBOX_HTTPS_PORT"
  printf '  %-12s https://%s:%s\n' "kargo"    "$KARGO_HOST"  "$SANDBOX_HTTPS_PORT"
  printf '  %-12s https://%s:%s\n' "demo-app" "$DEMO_HOST"   "$SANDBOX_HTTPS_PORT"
  if _kagent_present; then
    printf '  %-12s https://%s:%s\n' "kagent" "$KAGENT_HOST" "$SANDBOX_HTTPS_PORT"
  fi
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
  LLM:       configured for Ollama at ${KAGENT_OLLAMA_HOST} (model: ${KAGENT_OLLAMA_MODEL})
  Note:      kagent is installed but not wired to a live LLM by default.
             To make agents answer queries, install Ollama yourself:
               brew install ollama
               ollama serve &
               ollama pull ${KAGENT_OLLAMA_MODEL}
             or set KAGENT_OLLAMA_HOST to a remote endpoint and re-run 'sandboxctl up'.
EOF
  fi
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

detect_builder() {
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then echo docker
  elif command -v podman >/dev/null 2>&1; then echo podman
  else die "neither docker nor podman is available — install one to build images"
  fi
}

# Always podman: docker push from Docker Desktop's VM can't reach the
# Mac's gvproxy port-forward (different loopback) — the push hangs with
# layers stuck at "Waiting".
detect_pusher() {
  command -v podman >/dev/null 2>&1 && { echo podman; return; }
  die "podman is required for pushing — try 'sandboxctl setup-podman'"
}

# build_and_push <image> <dockerfile> <context> [extra build args]
build_and_push() {
  local image="$1" dockerfile="$2" context="$3"; shift 3
  local builder pusher
  builder="$(detect_builder)"
  pusher="$(detect_pusher)"

  log "building ${image}  (context: ${context}, builder: ${builder})"
  "$builder" build -t "$image" "$@" -f "$dockerfile" "$context" || \
    die "build failed for ${image}"

  # docker save | podman load is the universal handoff — `podman pull
  # docker-daemon:` needs daemon-socket access podman's VM doesn't have.
  if [[ "$builder" != "$pusher" ]]; then
    log "transferring ${image} from ${builder} to ${pusher} for push"
    "$builder" save "$image" 2>/dev/null | "$pusher" load 2>&1 | tail -3 || \
      die "could not transfer ${image} from ${builder} to ${pusher}"
  fi

  log "pushing ${image}  (pusher: ${pusher})"
  "$pusher" push --tls-verify=false "$image" || die "push failed for ${image}"
  ok "${image}"
}

# slugify an arbitrary path component into a docker-image-name-safe form.
slugify() {
  printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed 's/^-*//;s/-*$//'
}

cmd_build() {
  # If a sandboxctl.yaml is found, use it (build order, contexts,
  # aliases, deps). Otherwise auto-walk Dockerfiles.
  local target="${1:-.}" tag="${2:-latest}"

  _ensure_registry_reachable

  local manifest=""
  for candidate in "${target}/sandboxctl.yaml" "${target}/sandboxctl.yml" "$(pwd)/sandboxctl.yaml"; do
    [[ -f "$candidate" ]] && { manifest="$candidate"; break; }
  done
  if [[ -n "$manifest" ]]; then
    cmd_build_from_manifest "$manifest"
  else
    cmd_build_auto_walk "$target" "$tag"
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

    build_and_push "$image" "$abs_df" "$abs_ctx" "${extra_tags[@]}"
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
  # list / rm <ref> / prune / gc — see usage block.
  local sub="${1:-list}"; shift || true
  case "$sub" in
    list|"")  registry_images_list ;;
    rm)       [[ $# -ge 1 ]] || die "usage: sandboxctl images rm <image>[:tag]"
              registry_images_rm "$1"; registry_images_gc ;;
    prune)    registry_images_prune; registry_images_gc ;;
    gc)       registry_images_gc ;;
    *)        die "unknown 'images' subcommand: $sub (use list, rm, prune, gc)" ;;
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

  # Prefer values-sandbox.yaml (sandboxctl-specific overrides). Fall
  # back to values-local.yaml for charts that haven't been
  # sandbox-ified yet. Charts with neither still deploy with the
  # chart's baseline values.yaml.
  if   [[ -f "${chart_dir}/values-sandbox.yaml" ]]; then values="values-sandbox.yaml"
  elif [[ -f "${chart_dir}/values-local.yaml"   ]]; then values="values-local.yaml"
  fi

  printf 'helm\t%s\t%s\t%s\n' "$name" "$chart_dir" "$values"
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
  elif [[ -f "${chart_dir}/values-sandbox.yaml" ]]; then vfile="values-sandbox.yaml"
  elif [[ -f "${chart_dir}/values-local.yaml"   ]]; then vfile="values-local.yaml"
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

  # Validate: refuse to apply if any obvious placeholder is left.
  if grep -qE '<base64-encoded-[a-z-]+>' "$secrets" 2>/dev/null; then
    die "k8s/secrets.yaml still contains <base64-encoded-...> placeholders — fill them in and re-run"
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
  # Usage: sandboxctl deploy [path] [--env <name>] [--chart <dir>]
  #                          [--values <file>] [--name <name>] [--no-build]
  local target="" env="dev" do_build=1
  local chart_override="" values_override="" name_override=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env)      env="$2"; shift 2 ;;
      --chart)    chart_override="$2"; shift 2 ;;
      --values)   values_override="$2"; shift 2 ;;
      --name)     name_override="$2"; shift 2 ;;
      --no-build) do_build=0; shift ;;
      -h|--help)
        cat <<EOF
sandboxctl deploy [path] [--env <name>]
                  [--chart <dir>] [--values <file>] [--name <name>]
                  [--no-build]

Run from your product directory (one that contains your Dockerfile(s)
and chart). Builds + pushes images, applies secrets, pushes the chart
to the in-cluster Gitea, creates one Argo CD Application per chart,
and routes a stable URL to each.

Pipeline (per chart):
  1. Build + push every Dockerfile listed in <path>/sandboxctl.yaml,
     or auto-walk Dockerfiles when no manifest exists. Skip with
     --no-build (useful when iterating only on chart edits).
  2. Apply <path>/k8s/secrets.yaml to each chart's target namespace,
     prompting to fill placeholders on first run.
  3. Push the chart to the in-cluster Gitea, create one Argo CD
     Application per chart syncing from Gitea, and route
     <chart>.${SANDBOX_DOMAIN}:${SANDBOX_HTTPS_PORT} to the
     chart's primary Service.

Chart resolution order (no --chart):
  1. <path>/k8s/chart/Chart.yaml         the recommended layout
  2. Auto-discovery walks <path> for any Chart.yaml within depth 5
     (skipping vendor / node_modules / dist / .git).
  3. Interactive prompt asks for an absolute or relative chart path
     when nothing is found.

Override flags (skip auto-discovery and deploy a single chart):
  --chart <dir>     Path to a chart directory containing Chart.yaml.
                    Relative paths resolve from <path>.
  --values <file>   Values file inside <chart>. Defaults to
                    values-sandbox.yaml, then values-local.yaml.
  --name <name>     Override the Argo Application + routed hostname
                    name. Defaults to the chart's "name:" field.

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
        if [[ -z "$target" ]]; then target="$1"; shift
        else die "unexpected argument: $1"
        fi ;;
    esac
  done
  require_running_cluster
  target="${target:-.}"
  target="$(cd "$target" && pwd)"

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
        # Nothing chart-shaped under <target>. Prompt for a path —
        # absolute, or relative to <target>.
        if [[ ! -t 0 ]]; then
          die "no chart found under ${target} — pass --chart <dir> or place a chart at ${target}/k8s/chart (no TTY available for interactive prompt)"
        fi
        echo
        echo "  No chart found at ${target}/k8s/chart (the recommended layout)"
        echo "  and no other Helm chart was discovered under ${target}."
        echo
        echo "  If your chart lives elsewhere, enter its path now (absolute"
        echo "  or relative to ${target}). Press Enter on an empty line to"
        echo "  abort."
        echo
        local prompt_path=""
        printf '  Chart path: '
        read -r prompt_path
        [[ -n "$prompt_path" ]] || \
          die "deploy aborted — no chart path provided"
        entries="$(_emit_explicit_chart_entry "$target" "$prompt_path" "" "")" || return 1
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

  # Always rebuild + push every Dockerfile listed in sandboxctl.yaml so
  # the registry matches what the just-pushed chart references. Skipped
  # only on --no-build, which is useful when iterating on chart edits
  # without touching code. cmd_build is a no-op if there's no manifest
  # and no Dockerfiles under <target>.
  if (( do_build )); then
    if [[ -f "${target}/sandboxctl.yaml" || -f "${target}/sandboxctl.yml" ]] \
        || find "$target" -type f -name Dockerfile -not -path '*/.git/*' \
             -not -path '*/node_modules/*' -not -path '*/vendor/*' \
             -not -path '*/dist/*' -print -quit 2>/dev/null | grep -q .; then
      log "running 'sandboxctl build ${target}' first (use --no-build to skip)"
      cmd_build "$target"
    else
      log "no Dockerfiles or sandboxctl.yaml under ${target} — skipping build step"
    fi
  fi

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

    [[ "$kind" == "helm" && -n "$values_file" ]] && \
      log "[${cname}] using values file: ${values_file}"

    local repo_name="${cname}-chart"
    local gitea_url
    gitea_url="$(gitea_push_chart "$repo_name" "$src_dir")"
    log "[${cname}] pushed chart → ${gitea_url}"

    _apply_argo_app "$cname" "$kind" "$gitea_url" "$values_file" "$namespace"

    _wait_argo_health "$cname"

    _route_app_service "$cname" "$namespace" "$hostname"
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

# Apply (or update) one Argo CD Application. Helper for cmd_deploy so
# the per-chart loop body stays readable.
_apply_argo_app() {
  local cname="$1" kind="$2" gitea_url="$3" values_file="$4" namespace="$5"

  log "[${cname}] creating Argo CD Application (source: ${gitea_url}@main)"
  if [[ "$kind" == "helm" && -n "$values_file" ]]; then
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
    helm:
      valueFiles: ["${values_file}"]
  destination:
    server: https://kubernetes.default.svc
    namespace: ${namespace}
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
EOF
  elif [[ "$kind" == "helm" ]]; then
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
  destination:
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

# Poll Argo CD for an Application to become Synced + Healthy. Times out
# after 180s with a warning rather than failing — the user can inspect
# the Argo UI for details and re-run deploy.
_wait_argo_health() {
  local cname="$1"
  log "[${cname}] waiting for Argo CD to sync (Healthy)"
  local i sync health
  for ((i=1; i<=60; i++)); do
    sync="$(kc -n "$ARGOCD_NS" get application "$cname" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    health="$(kc -n "$ARGOCD_NS" get application "$cname" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    [[ "$sync" == "Synced" && "$health" == "Healthy" ]] && { ok "[${cname}] synced + healthy"; return 0; }
    sleep 3
  done
  warn "[${cname}] did not become Healthy in 180s (sync=${sync:-unknown} health=${health:-unknown}) — check Argo CD UI"
}

# Wire one Istio VirtualService + /etc/hosts entry for the app's primary
# Service. Heuristic: prefer a Service whose name matches the chart, fall
# back to the first Service in the namespace.
_route_app_service() {
  local cname="$1" namespace="$2" hostname="$3"
  local svc svc_port
  svc="$(kc -n "$namespace" get svc -o jsonpath="{.items[?(@.metadata.name=='${cname}')].metadata.name}" 2>/dev/null || true)"
  if [[ -z "$svc" ]]; then
    svc="$(kc -n "$namespace" get svc -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  fi
  if [[ -n "$svc" ]]; then
    svc_port="$(kc -n "$namespace" get svc "$svc" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo 80)"
    add_app_route "$hostname" "$namespace" "$svc" "$svc_port"
    add_app_host  "$hostname"
    ok "[${cname}] routed https://${hostname}:${SANDBOX_HTTPS_PORT} → svc/${svc}:${svc_port}"
  else
    warn "[${cname}] no Service found in ${namespace} yet — Argo may still be syncing. Re-run 'sandboxctl deploy' once pods are up to wire the route."
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
  ok "undeployed ${name} (namespace ${namespace} preserved — delete manually if desired)"
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
  sandbox.sh up [--with-kagent | --install all]
                            create cluster + install argocd/kargo/demo/registry/gitea + ingress + PKI + hosts + portfwd
                            (kagent is opt-in: --with-kagent or --install all)
  sandbox.sh down           remove cluster + LaunchAgent + /etc/hosts + keychain CA (keeps ~/.sandbox)
  sandbox.sh purge          down + remove ~/.sandbox (prompts for confirmation)
  sandbox.sh restart        down + up
  sandbox.sh status         cluster + workload status + URLs
  sandbox.sh validate       curl each URL from the Mac and print HTTP codes
  sandbox.sh creds          print login details (URLs + admin creds)
  sandbox.sh argocd-ui      print Argo CD URL + admin creds
  sandbox.sh kargo-ui       print Kargo URL + admin creds
  sandbox.sh build [path]            find Dockerfiles under <path>, build + push to the cluster registry
  sandbox.sh images                  list images in the cluster registry
  sandbox.sh images rm <ref>         delete an image (e.g. 'myapp:v1' or 'myapp' for all tags)
  sandbox.sh images prune            delete every image, then GC blobs
  sandbox.sh images gc               run registry garbage-collector to reclaim disk now
  sandbox.sh deploy [path] [--env <name>] [--no-build]
                                     auto-discover every chart under <path> (and sibling repos),
                                     build + push every Dockerfile, apply k8s/secrets.yaml, push each chart
                                     to in-cluster Gitea, create one Argo CD Application per chart, and
                                     route <chart>.${SANDBOX_DOMAIN} per app
  sandbox.sh undeploy --name <appname> [--env <name>]
                                     remove the Argo Application, route, and hosts entry (namespace preserved)
  sandbox.sh bootstrap [path] [up flags] [deploy flags]
                                     run 'up' (if not already up) + 'deploy' in one shot — handy first-run wrapper

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
  ARGOCD_CHART_VERSION        pin argo-cd helm chart version
  KARGO_CHART_VERSION         pin kargo helm chart version
  CERT_MANAGER_CHART_VERSION  pin cert-manager chart version
  ISTIO_CHART_VERSION         pin istio version
  KAGENT_CHART_VERSION        pin kagent helm chart version
  KAGENT_OLLAMA_HOST          Ollama endpoint kagent connects to (default: host.docker.internal:11434)
  KAGENT_OLLAMA_MODEL         model kagent will pull from Ollama (default: llama3.2)
  KARGO_TOKEN_SIGNING_KEY     pin Kargo JWT signing key (default: random per install)
  GITEA_CHART_VERSION         pin gitea helm chart version (default: 12.5.0)
  GITEA_ADMIN_USER            admin user created in Gitea (default: sandbox)
  GITEA_ORG                   org chart repos are pushed under (default: sandbox)
EOF
}

main() {
  case "${1:-}" in
    setup-podman)       cmd_setup_podman ;;
    trust-ca)           trust_root_ca ;;
    untrust-ca)         untrust_root_ca ;;
    up)                 shift; cmd_up "$@" ;;
    down)               cmd_down ;;
    purge)              cmd_purge ;;
    status)             cmd_status ;;
    restart)            cmd_down; cmd_up ;;
    validate)           require_running_cluster; validate_urls ;;
    creds)              cmd_creds ;;
    argocd-ui)          cmd_argocd_ui ;;
    kargo-ui)           cmd_kargo_ui ;;
    build)              shift; cmd_build "$@" ;;
    images)             shift; cmd_images "$@" ;;
    deploy)             shift; cmd_deploy "$@" ;;
    undeploy)           shift; cmd_undeploy "$@" ;;
    bootstrap)          shift; cmd_bootstrap "$@" ;;
    ""|-h|--help|help)  usage ;;
    *) die "unknown subcommand: $1 (try --help)" ;;
  esac
}

main "$@"
