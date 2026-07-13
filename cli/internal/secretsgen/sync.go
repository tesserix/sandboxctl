package secretsgen

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"

	"github.com/tesserix/sandboxctl/cli/internal/genwrite"
	"github.com/tesserix/sandboxctl/cli/internal/reposcan"
)

// RealPath is where the filled, gitignored secrets live.
const RealPath = "k8s/secrets.yaml"

// SyncReport says what a SyncSecretsFile pass did — sources only,
// never values.
type SyncReport struct {
	Filled []string // "DATABASE_URL ← secret cnpg/app-db key uri"
	Left   []string // variables still carrying placeholders
	Action string   // "created" | "updated" | "unchanged" | "skipped: <why>"
}

// SyncSecretsFile creates or updates k8s/secrets.yaml with resolved
// values:
//
//   - absent → generated from the app model with resolved values
//     substituted and placeholders for the rest (ownership marker, so
//     later refreshes are safe)
//   - present → surgical: ONLY values still matching the
//     `<required — …>` placeholder are replaced, in place, comments and
//     user edits untouched — whoever filled a value owns it forever
//
// The example file is never touched: it stays the committed, valueless
// template.
func SyncSecretsFile(root string, apps []reposcan.App, res map[string]Resolution) *SyncReport {
	rep := &SyncReport{Action: "unchanged"}
	target := filepath.Join(root, filepath.FromSlash(RealPath))

	if _, err := os.Stat(target); err != nil {
		// No real file yet: only worth creating when something resolved —
		// a file of pure placeholders is what the example already is.
		if len(res) == 0 {
			rep.Action = "skipped: nothing resolved and no k8s/secrets.yaml to update"
			return rep
		}
		body := renderResolved(apps, res, rep)
		plan, err := genwrite.BuildPlan(root, []genwrite.Op{{
			Path: RealPath, Body: []byte(body), Generator: Generator,
			Reason: "secrets filled from the sandbox cluster",
		}})
		if err != nil {
			rep.Action = "skipped: " + err.Error()
			return rep
		}
		if _, err := genwrite.Apply(plan, genwrite.Options{}); err != nil {
			rep.Action = "skipped: " + err.Error()
			return rep
		}
		rep.Action = "created"
		return rep
	}

	// Existing file: fill placeholders in place.
	data, err := os.ReadFile(target)
	if err != nil {
		rep.Action = "skipped: " + err.Error()
		return rep
	}
	updated, filled, left := fillPlaceholders(data, res)
	rep.Filled, rep.Left = filled, left
	if len(filled) == 0 {
		return rep
	}
	tmp := target + ".tmp"
	if err := os.WriteFile(tmp, updated, 0o600); err != nil {
		rep.Action = "skipped: " + err.Error()
		return rep
	}
	if err := os.Rename(tmp, target); err != nil {
		os.Remove(tmp)
		rep.Action = "skipped: " + err.Error()
		return rep
	}
	rep.Action = "updated"
	return rep
}

// renderResolved renders the secrets file from the app model with
// resolved values inlined.
func renderResolved(apps []reposcan.App, res map[string]Resolution, rep *SyncReport) string {
	var b strings.Builder
	b.WriteString("# Filled secrets for the sandbox — gitignored, never commit this file.\n")
	b.WriteString("# Values marked 'resolved from …' were read from the sandbox cluster;\n")
	b.WriteString("# fill the remaining <required — …> placeholders by hand. Re-running\n")
	b.WriteString("# 'sandboxctl scaffold' only ever fills placeholders, never overwrites\n")
	b.WriteString("# a value someone set.\n")
	for _, app := range apps {
		secrets := secretRefs(app)
		if len(secrets) == 0 {
			continue
		}
		b.WriteString("---\n")
		b.WriteString("apiVersion: v1\nkind: Secret\nmetadata:\n")
		fmt.Fprintf(&b, "  name: %s\n", SecretName(app.Name))
		fmt.Fprintf(&b, "  namespace: %s   # rewritten to the target namespace at deploy time\n", app.Name)
		b.WriteString("type: Opaque\nstringData:\n")
		for _, ref := range secrets {
			if r, ok := res[ref.Name]; ok {
				fmt.Fprintf(&b, "  %s: %s   # resolved from %s\n", ref.Name, yamlQuote(r.Value), r.Source)
				rep.Filled = append(rep.Filled, ref.Name+" ← "+r.Source)
			} else {
				fmt.Fprintf(&b, "  %s: \"<required — referenced at %s>\"\n", ref.Name, ref.Location)
				rep.Left = append(rep.Left, ref.Name)
			}
		}
	}
	return b.String()
}

// fillPlaceholders walks the YAML documents and replaces stringData
// values still holding `<required — …>` with resolved values. Comments,
// ordering, and every already-set value survive untouched.
func fillPlaceholders(data []byte, res map[string]Resolution) (out []byte, filled, left []string) {
	docs := strings.Split(string(data), "\n---\n")
	for d, doc := range docs {
		var root yaml.Node
		if yaml.Unmarshal([]byte(doc), &root) != nil || len(root.Content) == 0 {
			continue
		}
		walkStringData(root.Content[0], func(key string, val *yaml.Node) {
			if !strings.HasPrefix(val.Value, "<required") {
				return
			}
			if r, ok := res[key]; ok {
				val.Value = r.Value
				val.Style = yaml.DoubleQuotedStyle
				val.LineComment = "# resolved from " + r.Source
				filled = append(filled, key+" ← "+r.Source)
			} else {
				left = append(left, key)
			}
		})
		if enc, err := yaml.Marshal(&root); err == nil {
			docs[d] = strings.TrimSuffix(string(enc), "\n")
		}
	}
	return []byte(strings.Join(docs, "\n---\n") + "\n"), filled, left
}

func walkStringData(node *yaml.Node, visit func(key string, val *yaml.Node)) {
	if node == nil || node.Kind != yaml.MappingNode {
		return
	}
	for i := 0; i+1 < len(node.Content); i += 2 {
		k, v := node.Content[i], node.Content[i+1]
		if k.Value == "stringData" && v.Kind == yaml.MappingNode {
			for j := 0; j+1 < len(v.Content); j += 2 {
				if v.Content[j+1].Kind == yaml.ScalarNode {
					visit(v.Content[j].Value, v.Content[j+1])
				}
			}
		}
	}
}

// SecretVarNames lists every secret-classified variable across apps —
// the resolution work-list.
func SecretVarNames(apps []reposcan.App) []string {
	seen := map[string]bool{}
	var out []string
	for _, app := range apps {
		for _, ref := range secretRefs(app) {
			if !seen[ref.Name] {
				seen[ref.Name] = true
				out = append(out, ref.Name)
			}
		}
	}
	return out
}

func yamlQuote(s string) string {
	n := &yaml.Node{Kind: yaml.ScalarNode, Style: yaml.DoubleQuotedStyle, Value: s}
	b, _ := yaml.Marshal(n)
	return strings.TrimSuffix(string(b), "\n")
}
