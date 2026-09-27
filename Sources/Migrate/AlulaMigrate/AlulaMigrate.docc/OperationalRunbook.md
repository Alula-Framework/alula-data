# Operational runbook

What the failures look like, and what to do about each one.

## A migration failed

Read the error. It names the version, the statement, and whether the failure
was rolled back.

**If the migration was wrapped** (the default), nothing was applied and
nothing was recorded. Fix the migration and run again — the database is
exactly as it was.

**If it was unwrapped** (`wrapInTransaction = false`), the failure was not
rolled back and the version was not recorded. Inspect the database before
retrying. See <doc:UnwrappedMigrations>.

## Checksum mismatch

```
migration 20260715093000_AddEmailIndex has been modified since it was applied (checksum mismatch). Applied migrations are immutable — create a new migration to make further changes.
  recorded checksum: 3f2a…
  current checksum:  91be…
If the edit is confirmed-safe (formatting or comments only), run 'alula-migrate repair' to re-baseline the recorded checksum.
```

The CLI prints it after `Error: `; `status` shows the same migration as
`MODIFIED since applied (checksum mismatch)`.

A migration file was edited after it ran. The database no longer matches the
code that claims to describe it, so the run halts rather than guessing.

**If the edit was a mistake** — restore the original file. `git log` on the
migration will show what changed.

**If the edit was deliberate and the database already reflects it** — for
instance you fixed a typo in a comment, or corrected a `down` that was never
run — re-baseline:

```bash
swift run migrate repair
```

`repair` records the current checksums as authoritative. It does not run
anything, and it does not make the database match the file; it asserts that
you have checked they already agree.

**If the edit was deliberate and the database does not reflect it** — write a
new migration. Editing an applied migration and re-baselining is how
environments drift apart.

## Advisory lock timeout

```
Timed out after 30.0 seconds waiting for the migration advisory lock (key 5065504251389955399). Another migration run is holding it, or a session leaked it. Check for a deploy that is stuck mid-migration before raising the timeout; `SELECT * FROM pg_locks WHERE locktype = 'advisory'` shows who holds it.
```

Another migration is running, or one died without releasing the lock. Check
before raising the timeout:

```sql
SELECT pid, granted, state, query_start, query
FROM pg_locks
JOIN pg_stat_activity USING (pid)
WHERE locktype = 'advisory';
```

A `granted` lock held by a live, working session is a concurrent deploy —
wait for it. A lock held by an idle session is a leak; that session can be
terminated with `pg_terminate_backend(pid)`, which releases it.

Set ``AlulaMigrator/Configuration/lockTimeout`` to `nil` — or pass
`--lock-timeout 0` to the CLI — to wait indefinitely, which is reasonable for
an interactive run you are watching and a poor idea in an automated deploy.

## Unknown applied migrations

By default the CLI warns and carries on:

```
warning: 20260801120000_AddInvoices is recorded as applied but not registered in this binary (older binary than schema, or a deleted file).
```

With ``AlulaMigrator/Configuration/failOnUnknownApplied`` on, the run stops
instead:

```
the database records applied migrations that this binary does not know about:
  20260801120000_AddInvoices
This usually means the binary is older than the schema (a rolling deploy), or migration files were deleted. Deploy a binary that includes these migrations, or set failOnUnknownApplied = false to proceed anyway.
```

Either way, the database has been migrated by a newer build than the one
running now.

Mid-deploy this is **normal** — an old pod sees a schema the new pods
created. That is why the default is to warn and proceed.

Outside a deploy it usually means a migration file was deleted. Turn on
``AlulaMigrator/Configuration/failOnUnknownApplied`` once your deploys are
stable, and this becomes a hard error that catches exactly that.

## Rolling back

```bash
swift run migrate rollback --steps 1
swift run migrate rollback --to 20260714120000
```

Rollback runs each migration's `down` in reverse order, each in its own
transaction, and removes the ledger row in the same transaction.

Two things it will refuse to do:

- Roll back a migration whose checksum has drifted, since the `down` in the
  file may not undo the `up` that actually ran.
- Roll back a version the ledger records but this binary does not know about
  — there is no `down` to run.

Rollback applies the same integrity checks as a forward migration, including
``AlulaMigrator/Configuration/failOnUnknownApplied``. Reverting is as
destructive as applying, so it is gated the same way.

## Before a destructive deploy

```bash
swift run migrate apply --dry-run
```

Renders the exact SQL without running it, and ends with `Dry run: no changes
were made.` `rollback --dry-run` does the same for a rollback. Review against that, not against
the Swift that generates it.

## A note on running migrations at boot

This library will not do it for you, and the omission is deliberate. A schema
change is a deploy step with a decision behind it — who runs it, when, what
happens if it fails, whether the old code can survive the new schema. Making
it a side effect of a process starting means N replicas racing to migrate,
and a failed migration becoming a crash loop.

Run migrations from a job, an init container, or a human. Then start the app.
