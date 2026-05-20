package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// runAutogenManifest is invoked as `sandboxctl _autogen-manifest <target>`.
// It scans <target> for Dockerfiles, infers a build context per Dockerfile
// by parsing COPY/ADD sources and walking up to the smallest ancestor
// directory in which every source resolves, derives a slugified image
// name per Dockerfile (collision-suffixed), and writes a sandboxctl.yaml
// to <target>/sandboxctl.yaml. Output: the path of the file written, on
// stdout. Warnings (e.g. unresolvable sources) go to stderr.
//
// Hidden subcommand — driven by sandbox.sh's cmd_build when no manifest
// is present but Dockerfiles exist. End users never type this directly.
func runAutogenManifest(args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: sandboxctl _autogen-manifest <target>")
		return 2
	}
	target, err := filepath.Abs(args[0])
	if err != nil {
		fmt.Fprintf(os.Stderr, "_autogen-manifest: resolve %s: %v\n", args[0], err)
		return 1
	}
	st, err := os.Stat(target)
	if err != nil || !st.IsDir() {
		fmt.Fprintf(os.Stderr, "_autogen-manifest: %s is not a directory\n", target)
		return 1
	}

	dockerfiles, err := findDockerfiles(target)
	if err != nil {
		fmt.Fprintf(os.Stderr, "_autogen-manifest: scan %s: %v\n", target, err)
		return 1
	}
	if len(dockerfiles) == 0 {
		fmt.Fprintf(os.Stderr, "_autogen-manifest: no Dockerfiles under %s\n", target)
		return 1
	}

	imgs, warnings := buildAutogenImages(target, dockerfiles)
	for _, w := range warnings {
		fmt.Fprintf(os.Stderr, "_autogen-manifest: %s\n", w)
	}
	if len(imgs) == 0 {
		fmt.Fprintf(os.Stderr, "_autogen-manifest: produced no images\n")
		return 1
	}

	out := filepath.Join(target, "sandboxctl.yaml")
	if err := writeAutogenManifest(out, imgs); err != nil {
		fmt.Fprintf(os.Stderr, "_autogen-manifest: write %s: %v\n", out, err)
		return 1
	}
	fmt.Println(out)
	return 0
}

