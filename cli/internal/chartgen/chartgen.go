// Package chartgen turns a reposcan.Model into Helm charts. It is a
// pure function from model to genwrite ops: no filesystem reads, no
// cluster access — the safe-write engine decides what actually lands on
// disk, so existing charts and user edits are never at risk here.
package chartgen

import (
	"bytes"
	"fmt"
	"path"
	"text/template"

	"github.com/tesserix/sandboxctl/cli/internal/genwrite"
	"github.com/tesserix/sandboxctl/cli/internal/reposcan"
	"github.com/tesserix/sandboxctl/cli/internal/secretsgen"
)

// Generator is recorded in every file's ownership marker.
const Generator = "scaffold"

// registryHost is the push/pull coordinate of the in-cluster registry
// as seen from both the Mac and the kind node (containerd mirror).
// Kept overridable for tests and for a future SANDBOX_REGISTRY_PORT
// passthrough.
const defaultRegistry = "localhost:5050"

// Skip explains why an app gets no chart.
type Skip struct {
	App    string
	Reason string
}

// Result is the full generation outcome for a repo.
type Result struct {
	Ops   []genwrite.Op
	Skips []Skip
	// ChartDirs maps app name → repo-relative chart dir that was (or
	// would be) generated. Consumed by callers wiring deploy hints.
	ChartDirs map[string]string
}

// Ops plans one chart per eligible app. Eligibility: the app must have
// a Dockerfile (the chart references the image the build pushes) and no
// existing chart. Layout: k8s/chart for a single-app repo (the
// documented recommended layout), k8s/charts/<name> for monorepos.
func Ops(m *reposcan.Model, registry string) *Result {
	if registry == "" {
		registry = defaultRegistry
	}
	res := &Result{ChartDirs: map[string]string{}}

	single := len(m.Apps) == 1
	for _, app := range m.Apps {
		switch {
		case app.Existing.Chart != "":
			res.Skips = append(res.Skips, Skip{App: app.Name,
				Reason: "chart already exists at " + app.Existing.Chart})
			continue
		case app.Dockerfile == "":
			res.Skips = append(res.Skips, Skip{App: app.Name,
				Reason: "no Dockerfile — nothing builds an image for it (add one, then re-run)"})
			continue
		}

		dir := "k8s/charts/" + app.Name
		if single {
			dir = "k8s/chart"
		}
		res.ChartDirs[app.Name] = dir

		ops, err := chartOps(dir, app, registry)
		if err != nil {
			// Template rendering over our own constants only fails on a
			// programming error; surface it as a skip rather than
			// panicking an entire scaffold run.
			res.Skips = append(res.Skips, Skip{App: app.Name, Reason: err.Error()})
			continue
		}
		res.Ops = append(res.Ops, ops...)
	}
	return res
}

// chartContext is the data substituted into the chart templates.
type chartContext struct {
	Name        string
	Description string
	ImageRepo   string
	Port        int
	// SecretName wires envFrom to the app's generated Secret; empty when
	// the env scan found no secret-like variables.
	SecretName string
	// ConfigVars lists detected non-secret variables ("NAME (file:line)")
	// as values.yaml comments so the user knows what to configure.
	ConfigVars []string
}

func chartOps(dir string, app reposcan.App, registry string) ([]genwrite.Op, error) {
	ctx := chartContext{
		Name:        app.Name,
		Description: description(app),
		ImageRepo:   registry + "/" + app.Name,
		Port:        app.Port,
	}
	for _, ref := range app.Env {
		if ref.Secret {
			ctx.SecretName = secretsgen.SecretName(app.Name)
		} else {
			ctx.ConfigVars = append(ctx.ConfigVars, fmt.Sprintf("%s (%s)", ref.Name, ref.Location))
		}
	}

	files := []struct {
		rel  string
		tmpl string
	}{
		{"Chart.yaml", chartYamlTmpl},
		{"values.yaml", valuesYamlTmpl},
		{"values-sandbox.yaml", valuesSandboxTmpl},
		{"templates/_helpers.tpl", helpersTmpl},
		{"templates/deployment.yaml", deploymentTmpl},
		{"templates/service.yaml", serviceTmpl},
		{"templates/serviceaccount.yaml", serviceAccountTmpl},
	}

	reason := fmt.Sprintf("Helm chart for app %s (%s)", app.Name, describeRuntime(app))
	ops := make([]genwrite.Op, 0, len(files))
	for _, f := range files {
		body, err := render(f.rel, f.tmpl, ctx)
		if err != nil {
			return nil, fmt.Errorf("render %s for %s: %w", f.rel, app.Name, err)
		}
		ops = append(ops, genwrite.Op{
			Path:      path.Join(dir, f.rel),
			Body:      body,
			Generator: Generator,
			Reason:    reason,
		})
	}
	return ops, nil
}

func render(name, tmpl string, ctx chartContext) ([]byte, error) {
	t, err := template.New(name).Delims("[[", "]]").Parse(tmpl)
	if err != nil {
		return nil, err
	}
	var buf bytes.Buffer
	if err := t.Execute(&buf, ctx); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func description(app reposcan.App) string {
	switch app.Kind {
	case "worker":
		return fmt.Sprintf("%s — background worker (scaffolded by sandboxctl)", app.Name)
	case "frontend":
		return fmt.Sprintf("%s — web frontend (scaffolded by sandboxctl)", app.Name)
	default:
		return fmt.Sprintf("%s — HTTP service (scaffolded by sandboxctl)", app.Name)
	}
}

func describeRuntime(app reposcan.App) string {
	rt := app.Language
	if app.Framework != "" {
		rt += "/" + app.Framework
	}
	if rt == "" {
		rt = "unknown runtime"
	}
	if app.Port > 0 {
		return fmt.Sprintf("%s, port %d", rt, app.Port)
	}
	return fmt.Sprintf("%s, no port — worker", rt)
}
