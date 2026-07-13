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

A plain `sandboxctl up` ends with an onboarding check of the directory
you ran it from: if the repo isn't onboarded to the sandbox structure
yet, it shows exactly what `sandboxctl scaffold` would generate
(dry-run) and offers to run it on the spot — answer `y` and the repo is
ready for `deploy`. Already-onboarded repos just get the next-step
commands. Re-run the check any time with `sandboxctl _onboard-check`.

If you'd rather run the steps separately:

```sh
sandboxctl up                      # one-time: bring the platform up (~5–8 min first run)
cd path/to/your-app
sandboxctl deploy                  # build + push images, deploy via Argo CD
```

Open `https://<your-chart-name>.sandbox.app:8443` in your browser.

No Helm chart yet? `sandboxctl scaffold` generates one (plus the
secrets template) from what it detects in your repo — see
[Scaffolding charts](#scaffolding-charts-from-your-repo).

### Command overview

| Command | What it does |
|---|---|
| `sandboxctl up` | create the kind cluster + install the platform (Argo CD, Kargo, Gitea, Istio, registry, PKI, …) |
| `sandboxctl scaffold` | analyze the repo (monorepo-aware) and generate Helm chart(s), sandbox values, and the secrets template — skips what exists, asks before overwriting your edits |
| `sandboxctl build` | build + push the repo's images to the in-cluster registry |
| `sandboxctl deploy` | apply secrets, push chart(s) to Gitea, create Argo CD Applications, wire `https://<app>.sandbox.app` URLs (`--umbrella`: whole monorepo stack as one app) |
| `sandboxctl install` | helm-install the chart stack directly — umbrella-aware, hermetic dependency build, secrets + URLs handled, no Gitea/Argo in the path |
| `sandboxctl bootstrap` | `up` (if needed) + `deploy` in one shot |
| `sandboxctl status` / `tui` | cluster + workload status, URLs |
| `sandboxctl versions` | component doctor: pinned (chart→app) vs latest vs installed, with compatibility floors |
| `sandboxctl doctor` | validate everything — host tools, runtime, ports, env hazards, cluster + component health, Mac plumbing — with the exact fix per failure |
| `sandboxctl creds` | Argo CD + Kargo URLs and admin credentials |
| `sandboxctl kubeconfig` | path of the sandbox-owned kubeconfig; `--export` for `eval`, `--merge` to opt-in merge into `~/.kube/config` |
| `sandboxctl undeploy` / `down` / `purge` | remove an app / the cluster / everything |

Run any command with `--help` for its flags.

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

## Scaffolding charts from your repo

`sandboxctl scaffold [dir]` turns a repo without Kubernetes manifests
into one that deploys — it analyzes the code, generates the Helm
chart(s) with sandbox-ready values, discovers the environment variables
the apps need, and writes everything through a safe-write engine that
never destroys your work.

```
$ sandboxctl scaffold
~/code/shop — monorepo (pnpm), 3 app(s)
  NAME    RUNTIME   PATH         PORT  KIND    DOCKERFILE  ENV(SEC)  CHART
  api     go/gin    apps/api     8080  http    yes         2(2)      -
  web     ts/next   apps/web     3000  http    yes         1(0)      -
  worker  go        apps/worker  -     worker  yes         1(1)      -

Plan for ~/code/shop (23 file(s))
  create  k8s/charts/api/…            Helm chart for app api (go/gin, port 8080)
  create  k8s/secrets.example.yaml    secret template — 2 app(s) reference secret-like variables
  append  .gitignore                  keep k8s/secrets.yaml and .env out of git
Proceed? [y/N]
```

**What it detects.** Repo layout (single-app vs monorepo via pnpm/npm
workspaces, `go.work`, Cargo workspaces, docker compose, or plain
Dockerfile placement), and per app: language, framework, Dockerfile,
listen port (compose port → Dockerfile `EXPOSE` → framework default),
and env references. Every conclusion carries a reason —
`sandboxctl _analyze --json` shows the full model. Wrong guess? Pin it
in `sandboxctl.yaml`:

```yaml
apps:
  - path: apps/api
    port: 9090          # beats detection
secrets:
  include: [MY_OPAQUE_VAR]
  exclude: [NATS_URL]
```

**What it generates.** One chart per app that has a Dockerfile and no
chart yet — `k8s/chart/` for single-app repos, `k8s/charts/<name>/` for
monorepos. The values use the same `{ image: { repository, tag } }`
shape the deploy-time pin resolver understands, image coordinates point
at the in-cluster registry, chart-level Ingress ships disabled, and
each http app's chart carries its **own Istio VirtualService** —
enabled by `values-sandbox.yaml` with the right host + gateway, so
GitOps owns the URL end to end and nothing needs hand-written routing
(`deploy` detects the chart-managed route, skips its imperative one,
and still handles `/etc/hosts` + the URL probe). Workers get no
Service, and apps that reference secret-like variables are wired to
their Secret via `envFrom`. Monorepos also get an **umbrella chart** at `k8s/chart`
connecting every app chart as a `file://` dependency with per-app
`enabled` toggles. It deploys two ways: `sandboxctl deploy --umbrella`
runs the whole stack as **one Argo CD Application** (the entire `k8s/`
tree is pushed to Gitea so the `file://../charts/<app>` dependencies
resolve inside Argo's checkout, the Application points at its `chart/`
subdirectory, every app lands in one namespace, and each still gets its
own `https://<app>.…` URL via the chart-carried VirtualServices);
`sandboxctl install` runs the same stack via plain helm with no GitOps
in the path (hermetic dependency build so a stale helm repo index on
your machine can't break the `file://` deps, secrets applied before the
pods start, stuck first-installs auto-cleared, `/etc/hosts` + probe per
URL, `--dry-run` to see the plan); or standalone anywhere with `helm
dependency build --skip-refresh k8s/chart && helm install stack
k8s/chart`. The default `deploy` (no
flag) recognizes the umbrella by annotation, skips it, and keeps
deploying per-app — pipelines and URLs stay per-app. A
`values-sandbox.yaml` is emitted so `deploy` picks the chart up with
zero flags, and `k8s/secrets.example.yaml` + `.gitignore` handling is
automatic (see [Secrets](#secrets)). Tree pushes never include
`k8s/secrets.yaml` (your filled, gitignored secrets stay on your
machine) nor local `Chart.lock`/`charts/` build leftovers.

**What it will never do.** Files you authored are never touched — not
even with `--force`. Files scaffold generated earlier regenerate only
while you haven't edited them; edited ones prompt with a diff
(`[s]kip / [o]verwrite / [d]iff / [a]ll-skip / [q]uit`, Enter keeps
yours). Every chart written is `helm lint`-ed immediately; a failure
rolls that chart's files back so a broken chart never lands. Flags:
`--dry-run` (plan only), `--yes` (skip the confirm), `--force`
(overwrite your edits — still never touches files scaffold didn't
create). Exit codes: `0` clean, `1` lint-gate failure or abort, `3`
conflicts were kept (useful in CI to detect drift).

After scaffolding: `sandboxctl deploy` (or `bootstrap`) builds the
images, pushes the charts to Gitea, and wires the URLs — or
`sandboxctl install` for the same stack via plain helm, no GitOps.

### The promotion pipeline (Argo CD + Kargo)

Alongside each chart, scaffold generates a per-app GitOps pipeline
under `k8s/gitops/<app>/` that finally puts the bundled Kargo to work:

```
sandboxctl build ──▶ sandbox registry (localhost:5050/<app>)
                          │  Warehouse watches :latest by digest —
                          ▼  every push becomes promotable Freight
                    Stage dev ── promote ──▶ Stage staging
                          │                        │
              commits image.digest into    commits image.digest into
              values-sandbox.yaml          values-staging.yaml
                          │                        │
                          ▼  (chart repo in the sandbox Gitea)
                    Argo CD syncs ns <app>   Argo CD syncs ns <app>-staging
```

- `project.yaml` — Kargo Project `<app>-kargo` (its own namespace, so it
  never collides with the app's deployment namespaces)
- `warehouse.yaml` — watches the app's image in the in-cluster registry
  (`Digest` strategy on `latest`, so mutable-tag pushes still promote)
- `stages.yaml` — `dev` takes Freight straight from the Warehouse;
  `staging` only takes what dev has; each promotion clones the chart
  repo from Gitea, `yaml-update`s `image.digest`, commits, pushes, and
  points the stage's Argo app at the new revision
- `application.yaml` — the two stage-annotated Argo CD Applications
  (dev keeps the plain `<app>` name, so URLs/status/undeploy behave
  exactly as before; staging lands in `<app>-staging`)

`sandboxctl deploy` applies the pipeline (creating the Gitea
credentials Secret Kargo needs) instead of its classic single
Application. Promote from the Kargo UI (`sandboxctl kargo-ui`) or CLI.
`sandboxctl undeploy --name <app>` tears down both Applications and the
Kargo project. Repos that already have GitOps manifests are left
untouched, and `--no-gitops` opts out entirely. The manifests are plain
YAML — point them at a real Argo CD + Kargo by swapping the commented
in-cluster endpoints.

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
   and prompts you to fill the values. No example file yet? `sandboxctl
   scaffold` generates one from the environment variables your code
   actually references (see [Secrets](#secrets)).
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
| `--build-cpus N` / `--build-memory SIZE` | Forwarded to the build step. Cap the podman build container so a hot Go/Rust compile can't starve kind. Default: half the Podman VM along each axis; `0` opts out. See [Image management](#image-management). |
| `--build-runtime podman\|docker` / `--on-host` | Forwarded to the build step. Pick the build runtime; `--on-host` is shorthand for `--build-runtime docker`. |

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
│   └── secrets.example.yaml    # template — committed (hand-written, or
│                               # generated by `sandboxctl scaffold`)
└── ...
```

With this layout, `sandboxctl deploy` from the repo root needs no flags.

### Chart adaptation

`sandboxctl deploy` reads the chart's `values.yaml` and adapts to whatever
shape it finds, so you rarely need sandboxctl-specific values. Four passes
run automatically — each is opt-in, opt-out-able, and logged so you can
see *why* a decision was made.

**1. Chart-shipped `Ingress` is auto-disabled.** sandboxctl already creates
an Istio VirtualService for `<chart>.sandbox.app`, so a chart-defined
`Ingress` would either fight that route or stall waiting for an
`IngressClass` this cluster doesn't ship. Any `*.ingress.enabled: true`
or `*.ingress.create: true` key in `values.yaml` is flipped to `false`
via Argo helm parameters at deploy time. Your chart stays portable — the
toggle is only forced off inside sandboxctl, never edited.

**2. Multi-image pinning.** For each image in your build manifest,
sandboxctl walks the chart's `values.yaml` for nodes shaped like
`{ repository: …, tag: … }` and pins the matching one to the freshly
built image. Matching is by name: image `ui` ↔ group `ui.image`,
image `backend` ↔ group `backend.image`. Single-image charts still get
the legacy `image.repository` / `image.tag` pin. Charts with neither
shape get nothing — sandboxctl never guesses.

**3. Smarter primary-Service selection.** The VirtualService points at
your chart's most-likely-user-facing Service. The picker scores each
Service in the namespace by name match, web ports (80/8080/3000/8081),
name keywords (`ui`/`web`/`frontend` win; `backend`/`api`/`worker` get
a penalty), and falls back to first alphabetical when scores tie.

**4. Explicit overrides.** When the heuristic guesses wrong, take
control:

- **Annotation** — add `sandboxctl.io/primary: "true"` to the Service
  you want routed. Wins against everything else.

- **`sandboxctl.yaml`** — declare the entrypoint inline:

  ```yaml
  images:
    - name: backend
      context: app/backend
    - name: ui
      context: app/ui

  # Pick the Service routed to <chart>.sandbox.app:
  primary_service: hello-sandbox-ui

  # Map build-manifest images to values.yaml groups when the names
  # don't already match by convention:
  chart_image_map:
    ui: ui.image
    backend: backend.image
  ```

The deploy transcript logs each decision (`auto-disabling chart toggle
ingress.enabled=false`, `pinning ui.image → localhost:5050/ui:latest`,
`primary Service: svc/hello-sandbox-ui:80 (scored 90 …)`) so you can
debug without re-reading the script.

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
sandboxctl build --build-cpus 2 --build-memory 4g
                                          # cap the podman build at 2 cores / 4 GiB
                                          #   so kind keeps headroom during a hot compile
sandboxctl build --build-cpus 0           # opt out of capping (use the whole VM)
sandboxctl build --on-host                # alias for --build-runtime docker
sandboxctl images                         # list everything in the registry
sandboxctl images rm myapp:v1             # delete one tag
sandboxctl images rm myapp                # delete every tag of an image
sandboxctl images prune                   # delete every image, then GC blobs (alias: purge)
sandboxctl images purge                   # same as prune — for users coming from podman/docker
sandboxctl images gc                      # garbage-collect blobs only
```

`--purge-old-tags`, `--build-cpus`, `--build-memory`, `--build-runtime`,
and `--on-host` are also accepted by `sandboxctl deploy` and
`sandboxctl bootstrap`, where they forward to the build step.

### Why the build caps exist

`sandboxctl build` runs `podman build`, and `podman build` shares the
Podman VM with the kind cluster. A burst-y Go/Rust compile can claim
every CPU and most of the VM's RAM — kubelet on the kind control-plane
then misses heartbeats and the cluster goes "down" mid-build.

Default behaviour: pin the build to half the Podman VM's CPUs (via
`--cpuset-cpus 0..N-1`) and half its RAM (via `--memory`), resolved at
runtime from `podman machine inspect`. Override with
`--build-cpus`/`--build-memory`, opt out with `0`, or move the build
off the Podman VM entirely with `--build-runtime docker` /
`--on-host` (only meaningful when `docker` points at a separate daemon
like Docker Desktop — on a podman-only host, `docker` is the podman
CLI in disguise and lands in the same VM).

| Flag | Env var | What |
|---|---|---|
| `--build-cpus N` | `SANDBOX_BUILD_CPUS` | Pin podman build to N cores. Default `auto` (= half the VM). `0` disables. |
| `--build-memory SIZE` | `SANDBOX_BUILD_MEMORY` | RAM cap, e.g. `4g`, `1500m`. Default `auto`. `0` disables. |
| `--build-runtime podman\|docker` | `SANDBOX_BUILD_RUNTIME` | Force a specific runtime. Default: docker if its daemon is reachable, else podman. |
| `--on-host` | — | Shorthand for `--build-runtime docker`. |

## Cluster lifecycle

```sh
sandboxctl up                             # bring everything up (1 worker, ~5 GB RAM)
sandboxctl up --workers 2                 # 2 workers, more headroom for concurrent pods
sandboxctl up --workers 3                 # 3 workers, recommended for 32 GB+ Macs
sandboxctl up --podman-disk 80 --podman-memory 12g
                                          # resize the Podman VM and remember the size
                                          #   (persisted to ~/.sandboxctl/podman.env)
sandboxctl status                         # cluster + workload status + URLs
sandboxctl validate                       # curl each URL and report HTTP codes
sandboxctl creds                          # admin passwords for Argo CD + Kargo
sandboxctl argocd-ui                      # print just the Argo CD URL + admin creds
sandboxctl kargo-ui                       # print just the Kargo URL + admin creds
sandboxctl restart                        # re-apply installers, keep cluster + state
sandboxctl restart --rebuild              # full wipe-and-rebuild (alias: --full)
sandboxctl restart --workers 3            # resize the cluster (implies --rebuild)
sandboxctl restart --podman-cpus 8        # live-resize the Podman VM (cpu/memory only;
                                          #   disk grow surfaces a setup-podman --recreate hint)
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
laptop: Argo CD runs full-featured minus SSO (`applicationset` and
`notifications` stay on — the GitOps scaffolding uses them — only `dex`
is dropped), everything runs a single replica with small CPU/memory
requests (no CPU limits — only memory limits, so nothing balloons or
gets CPU-throttled), and the shared Postgres has capped memory.
The default `up` (agentgateway + platform) fits comfortably in the default
**4 CPU / 6 GB** VM — agentgateway adds a control-plane pod and one
data-plane proxy pod (~150 MB total). Turning on the heavier opt-ins —
especially `--with-litellm` (~700 MB image, ~1-2 GB RAM) or
`--with-ai-gateway` (all of them) — is when it's worth bumping the podman
VM. Use the `--podman-*` flags so the choice is remembered across runs:

```sh
sandboxctl restart --podman-cpus 6 --podman-memory 10g
# or, on a fresh machine:
sandboxctl up --podman-cpus 6 --podman-memory 10g --podman-disk 80
```

`--podman-cpus` and `--podman-memory` are applied live to an existing
rootful machine (`podman machine set …` under the hood). `--podman-disk`
needs a destructive recreate — sandboxctl prints the exact
`setup-podman --disk-size N --recreate` command instead of silently
downgrading. All three values are persisted to
`~/.sandboxctl/podman.env` and re-applied on every later `up`/`restart`,
so you only pass each flag once. The raw `podman machine set …`
recipe still works if you prefer it; sandboxctl will pick the new size
up via the existing `PODMAN_MACHINE_*` env vars.

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

### Deep clean + redeploy

When the Podman VM is genuinely full and you want to reset every cached
layer before a fresh build, chain a runtime-wide prune with
`--purge-old-tags`:

```sh
podman system prune -a -f --volumes \
  && podman builder prune -af \
  && sandboxctl deploy --chart path/to/your/chart --purge-old-tags
```

What this does, in order:

1. `podman system prune -a -f --volumes` — drop every stopped container,
   every dangling and unused image, every unused network, and every
   unused volume on the Podman VM. Running containers (the kind nodes
   and their attached volumes) are kept, so the cluster itself survives.
2. `podman builder prune -af` — wipe BuildKit's build-cache layers,
   which `system prune` doesn't always reach.
3. `sandboxctl deploy … --purge-old-tags` — rebuild and push, deleting
   every prior tag of each repo from the in-cluster registry before the
   new push and registry-GC'ing at the end, so only the tag you just
   pushed survives.

Useful as an occasional "reset the disk" pass before a clean build —
e.g. after a long sprint of churny image rebuilds. It is heavier than
`sandboxctl prune`: `--volumes` removes any unused anonymous volumes,
including ones from prior `kind` clusters or other podman projects on
the same VM. If you have unrelated podman work on the host, prefer
`sandboxctl prune` instead.

The first `up` prompts for `sudo` once — it edits `/etc/hosts` and trusts
the local root CA in the System keychain. Subsequent runs are silent.

## Requirements

- macOS (Apple Silicon or Intel)
- Homebrew with `kind`, `kubectl`, `helm`, `go`, and one of `podman`
  (recommended) or `docker`
- ≈6 GiB free RAM for the kind node + cluster workloads

**The toolchain heals itself.** `up` checks `kind`/`kubectl`/`helm`
against the versions sandboxctl is tested with: a missing tool is
brew-installed, one below the tested floor is brew-upgraded, healthy
tools are never touched, and every action is logged. Anything
unexpected (no brew, unparseable version) degrades to a warning — the
run continues. Floors show up in `sandboxctl versions` as
`<tool> (local)` rows; opt out with `SANDBOX_NO_TOOL_AUTOFIX=1`.

`sandboxctl setup-podman` installs and configures podman for you (rootful,
6 GiB memory, 60 GiB disk) if it isn't ready yet. To pick a different
size on first run:

```sh
sandboxctl setup-podman --disk-size 80 --memory 8192 --cpus 6
```

Or, equivalently — and persisted, so you don't have to re-pass the
flags every time:

```sh
sandboxctl up --podman-disk 80 --podman-memory 8g --podman-cpus 6
```

Existing machine too small? podman can't grow a VM's disk in place —
the only way to bump disk size is to recreate the machine, which wipes
its images, containers, and any kind cluster living inside:

```sh
sandboxctl down                            # tear the cluster down first
sandboxctl setup-podman --disk-size 80 --recreate
sandboxctl up                              # rebuild the cluster
```

`sandboxctl restart --podman-disk 80` does **not** silently recreate;
it prints the exact `setup-podman --recreate` command above so the
destructive step stays explicit. CPU and memory changes via
`--podman-cpus`/`--podman-memory` are non-destructive and applied live.

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
| `PODMAN_MACHINE_CPUS` | `4` | CPUs the podman VM gets at init. Saved value from `--podman-cpus` (in `~/.sandboxctl/podman.env`) wins over this default; an explicit env var still wins over both. |
| `PODMAN_MACHINE_MEMORY_MIB` | `6144` | RAM in MiB. Same precedence as `PODMAN_MACHINE_CPUS`. |
| `PODMAN_MACHINE_DISK_GIB` | `60` | virtual-disk size for the podman VM at init. podman has no in-place disk grow — use `setup-podman --disk-size N --recreate` to bump an existing machine. Same as `setup-podman --disk-size N` or `--podman-disk N` (persisted). |
| `SANDBOX_PODMAN_CONFIG` | `~/.sandboxctl/podman.env` | Persisted Podman VM sizing — written by `--podman-cpus`/`--podman-memory`/`--podman-disk` and sourced on every run so saved values become defaults. |
| `KIND_NODE_IMAGE` | `kindest/node:v1.35.0` | kind node image |
| `SANDBOX_WORKER_COUNT` | `1` | kind worker nodes (1–3). Same as `--workers N`. |
| `SANDBOX_BUILD_PURGE_OLD_TAGS` | `0` | wipe prior tags of each repo before pushing during `build`/`deploy`/`bootstrap`, then registry-GC at the end. Same as `--purge-old-tags`. |
| `SANDBOX_BUILD_CPUS` | `auto` | cap podman build CPU. `auto` resolves to half the Podman VM's CPUs at runtime; `0` disables. Same as `--build-cpus`. |
| `SANDBOX_BUILD_MEMORY` | `auto` | cap podman build memory (e.g. `4g`, `1500m`). `auto` resolves to half the VM's RAM; `0` disables. Same as `--build-memory`. |
| `SANDBOX_BUILD_RUNTIME` | (empty) | force `podman` or `docker` for the build leg. Default: docker if reachable, else podman. Same as `--build-runtime`. |
| `ARGO_HEALTH_ATTEMPTS` | `3` | number of 180s windows `deploy` waits for an Argo Application to become Synced+Healthy (default covers up to 9 min for slow CRD-heavy syncs). |
| `ARGOCD_CHART_VERSION` | `10.1.3` | argo-cd chart version (ships Argo CD `v3.4.5`); `latest` resolves at install time |
| `KARGO_CHART_VERSION` | `1.10.8` | kargo chart version (chart tracks the app version); `latest` resolves at install time; scaffold-generated manifests need ≥ `1.3.0` |
| `REFLECTOR_CHART_VERSION` | `10.0.58` | emberstack/reflector chart version |
| `CERT_MANAGER_CHART_VERSION` | `v1.21.0` | cert-manager chart version |
| `ISTIO_CHART_VERSION` | `1.30.2` | Istio chart version |
| `KAGENT_CHART_VERSION` | `0.9.11` | kagent chart version |
| `GITEA_CHART_VERSION` | `12.6.0` | Gitea chart version (ships Gitea `1.26.1`) |
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

## Managing component versions

`sandboxctl versions` is the doctor view of everything `up` installs:

```
COMPONENT      PINNED (chart→app)     LATEST (chart→app)     INSTALLED    STATUS
argo-cd        10.1.3 → v3.4.5        10.1.3 → v3.4.5        v3.4.5       ok
kargo          1.10.8                 1.10.8                 v1.10.8      ok
cert-manager   v1.21.0                v1.21.0                v1.21.0      ok
…
```

- **PINNED** is the tool's tested default (or your env override, marked
  `(env)`); the chart→app mapping is spelled out because they differ
  (argo-cd chart `10.1.3` ships Argo CD `v3.4.5`).
- **LATEST** is resolved from the chart repos (`--offline` skips it);
  **INSTALLED** is read from the running cluster when reachable.
- Compatibility floors are enforced: pinning Kargo below `1.3.0` (where
  the promotion vocabulary the scaffolding generates first appeared)
  exits non-zero and `up` warns. `--json` for scripts.

Want bleeding edge? `ARGOCD_CHART_VERSION=latest` /
`KARGO_CHART_VERSION=latest` resolve to the newest stable at install
time (logged, never silent) — pinned defaults stay the default for
reproducibility. A weekly `bump-components` workflow keeps the pins
fresh: it resolves upstream, render-checks the new version with the
exact `--set` profile `up` uses, runs the test suite, and opens one PR
per component.

## Secrets

Every install gets its own random secrets — there are **no shared
passwords baked into this repo**. On first `up` sandboxctl generates a
random Kargo admin password, JWT signing key, and Gitea admin password,
saved to `~/.sandboxctl/` (`chmod 600`) and reused on subsequent runs.
`sandboxctl creds` prints them.

The local CA private key is generated by cert-manager inside the cluster
and never leaves it.

### App secrets

`sandboxctl scaffold` scans your code for environment variable
references (`os.Getenv`, `process.env.X`, `os.environ[...]`, dotenv
example files, compose `environment:` keys, Dockerfile `ENV`/`ARG`) and
splits them by name heuristics:

- **Secret-like** (`*_SECRET`, `*_TOKEN`, `*_PASSWORD`, `*_API_KEY`,
  connection strings like `DATABASE_URL`, …) land in a generated
  `k8s/secrets.example.yaml`: one `Secret` per app, `stringData` so you
  paste values in **plain text** (no base64), and every key carries a
  comment naming the `file:line` that references it. The generated
  charts consume the Secret via `envFrom`, and Reloader rolls the pods
  whenever you re-apply it.
- **Plain configuration** (`LOG_LEVEL`, `API_URL`, …) is listed as
  comments in the chart's `values.yaml` `env:` block instead — config
  belongs in values, not in Secrets.

**When the sandbox is running, scaffold fills `k8s/secrets.yaml` for
you**: platform credentials resolve straight from the cluster —
`CLICKHOUSE_PASSWORD` from the unique clickhouse Secret,
`DATABASE_URL` from a CNPG-style `uri` key, `REDIS_HOST` from the
Service DNS, and so on — leaving placeholders only for truly external
values (Stripe keys, …). Ambiguous matches resolve to *nothing* (a
wrong credential is worse than a placeholder), every fill logs its
source (never the value), and the pass is strictly additive: it only
ever replaces `<required — …>` placeholders — values anyone set and
keys anyone hand-added are never overwritten or removed. `deploy` runs
the same resolution when it first creates `k8s/secrets.yaml`, so the
edit-prompt only appears if anything is actually left. Pin a
resolution explicitly when the heuristics can't:

```yaml
secrets:
  resolve:
    DATABASE_URL: secret://cnpg/app-db/uri
    CLICKHOUSE_HOST: service://clickhouse/clickhouse:8123
```

`.gitignore` learns `k8s/secrets.yaml` and `.env` before the template
is written, scaffold warns loudly if either is already **tracked** by
git, real `.env` values are never read (only `*.example/sample/template`
keys), and `deploy` refuses to apply a secrets file that still contains
`<required — …>` placeholders. Pin misclassified names in
`sandboxctl.yaml`:

```yaml
secrets:
  include: [MY_OPAQUE_VAR]   # force into the Secret template
  exclude: [NATS_URL]        # force out (plain config)
```

## Troubleshooting

```sh
sandboxctl doctor                         # validate EVERYTHING, with fixes
sandboxctl status                         # is everything running?
sandboxctl validate                       # do the URLs answer?
tail -f ~/.sandboxctl/portfwd.log         # port-forward output
```

Common issues:

- **`kubectl` can't see the sandbox.** By design: sandboxctl keeps its
  cluster in its own kubeconfig and never touches `~/.kube/config` (on
  work laptops that file belongs to other clusters, and hijacking
  `current-context` broke people). Point your tools at it per shell:

  ```sh
  eval "$(sandboxctl kubeconfig --export)"
  ```

  or opt in to merging it into your default config (your
  current-context is preserved, a backup is written):

  ```sh
  sandboxctl kubeconfig --merge
  ```

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
