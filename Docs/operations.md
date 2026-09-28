# Operating Alula Data

What someone running this package in production needs to know, in one place:
what the pools do under load and during an outage, what a transaction
guarantees about the connection it ran on, what PubSub and the job queue can
lose, and how migrations behave when a fleet deploys at once.

Where another guide already covers a topic properly, this page says what it
amounts to and links to the section. Everything else is written here, and
describes what the code does in this release, including where it does less
than you might assume.

## Connection pools

Both drivers own a small fixed pool, `PostgresDataSource` and
`ValkeyDataSource`, and share the queueing half of it (`ConnectionWaiters`
in AlulaDataCore). What follows is true of both unless it names one.

### Size, and what a caller waits for

**`pool-size` is a queue depth with a timeout, not a hard ceiling.**
`withConnection`, `withRepo` and `withReadRepo` queue for up to
`datasource.<name>.checkout-timeout-ms` (default 5000) and then fail with
`DataSourceError.poolExhausted`, which a web request sees as `503` with
`Retry-After: 1`. The four `DataSourceError` cases and the status each maps
to are in [data-core.md, What a pool size actually means](data-core.md#what-a-pool-size-actually-means).

What that page does not spell out:

- **The pool is fixed.** Every connection is dialled at start, and nothing
  grows it: `pool-size: 10` (the default) is ten sessions on the server for
  the life of the process, busy or idle. Budget the server's
  `max_connections` for it — per process, the primary's pool, plus the
  replica's pool if one is configured (on the replica's server), plus one
  connection for the PubSub listener if `AlulaPubSubPostgresModule` is
  listed. A migration run opens its own short-lived client beside all of
  those.
- **The queue is not strictly first-come, first-served.** A released
  connection wakes the longest-waiting caller, but a caller that has just
  arrived tries the free list before it queues and can take the connection
  first. The woken caller then queues again, behind everyone who arrived
  while it waited. Under sustained saturation an individual request can time
  out while later ones succeed.
- **A nested lease is a second connection.** `withRepo` inside `withRepo`
  (or `withConnection` inside either) leases another connection rather than
  reusing the first. With every connection held by an outer lease waiting on
  an inner one, every caller waits out its checkout timeout. Pass the `repo`
  or `tx` you already have down to the code that needs it.
- **Cancelling a queued caller is prompt.** A task cancelled while it waits
  throws `CancellationError` at once rather than sitting out its timeout.
  Once a caller holds a connection, cancellation does not take it back: the
  connection returns when the closure exits, and on Postgres a statement
  already sent runs to completion on the server — PostgresNIO sends no
  cancel request. Bound a statement with Hangar's
  `transaction(statementTimeout:)`, not by cancelling the task.

The pool publishes no metrics of its own. It exposes what to put in a gauge:
`activeCheckouts`, `availableConnections`, `establishedConnections`,
`totalCheckouts` and `waitingCallers` (now and peak). `waitingCallers.peak`
rising is the pool saying it is too small before it says so as timeouts. On
Postgres, `establishedConnections` minus the other two is the connections
between borrowers, being rolled back or reset.

