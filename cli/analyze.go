package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/tesserix/sandboxctl/cli/internal/envscan"
	"github.com/tesserix/sandboxctl/cli/internal/reposcan"
)

// runAnalyze implements `sandboxctl _analyze [dir] [--json]` — the
// hidden subcommand behind repo analysis. `sandbox.sh` and the future
// `scaffold` command consume the --json form; the default form prints a
// human summary for quick inspection.
func runAnalyze(args []string) int {
	jsonOut := false
	dir := "."
	for _, a := range args {
		switch a {
		case "--json":
			jsonOut = true
		case "-h", "--help":
			fmt.Println("usage: sandboxctl _analyze [dir] [--json]")
			return 0
		default:
			if len(a) > 0 && a[0] == '-' {
				fmt.Fprintf(os.Stderr, "_analyze: unknown flag %s\n", a)
				return 2
			}
			dir = a
		}
	}

	model, err := reposcan.Scan(dir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "_analyze: %v\n", err)
		return 1
	}
	for _, w := range model.Warnings {
		fmt.Fprintf(os.Stderr, "_analyze: warning: %s\n", w)
	}
	for _, w := range envscan.Attach(model) {
		fmt.Fprintf(os.Stderr, "_analyze: warning: %s\n", w)
	}

	if jsonOut {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		if err := enc.Encode(model); err != nil {
			fmt.Fprintf(os.Stderr, "_analyze: encode: %v\n", err)
			return 1
		}
		return 0
	}

	printAnalyzeSummary(model)
	return 0
}

// runOnboardStatus implements the hidden `_onboard-status [dir]` used
// by `up`'s end-of-run onboarding check. One parseable line on stdout:
//
//	<onboarded|needs-onboarding|not-a-repo> apps=N charts=N pipelines=N
//
// "Onboarded" means every buildable app (has a Dockerfile) already has
// a chart; pipelines are reported but optional.
func runOnboardStatus(args []string) int {
	dir := "."
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		dir = args[0]
	}
	model, err := reposcan.Scan(dir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "_onboard-status: %v\n", err)
		return 1
	}
	buildable, charts, pipelines := 0, 0, 0
	for _, a := range model.Apps {
		if a.Dockerfile == "" {
			continue
		}
		buildable++
		if a.Existing.Chart != "" {
			charts++
		}
		if a.Existing.GitOps != "" {
			pipelines++
		}
	}
	status := "needs-onboarding"
	switch {
	case buildable == 0:
		status = "not-a-repo"
	case charts == buildable:
		status = "onboarded"
	}
	fmt.Printf("%s apps=%d charts=%d pipelines=%d\n", status, buildable, charts, pipelines)
	return 0
}

// runResolveSecrets implements the hidden `_resolve-secrets [dir]` used
// by deploy's secrets step: same resolution scaffold performs, exit 0
// always (best-effort; the placeholder gate downstream stays the
// enforcement).
func runResolveSecrets(args []string) int {
	dir := "."
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		dir = args[0]
	}
	model, err := reposcan.Scan(dir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "_resolve-secrets: %v\n", err)
		return 0
	}
	envscan.Attach(model)
	resolveSecretsIntoFile(model, os.Stdout)
	return 0
}

func printAnalyzeSummary(m *reposcan.Model) {
	layout := m.Layout
	if m.Workspace != "" {
		layout += " (" + m.Workspace + ")"
	}
	fmt.Printf("%s — %s, %d app(s)\n", m.Root, layout, len(m.Apps))
	if len(m.Apps) == 0 {
		return
	}
	fmt.Printf("  %-16s %-14s %-24s %-6s %-9s %-11s %-9s %s\n",
		"NAME", "RUNTIME", "PATH", "PORT", "KIND", "DOCKERFILE", "ENV(SEC)", "CHART")
	for _, a := range m.Apps {
		runtime := a.Language
		if a.Framework != "" {
			runtime += "/" + a.Framework
		}
		if runtime == "" {
			runtime = "-"
		}
		port := "-"
		if a.Port > 0 {
			port = fmt.Sprintf("%d", a.Port)
		}
		df := "-"
		if a.Dockerfile != "" {
			df = "yes"
		}
		env := "-"
		if n := len(a.Env); n > 0 {
			sec := 0
			for _, r := range a.Env {
				if r.Secret {
					sec++
				}
			}
			env = fmt.Sprintf("%d(%d)", n, sec)
		}
		chart := "-"
		if a.Existing.Chart != "" {
			chart = a.Existing.Chart
		}
		fmt.Printf("  %-16s %-14s %-24s %-6s %-9s %-11s %-9s %s\n",
			a.Name, runtime, a.Path, port, a.Kind, df, env, chart)
	}
	fmt.Println("\n  run with --json for the full model including per-fact reasons")
}
