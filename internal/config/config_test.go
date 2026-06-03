package config

import (
	"strings"
	"testing"
)

func mustValidate(t *testing.T, c *Config) error { t.Helper(); return c.Validate() }

func TestValidate(t *testing.T) {
	cases := []struct {
		name    string
		caps    map[string]bool
		lang    LanguagesCfg
		wantErr string // substring; "" means valid
	}{
		{"minimal ok", map[string]bool{"document_store": true}, LanguagesCfg{}, ""},
		{"zero caps", map[string]bool{}, LanguagesCfg{}, "at least one capability"},
		{"auth needs api", map[string]bool{"auth": true}, LanguagesCfg{}, "auth' requires 'api"},
		{"dashboards needs timeseries", map[string]bool{"dashboards": true}, LanguagesCfg{}, "dashboards' requires 'timeseries"},
		{"plpython gated", map[string]bool{"document_store": true}, LanguagesCfg{PLPython: true}, "untrusted"},
		{"plpython allowed", map[string]bool{"document_store": true}, LanguagesCfg{PLPython: true, AllowUntrusted: true}, ""},
		{"api+auth ok", map[string]bool{"api": true, "auth": true}, LanguagesCfg{}, ""},
		{"ts+dashboards ok", map[string]bool{"timeseries": true, "dashboards": true}, LanguagesCfg{}, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c := &Config{Capabilities: tc.caps, Languages: tc.lang}
			err := mustValidate(t, c)
			if tc.wantErr == "" {
				if err != nil {
					t.Fatalf("want valid, got %v", err)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
				t.Fatalf("want error containing %q, got %v", tc.wantErr, err)
			}
		})
	}
}

func TestDefaults(t *testing.T) {
	c := &Config{Capabilities: map[string]bool{"document_store": true}}
	c.ApplyDefaults()
	if c.Postgres.User != "postgres" || c.Postgres.DB != "app" {
		t.Fatalf("defaults not applied: %+v", c.Postgres)
	}
	if !c.Seed() {
		t.Fatalf("seed should default true")
	}
}

func TestComposeAccessors(t *testing.T) {
	c := &Config{}
	if c.ProjectName() != "" {
		t.Errorf("ProjectName default: want empty, got %q", c.ProjectName())
	}
	if c.DBService() != "db" {
		t.Errorf("DBService default: want db, got %q", c.DBService())
	}
	if c.PostgRESTService() != "postgrest" {
		t.Errorf("PostgRESTService default: want postgrest, got %q", c.PostgRESTService())
	}

	c = &Config{Compose: ComposeCfg{
		Project:  "myapp",
		Services: map[string]string{"db": "postgres", "postgrest": "rest"},
	}}
	if c.ProjectName() != "myapp" {
		t.Errorf("ProjectName: got %q", c.ProjectName())
	}
	if c.DBService() != "postgres" {
		t.Errorf("DBService override: got %q", c.DBService())
	}
	if c.PostgRESTService() != "rest" {
		t.Errorf("PostgRESTService override: got %q", c.PostgRESTService())
	}
}

func TestComposeValidate(t *testing.T) {
	base := map[string]bool{"document_store": true, "api": true}
	cases := []struct {
		name    string
		compose ComposeCfg
		wantErr string
	}{
		{"empty ok", ComposeCfg{}, ""},
		{"valid names", ComposeCfg{Project: "my-app1", Services: map[string]string{"db": "postgres", "postgrest": "rest"}}, ""},
		{"unknown service key", ComposeCfg{Services: map[string]string{"web": "x"}}, "unknown service"},
		{"bad project name", ComposeCfg{Project: "My App"}, "invalid compose name"},
		{"bad service name", ComposeCfg{Services: map[string]string{"db": "Post gres"}}, "invalid compose name"},
		{"collision", ComposeCfg{Services: map[string]string{"db": "x", "postgrest": "x"}}, "must differ"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c := &Config{Capabilities: base, Compose: tc.compose}
			err := c.Validate()
			if tc.wantErr == "" {
				if err != nil {
					t.Fatalf("want valid, got %v", err)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
				t.Fatalf("want error containing %q, got %v", tc.wantErr, err)
			}
		})
	}
}
