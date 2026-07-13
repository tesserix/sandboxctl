package secretsgen

import (
	"encoding/base64"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/tesserix/sandboxctl/cli/internal/reposcan"
)

func b64(s string) string { return base64.StdEncoding.EncodeToString([]byte(s)) }

func fixtureState() *ClusterState {
	svcJSON := `{"items":[
	 {"metadata":{"namespace":"clickhouse","name":"clickhouse"},"spec":{"ports":[{"port":8123},{"port":9000}]}},
	 {"metadata":{"namespace":"redis-ns","name":"redis-master"},"spec":{"ports":[{"port":6379}]}},
	 {"metadata":{"namespace":"pg","name":"pg-a"},"spec":{"ports":[{"port":5432}]}},
	 {"metadata":{"namespace":"pg2","name":"pg-b"},"spec":{"ports":[{"port":5432}]}}
	]}`
	secJSON := fmt.Sprintf(`{"items":[
	 {"metadata":{"namespace":"clickhouse","name":"clickhouse-admin"},"type":"Opaque","data":{"admin-password":%q,"admin-user":%q}},
	 {"metadata":{"namespace":"db","name":"app-database"},"type":"Opaque","data":{"dsn":%q}},
	 {"metadata":{"namespace":"kube-system","name":"clickhouse-token-xyz"},"type":"kubernetes.io/service-account-token","data":{"password":%q}},
	 {"metadata":{"namespace":"pg","name":"pg-a-creds"},"type":"Opaque","data":{"password":%q}},
	 {"metadata":{"namespace":"pg2","name":"pg-b-creds"},"type":"Opaque","data":{"password":%q}}
	]}`, b64("ch-secret"), b64("ch-admin"), b64("postgres://u:p@db/app"), b64("machinery"), b64("pa"), b64("pb"))
	return &ClusterState{ServicesJSON: []byte(svcJSON), SecretsJSON: []byte(secJSON)}
}

func TestResolveBuiltinMatrix(t *testing.T) {
	state := fixtureState()
	res := Resolve([]string{
		"CLICKHOUSE_PASSWORD", // unique secret + password key
		"CLICKHOUSE_USER",     // unique secret + username key
		"CLICKHOUSE_HOST",     // unique service → DNS
		"CLICKHOUSE_PORT",     // unique service → first port
		"REDIS_HOST",          // token matches redis-master
		"DATABASE_URL",        // secret app-database key dsn
		"PG_PASSWORD",         // AMBIGUOUS (pg-a-creds + pg-b-creds) → unresolved
		"STRIPE_API_KEY",      // no suffix kind → unresolved
		"MISSING_HOST",        // no matching service → unresolved
	}, state, nil)

	want := map[string]string{
		"CLICKHOUSE_PASSWORD": "ch-secret",
		"CLICKHOUSE_USER":     "ch-admin",
		"CLICKHOUSE_HOST":     "clickhouse.clickhouse.svc.cluster.local",
		"CLICKHOUSE_PORT":     "8123",
		"REDIS_HOST":          "redis-master.redis-ns.svc.cluster.local",
		"DATABASE_URL":        "postgres://u:p@db/app",
	}
	for k, v := range want {
		got, ok := res[k]
		if !ok || got.Value != v {
			t.Errorf("%s = %+v, want %q", k, got, v)
		}
		if got.Source == "" || strings.Contains(got.Source, v) {
			t.Errorf("%s source must name the origin and never leak the value: %q", k, got.Source)
		}
	}
	for _, k := range []string{"PG_PASSWORD", "STRIPE_API_KEY", "MISSING_HOST"} {
		if _, ok := res[k]; ok {
			t.Errorf("%s must stay unresolved (got %+v)", k, res[k])
		}
	}
	// The machinery secret must never have been considered: if it were,
	// CLICKHOUSE_PASSWORD would have been ambiguous.
}

func TestResolveExplicitMappings(t *testing.T) {
	state := fixtureState()
	res := Resolve(
		[]string{"MY_DSN", "CH_ENDPOINT", "FEATURE_MODE", "BROKEN_REF"},
		state,
		map[string]string{
			"MY_DSN":       "secret://db/app-database/dsn",
			"CH_ENDPOINT":  "service://clickhouse/clickhouse:9000",
			"FEATURE_MODE": "sandbox",
			"BROKEN_REF":   "secret://nope/missing/key",
		})

	if res["MY_DSN"].Value != "postgres://u:p@db/app" {
		t.Fatalf("MY_DSN = %+v", res["MY_DSN"])
	}
	if res["CH_ENDPOINT"].Value != "clickhouse.clickhouse.svc.cluster.local:9000" {
		t.Fatalf("CH_ENDPOINT = %+v", res["CH_ENDPOINT"])
	}
	if res["FEATURE_MODE"].Value != "sandbox" {
		t.Fatalf("FEATURE_MODE = %+v", res["FEATURE_MODE"])
	}
	if _, ok := res["BROKEN_REF"]; ok {
		t.Fatal("mapping to a missing secret must resolve to nothing")
	}
}

