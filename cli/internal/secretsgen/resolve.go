package secretsgen

// Cluster-aware secret resolution: the values for platform services
// (Postgres/CNPG, ClickHouse, Redis, NATS, Gitea, …) already live in
// the sandbox cluster's Secrets and Services — so scaffold/deploy can
// fill k8s/secrets.yaml themselves and leave placeholders only for
// truly external credentials. The matching logic is pure (fed kubectl
// JSON) so it is table-testable; only FetchClusterState touches the
// cluster, read-only, via the sandbox-owned kubeconfig.
//
// Resolution order per variable:
//  1. explicit mapping from sandboxctl.yaml:
//       secrets:
//         resolve:
//           DATABASE_URL: secret://cnpg/app-db/uri
//           CLICKHOUSE_HOST: service://clickhouse/clickhouse:8123
//           FEATURE_FLAG: "on"            # plain literal
//  2. built-in token matching: CLICKHOUSE_PASSWORD → the unique Secret
//     whose name carries "clickhouse", key matching password/…;
//     REDIS_HOST → the unique Service carrying "redis", as
//     <name>.<ns>.svc.cluster.local. Ambiguity resolves to NOTHING —
//     a wrong credential is worse than a placeholder.
//
// Values are never logged; only their sources are.

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"gopkg.in/yaml.v3"
)

// ClusterState is the raw read-only snapshot resolution works from.
type ClusterState struct {
	ServicesJSON []byte
	SecretsJSON  []byte
}

// FetchClusterState reads Services + Secrets from the sandbox cluster.
// Returns nil when the cluster doesn't answer — callers treat that as
// "resolution unavailable", never an error.
func FetchClusterState() *ClusterState {
	kubectl, err := exec.LookPath("kubectl")
	if err != nil {
		return nil
	}
	home, _ := os.UserHomeDir()
	stateDir := os.Getenv("SANDBOX_STATE_DIR")
	if stateDir == "" {
		stateDir = home + "/.sandboxctl"
	}
	kubeconfig := os.Getenv("SANDBOX_KUBECONFIG")
	if kubeconfig == "" {
		kubeconfig = stateDir + "/kubeconfig"
	}
	cluster := os.Getenv("SANDBOX_CLUSTER_NAME")
	if cluster == "" {
		cluster = "sandboxctl"
	}
	get := func(kind string) []byte {
		cmd := exec.Command(kubectl, "--context", "kind-"+cluster,
			"--request-timeout=5s", "get", kind, "-A", "-o", "json")
		cmd.Env = append(os.Environ(), "KUBECONFIG="+kubeconfig)
		out, err := cmd.Output()
		if err != nil {
			return nil
		}
		return out
	}
	svcs := get("services")
	if svcs == nil {
		return nil
	}
	return &ClusterState{ServicesJSON: svcs, SecretsJSON: get("secrets")}
}

// Resolution is one resolved variable. Value is sensitive; Source is
// what gets logged.
type Resolution struct {
	Value  string
	Source string
}

type k8sSvc struct {
	Namespace string
	Name      string
	Ports     []int
}

type k8sSecret struct {
	Namespace string
	Name      string
	Data      map[string]string // decoded values
}

// suffix kinds the built-in matcher understands.
var suffixKinds = []struct {
	re   *regexp.Regexp
	kind string
}{
	{regexp.MustCompile(`_(URL|URI|DSN)$`), "url"},
	{regexp.MustCompile(`_(HOST|HOSTNAME|ADDR|ADDRESS|ENDPOINT)$`), "host"},
	{regexp.MustCompile(`_(PORT)$`), "port"},
	{regexp.MustCompile(`_(PASSWORD|PASSWD|PASS)$`), "password"},
	{regexp.MustCompile(`_(USER|USERNAME)$`), "username"},
}

var (
	passwordKeyRe = regexp.MustCompile(`(?i)(^|[-_.])(password|passwd)($|[-_.])`)
	usernameKeyRe = regexp.MustCompile(`(?i)(^|[-_.])(user|username)($|[-_.])`)
	urlKeyRe      = regexp.MustCompile(`(?i)(^|[-_.])(uri|url|dsn)($|[-_.])`)
)

