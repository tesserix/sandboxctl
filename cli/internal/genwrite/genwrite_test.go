package genwrite

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeFile(t *testing.T, root, rel, content string) {
	t.Helper()
	p := filepath.Join(root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func readFile(t *testing.T, root, rel string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(rel)))
	if err != nil {
		t.Fatalf("read %s: %v", rel, err)
	}
	return string(b)
}

// snapshot captures every file's content under root so dry-run tests can
// prove nothing changed.
func snapshot(t *testing.T, root string) map[string]string {
	t.Helper()
	out := map[string]string{}
	err := filepath.Walk(root, func(p string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() {
			return err
		}
		b, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		out[p] = string(b)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return out
}

// generate runs a full create pass for one file and returns its plan op.
func generate(t *testing.T, root, rel, body string) {
	t.Helper()
	plan, err := BuildPlan(root, []Op{{Path: rel, Body: []byte(body), Generator: "scaffold"}})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Apply(plan, Options{}); err != nil {
		t.Fatal(err)
	}
}

func planOne(t *testing.T, root string, op Op) PlannedOp {
	t.Helper()
	plan, err := BuildPlan(root, []Op{op})
	if err != nil {
		t.Fatal(err)
	}
	return plan.Ops[0]
}

// ----------------------------------------------------------------------------
// state matrix
// ----------------------------------------------------------------------------

func TestCreateNewFile(t *testing.T) {
	root := t.TempDir()
	op := planOne(t, root, Op{Path: "k8s/charts/api/values.yaml", Body: []byte("a: 1\n"), Generator: "scaffold"})
	if op.State != StateNew || op.Decision != DecisionCreate {
		t.Fatalf("state=%v decision=%v", op.State, op.Decision)
	}

	plan := &Plan{Root: root, Ops: []PlannedOp{op}}
	res, err := Apply(plan, Options{})
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Created) != 1 || res.ExitCode() != ExitClean {
		t.Fatalf("created=%v exit=%d", res.Created, res.ExitCode())
	}

	content := readFile(t, root, "k8s/charts/api/values.yaml")
	if !strings.HasPrefix(content, "# generated-by: sandboxctl scaffold v1 sha256:") {
		t.Fatalf("missing marker:\n%s", content)
	}
	if !strings.HasSuffix(content, "a: 1\n") {
		t.Fatalf("body mangled:\n%s", content)
	}
}

func TestOursCleanRegeneratesSilently(t *testing.T) {
	root := t.TempDir()
	generate(t, root, "values.yaml", "a: 1\n")

	op := planOne(t, root, Op{Path: "values.yaml", Body: []byte("a: 2\n"), Generator: "scaffold"})
	if op.State != StateOursClean || op.Decision != DecisionRegenerate || op.Conflict {
		t.Fatalf("state=%v decision=%v conflict=%v", op.State, op.Decision, op.Conflict)
	}
	res, err := Apply(&Plan{Root: root, Ops: []PlannedOp{op}}, Options{})
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Regenerated) != 1 {
		t.Fatalf("regenerated=%v", res.Regenerated)
	}
	if got := readFile(t, root, "values.yaml"); !strings.Contains(got, "a: 2") {
		t.Fatalf("content not updated:\n%s", got)
	}
}

func TestOursCleanIdenticalIsUnchanged(t *testing.T) {
	root := t.TempDir()
	generate(t, root, "values.yaml", "a: 1\n")

	op := planOne(t, root, Op{Path: "values.yaml", Body: []byte("a: 1\n"), Generator: "scaffold"})
	if op.Decision != DecisionUnchanged {
		t.Fatalf("decision=%v, want unchanged", op.Decision)
	}
}

func TestOursEditedIsConflictAndDefaultsToSkip(t *testing.T) {
	root := t.TempDir()
	generate(t, root, "values.yaml", "a: 1\n")
	// User edits the generated file (marker stays).
	edited := strings.Replace(readFile(t, root, "values.yaml"), "a: 1", "a: 1\nmine: true", 1)
	writeFile(t, root, "values.yaml", edited)

	op := planOne(t, root, Op{Path: "values.yaml", Body: []byte("a: 2\n"), Generator: "scaffold"})
	if op.State != StateOursEdited || !op.Conflict {
		t.Fatalf("state=%v conflict=%v", op.State, op.Conflict)
	}

	// Non-interactive (no resolver, no force): skip + distinct exit code.
	res, err := Apply(&Plan{Root: root, Ops: []PlannedOp{op}}, Options{})
	if err != nil {
		t.Fatal(err)
	}
	if len(res.SkippedConflicts) != 1 || res.ExitCode() != ExitConflictsSkipped {
		t.Fatalf("skippedConflicts=%v exit=%d", res.SkippedConflicts, res.ExitCode())
	}
	if got := readFile(t, root, "values.yaml"); !strings.Contains(got, "mine: true") {
		t.Fatalf("user edit lost:\n%s", got)
	}
}

