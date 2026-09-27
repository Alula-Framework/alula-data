# Getting started

From an empty database to a versioned schema.

## Writing a migration

A migration is a type with an `up` and a `down`. Both take a
``SchemaBuilder``, which accumulates statements rather than executing them —
so a migration can be rendered and reviewed before it runs.

```swift
struct CreateUsers: Migration {
    func up(_ schema: SchemaBuilder) {
        schema.createTable("users") { t in
            t.uuid("id").primaryKey()
            t.text("email").notNull().unique()
            t.text("display_name").notNull()
            t.timestamps()
        }
    }

    func down(_ schema: SchemaBuilder) {
        schema.dropTable("users")
    }
}
```

The file name carries the version: `20260714120000_CreateUsers.swift`. A
14-digit UTC timestamp sorts correctly, reads unambiguously, and does not
collide when two people add a migration on the same day.

```bash
swift run migrate create CreateUsers
```

## Registering them

A build plugin scans your migrations directory and generates the registry, so
adding a file is all it takes — there is no list to keep in sync, and no way
for a migration to exist but never run because someone forgot to register it.

```swift
// The package is alula-data, and the Postgres trait is required — without it
// the migration products are declared but hard-error at build time.
.package(
    url: "https://github.com/Alula-Framework/alula-data.git",
    from: "0.23.0",
    traits: ["Postgres"]
)

.target(
    name: "MyAppMigrations",
    dependencies: [.product(name: "AlulaMigrate", package: "alula-data")],
    plugins: [.plugin(name: "AlulaMigratePlugin", package: "alula-data")]
)
```

The plugin generates a public function, `_allMigrations()`, in that target:
every migration it found, ordered by version.

## Running them

```swift
import AlulaMigrate
import MyAppMigrations

let migrator = AlulaMigrator(
    client: postgresClient,
    migrations: _allMigrations()
)

let applied = try await migrator.migrate()
```

Or from the CLI, which is the more usual deploy step. A `migrate` executable
target depending on `AlulaMigrateCLI` and the migrations target needs only:

```swift
import AlulaMigrate
import AlulaMigrateCLI
import MyAppMigrations

@main
struct Migrate: MigrateTool {
    static var migrations: [MigrationEntry] { _allMigrations() }
}
```

```bash
swift run migrate status            # what is applied, what is pending
swift run migrate apply --dry-run   # the exact SQL, without running it
swift run migrate apply             # run everything pending
swift run migrate rollback --steps 1
```

`apply --dry-run` is worth using before anything destructive. It renders the
statements a run would execute, so a review happens against the SQL rather
than against the Swift that generates it. `rollback --dry-run` does the same
for a rollback.

The CLI finds the database in `--database-url`, `$ALULA_DATABASE_URL` or
`$DATABASE_URL`, and otherwise in the application's own `alula.yaml`
(`datasource.primary.url`, or another datasource with `--datasource`).

## Checking before you commit

`status` reports three things per migration: applied, pending, or drifted.

```
Applied migrations:
  20260714120000_CreateUsers  applied 2026-07-14T12:05:31Z  ok
  20260715093000_AddEmailIndex  applied 2026-07-15T09:31:02Z  MODIFIED since applied (checksum mismatch) — see 'repair'
Pending migrations:
  20260716101500_AddTeams  (transactional)
```

`status --json` prints the same as JSON, for a script.

A checksum mismatch means the file changed after it was applied. The next
`apply` will refuse to run until you either restore the file or re-baseline
it with `repair` — see <doc:OperationalRunbook>.

## Configuring

```swift
AlulaMigrator(
    client: client,
    migrations: _allMigrations(),
    configuration: .init(
        migrationsTable: "ops.alula_migrations",
        lockTimeout: .seconds(60),
        failOnUnknownApplied: true
    )
)
```

``AlulaMigrator/Configuration/failOnUnknownApplied`` is worth turning on once
your deploys are stable. It makes a ledger containing versions this binary
does not know about a hard error, which catches a deleted migration file — at
the cost of failing during the window where an old binary sees a new schema.
