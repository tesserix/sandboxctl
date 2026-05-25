package main

// "Smarts" — hidden subcommands invoked by sandbox.sh during `deploy` to make
// the deploy adapt to whatever shape the user's chart already has, instead
// of forcing them to learn sandboxctl conventions.
//
// All four helpers are pure functions of (chart files, manifest, kubectl
// service JSON) → tab-separated stdout. Bash captures the lines and turns
// them into `helm --set` arguments or VirtualService routing decisions.
// Keeping the logic in Go means we can unit-test it (see smarts_test.go)
// and avoid yet another fragile sed/awk pipeline in the shell script.
//
// Hidden subcommands wired in main.go:
//
//	_chart-ingress-overrides <chart-dir>
//	    Print one line per `*.ingress.enabled=true` or `*.enabled=true`
//	    near an Ingress-shaped block in values.yaml. Bash flips each to
//	    false via --set so chart-shipped Ingress templates stay dormant
//	    while sandboxctl owns external routing via Istio VirtualService.
//
//	_chart-image-keys <chart-dir>
//	    Walk values.yaml for nodes shaped like `{ repository: ..., tag: ... }`.
//	    Print one line per detected image group:
//	        <dot-path>\t<repository>\t<tag>
//	    Bash matches the build-manifest image names against these groups
//	    and emits `--set <path>.repository=...` for each pinning.
//
//	_score-services <chart-name>
//	    Read kubectl service JSON from stdin, score each service for
//	    "primary service" likelihood, print sorted:
//	        <name>\t<port>\t<score>\t<reasons>
//	    Bash picks the top-scored one as the VirtualService destination.
//
//	_manifest-extras <manifest-path>
//	    Print user-provided overrides from sandboxctl.yaml as KEY=VALUE
//	    lines (primary_service, chart_image_map). Empty stdout when the
//	    manifest doesn't exist or sets nothing — bash treats that as
//	    "no overrides".

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

// ============================================================================
// Tier 1A: chart-shipped Ingress detection
// ============================================================================

// runChartIngressOverrides implements `_chart-ingress-overrides <chart-dir>`.
//
// We deliberately probe values.yaml rather than `helm template` output: the
// goal is to disable the toggle, not enumerate rendered manifests. A chart
// without a values.yaml toggle (Ingress always rendered) can't be disabled
// from outside — we emit a diagnostic and let the caller decide.
func runChartIngressOverrides(args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: sandboxctl _chart-ingress-overrides <chart-dir>")
		return 2
	}
	chartDir := args[0]
	valsPath := filepath.Join(chartDir, "values.yaml")
	data, err := os.ReadFile(valsPath)
	if err != nil {
		// Missing values.yaml is fine — emit nothing.
		if os.IsNotExist(err) {
			return 0
		}
		fmt.Fprintf(os.Stderr, "_chart-ingress-overrides: read %s: %v\n", valsPath, err)
		return 1
	}
	var root yaml.Node
	if err := yaml.Unmarshal(data, &root); err != nil {
		fmt.Fprintf(os.Stderr, "_chart-ingress-overrides: parse %s: %v\n", valsPath, err)
		return 1
	}
	for _, path := range findIngressToggles(&root) {
		fmt.Println(path)
	}
	return 0
}

