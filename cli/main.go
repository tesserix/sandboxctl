package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
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

var commands = []command{
	{"setup-podman", "install/configure rootful podman machine (one-time; --disk-size/--memory/--cpus, --recreate to resize disk)"},
	{"trust-ca", "trust the sandbox root CA in macOS System keychain (sudo)"},
	{"untrust-ca", "remove the sandbox root CA from System keychain (sudo)"},
	{"up", "create cluster + install argocd/kargo/demo + gitea + ingress + PKI + arctl CLI (kagent opt-in via --with-kagent or --install all; skip arctl via --no-arctl)"},
	{"down", "remove cluster + LaunchAgent + /etc/hosts + keychain CA + arctl CLI (keeps ~/.sandbox)"},
	{"purge", "down + remove ~/.sandbox (prompts for confirmation)"},
	{"status", "cluster + workload status + URLs"},
	{"restart", "re-apply installers, keep cluster + state (--rebuild for full wipe)"},
	{"validate", "curl each URL from the Mac and print HTTP codes"},
	{"creds", "print login details (URLs + admin creds) for Argo CD + Kargo"},
	{"argocd-ui", "print Argo CD URL + admin creds"},
	{"kargo-ui", "print Kargo  URL + admin creds"},
	{"scaffold", "analyze the repo (monorepo-aware) + generate Helm chart(s) with sandbox values — skips existing files, asks before overwriting edits (--dry-run/--yes/--force)"},
	{"build", "build + push Dockerfiles in the product repo (--repo <dir> | [path] | cwd)"},
	{"images", "list / rm <ref> / prune / purge / gc — manage images in the cluster registry"},
	{"deploy", "discover charts in the product repo (--repo <dir> | [path] | cwd) + push to Gitea + create Argo Apps (--redeploy: chart-only sync, reuse existing image, force Argo refresh)"},
	{"undeploy", "remove the Argo Application + route created by 'deploy'"},
	{"bootstrap", "'up' (if needed) + 'deploy' in one command (--repo <dir> | [path] | cwd)"},
	{"versions", "component version doctor: pinned (chart→app) vs latest vs installed, with compatibility floors (--offline/--json; exits 1 on a floor violation)"},
	{"prune", "diagnose + clean disk: host / mounted DMGs / runtime VM / cluster registry (prompts before each step; alias: cleanup)"},
	{"tui", "live status dashboard (Bubble Tea)"},
	{"version", "print sandboxctl version, commit, and build date"},
}

func usage() string {
	s := "sandboxctl — local kind sandbox with Argo CD + Kargo\n\nusage:\n"
	for _, c := range commands {
		s += fmt.Sprintf("  sandboxctl %-13s %s\n", c.name, c.desc)
	}
	return s
}

func known(sub string) bool {
	for _, c := range commands {
		if c.name == sub {
			return true
		}
	}
	// Hidden subcommands consumed by sandbox.sh itself, not listed in usage.
	switch sub {
	case "secret",
		"_analyze",
		"_onboard-status",
		"_onboard-check",
		"_resolve-latest",
		"_semver-lt",
		"_render-args",
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
