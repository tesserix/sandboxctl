package components

import (
	"os/exec"
	"strings"
)

// Tool is one local CLI the sandbox depends on, with the minimum
// version the current sandboxctl is tested against. Floors are
// deliberately loose — old enough not to churn users' machines, new
// enough that known-broken combinations sit below them.
type Tool struct {
	Name  string
	Floor string
	// version extracts the installed version string from the tool's
	// output, "" when unparseable.
	version func() string
}

// ToolRegistry lists the CLIs `up` needs on the host. The container
// runtime is handled separately (setup-podman owns its lifecycle).
var ToolRegistry = []Tool{
	{Name: "kind", Floor: "0.30.0", version: kindVersion},
	{Name: "kubectl", Floor: "1.31.0", version: kubectlVersion},
	{Name: "helm", Floor: "3.16.0", version: helmVersion},
}

// ToolStatus is one row of the tool check.
type ToolStatus struct {
	Name      string
	Installed string // "" when the binary is missing
	Floor     string
	// Action is what the shell side should do: "ok", "install",
	// "upgrade", or "unknown" (version unparseable — warn, touch
	// nothing).
	Action string
}

// CheckTools classifies every registered tool.
func CheckTools() []ToolStatus {
	out := make([]ToolStatus, 0, len(ToolRegistry))
	for _, t := range ToolRegistry {
		st := ToolStatus{Name: t.Name, Floor: t.Floor}
		if _, err := exec.LookPath(t.Name); err != nil {
			st.Action = "install"
			out = append(out, st)
			continue
		}
		st.Installed = t.version()
		switch {
		case st.Installed == "":
			st.Action = "unknown"
		case SemverLess(st.Installed, t.Floor):
			st.Action = "upgrade"
		default:
			st.Action = "ok"
		}
		out = append(out, st)
	}
	return out
}

func kindVersion() string {
	// `kind version` → "kind v0.32.0 go1.26.3 darwin/arm64"
	out, err := exec.Command("kind", "version").Output()
	if err != nil {
		return ""
	}
	return ParseToolVersion("kind", string(out))
}

func kubectlVersion() string {
	// `kubectl version --client -o yaml` → contains `gitVersion: v1.35.0`
	out, err := exec.Command("kubectl", "version", "--client", "-o", "yaml").Output()
	if err != nil {
		return ""
	}
	return ParseToolVersion("kubectl", string(out))
}

func helmVersion() string {
	// `helm version --template {{.Version}}` → "v3.19.0"
	out, err := exec.Command("helm", "version", "--template", "{{.Version}}").Output()
	if err != nil {
		return ""
	}
	return ParseToolVersion("helm", string(out))
}

// ParseToolVersion extracts the semver from a tool's version output.
// Split from the exec paths so the parsing is table-testable.
func ParseToolVersion(tool, raw string) string {
	raw = strings.TrimSpace(raw)
	switch tool {
	case "kind":
		fields := strings.Fields(raw)
		if len(fields) >= 2 && strings.HasPrefix(fields[1], "v") {
			return fields[1]
		}
	case "kubectl":
		for _, line := range strings.Split(raw, "\n") {
			line = strings.TrimSpace(line)
			if v, ok := strings.CutPrefix(line, "gitVersion:"); ok {
				return strings.Trim(strings.TrimSpace(v), `"'`)
			}
		}
	case "helm":
		if strings.HasPrefix(raw, "v") {
			return strings.Fields(raw)[0]
		}
	}
	return ""
}
