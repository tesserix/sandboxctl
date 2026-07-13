package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// assetDir is injected at build time via:
//
//	go build -ldflags "-X main.assetDir=/abs/path/to/sandboxctl"
//
// It points at the directory containing sandbox.sh + manifests/.
//
// Packaged installs (e.g. Homebrew) leave assetDir empty at build time and
// set $SANDBOXCTL_ASSETS at runtime to the install prefix instead. See
// resolveAssetDir below.
var (
	assetDir = ""
	version  = "dev"
	commit   = "none"
	date     = "unknown"
)

func resolveAssetDir() string {
	if v := os.Getenv("SANDBOXCTL_ASSETS"); v != "" {
		return v
	}
	return assetDir
}

type command struct{ name, desc string }

type commandGroup struct {
	title string
	cmds  []command
}

// commandGroups drives the usage screen: grouped, short, aligned. Deep
// detail (flags, behaviours) lives in each command's --help, not here —
// a usage line that wraps is a usage line nobody reads.
var commandGroups = []commandGroup{
	{"platform", []command{
		{"up", "create the cluster + install the platform (--with-* add-ons)"},
		{"down", "remove the cluster + Mac plumbing (keeps ~/.sandboxctl)"},
		{"restart", "re-apply installers (--rebuild recreates the cluster)"},
		{"purge", "down + delete ~/.sandboxctl (asks first)"},
		{"setup-podman", "one-time podman machine setup (--cpus/--memory/--disk-size)"},
	}},
	{"your app", []command{
		{"scaffold", "repo → charts + secrets template + Kargo pipeline"},
		{"build", "build + push the repo's images to the sandbox registry"},
		{"deploy", "push charts to Gitea, create Argo apps, wire https URLs (--umbrella: whole stack as one app)"},
		{"bootstrap", "up (if needed) + deploy, in one command"},
		{"undeploy", "remove an app's Argo apps, pipeline, and route (--name)"},
	}},
	{"inspect", []command{
		{"status", "cluster + workload status + URLs"},
		{"doctor", "validate everything; exact fix printed per failure"},
		{"validate", "curl each URL and print the HTTP codes"},
		{"versions", "component pins vs latest vs installed (+ tool floors)"},
		{"creds", "Argo CD + Kargo URLs and admin credentials"},
		{"argocd-ui", "Argo CD URL + creds"},
		{"kargo-ui", "Kargo URL + creds"},
		{"kubeconfig", "sandbox kubeconfig path (--export | --merge)"},
		{"images", "registry images: list / rm / prune / purge / gc"},
		{"tui", "live status dashboard"},
	}},
	{"maintenance", []command{
		{"trust-ca", "trust the sandbox root CA (System keychain, sudo)"},
		{"untrust-ca", "remove the sandbox root CA from the keychain"},
		{"prune", "diagnose + reclaim disk (asks before each step)"},
		{"version", "print sandboxctl version, commit, and build date"},
	}},
}

func usage() string {
	var b strings.Builder
	b.WriteString("sandboxctl — local kind sandbox with Argo CD + Kargo\n")
	for _, g := range commandGroups {
		fmt.Fprintf(&b, "\n%s\n", g.title)
		for _, c := range g.cmds {
			fmt.Fprintf(&b, "  %-14s %s\n", c.name, c.desc)
		}
	}
	b.WriteString("\nrun 'sandboxctl <command> --help' for flags and details\n")
	return b.String()
}

func known(sub string) bool {
	for _, g := range commandGroups {
		for _, c := range g.cmds {
			if c.name == sub {
				return true
			}
		}
	}
	// Hidden subcommands consumed by sandbox.sh itself, not listed in usage.
	switch sub {
	case "secret",
		"_analyze",
		"_onboard-status",
		"_onboard-check",
		"_resolve-secrets",
		"_deploy-entries",
		"_resolve-latest",
		"_semver-lt",
		"_render-args",
		"_tool-check",
		"_ensure-tools",
		"_parse-build-manifest",
		"_autogen-manifest",
		"_chart-ingress-overrides",
		"_chart-image-keys",
		"_chart-image-strings",
		"_chart-mimic-values",
		"_chart-resolve-image-pins",
		"_score-services",
		"_manifest-extras":
		return true
	}
	// `cleanup` is a friendlier alias for `prune` — accepted, not advertised.
	if sub == "cleanup" {
		return true
	}
	return false
}

