// Package reposcan builds a structured model of a product repository:
// which deployable apps it contains, what runtime each app uses, and
// which sandbox-relevant artefacts (charts, GitOps manifests) already
// exist. Generators consume the model; nothing in this package touches
// the network or a cluster, and the tree is walked exactly once.
package reposcan

import (
	"fmt"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

// ModelVersion identifies the RepoModel schema. Consumers should refuse
// versions they don't understand rather than guessing.
const ModelVersion = 1

// Model is the analyzer's complete answer for one repository.
type Model struct {
	Version   int      `json:"version"`
	Root      string   `json:"root"`
	Layout    string   `json:"layout"`              // "single-app" | "monorepo"
	Workspace string   `json:"workspace,omitempty"` // pnpm | npm-workspaces | turbo | nx | lerna | go.work | go-multi-module | cargo | compose | dockerfiles
	Reasons   []string `json:"reasons,omitempty"`
	Apps      []App    `json:"apps"`
	Warnings  []string `json:"warnings,omitempty"`
}

// App is one deployable unit discovered in the repo.
type App struct {
	Name       string   `json:"name"`
	Path       string   `json:"path"` // repo-relative, "." for a root app
	Language   string   `json:"language,omitempty"`
	Framework  string   `json:"framework,omitempty"`
	Dockerfile string   `json:"dockerfile,omitempty"` // repo-relative
	Port       int      `json:"port,omitempty"`
	Kind       string   `json:"kind"` // http | frontend | worker
	Reasons    []string `json:"reasons,omitempty"`
	Existing   Existing `json:"existing"`
}

// Existing records artefacts the generators must treat as owned by the
// user: a chart or GitOps directory that already covers the app.
type Existing struct {
	Chart  string `json:"chart,omitempty"`  // repo-relative chart dir
	GitOps string `json:"gitops,omitempty"` // repo-relative manifest dir
}

// Scan analyzes the repository rooted at dir.
func Scan(dir string) (*Model, error) {
	root, err := filepath.Abs(dir)
	if err != nil {
		return nil, fmt.Errorf("resolve %s: %w", dir, err)
	}
	st, err := os.Stat(root)
	if err != nil || !st.IsDir() {
		return nil, fmt.Errorf("%s is not a directory", root)
	}

	idx, err := buildIndex(root)
	if err != nil {
		return nil, err
	}

	m := &Model{Version: ModelVersion, Root: root, Layout: "single-app"}

	ws, wsReasons := detectWorkspace(idx)
	m.Workspace = ws
	m.Reasons = append(m.Reasons, wsReasons...)

	apps, warns := deriveApps(idx, ws)
	m.Warnings = append(m.Warnings, warns...)

	for i := range apps {
		enrichApp(idx, &apps[i])
	}
	attachExisting(idx, apps)

	overrideWarns := applyOverrides(idx, &apps)
	m.Warnings = append(m.Warnings, overrideWarns...)

	sort.Slice(apps, func(i, j int) bool { return apps[i].Path < apps[j].Path })
	dedupeNames(apps)
	m.Apps = apps

	if ws != "" || len(apps) > 1 {
		m.Layout = "monorepo"
	}
	if len(apps) == 0 {
		m.Warnings = append(m.Warnings, "no apps detected — no language markers or Dockerfiles found")
	}
	return m, nil
}

// ----------------------------------------------------------------------------
// index: the single tree walk
// ----------------------------------------------------------------------------

// markerNames are the only base names the walk records. Everything else
// is ignored so the index stays small on large repos.
var markerNames = map[string]bool{
	"go.mod": true, "go.work": true, "main.go": true,
	"package.json": true, "pnpm-workspace.yaml": true, "tsconfig.json": true,
	"turbo.json": true, "nx.json": true, "lerna.json": true,
	"Cargo.toml": true, "pyproject.toml": true, "requirements.txt": true,
	"pom.xml": true, "build.gradle": true, "build.gradle.kts": true,
	"Gemfile": true, "Chart.yaml": true, "Dockerfile": true,
	"docker-compose.yml": true, "docker-compose.yaml": true,
	"compose.yml": true, "compose.yaml": true,
	"sandboxctl.yaml": true, "sandboxctl.yml": true,
}

// skipDirs matches the exclusion set used by the build auto-walk and
// chart discovery in sandbox.sh — keep the three in lockstep.
var skipDirs = map[string]bool{
	".git": true, "node_modules": true, "vendor": true, "dist": true,
}

type index struct {
	root string
	// dirs holds every visited directory, repo-relative ("." for root).
	dirs map[string]bool
	// files maps a marker base name to the repo-relative paths where it
	// was found, in walk (lexical) order.
	files map[string][]string
	// chartDirs are directories containing a Chart.yaml.
	chartDirs []string
}

func buildIndex(root string) (*index, error) {
	idx := &index{root: root, dirs: map[string]bool{}, files: map[string][]string{}}
	err := filepath.WalkDir(root, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		rel, rerr := filepath.Rel(root, p)
		if rerr != nil {
			return nil
		}
		rel = filepath.ToSlash(rel)
		if d.IsDir() {
			name := d.Name()
			if rel != "." && (skipDirs[name] || strings.HasPrefix(name, ".")) {
				return filepath.SkipDir
			}
			idx.dirs[rel] = true
			return nil
		}
		base := d.Name()
		switch {
		case markerNames[base]:
			idx.files[base] = append(idx.files[base], rel)
			if base == "Chart.yaml" {
				idx.chartDirs = append(idx.chartDirs, path.Dir(rel))
			}
		case strings.HasSuffix(base, ".csproj"):
			idx.files[".csproj"] = append(idx.files[".csproj"], rel)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return idx, nil
}

// has reports whether base name exists directly inside dir ("." = root).
func (idx *index) has(dir, base string) bool { return idx.pathOf(dir, base) != "" }

// pathOf returns the repo-relative path of base inside dir, or "".
func (idx *index) pathOf(dir, base string) string {
	want := base
	if dir != "." {
		want = dir + "/" + base
	}
	for _, p := range idx.files[base] {
		if p == want {
			return p
		}
	}
	return ""
}

// read returns the content of a repo-relative file, capped at 1 MiB —
// marker files larger than that are not worth parsing.
func (idx *index) read(rel string) []byte {
	if rel == "" {
		return nil
	}
	f, err := os.Open(filepath.Join(idx.root, filepath.FromSlash(rel)))
	if err != nil {
		return nil
	}
	defer f.Close()
	buf := make([]byte, 1<<20)
	n, _ := f.Read(buf)
	return buf[:n]
}

// ----------------------------------------------------------------------------
// workspace / layout detection
// ----------------------------------------------------------------------------

// detectWorkspace classifies the repo's workspace tooling. Precedence is
// most-specific first: an explicit workspace file beats inference from
// plain file counts, and JS workspace managers beat the task runners
// that sit on top of them.
func detectWorkspace(idx *index) (string, []string) {
	if idx.has(".", "pnpm-workspace.yaml") {
		return "pnpm", []string{"pnpm-workspace.yaml at repo root"}
	}
	if pkg := idx.pathOf(".", "package.json"); pkg != "" {
		if globs := packageJSONWorkspaces(idx.read(pkg)); len(globs) > 0 {
			return "npm-workspaces", []string{"package.json declares workspaces"}
		}
	}
	if idx.has(".", "lerna.json") {
		return "lerna", []string{"lerna.json at repo root"}
	}
	if idx.has(".", "nx.json") {
		return "nx", []string{"nx.json at repo root"}
	}
	if idx.has(".", "turbo.json") {
		return "turbo", []string{"turbo.json at repo root"}
	}
	if idx.has(".", "go.work") {
		return "go.work", []string{"go.work at repo root"}
	}
	if ct := idx.pathOf(".", "Cargo.toml"); ct != "" {
		if strings.Contains(string(idx.read(ct)), "[workspace]") {
			return "cargo", []string{"Cargo.toml declares [workspace]"}
		}
	}
	if len(subdirGoMods(idx)) >= 2 {
		return "go-multi-module", []string{"multiple go.mod files in subdirectories"}
	}
	if svcs := composeBuildServices(idx); len(svcs) >= 2 {
		return "compose", []string{fmt.Sprintf("docker compose file defines %d buildable services", len(svcs))}
	}
	if dirs := disjointDockerfileDirs(idx); len(dirs) >= 2 {
		return "dockerfiles", []string{fmt.Sprintf("%d Dockerfiles in separate directories", len(dirs))}
	}
	return "", nil
}

func subdirGoMods(idx *index) []string {
	var out []string
	for _, p := range idx.files["go.mod"] {
		if path.Dir(p) != "." {
			out = append(out, p)
		}
	}
	return out
}

func disjointDockerfileDirs(idx *index) []string {
	seen := map[string]bool{}
	var out []string
	for _, p := range idx.files["Dockerfile"] {
		d := path.Dir(p)
		if !seen[d] {
			seen[d] = true
			out = append(out, d)
		}
	}
	return out
}

// ----------------------------------------------------------------------------
// app derivation
// ----------------------------------------------------------------------------

// libraryDirNames mark workspace members that are almost certainly
// libraries, not deployable apps. A member under one of these is only
// promoted to app when it ships its own Dockerfile.
var libraryDirNames = map[string]bool{
	"packages": true, "libs": true, "lib": true, "shared": true, "common": true,
}

// deriveApps produces the candidate app list. Sources are additive and
// deduped by path: workspace members, compose build services, Dockerfile
// directories, then a root fallback.
func deriveApps(idx *index, ws string) ([]App, []string) {
	var warns []string
	byPath := map[string]*App{}

	add := func(rel, reason string) *App {
		rel = path.Clean(rel)
		if a, ok := byPath[rel]; ok {
			a.Reasons = append(a.Reasons, reason)
			return a
		}
		a := &App{Path: rel, Reasons: []string{reason}}
		byPath[rel] = a
		return a
	}

	// 1. Workspace members.
	for _, member := range workspaceMembers(idx, ws) {
		if lang, _ := languageOf(idx, member); lang == "" {
			continue // no language marker — not a buildable member
		}
		if isLibraryPath(member) && !idx.has(member, "Dockerfile") {
			continue
		}
		add(member, "workspace member ("+ws+")")
	}

	// 2. Compose services with a build context. Monorepos routinely
	// build from the repo root (`context: .`) with the Dockerfile inside
	// the app dir (`dockerfile: apps/shell/Dockerfile`) so the build can
	// reach workspace-level files — the app lives where the Dockerfile
	// is, not at the context root.
	for _, svc := range composeBuildServices(idx) {
		appDir := svc.context
		if svc.dockerfile != "" {
			if d := path.Clean(path.Join(svc.context, path.Dir(svc.dockerfile))); d != appDir && idx.dirs[d] {
				appDir = d
			}
		}
		a := add(appDir, fmt.Sprintf("compose service %q builds this directory", svc.name))
		if svc.port > 0 && a.Port == 0 {
			a.Port = svc.port
			a.Reasons = append(a.Reasons, fmt.Sprintf("compose publishes container port %d", svc.port))
		}
	}

	// 3. Dockerfile directories not already inside a candidate.
	for _, df := range idx.files["Dockerfile"] {
		dir := path.Dir(df)
		if coveredBy(byPath, dir) == nil {
			add(dir, "Dockerfile present")
		}
	}

	// 4. Root fallback: nothing found anywhere, but the root itself has a
	// language marker. A bare go.mod is not enough — Go library repos
	// (no main package) must not be mistaken for deployable apps.
	if len(byPath) == 0 {
		if lang, reason := languageOf(idx, "."); lang != "" {
			if lang == "go" && !goRootLooksRunnable(idx) {
				warns = append(warns, "go module at repo root has no main-package indicator (Dockerfile, cmd/, or main.go) — not treating it as an app; declare it in sandboxctl.yaml if it is one")
			} else {
				add(".", reason)
			}
		}
	}

	apps := make([]App, 0, len(byPath))
	for _, a := range byPath {
		apps = append(apps, *a)
	}
	return apps, warns
}

// coveredBy returns the candidate app whose path contains dir, if any.
func coveredBy(byPath map[string]*App, dir string) *App {
	for p, a := range byPath {
		if p == dir || p == "." || strings.HasPrefix(dir+"/", p+"/") {
			return a
		}
	}
	return nil
}

// goRootLooksRunnable reports whether the repo root plausibly builds a
// runnable Go program rather than a library.
func goRootLooksRunnable(idx *index) bool {
	return idx.has(".", "Dockerfile") || idx.dirs["cmd"] || idx.has(".", "main.go")
}

func isLibraryPath(rel string) bool {
	for _, seg := range strings.Split(rel, "/") {
		if libraryDirNames[seg] {
			return true
		}
	}
	return false
}

// workspaceMembers expands the workspace definition into member dirs.
func workspaceMembers(idx *index, ws string) []string {
	switch ws {
	case "pnpm":
		var doc struct {
			Packages []string `yaml:"packages"`
		}
		_ = yaml.Unmarshal(idx.read(idx.pathOf(".", "pnpm-workspace.yaml")), &doc)
		return expandGlobs(idx, doc.Packages)
	case "npm-workspaces", "lerna", "nx", "turbo":
		globs := packageJSONWorkspaces(idx.read(idx.pathOf(".", "package.json")))
		if len(globs) == 0 && ws == "lerna" {
			globs = lernaPackages(idx.read(idx.pathOf(".", "lerna.json")))
		}
		if len(globs) == 0 {
			// Task runners without explicit globs: fall back to the
			// conventional apps/* + packages/* pair.
			globs = []string{"apps/*", "packages/*"}
		}
		return expandGlobs(idx, globs)
	case "go.work":
		return goWorkUses(idx.read(idx.pathOf(".", "go.work")))
	case "go-multi-module":
		var out []string
		for _, p := range subdirGoMods(idx) {
			out = append(out, path.Dir(p))
		}
		return out
	case "cargo":
		return expandGlobs(idx, cargoMembers(idx.read(idx.pathOf(".", "Cargo.toml"))))
	}
	return nil
}

// packageJSONWorkspaces handles both shapes:
//
//	"workspaces": ["apps/*"]
//	"workspaces": { "packages": ["apps/*"] }
func packageJSONWorkspaces(data []byte) []string {
	var flat struct {
		Workspaces []string `json:"workspaces"`
	}
	if jsonUnmarshal(data, &flat) && len(flat.Workspaces) > 0 {
		return flat.Workspaces
	}
	var nested struct {
		Workspaces struct {
			Packages []string `json:"packages"`
		} `json:"workspaces"`
	}
	if jsonUnmarshal(data, &nested) {
		return nested.Workspaces.Packages
	}
	return nil
}

func lernaPackages(data []byte) []string {
	var doc struct {
		Packages []string `json:"packages"`
	}
	jsonUnmarshal(data, &doc)
	return doc.Packages
}

// goWorkUses extracts `use` directives (both single-line and block form).
func goWorkUses(data []byte) []string {
	var out []string
	inBlock := false
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		switch {
		case strings.HasPrefix(line, "use ("):
			inBlock = true
		case inBlock && line == ")":
			inBlock = false
		case inBlock && line != "" && !strings.HasPrefix(line, "//"):
			out = append(out, cleanUsePath(line))
		case strings.HasPrefix(line, "use "):
			out = append(out, cleanUsePath(strings.TrimPrefix(line, "use ")))
		}
	}
	return out
}

func cleanUsePath(s string) string {
	s = strings.TrimSpace(s)
	s = strings.Trim(s, `"`)
	return path.Clean(strings.TrimPrefix(s, "./"))
}

// cargoMembers extracts the members array from a workspace Cargo.toml
// with a tolerant line scan (a full TOML parser is not worth a
// dependency for one array of strings).
func cargoMembers(data []byte) []string {
	s := string(data)
	i := strings.Index(s, "members")
	if i < 0 {
		return nil
	}
	open := strings.Index(s[i:], "[")
	if open < 0 {
		return nil
	}
	end := strings.Index(s[i+open:], "]")
	if end < 0 {
		return nil
	}
	var out []string
	for _, part := range strings.Split(s[i+open+1:i+open+end], ",") {
		part = strings.TrimSpace(strings.Trim(strings.TrimSpace(part), `"'`))
		if part != "" {
			out = append(out, part)
		}
	}
	return out
}

// expandGlobs resolves workspace glob patterns against the walked dir
// set. Supports the common shapes: literal dirs, `dir/*`, and `dir/**`
// (any depth). Exclusion patterns (`!…`) remove prior matches.
func expandGlobs(idx *index, patterns []string) []string {
	matched := map[string]bool{}
	for _, pat := range patterns {
		neg := strings.HasPrefix(pat, "!")
		pat = path.Clean(strings.TrimPrefix(pat, "!"))
		for dir := range idx.dirs {
			if dir == "." || !globMatch(pat, dir) {
				continue
			}
			if neg {
				delete(matched, dir)
			} else {
				matched[dir] = true
			}
		}
	}
	out := make([]string, 0, len(matched))
	for d := range matched {
		out = append(out, d)
	}
	sort.Strings(out)
	return out
}

func globMatch(pat, dir string) bool {
	if strings.HasSuffix(pat, "/**") {
		prefix := strings.TrimSuffix(pat, "/**")
		return dir == prefix || strings.HasPrefix(dir, prefix+"/")
	}
	ok, err := path.Match(pat, dir)
	return err == nil && ok
}

// ----------------------------------------------------------------------------
// compose parsing
// ----------------------------------------------------------------------------

type composeService struct {
	name       string
	context    string // repo-relative build context
	dockerfile string // context-relative Dockerfile path, "" for the default
	port       int    // container port, 0 when unknown
}

func composeBuildServices(idx *index) []composeService {
	var file string
	for _, base := range []string{"docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml"} {
		if p := idx.pathOf(".", base); p != "" {
			file = p
			break
		}
	}
	if file == "" {
		return nil
	}
	var doc struct {
		Services map[string]struct {
			Build any   `yaml:"build"`
			Ports []any `yaml:"ports"`
		} `yaml:"services"`
	}
	if err := yaml.Unmarshal(idx.read(file), &doc); err != nil {
		return nil
	}
	names := make([]string, 0, len(doc.Services))
	for name := range doc.Services {
		names = append(names, name)
	}
	sort.Strings(names)

	var out []composeService
	for _, name := range names {
		svc := doc.Services[name]
		ctx, df := composeBuildSpec(svc.Build)
		if ctx == "" {
			continue // image-only service (a dependency, not the user's app)
		}
		out = append(out, composeService{
			name:       name,
			context:    path.Clean(strings.TrimPrefix(ctx, "./")),
			dockerfile: df,
			port:       composeContainerPort(svc.Ports),
		})
	}
	return out
}

func composeBuildSpec(build any) (context, dockerfile string) {
	switch b := build.(type) {
	case string:
		return b, ""
	case map[string]any:
		c, _ := b["context"].(string)
		d, _ := b["dockerfile"].(string)
		return c, d
	}
	return "", ""
}

// composeContainerPort extracts the first container-side port from the
// service's ports list. Handles "8080:80", "80", 80, "127.0.0.1:8080:80",
// "8080:80/tcp", and the long form { target: 80 }.
func composeContainerPort(ports []any) int {
	for _, p := range ports {
		switch v := p.(type) {
		case int:
			return v
		case string:
			s := strings.SplitN(v, "/", 2)[0]
			parts := strings.Split(s, ":")
			if n := atoi(parts[len(parts)-1]); n > 0 {
				return n
			}
		case map[string]any:
			switch t := v["target"].(type) {
			case int:
				return t
			case string:
				if n := atoi(t); n > 0 {
					return n
				}
			}
		}
	}
	return 0
}

func atoi(s string) int {
	n := 0
	for _, r := range s {
		if r < '0' || r > '9' {
			return 0
		}
		n = n*10 + int(r-'0')
	}
	return n
}
