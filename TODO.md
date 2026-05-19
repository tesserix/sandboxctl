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
