package main

import (
	"reflect"
	"strings"
	"testing"
)

func requireNames(reqs []manifestRequire) []string {
	out := make([]string, 0, len(reqs))
	for _, r := range reqs {
		out = append(out, r.Name)
	}
	return out
}

func TestParseRequires_OrdersNeedsFirst(t *testing.T) {
	y := `
images:
  - name: worker
requires:
  - name: worker-api
    repo: ../worker-api
    needs: [temporal]
  - name: temporal
    repo: ../temporal-service
    chart: k8s/charts/temporal-service
    values: values-local.yaml
    provides:
      service: temporal-server-frontend.temporal-service:7233
`
	reqs, warns, err := parseRequires([]byte(y))
	if err != nil {
		t.Fatalf("parseRequires: %v", err)
	}
	if len(warns) != 0 {
		t.Fatalf("unexpected warnings: %v", warns)
	}
	if got, want := requireNames(reqs), []string{"temporal", "worker-api"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("order mismatch\n got:  %v\n want: %v", got, want)
	}
	if reqs[0].Chart != "k8s/charts/temporal-service" || reqs[0].Values != "values-local.yaml" {
		t.Fatalf("chart/values not parsed: %+v", reqs[0])
	}
}

func TestParseRequires_NoBlockIsNotAnError(t *testing.T) {
	reqs, _, err := parseRequires([]byte("images:\n  - name: worker\n"))
	if err != nil {
		t.Fatalf("parseRequires: %v", err)
	}
	if len(reqs) != 0 {
		t.Fatalf("expected no requires, got %v", requireNames(reqs))
	}
}

func TestParseRequires_GitRefDefaultsToMain(t *testing.T) {
	reqs, _, err := parseRequires([]byte("requires:\n  - name: dep\n    git: https://example.com/dep.git\n"))
	if err != nil {
		t.Fatalf("parseRequires: %v", err)
	}
	if reqs[0].Ref != "main" {
		t.Fatalf("ref = %q, want main", reqs[0].Ref)
	}
}

func TestParseRequires_Rejects(t *testing.T) {
	cases := map[string]string{
		"missing name":      "requires:\n  - repo: ../dep\n",
		"no source":         "requires:\n  - name: dep\n",
		"both sources":      "requires:\n  - name: dep\n    repo: ../dep\n    git: https://x/y.git\n",
		"duplicate name":    "requires:\n  - name: dep\n    repo: ../a\n  - name: dep\n    repo: ../b\n",
		"unknown needs":     "requires:\n  - name: dep\n    repo: ../a\n    needs: [ghost]\n",
		"bare service name": "requires:\n  - name: dep\n    repo: ../a\n    provides:\n      service: frontend:7233\n",
		"non-numeric port":  "requires:\n  - name: dep\n    repo: ../a\n    provides:\n      service: frontend.ns:grpc\n",
	}
	for label, y := range cases {
		if _, _, err := parseRequires([]byte(y)); err == nil {
			t.Errorf("%s: expected an error, got none", label)
		}
	}
}

func TestParseRequires_CycleWarnsAndKeepsOrder(t *testing.T) {
	y := `
requires:
  - name: a
    repo: ../a
    needs: [b]
  - name: b
    repo: ../b
    needs: [a]
`
	reqs, warns, err := parseRequires([]byte(y))
	if err != nil {
		t.Fatalf("parseRequires: %v", err)
	}
	if len(warns) == 0 || !strings.Contains(warns[0], "cycle") {
		t.Fatalf("expected a cycle warning, got %v", warns)
	}
	if got, want := requireNames(reqs), []string{"a", "b"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("cycle should keep declared order\n got:  %v\n want: %v", got, want)
	}
}

func TestSplitProvidedService(t *testing.T) {
	cases := []struct {
		in            string
		svc, ns, port string
	}{
		{"frontend.ns:7233", "frontend", "ns", "7233"},
		{"frontend.ns.svc.cluster.local:7233", "frontend", "ns", "7233"},
		{"frontend.ns", "frontend", "ns", ""},
		{"", "", "", ""},
	}
	for _, c := range cases {
		svc, ns, port, err := splitProvidedService(c.in)
		if err != nil {
			t.Fatalf("%q: %v", c.in, err)
		}
		if svc != c.svc || ns != c.ns || port != c.port {
			t.Errorf("%q → (%q,%q,%q), want (%q,%q,%q)", c.in, svc, ns, port, c.svc, c.ns, c.port)
		}
	}
}
