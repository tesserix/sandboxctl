// Package secretsgen turns the env variables discovered by envscan into
// a k8s/secrets.example.yaml template (one Secret per app, stringData
// so values are pasted in plain text) plus the .gitignore lines that
// must exist before anyone copies it to a real k8s/secrets.yaml. Pure
// model→ops; the safe-write engine owns what actually lands on disk.
package secretsgen

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/tesserix/sandboxctl/cli/internal/genwrite"
	"github.com/tesserix/sandboxctl/cli/internal/reposcan"
)

// Generator tag recorded in the ownership marker.
const Generator = "scaffold"

// ExamplePath is where the template lands, matching the deploy flow's
// existing convention (ensure_secrets_for_namespace).
const ExamplePath = "k8s/secrets.example.yaml"

// gitignoreLines are ensured whenever a secrets template is generated,
// so the real file can never be committed by accident.
var gitignoreLines = []string{"k8s/secrets.yaml", ".env"}

// Skip explains why no template op was produced.
type Skip struct {
	Reason string
}

// SecretName returns the per-app Secret name the charts wire to.
func SecretName(app string) string { return app + "-secrets" }

// Ops plans the secrets template + gitignore writes. Nothing is
// produced when no app references a secret-like variable, or when the
// repo already manages its secrets files (either the example or the
// real file exists — both are user territory once present).
func Ops(root string, apps []reposcan.App) ([]genwrite.Op, *Skip) {
	for _, existing := range []string{"k8s/secrets.yaml", ExamplePath} {
		if _, err := os.Stat(filepath.Join(root, filepath.FromSlash(existing))); err == nil {
			return nil, &Skip{Reason: existing + " already exists — secrets stay under your management"}
		}
	}

	withSecrets := 0
	for _, app := range apps {
		if len(secretRefs(app)) > 0 {
			withSecrets++
		}
	}
	if withSecrets == 0 {
		return nil, &Skip{Reason: "no secret-like environment variables detected"}
	}

	body := render(apps)
	ops := []genwrite.Op{
		// .gitignore first: the ignore rule must exist before anything
		// invites the user to create the real file.
		{Path: ".gitignore", Append: gitignoreLines, Reason: "keep k8s/secrets.yaml and .env out of git"},
		{Path: ExamplePath, Body: []byte(body), Generator: Generator,
			Reason: fmt.Sprintf("secret template — %d app(s) reference secret-like variables", withSecrets)},
	}
	return ops, nil
}

func secretRefs(app reposcan.App) []reposcan.EnvRef {
	var out []reposcan.EnvRef
	for _, ref := range app.Env {
		if ref.Secret {
			out = append(out, ref)
		}
	}
	return out
}

func configRefs(app reposcan.App) []reposcan.EnvRef {
	var out []reposcan.EnvRef
	for _, ref := range app.Env {
		if !ref.Secret {
			out = append(out, ref)
		}
	}
	return out
}

// render emits the multi-document template. Values are stringData —
// plain text, no base64 gymnastics — and every key carries a provenance
// comment naming where it was first referenced. The `<required — …>`
// placeholders are refused by the deploy-time validation until filled.
func render(apps []reposcan.App) string {
	var b strings.Builder
	b.WriteString("# Secret template generated from environment variables referenced in\n")
	b.WriteString("# the code. To use it:\n")
	b.WriteString("#\n")
	b.WriteString("#   1. cp k8s/secrets.example.yaml k8s/secrets.yaml   (gitignored)\n")
	b.WriteString("#   2. fill each value in PLAIN TEXT — stringData handles encoding\n")
	b.WriteString("#   3. 'sandboxctl deploy' applies it into each app's namespace and\n")
	b.WriteString("#      refuses to run while <required — …> placeholders remain\n")
	b.WriteString("#\n")
	b.WriteString("# Non-secret configuration lives in each chart's values.yaml env list,\n")
	b.WriteString("# not here.\n")

	for _, app := range apps {
		secrets := secretRefs(app)
		if len(secrets) == 0 {
			continue
		}
		b.WriteString("---\n")
		b.WriteString("apiVersion: v1\n")
		b.WriteString("kind: Secret\n")
		b.WriteString("metadata:\n")
		fmt.Fprintf(&b, "  name: %s\n", SecretName(app.Name))
		fmt.Fprintf(&b, "  namespace: %s   # rewritten to the target namespace at deploy time\n", app.Name)
		b.WriteString("type: Opaque\n")
		b.WriteString("stringData:\n")
		for _, ref := range secrets {
			fmt.Fprintf(&b, "  %s: \"<required — referenced at %s>\"\n", ref.Name, ref.Location)
		}
		if cfg := configRefs(app); len(cfg) > 0 {
			fmt.Fprintf(&b, "  # non-secret config detected for %s (belongs in chart values, listed for reference):\n", app.Name)
			for _, ref := range cfg {
				fmt.Fprintf(&b, "  #   %s (%s)\n", ref.Name, ref.Location)
			}
		}
	}
	return b.String()
}
