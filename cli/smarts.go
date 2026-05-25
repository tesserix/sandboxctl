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
// Tier 2B: chart-image-string walker
// ============================================================================

// chartImageString is one detected scalar whose value parses as an OCI image
// reference. Many charts (fiber, anything written before the
// `{ repository, tag }` convention took over) carry the image as one inline
// string under keys like `agentImages.agent` or `sidecars.testrepos.image`.
// We detect them so the deploy can pin them just like the structured shape.
type chartImageString struct {
	Path       string // dot-path to the scalar, e.g. "agentImages.agent"
	Key        string // the leaf key, e.g. "agent" — used by the matcher
	Repository string // pre-tag part, e.g. "ghcr.io/acme/api-gateway"
	Tag        string // empty when the value is bare repo or has only a digest
	Digest     string // sha256 hex (no "sha256:" prefix), empty when none
}

// runChartImageStrings implements `_chart-image-strings <chart-dir>`.
func runChartImageStrings(args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: sandboxctl _chart-image-strings <chart-dir>")
		return 2
	}
	chartDir := args[0]
	valsPath := filepath.Join(chartDir, "values.yaml")
	data, err := os.ReadFile(valsPath)
	if err != nil {
		if os.IsNotExist(err) {
			return 0
		}
		fmt.Fprintf(os.Stderr, "_chart-image-strings: read %s: %v\n", valsPath, err)
		return 1
	}
	var root yaml.Node
	if err := yaml.Unmarshal(data, &root); err != nil {
		fmt.Fprintf(os.Stderr, "_chart-image-strings: parse %s: %v\n", valsPath, err)
		return 1
	}
	for _, s := range findImageStrings(&root) {
		fmt.Printf("%s\t%s\t%s\t%s\t%s\n", s.Path, s.Key, s.Repository, s.Tag, s.Digest)
	}
	return 0
}

// findImageStrings walks the AST for scalar values that look like image
// references. We're deliberately conservative: only mapping values whose
// *key* hints at "image" semantics are considered. Otherwise we'd
// frequently mis-classify things like resource limits, version strings, or
// URLs as images and rewrite them at deploy time.
//
// Accepted leaf-key shapes (case-insensitive, on the *innermost* mapping
// key only — the leaf):
//
//   - "image"
//   - any key ending in "Image" / "_image" / "-image"
//   - any key under a path segment named "image" / "images" /
//     "agentImages" — the parent already says "image goes here".
//
// `repository` / `tag` keys *under* an `{ repository, tag }` group are
// deliberately excluded: those are already covered by findImageKeys, and
// double-detecting them would produce two slot candidates for one logical
// image and confuse the resolver's claim accounting.
//
// Accepted value shapes (after trim):
//
//	[<host>[:<port>]/]<path>[:<tag>][@sha256:<hex>]
//
// We require *either* a host/path with a "/" *or* a tag, to avoid
// matching plain version strings like "1.25" — and we require the leaf
// hint above so e.g. `port: 80` never sneaks in.
func findImageStrings(root *yaml.Node) []chartImageString {
	var out []chartImageString
	if root == nil || len(root.Content) == 0 {
		return out
	}
	keyPaths := make(map[string]bool)
	for _, k := range findImageKeys(root) {
		keyPaths[k.Path] = true
	}
	walkYAML(root.Content[0], nil, func(path []string, key string, value *yaml.Node) {
		if value.Kind != yaml.ScalarNode {
			return
		}
		// Skip `repository`/`tag` scalars that belong to a detected
		// `{ repository, tag }` group — those are already represented
		// by findImageKeys and re-detecting them here would produce
		// duplicate slots for the resolver.
		if (key == "repository" || key == "tag") && len(path) > 0 && keyPaths[strings.Join(path, ".")] {
			return
		}
		if !looksLikeImageKey(path, key) {
			return
		}
		repo, tag, digest, ok := parseImageRef(strings.TrimSpace(value.Value))
		if !ok {
			return
		}
		full := append(append([]string{}, path...), key)
		out = append(out, chartImageString{
			Path:       strings.Join(full, "."),
			Key:        key,
			Repository: repo,
			Tag:        tag,
			Digest:     digest,
		})
	})
	sort.Slice(out, func(i, j int) bool { return out[i].Path < out[j].Path })
	return out
}

