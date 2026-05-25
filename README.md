<h1 align="center">sandboxctl</h1>

<p align="center">
  <a href="https://github.com/tesserix/sandboxctl/actions/workflows/ci.yml"><img src="https://github.com/tesserix/sandboxctl/actions/workflows/ci.yml/badge.svg?branch=main" alt="ci"></a>
  <a href="https://github.com/tesserix/sandboxctl/actions/workflows/release.yml"><img src="https://github.com/tesserix/sandboxctl/actions/workflows/release.yml/badge.svg" alt="release"></a>
  <a href="https://github.com/tesserix/sandboxctl/releases/latest"><img src="https://img.shields.io/github/v/release/tesserix/sandboxctl?label=latest&sort=semver&logo=github&color=blue" alt="latest release"></a>
</p>

A one-command local Kubernetes sandbox for macOS — kind + Argo CD + Kargo +
Istio + an in-cluster Docker registry + an in-cluster Gitea, all wired up
behind a single wildcard cert and a stable `*.sandbox.app:8443` URL.

`sandboxctl up` brings the platform up. `sandboxctl deploy` deploys *your*
app into it via a real GitOps loop — chart pushed to in-cluster Gitea, Argo
CD syncs, Istio routes the URL.

## Demo

https://github.com/user-attachments/assets/2de50f00-a427-4de0-a114-5b2f7eb05223