func TestUserAuthoredNeverTouchedEvenWithForce(t *testing.T) {
	root := t.TempDir()
	writeFile(t, root, "Chart.yaml", "apiVersion: v2\nname: theirs\n")

	op := planOne(t, root, Op{Path: "Chart.yaml", Body: []byte("name: ours\n"), Generator: "scaffold"})
	if op.State != StateUserAuthored || op.Decision != DecisionSkip || op.Conflict {
		t.Fatalf("state=%v decision=%v conflict=%v", op.State, op.Decision, op.Conflict)
	}

	res, err := Apply(&Plan{Root: root, Ops: []PlannedOp{op}}, Options{Force: true})
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Skipped) != 1 || len(res.Overwritten) != 0 {
		t.Fatalf("skipped=%v overwritten=%v", res.Skipped, res.Overwritten)
	}
	if got := readFile(t, root, "Chart.yaml"); !strings.Contains(got, "theirs") {
		t.Fatalf("user file rewritten:\n%s", got)
	}
	// A skipped user-authored file is not a "conflict" — exit stays clean.
	if res.ExitCode() != ExitClean {
		t.Fatalf("exit=%d, want %d", res.ExitCode(), ExitClean)
	}
}

// ----------------------------------------------------------------------------
// conflict resolution
// ----------------------------------------------------------------------------

func editGenerated(t *testing.T, root, rel string) {
	t.Helper()
	edited := readFile(t, root, rel) + "user-addition: true\n"
	writeFile(t, root, rel, edited)
}

func TestForceOverwritesConflicts(t *testing.T) {
	root := t.TempDir()
	generate(t, root, "values.yaml", "a: 1\n")
	editGenerated(t, root, "values.yaml")

	op := planOne(t, root, Op{Path: "values.yaml", Body: []byte("a: 2\n"), Generator: "scaffold"})
	res, err := Apply(&Plan{Root: root, Ops: []PlannedOp{op}}, Options{Force: true})
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Overwritten) != 1 || res.ExitCode() != ExitClean {
		t.Fatalf("overwritten=%v exit=%d", res.Overwritten, res.ExitCode())
	}
	got := readFile(t, root, "values.yaml")
	if strings.Contains(got, "user-addition") || !strings.Contains(got, "a: 2") {
		t.Fatalf("force overwrite wrong:\n%s", got)
	}
}

func TestResolverOverwriteAndDiff(t *testing.T) {
	root := t.TempDir()
	generate(t, root, "values.yaml", "a: 1\n")
	editGenerated(t, root, "values.yaml")

	var sawDiff string
	resolve := func(c Conflict) Choice {
		sawDiff = c.Diff
		return ChoiceOverwrite
	}
	op := planOne(t, root, Op{Path: "values.yaml", Body: []byte("a: 2\n"), Generator: "scaffold"})
	res, err := Apply(&Plan{Root: root, Ops: []PlannedOp{op}}, Options{Resolve: resolve})
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Overwritten) != 1 {
		t.Fatalf("overwritten=%v", res.Overwritten)
	}
	if !strings.Contains(sawDiff, "-user-addition: true") || !strings.Contains(sawDiff, "+a: 2") {
		t.Fatalf("diff missing expected lines:\n%s", sawDiff)
	}
}

func TestResolverSkipAllLatches(t *testing.T) {
	root := t.TempDir()
	generate(t, root, "one.yaml", "a: 1\n")
	generate(t, root, "two.yaml", "b: 1\n")
	editGenerated(t, root, "one.yaml")
	editGenerated(t, root, "two.yaml")

	calls := 0
	resolve := func(Conflict) Choice {
		calls++
		return ChoiceSkipAll
	}
	plan, err := BuildPlan(root, []Op{
		{Path: "one.yaml", Body: []byte("a: 2\n"), Generator: "scaffold"},
		{Path: "two.yaml", Body: []byte("b: 2\n"), Generator: "scaffold"},
	})
	if err != nil {
		t.Fatal(err)
	}
	res, err := Apply(plan, Options{Resolve: resolve})
	if err != nil {
		t.Fatal(err)
	}
	if calls != 1 {
		t.Fatalf("resolver called %d times, want 1 (skip-all latches)", calls)
	}
	if len(res.SkippedConflicts) != 2 {
		t.Fatalf("skippedConflicts=%v", res.SkippedConflicts)
	}
}

