package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/tesserix/sandboxctl/cli/internal/components"
)

// runVersions implements `sandboxctl versions [--offline] [--json]` —
// the doctor view of every component the sandbox installs: what the
// tool pins (chart→app), what upstream ships, what the cluster runs,
// and whether any compatibility floor is violated. Exit codes: 0 clean,
// 1 floor violation (so CI can gate on drift that would break features).
func runVersions(args []string) int {
	offline, jsonOut := false, false
	for _, a := range args {
		switch a {
		case "--offline":
			offline = true
		case "--json":
			jsonOut = true
		case "-h", "--help":
			fmt.Println("usage: sandboxctl versions [--offline] [--json]")
			return 0
		default:
			fmt.Fprintf(os.Stderr, "versions: unknown flag %s\n", a)
			return 2
		}
	}

	installed := components.Installed()

	type row struct {
		Component  string `json:"component"`
		Pinned     string `json:"pinned"`
		PinnedApp  string `json:"pinned_app,omitempty"`
		Overridden bool   `json:"overridden,omitempty"`
		Latest     string `json:"latest,omitempty"`
		LatestApp  string `json:"latest_app,omitempty"`
		Installed  string `json:"installed,omitempty"`
		Status     string `json:"status"`
	}

	var rows []row
	floorViolations := 0
	for _, c := range components.Registry {
		r := row{Component: c.Name}
		r.Pinned, r.Overridden = c.Pinned()
		if r.Pinned == c.Default {
			r.PinnedApp = c.App
		}
		if c.Release != "" {
			r.Installed = installed[c.Release]
		}

		if !offline {
			if v, app, err := c.Latest(); err == nil {
				r.Latest, r.LatestApp = v, app
			} else {
				r.Latest = "?"
			}
		}

		switch {
		case c.FloorViolated(r.Pinned):
			r.Status = fmt.Sprintf("BELOW FLOOR %s — %s", c.Floor, c.FloorReason)
			floorViolations++
		case r.Latest != "" && r.Latest != "?" && components.SemverLess(r.Pinned, r.Latest):
			r.Status = "update available"
		case r.Latest == "" || r.Latest == "?":
			r.Status = "ok (latest unknown)"
			if offline {
				r.Status = "ok"
			}
		default:
			r.Status = "ok"
		}
		rows = append(rows, r)
	}

	// Local host tools ride along in the same report: their "pin" is
	// the tested floor, and sitting below it counts as a violation.
	for _, t := range components.CheckTools() {
		r := row{Component: t.Name + " (local)", Pinned: "≥ " + t.Floor, Installed: t.Installed}
		switch t.Action {
		case "ok":
			r.Status = "ok"
		case "install":
			r.Status = "MISSING — 'sandboxctl up' auto-installs it"
			floorViolations++
		case "upgrade":
			r.Status = "BELOW FLOOR " + t.Floor + " — 'sandboxctl up' auto-upgrades it"
			floorViolations++
		default:
			r.Status = "version unparseable — left untouched"
		}
		rows = append(rows, r)
	}

	if jsonOut {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		_ = enc.Encode(rows)
	} else {
		fmt.Printf("%-14s %-22s %-22s %-12s %s\n", "COMPONENT", "PINNED (chart→app)", "LATEST (chart→app)", "INSTALLED", "STATUS")
		for _, r := range rows {
			pinned := r.Pinned
			if r.PinnedApp != "" && r.PinnedApp != r.Pinned {
				pinned += " → " + r.PinnedApp
			}
			if r.Overridden {
				pinned += " (env)"
			}
			latest := r.Latest
			if latest == "" {
				latest = "(offline)"
			} else if r.LatestApp != "" && r.LatestApp != r.Latest {
				latest += " → " + r.LatestApp
			}
			inst := r.Installed
			if inst == "" {
				inst = "-"
			}
			fmt.Printf("%-14s %-22s %-22s %-12s %s\n", r.Component, pinned, latest, inst, r.Status)
		}
		if floorViolations > 0 {
			fmt.Fprintf(os.Stderr, "\n%d component(s) below a compatibility floor\n", floorViolations)
		}
	}

	if floorViolations > 0 {
		return 1
	}
	return 0
}

// runToolCheck implements the hidden `_tool-check` consumed by
// sandbox.sh's toolchain auto-heal. One line per tool:
//
//	<name> <installed|-> <floor> <ok|install|upgrade|unknown>
func runToolCheck(_ []string) int {
	for _, t := range components.CheckTools() {
		installed := t.Installed
		if installed == "" {
			installed = "-"
		}
		fmt.Printf("%s %s %s %s\n", t.Name, installed, t.Floor, t.Action)
	}
	return 0
}

// runResolveLatest implements the hidden `_resolve-latest <component>`
// consumed by sandbox.sh's *_CHART_VERSION=latest channel and by the
// bump workflow. Prints the version on stdout, nothing else.
func runResolveLatest(args []string) int {
	if len(args) != 1 {
		fmt.Fprintln(os.Stderr, "usage: sandboxctl _resolve-latest <component>")
		return 2
	}
	c, ok := components.Lookup(args[0])
	if !ok {
		fmt.Fprintf(os.Stderr, "_resolve-latest: unknown component %q (known: %s)\n", args[0], componentNames())
		return 2
	}
	v, _, err := c.Latest()
	if err != nil {
		fmt.Fprintf(os.Stderr, "_resolve-latest: %v\n", err)
		return 1
	}
	fmt.Println(v)
	return 0
}

// runSemverLt implements the hidden `_semver-lt <a> <b>`: exit 0 when
// a < b, 1 otherwise — bash-friendly for floor warnings.
func runSemverLt(args []string) int {
	if len(args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: sandboxctl _semver-lt <a> <b>")
		return 2
	}
	if components.SemverLess(args[0], args[1]) {
		return 0
	}
	return 1
}

// runRenderArgs implements the hidden `_render-args <component>`: the
// exact --set profile `up` installs with, one value per line, for the
// bump workflow's helm-template render check.
func runRenderArgs(args []string) int {
	if len(args) != 1 {
		fmt.Fprintln(os.Stderr, "usage: sandboxctl _render-args <component>")
		return 2
	}
	c, ok := components.Lookup(args[0])
	if !ok {
		fmt.Fprintf(os.Stderr, "_render-args: unknown component %q (known: %s)\n", args[0], componentNames())
		return 2
	}
	for _, a := range c.RenderArgs {
		fmt.Println(a)
	}
	// The chart source goes last so the workflow can consume everything
	// from one call: repo|chart or the oci ref.
	if strings.HasPrefix(c.RepoURL, "oci://") {
		fmt.Println("@source=" + c.RepoURL)
	} else {
		fmt.Println("@source=" + c.RepoURL + "|" + c.Chart)
	}
	return 0
}

func componentNames() string {
	var names []string
	for _, c := range components.Registry {
		names = append(names, c.Name)
	}
	return strings.Join(names, ", ")
}
