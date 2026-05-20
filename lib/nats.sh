# shellcheck shell=bash
# lib/nats.sh — NATS + JetStream installer for sandboxctl.
#
# This is the first lib/<tool>.sh file. The v2.0.0 plan splits each
# install_<tool> from sandbox.sh into a sibling file here (argocd,
# kargo, kagent, gitea, registry, demo-app, reflector). Until then,
# only NATS lives here; sandbox.sh still owns the rest.
#
# Sourced by sandbox.sh; assumes sandbox.sh has already set the common
# globals (CLUSTER_NAME, SANDBOX_DOMAIN, ISTIO_INGRESS_NS, kc, kctx, log,
# ok, warn, die, launchagent_stop, write_pinned_kubeconfig, etc.) and
# that helm + kubectl are on PATH.
#
# Public functions:
#   install_nats              create namespace + helm install + cert + routes
#   install_nats_portfwd      LaunchAgent for kubectl port-forward :4222
#   uninstall_nats_portfwd    inverse — bounded launchctl teardown
#   install_nats_cli          install the `nats` CLI on the Mac
#   uninstall_nats_cli        remove `nats` CLI (if installed by us via brew)
#   nats_status               one-line health for cmd_status
#   nats_print_creds          one-shot info: how to connect from the Mac
#
# Everything is idempotent: reruns of `sandboxctl up` reapply manifests
# and re-render the plist without bouncing healthy state.

# ============================================================================
# Configuration
# ============================================================================

NATS_NS="${NATS_NS:-nats}"
NATS_RELEASE="${NATS_RELEASE:-nats}"
NATS_CHART_VERSION="${NATS_CHART_VERSION:-2.14.0}"
NATS_HOST="${NATS_HOST:-nats.${SANDBOX_DOMAIN}}"

# Mac-side TCP port the LaunchAgent binds for `nats://nats.sandbox.app:4222`.
# 4222 by default — matches the upstream client port so consumers don't
# have to override URLs. Override SANDBOX_NATS_PORT to dodge a conflict.
SANDBOX_NATS_PORT="${SANDBOX_NATS_PORT:-4222}"

# JetStream persistence sizing. 2 GiB is enough for typical local dev
# (streams + KV + object store); bump if you're load-testing.
NATS_JETSTREAM_SIZE="${NATS_JETSTREAM_SIZE:-2Gi}"

# LaunchAgent label + plist path for the NATS port-forward. Distinct from
# SANDBOX_LAUNCHAGENT_LABEL (which handles HTTP/HTTPS) so the two agents
# can be loaded/unloaded independently.
NATS_LAUNCHAGENT_LABEL="${NATS_LAUNCHAGENT_LABEL:-io.github.sandboxctl.nats-portfwd}"
NATS_LAUNCHAGENT_PLIST="${SANDBOX_LAUNCHAGENT_DIR}/${NATS_LAUNCHAGENT_LABEL}.plist"
NATS_PF_LOG="${SANDBOX_STATE_DIR}/nats-portfwd.log"

# TLS Secret holding the cert nats-server presents on :4222. Issued by the
# existing sandbox-ca ClusterIssuer with SANs for both the cluster-DNS
# name and the user-facing nats.${SANDBOX_DOMAIN}.
NATS_TLS_SECRET="${NATS_TLS_SECRET:-nats-server-tls}"

# ============================================================================
# install_nats — chart + cert + routes
# ============================================================================