func TestResolverAbortStopsEverything(t *testing.T) {
	root := t.TempDir()
	generate(t, root, "one.yaml", "a: 1\n")
	editGenerated(t, root, "one.yaml")

	plan, err := BuildPlan(root, []Op{
		{Path: "one.yaml", Body: []byte("a: 2\n"), Generator: "scaffold"},
		{Path: "new.yaml", Body: []byte("n: 1\n"), Generator: "scaffold"},
	})
	if err != nil {
		t.Fatal(err)
	}
	res, err := Apply(plan, Options{Resolve: func(Conflict) Choice { return ChoiceAbort }})
	if err != nil {
		t.Fatal(err)
	}
	if !res.Aborted || res.ExitCode() != ExitAborted {
		t.Fatalf("aborted=%v exit=%d", res.Aborted, res.ExitCode())
	}
	if _, err := os.Stat(filepath.Join(root, "new.yaml")); !os.IsNotExist(err) {
		t.Fatal("abort still wrote a later file")
	}
}

// ----------------------------------------------------------------------------
// dry run
// ----------------------------------------------------------------------------

func TestDryRunWritesNothingAndNeverPrompts(t *testing.T) {
	root := t.TempDir()
	generate(t, root, "clean.yaml", "a: 1\n")
	generate(t, root, "edited.yaml", "b: 1\n")
	editGenerated(t, root, "edited.yaml")
	writeFile(t, root, "theirs.yaml", "user file\n")
	before := snapshot(t, root)

	plan, err := BuildPlan(root, []Op{
		{Path: "clean.yaml", Body: []byte("a: 2\n"), Generator: "scaffold"},
		{Path: "edited.yaml", Body: []byte("b: 2\n"), Generator: "scaffold"},
		{Path: "theirs.yaml", Body: []byte("x\n"), Generator: "scaffold"},
		{Path: "brand-new.yaml", Body: []byte("y\n"), Generator: "scaffold"},
		{Path: ".gitignore", Append: []string{"k8s/secrets.yaml"}},
	})
	if err != nil {
		t.Fatal(err)
	}
	res, err := Apply(plan, Options{
		DryRun:  true,
		Resolve: func(Conflict) Choice { t.Fatal("dry run consulted the resolver"); return ChoiceSkip },
	})
	if err != nil {
		t.Fatal(err)
	}

	if diffCount := len(res.Created) + len(res.Regenerated) + len(res.Appended); diffCount != 3 {
		t.Fatalf("expected 3 would-be writes, got created=%v regen=%v appended=%v",
			res.Created, res.Regenerated, res.Appended)
	}
	after := snapshot(t, root)
	if len(before) != len(after) {
		t.Fatalf("dry run changed file count: %d → %d", len(before), len(after))
	}
	for p, c := range before {
		if after[p] != c {
			t.Fatalf("dry run mutated %s", p)
		}
	}
}

// ----------------------------------------------------------------------------
// hash stability + marker parsing
// ----------------------------------------------------------------------------

func TestCRLFCheckoutIsNotAConflict(t *testing.T) {
	root := t.TempDir()
	generate(t, root, "values.yaml", "a: 1\nb: 2\n")

	// Simulate a CRLF re-checkout of the identical file.
	crlf := strings.ReplaceAll(readFile(t, root, "values.yaml"), "\n", "\r\n")
	writeFile(t, root, "values.yaml", crlf)

	op := planOne(t, root, Op{Path: "values.yaml", Body: []byte("a: 1\nb: 2\n"), Generator: "scaffold"})
	if op.State != StateOursClean {
		t.Fatalf("state=%v (%s), want ours-clean across CRLF", op.State, op.Why)
	}
	if op.Decision != DecisionUnchanged {
		t.Fatalf("decision=%v, want unchanged", op.Decision)
	}
}

func TestMarkerToleratedBelowLeadingLines(t *testing.T) {
	root := t.TempDir()
	body := "real: content\n"
	content := "#!/usr/bin/env bash\n" + markerFor("scaffold", []byte(body)) + body
	writeFile(t, root, "script.sh", content)

	op := planOne(t, root, Op{Path: "script.sh", Body: []byte(body), Generator: "scaffold"})
	if op.State != StateOursClean {
		t.Fatalf("state=%v (%s), want ours-clean with marker on line 2", op.State, op.Why)
	}
}

