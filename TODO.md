# TODO

Open work that's worth doing but not yet scheduled. Delete entries
as they ship.

## 1. Test suite for pure-string functions

`sandbox.sh` has a handful of pure-string helpers that have caused
real outages this year (each bug shipped to brew before being caught
by an end user):

- `slugify`
- `deploy_namespace_for`
- `deploy_hostname_for`
- `_managed_hosts`
- `add_app_host` / `remove_app_host` (the `/etc/hosts` splice)
- `cli/manifest.go` — `_parse-build-manifest`

A small bats or shunit2 suite covering each of these would have
caught both the SIGPIPE regression (`tr -dc … | head -c 32`
returning 141 under `pipefail`) and the macOS BSD awk regression
(`sub()` silently no-op'ing on a marker string with parens) with a
5–10 line test apiece.

**Suggested layout:**

```
tests/
├── bats/
│   ├── add_app_host.bats          # splice into existing marker line
│   ├── add_app_host_no_marker.bats # add fresh line
│   ├── remove_app_host.bats
│   ├── slugify.bats
│   ├── deploy_namespace_for.bats
│   └── managed_hosts.bats
└── go/
    └── manifest_test.go           # _parse-build-manifest
```

CI: add a `test` GitHub Action that runs `bats tests/bats/` and
`go test ./cli/...`. Block release on red.

**Estimate:** 1–2 days. Highest leverage / lowest risk on this list.

## 2. Split sandbox.sh for grep-ability

At ~2900 lines `sandbox.sh` is hard to navigate. Most of that volume
is YAML/helm-values heredocs, but the orchestration is still big
enough that a four-file split would help:

```
src/
├── util.sh         # log/ok/warn/die, kc(), pure-string helpers
├── install.sh      # install_*  (cert-manager, argocd, kargo, …)
├── deploy.sh       # cmd_deploy, cmd_undeploy, cmd_bootstrap
└── cmd.sh          # cmd_up, cmd_down, cmd_status, dispatcher
```

Concatenate into a single `sandbox.sh` at Homebrew-install time so
the runtime footprint stays one file (avoids multi-file `assetDir`
headaches in the Go CLI).

**Estimate:** half a day. Pure refactor — no behaviour change, no
new tests required if (1) is already in place.

## 3. Linux support (sandbox.sh + lib/*.sh)

`brew install tesserix/tap/sandboxctl` works on macOS today; the Go
binary, goreleaser pipeline, and `cli/` already build for
`linux/{amd64,arm64}`. The shell side is what blocks Linux: ~3
darwin-only feature areas in `sandbox.sh` and `lib/nats.sh`, plus a
handful of small mac-isms.

**Detection strategy.** Auto-detect via `uname -s` (already done in
two spots: `install_dnsmasq`, `uninstall_dnsmasq`). Expose
`SANDBOX_OS` env var as an override for testing (`SANDBOX_OS=linux`).
No `--OS` CLI flag — wrong values are a footgun and detection is
trivial. Default `SANDBOX_OS` resolves to `darwin` or `linux` from
`uname -s`; anything else → `die`.

**Refactor shape.** Extract today's mac-only blocks into named
dispatch functions; the darwin branch keeps verbatim what the script
does today, the linux branch is new. No behaviour change for Mac
users.

| Concern | Today (darwin) | Linux equivalent |
| --- | --- | --- |
| port-forward supervisor | LaunchAgents (`launchctl`, `~/Library/LaunchAgents/*.plist`, `bootout`/`unload`) | `systemctl --user` units in `~/.config/systemd/user/`; fallback to `nohup … & echo $! > pidfile` when `systemctl --user` is unavailable (containers, WSL1) |
| trust store | `security add-trusted-cert -k /Library/Keychains/System.keychain` | Debian/Ubuntu: `/usr/local/share/ca-certificates/<name>.crt` + `update-ca-certificates`. Fedora/RHEL: `/etc/pki/ca-trust/source/anchors/<name>.crt` + `update-ca-trust`. Arch: `trust anchor <pem>` |
| wildcard DNS | `brew install dnsmasq` + `/etc/resolver/<domain>` | **Default: skip** — rely on `/etc/hosts` only (already maintained as the floor on both OSes). Optional follow-up: NetworkManager dnsmasq plugin or `systemd-resolved` per-link config |
| DNS cache flush | `dscacheutil -flushcache` + `killall -HUP mDNSResponder` | best-effort `resolvectl flush-caches` (systemd-resolved); no-op otherwise |
| dev tooling install | `brew install <tool>` | best-effort `apt-get install -y` / `dnf install -y` / `pacman -S --noconfirm`, gated on `command -v` and on whether the user can sudo. Warn-and-skip otherwise; the cluster install does not depend on these |
| `prune` step 2 (DMGs) | `hdiutil detach` | not applicable — skip the section on Linux |
| `sudo brew services` (dnsmasq) | LaunchAgent under launchd | `systemctl enable --now dnsmasq` if/when we add Linux DNS |

**Files that need edits.**

- `sandbox.sh`
  - Add `os_kind()` helper near the top (`darwin`|`linux`).
  - Wrap `LaunchAgent_*`, `install_portfwd`, `uninstall_portfwd`,
    `install_addtrust_ca`, `untrust_ca`, `install_hosts`,
    `remove_hosts_entries`, `install_dnsmasq`, `uninstall_dnsmasq`,
    `add_app_host`, `remove_app_host`, `ensure_tooling`,
    `_prune_*` in dispatch shells that switch on `os_kind`.
  - Move darwin bodies into `_*_darwin` helpers, add `_*_linux`
    counterparts.
- `lib/nats.sh` — same treatment for `install_nats_portfwd`,
  `uninstall_nats_portfwd`, `trust_nats_ca`, `untrust_nats_ca`,
  `install_nats_cli` (Linux: prefer the official tarball release;
  brew not assumed).
- `lib/aregistry.sh` — already OS-agnostic per a quick scan.
- README install section — document Linux install path (Linuxbrew
  works, or `tar -xzf sandboxctl_<v>_Linux_<arch>.tar.gz` + run
  `install.sh`).
- `.goreleaser.yaml` — already builds linux artefacts; add a
  Linuxbrew formula or `nfpms` (apt/dnf) packaging once the script
  changes are in.

**What to keep unchanged.** The Go CLI (`cli/`), goreleaser,
manifests, kind config, `lib/aregistry.sh`. The `kc` helper and
everything that talks to Kubernetes are already portable.

**Verification.** Manual: drive `up → deploy → status → down →
purge` on (a) macOS arm64, (b) Ubuntu 22.04 LTS amd64 with
`systemctl --user`, (c) a rootless container without systemd to
exercise the nohup fallback. Add a Linux job to the GH Actions
release matrix so the tarball at least starts a kind cluster on CI.

**Estimate:** 2–3 days end-to-end including the README + Linuxbrew
tap. Largely additive — no Mac regression risk if the dispatch
helpers default to the existing darwin code on `os_kind=darwin`.

**Open questions for when this is picked up.**

- systemd-user vs nohup-pidfile fallback — confirm we want both, or
  ship systemd-user only and document the requirement.
- DNS strategy on Linux — start with `/etc/hosts` only, or invest in
  the NetworkManager / resolved integration up-front?
- Package-manager handling — auto-`sudo apt install` like the
  darwin path auto-`brew install`s, or warn-and-skip and let the
  user install missing tools themselves?