// findIngressToggles walks the YAML AST looking for boolean `enabled: true`
// entries whose key-path contains a segment named (case-insensitive)
// "ingress". Returns dot-paths suitable for `helm --set <path>=false`.
//
// Examples that match:
//
//	ingress: { enabled: true }                  → "ingress.enabled"
//	global: { ingress: { enabled: true } }      → "global.ingress.enabled"
//	ui: { ingress: { create: true } }           → "ui.ingress.create"
//
// We also accept the alias `create: true` since some chart authors use it
// instead of `enabled`. Anything already false is skipped (no point
// emitting a redundant override).
func findIngressToggles(root *yaml.Node) []string {
	var out []string
	if root == nil || len(root.Content) == 0 {
		return out
	}
	walkYAML(root.Content[0], nil, func(path []string, key string, value *yaml.Node) {
		// Only care about scalar booleans that gate a section.
		if value.Kind != yaml.ScalarNode {
			return
		}
		if key != "enabled" && key != "create" {
			return
		}
		if !strings.EqualFold(value.Value, "true") {
			return
		}
		// The toggle key itself is `enabled` / `create`; the *containing*
		// path is what we need to check for an "ingress" segment.
		ingressSeen := false
		for _, seg := range path {
			if strings.EqualFold(seg, "ingress") {
				ingressSeen = true
				break
			}
		}
		if !ingressSeen {
			return
		}
		dot := strings.Join(append(append([]string{}, path...), key), ".")
		out = append(out, dot)
	})
	sort.Strings(out)
	return out
}

// ============================================================================
// Tier 2: chart-image-key walker
// ============================================================================

// chartImageKey is one detected `{ repository: ..., tag: ... }` group.
type chartImageKey struct {
	Path       string // dot-path to the group, e.g. "backend.image" or "image"
	Repository string
	Tag        string
}

// runChartImageKeys implements `_chart-image-keys <chart-dir>`.
func runChartImageKeys(args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: sandboxctl _chart-image-keys <chart-dir>")
		return 2
	}
	chartDir := args[0]
	valsPath := filepath.Join(chartDir, "values.yaml")
	data, err := os.ReadFile(valsPath)
	if err != nil {
		if os.IsNotExist(err) {
			return 0
		}
		fmt.Fprintf(os.Stderr, "_chart-image-keys: read %s: %v\n", valsPath, err)
		return 1
	}
	var root yaml.Node
	if err := yaml.Unmarshal(data, &root); err != nil {
		fmt.Fprintf(os.Stderr, "_chart-image-keys: parse %s: %v\n", valsPath, err)
		return 1
	}
	for _, k := range findImageKeys(&root) {
		fmt.Printf("%s\t%s\t%s\n", k.Path, k.Repository, k.Tag)
	}
	return 0
}

// findImageKeys walks the YAML AST for mapping nodes whose direct children
// include a `repository:` scalar. Such nodes are conventionally Helm image
// groups (the chart-best-practices shape Bitnami popularised). We accept
// missing tag (defaulted to empty); bash callers may default to "latest".
//
// The detected group's *path* is what callers want for --set. For example
// a group at `backend.image` becomes:
//
//	--set backend.image.repository=...
//	--set backend.image.tag=...
//
// Top-level `image: { repository: ..., tag: ... }` is detected as path "image".
func findImageKeys(root *yaml.Node) []chartImageKey {
	var out []chartImageKey
	if root == nil || len(root.Content) == 0 {
		return out
	}
	walkMappings(root.Content[0], nil, func(path []string, node *yaml.Node) {
		repo, tag, ok := mappingImageFields(node)
		if !ok {
			return
		}
		out = append(out, chartImageKey{
			Path:       strings.Join(path, "."),
			Repository: repo,
			Tag:        tag,
		})
	})
	sort.Slice(out, func(i, j int) bool { return out[i].Path < out[j].Path })
	return out
}

func mappingImageFields(node *yaml.Node) (repo, tag string, ok bool) {
	if node == nil || node.Kind != yaml.MappingNode {
		return "", "", false
	}
	for i := 0; i+1 < len(node.Content); i += 2 {
		k, v := node.Content[i], node.Content[i+1]
		if k.Kind != yaml.ScalarNode {
			continue
		}
		switch k.Value {
		case "repository":
			if v.Kind == yaml.ScalarNode {
				repo = v.Value
			}
		case "tag":
			if v.Kind == yaml.ScalarNode {
				tag = v.Value
			}
		}
	}
	return repo, tag, repo != ""
}

// ============================================================================
// Tier 1C: mimic chart values.yaml as a sandbox-local values file
// ============================================================================