func TestLegacyGeneratedHeaderIsConservativeConflict(t *testing.T) {
	root := t.TempDir()
	writeFile(t, root, "values-sandbox.yaml",
		"# Auto-generated by sandboxctl from values.yaml.\n# Edits land here on the next deploy\nimage:\n  tag: latest\n")

	op := planOne(t, root, Op{Path: "values-sandbox.yaml", Body: []byte("image:\n  tag: v2\n"), Generator: "scaffold"})
	if op.State != StateOursEdited || !op.Conflict {
		t.Fatalf("state=%v conflict=%v, want conservative conflict for legacy header", op.State, op.Conflict)
	}
	if !strings.Contains(op.Why, "edit tracking") {
		t.Fatalf("why=%q", op.Why)
	}
}

// ----------------------------------------------------------------------------
// append mode
// ----------------------------------------------------------------------------

func TestAppendCreatesAndAmends(t *testing.T) {
	root := t.TempDir()

	// Creating a fresh file.
	op := planOne(t, root, Op{Path: ".gitignore", Append: []string{"k8s/secrets.yaml", ".env"}})
	if op.Decision != DecisionCreate {
		t.Fatalf("decision=%v", op.Decision)
	}
	if _, err := Apply(&Plan{Root: root, Ops: []PlannedOp{op}}, Options{}); err != nil {
		t.Fatal(err)
	}
	if got := readFile(t, root, ".gitignore"); got != "k8s/secrets.yaml\n.env\n" {
		t.Fatalf("gitignore content:\n%q", got)
	}

	// Existing file without trailing newline: content preserved, missing
	// line appended, present line not duplicated.
	writeFile(t, root, ".gitignore", "node_modules\nk8s/secrets.yaml")
	op = planOne(t, root, Op{Path: ".gitignore", Append: []string{"k8s/secrets.yaml", ".env"}})
	if op.Decision != DecisionAppend {
		t.Fatalf("decision=%v", op.Decision)
	}
	res, err := Apply(&Plan{Root: root, Ops: []PlannedOp{op}}, Options{})
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Appended) != 1 {
		t.Fatalf("appended=%v", res.Appended)
	}
	if got := readFile(t, root, ".gitignore"); got != "node_modules\nk8s/secrets.yaml\n.env\n" {
		t.Fatalf("gitignore content:\n%q", got)
	}

	// Everything already present → unchanged.
	op = planOne(t, root, Op{Path: ".gitignore", Append: []string{".env"}})
	if op.Decision != DecisionUnchanged {
		t.Fatalf("decision=%v", op.Decision)
	}
}

// ----------------------------------------------------------------------------
// rollback
// ----------------------------------------------------------------------------

func TestRollbackRevertsCreateRegenerateAppend(t *testing.T) {
	root := t.TempDir()
	generate(t, root, "regen.yaml", "a: 1\n")
	oldRegen := readFile(t, root, "regen.yaml")
	writeFile(t, root, ".gitignore", "node_modules\n")

	plan, err := BuildPlan(root, []Op{
		{Path: "charts/api/new.yaml", Body: []byte("n: 1\n"), Generator: "scaffold"},
		{Path: "regen.yaml", Body: []byte("a: 2\n"), Generator: "scaffold"},
		{Path: ".gitignore", Append: []string{"k8s/secrets.yaml"}},
	})
	if err != nil {
		t.Fatal(err)
	}
	res, err := Apply(plan, Options{})
	if err != nil {
		t.Fatal(err)
	}

	reverted, err := res.Rollback()
	if err != nil {
		t.Fatal(err)
	}
	if len(reverted) != 3 {
		t.Fatalf("reverted = %v, want all three writes", reverted)
	}
	if _, err := os.Stat(filepath.Join(root, "charts/api/new.yaml")); !os.IsNotExist(err) {
		t.Fatal("created file survived rollback")
	}
	if _, err := os.Stat(filepath.Join(root, "charts")); !os.IsNotExist(err) {
		t.Fatal("empty created dirs not pruned")
	}
	if got := readFile(t, root, "regen.yaml"); got != oldRegen {
		t.Fatalf("regenerated file not restored:\n%s", got)
	}
	if got := readFile(t, root, ".gitignore"); got != "node_modules\n" {
		t.Fatalf("appended file not restored:\n%q", got)
	}
}

