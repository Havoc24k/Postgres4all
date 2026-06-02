package generate

import "embed"

//go:embed capabilities/*.sql
var capabilitiesFS embed.FS

//go:embed templates/*.tmpl
var templatesFS embed.FS
