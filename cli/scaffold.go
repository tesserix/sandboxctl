package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"

	"github.com/tesserix/sandboxctl/cli/internal/chartgen"
	"github.com/tesserix/sandboxctl/cli/internal/components"
	"github.com/tesserix/sandboxctl/cli/internal/envscan"
	"github.com/tesserix/sandboxctl/cli/internal/genwrite"
	"github.com/tesserix/sandboxctl/cli/internal/gitopsgen"
	"github.com/tesserix/sandboxctl/cli/internal/reposcan"
	"github.com/tesserix/sandboxctl/cli/internal/secretsgen"
)

// runScaffold implements `sandboxctl scaffold [dir]` — analyze the repo,
// plan the generated files, show the plan, and write through the
// safe-write engine. Runs entirely in Go: no cluster, no sandbox.sh.
func runScaffold(args []string) int {
	var (
		dir           = "."
		dryRun, force bool
		yes, noGitops bool
	)
	for _, a := range args {
		switch a {
		case "--dry-run":
			dryRun = true
		case "--force":
			force = true
		case "--yes", "-y":
			yes = true
		case "--no-gitops":
			noGitops = true
		case "-h", "--help":
			fmt.Print(`sandboxctl scaffold [dir] [--dry-run] [--force] [--yes]

Analyzes the repo (monorepo-aware), generates one Helm chart per
detected app with sandbox-ready values, and writes them through the
safe-write engine:

  - files you authored are never touched
  - files scaffold generated earlier regenerate only if you never
    edited them; edited ones prompt with a diff (default: keep yours)
  - the full plan is shown and confirmed before anything is written

Alongside the charts, a GitOps promotion pipeline is generated per app
under k8s/gitops/<app>/: a Kargo Project + Warehouse watching the app's
image in the sandbox registry (every 'sandboxctl build' push becomes
promotable Freight), dev + staging Stages whose promotions commit the
image digest into the chart's Gitea repo, and the stage-annotated Argo
CD Applications they drive. 'sandboxctl deploy' applies it all.

Flags:
  --dry-run   print the analysis + plan, write nothing
  --yes       accept the plan without the interactive prompt
  --force     overwrite files you edited after generation (still never
              touches files scaffold didn't create)
  --no-gitops generate charts + secrets only, skip the Kargo pipeline

Environment variables referenced in the code are scanned too: secret-
like ones produce k8s/secrets.example.yaml (stringData — fill values in
plain text) wired to each chart via envFrom, .gitignore learns to
ignore k8s/secrets.yaml and .env, and plain configuration is listed in
the chart's values.yaml. Pin classifications in sandboxctl.yaml:

  secrets:
    include: [MY_OPAQUE_VAR]
    exclude: [NATS_URL]

Every chart written is 'helm lint'-ed immediately afterwards; a lint
failure rolls that chart's files back so a broken chart never lands in
your repo (exit 1, lint output shown).

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
	for _, w := range envscan.Attach(model) {
		fmt.Fprintf(os.Stderr, "scaffold: warning: %s\n", w)
	}
	printAnalyzeSummary(model)
	if len(model.Apps) == 0 {
		fmt.Println("\nnothing to scaffold — no apps detected")
		return 0
	}

	gen := chartgen.Ops(model, registryHostPort())
	ops := gen.Ops
	secOps, secSkip := secretsgen.Ops(model.Root, model.Apps)
	ops = append(ops, secOps...)

	// GitOps pipeline (Kargo watching the sandbox registry → dev →
	// staging via the sandbox Gitea). Charts must exist or be planned;
	// a Kargo pinned below the promotion-vocabulary floor skips the
	// whole section rather than generating manifests it can't run.
	var gitops *gitopsgen.Result
	switch kargo, _ := components.Lookup("kargo"); {
	case noGitops:
	case func() bool { v, _ := kargo.Pinned(); return kargo.FloorViolated(v) }():
		v, _ := kargo.Pinned()
		fmt.Fprintf(os.Stderr, "scaffold: warning: KARGO_CHART_VERSION=%s is below %s — skipping GitOps pipeline generation (%s)\n", v, kargo.Floor, kargo.FloorReason)
	default:
		chartDirs := map[string]string{}
		for app, d := range gen.ChartDirs {
			chartDirs[app] = d
		}
		for _, app := range model.Apps {
			if app.Existing.Chart != "" {
				chartDirs[app.Name] = app.Existing.Chart
			}
		}
		gitops = gitopsgen.Ops(model, gitopsConfig(), chartDirs)
		ops = append(ops, gitops.Ops...)
	}

	if len(gen.Skips) > 0 || secSkip != nil || (gitops != nil && len(gitops.Skips) > 0) {
		fmt.Println()
		for _, s := range gen.Skips {
			fmt.Printf("  skip  %-16s %s\n", s.App, s.Reason)
		}
		if secSkip != nil {
			fmt.Printf("  skip  %-16s %s\n", "secrets", secSkip.Reason)
		}
		if gitops != nil {
			for _, s := range gitops.Skips {
				fmt.Printf("  skip  %-16s pipeline: %s\n", s.App, s.Reason)
			}
		}
	}
	if len(ops) == 0 {
		fmt.Println("\nnothing to scaffold — every app is already covered")
		return 0
	}
	if len(secOps) > 0 {
		warnTrackedSecrets(model.Root)
	}

	plan, err := genwrite.BuildPlan(model.Root, ops)
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

	wrote := len(res.Created)+len(res.Regenerated)+len(res.Overwritten) > 0
	var lintFailed []string
	if wrote {
		if helmPath, lerr := exec.LookPath("helm"); lerr != nil {
			fmt.Fprintln(os.Stderr, "scaffold: warning: helm not found — skipping the post-scaffold lint gate (install helm to enable it)")
		} else {
			fmt.Println()
			lintFailed = lintWrittenCharts(gen.ChartDirs, res, os.Stdout, helmLintRunner(helmPath, model.Root))
		}
	}

	if len(lintFailed) > 0 {
		fmt.Fprintf(os.Stderr, "\nscaffold: helm lint failed for %s — those changes were rolled back, nothing broken was left behind\n", strings.Join(lintFailed, ", "))
		fmt.Fprintln(os.Stderr, "scaffold: if the failure points at a file you edited and kept, fix it (or re-run with --force); otherwise please report this as a chart-template bug")
		return 1
	}
	if wrote {
		fmt.Println("\nnext: 'sandboxctl deploy' to build the image(s), push the chart(s) to Gitea, and wire URLs")
	}
	return res.ExitCode()
}

// lintWrittenCharts runs the lint gate over every chart dir that
// received a write this run, rolling back any dir that fails so a
// broken chart never survives a scaffold. Returns the failed dirs.
// The runner is injected so tests can simulate failures without helm.
func lintWrittenCharts(chartDirs map[string]string, res *genwrite.Result, out io.Writer, run func(dir string) (string, error)) []string {
	var written []string
	written = append(written, res.Created...)
	written = append(written, res.Regenerated...)
	written = append(written, res.Overwritten...)

	dirs := make([]string, 0, len(chartDirs))
	for _, dir := range chartDirs {
		for _, p := range written {
			if p == dir || strings.HasPrefix(p, dir+"/") {
				dirs = append(dirs, dir)
				break
			}
		}
	}
	sort.Strings(dirs)

	var failed []string
	for _, dir := range dirs {
		output, err := run(dir)
		if err == nil {
			fmt.Fprintf(out, "  helm lint ok  %s\n", dir)
			continue
		}
		fmt.Fprintf(out, "  helm lint FAILED  %s\n%s\n", dir, indent(output, "    "))
		reverted, rbErr := res.Rollback(dir)
		if rbErr != nil {
			fmt.Fprintf(out, "  rollback of %s incomplete: %v — inspect the directory before committing\n", dir, rbErr)
		} else {
			fmt.Fprintf(out, "  rolled back %d file(s) under %s\n", len(reverted), dir)
		}
		failed = append(failed, dir)
	}
	return failed
}

func helmLintRunner(helmPath, root string) func(dir string) (string, error) {
	return func(dir string) (string, error) {
		cmd := exec.Command(helmPath, "lint", filepath.Join(root, filepath.FromSlash(dir)))
		out, err := cmd.CombinedOutput()
		return string(out), err
	}
}

func indent(s, prefix string) string {
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	for i, l := range lines {
		lines[i] = prefix + l
	}
	return strings.Join(lines, "\n")
}

// warnTrackedSecrets checks whether files that must never be committed
// are already tracked by git — sandboxctl never rewrites history, so
// the most it can responsibly do is say it loudly.
func warnTrackedSecrets(root string) {
	git, err := exec.LookPath("git")
	if err != nil {
		return
	}
	out, err := exec.Command(git, "-C", root, "ls-files", "--", "k8s/secrets.yaml", ".env").Output()
	if err != nil {
		return // not a git repo, or git unhappy — nothing to warn about
	}
	for _, f := range strings.Fields(string(out)) {
		fmt.Fprintf(os.Stderr, "scaffold: warning: %s is TRACKED by git — rotate any values it holds, then 'git rm --cached %s' (the .gitignore entry only affects untracked files)\n", f, f)
	}
}

// gitopsConfig mirrors sandbox.sh's namespace/org defaults so the
// generated pipeline points at the same in-cluster Gitea + registry the
// rest of the tool uses. Env overrides carry through for operators who
// renamed namespaces.
func gitopsConfig() gitopsgen.Config {
	registryNS := envOr("REGISTRY_NS", "sandboxctl-registry")
	giteaNS := envOr("GITEA_NS", "gitea")
	return gitopsgen.Config{
		RegistryHost: "registry." + registryNS + ".svc.cluster.local:5000",
		GiteaHost:    "gitea-http." + giteaNS + ".svc.cluster.local:3000",
		Org:          envOr("GITEA_ORG", "apps"),
	}
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
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
