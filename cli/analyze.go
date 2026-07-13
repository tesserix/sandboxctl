package main

import (
	"encoding/json"
	"fmt"
	"os"

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

func printAnalyzeSummary(m *reposcan.Model) {
	layout := m.Layout
	if m.Workspace != "" {
		layout += " (" + m.Workspace + ")"
	}
	fmt.Printf("%s — %s, %d app(s)\n", m.Root, layout, len(m.Apps))
	if len(m.Apps) == 0 {
		return
	}
	fmt.Printf("  %-16s %-14s %-24s %-6s %-9s %-11s %s\n",
		"NAME", "RUNTIME", "PATH", "PORT", "KIND", "DOCKERFILE", "CHART")
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
		chart := "-"
		if a.Existing.Chart != "" {
			chart = a.Existing.Chart
		}
		fmt.Printf("  %-16s %-14s %-24s %-6s %-9s %-11s %s\n",
			a.Name, runtime, a.Path, port, a.Kind, df, chart)
	}
	fmt.Println("\n  run with --json for the full model including per-fact reasons")
}
