package components

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"testing"
)

func TestSemverLess(t *testing.T) {
	cases := []struct {
		a, b string
		want bool
	}{
		{"1.1.1", "1.10.8", true},
		{"1.10.8", "1.1.1", false},
		{"9.5.13", "10.1.3", true},
		{"v1.16.2", "v1.21.0", true},
		{"1.30.2", "1.30.2", false},
		{"1.2", "1.2.1", true},
		{"2.2.11", "2.2.14", true},
		{"1.11.0-rc.2", "1.11.0", true}, // prerelease sorts before release
		{"1.10.8", "1.11.0-rc.2", true}, // ...but after earlier releases
		{"garbage", "1.0.0", false},     // string fallback: "garbage" > "1.0.0"
	}
	for _, c := range cases {
		if got := SemverLess(c.a, c.b); got != c.want {
			t.Errorf("SemverLess(%q, %q) = %v, want %v", c.a, c.b, got, c.want)
		}
	}
}

func TestLatestFromIndex(t *testing.T) {
	index := []byte(`
entries:
  demo:
    - version: 1.2.0
      appVersion: v0.9.0
    - version: 1.10.1
      appVersion: v1.1.0
    - version: 1.11.0-rc.1
      appVersion: v1.2.0-rc.1
    - version: 1.9.9
      appVersion: v1.0.0
  other:
    - version: 9.9.9
`)
	v, app, err := LatestFromIndex(index, "demo")
	if err != nil {
		t.Fatal(err)
	}
	if v != "1.10.1" || app != "v1.1.0" {
		t.Fatalf("latest = %s/%s, want 1.10.1/v1.1.0 (prerelease excluded)", v, app)
	}
	if _, _, err := LatestFromIndex(index, "missing"); err == nil {
		t.Fatal("missing chart accepted")
	}
}

func TestFloorViolated(t *testing.T) {
	kargo, ok := Lookup("kargo")
	if !ok {
		t.Fatal("kargo not in registry")
	}
	if !kargo.FloorViolated("1.1.1") {
		t.Fatal("1.1.1 should violate the 1.3.0 floor")
	}
	if kargo.FloorViolated("1.10.8") {
		t.Fatal("1.10.8 must not violate the floor")
	}
}

func TestPinnedHonoursEnvOverride(t *testing.T) {
	c, _ := Lookup("argo-cd")
	t.Setenv(c.EnvVar, "9.9.9")
	v, overridden := c.Pinned()
	if v != "9.9.9" || !overridden {
		t.Fatalf("override ignored: %s/%v", v, overridden)
	}
	t.Setenv(c.EnvVar, "latest")
	if v, overridden = c.Pinned(); v != c.Default || overridden {
		t.Fatalf("latest must fall through to the default for pin display: %s/%v", v, overridden)
	}
}

// TestRegistryLockstepWithSandboxSh enforces the single most important
// invariant of this package: the Go defaults and the sandbox.sh
// *_CHART_VERSION defaults never drift. Skipped when the script isn't
// present (installed-binary contexts); always present in CI and dev.
func TestRegistryLockstepWithSandboxSh(t *testing.T) {
	script, err := os.ReadFile(filepath.Join("..", "..", "..", "sandbox.sh"))
	if err != nil {
		t.Skipf("sandbox.sh not found: %v", err)
	}
	for _, c := range Registry {
		re := regexp.MustCompile(fmt.Sprintf(`%s="\$\{%s:-([^}]+)\}"`, c.EnvVar, c.EnvVar))
		m := re.FindSubmatch(script)
		if m == nil {
			t.Errorf("%s: no default found in sandbox.sh for %s", c.Name, c.EnvVar)
			continue
		}
		if got := string(m[1]); got != c.Default {
			t.Errorf("%s: sandbox.sh default %q != registry default %q — bump both together", c.Name, got, c.Default)
		}
	}
}
