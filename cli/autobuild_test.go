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

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}
