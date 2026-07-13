// Package components is the registry of every third-party chart the
// sandbox installs: where it comes from, the pinned default version,
// the app version that chart ships, the compatibility floor other
// features depend on, and the exact --set profile `up` uses (so render
// checks validate what actually gets installed, not chart defaults).
//
// The pinned defaults here MUST match the *_CHART_VERSION defaults in
// sandbox.sh — a lockstep test enforces it, and the bump workflow
// updates both together.
package components

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

// Component describes one installable chart.
type Component struct {
	Name    string // registry key, e.g. "argo-cd"
	EnvVar  string // sandbox.sh override variable
	Default string // pinned chart version (lockstep with sandbox.sh)
	App     string // app version shipped by the pinned chart
	// Floor is the minimum chart version other sandboxctl features
	// require; empty means none.
	Floor       string
	FloorReason string
	// RepoURL is a classic helm repo (index.yaml) or an oci:// ref.
	RepoURL string
	Chart   string // chart name within a classic repo
	// Release is the helm release name `up` installs, for INSTALLED
	// lookups. Empty when the component spans several releases (istio).
	Release string
	// RenderArgs is the exact --set profile from sandbox.sh's installer,
	// with secrets replaced by shape-compatible dummies.
	RenderArgs []string
}

// Registry lists the components in display order.
var Registry = []Component{
	{
		Name: "argo-cd", EnvVar: "ARGOCD_CHART_VERSION", Default: "10.1.3", App: "v3.4.5",
		RepoURL: "https://argoproj.github.io/argo-helm", Chart: "argo-cd", Release: "argocd",
		RenderArgs: []string{
			`configs.params.server\.insecure=true`,
			"dex.enabled=false",
			"applicationSet.resources.requests.cpu=25m", "applicationSet.resources.requests.memory=64Mi",
			"notifications.resources.requests.cpu=10m", "notifications.resources.requests.memory=64Mi",
			"controller.replicas=1",
			"controller.resources.requests.cpu=50m", "controller.resources.requests.memory=256Mi",
			"repoServer.resources.requests.cpu=25m", "repoServer.resources.requests.memory=128Mi",
			"server.resources.requests.cpu=25m", "server.resources.requests.memory=128Mi",
			"redis.resources.requests.cpu=25m", "redis.resources.requests.memory=64Mi",
		},
	},
	{
		Name: "kargo", EnvVar: "KARGO_CHART_VERSION", Default: "1.10.8", App: "v1.10.8",
		Floor: "1.3.0", FloorReason: "scaffold-generated promotion manifests use yaml-update (helm-update-image was removed in 1.3.0)",
		RepoURL: "oci://ghcr.io/akuity/kargo-charts/kargo", Release: "kargo",
		RenderArgs: []string{
			"api.adminAccount.passwordHash=$2a$10$dummydummydummydummydummydummydummydummydummydummyddd",
			"api.adminAccount.tokenSigningKey=dummysigningkeydummysigningkey",
			"controller.argocd.namespace=argocd",
			"api.resources.requests.cpu=25m", "api.resources.requests.memory=128Mi",
			"controller.resources.requests.cpu=25m", "controller.resources.requests.memory=128Mi",
		},
	},
	{
		Name: "cert-manager", EnvVar: "CERT_MANAGER_CHART_VERSION", Default: "v1.21.0", App: "v1.21.0",
		RepoURL: "https://charts.jetstack.io", Chart: "cert-manager", Release: "cert-manager",
		RenderArgs: []string{
			"crds.enabled=true",
			"resources.requests.cpu=10m", "resources.requests.memory=64Mi",
			"webhook.resources.requests.cpu=10m", "webhook.resources.requests.memory=32Mi",
			"cainjector.resources.requests.cpu=10m", "cainjector.resources.requests.memory=64Mi",
		},
	},
	{
		Name: "istio", EnvVar: "ISTIO_CHART_VERSION", Default: "1.30.2", App: "1.30.2",
		RepoURL: "https://istio-release.storage.googleapis.com/charts", Chart: "istiod",
		RenderArgs: []string{
			"profile=ambient",
			"pilot.resources.requests.cpu=50m", "pilot.resources.requests.memory=128Mi",
		},
	},
	{
		Name: "gitea", EnvVar: "GITEA_CHART_VERSION", Default: "12.6.0", App: "1.26.1",
		RepoURL: "https://dl.gitea.com/charts/", Chart: "gitea", Release: "gitea",
		RenderArgs: []string{
			"gitea.admin.username=gitea-admin", "gitea.admin.password=dummy123456",
			"gitea.admin.email=sandbox@local",
			"gitea.config.database.DB_TYPE=sqlite3", "gitea.config.cache.ADAPTER=memory",
			"gitea.config.session.PROVIDER=memory", "gitea.config.queue.TYPE=level",
			"gitea.config.indexer.ISSUE_INDEXER_TYPE=bleve",
			"valkey-cluster.enabled=false", "valkey.enabled=false",
			"postgresql-ha.enabled=false", "postgresql.enabled=false",
			"redis-cluster.enabled=false", "redis.enabled=false", "memcached.enabled=false",
			"persistence.size=1Gi", "replicaCount=1", "service.http.port=3000",
			"resources.requests.cpu=25m", "resources.requests.memory=128Mi", "resources.limits.memory=512Mi",
		},
	},
	{
		Name: "reflector", EnvVar: "REFLECTOR_CHART_VERSION", Default: "10.0.58", App: "10.0.58",
		RepoURL: "https://emberstack.github.io/helm-charts", Chart: "reflector", Release: "reflector",
		RenderArgs: []string{
			"resources.requests.cpu=10m", "resources.requests.memory=32Mi", "resources.limits.memory=128Mi",
		},
	},
	{
		Name: "reloader", EnvVar: "RELOADER_CHART_VERSION", Default: "2.2.14", App: "v1.4.19",
		RepoURL: "https://stakater.github.io/stakater-charts", Chart: "reloader", Release: "reloader",
		RenderArgs: []string{
			"reloader.deployment.resources.requests.cpu=10m",
			"reloader.deployment.resources.requests.memory=32Mi",
			"reloader.deployment.resources.limits.memory=128Mi",
		},
	},
	{
		Name: "kagent", EnvVar: "KAGENT_CHART_VERSION", Default: "0.9.11", App: "0.9.11",
		RepoURL: "oci://ghcr.io/kagent-dev/kagent/helm/kagent", Release: "kagent",
	},
}

