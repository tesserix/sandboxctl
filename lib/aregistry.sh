# shellcheck shell=bash
# lib/aregistry.sh — agentregistry server + CNPG-backed Postgres (pgvector)
#
# What this lib installs (in order, all idempotent):
#   1. CloudNativePG operator           (helm release in cnpg-system)
#   2. A CNPG Cluster running PG 17 with the pgvector extension preloaded
#      (ghcr.io/cloudnative-pg/postgresql:17-standard-trixie ships pgvector
#      in the "standard" image flavour — no custom build needed).
#   3. The agentregistry server chart, pointed at the CNPG cluster via
#      database.postgres.url (no bundled postgres), with vectorEnabled=true
#      so embeddings + semantic search are available.
#
# Sourced by sandbox.sh; assumes the common globals are already set
# (CLUSTER_NAME, SANDBOX_DOMAIN, ISTIO_INGRESS_NS, kc, log/ok/warn/die,
# with_spinner, prime_sudo, etc.) and helm + kubectl + openssl are on PATH.
#
# Public functions called from sandbox.sh:
#   install_aregistry        — full pipeline (operator + cluster + chart)
#   install_aregistry_routes — Istio VirtualService for the gateway
#   aregistry_present        — predicate for the gating in install_routes /
#                              _managed_hosts / cmd_status
#   aregistry_status         — one-line status for cmd_status

# ============================================================================
# Configuration
# ============================================================================

AREGISTRY_NS="${AREGISTRY_NS:-aregistry}"
AREGISTRY_RELEASE="${AREGISTRY_RELEASE:-aregistry}"
AREGISTRY_CHART="${AREGISTRY_CHART:-oci://ghcr.io/agentregistry-dev/agentregistry/charts/agentregistry}"
AREGISTRY_CHART_VERSION="${AREGISTRY_CHART_VERSION:-0.3.3}"
AREGISTRY_IMAGE_TAG="${AREGISTRY_IMAGE_TAG:-v0.3.3}"
AREGISTRY_HOST="${AREGISTRY_HOST:-aregistry.${SANDBOX_DOMAIN}}"

# CNPG operator: pinned chart version. The operator watches `Cluster`
# resources cluster-wide; one release covers every database we'd want.
CNPG_NS="${CNPG_NS:-cnpg-system}"
CNPG_RELEASE="${CNPG_RELEASE:-cnpg}"
CNPG_CHART_VERSION="${CNPG_CHART_VERSION:-0.28.2}"

# Postgres image: the cloudnative-pg "standard" trixie flavour bundles
# pgvector (and pg_partman, pgaudit, etc.) — see
# https://github.com/cloudnative-pg/postgres-containers. Pinning a
# specific minor keeps reruns reproducible.
AREGISTRY_PG_IMAGE="${AREGISTRY_PG_IMAGE:-ghcr.io/cloudnative-pg/postgresql:17.9-standard-trixie}"

# Resources for the CNPG cluster + its PVC. The defaults stay tiny so a
# laptop can run the full sandbox; bump for load testing.
AREGISTRY_PG_INSTANCES="${AREGISTRY_PG_INSTANCES:-1}"
AREGISTRY_PG_STORAGE="${AREGISTRY_PG_STORAGE:-2Gi}"

AREGISTRY_DB_NAME="${AREGISTRY_DB_NAME:-aregistry}"
AREGISTRY_DB_USER="${AREGISTRY_DB_USER:-aregistry}"
AREGISTRY_PG_CLUSTER="${AREGISTRY_PG_CLUSTER:-aregistry-pg}"

# JWT signing key persisted in the state dir so issued tokens survive
# reruns of `up` / `restart`. Same convention as the Gitea admin
# password and the Kargo signing key.
AREGISTRY_JWT_FILE="${AREGISTRY_JWT_FILE:-${SANDBOX_STATE_DIR}/aregistry-jwt.key}"

# ============================================================================
# Predicates
# ============================================================================

aregistry_present() {
  kc get ns "$AREGISTRY_NS" >/dev/null 2>&1
}

# ============================================================================
# CNPG operator install (idempotent)
# ============================================================================