install_nats() {
  log "installing NATS + JetStream (ns: $NATS_NS, chart $NATS_CHART_VERSION)"

  helm repo add nats https://nats-io.github.io/k8s/helm/charts/ >/dev/null 2>&1 || true
  helm repo update nats >/dev/null

  kc create namespace "$NATS_NS" --dry-run=client -o yaml | kc apply -f - >/dev/null

  # Issue a server cert from the existing sandbox-ca. SANs cover:
  #   - the user-facing host (nats.${SANDBOX_DOMAIN}), used by clients
  #     coming through the Istio TLS-passthrough listener
  #   - the in-cluster DNS names, so apps inside the mesh can verify too
  kc apply -f - <<EOF >/dev/null
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: nats-server
  namespace: ${NATS_NS}
spec:
  secretName: ${NATS_TLS_SECRET}
  duration: 8760h
  renewBefore: 720h
  commonName: ${NATS_HOST}
  dnsNames:
    - ${NATS_HOST}
    - ${NATS_RELEASE}
    - ${NATS_RELEASE}.${NATS_NS}
    - ${NATS_RELEASE}.${NATS_NS}.svc
    - ${NATS_RELEASE}.${NATS_NS}.svc.cluster.local
    - "*.${NATS_RELEASE}.${NATS_NS}.svc.cluster.local"
  issuerRef:
    name: sandbox-ca
    kind: ClusterIssuer
    group: cert-manager.io
EOF
  kc -n "$NATS_NS" wait --for=condition=Ready --timeout=180s certificate/nats-server >/dev/null

  # Helm install. The official chart's value layout (1.2.x):
  #   config.cluster.enabled         - off; single-node is fine for local
  #   config.jetstream.enabled       - on
  #   config.jetstream.fileStore     - PVC-backed storage
  #   config.websocket.enabled       - on for browser/JS clients
  #   config.nats.tls / websocket.tls - reuse our cert-manager Secret
  # `maxSize` matches the PVC so JetStream's `max_file_store` doesn't
  # promise more disk than the PVC actually backs. Without this the
  # chart sets max_file_store to its 10Gi default and JetStream errors
  # out at PVC fill instead of refusing the write.
  with_spinner "NATS helm install + JetStream PVC bind (typically 1–2 min)" \
    helm upgrade --install "$NATS_RELEASE" nats/nats \
      --namespace "$NATS_NS" \
      --version "$NATS_CHART_VERSION" \
      --set "config.cluster.enabled=false" \
      --set "config.jetstream.enabled=true" \
      --set "config.jetstream.fileStore.enabled=true" \
      --set "config.jetstream.fileStore.pvc.size=${NATS_JETSTREAM_SIZE}" \
      --set "config.jetstream.fileStore.maxSize=${NATS_JETSTREAM_SIZE}" \
      --set "config.nats.tls.enabled=true" \
      --set "config.nats.tls.secretName=${NATS_TLS_SECRET}" \
      --set "config.websocket.enabled=true" \
      --set "config.websocket.tls.enabled=false" \
      --set "config.monitor.enabled=true" \
      --wait --timeout 5m

  with_spinner "waiting for NATS pod to become Ready" \
    kc -n "$NATS_NS" wait --for=condition=ready --timeout=180s \
      pod -l "app.kubernetes.io/instance=${NATS_RELEASE},app.kubernetes.io/component=nats"

  install_nats_routes
  write_nats_ca_bundle
  install_nats_cli
  ok "NATS ready (TCP+TLS at nats://${NATS_HOST}:${SANDBOX_NATS_PORT}, WSS at https://${NATS_HOST})"
}

# install_nats_routes — applies a VirtualService for the WebSocket
# endpoint on the existing :8443 HTTPS listener so https://${NATS_HOST}
# routes to nats:8080. Istio terminates TLS at the gateway; upstream is
# plain WebSocket (config.websocket.tls.enabled=false in install_nats).
#
# TCP+TLS at :4222 is currently delivered to the Mac via a direct
# kubectl port-forward LaunchAgent (install_nats_portfwd) that bypasses
# the gateway. The TLS-PASSTHROUGH route through Istio is functional
# in Envoy's listener config but the upstream traversal under ambient
# mesh deadlocks; getting it working is a follow-up. The direct
# port-forward gives the same user-facing endpoint without the gap.
install_nats_routes() {
  kc apply -f - <<EOF >/dev/null
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: nats-ws
  namespace: ${NATS_NS}
spec:
  hosts: ["${NATS_HOST}"]
  gateways: ["${ISTIO_INGRESS_NS}/sandbox-gateway"]
  http:
    - route:
        - destination:
            host: ${NATS_RELEASE}.${NATS_NS}.svc.cluster.local
            port: { number: 8080 }
EOF
}

# ============================================================================
# install_nats_portfwd — second LaunchAgent for :4222 on the Mac
# ============================================================================
#
# The HTTP/HTTPS LaunchAgent (sandbox.sh's install_portfwd) forwards
# 8080/8443. NATS gets its own agent so the two can be unloaded
# independently and so a NATS hiccup doesn't take down argo/kargo
# routing. Same self-healing pattern: regenerate the pinned kubeconfig,
# smoke-test before launchd, then bound-timeout teardown on uninstall.

