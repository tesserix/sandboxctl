# shellcheck shell=bash
# lib/agentgateway.sh — agentgateway (https://agentgateway.dev), the
# default-on AI Agentic Gateway.
#
# agentgateway is a Linux Foundation–hosted, Gateway-API-native proxy
# purpose-built for AI traffic: agent-to-LLM, agent-to-tool (MCP), and
# agent-to-agent (A2A). It ships as two OCI Helm charts under
# cr.agentgateway.dev (a CRDs chart and a control-plane chart) and the
# control plane creates the data-plane Deployment + Service for any
# Gateway resource that names its GatewayClass.
#
# What this lib installs (idempotent):
#   1. Upstream Kubernetes Gateway API standard CRDs (kubectl --server-side
#      apply, so re-runs are no-ops).
#   2. The `agentgateway-crds` OCI Helm chart into `agentgateway-system`.
#   3. The `agentgateway` OCI Helm chart (control plane) into the same ns.
#   4. An `AgentgatewayParameters` resource that (a) rebinds the data-plane
#      admin/UI listener from 127.0.0.1:15000 to 0.0.0.0:15000 (it ships
#      bound to loopback by default — see upstream Admin UI docs), and
#      (b) overlays the proxy Service to expose port 15000 alongside the
#      regular listener-80, so the admin UI is reachable from inside the
#      cluster without a port-forward.
#   5. A `Gateway` resource (gateway.networking.k8s.io/v1) with
#      gatewayClassName=agentgateway, listener port 80,
#      allowedRoutes.namespaces.from=All, and an
#      `infrastructure.parametersRef` pointing at (4) — so any product
#      chart can attach its own HTTPRoute later without coordinating with
#      sandboxctl.
#   6. An Istio VirtualService at https://agentgateway.${SANDBOX_DOMAIN}
#      pointing at the data-plane Service's admin-ui port (15000), so the
#      public URL serves the agentgateway Admin UI (HTTP 200 / HTML)
#      out of the box. Without this, the proxy returns 404 on / because
#      no HTTPRoutes are attached yet — which is correct but not useful
#      as a smoke-test landing page.
#
# Sourced by sandbox.sh; assumes the common globals + helpers are set
# (SANDBOX_DOMAIN, ISTIO_INGRESS_NS, kc, helm_install, with_spinner,
# log/ok/warn/die) and helm + kubectl + curl are on PATH.
#
# Public functions called from sandbox.sh:
#   install_agentgateway          — full install (gated on INSTALL_AGENTGATEWAY)
#   install_agentgateway_routes   — Istio VirtualService for the data plane
#   agentgateway_present          — predicate for route/host/status gating
#   agentgateway_status           — one-line status for cmd_status
#   agentgateway_print_creds      — connection details for cmd_creds
#
# Extension hooks (for local-dev integration later):
#   - The Gateway accepts HTTPRoutes from any namespace, so adding an LLM
#     provider, an MCP backend, or a per-product agent route is just a
#     `kubectl apply` of an HTTPRoute that names this Gateway as a parentRef.
#   - All chart versions, namespaces, hostnames, and listener ports below
#     are env-overridable — pin AGENTGATEWAY_CHART_VERSION /
#     GATEWAY_API_VERSION for reproducibility, or override
#     AGENTGATEWAY_NS/_GATEWAY_NAME to deploy a second instance side by side.

# ============================================================================
# Configuration
# ============================================================================

AGENTGATEWAY_NS="${AGENTGATEWAY_NS:-agentgateway-system}"
AGENTGATEWAY_RELEASE="${AGENTGATEWAY_RELEASE:-agentgateway}"
AGENTGATEWAY_CRDS_RELEASE="${AGENTGATEWAY_CRDS_RELEASE:-agentgateway-crds}"
AGENTGATEWAY_CHART="${AGENTGATEWAY_CHART:-oci://cr.agentgateway.dev/charts/agentgateway}"
AGENTGATEWAY_CRDS_CHART="${AGENTGATEWAY_CRDS_CHART:-oci://cr.agentgateway.dev/charts/agentgateway-crds}"
# Pin both helm releases to the same upstream tag — the control plane and
# CRDs chart are versioned in lockstep upstream, and pinning gives a
# reproducible install.
AGENTGATEWAY_CHART_VERSION="${AGENTGATEWAY_CHART_VERSION:-v1.2.0}"

