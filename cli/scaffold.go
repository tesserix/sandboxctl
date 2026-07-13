package main

import (
	"bufio"
	"fmt"
	"os"
	"strings"

	"github.com/tesserix/sandboxctl/cli/internal/chartgen"
	"github.com/tesserix/sandboxctl/cli/internal/genwrite"
	"github.com/tesserix/sandboxctl/cli/internal/reposcan"
)

// runScaffold implements `sandboxctl scaffold [dir]` — analyze the repo,
// plan the generated files, show the plan, and write through the
// safe-write engine. Runs entirely in Go: no cluster, no sandbox.sh.
func runScaffold(args []string) int {
	var (
		dir           = "."
		dryRun, force bool
		yes           bool
	)
	for _, a := range args {
		switch a {
		case "--dry-run":
			dryRun = true
		case "--force":
			force = true
		case "--yes", "-y":
			yes = true
		case "-h", "--help":
			fmt.Print(`sandboxctl scaffold [dir] [--dry-run] [--force] [--yes]

Analyzes the repo (monorepo-aware), generates one Helm chart per
detected app with sandbox-ready values, and writes them through the
safe-write engine:

  - files you authored are never touched
  - files scaffold generated earlier regenerate only if you never
    edited them; edited ones prompt with a diff (default: keep yours)
  - the full plan is shown and confirmed before anything is written

Flags:
  --dry-run   print the analysis + plan, write nothing
  --yes       accept the plan without the interactive prompt
  --force     overwrite files you edited after generation (still never
              touches files scaffold didn't create)

After scaffolding: 'sandboxctl deploy' builds the images, pushes the
chart(s) to the in-cluster Gitea, and wires URLs.
`)
			return 0
		default:
			if strings.HasPrefix(a, "-") {
				fmt.Fprintf(os.Stderr, "scaffold: unknown flag %s\n", a)
				return 2
			}
			dir = a
		}
	}

	model, err := reposcan.Scan(dir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "scaffold: %v\n", err)
		return 1
	}
	for _, w := range model.Warnings {
		fmt.Fprintf(os.Stderr, "scaffold: warning: %s\n", w)
	}
	printAnalyzeSummary(model)
	if len(model.Apps) == 0 {
		fmt.Println("\nnothing to scaffold — no apps detected")
		return 0
	}

	gen := chartgen.Ops(model, registryHostPort())
	if len(gen.Skips) > 0 {
		fmt.Println()
		for _, s := range gen.Skips {
			fmt.Printf("  skip  %-16s %s\n", s.App, s.Reason)
		}
	}
	if len(gen.Ops) == 0 {
		fmt.Println("\nnothing to scaffold — every app is already covered")
		return 0
	}

	plan, err := genwrite.BuildPlan(model.Root, gen.Ops)
	if err != nil {
		fmt.Fprintf(os.Stderr, "scaffold: %v\n", err)
		return 1
	}
	fmt.Println()
	genwrite.RenderPlan(os.Stdout, plan)

	if dryRun {
		fmt.Println("\ndry run — nothing written")
		return 0
	}

	interactive := stdinIsTTY()
	if !yes && !force {
		if !interactive {
			fmt.Println("\nno TTY and no --yes — stopping after the plan (re-run with --yes to write)")
			return 0
		}
		fmt.Print("\nProceed? [y/N] ")
		line, _ := bufio.NewReader(os.Stdin).ReadString('\n')
		switch strings.ToLower(strings.TrimSpace(line)) {
		case "y", "yes":
		default:
			fmt.Println("aborted — nothing written")
			return 1
		}
	}

	opts := genwrite.Options{Force: force}
	if interactive && !force {
		opts.Resolve = genwrite.PromptResolver(os.Stdin, os.Stdout)
	}
	res, err := genwrite.Apply(plan, opts)
	if err != nil {
		fmt.Fprintf(os.Stderr, "scaffold: %v\n", err)
		return 1
	}

	fmt.Println()
	genwrite.RenderResult(os.Stdout, res)
	if len(res.Created) > 0 || len(res.Regenerated) > 0 || len(res.Overwritten) > 0 {
		fmt.Println("\nnext: 'sandboxctl deploy' to build the image(s), push the chart(s) to Gitea, and wire URLs")
	}
	return res.ExitCode()
}

// registryHostPort mirrors sandbox.sh's SANDBOX_REGISTRY_PORT handling
// so scaffolded image coordinates line up with what build/deploy use.
func registryHostPort() string {
	port := os.Getenv("SANDBOX_REGISTRY_PORT")
	if port == "" {
		port = "5050"
	}
	return "localhost:" + port
}

func stdinIsTTY() bool {
	fi, err := os.Stdin.Stat()
	return err == nil && fi.Mode()&os.ModeCharDevice != 0
}