install_nats_portfwd() {
  log "installing NATS port-forward LaunchAgent (Mac :${SANDBOX_NATS_PORT} → svc/${NATS_RELEASE} :4222)"
  uninstall_nats_portfwd

  _nats_check_port_or_die "$SANDBOX_NATS_PORT"

  # write_pinned_kubeconfig is sandbox.sh's helper; it's already a no-op
  # if the file is fresh, so calling it again here is cheap insurance.
  write_pinned_kubeconfig
  # Forward straight to svc/nats. Routing through the istio gateway
  # (TLS PASSTHROUGH on :4222) is wired in install_nats_routes for
  # in-cluster apps that talk to nats.${SANDBOX_DOMAIN}, but the
  # ambient-mesh upstream path from the gateway pod to the nats pod
  # currently times out under Istio 1.29 ambient. Direct port-forward
  # gives the Mac a working nats:// endpoint today; the gateway path
  # is a follow-up.
  if ! kubectl --kubeconfig "$SANDBOX_KUBECONFIG" --context "$(kctx)" \
        -n "$NATS_NS" get svc "$NATS_RELEASE" >/dev/null 2>&1; then
    die "NATS service ${NATS_RELEASE} not found in namespace ${NATS_NS} — refusing to install a LaunchAgent that will respawn-loop. Try: sandboxctl restart"
  fi

  _write_nats_portfwd_plist
  launchctl load "$NATS_LAUNCHAGENT_PLIST" || \
    die "launchctl load failed for ${NATS_LAUNCHAGENT_PLIST} — check the file then 'sandboxctl restart'"

  local i
  for ((i=1; i<=30; i++)); do
    if nc -z 127.0.0.1 "$SANDBOX_NATS_PORT" 2>/dev/null; then
      ok "NATS port-forward ready on 127.0.0.1:${SANDBOX_NATS_PORT}"
      return
    fi
    sleep 1
  done
  warn "LaunchAgent loaded but :${SANDBOX_NATS_PORT} did not bind within 30s"
  warn "last lines of ${NATS_PF_LOG}:"
  tail -5 "$NATS_PF_LOG" 2>&1 | sed 's/^/    /' >&2
  die "NATS port-forward failed to bind — fix the cause above and run 'sandboxctl restart'"
}

uninstall_nats_portfwd() {
  # Match either of two child-process flavours: the current
  # istio-ingress :4222 forward (post-Istio-passthrough fix) and the
  # legacy direct svc/<NATS_RELEASE> forward. Both end with
  # "${SANDBOX_NATS_PORT}:4222" — but pgrep'ing on the port might
  # collide with the HTTPS LaunchAgent if SANDBOX_NATS_PORT happens to
  # equal SANDBOX_HTTPS_PORT (it never does by default), so we narrow
  # by the LaunchAgent's label-bearing argv.
  pkill -f "port-forward .*${SANDBOX_NATS_PORT}:4222" >/dev/null 2>&1 || true
  if [[ -f "$NATS_LAUNCHAGENT_PLIST" ]] || \
     launchctl list 2>/dev/null | awk '{print $3}' | grep -qx "$NATS_LAUNCHAGENT_LABEL"; then
    log "unloading + removing LaunchAgent ${NATS_LAUNCHAGENT_LABEL}"
    launchagent_stop "$NATS_LAUNCHAGENT_LABEL" "$NATS_LAUNCHAGENT_PLIST"
  fi
  pkill -f "port-forward .*${SANDBOX_NATS_PORT}:4222" >/dev/null 2>&1 || true
}

_nats_check_port_or_die() {
  local port="$1" pid cmdline
  pid="$(port_listener_pid "$port")"
  [[ -z "$pid" ]] && return 0
  cmdline="$(ps -p "$pid" -o command= 2>/dev/null || echo unknown)"
  # Recognise either the current (istio-ingress) or the legacy
  # (svc/<NATS_RELEASE>) port-forward as ours, plus the literal
  # "${SANDBOX_NATS_PORT}:4222" tail which both flavours share.
  if [[ "$cmdline" == *"port-forward"*"${SANDBOX_NATS_PORT}:4222"* ]]; then
    log "NATS port :${port} held by stale sandboxctl port-forward (pid ${pid}) — killing"
    kill "$pid" 2>/dev/null || true
    sleep 1
    return 0
  fi
  local alt=$(( port + 100 ))
  die "NATS port :${port} is in use by an unrelated process (pid ${pid}: ${cmdline}).
       Either stop that process, or pick a different port:
         SANDBOX_NATS_PORT=${alt} sandboxctl restart"
}

_write_nats_portfwd_plist() {
  local kubectl_path
  kubectl_path="$(command -v kubectl)" || die "kubectl not found on PATH"
  mkdir -p "$SANDBOX_LAUNCHAGENT_DIR" "$SANDBOX_STATE_DIR"
  [[ -f "$SANDBOX_KUBECONFIG" ]] || \
    die "pinned kubeconfig ${SANDBOX_KUBECONFIG} missing — run 'sandboxctl restart'"
  cat > "$NATS_LAUNCHAGENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTD/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${NATS_LAUNCHAGENT_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${kubectl_path}</string>
    <string>--kubeconfig</string><string>${SANDBOX_KUBECONFIG}</string>
    <string>--context</string><string>$(kctx)</string>
    <string>port-forward</string>
    <string>--address</string><string>127.0.0.1</string>
    <string>-n</string><string>${NATS_NS}</string>
    <string>svc/${NATS_RELEASE}</string>
    <string>${SANDBOX_NATS_PORT}:4222</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>StandardOutPath</key><string>${NATS_PF_LOG}</string>
  <key>StandardErrorPath</key><string>${NATS_PF_LOG}</string>
</dict>
</plist>
EOF
}

