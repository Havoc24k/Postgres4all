package generate

import "embed"

//go:embed capabilities/*.sql
var capabilitiesFS embed.FS

// templatesFS (templates/*.tmpl) is embedded in Task 5, once the templates exist.