// runChartMimicValues implements `_chart-mimic-values <chart-dir> <out-path> [<image>=<repo>:<tag>...]`.
//
// Generates a sandbox-flavoured values file by copying the chart's
// values.yaml and applying two non-destructive edits:
//
//  1. flip every detected Ingress toggle (`*.ingress.enabled`,
//     `*.ingress.create`) to false — sandboxctl owns external routing
//     via the per-app Istio VirtualService, so chart-shipped Ingress
//     templates would either fight the VirtualService or stall waiting
//     for an IngressClass that this cluster does not ship;
//
//  2. rewrite each `{ repository, tag }` image group whose containing
//     path or repository basename matches one of the supplied
//     `<image>=<repo>:<tag>` pins. Pins typically come from the build
//     manifest; charts whose images are not in the build manifest are
//     left untouched (Argo helm.parameters can still pin them).
//
// Output is written atomically (tempfile + rename) so a partially-written
// file can never replace a good values file. The file is intentionally
// committed-friendly: yaml.v3 round-trips comments and key ordering.
//
// Exits 0 when the file is written, 0 (no-op) when the chart has no
// values.yaml at all (a perfectly valid Helm chart shape), and non-zero
// only on real I/O or parse failures.
func runChartMimicValues(args []string) int {
	if len(args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: sandboxctl _chart-mimic-values <chart-dir> <out-path> [<image>=<repo>:<tag>...]")
		return 2
	}
	chartDir, outPath := args[0], args[1]
	pins, err := parseImagePins(args[2:])
	if err != nil {
		fmt.Fprintf(os.Stderr, "_chart-mimic-values: %v\n", err)
		return 2
	}

	valsPath := filepath.Join(chartDir, "values.yaml")
	data, err := os.ReadFile(valsPath)
	if err != nil {
		if os.IsNotExist(err) {
			return 0
		}
		fmt.Fprintf(os.Stderr, "_chart-mimic-values: read %s: %v\n", valsPath, err)
		return 1
	}

	var root yaml.Node
	if err := yaml.Unmarshal(data, &root); err != nil {
		fmt.Fprintf(os.Stderr, "_chart-mimic-values: parse %s: %v\n", valsPath, err)
		return 1
	}

	mutateChartValues(&root, pins)

	out, err := yaml.Marshal(&root)
	if err != nil {
		fmt.Fprintf(os.Stderr, "_chart-mimic-values: marshal: %v\n", err)
		return 1
	}

	header := []byte("# Auto-generated by sandboxctl from values.yaml.\n" +
		"# Edits land here on the next deploy; commit this file if you want them to stick.\n" +
		"# Ingress toggles are forced off (sandboxctl owns routing via Istio).\n" +
		"# Image repositories are pinned to the in-cluster registry where the build manifest matches.\n\n")
	out = append(header, out...)

	if err := writeAtomic(outPath, out); err != nil {
		fmt.Fprintf(os.Stderr, "_chart-mimic-values: write %s: %v\n", outPath, err)
		return 1
	}
	fmt.Println(outPath)
	return 0
}

type imagePin struct {
	Repo string
	Tag  string
}

// parseImagePins accepts <image-name>=<repo>:<tag> tokens. The image-name
// is matched against the dot-path of the image group (any path segment
// equal to the name) and the basename of the existing repository value.
func parseImagePins(args []string) (map[string]imagePin, error) {
	out := map[string]imagePin{}
	for _, a := range args {
		eq := strings.IndexByte(a, '=')
		if eq <= 0 {
			return nil, fmt.Errorf("invalid pin %q (want <name>=<repo>:<tag>)", a)
		}
		name, ref := a[:eq], a[eq+1:]
		colon := strings.LastIndexByte(ref, ':')
		repo, tag := ref, "latest"
		if colon > 0 && !strings.Contains(ref[colon:], "/") {
			repo, tag = ref[:colon], ref[colon+1:]
		}
		out[name] = imagePin{Repo: repo, Tag: tag}
	}
	return out, nil
}

