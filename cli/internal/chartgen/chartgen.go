// Package chartgen turns a reposcan.Model into Helm charts. It is a
// pure function from model to genwrite ops: no filesystem reads, no
// cluster access — the safe-write engine decides what actually lands on
// disk, so existing charts and user edits are never at risk here.
package chartgen

import (
	"bytes"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"text/template"

	"github.com/tesserix/sandboxctl/cli/internal/genwrite"
	"github.com/tesserix/sandboxctl/cli/internal/reposcan"
	"github.com/tesserix/sandboxctl/cli/internal/secretsgen"
)

// Generator is recorded in every file's ownership marker.
const Generator = "scaffold"

// Config carries the sandbox coordinates baked into generated charts.
// Zero values resolve to the stock sandbox layout.
// ImageRef is the registry-relative image coordinate `sandboxctl
// build` pushes for an app. Resolved by the caller from the build
// manifest (or the autogen derivation) so generated values reference
// what actually lands in the registry — assuming image name == app
// name is how deploys end in ImagePullBackOff.
type ImageRef struct {
	Name string // registry-relative repo, e.g. "agent-sim"
	Tag  string // defaults to "latest"
}

type Config struct {
	// Registry is the image push/pull coordinate as seen from both the
	// Mac and the kind node (containerd mirror), e.g. "localhost:5050".
	Registry string
	// Images maps app name → the image build pushes for it. Apps
	// absent here fall back to <app>:latest.
	Images map[string]ImageRef
	// Domain is the sandbox DNS suffix; the app's URL host becomes
	// "<app>.<Domain>".
	Domain string
	// GatewayRef is the Istio gateway the VirtualService binds to,
	// "<namespace>/<name>".
	GatewayRef string
}

// imageFor resolves the image an app's values must reference.
func (c *Config) imageFor(app string) ImageRef {
	ref, ok := c.Images[app]
	if !ok || ref.Name == "" {
		ref = ImageRef{Name: app}
	}
	if ref.Tag == "" {
		ref.Tag = "latest"
	}
	return ref
}

func (c *Config) defaults() {
	if c.Registry == "" {
		c.Registry = "localhost:5050"
	}
	if c.Domain == "" {
		c.Domain = "sandbox.app"
	}
	if c.GatewayRef == "" {
		c.GatewayRef = "istio-ingress/sandbox-gateway"
	}
}

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
	// UmbrellaDir is the monorepo umbrella chart dir ("k8s/chart"),
	// empty when none was generated. Its files are part of Ops; callers
	// use this to give the umbrella its own lint treatment (it needs
	// `helm dependency build` before it lints).
	UmbrellaDir string
}

