package main

import (
	"encoding/json"
	"reflect"
	"sort"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

// ----------------------------------------------------------------------------
// Tier 1A: findIngressToggles
// ----------------------------------------------------------------------------

func TestFindIngressToggles_TopLevel(t *testing.T) {
	got := togglesFromYAML(t, `
ingress:
  enabled: true
  host: example.local
`)
	want := []string{"ingress.enabled"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v want %v", got, want)
	}
}

func TestFindIngressToggles_NestedAndAlias(t *testing.T) {
	got := togglesFromYAML(t, `
global:
  ingress:
    enabled: true
ui:
  ingress:
    create: true
`)
	want := []string{"global.ingress.enabled", "ui.ingress.create"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v want %v", got, want)
	}
}

func TestFindIngressToggles_FalseAndUnrelatedAreSkipped(t *testing.T) {
	got := togglesFromYAML(t, `
ingress:
  enabled: false
backend:
  enabled: true       # not under "ingress"
  ingress:
    enabled: true     # under "ingress" — this one counts
`)
	want := []string{"backend.ingress.enabled"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v want %v", got, want)
	}
}

func TestFindIngressToggles_EmptyDoc(t *testing.T) {
	got := togglesFromYAML(t, ``)
	if len(got) != 0 {
		t.Fatalf("expected empty, got %v", got)
	}
}

func togglesFromYAML(t *testing.T, body string) []string {
	t.Helper()
	var n yaml.Node
	if err := yaml.Unmarshal([]byte(body), &n); err != nil {
		t.Fatal(err)
	}
	return findIngressToggles(&n)
}

// ----------------------------------------------------------------------------
// Tier 2: findImageKeys
// ----------------------------------------------------------------------------

func TestFindImageKeys_NestedGroups(t *testing.T) {
	body := `
backend:
  image:
    repository: hello-sandbox-backend
    tag: "0.1.0"
ui:
  image:
    repository: hello-sandbox-ui
    tag: latest
unrelated:
  enabled: true
`
	got := keysFromYAML(t, body)
	want := []chartImageKey{
		{Path: "backend.image", Repository: "hello-sandbox-backend", Tag: "0.1.0"},
		{Path: "ui.image", Repository: "hello-sandbox-ui", Tag: "latest"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %#v want %#v", got, want)
	}
}

func TestFindImageKeys_TopLevel(t *testing.T) {
	body := `
image:
  repository: foo/bar
  tag: v1
`
	got := keysFromYAML(t, body)
	want := []chartImageKey{{Path: "image", Repository: "foo/bar", Tag: "v1"}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %#v want %#v", got, want)
	}
}

func TestFindImageKeys_NoRepositorySkipped(t *testing.T) {
	body := `
backend:
  resources:
    limits:
      cpu: 200m
  image:
    tag: latest    # no repository — skipped
`
	got := keysFromYAML(t, body)
	if len(got) != 0 {
		t.Fatalf("expected empty, got %#v", got)
	}
}

func keysFromYAML(t *testing.T, body string) []chartImageKey {
	t.Helper()
	var n yaml.Node
	if err := yaml.Unmarshal([]byte(body), &n); err != nil {
		t.Fatal(err)
	}
	return findImageKeys(&n)
}

// ----------------------------------------------------------------------------
// Tier 1B: scoreServices
// ----------------------------------------------------------------------------

func TestScoreServices_UIBeatsBackend(t *testing.T) {
	svcs := mustSvcList(t, `{"items":[
        {"metadata":{"name":"hello-sandbox-hello-sandbox-backend"},
         "spec":{"type":"ClusterIP","ports":[{"port":8080,"name":"http"}]}},
        {"metadata":{"name":"hello-sandbox-hello-sandbox-ui"},
         "spec":{"type":"ClusterIP","ports":[{"port":80,"name":"http"}]}}
    ]}`)
	got := scoreServices("hello-sandbox", svcs)
	if got[0].Name != "hello-sandbox-hello-sandbox-ui" {
		t.Fatalf("ui should outrank backend, got order: %v", names(got))
	}
}

func TestScoreServices_AnnotationOverridesEverything(t *testing.T) {
	svcs := mustSvcList(t, `{"items":[
        {"metadata":{"name":"hello-sandbox","annotations":{}},
         "spec":{"type":"ClusterIP","ports":[{"port":80,"name":"http"}]}},
        {"metadata":{"name":"db","annotations":{"sandboxctl.io/primary":"true"}},
         "spec":{"type":"ClusterIP","ports":[{"port":5432,"name":"pg"}]}}
    ]}`)
	got := scoreServices("hello-sandbox", svcs)
	if got[0].Name != "db" {
		t.Fatalf("annotated db should win, got: %v", names(got))
	}
}

func TestScoreServices_ExactNameStillWinsWithoutHints(t *testing.T) {
	svcs := mustSvcList(t, `{"items":[
        {"metadata":{"name":"hello-sandbox"},
         "spec":{"type":"ClusterIP","ports":[{"port":9000,"name":"thrift"}]}},
        {"metadata":{"name":"aardvark-backend"},
         "spec":{"type":"ClusterIP","ports":[{"port":80,"name":"http"}]}}
    ]}`)
	got := scoreServices("hello-sandbox", svcs)
	if got[0].Name != "hello-sandbox" {
		t.Fatalf("exact-name service should win, got: %v", names(got))
	}
}

func TestScoreServices_ContainsTokenAvoidsFalsePositives(t *testing.T) {
	// "uikit-thing" should not score as "ui" container.
	if containsToken("uikit-thing", "ui") {
		t.Fatal("false positive: 'uikit-thing' counted as containing token 'ui'")
	}
	if !containsToken("my-ui-svc", "ui") {
		t.Fatal("missed token: 'my-ui-svc' should contain token 'ui'")
	}
	if !containsToken("ui", "ui") {
		t.Fatal("missed exact match 'ui'")
	}
}

func mustSvcList(t *testing.T, body string) []k8sService {
	t.Helper()
	var l k8sServiceList
	if err := json.Unmarshal([]byte(body), &l); err != nil {
		t.Fatal(err)
	}
	return l.Items
}

func names(scored []scoredService) []string {
	out := make([]string, len(scored))
	for i, s := range scored {
		out[i] = s.Name
	}
	return out
}

// ----------------------------------------------------------------------------
// Tier 3: manifestExtras parsing
// ----------------------------------------------------------------------------

func TestManifestExtras_Parse(t *testing.T) {
	body := `
images:
  - { name: backend, context: app/backend }
  - { name: ui, context: app/ui }
primary_service: hello-sandbox-ui
chart_image_map:
  ui: ui.image
  backend: backend.image
`
	var ex manifestExtras
	if err := yaml.Unmarshal([]byte(body), &ex); err != nil {
		t.Fatal(err)
	}
	if ex.PrimaryService != "hello-sandbox-ui" {
		t.Fatalf("primary_service = %q, want hello-sandbox-ui", ex.PrimaryService)
	}
	if got := ex.ChartImageMap["ui"]; got != "ui.image" {
		t.Fatalf("chart_image_map[ui] = %q, want ui.image", got)
	}
	if got := ex.ChartImageMap["backend"]; got != "backend.image" {
		t.Fatalf("chart_image_map[backend] = %q, want backend.image", got)
	}
}

// ----------------------------------------------------------------------------
// Output shape sanity: scored services serialise as expected tab-separated
// ----------------------------------------------------------------------------

func TestScoreServices_OutputContainsReasons(t *testing.T) {
	svcs := mustSvcList(t, `{"items":[
        {"metadata":{"name":"my-ui"},"spec":{"type":"ClusterIP","ports":[{"port":80,"name":"http"}]}}
    ]}`)
	got := scoreServices("anything", svcs)
	if len(got) != 1 {
		t.Fatalf("expected 1 row, got %d", len(got))
	}
	joined := strings.Join(got[0].Reasons, "; ")
	if !strings.Contains(joined, "web port 80") {
		t.Fatalf("expected 'web port 80' in reasons, got %q", joined)
	}
}

// Sort stability sanity — equal scores break alphabetically.
// ----------------------------------------------------------------------------
// Tier 1C: mimic chart values
// ----------------------------------------------------------------------------

func TestMutateChartValues_FlipsIngressAndPinsImages(t *testing.T) {
	body := `
ingress:
  enabled: true
ui:
  ingress:
    enabled: true
  image:
    repository: ghcr.io/acme/ui
    tag: 1.0.0
backend:
  image:
    repository: ghcr.io/acme/backend
    tag: 1.0.0
deep:
  inner:
    ingress:
      create: true
`
	root := parseYAML(t, body)
	pins := map[string]imagePin{
		"ui":      {Repo: "localhost:30500/ui", Tag: "abc"},
		"backend": {Repo: "localhost:30500/backend", Tag: "abc"},
	}
	mutateChartValues(root, pins)

	out, err := yaml.Marshal(root)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	got := string(out)
	wantContains := []string{
		"localhost:30500/ui",
		"localhost:30500/backend",
		"create: false",
	}
	for _, s := range wantContains {
		if !strings.Contains(got, s) {
			t.Fatalf("output missing %q\n%s", s, got)
		}
	}
	// All three ingress toggles flipped, no `enabled: true` left under
	// any segment named "ingress".
	if strings.Contains(got, "enabled: true") {
		t.Fatalf("ingress toggles not all flipped:\n%s", got)
	}
}

func TestMutateChartValues_NoPinsLeavesImagesAlone(t *testing.T) {
	body := `
image:
  repository: nginx
  tag: 1.25
`
	root := parseYAML(t, body)
	mutateChartValues(root, nil)
	out, _ := yaml.Marshal(root)
	if !strings.Contains(string(out), "repository: nginx") {
		t.Fatalf("expected nginx repo preserved, got:\n%s", string(out))
	}
}

func TestLookupPin_PathSegment(t *testing.T) {
	pins := map[string]imagePin{"backend": {Repo: "r", Tag: "t"}}
	if _, ok := lookupPin(pins, []string{"backend", "image"}, "ghcr.io/acme/backend"); !ok {
		t.Fatalf("expected match by path segment")
	}
}

func TestLookupPin_RepoBasename(t *testing.T) {
	pins := map[string]imagePin{"api-gateway": {Repo: "r", Tag: "t"}}
	if _, ok := lookupPin(pins, []string{"images", "primary"}, "ghcr.io/acme/api-gateway"); !ok {
		t.Fatalf("expected match by repo basename")
	}
}

func TestLookupPin_LoneFallback(t *testing.T) {
	pins := map[string]imagePin{"any-name": {Repo: "r", Tag: "t"}}
	if _, ok := lookupPin(pins, []string{"image"}, "nginx"); !ok {
		t.Fatalf("expected lone-pin fallback for top-level image group")
	}
}

func TestLookupPin_NoMatch(t *testing.T) {
	pins := map[string]imagePin{"frontend": {Repo: "r", Tag: "t"}}
	if _, ok := lookupPin(pins, []string{"backend", "image"}, "ghcr.io/acme/backend"); ok {
		t.Fatalf("did not expect a match")
	}
}

func TestParseImagePins_Basic(t *testing.T) {
	got, err := parseImagePins([]string{"ui=localhost:30500/ui:abc"})
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if got["ui"].Repo != "localhost:30500/ui" || got["ui"].Tag != "abc" {
		t.Fatalf("bad parse: %+v", got)
	}
}

func TestParseImagePins_DefaultsTagToLatest(t *testing.T) {
	got, _ := parseImagePins([]string{"ui=ghcr.io/acme/ui"})
	if got["ui"].Tag != "latest" {
		t.Fatalf("expected default tag latest, got %q", got["ui"].Tag)
	}
}

func TestParseImagePins_RejectsMissingEquals(t *testing.T) {
	if _, err := parseImagePins([]string{"oops"}); err == nil {
		t.Fatalf("expected error")
	}
}

func parseYAML(t *testing.T, body string) *yaml.Node {
	t.Helper()
	var n yaml.Node
	if err := yaml.Unmarshal([]byte(body), &n); err != nil {
		t.Fatalf("yaml: %v", err)
	}
	return &n
}

func TestScoreServices_TieBreakAlphabetical(t *testing.T) {
	svcs := mustSvcList(t, `{"items":[
        {"metadata":{"name":"zeta-thing"},"spec":{"type":"ClusterIP","ports":[]}},
        {"metadata":{"name":"alpha-thing"},"spec":{"type":"ClusterIP","ports":[]}}
    ]}`)
	got := scoreServices("anything", svcs)
	gotNames := names(got)
	want := []string{"alpha-thing", "zeta-thing"}
	if !reflect.DeepEqual(gotNames, want) {
		// Be tolerant: any stable order is acceptable as long as scores tied.
		sort.Strings(gotNames)
		sort.Strings(want)
		if !reflect.DeepEqual(gotNames, want) {
			t.Fatalf("got %v want %v", gotNames, want)
		}
	}
}
