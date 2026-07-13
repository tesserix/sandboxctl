package main

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/tesserix/sandboxctl/cli/internal/chartgen"
	"github.com/tesserix/sandboxctl/cli/internal/genwrite"
	"github.com/tesserix/sandboxctl/cli/internal/reposcan"
)

// scaffoldTwoCharts materializes two generated charts in a temp root and
// returns everything the lint gate consumes.
func scaffoldTwoCharts(t *testing.T) (root string, dirs map[string]string, res *genwrite.Result) {
	t.Helper()
	root = t.TempDir()
	gen := chartgen.Ops(&reposcan.Model{Apps: []reposcan.App{
		{Name: "api", Path: "apps/api", Language: "go", Dockerfile: "apps/api/Dockerfile", Port: 8080, Kind: "http"},
		{Name: "web", Path: "apps/web", Language: "ts", Dockerfile: "apps/web/Dockerfile", Port: 3000, Kind: "http"},
	}}, chartgen.Config{})
	plan, err := genwrite.BuildPlan(root, gen.Ops)
	if err != nil {
		t.Fatal(err)
	}
	res, err = genwrite.Apply(plan, genwrite.Options{})
	if err != nil {
		t.Fatal(err)
	}
	return root, gen.ChartDirs, res
}

func TestLintGateRollsBackFailingChartOnly(t *testing.T) {
	root, dirs, res := scaffoldTwoCharts(t)

	var out bytes.Buffer
	failed := lintWrittenCharts(dirs, res, &out, func(dir string) (string, error) {
		if strings.HasSuffix(dir, "/api") {
			return "[ERROR] templates/: template: boom", errors.New("exit status 1")
		}
		return "1 chart(s) linted, 0 chart(s) failed", nil
	})

	if len(failed) != 1 || failed[0] != "k8s/charts/api" {
		t.Fatalf("failed = %v", failed)
	}
	if _, err := os.Stat(filepath.Join(root, "k8s/charts/api")); !os.IsNotExist(err) {
		t.Fatal("failing chart not rolled back")
	}
	if _, err := os.Stat(filepath.Join(root, "k8s/charts/web/Chart.yaml")); err != nil {
		t.Fatal("passing chart was rolled back too")
	}
	o := out.String()
	if !strings.Contains(o, "helm lint FAILED  k8s/charts/api") ||
		!strings.Contains(o, "template: boom") ||
		!strings.Contains(o, "rolled back 8 file(s) under k8s/charts/api") ||
		!strings.Contains(o, "helm lint ok  k8s/charts/web") {
		t.Fatalf("gate output wrong:\n%s", o)
	}
}

func TestLintGateSkipsChartsWithoutWrites(t *testing.T) {
	_, dirs, _ := scaffoldTwoCharts(t)

	calls := 0
	var out bytes.Buffer
	failed := lintWrittenCharts(dirs, &genwrite.Result{}, &out, func(string) (string, error) {
		calls++
		return "", nil
	})
	if calls != 0 || len(failed) != 0 {
		t.Fatalf("gate ran %d lint(s) on a run that wrote nothing", calls)
	}
}
