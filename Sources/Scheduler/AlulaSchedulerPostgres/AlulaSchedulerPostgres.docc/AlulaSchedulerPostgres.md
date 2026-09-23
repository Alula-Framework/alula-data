# ``AlulaSchedulerPostgres``

Makes a scheduled job's `.once` mean once across every server.

## Overview

`AlulaScheduler` runs a job once per firing. On a single server that needs
nothing. On several it needs something the servers can contend through, and
this is that something:

```swift
// A module provides the coordinator as a value; the composition root hands
// it to AlulaSchedulerModule, matched by type:
let jobCoordinator: any JobCoordinator =
    PostgresJobCoordinator(dataSource: graph.postgresDataSource)
```

Provide it and the scheduler's startup line changes from `single-process`
to `postgres lease` — and the warning about run-once jobs with no coordinator
stops, because there now is one.

## Why a lease row rather than an advisory lock

`pg_try_advisory_lock` is the obvious choice and the wrong one here. It is
**session**-scoped: the lock belongs to the connection that took it and must
be released on that same connection. This package hands out *pooled*
connections, so a claim and its release would routinely land on different
ones — the release silently failing and the lock outliving the job. Holding a
single connection for the job's whole duration avoids that by trading a
correctness bug for a pool-exhaustion bug.

A lease row has neither problem. `INSERT … ON CONFLICT DO NOTHING` is atomic,
needs no connection affinity, and the row doubles as history: the table
answers "did last night's billing job run, and on which server" with no extra
bookkeeping.

## The claim is per firing, not per job

The primary key is `(job, scheduled_for)`, and the scheduler passes the
*schedule's* instant rather than a local `now`. Two servers whose clocks
differ by a second still agree about which firing they are competing for, and
tomorrow's firing of the same job is a separate row — otherwise a job would
run once and never again.

## The table

``PostgresJobCoordinator/createTableIfNeeded()`` exists for tests and for
deployments that do not use `alula migrate`. An application with migrations
should own this table in one, so the schema is versioned like the rest:

```sql
CREATE TABLE alula_job_leases (
    job text NOT NULL,
    scheduled_for timestamptz NOT NULL,
    claimed_by text NOT NULL,
    claimed_at timestamptz NOT NULL,
    PRIMARY KEY (job, scheduled_for)
);
```

A deployment that created `flight_job_leases` before the rename to Alula
either creates this table in a new migration or keeps the old one with
`PostgresJobCoordinator(dataSource:table:)` and `table: "flight_job_leases"`.
Switching tables mid-deploy lets a replica on each version claim the same
firing, so switch between firings of your most frequent job, or keep the old
name.

It grows by one row per job per firing — small, but not bounded.
``PostgresJobCoordinator/prune(olderThan:)`` trims it, and the natural place
to call that is a scheduled job:

```swift
@Scheduled("0 0 4 * * *")
func pruneJobLeases() async throws {
    try await coordinator.prune(olderThan: .days(7))
}
```

## Topics

- ``PostgresJobCoordinator``
