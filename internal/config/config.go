package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"regexp"
	"strings"
	"time"
)

// composeNameRe constrains compose project/service names to a safe, lowercase-only subset.
var composeNameRe = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]*$`)

// Order is the canonical capability order used across generation.
var Order = []string{"document_store", "job_queue", "search", "vector", "gis", "timeseries", "dashboards", "api", "auth"}

type Config struct {
	Postgres     PostgresCfg     `json:"postgres"`
	SeedDemoData *bool           `json:"seed_demo_data"`
	Capabilities map[string]bool `json:"capabilities"`
	Languages    LanguagesCfg    `json:"languages"`
	Compose      ComposeCfg      `json:"compose"`
	Security     SecurityCfg     `json:"security"`
}

// SecurityCfg holds hardening toggles. Defaults are the safe choice.
type SecurityCfg struct {
	// AnonFutureTables, when true, restores the demo behavior of auto-granting the anonymous
	// role SELECT on every FUTURE table (ALTER DEFAULT PRIVILEGES). Default false: new tables
	// are NOT exposed to anon unless you grant them explicitly.
	AnonFutureTables bool `json:"anon_future_tables"`
	// JWTAudience, when set, is published as PGRST_JWT_AUD (PostgREST then requires a matching
	// `aud` claim) and is embedded in tokens minted by `postgres4all mint-token`.
	JWTAudience string `json:"jwt_audience"`
	// JWTTTL is the default lifetime for `mint-token` (Go duration, e.g. "15m"). Empty = 15m.
	JWTTTL string `json:"jwt_ttl"`
}

// ComposeCfg names the generated docker compose stack and its services. All optional:
// an empty Project leaves the project name to docker compose (the build dir); a service
// not listed in Services keeps its canonical name (db, postgrest).
type ComposeCfg struct {
	Project  string            `json:"project"`
	Services map[string]string `json:"services"` // keyed by canonical name: "db", "postgrest"
}
type PostgresCfg struct {
	User              string `json:"user"`
	DB                string `json:"db"`
	Password          string `json:"password"`
	PublishExternally bool   `json:"publish_externally"`
}
type LanguagesCfg struct {
	PLPerl         bool `json:"plperl"`
	PLPython       bool `json:"plpython"`
	AllowUntrusted bool `json:"allow_untrusted"`
}

func Load(path string) (*Config, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading config %s: %w", path, err)
	}
	var c Config
	if err := json.Unmarshal(b, &c); err != nil {
		return nil, fmt.Errorf("parsing config %s: %w", path, err)
	}
	c.ApplyDefaults()
	return &c, nil
}

func (c *Config) ApplyDefaults() {
	if c.Postgres.User == "" {
		c.Postgres.User = "postgres"
	}
	if c.Postgres.DB == "" {
		c.Postgres.DB = "app"
	}
	if c.Capabilities == nil {
		c.Capabilities = map[string]bool{}
	}
}

func (c *Config) Seed() bool { return c.SeedDemoData == nil || *c.SeedDemoData }

func (c *Config) Enabled(cap string) bool { return c.Capabilities[cap] }

// ProjectName is the docker compose project name (empty = let compose default to the build dir).
func (c *Config) ProjectName() string { return c.Compose.Project }

// DBService is the configured db service name, or "db".
func (c *Config) DBService() string {
	if v := c.Compose.Services["db"]; v != "" {
		return v
	}
	return "db"
}

// PostgRESTService is the configured postgrest service name, or "postgrest".
func (c *Config) PostgRESTService() string {
	if v := c.Compose.Services["postgrest"]; v != "" {
		return v
	}
	return "postgrest"
}

// TokenTTL is the default lifetime for minted tokens (security.jwt_ttl, or 15m).
func (c *Config) TokenTTL() time.Duration {
	if c.Security.JWTTTL != "" {
		if d, err := time.ParseDuration(c.Security.JWTTTL); err == nil {
			return d
		}
	}
	return 15 * time.Minute
}

// Validate aggregates all problems into one error.
func (c *Config) Validate() error {
	var problems []string
	known := map[string]bool{}
	for _, k := range Order {
		known[k] = true
	}
	anyEnabled := false
	for _, k := range Order {
		if c.Capabilities[k] {
			anyEnabled = true
		}
	}
	if !anyEnabled {
		problems = append(problems, "at least one capability must be enabled")
	}
	for k := range c.Capabilities {
		if !known[k] {
			problems = append(problems, fmt.Sprintf("unknown capability %q (typo? not one of %v)", k, Order))
		}
	}
	if c.Capabilities["auth"] && !c.Capabilities["api"] {
		problems = append(problems, "capability 'auth' requires 'api'")
	}
	if c.Capabilities["dashboards"] && !c.Capabilities["timeseries"] {
		problems = append(problems, "capability 'dashboards' requires 'timeseries'")
	}
	if c.Languages.PLPython && !c.Languages.AllowUntrusted {
		problems = append(problems, "language 'plpython' is UNTRUSTED (plpython3u runs with the database OS user's full privileges); set languages.allow_untrusted=true to enable it deliberately")
	}
	// compose naming
	badName := func(n string) bool { return n != "" && !composeNameRe.MatchString(n) }
	if badName(c.Compose.Project) {
		problems = append(problems, fmt.Sprintf("invalid compose name %q (use lowercase letters, digits, '-' or '_', starting with a letter or digit)", c.Compose.Project))
	}
	knownSvc := map[string]bool{"db": true, "postgrest": true}
	for k, v := range c.Compose.Services {
		if !knownSvc[k] {
			problems = append(problems, fmt.Sprintf("unknown service %q in compose.services (known: db, postgrest)", k))
		}
		if badName(v) {
			problems = append(problems, fmt.Sprintf("invalid compose name %q for service %q (use lowercase letters, digits, '-' or '_', starting with a letter or digit)", v, k))
		}
	}
	if c.DBService() == c.PostgRESTService() {
		problems = append(problems, fmt.Sprintf("compose db and postgrest service names must differ (both %q)", c.DBService()))
	}
	if c.Security.JWTTTL != "" {
		if _, err := time.ParseDuration(c.Security.JWTTTL); err != nil {
			problems = append(problems, fmt.Sprintf("invalid security.jwt_ttl %q (use a Go duration like 15m, 1h)", c.Security.JWTTTL))
		}
	}
	if len(problems) > 0 {
		return errors.New("invalid config:\n  - " + strings.Join(problems, "\n  - "))
	}
	return nil
}