# ============================================================================
# nats CLI auto-install on the Mac
# ============================================================================
#
# Mirrors the arctl pattern (install at `up`, optionally remove at
# `down`/`purge`). Path:
#   1. respect SANDBOX_KEEP_NATS_CLI=1 / INSTALL_NATS_CLI=0 — skip entirely
#   2. if `nats` is already on PATH, no-op
#   3. brew install nats-io/nats-tools/nats (preferred; uniform across Macs)
#   4. fallback: download release binary and drop into ARCTL_INSTALL_DIR
#      (usually /usr/local/bin) the same way arctl does
#
# Marker file ~/.sandboxctl/.nats-cli-managed records that we installed
# the CLI ourselves, so uninstall only acts on managed installs and
# never touches a brew install the user did before sandboxctl ran.

NATS_CLI_MARKER="${SANDBOX_STATE_DIR}/.nats-cli-managed"

install_nats_cli() {
  [[ "${INSTALL_NATS_CLI:-1}" == "1" ]] || { log "skipping nats CLI install (INSTALL_NATS_CLI=0)"; return 0; }
  if command -v nats >/dev/null 2>&1; then
    ok "nats CLI already on PATH ($(command -v nats))"
    return 0
  fi
  if command -v brew >/dev/null 2>&1; then
    log "installing nats CLI via Homebrew (nats-io/nats-tools/nats)"
    if brew install nats-io/nats-tools/nats >/dev/null 2>&1; then
      mkdir -p "$SANDBOX_STATE_DIR"
      echo "brew" > "$NATS_CLI_MARKER"
      ok "nats CLI installed — try: nats --tlsca <path> --server tls://${NATS_HOST}:${SANDBOX_NATS_PORT} server check connection"
      return 0
    fi
    warn "brew install nats failed — falling back to direct download"
  fi
  _install_nats_cli_direct
}

# Direct download fallback. Pulls the release tarball from the natscli
# repo and drops the `nats` binary into ARCTL_INSTALL_DIR so it's on
# the same canonical path as arctl. ARCTL_INSTALL_DIR defaults to
# /usr/local/bin and is root-owned on macOS — sudo only when needed.
_install_nats_cli_direct() {
  command -v curl >/dev/null 2>&1 || { warn "nats CLI: curl not found — skipping install"; return 0; }
  local arch os
  case "$(uname -m)" in
    arm64|aarch64) arch=arm64 ;;
    x86_64|amd64)  arch=amd64 ;;
    *) warn "nats CLI: unsupported architecture $(uname -m) — skipping"; return 0 ;;
  esac
  os="$(uname | tr '[:upper:]' '[:lower:]')"

  # Ask GitHub for the latest release tag. Network failures here are
  # non-fatal: we already validated NATS itself is up; the CLI is a
  # convenience.
  local tag
  tag="$(curl -fsSL "https://api.github.com/repos/nats-io/natscli/releases/latest" 2>/dev/null \
    | awk -F'"' '/"tag_name":/{print $4; exit}')"
  if [[ -z "$tag" ]]; then
    warn "nats CLI: could not resolve latest version (offline?) — skipping"; return 0
  fi
  local ver="${tag#v}"
  local fname="nats-${ver}-${os}-${arch}.zip"
  local url="https://github.com/nats-io/natscli/releases/download/${tag}/${fname}"
  local tmp; tmp="$(mktemp -d -t natscli.XXXXXX)"
  log "downloading nats CLI ${tag} from ${url}"
  if ! curl -fsSL "$url" -o "${tmp}/nats.zip"; then
    rm -rf "$tmp"; warn "nats CLI: download failed — skipping"; return 0
  fi
  if ! (cd "$tmp" && unzip -q nats.zip); then
    rm -rf "$tmp"; warn "nats CLI: unzip failed — skipping"; return 0
  fi
  local extracted
  extracted="$(find "$tmp" -type f -name 'nats' -perm +111 2>/dev/null | head -1)"
  [[ -n "$extracted" ]] || { rm -rf "$tmp"; warn "nats CLI: binary not found in archive — skipping"; return 0; }
  if [[ -w "${ARCTL_INSTALL_DIR:-/usr/local/bin}" ]]; then
    install -m 0755 "$extracted" "${ARCTL_INSTALL_DIR:-/usr/local/bin}/nats"
  else
    prime_sudo
    sudo install -m 0755 "$extracted" "${ARCTL_INSTALL_DIR:-/usr/local/bin}/nats"
  fi
  rm -rf "$tmp"
  mkdir -p "$SANDBOX_STATE_DIR"
  echo "direct:${ARCTL_INSTALL_DIR:-/usr/local/bin}/nats" > "$NATS_CLI_MARKER"
  ok "nats CLI ${tag} installed -> ${ARCTL_INSTALL_DIR:-/usr/local/bin}/nats"
}

