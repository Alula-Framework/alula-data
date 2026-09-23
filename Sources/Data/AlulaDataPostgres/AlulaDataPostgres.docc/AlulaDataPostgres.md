# ``AlulaDataPostgres``

The Postgres driver: a pooled `DataSource`, a connection leased per
operation, and transactions as a visible bracket.

## Overview

Registering ``PostgresDataModule`` gives the container a pooled
``PostgresDataSource``, and everything above it works in terms of
`AlulaDataCore`'s seam rather than PostgresNIO:

```yaml
datasource:
  primary:                                    # the datasource NAME, not the store
    url: postgres://app@localhost:5432/app
    pool_size: 10
    checkout_timeout_ms: 5000                 # how long a caller queues before failing
    reset_on_release: true                    # DISCARD ALL between scopes
```

The key under `datasource:` is `Name.name` from the module's generic parameter
— `primary` for `PostgresDataModule<PrimaryDataSource>`. This page showed
`data: postgres:` for a while, which is not a prefix anything reads; copying it
produced a bootstrap failure about a missing `datasource.primary.url`.

``PostgresDataSourceURL`` parses and validates that URL during bootstrap, so
a typo is a startup failure with a message rather than a connection error on
the first request.

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
``PostgresMigrations``, the Postgres implementation of the migration
database. `alula migrate` is the command-line side.

## Topics

### The driver

- ``PostgresDataModule``
- ``PostgresDataSource``
- ``PostgresDataSourceURL``

### Migrations

- ``PostgresMigrations``

### Failure

- ``PostgresDataSourceURLError``