install_cnpg_operator() {
  if helmk status "$CNPG_RELEASE" -n "$CNPG_NS" >/dev/null 2>&1; then
    ok "cloudnative-pg operator already installed (ns: $CNPG_NS)"
    return 0
  fi
  log "installing cloudnative-pg operator (ns: $CNPG_NS, chart $CNPG_CHART_VERSION)"
  helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null 2>&1 || true
  helm repo update cnpg >/dev/null
  helm_install "cloudnative-pg helm install (typically 30-60s)" \
    helm upgrade --install "$CNPG_RELEASE" cnpg/cloudnative-pg \
      --namespace "$CNPG_NS" --create-namespace \
      --version "$CNPG_CHART_VERSION" \
      --wait --timeout 5m
  ok "cloudnative-pg operator ready"
}

# ============================================================================
# CNPG Cluster CR (postgres + pgvector)
# ============================================================================
#
# The "standard" image bundles pgvector but does not pre-create the
# extension in the application database. `postInitApplicationSQL` runs
# once on the application DB right after CNPG creates it, so
# `CREATE EXTENSION vector` lands before agentregistry's first connect.
install_aregistry_pg() {
  log "creating CNPG Postgres cluster '${AREGISTRY_PG_CLUSTER}' (image $AREGISTRY_PG_IMAGE, ${AREGISTRY_PG_INSTANCES} instance, ${AREGISTRY_PG_STORAGE})"
  kc create namespace "$AREGISTRY_NS" --dry-run=client -o yaml | kc apply -f - >/dev/null

  kc apply -f - <<EOF >/dev/null
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ${AREGISTRY_PG_CLUSTER}
  namespace: ${AREGISTRY_NS}
spec:
  instances: ${AREGISTRY_PG_INSTANCES}
  imageName: ${AREGISTRY_PG_IMAGE}
  primaryUpdateStrategy: unsupervised
  bootstrap:
    initdb:
      database: ${AREGISTRY_DB_NAME}
      owner: ${AREGISTRY_DB_USER}
      postInitApplicationSQL:
        - CREATE EXTENSION IF NOT EXISTS vector;
  storage:
    size: ${AREGISTRY_PG_STORAGE}
  monitoring:
    enablePodMonitor: false
EOF

  with_spinner "waiting for CNPG cluster '${AREGISTRY_PG_CLUSTER}' to be ready (typically 1-3 min)" \
    kc -n "$AREGISTRY_NS" wait --for=condition=Ready --timeout=300s \
      cluster.postgresql.cnpg.io/"$AREGISTRY_PG_CLUSTER"
  ok "CNPG Postgres ready (database '${AREGISTRY_DB_NAME}', pgvector enabled)"
}