// looksLikeImageKey returns true when the (path, key) pair is plausibly
// holding an OCI image reference. The rule set is purely structural — no
// chart-specific names — so any chart that uses common conventions
// (`image:`, `*Image:`, anything under an `image`/`images` parent) lights
// up automatically.
//
// Rules (case-insensitive):
//   - leaf key is "image"
//   - leaf key ends in "image" with a word boundary (e.g. "fooImage",
//     "foo_image", "foo-image") — but not e.g. "homepage" which contains
//     "image" embedded mid-word (the word-boundary check rejects it).
//   - any path segment is "image" or ends in "images" (e.g. "agentImages",
//     "containerImages") — the parent already says "image goes here".
func looksLikeImageKey(path []string, key string) bool {
	lkey := strings.ToLower(key)
	if lkey == "image" {
		return true
	}
	if strings.HasSuffix(lkey, "image") && len(lkey) > len("image") {
		boundary := key[len(key)-len("image")-1]
		if boundary == '_' || boundary == '-' || isUpper(boundary) {
			return true
		}
	}
	for _, seg := range path {
		lseg := strings.ToLower(seg)
		if lseg == "image" {
			return true
		}
		if strings.HasSuffix(lseg, "images") {
			return true
		}
	}
	return false
}

func isUpper(b byte) bool { return b >= 'A' && b <= 'Z' }

// parseImageRef parses [<host>[:<port>]/]<path>[:<tag>][@sha256:<hex>] and
// returns (repository-without-tag, tag, digest-hex, ok). We refuse values
// that look more like URLs ("http://..."), file paths ("./foo"), or empty
// strings.
func parseImageRef(s string) (repo, tag, digest string, ok bool) {
	if s == "" {
		return "", "", "", false
	}
	// Reject URLs and file paths up-front — those aren't image refs.
	if strings.HasPrefix(s, "http://") || strings.HasPrefix(s, "https://") ||
		strings.HasPrefix(s, "/") || strings.HasPrefix(s, "./") || strings.HasPrefix(s, "../") {
		return "", "", "", false
	}
	// Reject anything with whitespace — image refs never contain it.
	if strings.ContainsAny(s, " \t\n") {
		return "", "", "", false
	}
	work := s
	if at := strings.Index(work, "@sha256:"); at >= 0 {
		digest = work[at+len("@sha256:"):]
		work = work[:at]
		if !isHex(digest) {
			return "", "", "", false
		}
	}
	// Tag: a colon AFTER the last slash (so we don't confuse a registry
	// port like "localhost:5000/foo" for a tag).
	if colon := strings.LastIndexByte(work, ':'); colon >= 0 {
		slash := strings.LastIndexByte(work, '/')
		if colon > slash {
			tag = work[colon+1:]
			work = work[:colon]
			if tag == "" {
				return "", "", "", false
			}
		}
	}
	repo = work
	if repo == "" {
		return "", "", "", false
	}
	// Need at least a "/" (denoting host or path) OR a tag to call it
	// an image. Bare scalars like "fiber" or "1.25" are rejected.
	if !strings.Contains(repo, "/") && tag == "" && digest == "" {
		return "", "", "", false
	}
	return repo, tag, digest, true
}

func isHex(s string) bool {
	if len(s) == 0 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) {
			return false
		}
	}
	return true
}

// ============================================================================
// Tier 2C: resolve build-manifest images to chart-values pins
// ============================================================================

