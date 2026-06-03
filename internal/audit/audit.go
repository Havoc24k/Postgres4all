// Package audit reports production-readiness gaps in a postgres4all configuration.
// It is intentionally conservative: the generated stack is demo-grade by default, so most
// findings hold until the corresponding hardening knobs exist. As those land, Run keys its
// findings off the new config so the report reflects what you have actually tightened.
package audit

import "github.com/Havoc24k/postgres4all/internal/config"

// Finding is one production-readiness gap. Severity is "critical" | "high" | "info".
type Finding struct {
	Severity string
	Title    string
	Detail   string
	Fix      string
}

// Run returns findings for the config, in a stable order (critical concerns first).
func Run(c *config.Config) []Finding {
	var f []Finding
	add := func(sev, title, detail, fix string) {
		f = append(f, Finding{Severity: sev, Title: title, Detail: detail, Fix: fix})
	}

	api := c.Enabled("api")

	if c.Postgres.PublishExternally {
		add("critical", "Cleartext ports exposed to the network",
			"publish_externally=true binds Postgres (5432) and the API (3000) on all interfaces with no TLS.",
			"Front the API with a TLS-terminating proxy, or keep publish_externally=false and reach it over a private network/tunnel.")
	}

	add("critical", "No backups configured",
		"There is no backup, WAL archiving, or point-in-time recovery — a dropped table or lost volume is unrecoverable, and `down -v` deletes the data volume.",
		"Schedule pg_dump or pgBackRest, archive WAL off-host, and test-restore regularly.")

	if api {
		add("high", "Permissive anonymous access",
			"The unauthenticated `anon` role is granted SELECT on the public tables, and default privileges grant anon SELECT on future tables; row-level security protects only `notes`.",
			"Restrict anon grants to intended tables, drop the blanket default-privilege grant, and add RLS to any multi-tenant table.")
		add("high", "API served over plain HTTP",
			"PostgREST listens on plain HTTP (port 3000) with no TLS, so Bearer tokens and data travel in cleartext.",
			"Terminate TLS at a reverse proxy in front of PostgREST (or enable PostgREST SSL).")
	}

	if c.Enabled("auth") {
		add("high", "Demo-grade JWT auth",
			"JWTs are HS256 (the verification secret IS the signing secret, so any holder can forge any user), and the documented flow mints tokens with no exp claim.",
			"Issue short-lived RS256 tokens from a real auth service and verify with the public key only.")
	}

	if c.Seed() {
		add("high", "Demo seed data enabled",
			"seed_demo_data is on — demo rows are inserted into public tables on a fresh install.",
			"Set seed_demo_data=false for a real deployment.")
	}

	add("info", "Default Postgres config and no resource limits",
		"Postgres runs with default memory/connection settings and the containers declare no CPU/memory limits.",
		"Tune shared_buffers/work_mem/max_connections for your host and set container resource limits.")

	return f
}

// CriticalCount returns how many findings are critical.
func CriticalCount(fs []Finding) int {
	n := 0
	for _, f := range fs {
		if f.Severity == "critical" {
			n++
		}
	}
	return n
}