# Build the postgres connection URL agentregistry's chart expects, from
# the Secret CNPG generates for the application user. CNPG names that
# secret "<cluster>-app" by convention (bootstrap.initdb.owner=appUser).
_aregistry_pg_url() {
  local secret="${AREGISTRY_PG_CLUSTER}-app"
  local user pass host port db
  user="$(kc -n "$AREGISTRY_NS" get secret "$secret" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  pass="$(kc -n "$AREGISTRY_NS" get secret "$secret" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  host="${AREGISTRY_PG_CLUSTER}-rw.${AREGISTRY_NS}.svc.cluster.local"
  port="5432"
  db="$AREGISTRY_DB_NAME"
  [[ -n "$user" && -n "$pass" ]] || return 1
  # `sslmode=require` is the recommended default for CNPG — the operator
  # provisions a server cert via its built-in CA, and libpq honours
  # sslmode=require by encrypting without verifying the chain (which is
  # fine inside the cluster network and avoids needing to mount the CA
  # into the agentregistry pod for this dev sandbox).
  printf 'postgres://%s:%s@%s:%s/%s?sslmode=require\n' "$user" "$pass" "$host" "$port" "$db"
}

# ============================================================================
# JWT key — generate once, reuse across reruns
# ============================================================================

_aregistry_jwt_key() {
  mkdir -p "$SANDBOX_STATE_DIR"
  if [[ ! -s "$AREGISTRY_JWT_FILE" ]]; then
    openssl rand -hex 32 > "$AREGISTRY_JWT_FILE"
    chmod 600 "$AREGISTRY_JWT_FILE"
  fi
  cat "$AREGISTRY_JWT_FILE"
}

# ============================================================================
# Top-level installer — called from cmd_up / cmd_restart
# ============================================================================
#
# Designed to be NON-FATAL: a slow image pull or a flaky CNPG bootstrap
# must never abort `up`. agentregistry is independent of every other
# platform component, so we skip the usual `helm --wait` and bound the
# readiness check explicitly. Same idea as install_kagent.

install_aregistry() {
  (( ${INSTALL_AGENTREGISTRY:-1} )) || { log "skipping agentregistry (INSTALL_AGENTREGISTRY=0)"; return 0; }

  install_cnpg_operator
  install_aregistry_pg

  local pg_url
  if ! pg_url="$(_aregistry_pg_url)"; then
    warn "agentregistry: could not read CNPG app secret yet — skipping helm install"
    warn "debug: kc -n ${AREGISTRY_NS} get secret ${AREGISTRY_PG_CLUSTER}-app"
    return 0
  fi

  local jwt_key; jwt_key="$(_aregistry_jwt_key)"

  # Recover from a previously-failed install. Helm refuses to re-upgrade a
  # release whose last revision ended in STATUS: failed during a fresh
  # install; the only way out is `helm uninstall` first. We only do this
  # for revision-1 failures (i.e. the install never succeeded once) — a
  # later failed upgrade can be re-rolled forward without losing state.
  local helm_status
  helm_status="$(helmk -n "$AREGISTRY_NS" status "$AREGISTRY_RELEASE" -o json 2>/dev/null \
    | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("info",{}).get("status",""), d.get("version",0))' 2>/dev/null || true)"
  if [[ "$helm_status" == "failed 1" ]]; then
    log "previous agentregistry install failed (rev 1) — uninstalling before retry"
    helmk -n "$AREGISTRY_NS" uninstall "$AREGISTRY_RELEASE" >/dev/null 2>&1 || true
  fi

  log "installing agentregistry server (ns: $AREGISTRY_NS, chart $AREGISTRY_CHART_VERSION, image $AREGISTRY_IMAGE_TAG)"
  # No --wait here on purpose: the chart's image is ~150 MB on first
  # pull and the kind node's containerd may need 2-3 min. We rely on the
  # explicit rollout-status check below (5-min budget) instead, mirroring
  # install_kagent. Helm itself returns success once the resources are
  # applied, which is what we want to gate further steps on.
  if ! helm_install "agentregistry helm install" \
        helm upgrade --install "$AREGISTRY_RELEASE" "$AREGISTRY_CHART" \
          --namespace "$AREGISTRY_NS" --create-namespace \
          --version "$AREGISTRY_CHART_VERSION" \
          --set "image.tag=${AREGISTRY_IMAGE_TAG}" \
          --set "config.jwtPrivateKey=${jwt_key}" \
          --set "database.postgres.url=${pg_url}" \
          --set "database.postgres.vectorEnabled=true" \
          --set "database.postgres.bundled.enabled=false" \
          --set "service.type=ClusterIP"; then
    warn "agentregistry helm install failed — skipping; the rest of the sandbox is unaffected."
    warn "debug: helm -n ${AREGISTRY_NS} status ${AREGISTRY_RELEASE} ; kc -n ${AREGISTRY_NS} get pods"
    return 0
  fi

  if with_spinner "waiting for agentregistry pod to become Ready (image pull can take 2-3 min on first run)" \
       kc -n "$AREGISTRY_NS" rollout status deploy/"$AREGISTRY_RELEASE"-agentregistry --timeout=300s; then
    ok "agentregistry ready (UI: https://${AREGISTRY_HOST}:${SANDBOX_HTTPS_PORT})"
  else
    warn "agentregistry not Ready within 5 min — check 'kc -n ${AREGISTRY_NS} get pods'"
    warn "the route is live at https://${AREGISTRY_HOST}:${SANDBOX_HTTPS_PORT} once the pod is Ready"
  fi
}

# ============================================================================
# Istio route — called from sandbox.sh's install_routes when the namespace
# exists (gating prevents a 503 route on --no-agentregistry runs).
# ============================================================================

install_aregistry_routes() {
  aregistry_present || return 0
  # The chart names the Service "<release>-agentregistry" (helm-templated
  # fullname), exposing http=12121, grpc=21212, mcp=31313. The UI lives on
  # the http port — that's what we route at the gateway.
  kc apply -f - <<EOF >/dev/null
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: aregistry
  namespace: ${AREGISTRY_NS}
spec:
  hosts: ["${AREGISTRY_HOST}"]
  gateways: ["${ISTIO_INGRESS_NS}/sandbox-gateway"]
  http:
    - route:
        - destination:
            host: ${AREGISTRY_RELEASE}-agentregistry.${AREGISTRY_NS}.svc.cluster.local
            port: { number: 12121 }
EOF
}

# ============================================================================
# Status reporter — one line for cmd_status
# ============================================================================

aregistry_status() {
  if ! aregistry_present; then
    echo "aregistry: not installed"
    return
  fi
  local pod_ready pg_ready
  pod_ready="$(kc -n "$AREGISTRY_NS" get pod -l "app.kubernetes.io/instance=${AREGISTRY_RELEASE},app.kubernetes.io/name=agentregistry" \
    -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  pg_ready="$(kc -n "$AREGISTRY_NS" get cluster.postgresql.cnpg.io/"$AREGISTRY_PG_CLUSTER" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  if [[ "$pod_ready" == *"True"* && "$pg_ready" == "True" ]]; then
    echo "aregistry: ok (https://${AREGISTRY_HOST}:${SANDBOX_HTTPS_PORT}, pgvector via CNPG)"
  else
    echo "aregistry: installed but not Ready (server=${pod_ready:-?} pg=${pg_ready:-?}) — kc -n ${AREGISTRY_NS} get pods"
  fi
}

# ============================================================================
# Mac-side connection hint, called from cmd_creds
# ============================================================================
#
# Reads the live secrets/files (CNPG app secret, persisted JWT key) and
# prints copy-pasteable login details for both the agentregistry HTTP
# API and the underlying Postgres. Same model as cmd_creds for argo/
# kargo: this command is the explicit "show me the credentials" surface,
# so plaintext is appropriate here.

aregistry_print_creds() {
  aregistry_present || return 0

  local secret="${AREGISTRY_PG_CLUSTER}-app"
  local pg_user pg_pass pg_uri jwt_key
  pg_user="$(kc -n "$AREGISTRY_NS" get secret "$secret" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  pg_pass="$(kc -n "$AREGISTRY_NS" get secret "$secret" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  pg_uri="$(kc -n "$AREGISTRY_NS" get secret "$secret" -o jsonpath='{.data.uri}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  if [[ -s "$AREGISTRY_JWT_FILE" ]]; then jwt_key="$(cat "$AREGISTRY_JWT_FILE")"; fi

  cat <<EOF
agentregistry
  URL:           https://${AREGISTRY_HOST}:${SANDBOX_HTTPS_PORT}
  Auth:          JWT (HMAC-signed) — the chart's config.jwtPrivateKey backs all tokens.
                 No username/password — arctl mints tokens from the signing key below.
  JWT key file:  ${AREGISTRY_JWT_FILE}
  JWT key:       ${jwt_key:-<run 'sandboxctl up' to generate>}
  arctl:         arctl configure --url https://${AREGISTRY_HOST}:${SANDBOX_HTTPS_PORT}

PostgreSQL (CNPG-managed, pgvector preloaded)
  Cluster:       ${AREGISTRY_PG_CLUSTER}  (namespace: ${AREGISTRY_NS})
  Database:      ${AREGISTRY_DB_NAME}
  Username:      ${pg_user:-<not provisioned yet — re-run 'sandboxctl up'>}
  Password:      ${pg_pass:-<not provisioned yet>}
  In-cluster:    ${AREGISTRY_PG_CLUSTER}-rw.${AREGISTRY_NS}.svc.cluster.local:5432  (read-write)
                 ${AREGISTRY_PG_CLUSTER}-ro.${AREGISTRY_NS}.svc.cluster.local:5432  (read-only)
  Connection:    ${pg_uri:-<re-run 'sandboxctl up' once the cluster is ready>}
  From the Mac:  kubectl -n ${AREGISTRY_NS} port-forward svc/${AREGISTRY_PG_CLUSTER}-rw 5432:5432
                 then: psql "postgres://${pg_user:-<user>}:${pg_pass:-<password>}@127.0.0.1:5432/${AREGISTRY_DB_NAME}?sslmode=require"
EOF
}