func scriptPath() string { return filepath.Join(resolveAssetDir(), "sandbox.sh") }

func main() {
	if len(os.Args) < 2 {
		fmt.Print(usage())
		return
	}
	sub := os.Args[1]
	switch sub {
	case "-h", "--help", "help":
		fmt.Print(usage())
		return
	case "--version", "-v", "version":
		fmt.Printf("sandboxctl %s (commit %s, built %s)\n", version, commit, date)
		return
	}
	if !known(sub) {
		fmt.Fprintf(os.Stderr, "unknown subcommand: %s\n\n%s", sub, usage())
		os.Exit(2)
	}

	// Subcommands that don't need the runtime assets (sandbox.sh +
	// manifests). Dispatch them before the assets-dir check so they
	// work in CI, in dev builds, or when the user just wants to compute
	// something locally.
	if sub == "secret" {
		os.Exit(runSecret(os.Args[2:]))
	}
	if sub == "_analyze" {
		os.Exit(runAnalyze(os.Args[2:]))
	}
	if sub == "_onboard-status" {
		os.Exit(runOnboardStatus(os.Args[2:]))
	}
	if sub == "_resolve-secrets" {
		os.Exit(runResolveSecrets(os.Args[2:]))
	}
	if sub == "scaffold" {
		os.Exit(runScaffold(os.Args[2:]))
	}
	if sub == "versions" {
		os.Exit(runVersions(os.Args[2:]))
	}
	if sub == "_resolve-latest" {
		os.Exit(runResolveLatest(os.Args[2:]))
	}
	if sub == "_semver-lt" {
		os.Exit(runSemverLt(os.Args[2:]))
	}
	if sub == "_render-args" {
		os.Exit(runRenderArgs(os.Args[2:]))
	}
	if sub == "_tool-check" {
		os.Exit(runToolCheck(os.Args[2:]))
	}
	if sub == "_parse-build-manifest" {
		os.Exit(runParseBuildManifest(os.Args[2:]))
	}
	if sub == "_autogen-manifest" {
		os.Exit(runAutogenManifest(os.Args[2:]))
	}
	if sub == "_chart-ingress-overrides" {
		os.Exit(runChartIngressOverrides(os.Args[2:]))
	}
	if sub == "_chart-image-keys" {
		os.Exit(runChartImageKeys(os.Args[2:]))
	}
	if sub == "_chart-image-strings" {
		os.Exit(runChartImageStrings(os.Args[2:]))
	}
	if sub == "_chart-mimic-values" {
		os.Exit(runChartMimicValues(os.Args[2:]))
	}
	if sub == "_chart-resolve-image-pins" {
		os.Exit(runChartResolveImagePins(os.Args[2:]))
	}
	if sub == "_score-services" {
		os.Exit(runScoreServices(os.Args[2:]))
	}
	if sub == "_manifest-extras" {
		os.Exit(runManifestExtras(os.Args[2:]))
	}

	if resolveAssetDir() == "" {
		fmt.Fprintln(os.Stderr, "sandboxctl: cannot find runtime assets — set SANDBOXCTL_ASSETS or reinstall")
		os.Exit(2)
	}

	if sub == "tui" {
		if err := runTUI(); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}

	os.Exit(runScript(os.Args[1:]...))
}

func runScript(args ...string) int {
	script := scriptPath()
	if _, err := os.Stat(script); err != nil {
		fmt.Fprintf(os.Stderr, "sandbox.sh not found at %s: %v\n", script, err)
		return 2
	}
	cmd := exec.Command("bash", append([]string{script}, args...)...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	if err := cmd.Run(); err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			return ee.ExitCode()
		}
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	return 0
}
