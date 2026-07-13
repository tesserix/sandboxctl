package main

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/tesserix/sandboxctl/cli/internal/reposcan"
)

func writeFileT(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestResolveAppImages_ManifestNameMatch(t *testing.T) {
	root := t.TempDir()
	writeFileT(t, filepath.Join(root, "sandboxctl.yaml"), `
images:
  - name: agent-sim
    context: services/agent-sim
    tag: dev
  - name: gateway
    context: services/gateway
`)
	apps := []reposcan.App{
		{Name: "agent-sim", Path: "services/agent-sim", Dockerfile: "services/agent-sim/Dockerfile"},
		{Name: "gateway", Path: "services/gateway", Dockerfile: "services/gateway/Dockerfile"},
	}
	got := resolveAppImages(root, apps)
	if r := got["agent-sim"]; r.Name != "agent-sim" || r.Tag != "dev" {
		t.Fatalf("agent-sim → %+v, want agent-sim:dev", r)
	}
	if r := got["gateway"]; r.Name != "gateway" || r.Tag != "latest" {
		t.Fatalf("gateway → %+v, want gateway:latest", r)
	}
}

func TestResolveAppImages_DockerfileAndContextMatch(t *testing.T) {
	root := t.TempDir()
	// Image names that do NOT equal the app names — the exact failure
	// class: chart wants <app>:latest, build pushes something else.
	writeFileT(t, filepath.Join(root, "sandboxctl.yaml"), `
images:
  - name: obs-simulator
    context: services/agent-sim
  - name: obs-gateway
    context: .
    dockerfile: docker/gateway.Dockerfile
`)
	apps := []reposcan.App{
		{Name: "agent-sim", Path: "services/agent-sim", Dockerfile: "services/agent-sim/Dockerfile"},
		{Name: "gateway", Path: "services/gateway", Dockerfile: "docker/gateway.Dockerfile"},
	}
	got := resolveAppImages(root, apps)
	if r := got["agent-sim"]; r.Name != "obs-simulator" {
		t.Fatalf("agent-sim: context match failed, got %+v", r)
	}
	if r := got["gateway"]; r.Name != "obs-gateway" {
		t.Fatalf("gateway: dockerfile match failed, got %+v", r)
	}
}

func TestResolveAppImages_SoleAndAmbiguous(t *testing.T) {
	root := t.TempDir()
	writeFileT(t, filepath.Join(root, "sandboxctl.yaml"), `
images:
  - name: totally-different
    context: .
    tag: v2
`)
	sole := []reposcan.App{{Name: "myapp", Path: ".", Dockerfile: "Dockerfile"}}
	got := resolveAppImages(root, sole)
	if r := got["myapp"]; r.Name != "totally-different" || r.Tag != "v2" {
		t.Fatalf("sole-sole match failed: %+v", r)
	}

	// Two images sharing one context, neither named after the app, no
	// dockerfile signal → ambiguous → no mapping (fallback + warn).
	writeFileT(t, filepath.Join(root, "sandboxctl.yaml"), `
images:
  - name: alpha
    context: svc
    dockerfile: svc/a.Dockerfile
  - name: beta
    context: svc
    dockerfile: svc/b.Dockerfile
`)
	apps := []reposcan.App{{Name: "svc", Path: "svc", Dockerfile: "svc/Dockerfile"}}
	got = resolveAppImages(root, apps)
	if _, ok := got["svc"]; ok {
		t.Fatalf("ambiguous context must not resolve, got %+v", got["svc"])
	}
}

func TestResolveAppImages_AutogenFallback(t *testing.T) {
	root := t.TempDir()
	// No manifest: the autogen derivation names images after the
	// Dockerfile's dir — matching the app name by construction.
	writeFileT(t, filepath.Join(root, "apps/api/Dockerfile"), "FROM alpine\n")
	writeFileT(t, filepath.Join(root, "apps/api/main.go"), "package main\n")
	apps := []reposcan.App{{Name: "api", Path: "apps/api", Dockerfile: "apps/api/Dockerfile"}}
	got := resolveAppImages(root, apps)
	if r := got["api"]; r.Name != "api" || r.Tag != "latest" {
		t.Fatalf("autogen resolution failed: %+v", r)
	}
}

func TestResolveAppImages_ProjectPrefixedNames(t *testing.T) {
	// The live failure shape: registry/manifest names carry the repo
	// prefix (agent-observability-agent-sim) while apps/charts use the
	// bare dir name (agent-sim).
	parent := t.TempDir()
	root := filepath.Join(parent, "agent-observability")
	writeFileT(t, filepath.Join(root, "sandboxctl.yaml"), `
images:
  - name: agent-observability-agent-sim
  - name: agent-observability-api
  - name: agent-observability-ui
`)
	apps := []reposcan.App{
		{Name: "agent-sim", Path: "services/agent-sim", Dockerfile: "services/agent-sim/Dockerfile"},
		{Name: "api", Path: "services/api", Dockerfile: "services/api/Dockerfile"},
		{Name: "ui", Path: "ui", Dockerfile: "ui/Dockerfile"},
	}
	got := resolveAppImages(root, apps)
	for app, want := range map[string]string{
		"agent-sim": "agent-observability-agent-sim",
		"api":       "agent-observability-api",
		"ui":        "agent-observability-ui",
	} {
		if r := got[app]; r.Name != want || r.Tag != "latest" {
			t.Fatalf("%s → %+v, want %s:latest", app, r, want)
		}
	}
}
