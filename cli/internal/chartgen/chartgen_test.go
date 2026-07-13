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
		Env: []reposcan.EnvRef{
			{Name: "DATABASE_URL", Location: "apps/api/main.go:4", Secret: true},
			{Name: "LOG_LEVEL", Location: "apps/api/main.go:6", Secret: false},
		},
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
	res := Ops(&reposcan.Model{Apps: []reposcan.App{app}}, Config{})

	if len(res.Ops) != 8 {
		t.Fatalf("ops = %v, want 8 chart files", opPaths(res.Ops))
	}
	if res.ChartDirs["api"] != "k8s/chart" {
		t.Fatalf("chart dir = %q, want k8s/chart for single-app", res.ChartDirs["api"])
	}

	values := string(opByPath(t, res.Ops, "k8s/chart/values.yaml").Body)
	for _, want := range []string{
		"repository: localhost:5050/api", "port: 8080", "enabled: false",
		"envFromSecret: api-secrets",         // secret refs wire envFrom
		"#   LOG_LEVEL (apps/api/main.go:6)", // config surfaced as comment
	} {
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
	res := Ops(&reposcan.Model{Apps: []reposcan.App{httpApp(), workerApp()}}, Config{})
	if res.ChartDirs["api"] != "k8s/charts/api" || res.ChartDirs["jobs"] != "k8s/charts/jobs" {
		t.Fatalf("chart dirs = %v", res.ChartDirs)
	}
	if len(res.Ops) != 16 {
		t.Fatalf("ops = %d, want 8 per app", len(res.Ops))
	}
}

func TestWorkerChartHasNoServiceBlock(t *testing.T) {
	res := Ops(&reposcan.Model{Apps: []reposcan.App{httpApp(), workerApp()}}, Config{})
	values := string(opByPath(t, res.Ops, "k8s/charts/jobs/values.yaml").Body)
	if strings.Contains(values, "service:") {
		t.Fatalf("worker values.yaml has a service block:\n%s", values)
	}
}

func TestSkipsExistingChartAndDockerlessApps(t *testing.T) {
	covered := httpApp()
	covered.Existing.Chart = "k8s/chart"
	dockerless := reposcan.App{Name: "mobile", Path: "apps/mobile", Language: "ts", Kind: "frontend"}

	res := Ops(&reposcan.Model{Apps: []reposcan.App{covered, dockerless}}, Config{})
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
	res := Ops(&reposcan.Model{Apps: []reposcan.App{httpApp(), workerApp()}}, Config{Registry: "localhost:6060"})
	values := string(opByPath(t, res.Ops, "k8s/charts/api/values.yaml").Body)
	if !strings.Contains(values, "repository: localhost:6060/api") {
		t.Fatalf("registry override ignored:\n%s", values)
	}
}

func TestSandboxValuesCarryVirtualService(t *testing.T) {
	res := Ops(&reposcan.Model{Apps: []reposcan.App{httpApp(), workerApp()}},
		Config{Domain: "sb.test", GatewayRef: "gw-ns/gw"})

	api := string(opByPath(t, res.Ops, "k8s/charts/api/values-sandbox.yaml").Body)
	for _, want := range []string{"enabled: true", "host: api.sb.test", "gateway: gw-ns/gw"} {
		if !strings.Contains(api, want) {
			t.Fatalf("api values-sandbox missing %q:\n%s", want, api)
		}
	}
	// Workers have no port → no VS block in their sandbox values.
	jobs := string(opByPath(t, res.Ops, "k8s/charts/jobs/values-sandbox.yaml").Body)
	if strings.Contains(jobs, "virtualService") {
		t.Fatalf("worker values-sandbox has a VS block:\n%s", jobs)
	}
	// Portable default: values.yaml ships the block disabled.
	vals := string(opByPath(t, res.Ops, "k8s/charts/api/values.yaml").Body)
	if !strings.Contains(vals, "enabled: false") || !strings.Contains(vals, "virtualService:") {
		t.Fatalf("values.yaml missing disabled VS default:\n%s", vals)
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
	res := Ops(&reposcan.Model{Apps: []reposcan.App{httpApp(), workerApp()}}, Config{})
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
		// Portable default: no VirtualService without the sandbox values.
		if strings.Contains(rendered, "kind: VirtualService") {
			t.Fatalf("%s: default render carries a VirtualService:\n%s", app, rendered)
		}

		// With the sandbox values, http charts route; workers still don't.
		sbx := exec.Command(helm, "template", app, chartPath, "-f", filepath.Join(chartPath, "values-sandbox.yaml"))
		sbxOut, err := sbx.CombinedOutput()
		if err != nil {
			t.Fatalf("helm template -f values-sandbox %s failed:\n%s", app, sbxOut)
		}
		sbxRendered := string(sbxOut)
		hasVS := strings.Contains(sbxRendered, "kind: VirtualService")
		if app == "api" {
			if !hasVS || !strings.Contains(sbxRendered, `"api.sandbox.app"`) {
				t.Fatalf("api sandbox render missing VirtualService/host:\n%s", sbxRendered)
			}
		}
		if app == "jobs" && hasVS {
			t.Fatalf("worker sandbox render carries a VirtualService:\n%s", sbxRendered)
		}
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
			if !strings.Contains(rendered, "name: api-secrets") {
				t.Fatalf("api chart missing envFrom secretRef:\n%s", rendered)
			}
		case "jobs":
			if hasService {
				t.Fatalf("worker chart rendered a Service:\n%s", rendered)
			}
			if strings.Contains(rendered, "envFrom") {
				t.Fatalf("secretless worker rendered envFrom:\n%s", rendered)
			}
		}
	}
}