// resolvedPin is one (chart-group → build-image) decision. Each chart
// group is claimed at most once across the resolution: that invariant
// prevents the regression where N build images all wrote to the same
// `image.repository`/`image.tag` pair, last-write-wins.
//
// The pin is registry-agnostic by design — it only carries the build
// manifest's image *name* + tag. The shell wrapper (sandbox.sh) is what
// formats the final repository URL using the live registry host/port,
// so this helper stays portable across any sandbox configuration.
type resolvedPin struct {
	Path  string // dot-path of the chart-values key being claimed
	Kind  string // "keys" for { repository, tag } groups, "string" for inline
	Image string // build-manifest image name — caller prefixes with registry host
	Tag   string // build-manifest tag (defaults to "latest")
}

// runChartResolveImagePins implements
//
//	`_chart-resolve-image-pins <chart-dir> <build-manifest> [<chart-name>]`
//
// Output is one tab-separated line per claimed pin:
//
//	<group-path>\t<kind>\t<image>\t<repository>\t<tag>
//
// Build-manifest images that don't match any chart key produce no output:
// the chart simply has nothing to receive that image, and silently
// skipping is the correct behaviour (the alternative — emitting a
// duplicate `image.repository` pin — is exactly the v2.10.2 bug). A
// stderr diagnostic is emitted per skip so the user can see what was
// dropped and why.
func runChartResolveImagePins(args []string) int {
	if len(args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: sandboxctl _chart-resolve-image-pins <chart-dir> <build-manifest> [<chart-name>]")
		return 2
	}
	chartDir, manifestPath := args[0], args[1]
	chartName := ""
	if len(args) >= 3 {
		chartName = args[2]
	}

	// Build-manifest images.
	mdata, err := os.ReadFile(manifestPath)
	if err != nil {
		if os.IsNotExist(err) {
			return 0
		}
		fmt.Fprintf(os.Stderr, "_chart-resolve-image-pins: read %s: %v\n", manifestPath, err)
		return 1
	}
	var bm buildManifest
	if err := yaml.Unmarshal(mdata, &bm); err != nil {
		fmt.Fprintf(os.Stderr, "_chart-resolve-image-pins: parse %s: %v\n", manifestPath, err)
		return 1
	}

	// Optional chart_image_map override from the same manifest.
	var ex manifestExtras
	_ = yaml.Unmarshal(mdata, &ex)

	// Chart-values image surfaces.
	var keys []chartImageKey
	var strs []chartImageString
	if data, err := os.ReadFile(filepath.Join(chartDir, "values.yaml")); err == nil {
		var root yaml.Node
		if err := yaml.Unmarshal(data, &root); err == nil {
			keys = findImageKeys(&root)
			strs = findImageStrings(&root)
		}
	}

	pins, skipped := resolveImagePins(bm.Images, keys, strs, ex.ChartImageMap, chartName)
	for _, p := range pins {
		fmt.Printf("%s\t%s\t%s\t%s\n", p.Path, p.Kind, p.Image, p.Tag)
	}
	for _, s := range skipped {
		fmt.Fprintf(os.Stderr, "_chart-resolve-image-pins: skipped image %q — no matching chart key\n", s)
	}
	return 0
}