// findDockerfiles walks <root> and returns paths of files literally named
// "Dockerfile". The exclusion set matches sandbox.sh's auto-walk so the
// generated manifest covers the same set of images.
func findDockerfiles(root string) ([]string, error) {
	var out []string
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() {
			switch d.Name() {
			case ".git", "node_modules", "vendor", "dist":
				return filepath.SkipDir
			}
			return nil
		}
		if d.Name() == "Dockerfile" {
			out = append(out, path)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.Strings(out)
	return out, nil
}

// buildAutogenImages turns each Dockerfile into a manifestImage by
// inferring its context, then deduplicates names with a -2 / -3 suffix.
// Returned warnings are descriptive (e.g. "couldn't resolve <src>").
//
// After the per-file pass, runs resolveCrossRefs to detect Dockerfiles
// that `FROM <sibling-image>` and fills in aliases on producers +
// depends_on on consumers, then topologically sorts so producers come
// before consumers (cmd_build_from_manifest validates that order).
func buildAutogenImages(target string, dockerfiles []string) ([]manifestImage, []string) {
	var (
		imgs     []manifestImage
		dfPaths  []string
		warnings []string
		taken    = map[string]int{}
	)
	for _, df := range dockerfiles {
		srcs, parseWarn := parseDockerfileLocalSources(df)
		warnings = append(warnings, parseWarn...)

		ctx, ctxWarn := inferBuildContext(target, df, srcs)
		if ctxWarn != "" {
			warnings = append(warnings, ctxWarn)
		}

		name := imageNameFor(target, df, ctx)
		base := name
		if n := taken[base]; n > 0 {
			name = fmt.Sprintf("%s-%d", base, n+1)
		}
		taken[base]++

		ctxRel, err := filepath.Rel(target, ctx)
		if err != nil || ctxRel == "" {
			ctxRel = "."
		}
		dfRel, err := filepath.Rel(ctx, df)
		if err != nil {
			dfRel = "Dockerfile"
		}

		img := manifestImage{Name: name, Context: ctxRel}
		// Only emit `dockerfile:` when it's not the default
		// `<context>/Dockerfile`. Keeps output minimal.
		if dfRel != "Dockerfile" {
			img.Dockerfile = filepath.ToSlash(filepath.Join(ctxRel, dfRel))
		}
		imgs = append(imgs, img)
		dfPaths = append(dfPaths, df)
	}

	imgs, crossWarn := resolveCrossRefs(imgs, dfPaths, filepath.Base(target))
	warnings = append(warnings, crossWarn...)
	imgs, sortWarn := topoSortImages(imgs)
	warnings = append(warnings, sortWarn...)
	return imgs, warnings
}

// resolveCrossRefs scans each image's Dockerfile for `FROM <ref>` lines
// and, when ref points at a sibling image in the same manifest, fills
// in:
//
//   - producer.Aliases   ← the bare ref (so `podman build -t <ref>`
//     makes the consumer's FROM resolve locally)
//   - consumer.DependsOn ← producer.Name (build-order enforcement)
//
// Sibling matching (against the bare repo portion of the ref, after
// stripping registry/host/tag/digest):
//
//  1. exact slug match against an image's Name
//  2. <projectBase>- prefix stripped, then exact slug match
//     (so `fiber-agent-sdk` matches image `agent-sdk` when the
//     project's top-level dir is `fiber`)
//
// Existing aliases / depends_on entries are preserved. Refs that look
// like external registry images (docker.io/foo, gcr.io/bar, …) are
// never matched.
func resolveCrossRefs(imgs []manifestImage, dfPaths []string, projectBase string) ([]manifestImage, []string) {
	var warnings []string
	if len(imgs) != len(dfPaths) {
		return imgs, warnings
	}
	byName := map[string]int{}
	for i, img := range imgs {
		byName[img.Name] = i
	}
	prefix := slugifyName(projectBase) + "-"

	for i, df := range dfPaths {
		refs, refWarn := parseDockerfileFromRefs(df)
		warnings = append(warnings, refWarn...)
		for _, ref := range refs {
			producer, ok := matchSibling(ref, byName, prefix)
			if !ok || producer == i {
				continue
			}
			imgs[producer].Aliases = appendUnique(imgs[producer].Aliases, ref)
			imgs[i].DependsOn = appendUnique(imgs[i].DependsOn, imgs[producer].Name)
		}
	}
	return imgs, warnings
}

// matchSibling tries to identify an image in the manifest that produces
// `ref`. Returns its index in `imgs` (the slice the byName map was
// derived from). Registry-qualified refs are filtered out.
func matchSibling(ref string, byName map[string]int, projectPrefix string) (int, bool) {
	repo, _ := splitImageRef(ref)
	if repo == "" {
		return 0, false
	}
	// External registry refs (e.g. docker.io/x, gcr.io/x, localhost:5050/x)
	// never match a sibling image. The first segment is the registry host
	// when it contains a `.`, `:`, or is the literal "localhost".
	if i := strings.Index(repo, "/"); i >= 0 {
		host := repo[:i]
		if host == "localhost" || strings.ContainsAny(host, ".:") {
			return 0, false
		}
		// Otherwise treat as `org/name` and use the trailing segment
		// for matching.
		repo = repo[strings.LastIndex(repo, "/")+1:]
	}
	repo = strings.ToLower(repo)
	if idx, ok := byName[repo]; ok {
		return idx, true
	}
	if projectPrefix != "-" && strings.HasPrefix(repo, projectPrefix) {
		if idx, ok := byName[strings.TrimPrefix(repo, projectPrefix)]; ok {
			return idx, true
		}
	}
	return 0, false
}

// splitImageRef returns (repo, tag-or-digest). Tag/digest is best-effort —
// only the repo portion matters for cross-ref matching.
func splitImageRef(ref string) (string, string) {
	if i := strings.Index(ref, "@"); i >= 0 {
		return ref[:i], ref[i+1:]
	}
	// Last `:` separates tag from repo, but only if it's after the last `/`
	// (otherwise it's a registry port number).
	slash := strings.LastIndex(ref, "/")
	colon := strings.LastIndex(ref, ":")
	if colon > slash {
		return ref[:colon], ref[colon+1:]
	}
	return ref, ""
}

// parseDockerfileFromRefs returns external image refs from `FROM <ref>`
// instructions. Stage names from `FROM x AS y` are excluded so a later
// `FROM y` doesn't get treated as a real image. `scratch` and refs
// containing ${VAR} are excluded.
func parseDockerfileFromRefs(path string) ([]string, []string) {
	instrs, err := readDockerfileInstructions(path)
	if err != nil {
		return nil, []string{fmt.Sprintf("read %s: %v", path, err)}
	}
	var (
		refs   []string
		stages = map[string]bool{}
		varRe  = regexp.MustCompile(`\$\{?[A-Za-z_]`)
	)
	for _, instr := range instrs {
		fields := strings.Fields(instr)
		if len(fields) < 2 || strings.ToUpper(fields[0]) != "FROM" {
			continue
		}
		// Drop leading flags (e.g. `--platform=$BUILDPLATFORM`).
		args := fields[1:]
		for len(args) > 0 && strings.HasPrefix(args[0], "--") {
			args = args[1:]
		}
		if len(args) == 0 {
			continue
		}
		ref := args[0]
		if len(args) >= 3 && strings.EqualFold(args[1], "AS") {
			stages[strings.ToLower(args[2])] = true
		}
		if stages[strings.ToLower(ref)] || strings.EqualFold(ref, "scratch") {
			continue
		}
		if varRe.MatchString(ref) {
			continue
		}
		refs = append(refs, ref)
	}
	return refs, nil
}

// readDockerfileInstructions reads a Dockerfile and returns one logical
// instruction per element (line continuations joined, comments stripped).
// Shared by parseDockerfileLocalSources and parseDockerfileFromRefs.
func readDockerfileInstructions(path string) ([]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	var (
		out []string
		buf strings.Builder
		sc  = bufio.NewScanner(f)
	)
	sc.Buffer(make([]byte, 1<<20), 1<<24)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasSuffix(line, "\\") {
			buf.WriteString(strings.TrimSuffix(line, "\\"))
			buf.WriteByte(' ')
			continue
		}
		buf.WriteString(line)
		if buf.Len() > 0 {
			out = append(out, buf.String())
		}
		buf.Reset()
	}
	if buf.Len() > 0 {
		out = append(out, buf.String())
	}
	return out, nil
}

