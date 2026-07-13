package chartgen

import (
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/tesserix/sandboxctl/cli/internal/genwrite"
	"github.com/tesserix/sandboxctl/cli/internal/reposcan"
)

func httpApp() reposcan.App {
	return reposcan.App{
		Name: "api", Path: "apps/api", Language: "go", Framework: "gin",
		Dockerfile: "apps/api/Dockerfile", Port: 8080, Kind: "http",
	}
}

func workerApp() reposcan.App {
	return reposcan.App{
		Name: "jobs", Path: "apps/jobs", Language: "go",
		Dockerfile: "apps/jobs/Dockerfile", Kind: "worker",
	}
}

func opByPath(t *testing.T, ops []genwrite.Op, path string) genwrite.Op {
	t.Helper()
	for _, op := range ops {
		if op.Path == path {
			return op
		}
	}
	t.Fatalf("no op for %s (have %v)", path, opPaths(ops))
	return genwrite.Op{}
}

func opPaths(ops []genwrite.Op) []string {
	var out []string
	for _, op := range ops {
		out = append(out, op.Path)
	}
	return out
}

func TestSingleAppUsesRecommendedLayout(t *testing.T) {
	app := httpApp()
	app.Path = "."
	res := Ops(&reposcan.Model{Apps: []reposcan.App{app}}, "")

	if len(res.Ops) != 7 {
		t.Fatalf("ops = %v, want 7 chart files", opPaths(res.Ops))
	}
	if res.ChartDirs["api"] != "k8s/chart" {
		t.Fatalf("chart dir = %q, want k8s/chart for single-app", res.ChartDirs["api"])
	}

	values := string(opByPath(t, res.Ops, "k8s/chart/values.yaml").Body)
	for _, want := range []string{"repository: localhost:5050/api", "port: 8080", "enabled: false"} {
		if !strings.Contains(values, want) {
			t.Fatalf("values.yaml missing %q:\n%s", want, values)
		}
	}

	chart := string(opByPath(t, res.Ops, "k8s/chart/Chart.yaml").Body)
	if !strings.Contains(chart, "name: api") {
		t.Fatalf("Chart.yaml wrong:\n%s", chart)
	}

	helpers := string(opByPath(t, res.Ops, "k8s/chart/templates/_helpers.tpl").Body)
	if !strings.Contains(helpers, `define "api.fullname"`) {
		t.Fatalf("helpers not chart-scoped:\n%s", helpers)
	}
}

func TestMonorepoUsesPerAppChartDirs(t *testing.T) {
	res := Ops(&reposcan.Model{Apps: []reposcan.App{httpApp(), workerApp()}}, "")
	if res.ChartDirs["api"] != "k8s/charts/api" || res.ChartDirs["jobs"] != "k8s/charts/jobs" {
		t.Fatalf("chart dirs = %v", res.ChartDirs)
	}
	if len(res.Ops) != 14 {
		t.Fatalf("ops = %d, want 7 per app", len(res.Ops))
	}
}

func TestWorkerChartHasNoServiceBlock(t *testing.T) {
	res := Ops(&reposcan.Model{Apps: []reposcan.App{httpApp(), workerApp()}}, "")
	values := string(opByPath(t, res.Ops, "k8s/charts/jobs/values.yaml").Body)
	if strings.Contains(values, "service:") {
		t.Fatalf("worker values.yaml has a service block:\n%s", values)
	}
}

func TestSkipsExistingChartAndDockerlessApps(t *testing.T) {
	covered := httpApp()
	covered.Existing.Chart = "k8s/chart"
	dockerless := reposcan.App{Name: "mobile", Path: "apps/mobile", Language: "ts", Kind: "frontend"}

	res := Ops(&reposcan.Model{Apps: []reposcan.App{covered, dockerless}}, "")
	if len(res.Ops) != 0 {
		t.Fatalf("expected no ops, got %v", opPaths(res.Ops))
	}
	if len(res.Skips) != 2 {
		t.Fatalf("skips = %v", res.Skips)
	}
	if !strings.Contains(res.Skips[0].Reason, "chart already exists") ||
		!strings.Contains(res.Skips[1].Reason, "no Dockerfile") {
		t.Fatalf("skip reasons wrong: %v", res.Skips)
	}
}

func TestRegistryOverride(t *testing.T) {
	res := Ops(&reposcan.Model{Apps: []reposcan.App{httpApp(), workerApp()}}, "localhost:6060")
	values := string(opByPath(t, res.Ops, "k8s/charts/api/values.yaml").Body)
	if !strings.Contains(values, "repository: localhost:6060/api") {
		t.Fatalf("registry override ignored:\n%s", values)
	}
}

// TestHelmLintAndTemplate materializes the generated charts and runs the
// real helm binary over them — lint must pass, the http chart must
// render a Service, the worker chart must not. Skips when helm isn't
// installed (it is on the GitHub ubuntu runners and dev machines).
func TestHelmLintAndTemplate(t *testing.T) {
	helm, err := exec.LookPath("helm")
	if err != nil {
		t.Skip("helm not installed")
	}

	root := t.TempDir()
	res := Ops(&reposcan.Model{Apps: []reposcan.App{httpApp(), workerApp()}}, "")
	plan, err := genwrite.BuildPlan(root, res.Ops)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := genwrite.Apply(plan, genwrite.Options{}); err != nil {
		t.Fatal(err)
	}

	for app, dir := range res.ChartDirs {
		chartPath := filepath.Join(root, filepath.FromSlash(dir))

		lint := exec.Command(helm, "lint", chartPath)
		if out, err := lint.CombinedOutput(); err != nil {
			t.Fatalf("helm lint %s failed:\n%s", app, out)
		}

		tpl := exec.Command(helm, "template", app, chartPath)
		out, err := tpl.CombinedOutput()
		if err != nil {
			t.Fatalf("helm template %s failed:\n%s", app, out)
		}
		rendered := string(out)
		if !strings.Contains(rendered, "kind: Deployment") {
			t.Fatalf("%s: no Deployment rendered:\n%s", app, rendered)
		}
		hasService := strings.Contains(rendered, "kind: Service\n") ||
			strings.Contains(rendered, "kind: Service\r\n")
		switch app {
		case "api":
			if !hasService {
				t.Fatalf("api chart rendered no Service:\n%s", rendered)
			}
			if !strings.Contains(rendered, "containerPort: 8080") {
				t.Fatalf("api chart missing containerPort:\n%s", rendered)
			}
		case "jobs":
			if hasService {
				t.Fatalf("worker chart rendered a Service:\n%s", rendered)
			}
		}
	}
}
