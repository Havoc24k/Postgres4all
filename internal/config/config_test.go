package config

import "testing"

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
			if err == nil || !contains(err.Error(), tc.wantErr) {
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

func contains(s, sub string) bool { return len(sub) == 0 || (len(s) >= len(sub) && indexOf(s, sub) >= 0) }
func indexOf(s, sub string) int {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}