// topoSortImages reorders imgs so each image's depends_on entries come
// first. Stable: input order is preserved among nodes with no relative
// dependency. Cycles produce a warning and the original order is kept
// (cmd_build_from_manifest's validator will then surface the cycle as
// a build-time error pointing at the offending pair).
func topoSortImages(imgs []manifestImage) ([]manifestImage, []string) {
	if len(imgs) <= 1 {
		return imgs, nil
	}
	idx := map[string]int{}
	for i, img := range imgs {
		idx[img.Name] = i
	}
	const (
		unseen   = 0
		active   = 1
		finished = 2
	)
	state := make([]int, len(imgs))
	var (
		out      []manifestImage
		warnings []string
		visit    func(i int, stack []string) bool
	)
	visit = func(i int, stack []string) bool {
		switch state[i] {
		case active:
			warnings = append(warnings, fmt.Sprintf(
				"dependency cycle: %s -> %s — leaving manifest order unchanged",
				strings.Join(stack, " -> "), imgs[i].Name))
			return false
		case finished:
			return true
		}
		state[i] = active
		for _, dep := range imgs[i].DependsOn {
			j, ok := idx[dep]
			if !ok {
				continue
			}
			if !visit(j, append(stack, imgs[i].Name)) {
				return false
			}
		}
		state[i] = finished
		out = append(out, imgs[i])
		return true
	}
	for i := range imgs {
		if state[i] == unseen && !visit(i, nil) {
			return imgs, warnings
		}
	}
	return out, warnings
}

func appendUnique(xs []string, v string) []string {
	for _, x := range xs {
		if x == v {
			return xs
		}
	}
	return append(xs, v)
}

// imageNameFor picks a slug derived from the Dockerfile's parent dir.
// For the special case where context == target == parent (a single
// top-level Dockerfile at the repo root), use the target dir's basename
// — `localhost:5050/repo:latest` reads better than `localhost:5050/.:latest`.
func imageNameFor(target, dockerfile, context string) string {
	dir := filepath.Dir(dockerfile)
	base := filepath.Base(dir)
	if filepath.Clean(dir) == filepath.Clean(target) {
		base = filepath.Base(target)
	}
	name := slugifyName(base)
	if name == "" {
		name = "image"
	}
	return name
}

