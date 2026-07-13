package secretsgen

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/tesserix/sandboxctl/cli/internal/reposcan"
)

func apps() []reposcan.App {
	return []reposcan.App{
		{Name: "api", Path: "apps/api", Env: []reposcan.EnvRef{
			{Name: "DATABASE_URL", Location: "apps/api/main.go:4", Source: "go", Secret: true},
			{Name: "JWT_SIGNING_SECRET", Location: "apps/api/main.go:5", Source: "go", Secret: true},
			{Name: "LOG_LEVEL", Location: "apps/api/main.go:6", Source: "go", Secret: false},
		}},
		{Name: "web", Path: "apps/web", Env: []reposcan.EnvRef{
			{Name: "API_URL", Location: "apps/web/index.ts:1", Source: "js", Secret: false},
		}},
		{Name: "worker", Path: "apps/worker"},
	}
}

func TestOpsShape(t *testing.T) {
	root := t.TempDir()
	ops, skip := Ops(root, apps())
	if skip != nil {
		t.Fatalf("unexpected skip: %v", skip.Reason)
	}
	if len(ops) != 2 {
		t.Fatalf("ops = %d, want gitignore + example", len(ops))
	}

	// .gitignore comes first — the ignore rule must precede the invite
	// to create the real file.
	if ops[0].Path != ".gitignore" || len(ops[0].Append) != 2 {
		t.Fatalf("first op = %+v", ops[0])
	}
	if ops[1].Path != ExamplePath {
		t.Fatalf("second op path = %s", ops[1].Path)
	}

	body := string(ops[1].Body)
	for _, want := range []string{
		"name: api-secrets",
		`DATABASE_URL: "<required — referenced at apps/api/main.go:4>"`,
		`JWT_SIGNING_SECRET: "<required — referenced at apps/api/main.go:5>"`,
		"#   LOG_LEVEL (apps/api/main.go:6)", // config listed as comment only
		"stringData:",
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("template missing %q:\n%s", want, body)
		}
	}
	// Apps without secret refs get no Secret document.
	if strings.Contains(body, "web-secrets") || strings.Contains(body, "worker-secrets") {
		t.Fatalf("secretless apps got documents:\n%s", body)
	}
	// One document per secretful app.
	if strings.Count(body, "kind: Secret") != 1 {
		t.Fatalf("want exactly 1 Secret doc:\n%s", body)
	}
}

func TestSkipWhenNoSecrets(t *testing.T) {
	root := t.TempDir()
	_, skip := Ops(root, []reposcan.App{{Name: "web", Env: []reposcan.EnvRef{{Name: "API_URL"}}}})
	if skip == nil || !strings.Contains(skip.Reason, "no secret-like") {
		t.Fatalf("skip = %v", skip)
	}
}

func TestSkipWhenSecretsFilesExist(t *testing.T) {
	for _, existing := range []string{"k8s/secrets.yaml", ExamplePath} {
		root := t.TempDir()
		p := filepath.Join(root, filepath.FromSlash(existing))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte("theirs\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		ops, skip := Ops(root, apps())
		if ops != nil || skip == nil || !strings.Contains(skip.Reason, existing) {
			t.Fatalf("%s: ops=%v skip=%v", existing, ops, skip)
		}
	}
}
