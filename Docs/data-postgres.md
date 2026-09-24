# Alula Data Postgres

A pooled connection source, per-operation leases, and a DI-registered
repository layer — for Postgres, on top of Alula Core, Alula Data Core, and
Hangar.

This package is *composition plus stereotypes*, not a from-scratch data
stack: the driver and wire protocol are **PostgresNIO**, the query layer is
**Hangar** (`@Entity`), migrations are **Alula Migrate**. What Alula builds
is the seam between them.

| Product | Contents |
|---|---|
| `AlulaDataPostgres` | `PostgresDataSource` (the pool, behind Alula Data Core's `DataSource` seam), `PostgresDataModule<Name>`, `PostgresMigrations`, and the Hangar integration — `withRepo`, which leases a connection and hands you a `Repo` bound to it. Re-exports `AlulaCore`, `AlulaDataCore`, and `Hangar`, so a repository file needs one import. |

## Build status

`./scripts/test.sh` runs everything, integration tests included, against
throwaway servers it starts and cleans up — including the disposable Postgres
the outage suite is allowed to stop and restart.

The integration suites run against a real Postgres 16: leasing, pool lifecycle,
broken-connection replacement and recovery from a total outage, session
isolation in both directions, the queueing checkout, transactions with savepoint
nesting, changeset apply, migrate wiring, every dialect probe, and the shared
`DataSourceConformance` contract. Compile-time-checked queries run against
Postgres with three small decode/bind adaptations and no fallback to SQLKit.

## Using it

Entities are Hangar `@Entity` types — a typo'd column, a type-mismatched
comparison, or a reference to a non-stored property is a **compile error**:

```swift
@Entity("users")
struct User: Encodable, Equatable, Sendable {
    @ID var id: UUID
    var email: String
    @Column("lastName") var lastName: String
    var age: Int
    @Column("createdAt") var createdAt: Date
}
```

Repositories are `@Repository` types holding the **pool**. Each operation
leases a connection through `withRepo`, which hands it to a Hangar `Repo` and
returns it when the closure ends:

```swift
@Repository
struct UserRepository {
    // alula:hand-registered — the pool comes from PostgresDataModule, which
    // the registration generator cannot see; the marker silences its warning.
    @Inject var pool: PostgresDataSource

    func find(byEmail email: String) async throws -> User? {
        try await pool.withRepo { repo in
            try await repo.one(User.where { $0.email == email })
        }
    }

    func recentlyActive(since: Date, limit: Int) async throws -> [User] {
        try await pool.withRepo { repo in
            try await repo.all(
                User.where { $0.createdAt > since }
                    .order { $0.createdAt.desc() }
                    .limit(limit))
        }
    }
}
```

A repository is a `.singleton` — the default — because what it holds is the
pool, which every request shares. Nothing here is request-scoped, so a slow
handler holds no connection between its queries.

The raw connection is available the same way, through
`pool.withConnection { connection in … }`, for anything Hangar does not
express — `LISTEN`, `COPY`, server-side cursors.

The module is one generic instantiation per named datasource, reading
`datasource.<name>.url` / `pool_size` from Alula Config at freeze — a bad
URL fails bootstrap, never the first query:

```yaml
datasource:
  primary:
    url: "postgres://app:secret@localhost:5432/app?sslmode=prefer"
    pool_size: 10
```

```swift
await Alula.run(configuration: try .load(), modules: [
    PostgresDataModule<PrimaryDataSource>.self,
    AppModule.self,
], composedBy: alulaComposeModules)
```

Bootstrap ordering falls out for free: the pool's `run()` dials every
connection under the `ServiceGroup` before any request is served, replaces
broken connections while running, and drains on graceful shutdown.

### Transactions

Hangar owns transactions. `repo.transaction { }` is the unit of work, inside
the `withRepo` bracket that leased the connection:

```swift
@Repository
struct LedgerRepository {
    @Inject var pool: PostgresDataSource

    func transfer(_ amount: Int, from: String, to: String) async throws {
        try await pool.withRepo { repo in
            try await repo.transaction { tx in
                try await tx.update(debit(from, amount))
                try await tx.update(credit(to, amount))
            }
        }
    }
}
```

Every statement inside runs on the one leased connection. Throwing rolls
back. Nesting becomes a `SAVEPOINT`, so an inner failure can be handled
without discarding the outer work — Hangar tracks the depth, which is what
makes the nesting correct.

`withRepo` also binds Hangar's ambient `Repo.require()` for the duration of
the closure, so code that cannot take a repo parameter can still reach one.
The extent of that binding is exactly the bracket you can see.

This replaced `@Transactional`, `withPostgresScope`/`withPostgresTransactions`
and the transaction coordinators, which found the connection through an
ambient scope. The old arrangement had a defect the shape could not avoid: a
`Repo`'s `inTransaction` was fixed when the repo was *constructed*, and the
ambient repo was constructed before the unit of work ran — so a nested query
emitted a literal `COMMIT` that ended the enclosing transaction, and writes
the caller intended to roll back became durable with no error anywhere.
Constructing the repo per operation removes the thing that went stale.

### Read replicas

```yaml
datasource:
  primary:
    url: postgres://app@primary/db
    replica:
      url: postgres://app@replica/db
      pool_size: 8          # default: the primary's
      fallback: true        # default: read from the primary if the replica can't serve
```

Reads opt in, one call at a time:

```swift
let feed = try await pool.withReadRepo { repo in
    try await repo.all(Post.where { $0.published }.limit(50))
}
```

Nothing is routed to the replica automatically. A replica lags, and a read
that must see the request's own write (sign up, then show the profile) would
silently miss it, so reads stay on the primary through `withRepo` unless the
code says otherwise. `withReadRepo` without a replica configured is
`withRepo`, so the same code runs in development against one database.

When the replica cannot give a connection (down, or its pool exhausted), the
read goes to the primary and a warning is logged once. Recovery is logged
once too. Set `fallback: false` to fail instead. The replica's pool runs
beside the primary's and never takes it down. A replica is not part of
readiness, because with fallback the service is still whole without it.

The read repo is handed to your closure, not bound as the ambient
`Repo.current`. Binding it would send any code reaching for the ambient repo,
writes included, to a server that refuses them.

### Changesets

Nothing to wire here. Hangar's `@Entity` generates the `Changesets`
`TableModel` conformance itself, and `Repo` consumes changesets directly:

```swift
let changeset = Changeset(original: user)
    .change(\.email, input.email)
    .validate(\.email, .email)
try await repo.update(changeset)
// UPDATE only the dirty columns, addressed by the primary key —
// or INSERT when the changeset has no identity
```

Validation still throws before anything reaches the wire.

### Streaming holds a connection for as long as the client reads

`repo.stream` borrows the leased connection for the duration of its closure —
that is what makes it stream rather than materialize. Put an HTTP response
inside that closure and the *client* decides how long the borrow lasts:

```swift
return .streaming(contentType: .init("text/csv")) { writer in
    _ = try? await pool.withRepo { repo in
        try await repo.stream(query) { rows in
            for try await row in rows { _ = await writer.write(csv(row)) }   // ← suspends on the client
        }
    }
}
```

`writer.write` suspends until the transport has taken the chunk, which is
correct — a producer faster than its reader is slowed rather than buffered —
and it means a reader at 20 KB/s holds a pooled connection for the whole
download. Measured on a pool of four: four such readers, and
`activeCheckouts` is 4, `availableConnections` 0, with every other request
queueing behind them for `checkout_timeout_ms` and then failing. An
unauthenticated client that reads slowly is a denial of service against every
other database user in the process — the slowloris shape, pointed at the
pool rather than at the socket.

Three ways out, in the order they are usually worth reaching for:

1. **Page it.** Fetch a bounded batch, release the connection, write it,
   fetch the next. The export takes more round trips and holds nothing
   between them.
2. **Give exports their own pool.** A second named datasource against the
   same database (`datasource.exports.pool_size: 2`) bounds the damage to
   itself.
3. **Bound the response.** A write timeout on the streamed body — the same
   idea as `alula.channels.write-timeout-seconds` — turns an indefinite hold
   into a failed download.

Nothing here is a defect in either layer; it is what the two correct
behaviours add up to, and it is worth knowing before an export endpoint meets
a slow phone.

### Migrations

Not implemented here — Alula Migrate's. This package only wires the
migrator to the config-resolved datasource URL:

```swift
try await PostgresMigrations.migrate(
    configuration: try Configuration.load(),
    migrations: _allMigrations()      // the AlulaMigratePlugin registry
)
```

Run from a migrate binary or CI step, **never at boot**.

## Testing this package

Unit tests run bare. Integration tests need a real Postgres and are gated on
one environment variable:

```
$ docker run -d --name alula-data-pg -e POSTGRES_PASSWORD=alula \
    -e POSTGRES_DB=alula_data_test -p 127.0.0.1:55432:5432 postgres:16-alpine
$ export ALULA_POSTGRES_TEST_DATABASE_URL="postgres://postgres:alula@127.0.0.1:55432/alula_data_test?sslmode=disable"
$ swift test
```

The suite prepares its schema through `PostgresMigrations.migrate` — the same
path production uses — so the migrations are exercised on every run.

## Design decisions worth knowing (all deliberate, none silent)

| # | Delta | Why |
|---|---|---|
| P1 | This package owns a small fixed-size pool (`PostgresDataSource`) instead of leasing from `PostgresClient` | The sketch called `PostgresClient.leaseConnection()`, which is **private**; the modern client only lends connections inside async closures. The pool is deliberately thin — eager dial at service start, a `Mutex` free list, checkout that queues up to `checkout_timeout_ms`, and a replacement loop — and everything protocol-level stays PostgresNIO's. `PostgresClient` is still used where its shape fits: the migrate wiring, and the Alula-free binding product. |
| P2 | A connection is leased for **one operation**, not for a request | `withRepo`/`withConnection` bracket the lease. The alternative — a `.scoped` connection held for the whole request — pinned a connection for as long as the scope lived, which for a WebSocket upgrade meant one connection per open browser tab. Per-operation leasing makes the hold as short as the work. |
| P3 | Transactions are Hangar's `repo.transaction { }`, not an annotation | A `Repo` fixes `inTransaction` at construction, so an ambient repo built before a unit of work always believed it was outside one — it emitted a literal `COMMIT` when nested, ending the enclosing transaction and making writes durable that the caller meant to roll back. Constructing the repo per operation removes the state that could go stale, and Hangar's own bracket tracks depth and emits savepoints. |
| P4 | A connection returned mid-transaction is dropped, not reused | Every path through `repo.transaction` pairs begin with commit or rollback, but a torn task could still return a connection with a transaction open, and reusing it would leak that state into the next borrower. `DISCARD ALL` is what catches it: Postgres refuses the statement inside a transaction block, and a connection whose reset fails is closed and replaced rather than repooled. This is why `reset_on_release` defaults to on — turning it off gives up this guard as well as the session-state one. (The pool also carries an explicit rollback-on-release path, unreachable since transactions moved into Hangar, which does not tell the pool when it opens one.) |
| P5 | `reset_on_release` issues `DISCARD ALL` between borrowers | Session state — `SET`, prepared statements, temp tables, `LISTEN` registrations — outlives a lease otherwise, and the next borrower inherits it. On by default; turn it off only for a pool whose callers are known to leave nothing behind. |
| P6 | One pool per application, and `@Inject var pool: PostgresDataSource` finds it | This row used to describe qualified versus unqualified *registration*, which was container vocabulary and has not been how this works since alula 0.17.0. Composition wires by type: the datasource module provides its pool as a value and anything injecting `PostgresDataSource` receives it, with no name involved. The generic parameter (`<Analytics>`) names the configuration key the pool is built from, not the type it is provided as — so two instantiations are two pools. Both provide `PostgresDataSource`, which the application resolves with `defaultProviders` and `@Inject(from:)` — see `data-core.md`. Requires alula 0.21.0; before it the two collapsed into one binding. |

Toolchain/upstream deltas (the `.eq()` spelling, the parameter-pack
miscompile workaround, the S1–S4 dialect adaptations) are recorded in
[SPIKE-FINDINGS.md](SPIKE-FINDINGS.md).

## Non-goals

No ORM semantics, no cross-database abstraction, no auto-migration at boot,
no query caching, no Timescale support — all deliberately absent.
