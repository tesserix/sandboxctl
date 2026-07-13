// Package gitopsgen turns the repo model into a per-app GitOps
// pipeline: a Kargo Project + Warehouse watching the sandbox registry,
// dev→staging Stages whose promotions commit image digests into the
// chart's Gitea repo, and the stage-annotated Argo CD Applications those
// promotions drive. Pure model→ops; the safe-write engine owns disk.
package gitopsgen

import (
	"bytes"
	"fmt"
	"path"
	"text/template"

	"github.com/tesserix/sandboxctl/cli/internal/genwrite"
	"github.com/tesserix/sandboxctl/cli/internal/reposcan"
)

// Generator tag for ownership markers.
const Generator = "scaffold"

// Config carries the sandbox coordinates baked into the manifests.
// Zero values resolve to the stock sandbox layout.
type Config struct {
	// RegistryHost is the registry as the cluster (and Kargo) sees it,
	// e.g. "registry.sandboxctl-registry.svc.cluster.local:5000".
	RegistryHost string
	// GiteaHost is the in-cluster Gitea HTTP endpoint,
	// e.g. "gitea-http.gitea.svc.cluster.local:3000".
	GiteaHost string
	// Org is the Gitea org charts are pushed to ("apps").
	Org string
}

func (c *Config) defaults() {
	if c.RegistryHost == "" {
		c.RegistryHost = "registry.sandboxctl-registry.svc.cluster.local:5000"
	}
	if c.GiteaHost == "" {
		c.GiteaHost = "gitea-http.gitea.svc.cluster.local:3000"
	}
	if c.Org == "" {
		c.Org = "apps"
	}
}

// ProjectName is the Kargo Project (and its namespace) for an app —
// suffixed so it can never collide with the app's own dev/staging
// deployment namespaces.
func ProjectName(app string) string { return app + "-kargo" }

// Skip explains why an app got no pipeline.
type Skip struct {
	App    string
	Reason string
}

// Result is the generation outcome.
type Result struct {
	Ops   []genwrite.Op
	Skips []Skip
}

// Ops plans the pipeline files. chartDirs maps app name → repo-relative
// chart dir (generated this run or pre-existing) — the staging values
// file lands inside it. Eligibility: app has a Dockerfile (something to
// watch), a chart dir, and no existing GitOps manifests.
func Ops(m *reposcan.Model, cfg Config, chartDirs map[string]string) *Result {
	cfg.defaults()
	res := &Result{}

	for _, app := range m.Apps {
		switch {
		case app.Existing.GitOps != "":
			res.Skips = append(res.Skips, Skip{App: app.Name,
				Reason: "GitOps manifests already exist at " + app.Existing.GitOps})
			continue
		case app.Dockerfile == "":
			res.Skips = append(res.Skips, Skip{App: app.Name,
				Reason: "no Dockerfile — nothing for the Warehouse to watch"})
			continue
		case chartDirs[app.Name] == "":
			res.Skips = append(res.Skips, Skip{App: app.Name,
				Reason: "no chart to promote (scaffold one first)"})
			continue
		}

		ctx := pipelineContext{
			App:           app.Name,
			Project:       ProjectName(app.Name),
			ImageRepo:     cfg.RegistryHost + "/" + app.Name,
			GitRepo:       "http://" + cfg.GiteaHost + "/" + cfg.Org + "/" + app.Name + "-chart.git",
			DevValuesFile: "values-sandbox.yaml",
		}

		dir := "k8s/gitops/" + app.Name
		files := []struct {
			path, tmpl string
		}{
			{path.Join(dir, "project.yaml"), projectTmpl},
			{path.Join(dir, "warehouse.yaml"), warehouseTmpl},
			{path.Join(dir, "stages.yaml"), stagesTmpl},
			{path.Join(dir, "application.yaml"), applicationTmpl},
			{path.Join(chartDirs[app.Name], "values-staging.yaml"), valuesStagingTmpl},
		}
		reason := fmt.Sprintf("Kargo pipeline for %s (registry → dev → staging)", app.Name)
		ok := true
		for _, f := range files {
			body, err := render(f.path, f.tmpl, ctx)
			if err != nil {
				res.Skips = append(res.Skips, Skip{App: app.Name, Reason: err.Error()})
				ok = false
				break
			}
			res.Ops = append(res.Ops, genwrite.Op{
				Path: f.path, Body: body, Generator: Generator, Reason: reason,
			})
		}
		if !ok {
			continue
		}
	}
	return res
}

type pipelineContext struct {
	App           string
	Project       string
	ImageRepo     string
	GitRepo       string
	DevValuesFile string
}

func render(name, tmpl string, ctx pipelineContext) ([]byte, error) {
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
