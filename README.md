# sandboxctl

A one-command local Kubernetes sandbox for macOS — kind + Argo CD + Kargo +
Istio + an in-cluster Docker registry + an in-cluster Gitea, all wired up
behind a single wildcard cert and a stable `*.sandbox.app:8443` URL.

`sandboxctl up` brings the platform up. `sandboxctl deploy` deploys *your*
app into it via a real GitOps loop — chart pushed to in-cluster Gitea, Argo
CD syncs, Istio routes the URL.

## Install

```sh
brew install tesserix/tap/sandboxctl
```

That's the only step. The formula installs the binary plus the bundled
`sandbox.sh` and Helm manifests it drives.

## Quickstart

From your product repo root (the dir that holds your Dockerfile, chart,
and `k8s/secrets.yaml`):

```sh
cd path/to/your-app
sandboxctl bootstrap               # brings the platform up + deploys your app
```

`bootstrap` is the one-shot wrapper. It runs `sandboxctl up` (skipped if
the cluster is already up) then `sandboxctl deploy` in the current dir,
so re-running it later is also fine as your "redeploy this app"
shortcut.

If you'd rather run the steps separately:

```sh
sandboxctl up                      # one-time: bring the platform up (~5–8 min first run)
cd path/to/your-app
sandboxctl deploy                  # build + push images, deploy via Argo CD
```

Open `https://<your-chart-name>.sandbox.app:8443` in your browser.

## What's running after `sandboxctl up`