// mutateChartValues walks the parsed values.yaml node and applies the
// two sandbox-flavour edits in a single pass. Both edits operate on the
// original yaml.Node tree so comments + key ordering are preserved on
// re-marshal.
func mutateChartValues(root *yaml.Node, pins map[string]imagePin) {
	if root == nil || len(root.Content) == 0 {
		return
	}
	doc := root.Content[0]

	walkYAML(doc, nil, func(path []string, key string, value *yaml.Node) {
		if value.Kind != yaml.ScalarNode {
			return
		}
		if key != "enabled" && key != "create" {
			return
		}
		if !strings.EqualFold(value.Value, "true") {
			return
		}
		for _, seg := range path {
			if strings.EqualFold(seg, "ingress") {
				value.Value = "false"
				value.Tag = "!!bool"
				return
			}
		}
	})

	if len(pins) == 0 {
		return
	}
	walkMappings(doc, nil, func(path []string, node *yaml.Node) {
		repo, _, ok := mappingImageFields(node)
		if !ok {
			return
		}
		pin, ok := lookupPin(pins, path, repo)
		if !ok {
			return
		}
		setMappingScalar(node, "repository", pin.Repo)
		setMappingScalar(node, "tag", pin.Tag)
	})
}

// lookupPin matches an image group to a pin by:
//
//  1. exact match on any path segment (e.g. group at backend.image
//     matches pin "backend"), or
//  2. exact match on the basename of the existing repository value
//     (e.g. existing repo "ghcr.io/acme/ui" matches pin "ui"), or
//  3. fallback to the lone pin when there is exactly one and the chart
//     has a single image group at top level (path == ["image"]).
func lookupPin(pins map[string]imagePin, path []string, repo string) (imagePin, bool) {
	for _, seg := range path {
		if p, ok := pins[seg]; ok {
			return p, true
		}
	}
	if repo != "" {
		base := repo
		if i := strings.LastIndexByte(repo, '/'); i >= 0 {
			base = repo[i+1:]
		}
		if p, ok := pins[base]; ok {
			return p, true
		}
	}
	if len(pins) == 1 && len(path) == 1 && path[0] == "image" {
		for _, p := range pins {
			return p, true
		}
	}
	return imagePin{}, false
}

// setMappingScalar sets (or appends) a scalar key on a mapping node.
// Used so we don't drop existing comments or sibling keys when we
// rewrite repository / tag.
func setMappingScalar(node *yaml.Node, key, val string) {
	for i := 0; i+1 < len(node.Content); i += 2 {
		k, v := node.Content[i], node.Content[i+1]
		if k.Kind == yaml.ScalarNode && k.Value == key {
			v.Kind = yaml.ScalarNode
			v.Tag = "!!str"
			v.Value = val
			v.Style = 0
			return
		}
	}
	node.Content = append(node.Content,
		&yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: key},
		&yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: val},
	)
}

// writeAtomic writes data to path via tempfile + rename so a crash mid-write
// leaves the previous file intact.
func writeAtomic(path string, data []byte) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".sandboxctl-values-*.tmp")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmpPath)
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpPath)
		return err
	}
	return os.Rename(tmpPath, path)
}

// ============================================================================
// Tier 1B: primary-service scoring
// ============================================================================

// k8sService is the trimmed JSON shape we care about from `kubectl get svc`.
type k8sService struct {
	Metadata struct {
		Name        string            `json:"name"`
		Annotations map[string]string `json:"annotations"`
		Labels      map[string]string `json:"labels"`
	} `json:"metadata"`
	Spec struct {
		Type     string `json:"type"`
		Selector map[string]string
		Ports    []struct {
			Port       int    `json:"port"`
			TargetPort any    `json:"targetPort"`
			Protocol   string `json:"protocol"`
			Name       string `json:"name"`
		} `json:"ports"`
	} `json:"spec"`
}

type k8sServiceList struct {
	Items []k8sService `json:"items"`
}

// scoredService is the row we emit per service.
type scoredService struct {
	Name    string
	Port    int
	Score   int
	Reasons []string
}

