# ``FlightDataCore``

The store-neutral data seam: what a driver has to provide, and what
everything above it is allowed to assume.

## Overview

``DataSource`` is the whole contract. A driver — Postgres, Valkey, an
in-memory fake — implements it, registers itself, and everything that reads
or writes goes through it. Nothing above this module names a database.

That narrowness is the design. There is no cross-database query abstraction
here and there will not be: Postgres and Valkey do not answer the same
questions, and a layer pretending otherwise ends up serving neither well.
What *is* shared is connection acquisition, leasing, and liveness — which
genuinely are the same problem everywhere.

## Connections are leased per operation

A repository holds the *pool*, and brackets each operation with
``DataSource/withConnection(isolation:_:)``. The connection is checked out
when the operation starts and returned when it ends, on the success and
error paths alike:

```swift
@Repository
struct OrderRepository {
    @Inject var pool: PostgresDataSource

    func find(_ id: UUID) async throws -> Order? {
        try await pool.withConnection { connection in
            // ...
        }
    }
}
```

A repository is therefore a singleton, and so is every service holding one.
A connection used to be a `.scoped` component held for a whole request,
which made the repository request-scoped and everything above it
request-scoped too — lifetime propagating up the dependency graph from what
is really a pooling concern. This is the model Go's `*sql.DB` and Ecto's
`Repo` both settled on.

Work that must share one connection says so by putting it in one bracket, or
in a transaction. Two separate operations may land on two connections.

## Naming a source

``DataSourceName`` and ``PrimaryDataSource`` are how an application with more
than one database says which is which. One source is the primary; the rest
are named, and a component asks for the one it wants by qualifier rather than
by hoping the right one was registered first.

## Configuration and failure

``DataSourceSettings`` and ``DataSourceConfigKey`` are the shared
configuration shape a driver reads. ``DataSourceConfigurationError`` fires
during bootstrap — a malformed URL or a missing password is a startup
failure, not a first-query surprise. ``DataSourceError`` is the runtime
half, and ``DataSourceLiveness`` is what the actuator's health endpoint
reports.

## Topics

### The seam

- ``DataSource``

### Naming

- ``DataSourceName``
- ``PrimaryDataSource``

### Configuration

- ``DataSourceSettings``
- ``DataSourceConfigKey``
- ``DataSourceConfigurationError``

### Health and failure

- ``DataSourceLiveness``
- ``DataSourceError``
