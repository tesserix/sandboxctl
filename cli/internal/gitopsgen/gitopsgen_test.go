package gitopsgen

import (
	"strings"
	"testing"

	"gopkg.in/yaml.v3"

	"github.com/tesserix/sandboxctl/cli/internal/genwrite"
	"github.com/tesserix/sandboxctl/cli/internal/reposcan"
)

func model(apps ...reposcan.App) *reposcan.Model {
	return &reposcan.Model{Apps: apps}
}

func opByPath(t *testing.T, ops []genwrite.Op, p string) genwrite.Op {
	t.Helper()
	for _, op := range ops {
		if op.Path == p {
			return op
		}
	}
	var have []string
	for _, op := range ops {
		have = append(have, op.Path)
	}
	t.Fatalf("no op for %s (have %v)", p, have)
	return genwrite.Op{}
}

// everyDocParses asserts each YAML document in the body is well-formed —
// Kargo's ${{ … }} expressions must survive as plain strings.
func everyDocParses(t *testing.T, body []byte) int {
	t.Helper()
	docs := 0
	for _, doc := range strings.Split(string(body), "\n---\n") {
		var v map[string]any
		if err := yaml.Unmarshal([]byte(doc), &v); err != nil {
			t.Fatalf("document does not parse: %v\n%s", err, doc)
		}
		if len(v) > 0 {
			docs++
		}
	}
	return docs
}

func TestOpsGeneratesFullPipeline(t *testing.T) {
	app := reposcan.App{Name: "api", Path: "apps/api", Dockerfile: "apps/api/Dockerfile"}
	res := Ops(model(app), Config{}, map[string]string{"api": "k8s/charts/api"})

	if len(res.Skips) != 0 {
		t.Fatalf("unexpected skips: %v", res.Skips)
	}
	if len(res.Ops) != 5 {
		t.Fatalf("ops = %d, want 5 files", len(res.Ops))
	}

	wh := opByPath(t, res.Ops, "k8s/gitops/api/warehouse.yaml")
	for _, want := range []string{
		"repoURL: registry.sandboxctl-registry.svc.cluster.local:5000/api",
		"imageSelectionStrategy: Digest",
		"constraint: latest",
		"insecureSkipTLSVerify: true",
		"namespace: api-kargo",
	} {
		if !strings.Contains(string(wh.Body), want) {
			t.Fatalf("warehouse missing %q:\n%s", want, wh.Body)
		}
	}
	everyDocParses(t, wh.Body)

	stages := opByPath(t, res.Ops, "k8s/gitops/api/stages.yaml")
	if n := everyDocParses(t, stages.Body); n != 2 {
		t.Fatalf("stages docs = %d, want dev + staging", n)
	}
	body := string(stages.Body)
	for _, want := range []string{
		"http://gitea-http.gitea.svc.cluster.local:3000/apps/api-chart.git",
		"path: ./repo/values-sandbox.yaml",
		"path: ./repo/values-staging.yaml",
		"key: image.digest",
		`${{ imageFrom("registry.sandboxctl-registry.svc.cluster.local:5000/api").Digest }}`,
		"name: api-staging",
		"direct: true",
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("stages missing %q", want)
		}
	}
	if !strings.Contains(body, "stages:\n          - dev") {
		t.Fatalf("staging must request freight from dev:\n%s", body)
	}

	apps := opByPath(t, res.Ops, "k8s/gitops/api/application.yaml")
	if n := everyDocParses(t, apps.Body); n != 2 {
		t.Fatalf("application docs = %d, want dev + staging", n)
	}
	abody := string(apps.Body)
	for _, want := range []string{
		`kargo.akuity.io/authorized-stage: "api-kargo:dev"`,
		`kargo.akuity.io/authorized-stage: "api-kargo:staging"`,
		`valueFiles: ["values-sandbox.yaml"]`,
		`valueFiles: ["values-staging.yaml"]`,
		"namespace: api-staging",
	} {
		if !strings.Contains(abody, want) {
			t.Fatalf("applications missing %q", want)
		}
	}

	staging := opByPath(t, res.Ops, "k8s/charts/api/values-staging.yaml")
	if !strings.Contains(string(staging.Body), `digest: ""`) {
		t.Fatalf("values-staging missing digest key:\n%s", staging.Body)
	}
}

func TestOpsSkips(t *testing.T) {
	existing := reposcan.App{Name: "a", Dockerfile: "a/Dockerfile",
		Existing: reposcan.Existing{GitOps: "k8s/gitops/a"}}
	noDocker := reposcan.App{Name: "b"}
	noChart := reposcan.App{Name: "c", Dockerfile: "c/Dockerfile"}

	res := Ops(model(existing, noDocker, noChart), Config{}, map[string]string{"a": "k8s/charts/a"})
	if len(res.Ops) != 0 || len(res.Skips) != 3 {
		t.Fatalf("ops=%d skips=%v", len(res.Ops), res.Skips)
	}
	for i, want := range []string{"already exist", "no Dockerfile", "no chart"} {
		if !strings.Contains(res.Skips[i].Reason, want) {
			t.Fatalf("skip[%d] = %q, want %q", i, res.Skips[i].Reason, want)
		}
	}
}

func TestConfigOverrides(t *testing.T) {
	app := reposcan.App{Name: "api", Dockerfile: "Dockerfile"}
	res := Ops(model(app), Config{
		RegistryHost: "registry.custom.svc:5000",
		GiteaHost:    "git.custom.svc:3000",
		Org:          "team",
	}, map[string]string{"api": "k8s/chart"})

	wh := string(opByPath(t, res.Ops, "k8s/gitops/api/warehouse.yaml").Body)
	if !strings.Contains(wh, "registry.custom.svc:5000/api") {
		t.Fatalf("registry override ignored:\n%s", wh)
	}
	st := string(opByPath(t, res.Ops, "k8s/gitops/api/stages.yaml").Body)
	if !strings.Contains(st, "http://git.custom.svc:3000/team/api-chart.git") {
		t.Fatalf("gitea override ignored:\n%s", st)
	}
}