// runScoreServices implements `_score-services <chart-name>` reading
// kubectl service JSON from stdin.
func runScoreServices(args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: sandboxctl _score-services <chart-name>  (kubectl JSON on stdin)")
		return 2
	}
	chart := args[0]
	data, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintf(os.Stderr, "_score-services: read stdin: %v\n", err)
		return 1
	}
	var list k8sServiceList
	if err := json.Unmarshal(data, &list); err != nil {
		fmt.Fprintf(os.Stderr, "_score-services: parse JSON: %v\n", err)
		return 1
	}
	scored := scoreServices(chart, list.Items)
	for _, s := range scored {
		fmt.Printf("%s\t%d\t%d\t%s\n", s.Name, s.Port, s.Score, strings.Join(s.Reasons, "; "))
	}
	return 0
}

// scoreServices ranks services for "primary" likelihood. Higher = more
// likely. Ties broken alphabetically (stable, predictable). The heuristic
// is deliberately tunable rather than absolute — chart authors who care
// can pin with the `sandboxctl.io/primary: "true"` annotation, which
// short-circuits everything else.
func scoreServices(chart string, svcs []k8sService) []scoredService {
	out := make([]scoredService, 0, len(svcs))
	for _, s := range svcs {
		name := s.Metadata.Name
		score := 0
		var reasons []string

		// Explicit user override — wins decisively.
		if v := s.Metadata.Annotations["sandboxctl.io/primary"]; strings.EqualFold(v, "true") {
			score += 1000
			reasons = append(reasons, "annotation sandboxctl.io/primary=true")
		}

		// Exact name match (legacy behaviour).
		if name == chart {
			score += 100
			reasons = append(reasons, "name == chart")
		} else if strings.HasSuffix(name, "-"+chart) || strings.HasPrefix(name, chart+"-") {
			score += 40
			reasons = append(reasons, "name adjacent to chart")
		}

		// Web-port hints. We only credit ports the chart actually exposes.
		port := 0
		for _, p := range s.Spec.Ports {
			if port == 0 {
				port = p.Port
			}
			switch p.Port {
			case 80, 8080, 3000, 8081, 5000, 8000:
				score += 30
				reasons = append(reasons, fmt.Sprintf("web port %d", p.Port))
				// Only credit once per service even if multiple matching ports.
				goto portsDone
			}
			if strings.EqualFold(p.Name, "http") || strings.EqualFold(p.Name, "web") {
				score += 25
				reasons = append(reasons, "port name http/web")
				goto portsDone
			}
		}
	portsDone:

		// Name-keyword hints. UI-like names win against backend-like names
		// to nudge the heuristic toward the user-facing entrypoint.
		lname := strings.ToLower(name)
		uiHints := []string{"ui", "web", "frontend", "app", "client"}
		apiHints := []string{"backend", "api", "worker", "grpc", "db", "cache", "queue", "redis", "postgres", "mysql"}
		for _, h := range uiHints {
			if containsToken(lname, h) {
				score += 20
				reasons = append(reasons, "name contains '"+h+"'")
				break
			}
		}
		for _, h := range apiHints {
			if containsToken(lname, h) {
				score -= 30
				reasons = append(reasons, "name contains '"+h+"' (penalty)")
				break
			}
		}

		// Headless / ExternalName services are not user-facing.
		if s.Spec.Type == "ExternalName" {
			score -= 50
			reasons = append(reasons, "ExternalName type")
		}

		out = append(out, scoredService{
			Name:    name,
			Port:    port,
			Score:   score,
			Reasons: reasons,
		})
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].Score != out[j].Score {
			return out[i].Score > out[j].Score
		}
		return out[i].Name < out[j].Name
	})
	return out
}

