// Package genwrite is the single gate through which sandboxctl writes
// generated files into a user's repository. Every generator plans its
// writes here; the engine classifies each target by ownership, shows the
// full plan before anything touches disk, and never silently destroys a
// user's edits.
//
// Ownership is tracked with a one-line header marker carrying a content
// hash, which distinguishes four states without any sidecar ledger:
//
//	new            file absent                      → create
//	ours-clean     marker present, hash matches     → regenerate silently
//	ours-edited    marker present, hash differs     → conflict: ask first
//	user-authored  file present, no marker          → skip, never touch
//
// User-authored files are untouchable by design — not even --force
// overwrites them. Callers that truly need to replace one must delete it
// explicitly themselves.
package genwrite

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// markerVersion is bumped only if the marker line format itself changes.
const markerVersion = 1

// hashLen is the number of hex chars of the body's sha256 kept in the
// marker — tamper evidence for our own regeneration logic, not security.
const hashLen = 16

// State classifies who owns the current on-disk file.
type State int

const (
	StateNew State = iota
	StateOursClean
	StateOursEdited
	StateUserAuthored
)

func (s State) String() string {
	switch s {
	case StateNew:
		return "new"
	case StateOursClean:
		return "ours-clean"
	case StateOursEdited:
		return "ours-edited"
	case StateUserAuthored:
		return "user-authored"
	}
	return "unknown"
}

// Decision is what will happen (or happened) to one target file.
type Decision int

const (
	DecisionCreate Decision = iota
	DecisionRegenerate
	DecisionOverwrite // conflict resolved in favour of the new content
	DecisionSkip
	DecisionAppend
	DecisionUnchanged
)

func (d Decision) String() string {
	switch d {
	case DecisionCreate:
		return "create"
	case DecisionRegenerate:
		return "regenerate"
	case DecisionOverwrite:
		return "overwrite"
	case DecisionSkip:
		return "skip"
	case DecisionAppend:
		return "append"
	case DecisionUnchanged:
		return "unchanged"
	}
	return "unknown"
}

// Op is one desired write, expressed by a generator.
type Op struct {
	// Path is the target file, relative to the plan root.
	Path string
	// Body is the desired content, without the marker line. Mutually
	// exclusive with Append.
	Body []byte
	// Generator names the producer (e.g. "scaffold"); recorded in the
	// marker line.
	Generator string
	// Append lists exact lines that must exist in the file. Append-mode
	// files (e.g. .gitignore) belong to the user: missing lines are
	// added, existing content is never rewritten, and no marker is
	// written.
	Append []string
	// Reason says why this file is being generated, e.g. "Helm chart for
	// app api". Shown in the plan.
	Reason string
}

// PlannedOp is an Op after classification.
type PlannedOp struct {
	Op
	State    State
	Decision Decision
	// Conflict marks an ours-edited target whose fate is decided at
	// Apply time (prompt / --force / non-interactive skip).
	Conflict bool
	// Why explains the decision in one clause, e.g. "user-edited since
	// generation".
	Why string
	// appendMissing caches which Append lines are absent.
	appendMissing []string
}

// Plan is the classified set of writes, in caller order.
type Plan struct {
	Root string
	Ops  []PlannedOp
}

// Conflicts returns the ops that need a resolution at Apply time.
func (p *Plan) Conflicts() []PlannedOp {
	var out []PlannedOp
	for _, op := range p.Ops {
		if op.Conflict {
			out = append(out, op)
		}
	}
	return out
}

// Choice is a conflict resolution.
type Choice int

const (
	ChoiceSkip Choice = iota
	ChoiceOverwrite
	ChoiceSkipAll
	ChoiceAbort
)

// Conflict is handed to the resolver for one ours-edited file.
type Conflict struct {
	Path string
	// Diff is a unified diff from the on-disk body to the new body.
	Diff string
}