| URL | What |
|---|---|
| `https://argo.sandbox.app:8443` | Argo CD UI |
| `https://kargo.sandbox.app:8443` | Kargo UI |
| `https://kagent.sandbox.app:8443` | [kagent](https://github.com/kagent-dev/kagent) — agentic AI controller |
| `https://agentregistry.sandbox.app:8443` | [agentregistry](https://aregistry.ai) — registry for MCP servers, agents, skills, prompts (+ bundled PostgreSQL) |
| `https://demo-app.sandbox.app:8443` | a tiny demo deployment |
| `localhost:5050` | in-cluster Docker registry (push target for `sandboxctl build`) |

[**agentregistry**](https://aregistry.ai) is deployed into the cluster (with a
bundled PostgreSQL — the chart's dev/eval profile) so you have a registry for
MCP servers, agents, skills, and prompts out of the box. Skip it with
`sandboxctl up --no-agentregistry` (or `INSTALL_AGENTREGISTRY=0`). It's a
non-fatal step — if its images are slow to pull, the rest of the sandbox still
comes up. Embeddings (`arctl embeddings`) need a pgvector PostgreSQL and are
not available in the bundled profile. `down`/`purge` remove it with the cluster.

`sandboxctl up` also installs the matching [`arctl`](https://aregistry.ai) CLI
onto your Mac — for building, publishing, and running those artifacts and for
talking to the in-cluster registry. Skip it with `sandboxctl up --no-arctl`
(or `INSTALL_ARCTL=0`); pin a version with `ARCTL_VERSION=v0.3.3`.
`sandboxctl down` / `purge` remove it again (keep it with `SANDBOX_KEEP_ARCTL=1`).

All TLS is signed by a per-install root CA that `sandboxctl up` trusts in
your macOS System keychain — no browser warnings, no manual port-forwards.

`sandboxctl creds` prints admin passwords on demand. Each install
generates its own — nothing is hard-coded.

## Deploying your own app

Run `sandboxctl deploy` from your product directory — the same dir you'd
run `docker build` from. The CLI will:

1. **Build + push images.** Reads `sandboxctl.yaml` at the dir root if it
   exists (multi-image, dependency-ordered); otherwise walks Dockerfiles
   and pushes one image per Dockerfile to `localhost:5050/<dir-name>:latest`.
2. **Apply secrets.** Reads `k8s/secrets.yaml` and applies it to the
   target namespace. On first run, copies it from `k8s/secrets.example.yaml`
   and prompts you to fill the values.
3. **Push the chart.** The chart subtree is pushed to an in-cluster Gitea
   repo at `apps/<chart-name>-chart.git`.
4. **Create the Argo Application.** Argo syncs from that Gitea URL,
   waits for `Synced + Healthy`.
5. **Wire the URL.** Adds an Istio VirtualService and an `/etc/hosts`
   entry routing `<chart-name>.sandbox.app:8443` to the chart's primary
   Service.
6. **Print a status table** — namespace, sync, health, pod-ready ratio,
   URL — so you can see what landed.

### Where it looks for the chart

```
1. ./k8s/chart/Chart.yaml              ← recommended layout
2. Any Chart.yaml within depth 5 of cwd (Helm only — rendered-manifest
                                         dirs like deploy/ or k8s/ are
                                         intentionally not auto-picked)
3. Interactive prompt for a path       ← when nothing is found
```

If steps 1 and 2 turn up nothing, sandboxctl prompts for a chart path
(absolute, or relative to the product dir) and continues with whatever
you enter. Press Enter on an empty line to abort.

Override with `--chart <dir>` if your chart lives outside the product
dir and you want to skip the prompt:

```sh
sandboxctl deploy --chart ../platform/manifests/my-app/chart
sandboxctl deploy --chart /abs/path/to/chart
```

### Useful `deploy` flags

| Flag | What |
|---|---|
| `--chart <dir>` | Skip auto-discovery and use this chart |
| `--values <file>` | Pick a specific values file in the chart (default: `values-sandbox.yaml`, then `values-local.yaml`) |
| `--name <name>` | Override the Argo App + URL name (default: `Chart.yaml`'s `name`) |
| `--env <name>` | Namespace suffix only — URL stays `<name>.sandbox.app`. Default `dev`. |
| `--no-build` | Skip the build step (registry already has the images) |

`sandboxctl undeploy --name <chart>` reverses everything — removes the
Argo Application, the VirtualService, and the `/etc/hosts` entry. The
namespace is preserved unless you delete it manually.

### Recommended product-dir layout

```
your-app/
├── Dockerfile                  # or sandboxctl.yaml for multi-image builds
├── sandboxctl.yaml             # optional — see Multi-image builds
├── k8s/
│   ├── chart/                  # your Helm chart (auto-detected)
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   ├── values-sandbox.yaml # picked automatically by sandboxctl
│   │   └── templates/
│   ├── secrets.yaml            # gitignored — applied to namespace
│   └── secrets.example.yaml    # template — committed
└── ...
```

With this layout, `sandboxctl deploy` from the repo root needs no flags.

## Multi-image builds

If your repo has multiple Dockerfiles with build-order dependencies, drop
a `sandboxctl.yaml` at the root:

```yaml
images:
  - name: base
    context: docker/base
    aliases: [my-base:latest]      # extra tags so downstream FROMs resolve

  - name: api
    context: docker/api
    depends_on: [base]

  - name: worker
    context: docker/worker
    depends_on: [base]

  - name: app
    context: .                      # repo-root Dockerfile
```

Each entry gets pushed to `localhost:5050/<name>:latest`. Use them in your
chart values:

```yaml
image:
  repository: localhost:5050/app
  tag: latest
  pullPolicy: Always       # so Argo rollouts pick up new pushes
```

`sandboxctl build` runs the same pipeline standalone if you want to push
images without deploying.

## Image management

```sh
sandboxctl build                          # build + push all Dockerfiles in cwd
sandboxctl images                         # list everything in the registry
sandboxctl images rm myapp:v1             # delete one tag
sandboxctl images rm myapp                # delete every tag of an image
sandboxctl images prune                   # delete every image, then GC blobs
sandboxctl images gc                      # garbage-collect blobs only
```

## Cluster lifecycle

```sh
sandboxctl up                             # bring everything up
sandboxctl status                         # cluster + workload status + URLs
sandboxctl validate                       # curl each URL and report HTTP codes
sandboxctl creds                          # admin passwords for Argo CD + Kargo
sandboxctl restart                        # down + up
sandboxctl down                           # remove cluster + LaunchAgent + /etc/hosts + CA
sandboxctl purge                          # down + remove ~/.sandboxctl (prompts)
sandboxctl tui                            # live status dashboard
```

The first `up` prompts for `sudo` once — it edits `/etc/hosts` and trusts
the local root CA in the System keychain. Subsequent runs are silent.

## Requirements

- macOS (Apple Silicon or Intel)
- Homebrew with `kind`, `kubectl`, `helm`, `go`, and one of `podman`
  (recommended) or `docker`
- ≈6 GiB free RAM for the kind node + cluster workloads

`sandboxctl setup-podman` installs and configures podman for you (rootful,
6 GiB memory) if it isn't ready yet.

### Optional: Ollama for kagent

`kagent` defaults to Ollama as its LLM provider. The UI works without it,
but to actually invoke an LLM you need Ollama reachable from the cluster:

```sh
brew install ollama
ollama serve &
ollama pull llama3.2
```

The kagent pod reaches your Mac's Ollama via `host.docker.internal:11434`.
Override `KAGENT_OLLAMA_HOST` / `KAGENT_OLLAMA_MODEL` for a different
endpoint or model.

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
       ▼ Mac:8443 → istio-ingress:8443
   ┌──────────────── kind cluster ────────────────┐
   │  Istio gateway (wildcard TLS via cert-manager)│
   │       │                                       │
   │       ├── argocd-server  (argocd ns)          │
   │       ├── kargo-api       (kargo ns)          │
   │       ├── kagent-ui       (kagent ns)         │
   │       ├── demo-app        (demo-app ns)       │
   │       ├── gitea           (gitea ns)          │
   │       ├── registry:30050  (sandboxctl-registry ns)
   │       └── your apps       (one ns each)       │
   │                                                │
   │  ▲ Argo CD reads charts from in-cluster Gitea │
   │  ▲ Pods pull images from the in-cluster registry
   └───────────────────────────────────────────────┘
```

The pieces:

- **kind** — single-node Kubernetes in a container, run via podman or docker
- **cert-manager** — bootstrap CA → wildcard cert for `*.sandbox.app`
- **Istio ambient** — `istio-base` + `istiod` + `istio-cni` + `ztunnel` +
  `istio/gateway`. The gateway terminates TLS with the wildcard cert.
- **Argo CD, Kargo, kagent, demo-app** — Helm-installed control plane
- **reflector** — mirrors annotated Secrets/ConfigMaps across namespaces
  (inert until a workload chart annotates something)
- **In-cluster Gitea** — backs the GitOps loop for `sandboxctl deploy`
- **In-cluster registry** — `localhost:5050` push target, mirrored into
  the kind node's containerd via `hosts.toml`
- **macOS LaunchAgent** — `kubectl port-forward` so the gateway is
  reachable on `127.0.0.1:8443` across reboots
- **dnsmasq + `/etc/resolver/sandbox.app`** — wildcard `*.sandbox.app →
  127.0.0.1` so any product chart can add a VirtualService on a new
  subdomain (e.g. `mcp.fiber.sandbox.app`) without touching `/etc/hosts`

## Configuration

Defaults work for most people. Override via env vars:

| Variable | Default | What |
|---|---|---|
| `SANDBOX_DOMAIN` | `sandbox.app` | DNS suffix for app hostnames |
| `SANDBOX_CLUSTER_NAME` | `sandboxctl` | kind cluster name |
| `SANDBOX_HTTP_PORT` | `8080` | host HTTP port |
| `SANDBOX_HTTPS_PORT` | `8443` | host HTTPS port |
| `SANDBOX_REGISTRY_PORT` | `5050` | host port for the in-cluster registry |
| `SANDBOX_RUNTIME` | `podman` | `podman` or `docker` |
| `PODMAN_MACHINE_CPUS` | `4` | CPUs the podman VM gets at init |
| `PODMAN_MACHINE_MEMORY_MIB` | `6144` | RAM in MiB |
| `KIND_NODE_IMAGE` | `kindest/node:v1.35.0` | kind node image |
| `ARGOCD_CHART_VERSION` | `9.5.13` | argo-cd chart version |
| `KARGO_CHART_VERSION` | `1.1.1` | kargo chart version |
| `REFLECTOR_CHART_VERSION` | `9.1.7` | emberstack/reflector chart version |
| `CERT_MANAGER_CHART_VERSION` | `v1.16.2` | cert-manager chart version |
| `ISTIO_CHART_VERSION` | `1.29.2` | Istio chart version |
| `KAGENT_CHART_VERSION` | `0.9.4` | kagent chart version |
| `GITEA_CHART_VERSION` | `12.5.0` | Gitea chart version |
| `KAGENT_OLLAMA_HOST` | `host.docker.internal:11434` | Ollama endpoint |
| `KAGENT_OLLAMA_MODEL` | `llama3.2` | Ollama model |
| `ARCTL_VERSION` | `latest` | `arctl` release to install (`latest` or a tag like `v0.3.3`) |
| `INSTALL_ARCTL` | `1` | install `arctl` during `up`; set `0` to skip |
| `SANDBOX_KEEP_ARCTL` | `0` | keep `arctl` on `down`/`purge` when set to `1` |
| `ARCTL_INSTALL_DIR` | `/usr/local/bin` | where the `arctl` binary is installed |
| `INSTALL_AGENTREGISTRY` | `1` | install the agentregistry server in-cluster during `up`; set `0` to skip |
| `AGENTREGISTRY_CHART_VERSION` | `0.3.3` | agentregistry Helm chart version |
| `AGENTREGISTRY_IMAGE_TAG` | `v0.3.3` | agentregistry server image tag |
| `AGENTREGISTRY_STORAGE` | `2Gi` | bundled PostgreSQL PVC size |

## Secrets

Every install gets its own random secrets — there are **no shared
passwords baked into this repo**. On first `up` sandboxctl generates a
random Kargo admin password, JWT signing key, and Gitea admin password,
saved to `~/.sandboxctl/` (`chmod 600`) and reused on subsequent runs.
`sandboxctl creds` prints them.

The local CA private key is generated by cert-manager inside the cluster
and never leaves it.

## Troubleshooting

```sh
sandboxctl status                         # is everything running?
sandboxctl validate                       # do the URLs answer?
tail -f ~/.sandboxctl/portfwd.log         # port-forward output
```

Common issues:

- **Browser cert warning.** Keychain trust didn't take. `sandboxctl trust-ca`
  re-applies it.
- **`ERR_NAME_NOT_RESOLVED`.** `/etc/hosts` entry missing. `sandboxctl deploy`
  adds them automatically (you'll be prompted for sudo once).
- **`ERR_CONNECTION_REFUSED`.** LaunchAgent isn't bound to `:8443`.
  `sandboxctl status` will say so. `sandboxctl restart` reinstalls it.
- **`ImagePullBackOff` after deploy.** Run `sandboxctl images` — if the
  tag isn't there, run `sandboxctl build` from the product dir.

## Uninstall

```sh
sandboxctl purge                          # cluster + everything sandboxctl wrote
brew uninstall sandboxctl
```

The `kindest/node` image cache and the podman machine itself are left
alone — you may want them for other projects.

## License

MIT — see [LICENSE](LICENSE).