// slugifyName matches sandbox.sh's slugify(): lowercase, non-alnum to '-',
// trimmed. Kept in lockstep so names line up with what manual builds
// would have produced.
func slugifyName(s string) string {
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

// inferBuildContext walks up from the Dockerfile's parent directory
// until every local source from `srcs` resolves under the candidate
// context (file or directory exists). Stops at `target` — never picks
// an ancestor outside the user's working tree, even if that's where the
// referenced file would live.
//
// If even target fails to satisfy, returns target with a warning. The
// build will likely fail at `docker build` time, but the user gets a
// concrete pointer to the problematic Dockerfile.
func inferBuildContext(target, dockerfile string, srcs []string) (string, string) {
	target = filepath.Clean(target)
	dir := filepath.Clean(filepath.Dir(dockerfile))
	candidate := dir
	for {
		if allResolve(candidate, srcs) {
			return candidate, ""
		}
		if candidate == target {
			missing := unresolvedSources(candidate, srcs)
			if len(missing) > 0 {
				return candidate, fmt.Sprintf(
					"could not locate sources for %s within %s — unresolved: %s",
					mustRel(target, dockerfile), target, strings.Join(missing, ", "))
			}
			return candidate, ""
		}
		parent := filepath.Dir(candidate)
		if parent == candidate {
			return target, ""
		}
		// Don't escape target.
		rel, err := filepath.Rel(target, parent)
		if err != nil || strings.HasPrefix(rel, "..") {
			return target, ""
		}
		candidate = parent
	}
}

func mustRel(base, p string) string {
	r, err := filepath.Rel(base, p)
	if err != nil {
		return p
	}
	return r
}

// allResolve returns true when every src resolves under context. Globs
// are checked by stripping the glob suffix and testing the static prefix
// (e.g. `src/*.go` reduces to `src`); URLs and variable-bearing strings
// are pre-filtered by the parser, so an empty list is never passed in
// here for a real Dockerfile.
func allResolve(context string, srcs []string) bool {
	for _, s := range srcs {
		if !sourceResolves(context, s) {
			return false
		}
	}
	return true
}

func unresolvedSources(context string, srcs []string) []string {
	var out []string
	for _, s := range srcs {
		if !sourceResolves(context, s) {
			out = append(out, s)
		}
	}
	return out
}

func sourceResolves(context, src string) bool {
	prefix := globStaticPrefix(src)
	if prefix == "" {
		return true
	}
	full := filepath.Join(context, prefix)
	_, err := os.Stat(full)
	return err == nil
}

// globStaticPrefix returns the leading portion of a path up to (but not
// including) the first glob metacharacter. Used to test whether a
// candidate context could plausibly hold a glob's matches without
// actually walking them.
func globStaticPrefix(s string) string {
	for i, r := range s {
		switch r {
		case '*', '?', '[':
			j := strings.LastIndex(s[:i], "/")
			if j <= 0 {
				return ""
			}
			return s[:j]
		}
	}
	return s
}

// parseDockerfileLocalSources extracts every COPY/ADD source that refers
// to the build context. Returns:
//
//   - sources from `COPY a b dest` and `ADD a b dest` (shell + JSON forms)
//   - skips `--from=...` (stage / image refs)
//   - skips URL/HTTP sources
//   - skips heredoc forms (COPY <<EOF) — those don't read the context
//   - skips entries with unresolved ${VAR} (warns instead — too unsafe to
//     guess at build-arg values)
//
// Warnings are returned per-Dockerfile and surfaced to the user; the
// auto-generated manifest is best-effort, and a clear "we couldn't tell
// what this references" message beats a confidently-wrong context.
func parseDockerfileLocalSources(path string) ([]string, []string) {
	instrs, err := readDockerfileInstructions(path)
	if err != nil {
		return nil, []string{fmt.Sprintf("read %s: %v", path, err)}
	}
	var (
		srcs     []string
		warnings []string
		urlRe    = regexp.MustCompile(`^[a-zA-Z][a-zA-Z0-9+\-.]*://`)
		varRe    = regexp.MustCompile(`\$\{?[A-Za-z_]`)
	)
	for _, instr := range instrs {
		fields := strings.Fields(instr)
		if len(fields) == 0 {
			continue
		}
		op := strings.ToUpper(fields[0])
		if op != "COPY" && op != "ADD" {
			continue
		}
		rest := strings.TrimSpace(strings.TrimPrefix(instr, fields[0]))

		// Drop leading flags. `--from=` means a stage/image ref, not the
		// build context — we explicitly skip the whole instruction in
		// that case (the Dockerfile is *not* claiming a context source).
		hasFromFlag := false
		for {
			rest = strings.TrimSpace(rest)
			if !strings.HasPrefix(rest, "--") {
				break
			}
			sp := strings.IndexByte(rest, ' ')
			tab := strings.IndexByte(rest, '\t')
			end := sp
			if tab >= 0 && (end < 0 || tab < end) {
				end = tab
			}
			var flag string
			if end < 0 {
				flag, rest = rest, ""
			} else {
				flag, rest = rest[:end], rest[end:]
			}
			if strings.HasPrefix(flag, "--from=") {
				hasFromFlag = true
			}
		}
		if hasFromFlag {
			continue
		}
		// Heredoc form: `COPY <<EOF ... EOF`. Doesn't read context.
		if strings.HasPrefix(strings.TrimSpace(rest), "<<") {
			continue
		}

		var parts []string
		if strings.HasPrefix(strings.TrimSpace(rest), "[") {
			var arr []string
			if err := json.Unmarshal([]byte(rest), &arr); err != nil {
				warnings = append(warnings,
					fmt.Sprintf("%s: skipping malformed JSON-array COPY/ADD: %s", path, rest))
				continue
			}
			parts = arr
		} else {
			parts = strings.Fields(rest)
		}
		if len(parts) < 2 {
			continue
		}
		// Last element is the destination inside the image — discard it.
		parts = parts[:len(parts)-1]
		for _, p := range parts {
			p = strings.Trim(p, `"'`)
			if p == "" || urlRe.MatchString(p) {
				continue
			}
			if varRe.MatchString(p) {
				warnings = append(warnings,
					fmt.Sprintf("%s: source %q uses a variable — skipping for context inference", path, p))
				continue
			}
			srcs = append(srcs, strings.TrimPrefix(p, "./"))
		}
	}
	return srcs, warnings
}

// writeAutogenManifest emits a deliberately hand-formatted YAML so we
// can attach a header comment that explains *why* the file exists.
// Users routinely commit this file; if they bump into it via `git
// status`, the header should be enough to know what it is and that
// editing it is fine.
func writeAutogenManifest(path string, imgs []manifestImage) error {
	var b strings.Builder
	b.WriteString("# sandboxctl.yaml — auto-generated by `sandboxctl build|deploy|bootstrap`\n")
	b.WriteString("# when no manifest existed in this directory. Each entry is one image\n")
	b.WriteString("# pushed to the in-cluster registry at localhost:5050/<name>:latest.\n")
	b.WriteString("#\n")
	b.WriteString("# Edit freely — sandboxctl will not overwrite an existing file.\n")
	b.WriteString("# `aliases` + `depends_on` are inferred from FROM lines; override here\n")
	b.WriteString("# if needed (manual entries are preserved across regeneration).\n")
	b.WriteString("images:\n")
	for _, img := range imgs {
		fmt.Fprintf(&b, "  - name: %s\n", img.Name)
		fmt.Fprintf(&b, "    context: %s\n", yamlScalar(img.Context))
		if img.Dockerfile != "" {
			fmt.Fprintf(&b, "    dockerfile: %s\n", yamlScalar(img.Dockerfile))
		}
		if len(img.Aliases) > 0 {
			fmt.Fprintf(&b, "    aliases: [%s]\n", joinScalars(img.Aliases))
		}
		if len(img.DependsOn) > 0 {
			fmt.Fprintf(&b, "    depends_on: [%s]\n", joinScalars(img.DependsOn))
		}
	}
	return os.WriteFile(path, []byte(b.String()), 0o644)
}

func joinScalars(xs []string) string {
	out := make([]string, len(xs))
	for i, x := range xs {
		out[i] = yamlScalar(x)
	}
	return strings.Join(out, ", ")
}

// yamlScalar quotes a value when it contains characters that would
// confuse the YAML parser (whitespace, leading dot, etc.). Plain
// alphanumeric+slash+dash+underscore stays unquoted for readability.
func yamlScalar(s string) string {
	if s == "" {
		return `""`
	}
	safe := true
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z',
			r >= 'A' && r <= 'Z',
			r >= '0' && r <= '9',
			r == '/', r == '-', r == '_', r == '.':
		default:
			safe = false
		}
		if !safe {
			break
		}
	}
	// A bare "." would parse as a string but reads ambiguously; quote it.
	if !safe || s == "." || strings.HasPrefix(s, "-") {
		return strconvQuote(s)
	}
	return s
}

// strconvQuote without pulling strconv just for one call. Handles the
// characters we actually emit (paths) — escapes backslash and double quote.
func strconvQuote(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, r := range s {
		switch r {
		case '"', '\\':
			b.WriteByte('\\')
			b.WriteRune(r)
		default:
			b.WriteRune(r)
		}
	}
	b.WriteByte('"')
	return b.String()
}