// resolveImagePins is the matching algorithm — split out so it's
// directly testable. The algorithm:
//
//  1. Build the candidate-pool of chart slots (keys + strs).
//  2. For each build-manifest image, claim the first matching slot:
//     a. explicit chart_image_map override (if its target slot exists)
//     b. dot-path contains a segment equal to the image name
//     c. existing repository basename equals image name (tries direct,
//     then with the chart name stripped as a prefix — fiber-claude-agent
//     vs. claude-agent)
//     d. lone `{ repository, tag }` group AND image name == chart name
//     (the legacy single-image fallback, but only for the chart's
//     namesake image — never for arbitrary other images)
//  3. Each slot can be claimed at most once. Build images that find no
//     slot are reported as skipped.
//
// Image ordering follows the build manifest, so the user sees stable
// pin assignments across deploys.
func resolveImagePins(
	images []manifestImage,
	keys []chartImageKey,
	strs []chartImageString,
	chartImageMap map[string]string,
	chartName string,
) (pins []resolvedPin, skipped []string) {
	type slot struct {
		path string
		kind string // "keys" or "string"
		repo string
	}
	slots := make([]slot, 0, len(keys)+len(strs))
	for _, k := range keys {
		slots = append(slots, slot{path: k.Path, kind: "keys", repo: k.Repository})
	}
	for _, s := range strs {
		slots = append(slots, slot{path: s.Path, kind: "string", repo: s.Repository})
	}

	claimed := make(map[string]bool, len(slots))

	findFreeSlot := func(predicate func(slot) bool) (slot, bool) {
		for _, s := range slots {
			if claimed[s.path] {
				continue
			}
			if predicate(s) {
				return s, true
			}
		}
		return slot{}, false
	}

	pins = make([]resolvedPin, 0, len(images))
	for _, img := range images {
		if img.Name == "" {
			continue
		}
		tag := img.Tag
		if tag == "" {
			tag = "latest"
		}

		var match slot
		var ok bool

		if mapped, exists := chartImageMap[img.Name]; exists && mapped != "" {
			match, ok = findFreeSlot(func(s slot) bool { return s.path == mapped })
		}

		if !ok {
			match, ok = findFreeSlot(func(s slot) bool {
				for _, seg := range strings.Split(s.path, ".") {
					if seg == img.Name {
						return true
					}
				}
				return false
			})
		}

		// Rule 2.5: dashed-image-name → trailing segment.
		// e.g. build image "agent-sdk" → chart slot "agentImages.sdk";
		//      build image "claude-agent" → chart slot "agentImages.agent".
		// We match the *last* dash-segment of the build image name
		// against any path segment of the slot. Conservative: only
		// fires when the image actually contains a dash, so plain
		// names ("api", "ui") aren't accidentally widened.
		if !ok && strings.Contains(img.Name, "-") {
			tail := img.Name[strings.LastIndexByte(img.Name, '-')+1:]
			match, ok = findFreeSlot(func(s slot) bool {
				for _, seg := range strings.Split(s.path, ".") {
					if seg == tail {
						return true
					}
				}
				return false
			})
		}

		if !ok {
			match, ok = findFreeSlot(func(s slot) bool {
				base := repoBasename(s.repo)
				if base == img.Name {
					return true
				}
				if chartName != "" {
					stripped := strings.TrimPrefix(base, chartName+"-")
					if stripped == img.Name {
						return true
					}
				}
				return false
			})
		}

		if !ok && chartName != "" && img.Name == chartName {
			// Legacy single-image fallback: only for the chart's namesake
			// image, only when the chart has exactly one { repository, tag }
			// group at top level, and only if it isn't already claimed.
			if len(keys) == 1 && keys[0].Path == "image" && !claimed[keys[0].Path] {
				match, ok = slot{path: keys[0].Path, kind: "keys", repo: keys[0].Repository}, true
			}
		}

		if !ok {
			skipped = append(skipped, img.Name)
			continue
		}
		claimed[match.path] = true
		pins = append(pins, resolvedPin{
			Path:  match.path,
			Kind:  match.kind,
			Image: img.Name,
			Tag:   tag,
		})
	}
	return pins, skipped
}

// repoBasename returns the last path segment of a repository value,
// e.g. "ghcr.io/acme/foo" → "foo". An empty string returns "".
func repoBasename(repo string) string {
	if i := strings.LastIndexByte(repo, '/'); i >= 0 {
		return repo[i+1:]
	}
	return repo
}

// ============================================================================
// Tier 1C: mimic chart values.yaml as a sandbox-local values file
// ============================================================================