// Lookup returns the component by name.
func Lookup(name string) (Component, bool) {
	for _, c := range Registry {
		if c.Name == name {
			return c, true
		}
	}
	return Component{}, false
}

// Pinned returns the effective chart version: the env override when
// set (and not "latest"), else the registry default.
func (c Component) Pinned() (version string, overridden bool) {
	if v := os.Getenv(c.EnvVar); v != "" && v != "latest" {
		return v, true
	}
	return c.Default, false
}

// FloorViolated reports whether version sits below the component floor.
func (c Component) FloorViolated(version string) bool {
	if c.Floor == "" {
		return false
	}
	return SemverLess(version, c.Floor)
}

// ----------------------------------------------------------------------------
// latest resolution
// ----------------------------------------------------------------------------

var httpClient = &http.Client{Timeout: 20 * time.Second}

// Latest resolves the newest stable chart version (and its app version
// when the source reports one). Classic repos are answered from
// index.yaml over plain HTTP; oci:// refs shell out to helm, which is
// the only ubiquitous OCI client on dev machines and CI runners.
func (c Component) Latest() (version, app string, err error) {
	if strings.HasPrefix(c.RepoURL, "oci://") {
		return ociLatest(c.RepoURL)
	}
	return indexLatest(c.RepoURL, c.Chart)
}

func indexLatest(repoURL, chart string) (string, string, error) {
	url := strings.TrimSuffix(repoURL, "/") + "/index.yaml"
	resp, err := httpClient.Get(url)
	if err != nil {
		return "", "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", "", fmt.Errorf("GET %s: %s", url, resp.Status)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 64<<20))
	if err != nil {
		return "", "", err
	}
	return LatestFromIndex(body, chart)
}

// LatestFromIndex picks the highest stable (non-prerelease) version of
// chart from a helm repo index.yaml. Split out for testing.
func LatestFromIndex(index []byte, chart string) (string, string, error) {
	var doc struct {
		Entries map[string][]struct {
			Version    string `yaml:"version"`
			AppVersion string `yaml:"appVersion"`
		} `yaml:"entries"`
	}
	if err := yaml.Unmarshal(index, &doc); err != nil {
		return "", "", err
	}
	entries := doc.Entries[chart]
	if len(entries) == 0 {
		return "", "", fmt.Errorf("chart %q not in index", chart)
	}
	best := -1
	for i, e := range entries {
		if _, pre, ok := parseSemver(e.Version); !ok || pre {
			continue
		}
		if best < 0 || SemverLess(entries[best].Version, e.Version) {
			best = i
		}
	}
	if best < 0 {
		return "", "", fmt.Errorf("no stable version of %q in index", chart)
	}
	return entries[best].Version, entries[best].AppVersion, nil
}