A full `sandboxctl up` run, end to end. If the player above doesn’t load,
[▶ open the demo video](https://github.com/tesserix/sandboxctl/releases/download/v2.3.0/sandboxctl-video.mp4)
(MP4, ~500 MB — hosted on the [v2.3.0 release](https://github.com/tesserix/sandboxctl/releases/tag/v2.3.0)).

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

A plain `sandboxctl up` (no flags) is intentionally small — it only stands
up the pieces you'd reach for on day one. Everything else is opt-in
behind a `--with-*` flag. Pass `--install all` for the kitchen-sink demo.

### Default-on (always installed)

| Component | URL / port | What it gives you |
|---|---|---|
| **Argo CD** | `https://argo.sandbox.app:8443` | GitOps controller (the cluster's source of truth) |
| **Kargo** | `https://kargo.sandbox.app:8443` | Promotion pipelines on top of Argo |
| **Demo app** | `https://demo-app.sandbox.app:8443` | A tiny deployment so the cluster ships with something live |
| **Gitea** | `https://gitea.sandbox.app:8443` | In-cluster git server backing `sandboxctl deploy` |
| **In-cluster registry** | `localhost:5050` (NodePort `30050`) | Push target for `sandboxctl build` / `docker push` |
| **dnsmasq + DNS** | `/etc/resolver/sandbox.app` → `127.0.0.1` | Wildcard `*.sandbox.app` resolution on the host |
| Plumbing | — | cert-manager + per-install root CA (trusted in System keychain), reflector, reloader, Istio ambient + ingress, kubectl port-forward LaunchAgent |

All TLS is signed by a per-install root CA — no browser warnings, no
manual port-forwards. `sandboxctl creds` prints admin passwords on
demand; each install generates its own and nothing is hard-coded.

### Opt-in add-ons

Pass the flag to `sandboxctl up` (or `bootstrap`); flags are forwarded
through, and `up` is idempotent so re-running with a new flag adds the
piece without disturbing the rest.

| Component | Flag | URL / port | What it gives you |
|---|---|---|---|
| **arctl** (CLI on the Mac) | `--with-arctl` | binary in `/usr/local/bin/arctl` | [agentregistry](https://aregistry.ai) CLI — build/publish/run MCP servers, agents, skills, prompts. Pin with `ARCTL_VERSION`. `SANDBOX_KEEP_ARCTL=1` keeps it on `down`/`purge`. |
| **CloudNativePG operator** | `--with-cnpg` | (operator only) | Postgres-as-a-CRD; foundation for shared Postgres clusters. Implied by `--with-agentregistry`. |
| **agentregistry server** | `--with-agentregistry` | `https://aregistry.sandbox.app:8443` | In-cluster registry for MCP/agents/skills, backed by a CNPG Postgres with `pgvector` (semantic search). Implies `--with-cnpg`. |
| **NATS + JetStream** | `--with-nats` | `nats://nats.sandbox.app:4222` (also `wss://nats.sandbox.app:8443`) | Pub/sub + persistent streams. Adds a LaunchAgent that port-forwards `:4222` to the host. Pair with `--no-nats-cli` to skip the host-side `nats` CLI install. |
| **kagent** | `--with-kagent` | `https://kagent.sandbox.app:8443` | [kagent](https://github.com/kagent-dev/kagent) — agentic AI controller + UI (controller-only install; configure model providers out-of-band). |
| **agentgateway** | `--with-agentgateway` | `https://agentgateway.sandbox.app:8443` | [agentgateway](https://agentgateway.dev) — Linux-Foundation-hosted, [Gateway-API-native](https://gateway-api.sigs.k8s.io/) proxy for AI traffic (MCP / A2A / agent-to-LLM). Drop in `HTTPRoute`s from any namespace. |
| **Portkey** | `--with-portkey` | `https://portkey.sandbox.app:8443` (console `/public/`) | OSS AI gateway: routing, retries, fallbacks, load-balancing for 250+ LLMs. |
| **LiteLLM** | `--with-litellm` | `https://litellm.sandbox.app:8443` (UI `/ui`) | OpenAI-compatible proxy for 100+ providers. Reuses the shared CNPG cluster when `--with-agentregistry` (or `--with-cnpg`) is also on; otherwise falls back to the chart's bundled standalone Postgres. |
| **MLflow** | `--with-mlflow` | `https://mlflow.sandbox.app:8443` | Experiment tracking + model registry UI. |
| **Tyk OSS** | `--with-tyk` | `https://tyk.sandbox.app:8443` (`/hello`) | Open-source API gateway — rate-limit/auth/quotas in front of any upstream. (Bundled Redis is sandbox-grade: single replica, no PVC.) |
| **All AI gateways at once** | `--with-ai-gateway` | — | Umbrella: enables agentgateway + Portkey + LiteLLM + MLflow + Tyk. |
| **Kitchen sink** | `--install all` | — | Every opt-in above (full demo install). |

```sh
sandboxctl up                                    # core only
sandboxctl up --with-agentgateway                # add agentgateway
sandboxctl up --with-agentregistry --with-arctl  # agentregistry + CLI (pulls in CNPG)
sandboxctl up --with-litellm                     # LiteLLM with the chart's standalone Postgres
sandboxctl up --with-cnpg --with-litellm         # LiteLLM on a shared CNPG cluster (no agentregistry)
sandboxctl up --with-ai-gateway                  # all five AI gateways
sandboxctl up --install all                      # everything
sandboxctl creds                                 # URLs, admin creds, master keys, copy-paste curl examples
```

agentgateway is configured with `allowedRoutes.namespaces.from=All`, so
any chart in any namespace can attach an `HTTPRoute` whose `parentRefs`
points at `agentgateway-system/agentgateway-proxy` — that's the
integration hook for wiring your local-dev workloads in later.
`sandboxctl creds` prints a copy-paste `HTTPRoute` template under the
agentgateway block.

Each opt-in tool's master key / API secret is generated per-install and
persisted under `~/.sandboxctl/` (printed by `sandboxctl creds`). The
graphical **Tyk Dashboard** is a licensed component and is *not* part of
Tyk OSS — the gateway here is driven by its control API + API-definition
files.

`sandboxctl restart` re-asserts whatever you previously opted into (it
detects components by namespace presence), so it never silently
uninstalls something. Removing an add-on means `sandboxctl down` (which
wipes the cluster) — there is no per-component uninstaller today.

The deprecated `--no-arctl` / `--no-cnpg` / `--no-agentregistry` /
`--no-nats` / `--no-agentgateway` / `--no-portkey` / `--no-litellm` /
`--no-mlflow` / `--no-tyk` / `--no-ai-gateway` flags are still parsed as
no-ops so older scripts keep working — they exist only because these
components were once default-on. Drop them when you next touch the
script.

## Deploying your own app

Run `sandboxctl deploy` from your product directory — the same dir you'd
run `docker build` from. To target a different directory without `cd`-ing
in, pass it positionally (`sandboxctl deploy path/to/repo`) or via
`--repo path/to/repo`. The same selectors work for `build` and
`bootstrap`. The CLI will:

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
| `--repo <dir>` | Run against a product repo other than `cwd` (positional `[path]` works too). Same flag is accepted by `build` and `bootstrap`. |
| `--chart <dir>` | Skip auto-discovery and use this chart |
| `--values <file>` | Pick a specific values file in the chart (default: `values-sandbox.yaml`, then `values-local.yaml`) |
| `--name <name>` | Override the Argo App + URL name (default: `Chart.yaml`'s `name`) |
| `--env <name>` | Namespace suffix only — URL stays `<name>.sandbox.app`. Default `dev`. |
| `--no-build` | Skip the build step (registry already has the images) |
| `--purge-old-tags` | Forwarded to the build step (see [Image management](#image-management)). `--no-purge-old-tags` overrides `SANDBOX_BUILD_PURGE_OLD_TAGS=1` from the env. |

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
sandboxctl build --purge-old-tags         # wipe prior tags of each repo before pushing,
                                          #   then GC; only the just-pushed tag remains
                                          #   (env equivalent: SANDBOX_BUILD_PURGE_OLD_TAGS=1)
sandboxctl images                         # list everything in the registry
sandboxctl images rm myapp:v1             # delete one tag
sandboxctl images rm myapp                # delete every tag of an image
sandboxctl images prune                   # delete every image, then GC blobs (alias: purge)
sandboxctl images purge                   # same as prune — for users coming from podman/docker
sandboxctl images gc                      # garbage-collect blobs only
```

`--purge-old-tags` is also accepted by `sandboxctl deploy` and
`sandboxctl bootstrap`, where it forwards to the build step.

## Cluster lifecycle

```sh
sandboxctl up                             # bring everything up (1 worker, ~5 GB RAM)
sandboxctl up --workers 2                 # 2 workers, more headroom for concurrent pods
sandboxctl up --workers 3                 # 3 workers, recommended for 32 GB+ Macs
sandboxctl status                         # cluster + workload status + URLs
sandboxctl validate                       # curl each URL and report HTTP codes
sandboxctl creds                          # admin passwords for Argo CD + Kargo
sandboxctl argocd-ui                      # print just the Argo CD URL + admin creds
sandboxctl kargo-ui                       # print just the Kargo URL + admin creds
sandboxctl restart                        # re-apply installers, keep cluster + state
sandboxctl restart --rebuild              # full wipe-and-rebuild (alias: --full)
sandboxctl restart --workers 3            # resize the cluster (implies --rebuild)
sandboxctl down                           # remove cluster + LaunchAgent + /etc/hosts + CA
sandboxctl purge                          # down + remove ~/.sandboxctl (prompts)
sandboxctl trust-ca                       # re-trust the per-install root CA in the System keychain
sandboxctl untrust-ca                     # remove the root CA from the System keychain
sandboxctl tui                            # live status dashboard (Bubble Tea)
```

### Sizing the cluster

`--workers N` picks how many kind worker nodes you get alongside the
control-plane. Range is `1`–`3`; anything else fails fast with a clean
message before any cluster work starts.

| Workers | Best for | Approx. RAM | Concurrent sandbox pods (rough) |
|---|---|---|---|
| `1` (default) | Single-task experiments, low memory | ~5 GB | 3–4 |
| `2` | Day-to-day on a 16 GB Mac | ~8 GB | 6–8 |
| `3` | 32 GB+ Mac running heavy workloads | ~12 GB | 10–12 |

Why the cap at 3: each kind worker is its own Docker container with its
own image cache and kubelet. Beyond 3 the Mac itself starts swapping —
the cluster is happy, the host isn't, and the dev loop gets slower not
faster. If you really need more, file an issue with your use case.

You can also set the count via env var:

```sh
SANDBOX_WORKER_COUNT=2 sandboxctl up
SANDBOX_WORKER_COUNT=3 sandboxctl bootstrap path/to/repo
```

The flag wins over the env var when both are set. `bootstrap` accepts
`--workers` and forwards it to `up`. `restart --workers N` rebuilds the
cluster with the new count (kind doesn't support adding nodes to an
existing cluster — recreating the kind cluster is the only path).

**Resizing an existing cluster:** `--workers N` is read only at cluster
*creation* time. Running `sandboxctl up --workers 2` against a cluster
that already exists is a no-op for the worker count: `up` is idempotent
and skips `kind create cluster` entirely, so the existing 1-worker
topology stays. To resize:

```sh
sandboxctl restart --workers 2 --rebuild   # destroys + recreates the cluster with the new count
# or
sandboxctl down && sandboxctl up --workers 2
```

`kc get nodes` is the way to confirm the live count (one
`*-control-plane` line plus N `*-worker*` lines).

**Lean by default.** Every component sandboxctl installs is tuned for a
laptop: Argo CD ships without its `dex`/`applicationset`/`notifications`
subcomponents (3 fewer pods), everything runs a single replica with small
CPU/memory requests (no CPU limits — only memory limits, so nothing
balloons or gets CPU-throttled), and the shared Postgres has capped memory.
The default `up` (agentgateway + platform) fits comfortably in the default
**4 CPU / 6 GB** VM — agentgateway adds a control-plane pod and one
data-plane proxy pod (~150 MB total). Turning on the heavier opt-ins —
especially `--with-litellm` (~700 MB image, ~1-2 GB RAM) or
`--with-ai-gateway` (all of them) — is when it's worth bumping the podman
VM:

```sh
podman machine stop
podman machine set --cpus 6 --memory 10240   # 10 GB; host should have >= 16 GB
podman machine start
```

## Reclaiming disk

Builds and pushes can fail with `no space left on device` even when the Mac
has hundreds of GiB free, because containers use a separate VM disk and the
in-cluster registry uses a PVC inside that VM. `sandboxctl prune` walks the
four surfaces, explains each one, and prompts before doing anything:

```sh
sandboxctl prune                          # interactive — diagnoses all four
sandboxctl prune runtime                  # only podman/docker VM (positional shorthand)
sandboxctl prune --only registry          # explicit form: host | dmgs | runtime | registry
sandboxctl prune --yes                    # accept every prompt (scripted use; alias: -y)
sandboxctl cleanup                        # alias for `prune` — same flags
```

Stages, in order:

1. **macOS host disk** — read-only diagnosis; never auto-cleaned.
2. **Mounted DMGs under `/Volumes`** — offers `hdiutil detach`. DMGs always
   show as 100% full in `df`; that's expected, not a leak.
3. **Container runtime VM** (podman or docker) — runs `<runtime> system prune`
   to free dangling images, stopped containers, and build cache. A second
   prompt offers to also remove unused tagged images.
4. **In-cluster registry** — runs registry GC (safe, blob-only) and, on a
   separate prompt, a full prune of every tag.

The first `up` prompts for `sudo` once — it edits `/etc/hosts` and trusts
the local root CA in the System keychain. Subsequent runs are silent.

## Requirements

- macOS (Apple Silicon or Intel)
- Homebrew with `kind`, `kubectl`, `helm`, `go`, and one of `podman`
  (recommended) or `docker`
- ≈6 GiB free RAM for the kind node + cluster workloads

`sandboxctl setup-podman` installs and configures podman for you (rootful,
6 GiB memory, 60 GiB disk) if it isn't ready yet. To pick a different
size on first run:

```sh
sandboxctl setup-podman --disk-size 80 --memory 8192 --cpus 6
```

Existing machine too small? podman can't grow a VM's disk in place —
the only way to bump `--disk-size` is to recreate the machine, which
wipes its images, containers, and any kind cluster living inside:

```sh
sandboxctl down                            # tear the cluster down first
sandboxctl setup-podman --disk-size 80 --recreate
sandboxctl up                              # rebuild the cluster
```

### kagent model providers

`sandboxctl --with-kagent` installs only the kagent controller + UI — no
model provider is configured. Wire a provider/model yourself afterwards
(via the kagent UI or a `ModelConfig` CRD); sandboxctl will not pull
models or stand up Ollama for you.

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
   │       ├── nats + JetStream (nats ns)          │
   │       ├── agentgateway     (agentgateway-system) │ AI Agentic Gateway (default)
   │       ├── portkey-gateway (portkey ns)        │ ┐
   │       ├── litellm         (litellm ns)        │ │ opt-in legacy alternatives:
   │       ├── mlflow          (mlflow ns)         │ │ --with-portkey / --with-litellm
   │       ├── tyk + redis     (tyk ns)            │ ┘ / --with-mlflow / --with-tyk
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
- **NATS + JetStream** — single-replica messaging server with persistent
  file store (2 GiB PVC). Reachable from the Mac at `nats://nats.sandbox.app:4222`
  (TCP+TLS, served via an Istio TLS-passthrough listener and a second
  LaunchAgent port-forward) and `wss://nats.sandbox.app:8443` for browser/JS
  clients. Cert is signed by the same per-install CA as everything else.
- **AI Agentic Gateway** — agentgateway default-on (Gateway-API-native, MCP/A2A/LLM);
  Portkey, LiteLLM, MLflow, Tyk opt-in, each in its own namespace with an
  Istio route + trusted HTTPS URL (see the section above). agentgateway brings
  in the upstream Kubernetes Gateway API CRDs; LiteLLM reuses the shared
  CloudNativePG cluster (a `litellm` db on agentregistry's Postgres — no
  second pod; bundled-standalone fallback); Tyk ships a bundled
  single-replica Redis.
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
| `PODMAN_MACHINE_DISK_GIB` | `60` | virtual-disk size for the podman VM at init. podman has no in-place disk grow — use `setup-podman --disk-size N --recreate` to bump an existing machine. Same as `setup-podman --disk-size N`. |
| `KIND_NODE_IMAGE` | `kindest/node:v1.35.0` | kind node image |
| `SANDBOX_WORKER_COUNT` | `1` | kind worker nodes (1–3). Same as `--workers N`. |
| `SANDBOX_BUILD_PURGE_OLD_TAGS` | `0` | wipe prior tags of each repo before pushing during `build`/`deploy`/`bootstrap`, then registry-GC at the end. Same as `--purge-old-tags`. |
| `ARGO_HEALTH_ATTEMPTS` | `3` | number of 180s windows `deploy` waits for an Argo Application to become Synced+Healthy (default covers up to 9 min for slow CRD-heavy syncs). |
| `ARGOCD_CHART_VERSION` | `9.5.13` | argo-cd chart version |
| `KARGO_CHART_VERSION` | `1.1.1` | kargo chart version |
| `REFLECTOR_CHART_VERSION` | `9.1.7` | emberstack/reflector chart version |
| `CERT_MANAGER_CHART_VERSION` | `v1.16.2` | cert-manager chart version |
| `ISTIO_CHART_VERSION` | `1.29.2` | Istio chart version |
| `KAGENT_CHART_VERSION` | `0.9.4` | kagent chart version |
| `GITEA_CHART_VERSION` | `12.5.0` | Gitea chart version |
| `ARCTL_VERSION` | `latest` | `arctl` release to install (`latest` or a tag like `v0.3.3`) |
| `INSTALL_ARCTL` | `0` | install `arctl` during `up` (opt-in; `--with-arctl` or `INSTALL_ARCTL=1`) |
| `SANDBOX_KEEP_ARCTL` | `0` | keep `arctl` on `down`/`purge` when set to `1` |
| `ARCTL_INSTALL_DIR` | `/usr/local/bin` | where the `arctl` binary is installed |
| `INSTALL_CNPG` | `0` | CloudNativePG operator (opt-in; `--with-cnpg`; implied by `--with-agentregistry`) |
| `INSTALL_AGENTREGISTRY` | `0` | agentregistry server + CNPG cluster (opt-in; `--with-agentregistry`) |
| `INSTALL_NATS` | `0` | NATS + JetStream (opt-in; `--with-nats`) |
| `INSTALL_KAGENT` | `0` | kagent controller + UI (opt-in; `--with-kagent`) |
| `INSTALL_AGENTGATEWAY` | `0` | agentgateway proxy (opt-in; `--with-agentgateway`) |
| `INSTALL_PORTKEY` | `0` | Portkey gateway (opt-in; `--with-portkey`) |
| `INSTALL_LITELLM` | `0` | LiteLLM proxy (opt-in; `--with-litellm`) |
| `INSTALL_MLFLOW` | `0` | MLflow (opt-in; `--with-mlflow`) |
| `INSTALL_TYK` | `0` | Tyk OSS gateway (opt-in; `--with-tyk`) |
| `AGENTGATEWAY_CHART_VERSION` | `v1.2.0` | pin the agentgateway OCI chart version |
| `GATEWAY_API_VERSION` | `v1.5.0` | pin the upstream Kubernetes Gateway API CRDs version agentgateway installs |
| `LITELLM_CHART_VERSION` | `latest` | pin the `litellm-helm` OCI chart version |
| `LITELLM_DB_MODE` | `auto` | LiteLLM Postgres: `auto`/`shared` (reuse the shared CNPG cluster) or `standalone` (chart's own) |
| `LITELLM_IMAGE_TAG` | `main-latest` | LiteLLM image tag (the chart's version-derived default is often unpublished) |
| `MLFLOW_CHART_VERSION` | `latest` | pin the `community-charts/mlflow` chart version |
| `TYK_CHART_VERSION` | `latest` | pin the `tyk-helm/tyk-oss` chart version |
| `PORTKEY_IMAGE` | `portkeyai/gateway:latest` | Portkey gateway container image |

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
