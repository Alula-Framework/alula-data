# ``AlulaDataPostgres``

The Postgres driver: a pooled `DataSource`, a connection leased per
operation, and transactions as a visible bracket.

## Overview

Listing ``PostgresDataModule`` gives the application a pooled
``PostgresDataSource``, and everything above it works in terms of
`AlulaDataCore`'s seam rather than PostgresNIO:

```yaml
datasource:
  primary:                                    # the datasource NAME, not the store
    url: postgres://app@localhost:5432/app
    pool-size: 10
    checkout-timeout-ms: 5000                 # how long a caller queues before failing
    reset-on-release: true                    # DISCARD ALL between scopes
```

The key under `datasource:` is `Name.name` from the module's generic parameter
— `primary` for `PostgresDataModule<PrimaryDataSource>`. This page showed
`data: postgres:` for a while, which is not a prefix anything reads; copying it
produced a bootstrap failure about a missing `datasource.primary.url`.

``PostgresDataSourceURL`` parses and validates that URL during bootstrap, so
a typo is a startup failure with a message rather than a connection error on
the first request. The module then dials every connection in a before-start
hook, before any service of the application starts, so a database that
refuses the connection is reported first and alone, as `ALD-DATA-1001`.

## What a client sees

A request that fails on the database gets a status that says what happened,
not an opaque `500`. This module conforms Hangar's errors to alula's
`TemporarilyUnavailable` and `RejectedInput`:

- A transient `DatabaseError` — a deadlock, a serialization failure, a lock
  not available, a cancelled statement, the server starting up or shutting
  down — is `503` with `Retry-After: 1`.
- A `DatabaseConnectionError` for a database that cannot be reached, or a
  connection that dropped, is `503` with `Retry-After: 5`. A refused login, a
  TLS failure or a closed pool is configuration, and stays a `500`.
- `HangarError.unknownFilterField` and `.invalidFilterValue` are `400`, with a
  message naming only the field the request gave, never the table.

The pool's own `DataSourceError` is `503` too, except a checkout before the
pool started, which is a bug and stays a `500`.

## Transactions are a bracket

Hangar owns transactions. `withRepo` — this module's extension on
`AlulaDataCore`'s `DataSource` — leases a connection and hands you a `Repo`
bound to it; `repo.transaction { }` is the unit of work:

```swift
@Repository
struct OrderRepository {
    @Inject var pool: PostgresDataSource

    func place(_ input: OrderInput) async throws -> Order {
        try await pool.withRepo { repo in
            try await repo.transaction { tx in
                let order = try await tx.insert(...)
                try await tx.insert(...)   // same connection, same transaction
                return order
            }
        }
    }
}
```

Every query inside runs on one connection. Throwing rolls back. Nesting
becomes a savepoint, so an inner failure can be handled without discarding
the outer work — Hangar tracks the depth, which is what makes the nesting
correct.

This replaces `@Transactional` and a `PostgresTransactionCoordinator` that
found the connection through the ambient scope. The extent of a transaction
is now visible in the code that opens it, rather than inferred from an
annotation and a scope you cannot see.

## Migrations

`AlulaMigrate` owns schema change; this module contributes
``PostgresMigrations``, which runs an `AlulaMigrator` against a datasource's
configured URL. `alula migrate`, or a project's own migrate executable built
on `AlulaMigrateCLI`, is the command-line side.

## Topics

### The driver

- ``PostgresDataModule``
- ``PostgresDataSource``
- ``PostgresDataSourceURL``

### Migrations

- ``PostgresMigrations``

### Failure

- ``PostgresDataSourceURLError``
