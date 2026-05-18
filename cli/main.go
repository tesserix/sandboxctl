package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
)

// assetDir is injected at build time via:
//   go build -ldflags "-X main.assetDir=/abs/path/to/sandboxctl"
// It points at the directory containing sandbox.sh + manifests/.
var assetDir = ""

type command struct{ name, desc string }

var commands = []command{
	{"setup-podman", "install/configure rootful podman machine (one-time)"},
	{"trust-ca", "trust the sandbox root CA in macOS System keychain (sudo)"},
	{"untrust-ca", "remove the sandbox root CA from System keychain (sudo)"},
	{"up", "create cluster + install argocd/kargo/demo + ingress + PKI + hosts + portfwd"},
	{"down", "remove cluster + LaunchAgent + /etc/hosts + keychain CA (keeps ~/.sandbox)"},
	{"purge", "down + remove ~/.sandbox (prompts for confirmation)"},
	{"status", "cluster + workload status + URLs"},
	{"restart", "down + up"},
	{"validate", "curl each URL from the Mac and print HTTP codes"},
	{"creds", "print login details (URLs + admin creds) for Argo CD + Kargo"},
	{"argocd-ui", "print Argo CD URL + admin creds"},
	{"kargo-ui", "print Kargo  URL + admin creds"},
	{"tui", "live status dashboard (Bubble Tea)"},
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
	return false
}

func scriptPath() string { return filepath.Join(assetDir, "sandbox.sh") }

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
	}
	if !known(sub) {
		fmt.Fprintf(os.Stderr, "unknown subcommand: %s\n\n%s", sub, usage())
		os.Exit(2)
	}
	if assetDir == "" {
		fmt.Fprintln(os.Stderr, "sandboxctl was built without assetDir; rebuild via ./install.sh")
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
