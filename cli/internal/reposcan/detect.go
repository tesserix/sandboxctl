package reposcan

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

// ----------------------------------------------------------------------------
// per-app enrichment: language, framework, dockerfile, port, kind
// ----------------------------------------------------------------------------

// frameworkInfo captures what a recognized framework implies. Default
// ports are the framework's documented dev/serve default — the lowest
// tier of the port precedence (Dockerfile EXPOSE and compose ports both
// beat it).
type frameworkInfo struct {
	name string
	port int
	kind string // "" means: decide by port ("http" when set, else "worker")
}

// enrichApp fills language/framework/dockerfile/port/kind on a derived
// app. Port precedence (each tier only fires when the previous left the
// port unset): compose (recorded during derivation) → Dockerfile EXPOSE
// → framework default.
func enrichApp(idx *index, a *App) {
	lang, langReason := languageOf(idx, a.Path)
	if lang != "" {
		a.Language = lang
		a.Reasons = append(a.Reasons, langReason)
	}

	fw := detectFramework(idx, a.Path, lang)
	if fw.name != "" {
		a.Framework = fw.name
		a.Reasons = append(a.Reasons, "framework "+fw.name+" detected in dependencies")
	}

	if df := idx.pathOf(a.Path, "Dockerfile"); df != "" {
		a.Dockerfile = df
		if a.Port == 0 {
			if port := dockerfileExposedPort(idx, df); port > 0 {
				a.Port = port
				a.Reasons = append(a.Reasons, fmt.Sprintf("EXPOSE %d in %s", port, df))
			}
		}
	}

	if a.Port == 0 && fw.port > 0 {
		a.Port = fw.port
		a.Reasons = append(a.Reasons, fmt.Sprintf("framework default port %d (%s)", fw.port, fw.name))
	}

	switch {
	case fw.kind != "":
		a.Kind = fw.kind
	case a.Port > 0:
		a.Kind = "http"
	default:
		a.Kind = "worker"
	}

	if a.Name == "" {
		a.Name = slugify(baseName(idx.root, a.Path))
	}
}

// languageOf identifies the language of the code in dir from marker
// files, most-specific first. The returned reason names the marker.
func languageOf(idx *index, dir string) (string, string) {
	switch {
	case idx.has(dir, "go.mod"):
		return "go", "go.mod present"
	case idx.has(dir, "package.json"):
		if idx.has(dir, "tsconfig.json") {
			return "ts", "package.json + tsconfig.json present"
		}
		return "js", "package.json present"
	case idx.has(dir, "pyproject.toml"):
		return "python", "pyproject.toml present"
	case idx.has(dir, "requirements.txt"):
		return "python", "requirements.txt present"
	case idx.has(dir, "Cargo.toml"):
		return "rust", "Cargo.toml present"
	case idx.has(dir, "pom.xml"):
		return "java", "pom.xml present"
	case idx.has(dir, "build.gradle") || idx.has(dir, "build.gradle.kts"):
		return "java", "gradle build file present"
	case idx.has(dir, "Gemfile"):
		return "ruby", "Gemfile present"
	}
	for _, p := range idx.files[".csproj"] {
		if path.Dir(p) == dir {
			return "dotnet", path.Base(p) + " present"
		}
	}
	return "", ""
}

// dependency-marker tables per language. Order matters: the first match
// wins, so more specific frameworks come before the generic ones they
// embed (next before react, fastapi before flask's shared deps, …).
var (
	goFrameworks = []struct{ marker, name string }{
		{"github.com/gin-gonic/gin", "gin"},
		{"github.com/labstack/echo", "echo"},
		{"github.com/gofiber/fiber", "fiber"},
		{"github.com/go-chi/chi", "chi"},
	}
	jsFrameworks = []struct {
		dep  string
		info frameworkInfo
	}{
		{"next", frameworkInfo{name: "next", port: 3000, kind: "http"}},
		{"@nestjs/core", frameworkInfo{name: "nestjs", port: 3000}},
		{"fastify", frameworkInfo{name: "fastify", port: 3000}},
		{"express", frameworkInfo{name: "express", port: 3000}},
		{"vite", frameworkInfo{name: "vite", kind: "frontend"}},
		{"react", frameworkInfo{name: "react", kind: "frontend"}},
	}
	pyFrameworks = []struct {
		marker, name string
		port         int
	}{
		{"fastapi", "fastapi", 8000},
		{"django", "django", 8000},
		{"flask", "flask", 5000},
	}
)

