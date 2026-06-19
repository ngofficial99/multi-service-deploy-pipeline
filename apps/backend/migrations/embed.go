package migrations

import "embed"

// FS holds the SQL migration files, embedded at build time so the binary is
// self-contained (no migration files to ship alongside it).
//
//go:embed *.sql
var FS embed.FS