# Upstream Kubernetes Gateway API CRDs version. agentgateway requires the
# v1 GatewayClass / Gateway / HTTPRoute kinds; v1.5.0 is the published
# baseline at the time this lib was written. server-side apply is
# idempotent so re-running `up` is safe.
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.5.0}"
GATEWAY_API_MANIFEST_URL="${GATEWAY_API_MANIFEST_URL:-https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml}"

# The Gateway CR we create — and the data-plane Service the control plane
# creates in turn (the controller names the Service after the Gateway).
AGENTGATEWAY_GATEWAY_NAME="${AGENTGATEWAY_GATEWAY_NAME:-agentgateway-proxy}"
AGENTGATEWAY_LISTENER_PORT="${AGENTGATEWAY_LISTENER_PORT:-80}"

# Admin UI port. The agentgateway data-plane binary serves a built-in
# Admin UI at /ui (and 308-redirects / -> /ui) on this port; upstream
# binds it to 127.0.0.1 by default, so we rebind it to 0.0.0.0 via
# AgentgatewayParameters.rawConfig to make it reachable through the
# proxy Service.
AGENTGATEWAY_ADMIN_PORT="${AGENTGATEWAY_ADMIN_PORT:-15000}"

AGENTGATEWAY_HOST="${AGENTGATEWAY_HOST:-agentgateway.${SANDBOX_DOMAIN}}"

# Gate: default-on. The control plane is small (~150 MB total across the
# controller and one data-plane proxy pod) so it fits in the default 4 CPU
# / 6 GB podman VM. Disable with `up --no-agentgateway` or
# INSTALL_AGENTGATEWAY=0.
INSTALL_AGENTGATEWAY="${INSTALL_AGENTGATEWAY:-1}"

# ============================================================================
# Predicate
# ============================================================================

agentgateway_present() {
  kc get ns "$AGENTGATEWAY_NS" >/dev/null 2>&1
}

# ============================================================================
# Installer — called from cmd_up. NON-FATAL: a slow image pull or a flaky
# chart must never abort `up`, so every failure path warns and returns 0.
# ============================================================================