func detectFramework(idx *index, dir, lang string) frameworkInfo {
	switch lang {
	case "go":
		content := string(idx.read(idx.pathOf(dir, "go.mod")))
		for _, f := range goFrameworks {
			if strings.Contains(content, f.marker) {
				// Go web frameworks have no fixed default port — the
				// port must come from EXPOSE, compose, or an override.
				return frameworkInfo{name: f.name}
			}
		}
	case "js", "ts":
		deps := packageJSONDeps(idx.read(idx.pathOf(dir, "package.json")))
		for _, f := range jsFrameworks {
			if _, ok := deps[f.dep]; ok {
				return f.info
			}
		}
	case "python":
		content := string(idx.read(idx.pathOf(dir, "pyproject.toml"))) +
			string(idx.read(idx.pathOf(dir, "requirements.txt")))
		for _, f := range pyFrameworks {
			if strings.Contains(strings.ToLower(content), f.marker) {
				return frameworkInfo{name: f.name, port: f.port}
			}
		}
	case "rust":
		content := string(idx.read(idx.pathOf(dir, "Cargo.toml")))
		for _, name := range []string{"axum", "actix-web", "rocket"} {
			if strings.Contains(content, name) {
				return frameworkInfo{name: strings.TrimSuffix(name, "-web")}
			}
		}
	case "java":
		content := string(idx.read(idx.pathOf(dir, "pom.xml"))) +
			string(idx.read(idx.pathOf(dir, "build.gradle"))) +
			string(idx.read(idx.pathOf(dir, "build.gradle.kts")))
		if strings.Contains(content, "spring-boot") {
			return frameworkInfo{name: "spring", port: 8080}
		}
	case "ruby":
		if strings.Contains(string(idx.read(idx.pathOf(dir, "Gemfile"))), "rails") {
			return frameworkInfo{name: "rails", port: 3000}
		}
	}
	return frameworkInfo{}
}

func packageJSONDeps(data []byte) map[string]string {
	var doc struct {
		Dependencies    map[string]string `json:"dependencies"`
		DevDependencies map[string]string `json:"devDependencies"`
	}
	if !jsonUnmarshal(data, &doc) {
		return nil
	}
	out := make(map[string]string, len(doc.Dependencies)+len(doc.DevDependencies))
	for k, v := range doc.DevDependencies {
		out[k] = v
	}
	for k, v := range doc.Dependencies {
		out[k] = v
	}
	return out
}

// dockerfileExposedPort returns the first literal port from an EXPOSE
// instruction. Variable ports (`EXPOSE $PORT`) are skipped — guessing a
// build-arg value would be worse than reporting nothing.
func dockerfileExposedPort(idx *index, rel string) int {
	f, err := os.Open(filepath.Join(idx.root, filepath.FromSlash(rel)))
	if err != nil {
		return 0
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 1<<24)
	for sc.Scan() {
		fields := strings.Fields(strings.TrimSpace(sc.Text()))
		if len(fields) < 2 || !strings.EqualFold(fields[0], "EXPOSE") {
			continue
		}
		for _, arg := range fields[1:] {
			arg = strings.SplitN(arg, "/", 2)[0]
			if n := atoi(arg); n > 0 {
				return n
			}
		}
	}
	return 0
}

// ----------------------------------------------------------------------------
// existing artefact association
// ----------------------------------------------------------------------------

// attachExisting links each app to a chart / GitOps dir that already
// covers it, so generators know what to skip. Association rules, in
// order: artefact inside the app dir; k8s/charts/<app-name>;
// k8s/chart when the repo has exactly one app; same ladder for
// k8s/gitops/<app-name>.
func attachExisting(idx *index, apps []App) {
	single := len(apps) == 1
	for i := range apps {
		a := &apps[i]

		for _, cd := range idx.chartDirs {
			if cd == a.Path || strings.HasPrefix(cd, a.Path+"/") {
				a.Existing.Chart = cd
				a.Reasons = append(a.Reasons, "existing chart at "+cd)
				break
			}
		}
		if a.Existing.Chart == "" {
			if cd := "k8s/charts/" + a.Name; idx.dirs[cd] && hasChart(idx, cd) {
				a.Existing.Chart = cd
				a.Reasons = append(a.Reasons, "existing chart at "+cd)
			} else if single && hasChart(idx, "k8s/chart") {
				a.Existing.Chart = "k8s/chart"
				a.Reasons = append(a.Reasons, "existing chart at k8s/chart")
			}
		}

		if gd := "k8s/gitops/" + a.Name; idx.dirs[gd] {
			a.Existing.GitOps = gd
		} else if single && idx.dirs["k8s/gitops"] {
			a.Existing.GitOps = "k8s/gitops"
		}
		if a.Existing.GitOps != "" {
			a.Reasons = append(a.Reasons, "existing GitOps manifests at "+a.Existing.GitOps)
		}
	}
}

func hasChart(idx *index, dir string) bool { return idx.has(dir, "Chart.yaml") }

// ----------------------------------------------------------------------------
// sandboxctl.yaml overrides
// ----------------------------------------------------------------------------

// appOverride is one entry under `apps:` in sandboxctl.yaml. Every field
// beats detection; entries whose path matches nothing declare a new app.
type appOverride struct {
	Path      string `yaml:"path"`
	Name      string `yaml:"name"`
	Language  string `yaml:"language"`
	Framework string `yaml:"framework"`
	Port      int    `yaml:"port"`
	Kind      string `yaml:"kind"`
}