// Resolve maps each variable to a value, when it can do so safely.
func Resolve(vars []string, state *ClusterState, overrides map[string]string) map[string]Resolution {
	out := map[string]Resolution{}
	if state == nil && len(overrides) == 0 {
		return out
	}
	svcs, secrets := parseState(state)

	for _, name := range vars {
		if mapped, ok := overrides[name]; ok {
			if r, ok := resolveMapping(mapped, svcs, secrets); ok {
				out[name] = r
			}
			continue
		}
		if r, ok := resolveBuiltin(name, svcs, secrets); ok {
			out[name] = r
		}
	}
	return out
}

func parseState(state *ClusterState) ([]k8sSvc, []k8sSecret) {
	if state == nil {
		return nil, nil
	}
	var svcList struct {
		Items []struct {
			Metadata struct {
				Namespace string `json:"namespace"`
				Name      string `json:"name"`
			} `json:"metadata"`
			Spec struct {
				Ports []struct {
					Port int `json:"port"`
				} `json:"ports"`
			} `json:"spec"`
		} `json:"items"`
	}
	_ = json.Unmarshal(state.ServicesJSON, &svcList)
	var svcs []k8sSvc
	for _, it := range svcList.Items {
		s := k8sSvc{Namespace: it.Metadata.Namespace, Name: it.Metadata.Name}
		for _, p := range it.Spec.Ports {
			s.Ports = append(s.Ports, p.Port)
		}
		svcs = append(svcs, s)
	}

	var secList struct {
		Items []struct {
			Metadata struct {
				Namespace string `json:"namespace"`
				Name      string `json:"name"`
			} `json:"metadata"`
			Type string            `json:"type"`
			Data map[string]string `json:"data"` // base64
		} `json:"items"`
	}
	_ = json.Unmarshal(state.SecretsJSON, &secList)
	var secrets []k8sSecret
	for _, it := range secList.Items {
		// Skip machinery secrets — credentials never live there, and
		// matching against them only creates ambiguity.
		if strings.HasPrefix(it.Type, "kubernetes.io/") || it.Type == "helm.sh/release.v1" {
			continue
		}
		s := k8sSecret{Namespace: it.Metadata.Namespace, Name: it.Metadata.Name, Data: map[string]string{}}
		for k, v := range it.Data {
			if dec, err := base64Decode(v); err == nil {
				s.Data[k] = dec
			}
		}
		secrets = append(secrets, s)
	}
	return svcs, secrets
}

// resolveMapping handles the explicit forms:
//
//	secret://<ns>/<name>/<key>
//	service://<ns>/<name>[:<port>]     → host[:port] as one value
//	anything else                      → literal
func resolveMapping(mapped string, svcs []k8sSvc, secrets []k8sSecret) (Resolution, bool) {
	switch {
	case strings.HasPrefix(mapped, "secret://"):
		parts := strings.SplitN(strings.TrimPrefix(mapped, "secret://"), "/", 3)
		if len(parts) != 3 {
			return Resolution{}, false
		}
		for _, s := range secrets {
			if s.Namespace == parts[0] && s.Name == parts[1] {
				if v, ok := s.Data[parts[2]]; ok {
					return Resolution{Value: v, Source: "secret " + parts[0] + "/" + parts[1] + " key " + parts[2]}, true
				}
			}
		}
		return Resolution{}, false
	case strings.HasPrefix(mapped, "service://"):
		ref := strings.TrimPrefix(mapped, "service://")
		port := ""
		if i := strings.LastIndexByte(ref, ':'); i > strings.IndexByte(ref, '/') {
			port = ref[i+1:]
			ref = ref[:i]
		}
		parts := strings.SplitN(ref, "/", 2)
		if len(parts) != 2 {
			return Resolution{}, false
		}
		for _, s := range svcs {
			if s.Namespace == parts[0] && s.Name == parts[1] {
				host := svcDNS(s)
				if port != "" {
					host += ":" + port
				}
				return Resolution{Value: host, Source: "service " + parts[0] + "/" + parts[1]}, true
			}
		}
		return Resolution{}, false
	default:
		return Resolution{Value: mapped, Source: "sandboxctl.yaml literal"}, true
	}
}

