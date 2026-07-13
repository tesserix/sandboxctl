package reposcan

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// writeTree materializes a fixture repo under a stable directory name
// ("shop") so app names derived from the root basename are predictable.
func writeTree(t *testing.T, files map[string]string) string {
	t.Helper()
	root := filepath.Join(t.TempDir(), "shop")
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatal(err)
	}
	for rel, content := range files {
		p := filepath.Join(root, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

func mustScan(t *testing.T, root string) *Model {
	t.Helper()
	m, err := Scan(root)
	if err != nil {
		t.Fatalf("Scan: %v", err)
	}
	if m.Version != ModelVersion {
		t.Fatalf("model version = %d, want %d", m.Version, ModelVersion)
	}
	return m
}

func findApp(t *testing.T, m *Model, path string) *App {
	t.Helper()
	for i := range m.Apps {
		if m.Apps[i].Path == path {
			return &m.Apps[i]
		}
	}
	t.Fatalf("no app at path %q (have %v)", path, appPaths(m))
	return nil
}

func appPaths(m *Model) []string {
	var out []string
	for _, a := range m.Apps {
		out = append(out, a.Path)
	}
	return out
}

func hasReason(a *App, substr string) bool {
	for _, r := range a.Reasons {
		if strings.Contains(r, substr) {
			return true
		}
	}
	return false
}

// ----------------------------------------------------------------------------
// required fixture shapes (issue acceptance list)
// ----------------------------------------------------------------------------

func TestScanSingleGoApp(t *testing.T) {
	root := writeTree(t, map[string]string{
		"go.mod":     "module example.com/shop\n\ngo 1.25\n\nrequire github.com/gin-gonic/gin v1.10.0\n",
		"main.go":    "package main\nfunc main() {}\n",
		"Dockerfile": "FROM golang:1.25\nEXPOSE 8080\n",
	})
	m := mustScan(t, root)

	if m.Layout != "single-app" || m.Workspace != "" {
		t.Fatalf("layout=%q workspace=%q, want single-app with no workspace", m.Layout, m.Workspace)
	}
	if len(m.Apps) != 1 {
		t.Fatalf("apps = %v, want exactly one", appPaths(m))
	}
	a := findApp(t, m, ".")
	if a.Name != "shop" || a.Language != "go" || a.Framework != "gin" {
		t.Fatalf("got name=%q lang=%q fw=%q", a.Name, a.Language, a.Framework)
	}
	if a.Port != 8080 || a.Kind != "http" || a.Dockerfile != "Dockerfile" {
		t.Fatalf("got port=%d kind=%q dockerfile=%q", a.Port, a.Kind, a.Dockerfile)
	}
	if !hasReason(a, "EXPOSE 8080") {
		t.Fatalf("missing EXPOSE reason: %v", a.Reasons)
	}
}

func TestScanSingleNodeApp(t *testing.T) {
	root := writeTree(t, map[string]string{
		"package.json": `{"name":"shop","dependencies":{"express":"^4.19.0"}}`,
	})
	m := mustScan(t, root)

	a := findApp(t, m, ".")
	if a.Language != "js" || a.Framework != "express" {
		t.Fatalf("got lang=%q fw=%q", a.Language, a.Framework)
	}
	if a.Port != 3000 || a.Kind != "http" {
		t.Fatalf("got port=%d kind=%q, want framework default 3000/http", a.Port, a.Kind)
	}
	if !hasReason(a, "framework default port 3000") {
		t.Fatalf("missing framework-default reason: %v", a.Reasons)
	}
}

func TestScanPnpmMonorepo(t *testing.T) {
	root := writeTree(t, map[string]string{
		"pnpm-workspace.yaml":      "packages:\n  - apps/*\n  - packages/*\n",
		"package.json":             `{"name":"shop","private":true}`,
		"apps/web/package.json":    `{"name":"web","dependencies":{"next":"15.0.0"}}`,
		"apps/web/Dockerfile":      "FROM node:22\nEXPOSE 3000\n",
		"apps/api/package.json":    `{"name":"api","dependencies":{"express":"^4.19.0"}}`,
		"apps/api/tsconfig.json":   `{}`,
		"apps/api/Dockerfile":      "FROM node:22\nEXPOSE 8080\n",
		"packages/ui/package.json": `{"name":"@shop/ui","dependencies":{"react":"^19.0.0"}}`,
	})
	m := mustScan(t, root)

	if m.Layout != "monorepo" || m.Workspace != "pnpm" {
		t.Fatalf("layout=%q workspace=%q, want monorepo/pnpm", m.Layout, m.Workspace)
	}
	if len(m.Apps) != 2 {
		t.Fatalf("apps = %v, want web + api only (packages/ui is a library)", appPaths(m))
	}

	api := findApp(t, m, "apps/api")
	if api.Language != "ts" || api.Framework != "express" {
		t.Fatalf("api: lang=%q fw=%q", api.Language, api.Framework)
	}
	// EXPOSE beats the express framework default.
	if api.Port != 8080 {
		t.Fatalf("api port = %d, want 8080 (EXPOSE beats framework default)", api.Port)
	}

	web := findApp(t, m, "apps/web")
	if web.Framework != "next" || web.Kind != "http" || web.Port != 3000 {
		t.Fatalf("web: fw=%q kind=%q port=%d", web.Framework, web.Kind, web.Port)
	}
}

func TestScanGoWorkMonorepo(t *testing.T) {
	root := writeTree(t, map[string]string{
		"go.work":          "go 1.25\n\nuse (\n\t./svc-a\n\t./svc-b\n)\n",
		"svc-a/go.mod":     "module example.com/svc-a\n",
		"svc-a/Dockerfile": "FROM golang:1.25\nEXPOSE 9000\n",
		"svc-b/go.mod":     "module example.com/svc-b\n",
	})
	m := mustScan(t, root)

	if m.Layout != "monorepo" || m.Workspace != "go.work" {
		t.Fatalf("layout=%q workspace=%q, want monorepo/go.work", m.Layout, m.Workspace)
	}
	a := findApp(t, m, "svc-a")
	if a.Port != 9000 || a.Kind != "http" {
		t.Fatalf("svc-a: port=%d kind=%q", a.Port, a.Kind)
	}
	b := findApp(t, m, "svc-b")
	if b.Kind != "worker" || b.Port != 0 {
		t.Fatalf("svc-b: kind=%q port=%d, want worker with no port", b.Kind, b.Port)
	}
}

func TestScanComposeOnlyRepo(t *testing.T) {
	root := writeTree(t, map[string]string{
		"docker-compose.yml": `
services:
  api:
    build: ./api
    ports: ["8080:8080"]
  web:
    build:
      context: ./web
    ports: ["3000:80"]
  db:
    image: postgres:16
`,
		"api/requirements.txt": "fastapi\nuvicorn\n",
		"api/Dockerfile":       "FROM python:3.13\nEXPOSE 9999\n",
		"web/package.json":     `{"name":"web","dependencies":{"react":"19.0.0","vite":"6.0.0"}}`,
		"web/Dockerfile":       "FROM nginx:alpine\n",
	})
	m := mustScan(t, root)

	if m.Layout != "monorepo" || m.Workspace != "compose" {
		t.Fatalf("layout=%q workspace=%q, want monorepo/compose", m.Layout, m.Workspace)
	}
	if len(m.Apps) != 2 {
		t.Fatalf("apps = %v, want api + web (db is image-only)", appPaths(m))
	}

	api := findApp(t, m, "api")
	// compose's published container port beats the Dockerfile EXPOSE.
	if api.Port != 8080 {
		t.Fatalf("api port = %d, want 8080 (compose beats EXPOSE)", api.Port)
	}
	if api.Language != "python" || api.Framework != "fastapi" {
		t.Fatalf("api: lang=%q fw=%q", api.Language, api.Framework)
	}

	web := findApp(t, m, "web")
	if web.Port != 80 {
		t.Fatalf("web port = %d, want container side of 3000:80", web.Port)
	}
	if web.Kind != "frontend" {
		t.Fatalf("web kind = %q, want frontend (react+vite)", web.Kind)
	}
}

func TestScanRepoWithExistingChart(t *testing.T) {
	root := writeTree(t, map[string]string{
		"go.mod":               "module example.com/shop\n",
		"Dockerfile":           "FROM golang:1.25\nEXPOSE 8080\n",
		"k8s/chart/Chart.yaml": "apiVersion: v2\nname: shop\nversion: 0.1.0\n",
	})
	m := mustScan(t, root)

	a := findApp(t, m, ".")
	if a.Existing.Chart != "k8s/chart" {
		t.Fatalf("existing chart = %q, want k8s/chart", a.Existing.Chart)
	}
	if !hasReason(a, "existing chart at k8s/chart") {
		t.Fatalf("missing existing-chart reason: %v", a.Reasons)
	}
}

func TestScanOverrides(t *testing.T) {
	root := writeTree(t, map[string]string{
		"go.mod":     "module example.com/shop\n",
		"Dockerfile": "FROM golang:1.25\nEXPOSE 8080\n",
		"sandboxctl.yaml": `
apps:
  - path: .
    port: 9090
  - path: tools/migrator
    name: migrator
    kind: worker
  - name: ghost
    port: 1234
  - path: .
    flavour: spicy
`,
	})
	m := mustScan(t, root)

	a := findApp(t, m, ".")
	if a.Port != 9090 {
		t.Fatalf("port = %d, want 9090 (override beats EXPOSE)", a.Port)
	}
	if !hasReason(a, "overridden in sandboxctl.yaml") {
		t.Fatalf("missing override reason: %v", a.Reasons)
	}

	mg := findApp(t, m, "tools/migrator")
	if mg.Name != "migrator" || mg.Kind != "worker" {
		t.Fatalf("migrator: name=%q kind=%q", mg.Name, mg.Kind)
	}

	var ghostWarn, unknownWarn bool
	for _, w := range m.Warnings {
		if strings.Contains(w, `"ghost"`) {
			ghostWarn = true
		}
		if strings.Contains(w, `unknown field "flavour"`) {
			unknownWarn = true
		}
	}
	if !ghostWarn || !unknownWarn {
		t.Fatalf("expected ghost + unknown-field warnings, got %v", m.Warnings)
	}
}

func TestScanDisjointDockerfiles(t *testing.T) {
	root := writeTree(t, map[string]string{
		"alpha/Dockerfile": "FROM alpine\n",
		"beta/Dockerfile":  "FROM alpine\nEXPOSE 8000\n",
	})
	m := mustScan(t, root)

	if m.Layout != "monorepo" || m.Workspace != "dockerfiles" {
		t.Fatalf("layout=%q workspace=%q, want monorepo/dockerfiles", m.Layout, m.Workspace)
	}
	if len(m.Apps) != 2 {
		t.Fatalf("apps = %v, want alpha + beta", appPaths(m))
	}
	if b := findApp(t, m, "beta"); b.Port != 8000 || b.Kind != "http" {
		t.Fatalf("beta: port=%d kind=%q", b.Port, b.Kind)
	}
	if a := findApp(t, m, "alpha"); a.Kind != "worker" {
		t.Fatalf("alpha kind = %q, want worker (no port)", a.Kind)
	}
}

func TestScanComposeRootContextInMonorepo(t *testing.T) {
	// Monorepos routinely build with `context: .` and a Dockerfile inside
	// the app dir; the repo root must not be promoted to an app.
	root := writeTree(t, map[string]string{
		"pnpm-workspace.yaml":     "packages:\n  - apps/*\n",
		"package.json":            `{"name":"shop","private":true}`,
		"apps/shell/package.json": `{"name":"shell","dependencies":{"next":"15.0.0"}}`,
		"apps/shell/Dockerfile":   "FROM node:22\n",
		"docker-compose.yml": `
services:
  shell:
    build:
      context: .
      dockerfile: apps/shell/Dockerfile
    ports: ["3100:3000"]
`,
	})
	m := mustScan(t, root)

	if len(m.Apps) != 1 {
		t.Fatalf("apps = %v, want only apps/shell (no root app)", appPaths(m))
	}
	shell := findApp(t, m, "apps/shell")
	if shell.Port != 3000 {
		t.Fatalf("shell port = %d, want 3000 from compose (Dockerfile has no EXPOSE)", shell.Port)
	}
	if !hasReason(shell, `compose service "shell"`) {
		t.Fatalf("missing compose reason: %v", shell.Reasons)
	}
}

func TestScanGoLibraryRepoIsNotAnApp(t *testing.T) {
	root := writeTree(t, map[string]string{
		"go.mod":         "module example.com/shared\n\nrequire github.com/gin-gonic/gin v1.10.0\n",
		"auth/auth.go":   "package auth\n",
		"cache/cache.go": "package cache\n",
	})
	m := mustScan(t, root)

	if len(m.Apps) != 0 {
		t.Fatalf("apps = %v, want none for a Go library repo", appPaths(m))
	}
	var warned bool
	for _, w := range m.Warnings {
		if strings.Contains(w, "no main-package indicator") {
			warned = true
		}
	}
	if !warned {
		t.Fatalf("expected library-repo warning, got %v", m.Warnings)
	}
}

func TestScanEmptyRepo(t *testing.T) {
	root := writeTree(t, map[string]string{"README.md": "hello\n"})
	m := mustScan(t, root)
	if len(m.Apps) != 0 {
		t.Fatalf("apps = %v, want none", appPaths(m))
	}
	if len(m.Warnings) == 0 {
		t.Fatal("expected a no-apps warning")
	}
}

// ----------------------------------------------------------------------------
// focused unit tests
// ----------------------------------------------------------------------------

func TestComposeContainerPortForms(t *testing.T) {
	cases := []struct {
		in   []any
		want int
	}{
		{[]any{"8080:80"}, 80},
		{[]any{"127.0.0.1:8080:80"}, 80},
		{[]any{"8080:80/tcp"}, 80},
		{[]any{"9000"}, 9000},
		{[]any{9000}, 9000},
		{[]any{map[string]any{"target": 8443}}, 8443},
		{[]any{map[string]any{"target": "8443"}}, 8443},
		{[]any{}, 0},
		{[]any{"$PORT:80x"}, 0},
	}
	for _, c := range cases {
		if got := composeContainerPort(c.in); got != c.want {
			t.Errorf("composeContainerPort(%v) = %d, want %d", c.in, got, c.want)
		}
	}
}

func TestGoWorkUsesForms(t *testing.T) {
	single := "go 1.25\nuse ./svc\n"
	if got := goWorkUses([]byte(single)); len(got) != 1 || got[0] != "svc" {
		t.Fatalf("single-line use = %v", got)
	}
	block := "go 1.25\nuse (\n\t./a\n\t\"./b\"\n\t// comment\n)\n"
	got := goWorkUses([]byte(block))
	if len(got) != 2 || got[0] != "a" || got[1] != "b" {
		t.Fatalf("block use = %v", got)
	}
}

func TestGlobMatch(t *testing.T) {
	cases := []struct {
		pat, dir string
		want     bool
	}{
		{"apps/*", "apps/api", true},
		{"apps/*", "apps/api/sub", false},
		{"apps/**", "apps/api/sub", true},
		{"apps/**", "apps", true},
		{"tools", "tools", true},
		{"apps/*", "packages/x", false},
	}
	for _, c := range cases {
		if got := globMatch(c.pat, c.dir); got != c.want {
			t.Errorf("globMatch(%q, %q) = %v, want %v", c.pat, c.dir, got, c.want)
		}
	}
}

func TestCargoMembers(t *testing.T) {
	toml := "[workspace]\nmembers = [\"crates/api\", 'crates/worker']\n"
	got := cargoMembers([]byte(toml))
	if len(got) != 2 || got[0] != "crates/api" || got[1] != "crates/worker" {
		t.Fatalf("cargoMembers = %v", got)
	}
}

func TestDedupeNames(t *testing.T) {
	apps := []App{{Name: "api", Path: "a/api"}, {Name: "api", Path: "b/api"}}
	dedupeNames(apps)
	if apps[0].Name != "api" || apps[1].Name != "api-2" {
		t.Fatalf("dedupe = %q, %q", apps[0].Name, apps[1].Name)
	}
}

func TestSlugify(t *testing.T) {
	if got := slugify("My Cool_App!"); got != "my-cool-app" {
		t.Fatalf("slugify = %q", got)
	}
}