// ----------------------------------------------------------------------------
// SyncSecretsFile — the never-destroy contract
// ----------------------------------------------------------------------------

func syncApps() []reposcan.App {
	return []reposcan.App{{Name: "api", Path: "apps/api", Env: []reposcan.EnvRef{
		{Name: "CLICKHOUSE_PASSWORD", Location: "apps/api/main.go:4", Secret: true},
		{Name: "STRIPE_API_KEY", Location: "apps/api/main.go:5", Secret: true},
	}}}
}

func TestSyncCreatesWhenAbsent(t *testing.T) {
	root := t.TempDir()
	res := Resolve([]string{"CLICKHOUSE_PASSWORD", "STRIPE_API_KEY"}, fixtureState(), nil)
	rep := SyncSecretsFile(root, syncApps(), res)
	if rep.Action != "created" {
		t.Fatalf("action = %q", rep.Action)
	}
	data, _ := os.ReadFile(filepath.Join(root, "k8s/secrets.yaml"))
	body := string(data)
	if !strings.Contains(body, `CLICKHOUSE_PASSWORD: "ch-secret"   # resolved from secret clickhouse/clickhouse-admin key admin-password`) {
		t.Fatalf("resolved value missing:\n%s", body)
	}
	if !strings.Contains(body, "STRIPE_API_KEY: \"<required") {
		t.Fatalf("external key must stay a placeholder:\n%s", body)
	}
}

// TestSyncNeverRemovesUserSecrets is THE contract: someone hand-added
// keys and even whole Secret documents — a resolution pass may only
// fill placeholders, never touch or drop anything a human wrote.
func TestSyncNeverRemovesUserSecrets(t *testing.T) {
	root := t.TempDir()
	existing := `# my precious hand-tuned secrets
apiVersion: v1
kind: Secret
metadata:
  name: api-secrets
  namespace: api
type: Opaque
stringData:
  CLICKHOUSE_PASSWORD: "<required — referenced at apps/api/main.go:4>"
  STRIPE_API_KEY: "sk_live_i_typed_this"
  MY_CUSTOM_EXTRA: "added-by-hand"   # do not lose me
---
apiVersion: v1
kind: Secret
metadata:
  name: totally-custom
  namespace: api
type: Opaque
stringData:
  ONLY_MINE: "mine"
`
	p := filepath.Join(root, "k8s", "secrets.yaml")
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(existing), 0o600); err != nil {
		t.Fatal(err)
	}

	res := Resolve([]string{"CLICKHOUSE_PASSWORD", "STRIPE_API_KEY"}, fixtureState(), nil)
	rep := SyncSecretsFile(root, syncApps(), res)
	if rep.Action != "updated" {
		t.Fatalf("action = %q", rep.Action)
	}

	data, _ := os.ReadFile(p)
	body := string(data)
	for _, must := range []string{
		"ch-secret",              // placeholder filled
		"sk_live_i_typed_this",   // user-set value untouched (resolver had a match!)
		"MY_CUSTOM_EXTRA:",       // hand-added key survives
		"added-by-hand",          // ...with its value
		"ONLY_MINE:",             // whole custom document survives
		"my precious hand-tuned", // top comment survives
	} {
		if !strings.Contains(body, must) {
			t.Fatalf("lost %q:\n%s", must, body)
		}
	}
	if strings.Contains(body, "<required") {
		t.Fatalf("placeholder not filled:\n%s", body)
	}

	// Second pass: nothing left to fill → unchanged, byte-stable.
	rep = SyncSecretsFile(root, syncApps(), res)
	if rep.Action != "unchanged" || len(rep.Filled) != 0 {
		t.Fatalf("second pass: action=%q filled=%v", rep.Action, rep.Filled)
	}
	again, _ := os.ReadFile(p)
	if string(again) != body {
		t.Fatal("second pass mutated the file")
	}
}

func TestSyncSkipsWhenNothingResolvedAndNoFile(t *testing.T) {
	rep := SyncSecretsFile(t.TempDir(), syncApps(), nil)
	if !strings.HasPrefix(rep.Action, "skipped") {
		t.Fatalf("action = %q", rep.Action)
	}
}