var overrideFields = map[string]bool{
	"path": true, "name": true, "language": true,
	"framework": true, "port": true, "kind": true,
}

// applyOverrides reads the `apps:` section of sandboxctl.yaml (when
// present) and applies it over the detected apps. Unknown fields warn
// rather than fail — a typo should never abort an analysis.
func applyOverrides(idx *index, apps *[]App) []string {
	var manifest string
	for _, base := range []string{"sandboxctl.yaml", "sandboxctl.yml"} {
		if p := idx.pathOf(".", base); p != "" {
			manifest = p
			break
		}
	}
	if manifest == "" {
		return nil
	}

	var raw struct {
		Apps []map[string]any `yaml:"apps"`
	}
	if err := yaml.Unmarshal(idx.read(manifest), &raw); err != nil || len(raw.Apps) == 0 {
		return nil
	}

	var warns []string
	for i, entry := range raw.Apps {
		var ov appOverride
		for k, v := range entry {
			if !overrideFields[k] {
				warns = append(warns, fmt.Sprintf("%s: apps[%d]: unknown field %q (ignored)", manifest, i, k))
				continue
			}
			switch k {
			case "path":
				ov.Path, _ = v.(string)
			case "name":
				ov.Name, _ = v.(string)
			case "language":
				ov.Language, _ = v.(string)
			case "framework":
				ov.Framework, _ = v.(string)
			case "kind":
				ov.Kind, _ = v.(string)
			case "port":
				switch n := v.(type) {
				case int:
					ov.Port = n
				case string:
					ov.Port = atoi(n)
				}
			}
		}
		if ov.Path == "" && ov.Name == "" {
			warns = append(warns, fmt.Sprintf("%s: apps[%d]: needs a path or name to match", manifest, i))
			continue
		}
		if ov.Path != "" {
			ov.Path = path.Clean(strings.TrimPrefix(ov.Path, "./"))
		}

		target := matchOverride(*apps, ov)
		if target == nil {
			// A path that matched nothing declares a new app. A
			// name-only entry can't — there is no directory to attach
			// it to.
			if ov.Path == "" {
				warns = append(warns, fmt.Sprintf("%s: apps[%d]: name %q matches no detected app (add a path to declare a new one)", manifest, i, ov.Name))
				continue
			}
			*apps = append(*apps, App{
				Path:    ov.Path,
				Reasons: []string{"declared in " + manifest},
			})
			target = &(*apps)[len(*apps)-1]
		}
		applyOverride(target, ov, manifest)
	}
	return warns
}

func matchOverride(apps []App, ov appOverride) *App {
	for i := range apps {
		if ov.Path != "" && ov.Path != "." && apps[i].Path == ov.Path {
			return &apps[i]
		}
	}
	if ov.Path == "." {
		for i := range apps {
			if apps[i].Path == "." {
				return &apps[i]
			}
		}
	}
	if ov.Name != "" {
		for i := range apps {
			if apps[i].Name == ov.Name {
				return &apps[i]
			}
		}
	}
	return nil
}

func applyOverride(a *App, ov appOverride, source string) {
	set := func(field string) { a.Reasons = append(a.Reasons, field+" overridden in "+source) }
	if ov.Name != "" && ov.Name != a.Name {
		a.Name = slugify(ov.Name)
		set("name")
	}
	if ov.Language != "" {
		a.Language = ov.Language
		set("language")
	}
	if ov.Framework != "" {
		a.Framework = ov.Framework
		set("framework")
	}
	if ov.Port > 0 {
		a.Port = ov.Port
		set("port")
	}
	if ov.Kind != "" {
		a.Kind = ov.Kind
		set("kind")
	}
	if a.Kind == "" {
		if a.Port > 0 {
			a.Kind = "http"
		} else {
			a.Kind = "worker"
		}
	}
}

// ----------------------------------------------------------------------------
// naming helpers
// ----------------------------------------------------------------------------

// dedupeNames suffixes later duplicates with -2, -3, … (apps are already
// path-sorted, so the suffix assignment is deterministic).
func dedupeNames(apps []App) {
	taken := map[string]int{}
	for i := range apps {
		base := apps[i].Name
		if n := taken[base]; n > 0 {
			apps[i].Name = fmt.Sprintf("%s-%d", base, n+1)
		}
		taken[base]++
	}
}

func baseName(root, rel string) string {
	if rel == "." {
		return filepath.Base(root)
	}
	return path.Base(rel)
}

// slugify matches sandbox.sh's slugify(): lowercase, non-alphanumerics
// collapse to '-', trimmed. Kept in lockstep so analyzer names line up
// with build/deploy names.
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

// jsonUnmarshal is a strictness-relaxed unmarshal: returns false on
// error instead of propagating it, since marker files are user-authored
// and a malformed one should degrade detection, not abort it.
func jsonUnmarshal(data []byte, v any) bool {
	if len(bytes.TrimSpace(data)) == 0 {
		return false
	}
	return json.Unmarshal(data, v) == nil
}
