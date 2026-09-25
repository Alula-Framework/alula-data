# ALD-MIGRATE-2001: An invalid migration filename

**Severity:** error

## Meaning

A file in a migrations target looks like a migration but its name does not
parse as `<timestamp>_<TypeName>.swift`.

## Why alula-data rejects it

The timestamp is the migration's version and orders it; the name is the
type the registry runs. Both come from the filename.

## Fixes

1. Create migrations with `alula migrate create <Name>`, which writes the name correctly.
2. Fix the name to `YYYYMMDDHHMMSS_TypeName.swift`.

## Related

ALD-MIGRATE-2002.
