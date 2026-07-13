// Package envscan discovers the environment variables a repo's apps
// reference and classifies each as secret-like or plain configuration.
// It reads source files (which reposcan deliberately does not), never
// reads values from a real .env, and never talks to a cluster. Results
// feed the secrets template generator and the chart generator's
// envFrom wiring.
package envscan

import (
	"bufio"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"gopkg.in/yaml.v3"

	"github.com/tesserix/sandboxctl/cli/internal/reposcan"
)

// maxFileSize caps how much of any one source file is scanned.
const maxFileSize = 1 << 20

// skipDirs mirrors reposcan's exclusion set, plus manifest dirs whose
// env blocks would only echo what we generate.
var skipDirs = map[string]bool{
	".git": true, "node_modules": true, "vendor": true, "dist": true,
	"k8s": true, "charts": true, "testdata": true,
}

// noiseVars are ambient shell/runtime variables that would only clutter
// the report; they are never worth templating.
var noiseVars = map[string]bool{
	"PATH": true, "HOME": true, "PWD": true, "TMPDIR": true,
	"TERM": true, "USER": true, "SHELL": true, "HOSTNAME": true,
}

// secretNameRe marks a variable as secret-like from its name alone.
var secretNameRe = regexp.MustCompile(`(?i)(` +
	`SECRET|TOKEN|PASSWORD|PASSWD|PRIVATE|CREDENTIAL|CERT|SALT|SIGNING|LICENSE|` +
	`API_?KEY|ACCESS_KEY|AUTH` +
	`)`)

// connStringRe marks connection strings (which conventionally embed
// credentials) as secret-like: DATABASE_URL, REDIS_URI, PG_DSN, …
var connStringRe = regexp.MustCompile(`(?i)^(DATABASE|DB|POSTGRES|PG|MYSQL|MONGO|REDIS|AMQP|BROKER|NATS|KAFKA)_?(URL|URI|DSN|CONN(ECTION)?_?STRING)$`)

// varNameRe is the shape of an environment variable name we accept.
// Uppercase-only filters out dynamic lookups and locals.
var varNameRe = `[A-Z][A-Z0-9_]*`

// per-language reference patterns. Each must capture the variable name
// in group 1.
var sourcePatterns = map[string][]*regexp.Regexp{
	"go": {
		regexp.MustCompile(`os\.(?:Getenv|LookupEnv)\(\s*"(` + varNameRe + `)"`),
		regexp.MustCompile(`env:"(` + varNameRe + `)`),
	},
	"js": {
		regexp.MustCompile(`process\.env\.(` + varNameRe + `)\b`),
		regexp.MustCompile(`process\.env\[["'](` + varNameRe + `)["']`),
		regexp.MustCompile(`import\.meta\.env\.(` + varNameRe + `)\b`),
	},
	"python": {
		regexp.MustCompile(`os\.environ\.get\(\s*["'](` + varNameRe + `)["']`),
		regexp.MustCompile(`os\.environ\[["'](` + varNameRe + `)["']`),
		regexp.MustCompile(`os\.getenv\(\s*["'](` + varNameRe + `)["']`),
	},
}

var extToLang = map[string]string{
	".go": "go",
	".js": "js", ".jsx": "js", ".ts": "js", ".tsx": "js", ".mjs": "js", ".cjs": "js",
	".py": "python",
}

var dotenvExampleNames = map[string]bool{
	".env.example": true, ".env.sample": true, ".env.template": true,
}

var dotenvKeyRe = regexp.MustCompile(`^\s*(?:export\s+)?(` + varNameRe + `)\s*=`)

var dockerfileEnvRe = regexp.MustCompile(`^\s*(?:ENV|ARG)\s+(` + varNameRe + `)`)

// Overrides pins classifications from sandboxctl.yaml:
//
//	secrets:
//	  include: [SOME_VAR]   # force secret
//	  exclude: [OTHER_VAR]  # force plain config
type Overrides struct {
	Include []string `yaml:"include"`
	Exclude []string `yaml:"exclude"`
}

// Attach scans the tree under model.Root and fills each app's Env list.
// Attribution is by longest matching app path; refs in files outside
// every app dir (shared libraries in a monorepo) are dropped — the app
// that consumes the library names its own variables in practice.
func Attach(model *reposcan.Model) []string {
	refs, warnings := scan(model.Root, loadOverrides(model.Root))

	// Longest path first so nested apps win attribution.
	order := make([]int, len(model.Apps))
	for i := range order {
		order[i] = i
	}
	sort.Slice(order, func(a, b int) bool {
		return len(model.Apps[order[a]].Path) > len(model.Apps[order[b]].Path)
	})

	for _, r := range refs {
		for _, i := range order {
			app := &model.Apps[i]
			if r.compose != "" {
				// Compose refs carry the service name; match by app name.
				if r.compose == app.Name {
					addRef(app, r.ref)
					break
				}
				continue
			}
			dir := path.Dir(r.ref.Location[:strings.LastIndexByte(r.ref.Location, ':')])
			if app.Path == "." || dir == app.Path || strings.HasPrefix(dir, app.Path+"/") {
				addRef(app, r.ref)
				break
			}
		}
	}

	for i := range model.Apps {
		sort.Slice(model.Apps[i].Env, func(a, b int) bool {
			return model.Apps[i].Env[a].Name < model.Apps[i].Env[b].Name
		})
	}
	return warnings
}

func addRef(app *reposcan.App, ref reposcan.EnvRef) {
	for _, have := range app.Env {
		if have.Name == ref.Name {
			return // first reference wins (walk order is deterministic)
		}
	}
	app.Env = append(app.Env, ref)
}

