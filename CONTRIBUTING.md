# Contributing

Thanks for your interest in alula-data.

## Getting set up

Every target builds only with its trait on, so a build of this repository
needs them all. A plain `swift build` fails by design (see the README's
[Traits](README.md#traits)):

```bash
swift build --enable-all-traits
swift test  --enable-all-traits   # the integration suites skip without servers
```

The integration suites need real servers. `scripts/test.sh` starts
**throwaway** Postgres and Valkey containers, sets the variables the suites
read (`ALULA_POSTGRES_TEST_DATABASE_URL`, `ALULA_MIGRATE_TEST_DATABASE_URL`,
`ALULA_VALKEY_TEST_URL` and the outage switches), runs everything, and
removes them:

```bash
./scripts/test.sh                 # everything, integration tests included
./scripts/test.sh --filter Foo    # arguments pass through to swift test
```

> **Throwaway, genuinely.** The suites drop and recreate fixture tables and
> `FLUSHDB` between tests, and the outage suites stop and restart their own
> servers mid-test. Never point the variables at a server you care about.

## Before opening a pull request

```bash
ALULA_STRICT_WARNINGS=1 swift build --enable-all-traits
./scripts/test.sh
python3 CI/check-diagnostic-quotes.py \
    --docs README.md Docs Diagnostics Sources --source ALD=Sources
```

If you touched a `.docc` catalogue or doc comments, build that target's
documentation the way CI does, then revert the `Package.resolved` change the
docs plugin makes:

```bash
mkdir -p ./docs && ALULA_BUILD_DOCS=1 swift package --enable-all-traits \
    --allow-writing-to-directory ./docs/AlulaMigrate \
    generate-documentation --target AlulaMigrate \
    --warnings-as-errors --output-path ./docs/AlulaMigrate
```

CI runs on Swift 6.3.3 — the one toolchain the matrix pins, and the floor
`swift-tools-version: 6.3` requires — with Postgres and Valkey service
containers. A green run that quietly skipped every integration test proves
almost nothing, and this package's value is mostly what it proves against
real servers.

## The rules that govern migrations

These apply to `AlulaMigrate` and `AlulaMigrateCore`.

**A migration is either fully applied and recorded, or neither.** Every change
to the run path has to preserve that. If you are adding a step between the
migration's statements and its bookkeeping row, it belongs inside the same
transaction.

**Never record a version that did not fully apply.** A recorded version will
never run again, so recording one optimistically converts a recoverable
failure into a permanently skipped migration.

**Failures name the fix.** Every error in `MigrationError` tells an operator
what to do, not just what went wrong. A new one should too — there is usually
someone reading it during an incident.

**The unwrapped path does not get to pretend.** When `wrapInTransaction` is
false there is no rollback, and the code says so plainly rather than
implying safety it cannot provide.

**Some identifiers still say "flight", on purpose.** The checksum domain
`flight-migrate:v1`, the advisory-lock key (the bytes `FLIGHTMG`) and the
legacy ledger name `flight_migrations` date from before the project became
Alula. Every recorded checksum was computed with that prefix, a pre-rename
migrator still takes that lock, and a pre-rename database keeps its ledger
under that name until a locked run renames it. Changing any of them reports
every applied migration as drifted, lets two migrators run at once, or loses
the ledger (alula's DECISIONS.md, D45).

## Testing migrations

`FakeDatabase` records the exact operation sequence — `BEGIN`, each statement,
the bookkeeping write, `COMMIT` — and rejects nested transactions and commits
without a transaction. Assert against that transcript when you change
ordering; it is what makes the atomicity guarantees testable without a server.

Reserve the integration suite for things only real Postgres can prove:
transactional DDL rollback, `CONCURRENTLY` outside a transaction, advisory
lock behavior under contention.