// resolveBuiltin implements token matching: the variable's leading
// segments name the service, the suffix names what is wanted.
func resolveBuiltin(varName string, svcs []k8sSvc, secrets []k8sSecret) (Resolution, bool) {
	kind := ""
	base := varName
	for _, s := range suffixKinds {
		if s.re.MatchString(varName) {
			kind = s.kind
			base = s.re.ReplaceAllString(varName, "")
			break
		}
	}
	if kind == "" || base == "" {
		return Resolution{}, false
	}
	tokens := strings.Split(strings.ToLower(base), "_")

	switch kind {
	case "host", "port":
		svc, ok := uniqueSvc(svcs, tokens)
		if !ok {
			return Resolution{}, false
		}
		if kind == "host" {
			return Resolution{Value: svcDNS(svc), Source: "service " + svc.Namespace + "/" + svc.Name}, true
		}
		if len(svc.Ports) == 0 {
			return Resolution{}, false
		}
		return Resolution{Value: strconv.Itoa(svc.Ports[0]), Source: "service " + svc.Namespace + "/" + svc.Name}, true
	case "password", "username", "url":
		keyRe := passwordKeyRe
		if kind == "username" {
			keyRe = usernameKeyRe
		}
		if kind == "url" {
			keyRe = urlKeyRe
		}
		sec, key, ok := uniqueSecretKey(secrets, tokens, keyRe)
		if !ok {
			return Resolution{}, false
		}
		return Resolution{Value: sec.Data[key], Source: "secret " + sec.Namespace + "/" + sec.Name + " key " + key}, true
	}
	return Resolution{}, false
}

// uniqueSvc returns the single Service whose name carries every token.
func uniqueSvc(svcs []k8sSvc, tokens []string) (k8sSvc, bool) {
	var hits []k8sSvc
	for _, s := range svcs {
		if nameCarries(s.Name, tokens) {
			hits = append(hits, s)
		}
	}
	if len(hits) != 1 {
		return k8sSvc{}, false
	}
	return hits[0], true
}

// uniqueSecretKey returns the single (secret, key) whose secret name
// carries every token and whose key matches the kind regex.
func uniqueSecretKey(secrets []k8sSecret, tokens []string, keyRe *regexp.Regexp) (k8sSecret, string, bool) {
	type hit struct {
		sec k8sSecret
		key string
	}
	var hits []hit
	for _, s := range secrets {
		if !nameCarries(s.Name, tokens) {
			continue
		}
		var keys []string
		for k := range s.Data {
			if keyRe.MatchString(k) {
				keys = append(keys, k)
			}
		}
		sort.Strings(keys)
		for _, k := range keys {
			hits = append(hits, hit{s, k})
		}
	}
	if len(hits) != 1 {
		return k8sSecret{}, "", false
	}
	return hits[0].sec, hits[0].key, true
}

func nameCarries(name string, tokens []string) bool {
	n := strings.ToLower(name)
	for _, t := range tokens {
		if t == "" || !strings.Contains(n, t) {
			return false
		}
	}
	return true
}

func svcDNS(s k8sSvc) string {
	return fmt.Sprintf("%s.%s.svc.cluster.local", s.Name, s.Namespace)
}

// LoadResolveOverrides reads sandboxctl.yaml's secrets.resolve map.
func LoadResolveOverrides(root string) map[string]string {
	var doc struct {
		Secrets struct {
			Resolve map[string]string `yaml:"resolve"`
		} `yaml:"secrets"`
	}
	for _, base := range []string{"sandboxctl.yaml", "sandboxctl.yml"} {
		if data, err := os.ReadFile(root + "/" + base); err == nil {
			_ = yaml.Unmarshal(data, &doc)
			break
		}
	}
	return doc.Secrets.Resolve
}

func base64Decode(s string) (string, error) {
	dec, err := base64.StdEncoding.DecodeString(s)
	if err != nil {
		return "", err
	}
	return string(dec), nil
}
