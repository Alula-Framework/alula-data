# ``AlulaQueuePostgres``

A durable store for Alula's job queue, in a Postgres table.

## Overview

List the module, and `AlulaQueueModule` keeps jobs in Postgres instead of
memory:

```swift
await Alula.run(configuration: try .load(), modules: [
    PostgresDataModule<PrimaryDataSource>.self,
    AlulaQueuePostgresModule.self,
    AlulaQueueWorkerModule.self,
    AppModule.self,
], composedBy: alulaComposeModules)
```

Workers on every replica claim from the one table with a single
`FOR UPDATE SKIP LOCKED` statement, so they share the queue without waiting
on each other's row locks.

``PostgresQueueStore/enqueue(_:in:)`` writes a job inside the caller's own
transaction, so the job exists exactly when the change that caused it does.

The table is not created at boot. Put ``PostgresQueueStore/schema(table:)``
in a migration, or call ``PostgresQueueStore/createTableIfNeeded()`` in
tests.

## Topics

- ``AlulaQueuePostgresModule``
- ``PostgresQueueStore``
- ``PostgresQueueStoreError``