// runChartMimicValues implements `_chart-mimic-values <chart-dir> <out-path> [<pin>...]`.
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
//  2. rewrite chart-values image fields to point at the in-cluster
//     registry. Two pin forms are accepted:
//
//     - heuristic:    <image-name>=<repo>:<tag>
//     The walker matches the image-name to a `{ repository, tag }`
//     group by path segment, repo basename, or lone-fallback. Kept
//     for direct callers and for backward compat.
//
//     - resolved:     --by-path <group-path>=<kind>:<repo>:<tag>
//     <kind> is "keys" (write `repository`/`tag` on the group) or
//     "string" (overwrite the inline-string scalar at <group-path>).
//     This form bypasses the heuristic — the deploy flow uses it
//     after `_chart-resolve-image-pins` has assigned each pin to
//     exactly one slot, so we never overwrite the same key twice.
//
//     Charts whose images aren't named in either form are left untouched
//     (Argo helm.parameters can still pin them).
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
		fmt.Fprintln(os.Stderr, "usage: sandboxctl _chart-mimic-values <chart-dir> <out-path> [--by-path <path>=<kind>:<repo>:<tag>] [<image>=<repo>:<tag>...]")
		return 2
	}
	chartDir, outPath := args[0], args[1]

	heuristic, resolved, err := parseMimicPins(args[2:])
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

	mutateChartValues(&root, heuristic)
	applyResolvedPins(&root, resolved)

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

// parseImagePins parses the legacy heuristic-only form, kept for
// backward compatibility with direct callers and existing tests.
func parseImagePins(args []string) (map[string]imagePin, error) {
	heuristic, resolved, err := parseMimicPins(args)
	if err != nil {
		return nil, err
	}
	if len(resolved) > 0 {
		return nil, fmt.Errorf("parseImagePins does not accept --by-path pins")
	}
	return heuristic, nil
}

// resolvedMimicPin is one pre-resolved chart-values rewrite. The mimic
// helper trusts these — the resolver upstream guarantees no two pins
// touch the same path.
type resolvedMimicPin struct {
	Path string
	Kind string // "keys" or "string"
	Repo string
	Tag  string
}

// parseMimicPins demuxes the post-positional args of _chart-mimic-values.
// Two forms coexist:
//
//	<name>=<repo>:<tag>                     → heuristic pin (legacy form)
//	--by-path <path>=<kind>:<repo>:<tag>    → already-resolved pin
//
// Multiple of either form may be passed. Pins with empty fields are
// rejected so a malformed pin can't silently no-op.
func parseMimicPins(args []string) (map[string]imagePin, []resolvedMimicPin, error) {
	heuristic := map[string]imagePin{}
	var resolved []resolvedMimicPin
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "--by-path" {
			if i+1 >= len(args) {
				return nil, nil, fmt.Errorf("--by-path needs an argument")
			}
			i++
			r, err := parseResolvedPin(args[i])
			if err != nil {
				return nil, nil, err
			}
			resolved = append(resolved, r)
			continue
		}
		eq := strings.IndexByte(a, '=')
		if eq <= 0 {
			return nil, nil, fmt.Errorf("invalid pin %q (want <name>=<repo>:<tag>)", a)
		}
		name, ref := a[:eq], a[eq+1:]
		colon := strings.LastIndexByte(ref, ':')
		repo, tag := ref, "latest"
		if colon > 0 && !strings.Contains(ref[colon:], "/") {
			repo, tag = ref[:colon], ref[colon+1:]
		}
		heuristic[name] = imagePin{Repo: repo, Tag: tag}
	}
	return heuristic, resolved, nil
}

