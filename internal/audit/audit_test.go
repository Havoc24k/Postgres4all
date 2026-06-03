package audit

import (
	"testing"

	"github.com/Havoc24k/postgres4all/internal/config"
)

func bySeverity(fs []Finding) map[string]string { // title -> severity
	m := map[string]string{}
	for _, f := range fs {
		m[f.Title] = f.Severity
	}
	return m
}

func TestRunMinimal(t *testing.T) {
	// document_store only: no api/auth, seed defaults ON, not published externally.
	c := &config.Config{Capabilities: map[string]bool{"document_store": true}}
	c.ApplyDefaults()
	m := bySeverity(Run(c))

	if m["No backups configured"] != "critical" {
		t.Errorf("want critical backups finding, got %q", m["No backups configured"])
	}
	if m["Demo seed data enabled"] != "high" {
		t.Errorf("want high demo-seed finding, got %q", m["Demo seed data enabled"])
	}
	if _, ok := m["Permissive anonymous access"]; ok {
		t.Errorf("anon finding must not appear without api")
	}
	if _, ok := m["Cleartext ports exposed to the network"]; ok {
		t.Errorf("exposure finding must not appear when not published externally")
	}
}

func TestRunHardened(t *testing.T) {
	seedOff := false
	c := &config.Config{
		Capabilities: map[string]bool{"document_store": true, "api": true, "auth": true},
		SeedDemoData: &seedOff,
	}
	c.Postgres.PublishExternally = true
	c.ApplyDefaults()
	m := bySeverity(Run(c))

	if m["Cleartext ports exposed to the network"] != "critical" {
		t.Errorf("want critical exposure finding when published externally")
	}
	if m["Permissive anonymous access"] != "high" {
		t.Errorf("want anon finding when api enabled")
	}
	if m["Demo-grade JWT auth"] != "high" {
		t.Errorf("want jwt finding when auth enabled")
	}
	if _, ok := m["Demo seed data enabled"]; ok {
		t.Errorf("seed finding must be absent when seed_demo_data=false")
	}
}
