package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
)

// Order is the canonical capability order used across generation.
var Order = []string{"document_store", "job_queue", "search", "vector", "gis", "timeseries", "dashboards", "api", "auth"}

type Config struct {
	Postgres     PostgresCfg     `json:"postgres"`
	SeedDemoData *bool           `json:"seed_demo_data"`
	Capabilities map[string]bool `json:"capabilities"`
	API          APICfg          `json:"api"`
	Languages    LanguagesCfg    `json:"languages"`
}
type PostgresCfg struct {
	User              string `json:"user"`
	DB                string `json:"db"`
	Password          string `json:"password"`
	PublishExternally bool   `json:"publish_externally"`
}
type APICfg struct {
	AuthenticatorPassword string `json:"authenticator_password"`
	JWTSecret             string `json:"jwt_secret"`
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
	if len(problems) > 0 {
		return errors.New("invalid config:\n  - " + strings.Join(problems, "\n  - "))
	}
	return nil
}
