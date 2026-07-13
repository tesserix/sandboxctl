package envscan

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/tesserix/sandboxctl/cli/internal/reposcan"
)

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

func attach(t *testing.T, root string, apps []reposcan.App) *reposcan.Model {
	t.Helper()
	m := &reposcan.Model{Root: root, Apps: apps}
	Attach(m)
	return m
}

func refByName(t *testing.T, app reposcan.App, name string) reposcan.EnvRef {
	t.Helper()
	for _, r := range app.Env {
		if r.Name == name {
			return r
		}
	}
	t.Fatalf("app %s has no env ref %q (have %v)", app.Name, name, app.Env)
	return reposcan.EnvRef{}
}

func TestScanSourcesAndClassification(t *testing.T) {
	root := writeTree(t, map[string]string{
		"apps/api/main.go": `package main
import "os"
func main() {
	_ = os.Getenv("DATABASE_URL")
	_, _ = os.LookupEnv("STRIPE_API_KEY")
	_ = os.Getenv("LOG_LEVEL")
	_ = os.Getenv("PATH") // ambient noise — never reported
}`,
		"apps/web/server.ts": `const url = process.env.API_URL;
const s = process.env["SESSION_SECRET"];
const v = import.meta.env.VITE_FLAG;`,
		"apps/etl/job.py": `import os
dsn = os.environ.get("PG_DSN")
mode = os.getenv("RUN_MODE")
tok = os.environ["SLACK_TOKEN"]`,
		"apps/api/.env.example": "FEATURE_FLAG=off\nJWT_SIGNING_SECRET=change-me\n",
		"apps/api/Dockerfile":   "FROM golang:1.25\nENV GIN_MODE=release\nEXPOSE 8080\n",
	})
	apps := []reposcan.App{
		{Name: "api", Path: "apps/api"},
		{Name: "web", Path: "apps/web"},
		{Name: "etl", Path: "apps/etl"},
	}
	m := attach(t, root, apps)

	api, web, etl := m.Apps[0], m.Apps[1], m.Apps[2]

	// Classification matrix.
	cases := []struct {
		app    reposcan.App
		name   string
		secret bool
		source string
	}{
		{api, "DATABASE_URL", true, "go"},   // connection string
		{api, "STRIPE_API_KEY", true, "go"}, // API_KEY
		{api, "LOG_LEVEL", false, "go"},     // plain config
		{api, "JWT_SIGNING_SECRET", true, "dotenv"},
		{api, "FEATURE_FLAG", false, "dotenv"},
		{api, "GIN_MODE", false, "dockerfile"},
		{web, "API_URL", false, "js"}, // URL without conn-string prefix
		{web, "SESSION_SECRET", true, "js"},
		{web, "VITE_FLAG", false, "js"},
		{etl, "PG_DSN", true, "python"},
		{etl, "SLACK_TOKEN", true, "python"},
		{etl, "RUN_MODE", false, "python"},
	}
	for _, c := range cases {
		ref := refByName(t, c.app, c.name)
		if ref.Secret != c.secret || ref.Source != c.source {
			t.Errorf("%s/%s: secret=%v source=%q, want secret=%v source=%q",
				c.app.Name, c.name, ref.Secret, ref.Source, c.secret, c.source)
		}
	}

	// Noise never appears.
	for _, r := range api.Env {
		if r.Name == "PATH" {
			t.Fatal("ambient PATH reported")
		}
	}

	// Provenance points at the first reference.
	if ref := refByName(t, api, "DATABASE_URL"); ref.Location != "apps/api/main.go:4" {
		t.Fatalf("DATABASE_URL location = %q", ref.Location)
	}
}

func TestComposeEnvAttributionByServiceName(t *testing.T) {
	root := writeTree(t, map[string]string{
		"docker-compose.yml": `
services:
  api:
    build: ./api
    environment:
      REDIS_URL: redis://cache:6379
      DEBUG: "1"
  db:
    image: postgres:16
    environment:
      - POSTGRES_PASSWORD=dev
`,
		"api/main.go": "package main\nfunc main() {}\n",
	})
	m := attach(t, root, []reposcan.App{{Name: "api", Path: "api"}})

	api := m.Apps[0]
	if ref := refByName(t, api, "REDIS_URL"); !ref.Secret || ref.Source != "compose" {
		t.Fatalf("REDIS_URL: %+v", ref)
	}
	if ref := refByName(t, api, "DEBUG"); ref.Secret {
		t.Fatalf("DEBUG classified secret")
	}
	// db is not an app — POSTGRES_PASSWORD must not leak onto api.
	for _, r := range api.Env {
		if r.Name == "POSTGRES_PASSWORD" {
			t.Fatal("db service env attributed to api")
		}
	}
}

func TestOverridesBeatHeuristics(t *testing.T) {
	root := writeTree(t, map[string]string{
		"sandboxctl.yaml": "secrets:\n  include: [PLAIN_LOOKING]\n  exclude: [NATS_URL]\n",
		"main.go": `package main
import "os"
func main() {
	_ = os.Getenv("PLAIN_LOOKING")
	_ = os.Getenv("NATS_URL")
}`,
	})
	m := attach(t, root, []reposcan.App{{Name: "shop", Path: "."}})

	if ref := refByName(t, m.Apps[0], "PLAIN_LOOKING"); !ref.Secret {
		t.Fatal("include override ignored")
	}
	if ref := refByName(t, m.Apps[0], "NATS_URL"); ref.Secret {
		t.Fatal("exclude override ignored")
	}
}

func TestLibraryRefsOutsideAppsAreDropped(t *testing.T) {
	root := writeTree(t, map[string]string{
		"packages/shared/util.ts": `export const k = process.env.SHARED_ONLY_VAR;`,
		"apps/web/index.ts":       `const a = process.env.WEB_VAR;`,
	})
	m := attach(t, root, []reposcan.App{{Name: "web", Path: "apps/web"}})

	web := m.Apps[0]
	if len(web.Env) != 1 || web.Env[0].Name != "WEB_VAR" {
		t.Fatalf("attribution wrong: %v", web.Env)
	}
}

func TestRootAppCatchesEverythingAndDedupes(t *testing.T) {
	root := writeTree(t, map[string]string{
		"a.go": "package a\nimport \"os\"\nvar _ = os.Getenv(\"DUP_VAR\")\n",
		"b.go": "package a\nimport \"os\"\nvar _ = os.Getenv(\"DUP_VAR\")\n",
	})
	m := attach(t, root, []reposcan.App{{Name: "shop", Path: "."}})
	if len(m.Apps[0].Env) != 1 {
		t.Fatalf("dedupe failed: %v", m.Apps[0].Env)
	}
	if loc := m.Apps[0].Env[0].Location; loc != "a.go:3" {
		t.Fatalf("first-seen location = %q", loc)
	}
}

func TestNeverReadsRealDotenv(t *testing.T) {
	root := writeTree(t, map[string]string{
		".env":         "REAL_SECRET=oops\n",
		".env.example": "TEMPLATED_KEY=\n",
	})
	m := attach(t, root, []reposcan.App{{Name: "shop", Path: "."}})
	for _, r := range m.Apps[0].Env {
		if r.Name == "REAL_SECRET" {
			t.Fatal(".env was read — it must never be")
		}
	}
	// .env.example keys are fine (keys only, no values captured).
	found := false
	for _, r := range m.Apps[0].Env {
		if r.Name == "TEMPLATED_KEY" {
			found = true
		}
	}
	if !found {
		t.Fatal(".env.example keys not collected")
	}
}
