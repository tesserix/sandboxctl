package chartgen

import (
	"strings"
	"testing"

	"github.com/tesserix/sandboxctl/cli/internal/reposcan"
)

// The sandbox registry serves mutable tags; a cached node image must
// never shadow a fresh build. Every generated values surface (chart
// default, sandbox flavour, umbrella nesting) pins pullPolicy Always,
// and the deployment falls back to Always when values omit the key.
func TestGeneratedChartsPullAlways(t *testing.T) {
	m := &reposcan.Model{
		Root:   "/tmp/demo",
		Layout: "monorepo",
		Apps: []reposcan.App{
			{Name: "api", Path: "apps/api", Dockerfile: "apps/api/Dockerfile", Port: 8080, Kind: "http"},
			{Name: "web", Path: "apps/web", Dockerfile: "apps/web/Dockerfile", Port: 3000, Kind: "http"},
		},
	}
	res := Ops(m, Config{})
	byPath := map[string]string{}
	for _, op := range res.Ops {
		byPath[op.Path] = string(op.Body)
	}

	for path, want := range map[string]string{
		"k8s/charts/api/values.yaml":         "pullPolicy: Always",
		"k8s/charts/api/values-sandbox.yaml": "pullPolicy: Always",
		"k8s/chart/values-sandbox.yaml":      "pullPolicy: Always",
	} {
		body, ok := byPath[path]
		if !ok {
			t.Fatalf("%s not generated", path)
		}
		if !strings.Contains(body, want) {
			t.Fatalf("%s missing %q:\n%s", path, want, body)
		}
	}
	if dep := byPath["k8s/charts/api/templates/deployment.yaml"]; !strings.Contains(dep, `default "Always"`) {
		t.Fatalf("deployment must default pullPolicy to Always when values omit it:\n%s", dep)
	}
}
