# Migrations that cannot run in a transaction

`CREATE INDEX CONCURRENTLY` and friends, and what you give up to use them.

## Overview

Every migration runs inside a transaction by default, which is what makes a
failure safe: the schema change and its bookkeeping row commit together or
not at all.

A few Postgres operations refuse to run inside a transaction block. The most
common by far is `CREATE INDEX CONCURRENTLY`, which is also the one you most
want in production — it builds an index without taking a write lock, so the
table stays available.

Opting out is explicit:

```swift
struct AddEmailIndex: Migration {
    static let wrapInTransaction = false

    func up(_ schema: SchemaBuilder) {
        schema.createIndex(on: "users", columns: ["email"], concurrently: true)
    }

    func down(_ schema: SchemaBuilder) {
        schema.dropIndex("users_email_idx", concurrently: true, ifExists: true)
    }
}
```

## What you give up

**Atomicity, entirely.** If the statement fails halfway there is nothing to
roll back — no transaction was open. The database is left in whatever state
the failure produced.

The library's response is to refuse to lie about it:

- The version is **not** recorded as applied, so a retry will run it again.
- The error names the exact statement that failed.
- The message says manual intervention may be required, because it may.

```
migration 20260715093000_AddEmailIndex failed while applying statement 1 of 1:

    CREATE INDEX CONCURRENTLY IF NOT EXISTS "users_email_idx" ON "users" ("email")

underlying error: …

This migration runs with wrapInTransaction = false, so there was no transaction to roll back. No statements from this migration had been applied. The version was not recorded, so the migration can re-run once the database state is repaired. Manual intervention may be required — for example, a failed CREATE INDEX CONCURRENTLY leaves an INVALID index that must be dropped before retrying.
```

`underlying error:` is the server's own report — severity, SQLSTATE and
message, with its detail and hint when it gives them.

## The INVALID index case

A failed concurrent build leaves the index behind, marked `INVALID`. It does
not serve queries, but it does occupy the name — so a naive retry fails on
`relation already exists` and makes no progress.

This is why ``SchemaBuilder/createIndex(on:columns:name:unique:concurrently:ifNotExists:using:where:)``
defaults `ifNotExists` to whatever `concurrently` is. With `IF NOT EXISTS`, a
retry is a no-op against the stranded index rather than an error — which is
not a fix, but it does let the migration complete once you drop the invalid
index:

```sql
-- Find them
SELECT indexrelid::regclass FROM pg_index WHERE NOT indisvalid;

-- Drop, then re-run the migration
DROP INDEX CONCURRENTLY users_email_idx;
```

Pass `ifNotExists: false` explicitly if you would rather the retry fail loudly
than proceed past a stranded index.

## The rule that follows from all this

**One statement per direction.** A wrapped migration can do as much as you
like, because it either all lands or none of it does. An unwrapped migration
has no such guarantee, so every additional statement multiplies the number of
partial states you might have to reason about at three in the morning.

The library warns when an unwrapped migration contains more than one
statement. It does not refuse — there are legitimate reasons — but the warning
is there because the failure mode is genuinely worse than it looks.

## When you do not need this

If the table is small, or the deploy has a maintenance window, a plain
`CREATE INDEX` inside a transaction is simpler and safe. Reach for
`CONCURRENTLY` when the write lock is the problem, not by default.