// Options controls Apply.
type Options struct {
	// DryRun stops after planning: Apply reports what would happen and
	// writes nothing.
	DryRun bool
	// Force resolves every conflict as overwrite. User-authored files
	// are still never touched.
	Force bool
	// Resolve is consulted per conflict when Force is false. Nil means
	// non-interactive: every conflict resolves to skip.
	Resolve func(Conflict) Choice
}

// Result summarizes an Apply.
type Result struct {
	Created     []string
	Regenerated []string
	Overwritten []string
	Appended    []string
	Unchanged   []string
	Skipped     []string
	// SkippedConflicts are ours-edited files left in place — the signal
	// CI uses to detect drift between generator and repo.
	SkippedConflicts []string
	Aborted          bool

	// undo journals every executed write so post-write validation (e.g.
	// a helm lint gate) can revert cleanly instead of leaving a broken
	// artefact behind.
	root string
	undo []undoEntry
}

type undoEntry struct {
	path    string // repo-relative
	existed bool
	prev    []byte
}

// Rollback reverts writes recorded in this Result, newest first. With
// prefixes, only paths equal to or under one of them are reverted (so a
// caller can undo a single chart dir); with none, everything is.
// Created files are removed and their now-empty parent directories
// pruned up to (never including) the plan root. Returns the reverted
// paths.
func (r *Result) Rollback(prefixes ...string) ([]string, error) {
	var reverted []string
	for i := len(r.undo) - 1; i >= 0; i-- {
		e := r.undo[i]
		if !pathUnderAny(e.path, prefixes) {
			continue
		}
		target := filepath.Join(r.root, filepath.FromSlash(e.path))
		if e.existed {
			if err := os.WriteFile(target, e.prev, 0o644); err != nil {
				return reverted, fmt.Errorf("rollback %s: %w", e.path, err)
			}
		} else {
			if err := os.Remove(target); err != nil && !os.IsNotExist(err) {
				return reverted, fmt.Errorf("rollback %s: %w", e.path, err)
			}
			pruneEmptyDirs(r.root, filepath.Dir(target))
		}
		reverted = append(reverted, e.path)
	}
	return reverted, nil
}

func pathUnderAny(path string, prefixes []string) bool {
	if len(prefixes) == 0 {
		return true
	}
	for _, p := range prefixes {
		if path == p || strings.HasPrefix(path, p+"/") {
			return true
		}
	}
	return false
}

// pruneEmptyDirs removes now-empty directories from dir upward, stopping
// at the plan root or the first non-empty directory. Best-effort.
func pruneEmptyDirs(root, dir string) {
	root = filepath.Clean(root)
	for {
		dir = filepath.Clean(dir)
		if dir == root || len(dir) <= len(root) {
			return
		}
		if err := os.Remove(dir); err != nil {
			return // non-empty or gone — either way, stop
		}
		dir = filepath.Dir(dir)
	}
}

// Exit codes for callers that surface Result as a process status.
// 3 is deliberately distinct from the 0/1/2 the CLI already uses, so
// scripts can tell "wrote everything" from "conflicts were skipped".
const (
	ExitClean            = 0
	ExitAborted          = 1
	ExitConflictsSkipped = 3
)

func (r *Result) ExitCode() int {
	switch {
	case r.Aborted:
		return ExitAborted
	case len(r.SkippedConflicts) > 0:
		return ExitConflictsSkipped
	default:
		return ExitClean
	}
}

// ----------------------------------------------------------------------------
// marker line
// ----------------------------------------------------------------------------

// markerRe matches our marker line. The trailing prose is deliberately
// not matched so its wording can improve without a version bump.
var markerRe = regexp.MustCompile(`^#\s*generated-by:\s*sandboxctl\s+(\S+)\s+v(\d+)\s+sha256:([0-9a-f]+)`)