// scannedRef pairs a ref with its compose service name when the ref
// came from a compose file (path-based attribution doesn't apply there).
type scannedRef struct {
	ref     reposcan.EnvRef
	compose string
}

func scan(root string, ov Overrides) ([]scannedRef, []string) {
	var (
		refs     []scannedRef
		warnings []string
	)
	classify := classifier(ov)

	_ = filepath.WalkDir(root, func(p string, d os.DirEntry, err error) error {
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
			return nil
		}

		base := d.Name()
		switch {
		case dotenvExampleNames[base]:
			refs = append(refs, fileRefs(root, rel, "dotenv", dotenvLineRefs, classify)...)
		case base == "Dockerfile":
			refs = append(refs, fileRefs(root, rel, "dockerfile", dockerfileLineRefs, classify)...)
		case rel == "docker-compose.yml" || rel == "docker-compose.yaml" ||
			rel == "compose.yml" || rel == "compose.yaml":
			refs = append(refs, composeRefs(root, rel, classify)...)
		default:
			lang := extToLang[strings.ToLower(filepath.Ext(base))]
			if lang == "" {
				return nil
			}
			refs = append(refs, fileRefs(root, rel, lang, func(line string) []string {
				return matchAll(sourcePatterns[lang], line)
			}, classify)...)
		}
		return nil
	})

	return refs, warnings
}

// fileRefs scans one file line-by-line with the given extractor. Files
// over the size cap (generated bundles, lockfiles) are skipped whole.
func fileRefs(root, rel, source string, extract func(string) []string, classify func(string) bool) []scannedRef {
	full := filepath.Join(root, filepath.FromSlash(rel))
	if st, err := os.Stat(full); err != nil || st.Size() > maxFileSize {
		return nil
	}
	f, err := os.Open(full)
	if err != nil {
		return nil
	}
	defer f.Close()

	var out []scannedRef
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64*1024), maxFileSize)
	lineNo := 0
	for sc.Scan() {
		lineNo++
		line := sc.Text()
		if lineNo == 1 && strings.ContainsRune(line, '\x00') {
			return nil // binary
		}
		for _, name := range extract(line) {
			if noiseVars[name] {
				continue
			}
			out = append(out, scannedRef{ref: reposcan.EnvRef{
				Name:     name,
				Location: rel + ":" + strconv.Itoa(lineNo),
				Source:   source,
				Secret:   classify(name),
			}})
		}
	}
	return out
}

func dotenvLineRefs(line string) []string {
	if m := dotenvKeyRe.FindStringSubmatch(line); m != nil {
		return []string{m[1]}
	}
	return nil
}

func dockerfileLineRefs(line string) []string {
	if m := dockerfileEnvRe.FindStringSubmatch(line); m != nil {
		return []string{m[1]}
	}
	return nil
}

func matchAll(patterns []*regexp.Regexp, line string) []string {
	var out []string
	for _, re := range patterns {
		for _, m := range re.FindAllStringSubmatch(line, -1) {
			out = append(out, m[1])
		}
	}
	return out
}

// composeRefs extracts `environment:` keys per service. Attribution is
// by service name (matched against app names by Attach).
func composeRefs(root, rel string, classify func(string) bool) []scannedRef {
	data, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(rel)))
	if err != nil || len(data) > maxFileSize {
		return nil
	}
	var doc struct {
		Services map[string]struct {
			Environment any `yaml:"environment"`
		} `yaml:"services"`
	}
	if yaml.Unmarshal(data, &doc) != nil {
		return nil
	}

	names := make([]string, 0, len(doc.Services))
	for n := range doc.Services {
		names = append(names, n)
	}
	sort.Strings(names)

	var out []scannedRef
	for _, svc := range names {
		for _, key := range composeEnvKeys(doc.Services[svc].Environment) {
			if noiseVars[key] {
				continue
			}
			out = append(out, scannedRef{
				compose: svc,
				ref: reposcan.EnvRef{
					Name:     key,
					Location: rel + ":services." + svc,
					Source:   "compose",
					Secret:   classify(key),
				},
			})
		}
	}
	return out
}

// composeEnvKeys handles both the map form (KEY: value) and the list
// form (["KEY=value", "FLAG"]).
func composeEnvKeys(env any) []string {
	nameRe := regexp.MustCompile(`^(` + varNameRe + `)`)
	var out []string
	switch e := env.(type) {
	case map[string]any:
		for k := range e {
			if nameRe.MatchString(k) {
				out = append(out, nameRe.FindString(k))
			}
		}
		sort.Strings(out)
	case []any:
		for _, item := range e {
			s, ok := item.(string)
			if !ok {
				continue
			}
			if m := nameRe.FindString(strings.SplitN(s, "=", 2)[0]); m != "" {
				out = append(out, m)
			}
		}
	}
	return out
}

// classifier builds the secret/config decision function: overrides win,
// then the name heuristics.
func classifier(ov Overrides) func(string) bool {
	include := map[string]bool{}
	exclude := map[string]bool{}
	for _, v := range ov.Include {
		include[strings.ToUpper(v)] = true
	}
	for _, v := range ov.Exclude {
		exclude[strings.ToUpper(v)] = true
	}
	return func(name string) bool {
		switch {
		case include[name]:
			return true
		case exclude[name]:
			return false
		default:
			return secretNameRe.MatchString(name) || connStringRe.MatchString(name)
		}
	}
}

func loadOverrides(root string) Overrides {
	var doc struct {
		Secrets Overrides `yaml:"secrets"`
	}
	for _, base := range []string{"sandboxctl.yaml", "sandboxctl.yml"} {
		if data, err := os.ReadFile(filepath.Join(root, base)); err == nil {
			_ = yaml.Unmarshal(data, &doc)
			break
		}
	}
	return doc.Secrets
}