A connection held while a slow client reads a streamed response is held for
the whole download, and a few slow readers can starve the pool; see
[Streaming holds a connection for as long as the client reads](data-postgres.md#streaming-holds-a-connection-for-as-long-as-the-client-reads).

### What happens when a connection comes back

`release` decides, in this order:

1. **The pool has shut down**: the connection is closed.
2. **The connection is closed** (it broke while borrowed): it is dropped and
   a replacement is dialled.
3. **Postgres only — a transaction is still open on it**: `ROLLBACK`, then
   the reset below, then back to the pool. If the `ROLLBACK` fails the
   connection is dropped and replaced. See [Transactions and the
   connection](#transactions-and-the-connection).
4. **`reset-on-release` is on** (the default): the session is reset —
   `DISCARD ALL` on Postgres; `DISCARD`, `UNWATCH` and `SELECT <db>` in one
   pipelined round trip on Valkey. If the reset fails the connection is
   dropped and replaced, never reused.
5. Otherwise it goes straight back to the pool.

A connection being rolled back or reset is available to nobody until that
finishes. With the reset on, a reused connection therefore never carries the
previous borrower's `SET ROLE`, `search_path`, temporary tables, `LISTEN`s,
open `MULTI` or selected database. Turn `reset-on-release` off only for a
pool whose callers are known to leave nothing behind; why it defaults on is
[P5 in data-postgres.md](data-postgres.md#design-decisions-worth-knowing-all-deliberate-none-silent).

Releasing a connection twice, or one the pool did not hand out, traps. That
is deliberate: continuing would give one connection to two callers.

### Broken connections

The pool does not probe idle connections. It finds a broken one when it
tries to use it: a checkout skips connections already known to be closed, a
release drops one, a failed reset drops one, and a checkout that finds the
pool empty — or a readiness probe that finds nothing established — asks for
replacements. A connection that dies silently while idle can therefore be
handed out once, and its borrower sees the failure; it is dropped when it
comes back.

Replacement dials with backoff, 100 ms doubling to a 5 s cap, and never
gives up while the pool is running. Each failure logs `failed to replace
broken postgres connection; retrying` (or `valkey`) with the attempt number
and `retry-in`.

### Shutdown

A Postgres pool shuts down in the infrastructure phase, after the HTTP
transport and background services, so requests in flight are finished with
it first. Its `shutdown()`:

1. refuses new checkouts (`DataSourceError.closed`);
2. waits up to 10 seconds for borrowed connections to come back, then logs
   `shutting down with connections still checked out` and carries on;
3. waits up to 5 seconds for rollbacks and resets in progress;
4. closes the idle connections.

A connection returned after that is closed as it comes back. A caller that
was queued when the pool closed is not woken by the shutdown: it receives
`closed` when its own checkout timeout runs out.

A Valkey pool does steps 1, 3 and 4 and does not wait for borrowed
connections; one returned later is retired as it comes back.

## Transactions and the connection

Transactions are Hangar's: `repo.transaction { tx in … }` inside the
`withRepo` bracket that leased the connection. Returning commits, throwing
rolls back, nesting becomes a savepoint. See
[Transactions in data-postgres.md](data-postgres.md#transactions) for the
shape and why it replaced `@Transactional`.

What keeps a connection from going back to the pool mid-transaction:

- **Every `Repo` the pool builds reports its outermost transaction to the
  pool.** `withRepo` and `withReadRepo` hand Hangar a `TransactionObserver`.
  Hangar calls it *before* sending `BEGIN`, and again only once `COMMIT` or
  `ROLLBACK` has been answered. A connection released between the two is
  rolled back before anyone can reuse it — whatever `reset-on-release` says.
- **A failed rollback never reaches the next borrower.** Hangar swallows a
  failing `ROLLBACK` (the body's error is the one worth reporting), so the
  pool still has the transaction marked open. It sends its own `ROLLBACK`
  and, if that fails too, drops the connection and dials a replacement. The
  pool logs `connection returned to pool with an open transaction; rolling
  back`, and on failure `rollback of leaked transaction failed; dropping
  connection`.
- **A `COMMIT` that did not commit throws.** If a statement failed inside
  the transaction and the body caught it and returned normally, Postgres
  answers `COMMIT` with `ROLLBACK`. Hangar checks the answer and throws
  `HangarError.transactionAborted`, naming the statement that failed.
- **A cancelled task does not commit.** The outermost level checks for
  cancellation before `COMMIT`, and rolls back instead.

What is not covered:

- **A `COMMIT` whose answer never arrives.** If the connection drops while
  `COMMIT` is in flight, the call throws and the connection is dropped; the
  transaction may or may not have committed on the server. Nothing here
  retries it or finds out. Writes that must survive that ambiguity need to be
  idempotent.
- **A transaction opened by hand.** `BEGIN` sent through `withConnection` is
  invisible to the pool. With `reset-on-release` on, `DISCARD ALL` then fails
  inside the open transaction block and the connection is dropped, which is
  safe. With it off, the connection goes back to the pool with the
  transaction still open. Use `repo.transaction`.
- **Serialization failures and deadlocks are not retried unless you ask.**
  They reach a client as `503` with `Retry-After: 1`. For `SERIALIZABLE`
  work, `repo.transaction(isolation:retryingOnSerializationFailure:)` reruns
  the whole body, which must then be safe to run more than once.

## When Postgres is unavailable

### At startup

`PostgresDataModule` dials every connection in the application's
before-start hook, one after another, before any service starts. The first
dial that fails stops the start with `ALD-DATA-1001`, naming the datasource,
host, port and database and what the server or network answered — never the
URL or password ([the diagnostic](../Diagnostics/ALD-DATA-1001.md)). There is
no retry at startup: a database that is not accepting connections yet is a
failed start, and the orchestrator's restart policy is the retry. Start the
database first, or let the process be restarted until it is up.

A read replica dials when the service starts, not in that hook. If it fails,
the error is logged (`read replica pool stopped; reads use the primary`) and
the application carries on. That replica **stays down until the process
restarts**: its pool is closed, reads fall back to the primary if fallback is
on, and nothing redials it. A replica that started and then lost its
connections recovers the way the primary does.

### While running

When the database goes away, borrowed connections fail their statements —
through a `Repo`, as Hangar's `DatabaseConnectionError`, which a client sees
as `503` with
`Retry-After: 5` ([What a client sees when the database fails](data-postgres.md#what-a-client-sees-when-the-database-fails)).
As closed connections are discarded, the pool empties and starts redialling.

A checkout against an empty pool:

- queues for its checkout timeout, then fails with
  `DataSourceError.unreachable(reason:)` once a redial has failed, carrying
  the reason (`connection refused (host:port)`, say), or with
  `poolExhausted` if no redial has been attempted yet;
- **once the outage has lasted longer than the checkout timeout, fails at
  once** with `unreachable` rather than making every request wait five
  seconds to be told the same thing.

`unreachable` is a `503` with `Retry-After: 5`. Readiness goes to not-ready:
the datasource's health check, `datasource.<name>`, reports dead when the
pool has no established connections. Liveness is not affected, because
restarting the process does not bring the database back.

### Recovery

The first redial that succeeds logs `postgres reachable again; pool
refilling` with the number of failed attempts, and the pool refills without
further delay, waking a queued caller for each connection it adds. Because
the backoff caps at 5 seconds, the pool notices a recovered database within
about 5 seconds of it accepting connections — sooner if the outage was
short. Nothing needs restarting.

Redialling starts when the pool notices a broken connection — at a
checkout, a release, or a readiness probe — and then continues on its own
until the pool is full. A process that receives no traffic and is not
probed does not notice the outage until its next request.

## Read replicas

Summary of [Read replicas in data-postgres.md](data-postgres.md#read-replicas):
`datasource.<name>.replica.url` adds a second pool. Only `withReadRepo`
reads from it, one call at a time; `withRepo`, and therefore every write and
every transaction, stays on the primary. Without a replica configured,
`withReadRepo` is `withRepo`. The replica is not part of readiness.

What else an operator should know:

- **Fallback happens at checkout, and only there.** When the replica cannot
  give a connection within its checkout timeout (down, or its pool busy),
  the read goes to the primary, and the switch is logged once, as is the
  recovery. A read can therefore wait up to one checkout timeout on the
  replica and then another on the primary. A statement that fails *on* the
  replica — a dropped connection, a query cancelled by the standby because
  of a conflict with recovery — is not retried on the primary; its error
  propagates. `replica.fallback: false` makes a failed checkout throw too.
- **Staleness is unbounded by this package.** Nothing measures replication
  lag or routes around a lagging replica. `withReadRepo` returns whatever
  the replica has.
- **There is no read-your-writes.** A read through `withReadRepo` after a
  write through `withRepo` may not see it. That includes a `withReadRepo`
  inside a `withRepo` transaction: it runs on another connection, so it
  cannot see the transaction's uncommitted writes even when it falls back to
  the primary.
- **Forcing the primary** is `withRepo` — per call, in code. There is no
  configuration switch that sends `withReadRepo` to the primary short of
  removing `replica.url`.
- The replica's pool size defaults to the primary's
  (`replica.pool-size`), and it shares the primary's checkout timeout and
  `reset-on-release`.

## PubSub between nodes

`AlulaPubSubPostgres` (LISTEN/NOTIFY) and `AlulaPubSubValkey`
(PUBLISH/SUBSCRIBE) carry alula's PubSub between processes. Both are
**at most once**: one channel carries every topic, every node receives every
message, and a node that is not subscribed at the moment of a publish never
receives it. Choosing between them is in
[Postgres or Valkey](pubsub-postgres.md#postgres-or-valkey).

### Publishing

alula's `ClusteredPubSub.publish` delivers to this node's subscribers first
and unconditionally, then broadcasts, giving up after
`pubsub.broadcast-timeout` (default 5 seconds). It does not throw: a
broadcast that fails is logged (`distributed broadcast failed; local
delivery unaffected`, or `distributed broadcast timed out; …`) and the
message is lost for every other node.

On Postgres a broadcast is `SELECT pg_notify(…)` on a pooled connection, so
it queues for the pool like any other caller and fails with it when the pool
is exhausted or the database is down. A message whose encoding exceeds 7999
bytes throws `payloadTooLarge` and reaches this node only. On Valkey it is a
`PUBLISH` through the module's client.

### Receiving

| | Postgres | Valkey |
|---|---|---|
| Connection | one dedicated connection per process, outside the pool | the module's `ValkeyClient` |
| Reconnect | every `pubsub.postgres.retry-delay-ms` (default 1000), no backoff | from `pubsub.valkey.retry-delay-ms`, doubling to 30 s, jittered |
| Logs | `pubsub listener lost its connection; …` once, then `pubsub listener reconnected` | `pubsub subscription dropped; retrying` per attempt |
| Relay buffer | 10,000 messages | 1,024 messages |
| Readiness | none | `pubsub.valkey`: a `PING` through the client |

Messages published while a node is reconnecting are missed by that node.
The Valkey readiness check proves the client can reach the server; it does
not check that the subscription itself is established. The Postgres module
contributes no readiness check, so a node whose listener is down still
reports ready.

### Where messages are lost, and how you can tell

| Cause | Visible as |
|---|---|
| Broadcast failed or timed out on the publisher | warning on the publisher, per message |
| Receiving node not subscribed (reconnecting, starting) | the listener's loss and recovery log lines; nothing per message |
| Relay buffer full: the node reads slower than messages arrive | counter `alula.pubsub.dropped` (dimension `adapter`), and a warning at most every 10 s with the count; the **oldest** buffered messages are dropped |
| Postgres payload over 7999 bytes | `payloadTooLarge` on the publisher; delivered locally only |
| A message this build cannot decode | a log line per message on the receiver |

### Publishing on commit

[Publishing on commit](pubsub-postgres.md#publishing-on-commit) introduces
`Outbox`, which publishes a message only if the transaction that wrote it
commits. Precisely, as `AlulaQueuePostgres` implements it:

- **Durable.** `outbox.publish(_:to:in: tx)` writes the message as a job row
  through `tx`, so it commits or rolls back with the rest of the
  transaction. Pass the transaction's `tx`; a different repo writes outside
  it.
- **Published by a queue worker, not by the committing request.** Some
  process running `AlulaQueueWorkerModule` for the `outbox` queue claims the
  job on its next poll (`queue.poll-interval-ms`, default 1000) and calls
  `PubSub.publish`. With no worker running, committed messages wait in the
  table.
- **Not retried because the bus failed.** `publish` cannot throw, so the job
  completes whether or not the broadcast reached any other node. There is no
  retry for a lost broadcast.
- **Can run more than once.** If the worker stops, or cannot renew its
  lease, before the job is recorded complete, the job is claimed again once
  the lease expires (`queue.lease-seconds`, default 60) and published again.
  A renewal failure can make that overlap with the first attempt. Each
  message carries a unique `outbox-id` in its metadata so subscribers can
  discard repeats.
- **Bounded by the job's attempts.** Every claim counts as an attempt, except
  that a job handed back at shutdown gets its attempt back. A job claimed
  back after its last attempt was lost to a dead worker is discarded
  unpublished.
  The envelope uses the queue's default retry policy, ten attempts.
- **Downstream delivery is still at most once.** The worker's own node
  receives the message; other nodes receive it only if the application's
  PubSub is clustered and the broadcast succeeds. Without a distributed
  adapter, only subscribers in the worker's process see it — which need not
  be the process that committed.
- **Not ordered.** Workers run jobs concurrently.

A consumer that must see every event — billing, an external system — should
consume the queue, not the bus.

## The job queue (AlulaQueuePostgres)

`PostgresQueueStore` keeps alula's job queue in a table
(`queue.postgres.table`, default `alula_jobs`). The table is not created at
boot; put `PostgresQueueStore.schema(table:)` in a migration.

**Claiming.** One statement picks due rows with `FOR UPDATE SKIP LOCKED`,
marks them `running`, increments `attempt` and sets `lease_until`.
Concurrent workers split the due rows between them rather than queueing on
each other's locks, and no two claims return the same row. The row lock
lasts only as long as that statement. From then on a job belongs to its
worker by **lease**, not by lock: the worker renews the lease every third of
`queue.lease-seconds` while the job runs.

**Fencing.** Completing, retrying or discarding a job matches on the attempt
number that claimed it. A worker whose lease expired and whose job was
claimed again finds its result update matches nothing, so the second
attempt's outcome is the one recorded.

**What survives a crash.** Everything committed: jobs waiting, jobs
running, and their attempt counts. A job whose worker died stays `running`
until its lease expires and is then claimed again with the next attempt
number. Whatever the dead attempt did outside the database has already
happened, so execution is **at least once**, and handlers must tolerate
running twice.

**Enqueueing inside a transaction.** `enqueue(_:in: tx)` writes the job
through your transaction, so it exists exactly when the rows beside it do.
Unique jobs (`uniqueKey`) are deduplicated against jobs still `available` or
`running`, by a partial unique index.

**Clocks.** `run_at`, `lease_until` and the claim's "now" come from the
application processes' clocks, not the database's. Skew between servers
delays scheduled jobs by the skew, and skew approaching the lease can let a
job be claimed from a worker that is still running it. Keep the servers'
clocks synchronised.

Finished rows are deleted by the worker after `queue.retain-completed-hours`
(24) and `queue.retain-discarded-days` (14).

## Migrations in a deployment

[The guarantees, precisely](migrate.md#the-guarantees-precisely) is the
contract: each migration runs in its own transaction together with its
ledger row, the whole run holds a Postgres advisory lock, and applied
migrations are checksummed. What that means for a deploy:

- **Run migrations as a step, then roll out.** Nothing migrates at boot, and
  nothing at boot checks that the schema is current: an application started
  against an unmigrated database fails on the first query that needs the
  change. A migrate job, an init container or a CI step runs first; the
  application follows.
- **Several instances starting the migration at once serialize.** The first
  takes the lock; the others wait for it, find nothing pending, and exit
  successfully. The wait is bounded by `lockTimeout` (30 seconds by default,
  `--lock-timeout` on the CLI): if the first run takes longer than that, the
  waiting ones fail with the lock-timeout error rather than hanging, so set
  it above your longest migration or run the migration from one place only.
  What to check when it fires is in the [runbook](../Sources/Migrate/AlulaMigrate/AlulaMigrate.docc/OperationalRunbook.md#advisory-lock-timeout).
- **A failure mid-run keeps what already committed.** Migrations apply one
  transaction each, in version order. If the third of five fails, the first
  two stay applied and recorded, the third is rolled back completely, and
  the last two are not attempted. Fix and rerun; it resumes at the third.
  An unwrapped migration (`wrapInTransaction = false`) is the exception —
  see [Migrations that can't run in a transaction](migrate.md#migrations-that-cant-run-in-a-transaction).
- **The lock is released if the migrator dies.** It is a session-level
  advisory lock on the migrator's own connection, so the server releases it
  when that connection closes.
- **Old code meets new schema during a rollout.** Pods still running the
  previous build see the new schema, so each migration has to be one the
  previous build survives — add before use, drop after the last reader is
  gone. An older migrator that finds versions it does not know warns and
  proceeds by default; `failOnUnknownApplied` makes that fatal.

## Valkey

### The data source

[What happens when the server goes away](data-valkey.md#what-happens-when-the-server-goes-away)
covers it: the pool redials with the same backoff as the Postgres pool
(100 ms to 5 s, forever) and logs the loss and the recovery. Two differences
from Postgres matter operationally. A checkout during an outage fails with
`poolExhausted`, not `unreachable`, and without the Postgres pool's
fail-fast once the outage outlasts the checkout timeout. And the pool dials
when its service starts rather than in a before-start hook, so a server that
refuses the connection fails the start from inside the running service
group, still as `ALD-DATA-1001`.

### Cache, sessions and the rate limiter

These three hold valkey-swift's own `ValkeyClient` rather than the data
source's pool. The client's connection breaker is what makes a down server
fail fast: `unreachable-after` bounds how long a call waits for a
connection, `command-timeout` how long a command may run once it has one.
Setting only the second leaves the first at the driver's 60-second default —
[CV1 in cache-valkey.md](cache-valkey.md#design-deltas).

What each does when Valkey is unavailable:

| Store | On failure | Readiness |
|---|---|---|
| `ValkeyCache` | Fails open: a read is a miss, a write or eviction does nothing. Counted in `alula.cache.store_errors`. | not checked |
| `ValkeySessionStore` | Throws. alula's `Sessions` middleware answers `503` for a request that carries a session cookie or changes a session; a request with neither never touches the store. | `sessions.valkey` |
| `ValkeyRateLimitStore` | Throws. alula's `RateLimiting` middleware serves the request and logs `rate limit store unavailable` per request by default (`onStoreFailure: .deny` refuses with `503`); alula's sign-in throttle refuses instead. | not checked |

Consequences worth planning for:

- **Evictions during a cache outage are lost.** `@CacheEvict` against a
  cache that is failing open does nothing, so a value cached before the
  outage and invalidated during it is served again once the cache is back,
  until its TTL expires. Keep TTLs as short as that staleness can afford.
- **A failed session save comes after the handler ran.** The handler's work
  is done; the client is told `503`. See
  [alula's sessions guide](https://github.com/Alula-Framework/alula/blob/main/Docs/sessions.md).
- **Sign-out-everywhere can miss a session saved during a partial failure.**
  Saving a signed-in session writes the session, then its owner index, as
  separate commands. A failure between them throws, but the session is
  stored and not in the index.
- **The limiter is not enforcing while Valkey is down**, with the default
  policy. That is the trade described in
  [Failure is reported, not decided](rate-limit-valkey.md#failure-is-reported-not-decided).

### The cache's own breaker

`ValkeyCache` also has a breaker of its own for a server that accepts
connections but fails its commands: after 5 consecutive failures that say
something about the store's health it skips the store for 3 seconds, then
admits one probe; success closes it, failure starts the cool-off again. A
command the server merely refuses (`WRONGTYPE`, `OOM`) fails that one
operation and does not count. The reasoning is in
[What the breaker is for](cache-valkey.md#what-the-breaker-is-for).

A probe that ends with no verdict — cancelled, or failed for a reason that
says nothing about the store, such as the client's own breaker while the
server is still down — gives the probe up, and the next call probes instead.
(Before 0.24.0 such a probe was never reported, and the cache stayed off
until the process restarted.)

### Recovery

Beyond the defect above, nothing needs restarting for the client-based
stores: valkey-swift's pool breaker heals itself
([CV2](cache-valkey.md#design-deltas)), the session and limiter stores answer
again as soon as the client does, and PubSub resubscribes with backoff.