// legacyHeaders are generated-file headers that predate this engine.
// They carry no hash, so edits can't be detected — the conservative
// classification is ours-edited (ask before replacing).
var legacyHeaders = []string{
	"# sandboxctl.yaml — auto-generated by",           // writeAutogenManifest
	"# Auto-generated by sandboxctl from values.yaml", // _chart-mimic-values
}

// markerFor renders the marker line for a body.
func markerFor(generator string, body []byte) string {
	return fmt.Sprintf(
		"# generated-by: sandboxctl %s v%d sha256:%s — edits are yours to keep; sandboxctl asks before replacing this file\n",
		generator, markerVersion, bodyHash(body))
}

// bodyHash hashes the body with line endings normalized, so a CRLF
// checkout doesn't turn every file into a false conflict.
func bodyHash(body []byte) string {
	sum := sha256.Sum256(normalizeNewlines(body))
	return hex.EncodeToString(sum[:])[:hashLen]
}

func normalizeNewlines(b []byte) []byte {
	return bytes.ReplaceAll(b, []byte("\r\n"), []byte("\n"))
}

// splitMarker looks for our marker (or a legacy header) within the first
// few lines of existing content. Returns the recorded hash (empty for
// legacy), the newline-normalized body below our marker, and whether
// anything matched. The search window tolerates a leading shebang or
// `---` document line. All offsets are computed on the normalized
// buffer so CRLF checkouts can't skew the body slice.
func splitMarker(content []byte) (hash string, body []byte, legacy, found bool) {
	norm := normalizeNewlines(content)
	offset := 0
	for i := 0; i < 5 && offset <= len(norm); i++ {
		line := norm[offset:]
		lineEnd := len(norm)
		if nl := bytes.IndexByte(line, '\n'); nl >= 0 {
			line = line[:nl]
			lineEnd = offset + nl + 1
		}
		if m := markerRe.FindSubmatch(line); m != nil {
			return string(m[3]), norm[lineEnd:], false, true
		}
		for _, lh := range legacyHeaders {
			if strings.HasPrefix(string(line), lh) {
				return "", nil, true, true
			}
		}
		if lineEnd >= len(norm) {
			break
		}
		offset = lineEnd
	}
	return "", nil, false, false
}

// ----------------------------------------------------------------------------
// planning
// ----------------------------------------------------------------------------

// BuildPlan classifies every op against the tree under root. Read-only.
func BuildPlan(root string, ops []Op) (*Plan, error) {
	plan := &Plan{Root: root}
	for _, op := range ops {
		if op.Path == "" {
			return nil, fmt.Errorf("genwrite: op with empty path")
		}
		if len(op.Body) > 0 && len(op.Append) > 0 {
			return nil, fmt.Errorf("genwrite: %s: Body and Append are mutually exclusive", op.Path)
		}
		var planned PlannedOp
		if len(op.Append) > 0 {
			planned = planAppend(root, op)
		} else {
			planned = planWrite(root, op)
		}
		plan.Ops = append(plan.Ops, planned)
	}
	return plan, nil
}

func planWrite(root string, op Op) PlannedOp {
	target := filepath.Join(root, filepath.FromSlash(op.Path))
	existing, err := os.ReadFile(target)
	if err != nil {
		return PlannedOp{Op: op, State: StateNew, Decision: DecisionCreate, Why: "new file"}
	}

	hash, oldBody, legacy, found := splitMarker(existing)
	switch {
	case !found:
		return PlannedOp{
			Op: op, State: StateUserAuthored, Decision: DecisionSkip,
			Why: "not generated by sandboxctl — left untouched",
		}
	case legacy:
		return PlannedOp{
			Op: op, State: StateOursEdited, Decision: DecisionSkip, Conflict: true,
			Why: "generated before edit tracking existed — treated as edited",
		}
	case hash == bodyHash(oldBody):
		if bytes.Equal(normalizeNewlines(oldBody), normalizeNewlines(op.Body)) {
			return PlannedOp{Op: op, State: StateOursClean, Decision: DecisionUnchanged, Why: "content identical"}
		}
		return PlannedOp{
			Op: op, State: StateOursClean, Decision: DecisionRegenerate,
			Why: "previous generation unmodified",
		}
	default:
		return PlannedOp{
			Op: op, State: StateOursEdited, Decision: DecisionSkip, Conflict: true,
			Why: "user-edited since generation",
		}
	}
}

