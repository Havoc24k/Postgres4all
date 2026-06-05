package functions

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// untrustedLang matches a CREATE FUNCTION ... LANGUAGE clause naming an UNTRUSTED
// procedural language. PostgreSQL only lets superusers CREATE FUNCTION in these,
// so they cannot be created under SET ROLE <non-superuser> (see EmitSQL).
var untrustedLang = regexp.MustCompile(`(?i)language\s+(plpython3u|plpythonu|plpython2u|plperlu)`)

// EmitSQL concatenates dir/*.sql in deterministic (byte-order) sort, each as "-- <path>\n<bytes>\n",
// then appends a NOTIFY reload if any files were found. Returns (sql, fileCount, err).
//
// When owner is non-empty, created objects must end up owned by that non-superuser
// role — the idiomatic PostgreSQL way to keep SECURITY DEFINER functions from
// running as the superuser. Two paths, because untrusted procedural languages
// (plpython3u, plperlu, …) can ONLY be created by a superuser and so cannot run
// under SET ROLE:
//
//   - Trusted files (plpgsql, sql, plperl, plain DDL) are wrapped in
//     `SET ROLE <owner>; … RESET ROLE;` and are owned by <owner> directly.
//   - Untrusted-language files are emitted AFTER `RESET ROLE` (i.e. as the
//     connected superuser), bracketed by a snapshot of pg_proc; a trailing
//     DO block then `ALTER FUNCTION … OWNER TO <owner>` for every function the
//     batch newly created. Ownership transfer is allowed for non-superusers and
//     the untrusted-language privilege is only checked at CREATE, so the result
//     is a <owner>-owned function with no superuser involvement at run time.
//
// The trailing NOTIFY always runs last, as the connected superuser. When owner is
// empty (non-api install) files are concatenated verbatim in sort order, owned by
// the connecting role.
func EmitSQL(dir, owner string) (string, int, error) {
	matches, err := filepath.Glob(filepath.Join(dir, "*.sql"))
	if err != nil {
		return "", 0, err
	}
	sort.Strings(matches) // LC_ALL=C byte-order, matching bash `printf ... | LC_ALL=C sort`
	if len(matches) == 0 {
		return "", 0, nil
	}

	type file struct {
		path  string
		bytes []byte
	}
	var trusted, untrusted []file
	for _, f := range matches {
		bytes, err := os.ReadFile(f)
		if err != nil {
			return "", 0, err
		}
		fl := file{path: f, bytes: bytes}
		if owner != "" && untrustedLang.Match(bytes) {
			untrusted = append(untrusted, fl)
		} else {
			trusted = append(trusted, fl)
		}
	}
	n := len(trusted) + len(untrusted)

	var b strings.Builder
	emit := func(f file) {
		b.WriteString("-- " + f.path + "\n")
		b.Write(f.bytes)
		b.WriteString("\n")
	}

	if owner == "" {
		// Legacy/non-api path: verbatim concat in sort order.
		for _, f := range trusted {
			emit(f)
		}
	} else {
		if len(trusted) > 0 {
			b.WriteString("SET ROLE " + owner + ";\n")
			for _, f := range trusted {
				emit(f)
			}
			b.WriteString("RESET ROLE;\n")
		}
		if len(untrusted) > 0 {
			// Untrusted languages require a superuser to CREATE, so run these after RESET
			// ROLE, then reassign ownership of every function this batch created to <owner>.
			b.WriteString("-- untrusted-language functions: created as superuser (required), then reassigned to " + owner + "\n")
			b.WriteString("CREATE TEMP TABLE _p4a_pre_proc AS SELECT oid FROM pg_proc;\n")
			for _, f := range untrusted {
				emit(f)
			}
			b.WriteString("DO $p4a$\nDECLARE r record;\nBEGIN\n")
			b.WriteString("    FOR r IN SELECT p.oid::regprocedure AS sig FROM pg_proc p\n")
			b.WriteString("             WHERE p.oid NOT IN (SELECT oid FROM _p4a_pre_proc)\n")
			b.WriteString("    LOOP\n")
			b.WriteString("        EXECUTE format('ALTER FUNCTION %s OWNER TO %I', r.sig, '" + owner + "');\n")
			b.WriteString("    END LOOP;\nEND $p4a$;\n")
			b.WriteString("DROP TABLE _p4a_pre_proc;\n")
		}
	}

	b.WriteString("NOTIFY pgrst, 'reload schema';\n")
	return b.String(), n, nil
}
