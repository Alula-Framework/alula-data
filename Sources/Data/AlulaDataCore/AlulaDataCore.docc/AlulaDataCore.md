# ``AlulaDataCore``

The store-neutral data seam: what a driver has to provide, and what
everything above it is allowed to assume.

## Overview

``DataSource`` is the whole contract. A driver — Postgres, Valkey, an
in-memory fake — implements it, its module provides the pool, and everything
that reads or writes goes through it. Nothing above this module names a database.

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
are named: the application says which pool an unqualified `@Inject` means
with `defaultProviders`, and a component that wants another names its module
with `@Inject(from:)`.

## Configuration and failure

``DataSourceSettings`` and ``DataSourceConfigKey`` are the shared
configuration shape a driver reads. ``DataSourceConfigurationError`` fires
during bootstrap — an empty URL or a pool size below one is a startup
failure, not a first-query surprise. ``DataSourceStartupError`` is a source
that could not connect at startup (`ALD-DATA-1001`): which source, where it
dialled, and what came back, never the password. ``DataSourceError`` is the
runtime half; a web request that meets one gets a `503` with `Retry-After`,
except a checkout before the pool started, which stays a `500`.
``DataSourceLiveness`` is what the actuator's health endpoint reports.

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
- ``DataSourceStartupError``