// Ops plans one chart per eligible app. Eligibility: the app must have
// a Dockerfile (the chart references the image the build pushes) and no
// existing chart. Layout: k8s/chart for a single-app repo (the
// documented recommended layout), k8s/charts/<name> for monorepos.
func Ops(m *reposcan.Model, cfg Config) *Result {
	cfg.defaults()
	res := &Result{ChartDirs: map[string]string{}}

	single := len(m.Apps) == 1
	for _, app := range m.Apps {
		switch {
		case app.Existing.Chart != "":
			res.Skips = append(res.Skips, Skip{App: app.Name,
				Reason: "chart already exists at " + app.Existing.Chart})
			// The chart stays the user's, but its sandbox image wiring
			// must keep tracking what build pushes — refresh
			// values-sandbox.yaml when we generated it earlier.
			// genwrite keeps edited copies; only ours-clean files
			// regenerate, and we never inject the file into a chart
			// that doesn't have one.
			res.Ops = append(res.Ops, refreshValuesOps(m.Root, app, cfg)...)
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

		ops, err := chartOps(dir, app, cfg)
		if err != nil {
			// Template rendering over our own constants only fails on a
			// programming error; surface it as a skip rather than
			// panicking an entire scaffold run.
			res.Skips = append(res.Skips, Skip{App: app.Name, Reason: err.Error()})
			continue
		}
		res.Ops = append(res.Ops, ops...)
	}

	addUmbrella(m, cfg, res)
	return res
}

// addUmbrella emits the monorepo umbrella chart at k8s/chart: one chart
// whose file:// dependencies pull in every per-app chart under
// k8s/charts/, each behind an <app>.enabled condition. Only when 2+
// apps are charted (there is nothing to "connect" otherwise), and never
// when k8s/chart already exists as a real single-app chart — the
// analyzer reports that as an app's Existing.Chart, and hijacking the
// recommended single-app location would change what deploy runs.
func addUmbrella(m *reposcan.Model, cfg Config, res *Result) {
	type dep struct {
		Name      string
		Port      int
		ImageRepo string
		ImageTag  string
	}
	var apps []dep
	for _, app := range m.Apps {
		dir := res.ChartDirs[app.Name]
		if dir == "" && strings.HasPrefix(app.Existing.Chart, "k8s/charts/") {
			dir = app.Existing.Chart
		}
		if strings.HasPrefix(dir, "k8s/charts/") {
			img := cfg.imageFor(app.Name)
			apps = append(apps, dep{
				Name: app.Name, Port: app.Port,
				ImageRepo: cfg.Registry + "/" + img.Name,
				ImageTag:  img.Tag,
			})
		}
	}
	if len(apps) < 2 {
		return
	}
	for _, app := range m.Apps {
		if app.Existing.Chart == "k8s/chart" {
			res.Skips = append(res.Skips, Skip{App: "umbrella",
				Reason: "k8s/chart already holds a chart — not generating the umbrella there"})
			return
		}
	}
	sort.Slice(apps, func(i, j int) bool { return apps[i].Name < apps[j].Name })

	name := slugify(path.Base(m.Root))
	if name == "" {
		name = "stack"
	}
	ctx := map[string]any{
		"Name": name, "Dir": "k8s/chart", "Apps": apps,
		"Registry": cfg.Registry, "Domain": cfg.Domain, "Gateway": cfg.GatewayRef,
	}
	reason := fmt.Sprintf("umbrella chart connecting %d app charts (one 'helm install' for the stack)", len(apps))
	files := []struct{ rel, tmpl string }{
		{"k8s/chart/Chart.yaml", umbrellaChartYamlTmpl},
		{"k8s/chart/values.yaml", umbrellaValuesTmpl},
		{"k8s/chart/values-sandbox.yaml", umbrellaValuesSandboxTmpl},
	}
	for _, f := range files {
		body, err := renderAny(f.rel, f.tmpl, ctx)
		if err != nil {
			res.Skips = append(res.Skips, Skip{App: "umbrella", Reason: err.Error()})
			return
		}
		res.Ops = append(res.Ops, genwrite.Op{Path: f.rel, Body: body, Generator: Generator, Reason: reason})
	}
	// `helm dependency build` vendors the subcharts as tgz files —
	// derived artifacts that don't belong in git.
	res.Ops = append(res.Ops, genwrite.Op{
		Path: ".gitignore", Append: []string{"k8s/chart/charts/"},
		Reason: "ignore the umbrella's vendored dependencies",
	})
	res.UmbrellaDir = "k8s/chart"
}

func renderAny(name, tmpl string, ctx any) ([]byte, error) {
	t, err := template.New(name).Delims("[[", "]]").Parse(tmpl)
	if err != nil {
		return nil, fmt.Errorf("render %s: %w", name, err)
	}
	var buf bytes.Buffer
	if err := t.Execute(&buf, ctx); err != nil {
		return nil, fmt.Errorf("render %s: %w", name, err)
	}
	return buf.Bytes(), nil
}

// slugify matches the analyzer's naming so the umbrella lines up with
// app/image names.
func slugify(s string) string {
	s = strings.ToLower(s)
	var b strings.Builder
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9':
			b.WriteRune(r)
		default:
			b.WriteByte('-')
		}
	}
	return strings.Trim(b.String(), "-")
}

// chartContext is the data substituted into the chart templates.
type chartContext struct {
	Name        string
	Description string
	ImageRepo   string
	ImageTag    string
	Port        int
	// Host + Gateway wire the chart's own VirtualService in
	// values-sandbox.yaml, so GitOps owns the app's URL end to end and
	// nothing has to hand-craft routing per app.
	Host    string
	Gateway string
	// SecretName wires envFrom to the app's generated Secret; empty when
	// the env scan found no secret-like variables.
	SecretName string
	// ConfigVars lists detected non-secret variables ("NAME (file:line)")
	// as values.yaml comments so the user knows what to configure.
	ConfigVars []string
}

func chartCtx(app reposcan.App, cfg Config) chartContext {
	img := cfg.imageFor(app.Name)
	ctx := chartContext{
		Name:        app.Name,
		Description: description(app),
		ImageRepo:   cfg.Registry + "/" + img.Name,
		ImageTag:    img.Tag,
		Port:        app.Port,
		Host:        app.Name + "." + cfg.Domain,
		Gateway:     cfg.GatewayRef,
	}
	for _, ref := range app.Env {
		if ref.Secret {
			ctx.SecretName = secretsgen.SecretName(app.Name)
		} else {
			ctx.ConfigVars = append(ctx.ConfigVars, fmt.Sprintf("%s (%s)", ref.Name, ref.Location))
		}
	}
	return ctx
}

// refreshValuesOps re-emits values-sandbox.yaml for an app whose chart
// already exists, so the image coordinates keep following the build
// manifest. Only when the file is already there — a chart without one
// is not ours to extend (deploy's values mimic handles those).
func refreshValuesOps(root string, app reposcan.App, cfg Config) []genwrite.Op {
	rel := path.Join(app.Existing.Chart, "values-sandbox.yaml")
	if _, err := os.Stat(filepath.Join(root, filepath.FromSlash(rel))); err != nil {
		return nil
	}
	body, err := render("values-sandbox.yaml", valuesSandboxTmpl, chartCtx(app, cfg))
	if err != nil {
		return nil
	}
	return []genwrite.Op{{
		Path: rel, Body: body, Generator: Generator, Refresh: true,
		Reason: fmt.Sprintf("image wiring for %s (follows the build manifest)", app.Name),
	}}
}

func chartOps(dir string, app reposcan.App, cfg Config) ([]genwrite.Op, error) {
	ctx := chartCtx(app, cfg)

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
		{"templates/virtualservice.yaml", virtualServiceTmpl},
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