func TestRollbackHonoursPrefix(t *testing.T) {
	root := t.TempDir()
	plan, err := BuildPlan(root, []Op{
		{Path: "charts/a/f.yaml", Body: []byte("a\n"), Generator: "scaffold"},
		{Path: "charts/b/f.yaml", Body: []byte("b\n"), Generator: "scaffold"},
	})
	if err != nil {
		t.Fatal(err)
	}
	res, err := Apply(plan, Options{})
	if err != nil {
		t.Fatal(err)
	}

	reverted, err := res.Rollback("charts/a")
	if err != nil {
		t.Fatal(err)
	}
	if len(reverted) != 1 || reverted[0] != "charts/a/f.yaml" {
		t.Fatalf("reverted = %v", reverted)
	}
	if _, err := os.Stat(filepath.Join(root, "charts/a")); !os.IsNotExist(err) {
		t.Fatal("charts/a not fully removed")
	}
	if got := readFile(t, root, "charts/b/f.yaml"); !strings.Contains(got, "b") {
		t.Fatal("unrelated chart b was rolled back")
	}
}

// ----------------------------------------------------------------------------
// validation, rendering, diff
// ----------------------------------------------------------------------------

func TestBuildPlanValidation(t *testing.T) {
	if _, err := BuildPlan(t.TempDir(), []Op{{Path: ""}}); err == nil {
		t.Fatal("empty path accepted")
	}
	if _, err := BuildPlan(t.TempDir(), []Op{{Path: "x", Body: []byte("b"), Append: []string{"l"}}}); err == nil {
		t.Fatal("body+append accepted")
	}
}

func TestRenderPlanShowsConflictsAndReasons(t *testing.T) {
	root := t.TempDir()
	generate(t, root, "edited.yaml", "a: 1\n")
	editGenerated(t, root, "edited.yaml")
	writeFile(t, root, "theirs.yaml", "user\n")

	plan, err := BuildPlan(root, []Op{
		{Path: "new.yaml", Body: []byte("n\n"), Generator: "scaffold", Reason: "Helm chart for app api"},
		{Path: "edited.yaml", Body: []byte("a: 2\n"), Generator: "scaffold"},
		{Path: "theirs.yaml", Body: []byte("x\n"), Generator: "scaffold"},
	})
	if err != nil {
		t.Fatal(err)
	}
	var buf bytes.Buffer
	RenderPlan(&buf, plan)
	out := buf.String()
	for _, want := range []string{
		"create", "Helm chart for app api",
		"overwrite?", "user-edited since generation",
		"skip", "not generated by sandboxctl",
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("plan output missing %q:\n%s", want, out)
		}
	}
}

func TestPromptResolverFlows(t *testing.T) {
	c := Conflict{Path: "x.yaml", Diff: "-old\n+new\n"}

	cases := []struct {
		input string
		want  Choice
	}{
		{"\n", ChoiceSkip},
		{"s\n", ChoiceSkip},
		{"o\n", ChoiceOverwrite},
		{"d\no\n", ChoiceOverwrite}, // show diff, then overwrite
		{"a\n", ChoiceSkipAll},
		{"q\n", ChoiceAbort},
		{"bogus\ns\n", ChoiceSkip},
		{"", ChoiceSkip}, // EOF
	}
	for _, tc := range cases {
		var out bytes.Buffer
		got := PromptResolver(strings.NewReader(tc.input), &out)(c)
		if got != tc.want {
			t.Errorf("input %q → %v, want %v", tc.input, got, tc.want)
		}
		if strings.HasPrefix(tc.input, "d") && !strings.Contains(out.String(), "-old") {
			t.Errorf("diff not shown for input %q", tc.input)
		}
	}
}

func TestUnifiedDiffBasics(t *testing.T) {
	if d := unifiedDiff("f", "a\nb\n", "a\nb\n"); d != "" {
		t.Fatalf("identical inputs produced diff:\n%s", d)
	}
	d := unifiedDiff("f", "a\nb\nc\n", "a\nX\nc\n")
	if !strings.Contains(d, "-b") || !strings.Contains(d, "+X") {
		t.Fatalf("diff wrong:\n%s", d)
	}

	// Truncation cap.
	var oldB, newB strings.Builder
	for i := 0; i < 300; i++ {
		oldB.WriteString("old line\n")
		newB.WriteString("new line\n")
	}
	if d := unifiedDiff("f", oldB.String(), newB.String()); !strings.Contains(d, "diff truncated") {
		t.Fatal("large diff not truncated")
	}
}