func planAppend(root string, op Op) PlannedOp {
	target := filepath.Join(root, filepath.FromSlash(op.Path))
	existing, err := os.ReadFile(target)
	state := StateUserAuthored // append targets belong to the user by definition
	if err != nil {
		state = StateNew
	}

	present := map[string]bool{}
	for _, line := range strings.Split(string(normalizeNewlines(existing)), "\n") {
		present[strings.TrimSpace(line)] = true
	}
	var missing []string
	for _, want := range op.Append {
		if !present[strings.TrimSpace(want)] {
			missing = append(missing, want)
		}
	}

	if len(missing) == 0 {
		return PlannedOp{Op: op, State: state, Decision: DecisionUnchanged, Why: "all lines already present"}
	}
	decision := DecisionAppend
	why := fmt.Sprintf("adds %s", strings.Join(missing, ", "))
	if state == StateNew {
		decision = DecisionCreate
		why = fmt.Sprintf("new file with %s", strings.Join(missing, ", "))
	}
	return PlannedOp{Op: op, State: state, Decision: decision, Why: why, appendMissing: missing}
}

// ----------------------------------------------------------------------------
// applying
// ----------------------------------------------------------------------------

// Apply executes the plan. Conflicts are resolved by opts.Force, then
// opts.Resolve, then default-skip. Aborting leaves remaining ops
// untouched and marks the result aborted. Every executed write is
// journalled so Result.Rollback can revert it.
func Apply(plan *Plan, opts Options) (*Result, error) {
	res := &Result{root: plan.Root}
	skipAll := false

	for i := range plan.Ops {
		op := &plan.Ops[i]

		if op.Conflict && !opts.DryRun {
			resolveConflict(plan.Root, op, opts, &skipAll, res)
			if res.Aborted {
				for _, rest := range plan.Ops[i:] {
					res.Skipped = append(res.Skipped, rest.Path)
				}
				return res, nil
			}
		} else if op.Conflict && opts.DryRun {
			// Dry runs never prompt: report the default outcome.
			if opts.Force {
				op.Decision = DecisionOverwrite
			}
		}

		if opts.DryRun {
			record(res, op)
			continue
		}

		undo, snapErr := snapshotForUndo(plan.Root, op)
		if snapErr != nil {
			return res, snapErr
		}
		if err := execute(plan.Root, op); err != nil {
			return res, err
		}
		if undo != nil {
			res.undo = append(res.undo, *undo)
		}
		record(res, op)
	}
	return res, nil
}

// snapshotForUndo captures a file's pre-write state for decisions that
// mutate disk. Skip/unchanged decisions journal nothing.
func snapshotForUndo(root string, op *PlannedOp) (*undoEntry, error) {
	switch op.Decision {
	case DecisionCreate, DecisionRegenerate, DecisionOverwrite, DecisionAppend:
	default:
		return nil, nil
	}
	target := filepath.Join(root, filepath.FromSlash(op.Path))
	prev, err := os.ReadFile(target)
	if err != nil {
		if !os.IsNotExist(err) {
			return nil, fmt.Errorf("snapshot %s before write: %w", op.Path, err)
		}
		return &undoEntry{path: op.Path, existed: false}, nil
	}
	return &undoEntry{path: op.Path, existed: true, prev: prev}, nil
}

