package main

import (
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
)

func TestParseDockerfileLocalSources_SkipsFromAndUrls(t *testing.T) {
	dir := t.TempDir()
	df := filepath.Join(dir, "Dockerfile")
	body := `# comment line
FROM alpine AS build
COPY go.mod go.sum ./
COPY src/ ./src/
COPY --from=build /out/bin /usr/local/bin/bin
ADD https://example.com/file.tar.gz /tmp/
ADD ["pkg.json", "/app/"]
COPY \
  shared/lib \
  shared/pkg \
  /app/
COPY scripts/*.sh /app/scripts/
`
	if err := os.WriteFile(df, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	srcs, warns := parseDockerfileLocalSources(df)
	if len(warns) != 0 {
		t.Fatalf("unexpected warnings: %v", warns)
	}
	want := []string{
		"go.mod", "go.sum",
		"src/",
		"pkg.json",
		"shared/lib", "shared/pkg",
		"scripts/*.sh",
	}
	sort.Strings(srcs)
	sort.Strings(want)
	if !reflect.DeepEqual(srcs, want) {
		t.Fatalf("sources mismatch\n got:  %v\n want: %v", srcs, want)
	}
}

func TestParseDockerfileLocalSources_VarsWarn(t *testing.T) {
	dir := t.TempDir()
	df := filepath.Join(dir, "Dockerfile")
	if err := os.WriteFile(df, []byte("FROM scratch\nCOPY ${BUILD_DIR}/out /app/\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	srcs, warns := parseDockerfileLocalSources(df)
	if len(srcs) != 0 {
		t.Fatalf("expected no sources, got %v", srcs)
	}
	if len(warns) == 0 {
		t.Fatalf("expected warning for ${VAR} source")
	}
}

// The whole point of this change: a Dockerfile that lives at
// docker/e2e/Dockerfile and COPYs go.mod/go.sum should resolve its
// build context to the repo root, not its own parent directory.
func TestInferBuildContext_NestedDockerfileNeedsRepoRoot(t *testing.T) {
	root := t.TempDir()
	must(t, os.MkdirAll(filepath.Join(root, "docker", "e2e"), 0o755))
	must(t, os.WriteFile(filepath.Join(root, "go.mod"), []byte("module x\n"), 0o644))
	must(t, os.WriteFile(filepath.Join(root, "go.sum"), []byte(""), 0o644))
	must(t, os.MkdirAll(filepath.Join(root, "integration", "e2e"), 0o755))
	must(t, os.WriteFile(filepath.Join(root, "integration", "e2e", "doc.go"), []byte("package e2e\n"), 0o644))

	df := filepath.Join(root, "docker", "e2e", "Dockerfile")
	must(t, os.WriteFile(df, []byte(`FROM golang AS b
WORKDIR /src
COPY go.mod go.sum ./
COPY . .
`), 0o644))

	srcs, _ := parseDockerfileLocalSources(df)
	ctx, warn := inferBuildContext(root, df, srcs)
	if warn != "" {
		t.Fatalf("unexpected warning: %s", warn)
	}
	if filepath.Clean(ctx) != filepath.Clean(root) {
		t.Fatalf("expected context = repo root %s, got %s", root, ctx)
	}
}

// The opposite case: a Dockerfile whose sources resolve in its own
// directory should keep that directory as context, not silently
// promote to the repo root.
func TestInferBuildContext_LocalSourcesStayLocal(t *testing.T) {
	root := t.TempDir()
	sub := filepath.Join(root, "docker", "tool")
	must(t, os.MkdirAll(sub, 0o755))
	must(t, os.WriteFile(filepath.Join(sub, "tool.go"), []byte("package main"), 0o644))
	df := filepath.Join(sub, "Dockerfile")
	must(t, os.WriteFile(df, []byte("FROM scratch\nCOPY tool.go /tool.go\n"), 0o644))

	srcs, _ := parseDockerfileLocalSources(df)
	ctx, warn := inferBuildContext(root, df, srcs)
	if warn != "" {
		t.Fatalf("unexpected warning: %s", warn)
	}
	if filepath.Clean(ctx) != filepath.Clean(sub) {
		t.Fatalf("expected context = %s, got %s", sub, ctx)
	}
}

// `COPY --from=stage ...` references another stage, not the build
// context — its source paths must NOT be used to widen the context.
func TestInferBuildContext_FromFlagIgnored(t *testing.T) {
	root := t.TempDir()
	sub := filepath.Join(root, "docker", "tool")
	must(t, os.MkdirAll(sub, 0o755))
	df := filepath.Join(sub, "Dockerfile")
	must(t, os.WriteFile(df, []byte(`FROM golang AS b
WORKDIR /src
RUN echo hello
FROM scratch
COPY --from=b /out/bin /bin/bin
`), 0o644))
	srcs, _ := parseDockerfileLocalSources(df)
	if len(srcs) != 0 {
		t.Fatalf("expected zero local sources (only --from), got %v", srcs)
	}
	// With no sources, allResolve is trivially true at the dockerfile's
	// own dir — context inference should stay there.
	ctx, _ := inferBuildContext(root, df, srcs)
	if filepath.Clean(ctx) != filepath.Clean(sub) {
		t.Fatalf("expected context = %s, got %s", sub, ctx)
	}
}

// Globs: prefix up to the first metacharacter must resolve.
func TestInferBuildContext_GlobsResolveByPrefix(t *testing.T) {
	root := t.TempDir()
	must(t, os.MkdirAll(filepath.Join(root, "scripts"), 0o755))
	must(t, os.WriteFile(filepath.Join(root, "scripts", "run.sh"), []byte("#!/bin/sh"), 0o644))
	sub := filepath.Join(root, "docker", "tool")
	must(t, os.MkdirAll(sub, 0o755))
	df := filepath.Join(sub, "Dockerfile")
	must(t, os.WriteFile(df, []byte("FROM scratch\nCOPY scripts/*.sh /scripts/\n"), 0o644))

	srcs, _ := parseDockerfileLocalSources(df)
	ctx, _ := inferBuildContext(root, df, srcs)
	if filepath.Clean(ctx) != filepath.Clean(root) {
		t.Fatalf("expected context = %s, got %s", root, ctx)
	}
}

// End-to-end: feed a tree to the autogen entry point and check the
// produced manifest is what manifest.go can later parse without errors.
func TestAutogen_EndToEnd_ProducesUsableManifest(t *testing.T) {
	root := t.TempDir()

	// Repo-root layout: a top-level Dockerfile, plus a nested one
	// (matching the e2e case that triggered this whole change).
	must(t, os.MkdirAll(filepath.Join(root, "cmd", "x"), 0o755))
	must(t, os.WriteFile(filepath.Join(root, "go.mod"), []byte("module x\n"), 0o644))
	must(t, os.WriteFile(filepath.Join(root, "go.sum"), []byte(""), 0o644))
	must(t, os.WriteFile(filepath.Join(root, "Dockerfile"), []byte(`FROM golang
COPY go.mod go.sum ./
COPY . .
`), 0o644))

	must(t, os.MkdirAll(filepath.Join(root, "docker", "e2e"), 0o755))
	must(t, os.WriteFile(filepath.Join(root, "docker", "e2e", "Dockerfile"), []byte(`FROM golang
COPY go.mod go.sum ./
COPY . .
`), 0o644))

	dfs, err := findDockerfiles(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(dfs) != 2 {
		t.Fatalf("expected 2 Dockerfiles, found %d: %v", len(dfs), dfs)
	}
	imgs, warns := buildAutogenImages(root, dfs)
	if len(warns) != 0 {
		t.Fatalf("unexpected warnings: %v", warns)
	}
	if len(imgs) != 2 {
		t.Fatalf("expected 2 images, got %d", len(imgs))
	}
	for _, img := range imgs {
		if img.Context != "." {
			t.Fatalf("expected context '.' for %s, got %q", img.Name, img.Context)
		}
	}

	out := filepath.Join(root, "sandboxctl.yaml")
	if err := writeAutogenManifest(out, imgs); err != nil {
		t.Fatal(err)
	}

	// Round-trip through the existing manifest parser to make sure the
	// emitted YAML is valid and produces the same context decisions.
	body, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(body), "auto-generated") {
		t.Fatalf("expected header comment in generated YAML:\n%s", body)
	}

	rc := runParseBuildManifest([]string{out})
	if rc != 0 {
		t.Fatalf("manifest parser rejected the auto-generated file (rc=%d)", rc)
	}
}

func TestSlugifyName_MatchesShellSlugify(t *testing.T) {
	cases := map[string]string{
		"FooBar":          "foobar",
		"my_app":          "my-app",
		"docker/e2e":      "docker-e2e",
		"---weird---":     "weird",
		"v1.2.3":          "v1-2-3",
		"":                "",
	}
	for in, want := range cases {
		got := slugifyName(in)
		if got != want {
			t.Errorf("slugifyName(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestGlobStaticPrefix(t *testing.T) {
	cases := map[string]string{
		"foo/bar":         "foo/bar",
		"foo/*.go":        "foo",
		"foo/bar/*.go":    "foo/bar",
		"*.go":            "",
		"foo/[ab]/c":      "foo",
		"foo/?ar":         "foo",
		"foo":             "foo",
	}
	for in, want := range cases {
		got := globStaticPrefix(in)
		if got != want {
			t.Errorf("globStaticPrefix(%q) = %q, want %q", in, got, want)
		}
	}
}

// The headline fix: a manifest where one image's Dockerfile FROMs
// another (with a project-name prefix that differs from the manifest
// slug) should auto-pick up aliases + depends_on, and the build order
// should put the producer first.
func TestAutogen_CrossRef_PrefixedFromInfersAliasAndOrder(t *testing.T) {
	root := filepath.Join(t.TempDir(), "fiber") // base name = "fiber"
	must(t, os.MkdirAll(filepath.Join(root, "docker", "agent-sdk"), 0o755))
	must(t, os.MkdirAll(filepath.Join(root, "docker", "quality"), 0o755))
	must(t, os.WriteFile(filepath.Join(root, "docker", "agent-sdk", "Dockerfile"),
		[]byte("FROM python:3.12-slim\n"), 0o644))
	must(t, os.WriteFile(filepath.Join(root, "docker", "quality", "Dockerfile"),
		[]byte("FROM fiber-agent-sdk:latest\nRUN echo hi\n"), 0o644))

	dfs, err := findDockerfiles(root)
	must(t, err)
	imgs, warns := buildAutogenImages(root, dfs)
	if len(warns) != 0 {
		t.Fatalf("unexpected warnings: %v", warns)
	}
	// Producer must come first in the topo-sorted output.
	if imgs[0].Name != "agent-sdk" {
		t.Fatalf("expected agent-sdk first after topo sort, got order: %v", imageNames(imgs))
	}
	idx := indexByName(imgs)
	prod := imgs[idx["agent-sdk"]]
	cons := imgs[idx["quality"]]
	if !contains(prod.Aliases, "fiber-agent-sdk:latest") {
		t.Fatalf("producer agent-sdk missing alias 'fiber-agent-sdk:latest', got %v", prod.Aliases)
	}
	if !contains(cons.DependsOn, "agent-sdk") {
		t.Fatalf("consumer quality missing depends_on 'agent-sdk', got %v", cons.DependsOn)
	}
}

// External registry refs (docker.io/x, gcr.io/x, alpine, …) must NOT
// match a sibling image, even when the bare name happens to overlap.
func TestAutogen_CrossRef_RegistryRefsAreIgnored(t *testing.T) {
	root := filepath.Join(t.TempDir(), "proj")
	must(t, os.MkdirAll(filepath.Join(root, "alpine"), 0o755)) // sibling slug = "alpine"
	must(t, os.MkdirAll(filepath.Join(root, "user"), 0o755))
	must(t, os.WriteFile(filepath.Join(root, "alpine", "Dockerfile"),
		[]byte("FROM scratch\n"), 0o644))
	must(t, os.WriteFile(filepath.Join(root, "user", "Dockerfile"),
		[]byte("FROM docker.io/library/alpine:3.20\n"), 0o644))

	dfs, err := findDockerfiles(root)
	must(t, err)
	imgs, _ := buildAutogenImages(root, dfs)
	idx := indexByName(imgs)
	if got := imgs[idx["alpine"]].Aliases; len(got) != 0 {
		t.Fatalf("expected no alias on alpine sibling for registry-qualified FROM, got %v", got)
	}
	if got := imgs[idx["user"]].DependsOn; len(got) != 0 {
		t.Fatalf("expected no depends_on for registry-qualified FROM, got %v", got)
	}
}

// FROM stage names introduced by `AS` aren't real images.
func TestAutogen_CrossRef_StageAliasesIgnored(t *testing.T) {
	root := filepath.Join(t.TempDir(), "p")
	must(t, os.MkdirAll(filepath.Join(root, "tool"), 0o755))
	must(t, os.MkdirAll(filepath.Join(root, "build"), 0o755))
	must(t, os.WriteFile(filepath.Join(root, "build", "Dockerfile"),
		[]byte("FROM scratch\n"), 0o644))
	must(t, os.WriteFile(filepath.Join(root, "tool", "Dockerfile"),
		[]byte(`FROM golang:1.25 AS build
RUN echo hi
FROM scratch
COPY --from=build /bin/x /x
`), 0o644))

	dfs, err := findDockerfiles(root)
	must(t, err)
	imgs, _ := buildAutogenImages(root, dfs)
	idx := indexByName(imgs)
	if got := imgs[idx["build"]].Aliases; len(got) != 0 {
		t.Fatalf("`build` stage alias should not match sibling 'build', got %v", got)
	}
}

// Cycles must not crash; manifest order is preserved with a warning.
func TestTopoSort_CyclePreservesOrder(t *testing.T) {
	imgs := []manifestImage{
		{Name: "a", DependsOn: []string{"b"}},
		{Name: "b", DependsOn: []string{"a"}},
	}
	out, warns := topoSortImages(imgs)
	if len(warns) == 0 {
		t.Fatalf("expected cycle warning")
	}
	if out[0].Name != "a" || out[1].Name != "b" {
		t.Fatalf("expected original order preserved on cycle, got %v", imageNames(out))
	}
}

// _parse-build-manifest applies the same inference, so a hand-edited
// manifest gets the auto-fix without regenerating.
func TestParseBuildManifest_InfersCrossRefsForExistingManifest(t *testing.T) {
	root := filepath.Join(t.TempDir(), "fiber")
	must(t, os.MkdirAll(filepath.Join(root, "docker", "agent-sdk"), 0o755))
	must(t, os.MkdirAll(filepath.Join(root, "docker", "quality"), 0o755))
	must(t, os.WriteFile(filepath.Join(root, "docker", "agent-sdk", "Dockerfile"),
		[]byte("FROM python:3.12-slim\n"), 0o644))
	must(t, os.WriteFile(filepath.Join(root, "docker", "quality", "Dockerfile"),
		[]byte("FROM fiber-agent-sdk:latest\n"), 0o644))
	manifest := filepath.Join(root, "sandboxctl.yaml")
	// Hand-written manifest: WRONG order, no aliases, no depends_on.
	must(t, os.WriteFile(manifest, []byte(`images:
  - name: quality
    context: docker/quality
  - name: agent-sdk
    context: docker/agent-sdk
`), 0o644))

	stdout := captureStdout(t, func() { runParseBuildManifest([]string{manifest}) })
	lines := strings.Split(strings.TrimSpace(stdout), "\n")
	if len(lines) != 2 {
		t.Fatalf("expected 2 output lines, got %d:\n%s", len(lines), stdout)
	}
	// Producer must come first; aliases on producer; depends_on on consumer.
	first := strings.Split(lines[0], "\t")
	second := strings.Split(lines[1], "\t")
	if first[0] != "agent-sdk" {
		t.Fatalf("expected agent-sdk first, got %s", first[0])
	}
	if first[4] != "fiber-agent-sdk:latest" {
		t.Fatalf("expected agent-sdk aliases='fiber-agent-sdk:latest', got %q", first[4])
	}
	if second[0] != "quality" || second[5] != "agent-sdk" {
		t.Fatalf("expected quality with depends_on=agent-sdk, got %v", second)
	}
}

func indexByName(imgs []manifestImage) map[string]int {
	out := map[string]int{}
	for i, img := range imgs {
		out[img.Name] = i
	}
	return out
}

func imageNames(imgs []manifestImage) []string {
	out := make([]string, len(imgs))
	for i, img := range imgs {
		out[i] = img.Name
	}
	return out
}

func contains(xs []string, v string) bool {
	for _, x := range xs {
		if x == v {
			return true
		}
	}
	return false
}

func captureStdout(t *testing.T, fn func()) string {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	orig := os.Stdout
	os.Stdout = w
	defer func() { os.Stdout = orig }()
	done := make(chan string)
	go func() {
		var b strings.Builder
		buf := make([]byte, 4096)
		for {
			n, err := r.Read(buf)
			if n > 0 {
				b.Write(buf[:n])
			}
			if err != nil {
				done <- b.String()
				return
			}
		}
	}()
	fn()
	w.Close()
	return <-done
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}
