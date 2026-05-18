# sandboxctl

A one-command local Kubernetes sandbox for macOS. Spins up a kind cluster
with Argo CD, Kargo, an Istio ambient mesh and a wildcard-cert ingress, plus
the host wiring (DNS, port-forward, root CA trust) so you can open
`https://argo.sandbox.app:8443` in your browser straight after `up`.

## What you get

After `sandboxctl up`:

| URL | App |
|---|---|
| `https://argo.sandbox.app:8443` | Argo CD |
| `https://kargo.sandbox.app:8443` | Kargo |
| `https://demo-app.sandbox.app:8443` | a small demo deployment |

All three are served by an Istio gateway behind a wildcard cert that's
trusted by macOS — no browser warnings, no manual port-forwards.

## Requirements

- macOS (Apple Silicon or Intel)
- Homebrew, with these formulae available: `kind`, `kubectl`, `helm`, `go`,
  and one of `podman` (recommended) or `docker`
- Roughly 6 GiB of free RAM for the kind node + cluster workloads

`sandboxctl setup-podman` will install and configure podman for you if it's
not yet ready (rootful mode, 6 GiB memory).

## Install

```sh
git clone https://github.com/zendesk/sandboxctl.git
cd sandboxctl
./install.sh
```

This builds the Go CLI and drops it in `$GOBIN` (or `$GOPATH/bin`,
defaulting to `$HOME/go/bin`). Make sure that directory is on your `PATH`.

## Quickstart

```sh
sandboxctl up        # creates everything, ~5–8 min on first run
sandboxctl status    # cluster health + URLs
sandboxctl creds     # login details for Argo CD and Kargo
sandboxctl down      # tear it all down
```

The first `up` will prompt for `sudo` once — it needs root to add three
entries to `/etc/hosts` and trust the local root CA in the System keychain.
After that it's silent on subsequent runs.

## How it fits together

```
     Browser
       │
       ▼ https://*.sandbox.app:8443
   /etc/hosts (127.0.0.1)
       │
       ▼
   LaunchAgent: kubectl port-forward
       │
       ▼ Mac:8443 → Service:8443
   ┌──────────────── kind cluster ────────────────┐
   │  Istio gateway (wildcard TLS via cert-manager)│
   │       │                                       │
   │       ├── argocd-server (argocd ns)           │
   │       ├── kargo-api      (kargo ns)           │
   │       └── demo-app       (demo-app ns)        │
   └───────────────────────────────────────────────┘
```

The pieces:

- **kind** — single-node Kubernetes in a container, run via podman or docker
- **cert-manager** — bootstrap CA → wildcard certificate for `*.sandbox.app`
- **Istio ambient** — `istio-base` + `istiod` + `istio-cni` + `ztunnel` +
  `istio/gateway`. The gateway serves TLS with the wildcard cert.
- **Argo CD, Kargo, demo app** — installed via Helm into their own namespaces
- **macOS LaunchAgent** — runs `kubectl port-forward` so the gateway is
  reachable on `127.0.0.1:8443`. Survives reboots, auto-restarts on failure.
- **State file** at `~/.sandboxctl/setup.yaml` records the live config

## Commands

```
setup-podman   install/configure rootful podman machine (one-time)
trust-ca       trust the sandbox root CA in the System keychain (sudo)
untrust-ca     remove the root CA from the System keychain (sudo)

up             create cluster + install everything
down           remove cluster, LaunchAgent, /etc/hosts entries, keychain CA
purge          down + remove ~/.sandboxctl (prompts for confirmation)
restart        down + up

status         cluster + workload status + URLs
validate       curl each URL from the Mac and report HTTP codes
creds          full login details (URLs + admin creds)
argocd-ui      Argo CD URL + admin creds
kargo-ui       Kargo URL + admin creds
tui            live status dashboard
```

## Configuration

Everything is overridable via env vars. Defaults work for most people.

| Variable | Default | What it does |
|---|---|---|
| `SANDBOX_DOMAIN` | `sandbox.app` | DNS suffix for the three hostnames |
| `SANDBOX_CLUSTER_NAME` | `sandboxctl` | kind cluster name |
| `SANDBOX_HTTP_PORT` | `8080` | host HTTP port |
| `SANDBOX_HTTPS_PORT` | `8443` | host HTTPS port |
| `SANDBOX_RUNTIME` | `podman` | `podman` or `docker` |
| `PODMAN_MACHINE_CPUS` | `4` | CPUs the podman VM gets at init |
| `PODMAN_MACHINE_MEMORY_MIB` | `6144` | RAM in MiB |
| `KIND_NODE_IMAGE` | `kindest/node:v1.35.0` | kind node image |
| `ARGOCD_CHART_VERSION` | `9.5.13` | argo-cd Helm chart version |
| `KARGO_CHART_VERSION` | `1.1.1` | kargo Helm chart version |
| `CERT_MANAGER_CHART_VERSION` | `v1.16.2` | cert-manager chart version |
| `ISTIO_CHART_VERSION` | `1.29.2` | Istio chart version |

### Adding your own apps

The Istio gateway accepts any host under `*.${SANDBOX_DOMAIN}`. To add a new
app:

1. Deploy your Service in any namespace.
2. Create a `VirtualService` that selects `istio-ingress/sandbox-gateway`
   and routes by host:

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata: { name: myapp, namespace: my-ns }
   spec:
     hosts: ["myapp.sandbox.app"]
     gateways: ["istio-ingress/sandbox-gateway"]
     http:
       - route:
           - destination: { host: myapp.my-ns.svc.cluster.local, port: { number: 80 } }
   ```

3. Add `myapp.sandbox.app` to `/etc/hosts` (or re-run `up` and add the host
   to the same line). The wildcard cert covers it automatically — no
   per-app TLS config.

## Troubleshooting

```sh
sandboxctl status      # is everything running?
sandboxctl validate    # do the URLs actually answer?
tail -f ~/.sandboxctl/portfwd.log   # port-forward output
```

Common issues:

- **Browser shows a cert warning.** The keychain trust didn't take.
  `sandboxctl trust-ca` re-applies it.
- **`ERR_CONNECTION_REFUSED`.** The LaunchAgent isn't bound to `:8443`.
  `sandboxctl status` will say so. `sandboxctl restart` reinstalls it.
- **podman issues.** `sandboxctl setup-podman` reconfigures the VM.

## Uninstall

```sh
sandboxctl purge       # removes cluster + everything sandboxctl wrote
rm $(which sandboxctl)
```

The `kindest/node` image cache and the podman machine itself are left
alone — you may want them for other projects.

## License

MIT — see [LICENSE](LICENSE).
