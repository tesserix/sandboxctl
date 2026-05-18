# Contributing

Thanks for the interest. sandboxctl is small on purpose, so the bar is "does
it make the tool simpler or more reliable for the next person on a fresh
Mac".

## Local dev loop

```sh
./install.sh             # rebuilds the Go CLI
sandboxctl restart       # apply your changes against a real cluster
sandboxctl validate      # smoke-test the URLs from the Mac
```

`bash -n sandbox.sh` is a quick syntax check.

## Style

- **Bash** with `set -euo pipefail`. Keep functions small; prefer one
  responsibility per function.
- **Go** for the CLI. Standard library only, no extra deps unless something
  is genuinely missing.
- Comments explain *why*, not *what*. If a comment is repeating the code,
  delete it.
- Keep the install pipeline idempotent. `up` running twice in a row should
  do almost nothing the second time.

## Pull requests

- One topic per PR. A bug fix and a refactor go in two separate PRs.
- Include the output of `sandboxctl validate` after your change so reviewers
  can see the URLs still answer.
- If you add a new env override, document it in `README.md` and `usage()` in
  `sandbox.sh`.
- Keep commit messages plain — describe what changed and why, in normal
  English. No tooling attribution.

## Reporting bugs

Open an issue with:

- macOS version, chip (Apple Silicon vs Intel)
- `sandboxctl status` output
- The portion of `~/.sandboxctl/portfwd.log` around the failure if it's a
  reachability issue
- Whether you're running `podman` or `docker`