func resolveConflict(root string, op *PlannedOp, opts Options, skipAll *bool, res *Result) {
	switch {
	case opts.Force:
		op.Decision = DecisionOverwrite
		op.Why = "user-edited; overwritten (--force)"
	case *skipAll || opts.Resolve == nil:
		op.Decision = DecisionSkip
	default:
		diff := conflictDiff(root, *op)
		switch opts.Resolve(Conflict{Path: op.Path, Diff: diff}) {
		case ChoiceOverwrite:
			op.Decision = DecisionOverwrite
			op.Why = "user-edited; overwrite approved"
		case ChoiceSkipAll:
			*skipAll = true
			op.Decision = DecisionSkip
		case ChoiceAbort:
			res.Aborted = true
		default:
			op.Decision = DecisionSkip
		}
	}
}

// conflictDiff renders the on-disk body → new body diff for a conflict.
func conflictDiff(root string, op PlannedOp) string {
	existing, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(op.Path)))
	if err != nil {
		return ""
	}
	_, oldBody, legacy, found := splitMarker(existing)
	if !found || legacy {
		oldBody = existing
	}
	return unifiedDiff(op.Path, string(normalizeNewlines(oldBody)), string(normalizeNewlines(op.Body)))
}

func execute(root string, op *PlannedOp) error {
	target := filepath.Join(root, filepath.FromSlash(op.Path))
	switch op.Decision {
	case DecisionSkip, DecisionUnchanged:
		return nil
	case DecisionAppend, DecisionCreate:
		if len(op.Append) > 0 {
			return appendLines(target, op.appendMissing)
		}
		return writeGenerated(target, op.Generator, op.Body)
	case DecisionRegenerate, DecisionOverwrite:
		return writeGenerated(target, op.Generator, op.Body)
	}
	return fmt.Errorf("genwrite: %s: unknown decision %v", op.Path, op.Decision)
}

func record(res *Result, op *PlannedOp) {
	switch op.Decision {
	case DecisionCreate:
		res.Created = append(res.Created, op.Path)
	case DecisionRegenerate:
		res.Regenerated = append(res.Regenerated, op.Path)
	case DecisionOverwrite:
		res.Overwritten = append(res.Overwritten, op.Path)
	case DecisionAppend:
		res.Appended = append(res.Appended, op.Path)
	case DecisionUnchanged:
		res.Unchanged = append(res.Unchanged, op.Path)
	case DecisionSkip:
		res.Skipped = append(res.Skipped, op.Path)
		if op.Conflict {
			res.SkippedConflicts = append(res.SkippedConflicts, op.Path)
		}
	}
}

// writeGenerated writes marker + body atomically (tempfile + rename), so
// a crash mid-write can never leave a half-generated file behind.
func writeGenerated(target, generator string, body []byte) error {
	if generator == "" {
		generator = "generate"
	}
	content := append([]byte(markerFor(generator, body)), body...)
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(target), ".genwrite-*.tmp")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	if _, err := tmp.Write(content); err != nil {
		tmp.Close()
		os.Remove(tmpPath)
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpPath)
		return err
	}
	return os.Rename(tmpPath, target)
}

// appendLines adds the missing lines to the end of the file, creating it
// when absent, and preserving everything already there.
func appendLines(target string, lines []string) error {
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return err
	}
	existing, _ := os.ReadFile(target)
	var b bytes.Buffer
	b.Write(existing)
	if len(existing) > 0 && !bytes.HasSuffix(existing, []byte("\n")) {
		b.WriteByte('\n')
	}
	for _, l := range lines {
		b.WriteString(l)
		b.WriteByte('\n')
	}
	tmp, err := os.CreateTemp(filepath.Dir(target), ".genwrite-*.tmp")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	if _, err := tmp.Write(b.Bytes()); err != nil {
		tmp.Close()
		os.Remove(tmpPath)
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpPath)
		return err
	}
	return os.Rename(tmpPath, target)
}

// SortedPaths is a small helper for deterministic reporting in tests and
// summaries.
func SortedPaths(paths []string) []string {
	out := append([]string(nil), paths...)
	sort.Strings(out)
	return out
}