// ociLatest asks helm for the chart's newest tag. HELM_REGISTRY_CONFIG
// points at an empty file so a broken docker credential helper (common
// on macOS) can't break an anonymous pull.
func ociLatest(ref string) (string, string, error) {
	helm, err := exec.LookPath("helm")
	if err != nil {
		return "", "", fmt.Errorf("resolving %s needs helm on PATH", ref)
	}
	empty, err := os.CreateTemp("", "sandboxctl-registry-*.json")
	if err == nil {
		_, _ = empty.WriteString("{}")
		empty.Close()
		defer os.Remove(empty.Name())
	}
	cmd := exec.Command(helm, "show", "chart", ref)
	cmd.Env = append(os.Environ(), "HELM_REGISTRY_CONFIG="+empty.Name())
	out, err := cmd.Output()
	if err != nil {
		return "", "", fmt.Errorf("helm show chart %s: %w", ref, err)
	}
	var meta struct {
		Version    string `yaml:"version"`
		AppVersion string `yaml:"appVersion"`
	}
	if err := yaml.Unmarshal(out, &meta); err != nil || meta.Version == "" {
		return "", "", fmt.Errorf("could not parse chart metadata from %s", ref)
	}
	return meta.Version, meta.AppVersion, nil
}

// ----------------------------------------------------------------------------
// installed lookup
// ----------------------------------------------------------------------------

// Installed maps release name → app version from `helm ls` against the
// sandbox cluster. Best-effort: any failure returns an empty map (the
// cluster may simply not be running).
func Installed() map[string]string {
	helm, err := exec.LookPath("helm")
	if err != nil {
		return nil
	}
	cluster := os.Getenv("SANDBOX_CLUSTER_NAME")
	if cluster == "" {
		cluster = "sandboxctl"
	}
	out, err := exec.Command(helm, "ls", "-A", "-o", "yaml", "--kube-context", "kind-"+cluster).Output()
	if err != nil {
		return nil
	}
	var releases []struct {
		Name       string `yaml:"name"`
		AppVersion string `yaml:"app_version"`
		Chart      string `yaml:"chart"`
	}
	if yaml.Unmarshal(out, &releases) != nil {
		return nil
	}
	m := map[string]string{}
	for _, r := range releases {
		v := r.AppVersion
		if v == "" {
			// Fall back to the chart version suffix ("kargo-1.10.8").
			if i := strings.LastIndexByte(r.Chart, '-'); i > 0 {
				v = r.Chart[i+1:]
			}
		}
		m[r.Name] = v
	}
	return m
}

// ----------------------------------------------------------------------------
// semver
// ----------------------------------------------------------------------------

// parseSemver accepts 1.2.3, v1.2.3, and 1.2, flagging prereleases
// (anything carrying -suffix). Build metadata (+…) is ignored.
func parseSemver(s string) (nums [3]int, prerelease, ok bool) {
	s = strings.TrimPrefix(strings.TrimSpace(s), "v")
	if s == "" {
		return nums, false, false
	}
	if i := strings.IndexByte(s, '+'); i >= 0 {
		s = s[:i]
	}
	if i := strings.IndexByte(s, '-'); i >= 0 {
		prerelease = true
		s = s[:i]
	}
	parts := strings.Split(s, ".")
	if len(parts) > 3 {
		return nums, false, false
	}
	for i, p := range parts {
		n, err := strconv.Atoi(p)
		if err != nil || n < 0 {
			return nums, false, false
		}
		nums[i] = n
	}
	return nums, prerelease, true
}

// SemverLess reports a < b. Unparseable versions compare via plain
// string ordering as a last resort so the caller always gets an answer.
func SemverLess(a, b string) bool {
	av, apre, aok := parseSemver(a)
	bv, bpre, bok := parseSemver(b)
	if !aok || !bok {
		return a < b
	}
	for i := 0; i < 3; i++ {
		if av[i] != bv[i] {
			return av[i] < bv[i]
		}
	}
	// Equal numerics: a prerelease sorts before its release.
	return apre && !bpre
}

// SortVersions returns the input sorted ascending by SemverLess —
// exposed for tests and future callers.
func SortVersions(vs []string) []string {
	out := append([]string(nil), vs...)
	sort.Slice(out, func(i, j int) bool { return SemverLess(out[i], out[j]) })
	return out
}
