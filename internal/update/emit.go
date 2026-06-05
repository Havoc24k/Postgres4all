package update

import (
	"fmt"
	"strings"

	"github.com/Havoc24k/postgres4all/internal/config"
	"github.com/Havoc24k/postgres4all/internal/generate"
)

// schemaOrder is config.Order without "api" (api owns no schema fragment).
var schemaOrder = func() []string {
	out := make([]string, 0, len(config.Order))
	for _, c := range config.Order {
		if c != "api" {
			out = append(out, c)
		}
	}
	return out
}()

// EmitPreSQL produces idempotent role-chain creation SQL.
// Called only when "api" is being added, BEFORE the image rebuild.
// authPw is the AUTHENTICATOR_PASSWORD value; single-quotes are doubled for the SQL literal.
func EmitPreSQL(authPw string) string {
	escaped := strings.ReplaceAll(authPw, "'", "''")
	var sb strings.Builder
	sb.WriteString("DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon NOLOGIN; END IF; END $$;\n")
	sb.WriteString("DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF; END $$;\n")
	sb.WriteString(fmt.Sprintf("DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='authenticator') THEN CREATE ROLE authenticator NOINHERIT LOGIN PASSWORD '%s'; END IF; END $$;\n", escaped))
	sb.WriteString("DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='api_owner') THEN CREATE ROLE api_owner NOLOGIN NOINHERIT; END IF; END $$;\n")
	sb.WriteString("GRANT anon, authenticated TO authenticator;\n")
	return sb.String()
}

// EmitAddSQL produces extension + schema + grant + meta-insert SQL for the ADD set.
// Grant rule: if api is newly added, grant the ALREADY-INSTALLED read tables in the api block;
// the per-cap loop grants NEW tables AFTER their CREATE.
// installed is the installed capability set before this delta.
func EmitAddSQL(cfg *config.Config, add, installed []string) string {
	apiAdded := Contains(add, "api")
	apiEff := cfg.Enabled("api") // api present after this delta

	var sb strings.Builder

	// api block: schema/table grants over the already-installed tables.
	if apiAdded {
		sb.WriteString("GRANT USAGE ON SCHEMA public TO anon, authenticated;\n")
		sb.WriteString("GRANT USAGE, CREATE ON SCHEMA public TO api_owner;\n")

		// Read-table grant for INSTALLED caps (not the ones being added).
		var tables []string
		for _, c := range config.Order {
			if c == "api" || c == "auth" {
				continue
			}
			if _, ok := generate.ReadTableMap[c]; !ok {
				continue
			}
			if Contains(installed, c) {
				tables = append(tables, generate.ReadTableMap[c])
			}
		}
		if len(tables) > 0 {
			sb.WriteString("GRANT SELECT ON " + strings.Join(tables, ", ") + " TO anon, authenticated;\n")
			sb.WriteString("GRANT SELECT, INSERT, UPDATE, DELETE ON " + strings.Join(tables, ", ") + " TO api_owner;\n")
		}
		if Contains(installed, "auth") {
			sb.WriteString("GRANT SELECT, INSERT, UPDATE, DELETE ON notes TO authenticated;\n")
		}

		if cfg.Security.AnonFutureTables {
			sb.WriteString("ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO anon;\n")
		}
	}

	// Per-cap loop: schema fragments for each cap being added (excluding api).
	for _, c := range schemaOrder {
		if !Contains(add, c) {
			continue
		}

		// Extension (if any).
		if ext, ok := generate.ExtensionMap[c]; ok {
			sb.WriteString("CREATE EXTENSION IF NOT EXISTS " + ext + ";\n")
		}

		// Schema fragment + extra blank line (reproduces bash: cat file; echo).
		schemaBytes, err := generate.ReadCapabilitySQL(c + ".schema.sql")
		if err == nil {
			sb.Write(schemaBytes)
			sb.WriteString("\n")
		}

		// Seed fragment + extra blank line (if seeding enabled and seed exists).
		if cfg.Seed() {
			seedBytes, err := generate.ReadCapabilitySQL(c + ".seed.sql")
			if err == nil {
				sb.Write(seedBytes)
				sb.WriteString("\n")
			}
		}

		// Per-cap grants (only when api is effective after this delta).
		if apiEff {
			if tbl, ok := generate.ReadTableMap[c]; ok {
				sb.WriteString("GRANT SELECT ON " + tbl + " TO anon, authenticated;\n")
				sb.WriteString("GRANT SELECT, INSERT, UPDATE, DELETE ON " + tbl + " TO api_owner;\n")
			}
			if c == "auth" {
				sb.WriteString("GRANT SELECT, INSERT, UPDATE, DELETE ON notes TO authenticated;\n")
			}
		}

		// Meta insert.
		sb.WriteString(fmt.Sprintf("INSERT INTO p4a_meta.capabilities (cap) VALUES ('%s') ON CONFLICT (cap) DO NOTHING;\n", c))
	}

	// api meta insert (last).
	if apiAdded {
		sb.WriteString("INSERT INTO p4a_meta.capabilities (cap) VALUES ('api') ON CONFLICT (cap) DO NOTHING;\n")
	}

	return sb.String()
}

// EmitRemoveSQL produces drop SQL for the REMOVE set.
// Caps are processed in REVERSE canonical-schema order; api removal appends the role teardown block.
func EmitRemoveSQL(_ *config.Config, remove []string) string {
	apiRemoved := Contains(remove, "api")

	var sb strings.Builder

	// Drop in reverse schema order (excluding api).
	for i := len(schemaOrder) - 1; i >= 0; i-- {
		c := schemaOrder[i]
		if !Contains(remove, c) {
			continue
		}

		// Drop fragment + extra blank line.
		dropBytes, err := generate.ReadCapabilitySQL(c + ".drop.sql")
		if err == nil {
			sb.Write(dropBytes)
			sb.WriteString("\n")
		}

		// Drop extension (if any).
		if ext, ok := generate.ExtensionMap[c]; ok {
			sb.WriteString("DROP EXTENSION IF EXISTS " + ext + ";\n")
		}

		// Meta delete.
		sb.WriteString(fmt.Sprintf("DELETE FROM p4a_meta.capabilities WHERE cap = '%s';\n", c))
	}

	// api teardown block (only when api is being removed).
	if apiRemoved {
		sb.WriteString("ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE SELECT ON TABLES FROM anon;\n")
		sb.WriteString("DROP OWNED BY authenticator, anon, authenticated, api_owner;\n")
		sb.WriteString("DROP ROLE IF EXISTS authenticator;\n")
		sb.WriteString("DROP ROLE IF EXISTS authenticated;\n")
		sb.WriteString("DROP ROLE IF EXISTS anon;\n")
		sb.WriteString("DROP ROLE IF EXISTS api_owner;\n")
		sb.WriteString("DELETE FROM p4a_meta.capabilities WHERE cap = 'api';\n")
	}

	return sb.String()
}