// parseResolvedPin parses one --by-path argument:
//
//	<dot.path>=<kind>:<repo>:<tag>
//
// The format uses ':' as field separator, but `<repo>` itself often
// contains a ':' for the host port (e.g. "localhost:5050/foo"). We split
// the kind off as the first ':'-delimited field, then split tag off as
// everything *after the last ':' that isn't followed by a '/'* — which
// matches the same rule parseImageRef uses to find the tag separator in
// an image reference.
func parseResolvedPin(a string) (resolvedMimicPin, error) {
	eq := strings.IndexByte(a, '=')
	if eq <= 0 {
		return resolvedMimicPin{}, fmt.Errorf("invalid --by-path pin %q (want <path>=<kind>:<repo>:<tag>)", a)
	}
	path, rest := a[:eq], a[eq+1:]
	colon := strings.IndexByte(rest, ':')
	if colon <= 0 {
		return resolvedMimicPin{}, fmt.Errorf("invalid --by-path pin %q (need kind:repo:tag)", a)
	}
	kind := rest[:colon]
	body := rest[colon+1:]
	repo, tag, _, ok := parseImageRef(body)
	if !ok || tag == "" {
		return resolvedMimicPin{}, fmt.Errorf("invalid --by-path pin %q (could not split %q into repo:tag)", a, body)
	}
	if path == "" || repo == "" || (kind != "keys" && kind != "string") {
		return resolvedMimicPin{}, fmt.Errorf("invalid --by-path pin %q (kind must be keys|string; path/repo/tag must be non-empty)", a)
	}
	return resolvedMimicPin{Path: path, Kind: kind, Repo: repo, Tag: tag}, nil
}

// applyResolvedPins rewrites the chart values tree using the upstream-
// resolved pin list. Each pin specifies the exact dot-path of the slot
// to update, so no heuristic matching happens here. For "keys" pins we
// set/append `repository` and `tag` on the addressed mapping node; for
// "string" pins we replace the addressed scalar value.
func applyResolvedPins(root *yaml.Node, pins []resolvedMimicPin) {
	if root == nil || len(root.Content) == 0 || len(pins) == 0 {
		return
	}
	doc := root.Content[0]
	for _, p := range pins {
		switch p.Kind {
		case "keys":
			if node := findMappingByPath(doc, strings.Split(p.Path, ".")); node != nil {
				setMappingScalar(node, "repository", p.Repo)
				setMappingScalar(node, "tag", p.Tag)
			}
		case "string":
			ref := p.Repo + ":" + p.Tag
			setScalarByPath(doc, strings.Split(p.Path, "."), ref)
		}
	}
}

// findMappingByPath walks a yaml.Node mapping tree to the dot-path
// segments and returns the addressed mapping node, or nil if any segment
// doesn't resolve to a mapping along the way.
func findMappingByPath(node *yaml.Node, segs []string) *yaml.Node {
	cur := node
	for _, seg := range segs {
		if cur == nil || cur.Kind != yaml.MappingNode {
			return nil
		}
		var next *yaml.Node
		for i := 0; i+1 < len(cur.Content); i += 2 {
			k, v := cur.Content[i], cur.Content[i+1]
			if k.Kind == yaml.ScalarNode && k.Value == seg {
				next = v
				break
			}
		}
		if next == nil {
			return nil
		}
		cur = next
	}
	if cur == nil || cur.Kind != yaml.MappingNode {
		return nil
	}
	return cur
}

// setScalarByPath walks to the addressed scalar (creating no nodes —
// missing paths are silently dropped) and replaces its value.
func setScalarByPath(node *yaml.Node, segs []string, val string) {
	if len(segs) == 0 {
		return
	}
	cur := node
	for i, seg := range segs {
		if cur == nil || cur.Kind != yaml.MappingNode {
			return
		}
		for j := 0; j+1 < len(cur.Content); j += 2 {
			k, v := cur.Content[j], cur.Content[j+1]
			if k.Kind != yaml.ScalarNode || k.Value != seg {
				continue
			}
			if i == len(segs)-1 {
				if v.Kind == yaml.ScalarNode {
					v.Value = val
					v.Tag = "!!str"
					v.Style = 0
				}
				return
			}
			cur = v
			break
		}
	}
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