install_agentgateway() {
  (( ${INSTALL_AGENTGATEWAY:-1} )) || { log "skipping agentgateway (INSTALL_AGENTGATEWAY=0; default-on — re-enable with --with-agentgateway or INSTALL_AGENTGATEWAY=1)"; return 0; }

  log "installing agentgateway (ns: $AGENTGATEWAY_NS, chart $AGENTGATEWAY_CHART @ $AGENTGATEWAY_CHART_VERSION)"

  # 1. Upstream Gateway API CRDs. server-side apply lets multiple owners
  # coexist on the same CRDs without ripping each other's fields, and
  # makes re-runs of `up` no-ops.
  if ! with_spinner "applying Kubernetes Gateway API CRDs ($GATEWAY_API_VERSION)" \
       kc apply --server-side -f "$GATEWAY_API_MANIFEST_URL"; then
    warn "agentgateway: failed to apply Gateway API CRDs from $GATEWAY_API_MANIFEST_URL — skipping; the rest of the sandbox is unaffected."
    return 0
  fi

  # 2. agentgateway CRDs chart. --create-namespace because both helm
  # releases land in the same namespace and we don't pre-create it.
  if ! helm_install "agentgateway CRDs helm install (typically <1 min)" \
       helm upgrade --install "$AGENTGATEWAY_CRDS_RELEASE" "$AGENTGATEWAY_CRDS_CHART" \
         --namespace "$AGENTGATEWAY_NS" --create-namespace \
         --version "$AGENTGATEWAY_CHART_VERSION" \
         --wait --timeout 3m; then
    warn "agentgateway: CRDs helm install failed — skipping; the rest of the sandbox is unaffected."
    warn "debug: helm -n ${AGENTGATEWAY_NS} status ${AGENTGATEWAY_CRDS_RELEASE} ; kc -n ${AGENTGATEWAY_NS} get pods"
    return 0
  fi

  # 3. agentgateway control-plane chart. Lean overrides keep the controller
  # comfortable on a laptop VM — no CPU limit (so it doesn't get throttled),
  # small CPU/memory request, modest memory cap. The chart's value keys
  # follow the standard Helm convention (resources.requests.* /
  # resources.limits.*); if upstream renames them an `--install` will still
  # succeed without these overrides, just at the chart defaults.
  if ! helm_install "agentgateway helm install (typically 1–2 min)" \
       helm upgrade --install "$AGENTGATEWAY_RELEASE" "$AGENTGATEWAY_CHART" \
         --namespace "$AGENTGATEWAY_NS" --create-namespace \
         --version "$AGENTGATEWAY_CHART_VERSION" \
         --set 'replicaCount=1' \
         --set 'resources.requests.cpu=25m' \
         --set 'resources.requests.memory=64Mi' \
         --set 'resources.limits.memory=256Mi' \
         --wait --timeout 5m; then
    warn "agentgateway: helm install failed — skipping; the rest of the sandbox is unaffected."
    warn "debug: helm -n ${AGENTGATEWAY_NS} status ${AGENTGATEWAY_RELEASE} ; kc -n ${AGENTGATEWAY_NS} get pods"
    return 0
  fi

  # 4. AgentgatewayParameters. Two jobs here:
  #    a) rawConfig: rebind the built-in Admin UI from 127.0.0.1:15000 to
  #       0.0.0.0:15000 so it's reachable through the proxy Service. The
  #       UI ships bound to loopback by default and the upstream
  #       Kubernetes docs only show port-forward as the access path.
  #    b) service overlay: replace the generated Service ports list (which
  #       only includes listener-80) with one that also exposes the
  #       admin-ui port. We use $patch: replace because Strategic Merge
  #       Patch on `ports` would merge by name and leave the original
  #       listener-80 behind unchanged — that's actually what we want, so
  #       we list it explicitly instead of inheriting it.
  if ! kc apply --server-side -f - <<EOF >/dev/null 2>&1
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayParameters
metadata:
  name: ${AGENTGATEWAY_GATEWAY_NAME}
  namespace: ${AGENTGATEWAY_NS}
spec:
  rawConfig:
    config:
      adminAddr: "0.0.0.0:${AGENTGATEWAY_ADMIN_PORT}"
  service:
    spec:
      ports:
        - \$patch: replace
        - name: listener-80
          port: ${AGENTGATEWAY_LISTENER_PORT}
          targetPort: ${AGENTGATEWAY_LISTENER_PORT}
          protocol: TCP
        - name: admin-ui
          port: ${AGENTGATEWAY_ADMIN_PORT}
          targetPort: ${AGENTGATEWAY_ADMIN_PORT}
          protocol: TCP
EOF
  then
    warn "agentgateway: applying AgentgatewayParameters failed — admin UI may not be reachable, the rest of the sandbox is unaffected."
  fi

  # 5. Gateway CR. allowedRoutes.namespaces.from=All so any product chart
  # in any namespace can attach an HTTPRoute later — that's the
  # "adaptable to local dev integration" hook the user asked for. The
  # parametersRef wires in the AgentgatewayParameters above.
  if ! kc apply -f - <<EOF >/dev/null 2>&1
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${AGENTGATEWAY_GATEWAY_NAME}
  namespace: ${AGENTGATEWAY_NS}
spec:
  gatewayClassName: agentgateway
  infrastructure:
    parametersRef:
      group: agentgateway.dev
      kind: AgentgatewayParameters
      name: ${AGENTGATEWAY_GATEWAY_NAME}
  listeners:
    - name: http
      protocol: HTTP
      port: ${AGENTGATEWAY_LISTENER_PORT}
      allowedRoutes:
        namespaces: { from: All }
EOF
  then
    warn "agentgateway: applying Gateway resource failed — skipping; the rest of the sandbox is unaffected."
    return 0
  fi

  # 6. Wait on Programmed=True (Gateway-API-canonical "controller has
  # reconciled this Gateway and the data plane is ready"). Falls back
  # gracefully when the controller is slow — `up` continues either way.
  if with_spinner "waiting for agentgateway data plane to become Programmed" \
       kc -n "$AGENTGATEWAY_NS" wait --for=condition=Programmed --timeout=180s "gateway/${AGENTGATEWAY_GATEWAY_NAME}"; then
    ok "agentgateway ready (Admin UI: https://${AGENTGATEWAY_HOST}:${SANDBOX_HTTPS_PORT}/ui/)"
  else
    warn "agentgateway not Programmed within 3 min — check 'kc -n ${AGENTGATEWAY_NS} get gateway,pods'"
    warn "the Admin UI goes live at https://${AGENTGATEWAY_HOST}:${SANDBOX_HTTPS_PORT}/ui/ once the Gateway is Programmed"
  fi
}

