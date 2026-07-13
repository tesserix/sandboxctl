package genwrite

import (
	"fmt"
	"strings"
)

// maxDiffLines caps a rendered diff so a pathological conflict can't
// flood the terminal; the tail is summarized instead.
const maxDiffLines = 200

// unifiedDiff renders a compact unified-style diff between two texts.
// It is intentionally a plain LCS over lines — good enough to show a
// user what would change in a config-sized file, with no ambition to
// match git's output byte-for-byte.
func unifiedDiff(path, oldText, newText string) string {
	oldLines := splitLines(oldText)
	newLines := splitLines(newText)

	var b strings.Builder
	fmt.Fprintf(&b, "--- %s (on disk)\n+++ %s (regenerated)\n", path, path)

	emitted := 0
	emit := func(prefix, line string) {
		if emitted == maxDiffLines {
			b.WriteString("… diff truncated …\n")
		}
		if emitted >= maxDiffLines {
			emitted++
			return
		}
		b.WriteString(prefix)
		b.WriteString(line)
		b.WriteByte('\n')
		emitted++
	}

	for _, h := range diffHunks(oldLines, newLines) {
		for _, l := range h.removed {
			emit("-", l)
		}
		for _, l := range h.added {
			emit("+", l)
		}
	}
	if emitted == 0 {
		return ""
	}
	return b.String()
}

type hunk struct {
	removed []string
	added   []string
}

// diffHunks computes change blocks via a longest-common-subsequence
// table. Inputs beyond a few thousand lines fall back to a whole-file
// replace hunk rather than an O(n·m) table nobody will read anyway.
func diffHunks(oldLines, newLines []string) []hunk {
	const lcsCap = 2000
	if len(oldLines) > lcsCap || len(newLines) > lcsCap {
		return []hunk{{removed: oldLines, added: newLines}}
	}

	n, m := len(oldLines), len(newLines)
	table := make([][]int, n+1)
	for i := range table {
		table[i] = make([]int, m+1)
	}
	for i := n - 1; i >= 0; i-- {
		for j := m - 1; j >= 0; j-- {
			if oldLines[i] == newLines[j] {
				table[i][j] = table[i+1][j+1] + 1
			} else if table[i+1][j] >= table[i][j+1] {
				table[i][j] = table[i+1][j]
			} else {
				table[i][j] = table[i][j+1]
			}
		}
	}

	var hunks []hunk
	var cur hunk
	flush := func() {
		if len(cur.removed) > 0 || len(cur.added) > 0 {
			hunks = append(hunks, cur)
			cur = hunk{}
		}
	}
	i, j := 0, 0
	for i < n && j < m {
		switch {
		case oldLines[i] == newLines[j]:
			flush()
			i++
			j++
		case table[i+1][j] >= table[i][j+1]:
			cur.removed = append(cur.removed, oldLines[i])
			i++
		default:
			cur.added = append(cur.added, newLines[j])
			j++
		}
	}
	cur.removed = append(cur.removed, oldLines[i:]...)
	cur.added = append(cur.added, newLines[j:]...)
	flush()
	return hunks
}

// splitLines splits without manufacturing a trailing empty line for
// newline-terminated text.
func splitLines(s string) []string {
	if s == "" {
		return nil
	}
	s = strings.TrimSuffix(s, "\n")
	return strings.Split(s, "\n")
}