// containsToken returns true when `needle` appears in `s` as a whole token
// delimited by start/end/non-letter chars. Avoids false positives like
// "api" matching inside "apirate" or "ui" matching "uikit-something".
func containsToken(s, needle string) bool {
	if s == needle {
		return true
	}
	for i := 0; i+len(needle) <= len(s); i++ {
		if s[i:i+len(needle)] != needle {
			continue
		}
		// Check boundaries.
		left := i == 0 || !isWordChar(s[i-1])
		right := i+len(needle) == len(s) || !isWordChar(s[i+len(needle)])
		if left && right {
			return true
		}
	}
	return false
}

func isWordChar(b byte) bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9')
}

// ============================================================================
// Tier 3: explicit overrides from sandboxctl.yaml
// ============================================================================

// manifestExtras holds the optional override fields. Kept separate from
// manifestImage so the existing _parse-build-manifest output stays stable.
type manifestExtras struct {
	PrimaryService string            `yaml:"primary_service,omitempty"`
	ChartImageMap  map[string]string `yaml:"chart_image_map,omitempty"`
}

// runManifestExtras implements `_manifest-extras <manifest-path>`.
//
// Emits one KEY=VALUE line per set field. ChartImageMap is flattened as
// chart_image_map.<image>=<chart-values-group>. Empty / missing manifest
// yields zero lines (exit 0) — bash treats absence as "no overrides".
func runManifestExtras(args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: sandboxctl _manifest-extras <manifest-path>")
		return 2
	}
	path := args[0]
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return 0
		}
		fmt.Fprintf(os.Stderr, "_manifest-extras: read %s: %v\n", path, err)
		return 1
	}
	var ex manifestExtras
	if err := yaml.Unmarshal(data, &ex); err != nil {
		fmt.Fprintf(os.Stderr, "_manifest-extras: parse %s: %v\n", path, err)
		return 1
	}
	if ex.PrimaryService != "" {
		fmt.Printf("primary_service=%s\n", ex.PrimaryService)
	}
	// Sort the map for deterministic output (useful in tests).
	keys := make([]string, 0, len(ex.ChartImageMap))
	for k := range ex.ChartImageMap {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		fmt.Printf("chart_image_map.%s=%s\n", k, ex.ChartImageMap[k])
	}
	return 0
}

// ============================================================================
// shared YAML walkers
// ============================================================================

// walkYAML walks a yaml.Node tree invoking visit(path, key, value) for every
// mapping entry (key,value) pair. Sequence entries are walked recursively
// but never invoke visit themselves (we have no use for indexed paths
// here).
func walkYAML(node *yaml.Node, path []string, visit func(path []string, key string, value *yaml.Node)) {
	if node == nil {
		return
	}
	switch node.Kind {
	case yaml.DocumentNode:
		for _, c := range node.Content {
			walkYAML(c, path, visit)
		}
	case yaml.MappingNode:
		for i := 0; i+1 < len(node.Content); i += 2 {
			k, v := node.Content[i], node.Content[i+1]
			if k.Kind != yaml.ScalarNode {
				continue
			}
			visit(path, k.Value, v)
			if v.Kind == yaml.MappingNode || v.Kind == yaml.SequenceNode {
				walkYAML(v, append(path, k.Value), visit)
			}
		}
	case yaml.SequenceNode:
		for _, c := range node.Content {
			walkYAML(c, path, visit)
		}
	}
}

// walkMappings walks just mapping nodes, invoking visit(path, mappingNode)
// for each. Used by findImageKeys to inspect candidate `{ repository: ... }`
// containers without needing to know every parent key.
func walkMappings(node *yaml.Node, path []string, visit func(path []string, mapping *yaml.Node)) {
	if node == nil {
		return
	}
	switch node.Kind {
	case yaml.DocumentNode:
		for _, c := range node.Content {
			walkMappings(c, path, visit)
		}
	case yaml.MappingNode:
		visit(path, node)
		for i := 0; i+1 < len(node.Content); i += 2 {
			k, v := node.Content[i], node.Content[i+1]
			if k.Kind != yaml.ScalarNode {
				continue
			}
			walkMappings(v, append(path, k.Value), visit)
		}
	case yaml.SequenceNode:
		for _, c := range node.Content {
			walkMappings(c, path, visit)
		}
	}
}
