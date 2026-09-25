# ALD-MIGRATE-2003: Two migrations with one version

**Severity:** error

## Meaning

Two migration files share a timestamp prefix, which is the migration's
version.

## Why alula-data rejects it

Versions order migrations and record which have run; two with one version
cannot both be tracked. It usually comes from a hand-edited or
merge-conflicted filename.

## Fixes

1. Regenerate one of the timestamps: create it again with `alula migrate create` and move its body across.

## Related

ALD-MIGRATE-2001.