# ============================================================================
# Istio route — called from sandbox.sh's install_routes (present-gated so a
# --no-agentgateway run doesn't leave a 503 route behind).
# ============================================================================

install_agentgateway_routes() {
  agentgateway_present || return 0
  # Route the public hostname to the admin UI port (15000), not the
  # listener-80 port. The data-plane proxy has zero HTTPRoutes attached
  # by default and would return 404 on listener-80 — so visiting
  # https://agentgateway.${SANDBOX_DOMAIN} would look broken even though
  # the gateway is healthy. Pointing it at the admin UI makes / serve a
  # 308 redirect to /ui (HTTP 200, the Admin UI HTML) so the URL is a
  # working landing page out of the box. Product charts that want to
  # serve their own traffic at this hostname can attach an HTTPRoute to
  # the agentgateway-proxy Gateway and add their own VirtualService at a
  # different host.
  kc apply -f - <<EOF >/dev/null
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: agentgateway
  namespace: ${AGENTGATEWAY_NS}
spec:
  hosts: ["${AGENTGATEWAY_HOST}"]
  gateways: ["${ISTIO_INGRESS_NS}/sandbox-gateway"]
  http:
    - route:
        - destination:
            host: ${AGENTGATEWAY_GATEWAY_NAME}.${AGENTGATEWAY_NS}.svc.cluster.local
            port: { number: ${AGENTGATEWAY_ADMIN_PORT} }
EOF
}

# ============================================================================
# Status reporter — one line for cmd_status.
# ============================================================================

agentgateway_status() {
  agentgateway_present || { echo "agentgateway: not installed"; return; }
  local programmed
  programmed="$(kc -n "$AGENTGATEWAY_NS" get gateway "$AGENTGATEWAY_GATEWAY_NAME" \
    -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)"
  if [[ "$programmed" == "True" ]]; then
    echo "agentgateway: ok (Admin UI: https://${AGENTGATEWAY_HOST}:${SANDBOX_HTTPS_PORT}/ui/, Gateway-API proxy for AI traffic)"
  else
    echo "agentgateway: installed but Gateway not Programmed — kc -n ${AGENTGATEWAY_NS} get gateway,pods"
  fi
}

# ============================================================================
# Mac-side connection hint
# ============================================================================

agentgateway_print_creds() {
  agentgateway_present || return 0
  cat <<EOF
agentgateway (default AI Agentic Gateway — Gateway-API-native, MCP/A2A/LLM)
  Admin UI:     https://${AGENTGATEWAY_HOST}:${SANDBOX_HTTPS_PORT}/ui/  (also: / 308-redirects to /ui)
  Data plane:   http://${AGENTGATEWAY_GATEWAY_NAME}.${AGENTGATEWAY_NS}.svc.cluster.local:${AGENTGATEWAY_LISTENER_PORT}  (in-cluster, no HTTPRoutes attached → 404 by design)
  Admin port:   http://${AGENTGATEWAY_GATEWAY_NAME}.${AGENTGATEWAY_NS}.svc.cluster.local:${AGENTGATEWAY_ADMIN_PORT}      (in-cluster, serves the Admin UI)
  Gateway:      ${AGENTGATEWAY_NS}/${AGENTGATEWAY_GATEWAY_NAME}  (gatewayClassName: agentgateway)
  Auth:         none in the OSS distribution by default — bring your own auth via HTTPRoute filters or upstream LLM creds.
  Try it:       curl -sk -o /dev/null -w 'HTTP %{http_code}\\n' https://${AGENTGATEWAY_HOST}:${SANDBOX_HTTPS_PORT}/ui/
  Add a route:  kubectl apply -f - <<YAML
                apiVersion: gateway.networking.k8s.io/v1
                kind: HTTPRoute
                metadata: { name: my-llm, namespace: <your-ns> }
                spec:
                  parentRefs: [{ namespace: ${AGENTGATEWAY_NS}, name: ${AGENTGATEWAY_GATEWAY_NAME} }]
                  rules:
                    - matches: [{ path: { type: PathPrefix, value: /v1 } }]
                      backendRefs: [{ name: <your-upstream-svc>, port: <port> }]
                YAML
  Docs:         https://agentgateway.dev/docs/kubernetes/
EOF
}
