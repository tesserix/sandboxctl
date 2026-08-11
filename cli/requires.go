package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"gopkg.in/yaml.v3"
)

// manifestRequire is one entry under `requires:` in sandboxctl.yaml — a
// declaration that this repo cannot run until another repo's chart is
// deployed. `depends_on` orders images inside one repo; `requires`
// orders whole repos.
//
//	requires:
//	  - name: temporal-service
//	    repo: ../temporal-service          # or: git + ref
//	    chart: k8s/charts/temporal-service
//	    values: values-local.yaml
//	    needs: [postgres]                  # other requires entries first
//	    provides:
//	      service: temporal-server-frontend.temporal-service:7233
//
// `provides.service` is what makes the dependency skippable: if that
// Service already has ready endpoints, the dependency is satisfied and
// nothing is rebuilt or redeployed.
type manifestRequire struct {
	Name     string          `yaml:"name"`
	Repo     string          `yaml:"repo,omitempty"`
	Git      string          `yaml:"git,omitempty"`
	Ref      string          `yaml:"ref,omitempty"`
	Chart    string          `yaml:"chart,omitempty"`
	Values   string          `yaml:"values,omitempty"`
	Needs    []string        `yaml:"needs,omitempty"`
	Provides requireProvides `yaml:"provides,omitempty"`
}

type requireProvides struct {
	Service string `yaml:"service,omitempty"`
}

// requiresManifest is a narrow view of sandboxctl.yaml: parsing only the
// key we need keeps `requires` readable by an older binary's build path
// and vice versa.
type requiresManifest struct {
	Requires []manifestRequire `yaml:"requires"`
}

// splitProvidedService splits "svc.ns[.svc.cluster.local][:port]" into
// its parts. The namespace is mandatory — a bare Service name would be
// probed against whatever namespace the caller happened to be in.
func splitProvidedService(s string) (svc, ns, port string, err error) {
	hostport := strings.TrimSpace(s)
	if hostport == "" {
		return "", "", "", nil
	}
	if i := strings.LastIndex(hostport, ":"); i >= 0 {
		port = hostport[i+1:]
		hostport = hostport[:i]
		if _, convErr := strconv.Atoi(port); convErr != nil {
			return "", "", "", fmt.Errorf("provides.service %q: port %q is not a number", s, port)
		}
	}
	parts := strings.Split(strings.TrimSuffix(hostport, "."), ".")
	if len(parts) < 2 || parts[0] == "" || parts[1] == "" {
		return "", "", "", fmt.Errorf("provides.service %q: want <service>.<namespace>[.svc.cluster.local][:<port>]", s)
	}
	return parts[0], parts[1], port, nil
}

// parseRequires validates the `requires:` block and returns it in
// dependency-first order (a `needs:` entry always precedes the entry
// that names it).
func parseRequires(data []byte) ([]manifestRequire, []string, error) {
	var m requiresManifest
	if err := yaml.Unmarshal(data, &m); err != nil {
		return nil, nil, err
	}
	seen := map[string]bool{}
	for i, r := range m.Requires {
		if r.Name == "" {
			return nil, nil, fmt.Errorf("requires[%d]: missing 'name'", i)
		}
		if seen[r.Name] {
			return nil, nil, fmt.Errorf("requires: duplicate name %q", r.Name)
		}
		seen[r.Name] = true
		switch {
		case r.Repo == "" && r.Git == "":
			return nil, nil, fmt.Errorf("requires[%s]: needs either 'repo' (local path) or 'git' (clone URL)", r.Name)
		case r.Repo != "" && r.Git != "":
			return nil, nil, fmt.Errorf("requires[%s]: 'repo' and 'git' are mutually exclusive", r.Name)
		}
		if _, _, _, err := splitProvidedService(r.Provides.Service); err != nil {
			return nil, nil, fmt.Errorf("requires[%s]: %w", r.Name, err)
		}
		if r.Git != "" && r.Ref == "" {
			m.Requires[i].Ref = "main"
		}
	}
	// An unknown `needs:` target is a typo in a hand-written manifest, and
	// silently ignoring it means the dependency deploys in the wrong order
	// for reasons nobody can see.
	for _, r := range m.Requires {
		for _, n := range r.Needs {
			if !seen[n] {
				return nil, nil, fmt.Errorf("requires[%s]: needs %q, which is not declared in requires", r.Name, n)
			}
		}
	}

	names := make([]string, len(m.Requires))
	deps := make([][]string, len(m.Requires))
	for i, r := range m.Requires {
		names[i], deps[i] = r.Name, r.Needs
	}
	order, warnings := topoSortNodes(names, deps)
	out := make([]manifestRequire, 0, len(m.Requires))
	for _, i := range order {
		out = append(out, m.Requires[i])
	}
	return out, warnings, nil
}

// requireSep separates the fields runParseRequires emits. Deliberately
// not a tab: most fields here are optional, and bash's `read` treats a
// run of IFS *whitespace* as one delimiter, so `a\t\t\tb` silently
// shifts every field after the gap. A non-whitespace separator keeps
// empty fields empty.
const requireSep = "|"

// runParseRequires is invoked as `sandboxctl _parse-requires <path>` — a
// hidden subcommand consumed by sandbox.sh's _deploy_requires. Emits one
// pipe-separated line per dependency, in deploy order:
//
//	name|repo|git|ref|chart|values|svc|ns|port|needs-comma-sep
//
// Exits 0 with no output when the manifest declares no `requires:`, so
// the caller can treat "no dependencies" and "nothing to do" alike.
func runParseRequires(args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: sandboxctl _parse-requires <path>")
		return 2
	}
	path, err := filepath.Abs(args[0])
	if err != nil {
		fmt.Fprintf(os.Stderr, "_parse-requires: resolve %s: %v\n", args[0], err)
		return 1
	}
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return 0
		}
		fmt.Fprintf(os.Stderr, "_parse-requires: read %s: %v\n", path, err)
		return 1
	}
	reqs, warnings, err := parseRequires(data)
	if err != nil {
		fmt.Fprintf(os.Stderr, "_parse-requires: %s: %v\n", path, err)
		return 1
	}
	for _, w := range warnings {
		fmt.Fprintf(os.Stderr, "_parse-requires: %s\n", w)
	}
	for _, r := range reqs {
		svc, ns, port, _ := splitProvidedService(r.Provides.Service)
		fields := []string{
			r.Name, r.Repo, r.Git, r.Ref, r.Chart, r.Values,
			svc, ns, port, strings.Join(r.Needs, ","),
		}
		for _, f := range fields {
			if strings.Contains(f, requireSep) {
				fmt.Fprintf(os.Stderr, "_parse-requires: %s: requires[%s]: %q contains %q, which is reserved as a field separator\n",
					path, r.Name, f, requireSep)
				return 1
			}
		}
		fmt.Println(strings.Join(fields, requireSep))
	}
	return 0
}