uninstall_nats_cli() {
  [[ "${SANDBOX_KEEP_NATS_CLI:-0}" == "1" ]] && { ok "keeping nats CLI (SANDBOX_KEEP_NATS_CLI=1)"; return 0; }
  [[ -f "$NATS_CLI_MARKER" ]] || { ok "nats CLI was not installed by sandboxctl — leaving alone"; return 0; }
  local how; how="$(cat "$NATS_CLI_MARKER" 2>/dev/null || true)"
  case "$how" in
    brew)
      log "removing nats CLI (brew uninstall)"
      brew uninstall nats >/dev/null 2>&1 || true
      ;;
    direct:*)
      local path="${how#direct:}"
      if [[ -e "$path" ]]; then
        log "removing nats CLI ($path)"
        if [[ -w "$(dirname "$path")" ]]; then rm -f "$path"
        else prime_sudo; sudo rm -f "$path"; fi
      fi
      ;;
    *) ;;
  esac
  rm -f "$NATS_CLI_MARKER"
  ok "nats CLI removed"
}

# ============================================================================
# Mac-side connection hint, called from cmd_up and cmd_creds
# ============================================================================
nats_print_creds() {
  local ca; ca="${SANDBOX_STATE_DIR}/sandbox-ca.crt"
  echo "NATS:"
  echo "  TCP+TLS:    nats://${NATS_HOST}:${SANDBOX_NATS_PORT}"
  echo "  WebSocket:  wss://${NATS_HOST}:${SANDBOX_HTTPS_PORT}"
  if [[ -f "$ca" ]]; then
    echo "  CA bundle:  ${ca}"
    echo "  smoke test: nats --tlsca ${ca} --server tls://${NATS_HOST}:${SANDBOX_NATS_PORT} server check connection"
  else
    echo "  CA bundle:  (run 'sandboxctl up' to materialise; the system keychain is also trusted)"
  fi
}

# write_nats_ca_bundle dumps the cluster's nats-server CA into
# $SANDBOX_STATE_DIR so users have a canonical path to point clients
# at. Uses the same secret cert-manager issued.
write_nats_ca_bundle() {
  local ca_path="${SANDBOX_STATE_DIR}/sandbox-ca.crt"
  mkdir -p "$SANDBOX_STATE_DIR"
  if kc -n "$NATS_NS" get secret "$NATS_TLS_SECRET" >/dev/null 2>&1; then
    kc -n "$NATS_NS" get secret "$NATS_TLS_SECRET" -o jsonpath='{.data.ca\.crt}' 2>/dev/null \
      | base64 -d > "${ca_path}.tmp" 2>/dev/null || true
    if [[ -s "${ca_path}.tmp" ]]; then
      mv "${ca_path}.tmp" "$ca_path"
      chmod 644 "$ca_path"
    else
      rm -f "${ca_path}.tmp"
    fi
  fi
}

# ============================================================================
# Status reporter — one line, called by cmd_status
# ============================================================================

nats_status() {
  if ! kc -n "$NATS_NS" get svc "$NATS_RELEASE" >/dev/null 2>&1; then
    echo "nats:      not installed"
    return
  fi
  local ready
  ready="$(kc -n "$NATS_NS" get pod -l "app.kubernetes.io/instance=${NATS_RELEASE},app.kubernetes.io/component=nats" \
    -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  if [[ "$ready" == *"True"* ]]; then
    if nc -z 127.0.0.1 "$SANDBOX_NATS_PORT" 2>/dev/null; then
      echo "nats:      ok (TCP nats://${NATS_HOST}:${SANDBOX_NATS_PORT}, WSS https://${NATS_HOST})"
    else
      echo "nats:      pod ready, :${SANDBOX_NATS_PORT} not bound — see ${NATS_PF_LOG}"
    fi
  else
    echo "nats:      installed but not Ready — kubectl -n ${NATS_NS} describe pod"
  fi
}
