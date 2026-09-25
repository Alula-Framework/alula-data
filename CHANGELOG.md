# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.19.1] - 2026-09-25

### Fixed

- **`ValkeyRateLimitStore` refuses a negative cost.** Its script computes
  `tat + cost * emission`, so a negative cost did not fail — it handed
  permits back. It now throws `RateLimitStoreError`, as alula's in-memory store
  does since alula 0.52.0, whose `RateLimiting` middleware also charges a
  negative computed cost as one permit.
- **Postgres warnings say why a connection failed** (Relay #34). A
  reconnect, a failed session reset, a leaked-transaction rollback, a
  stopped read replica and a lost PubSub listener logged PostgresNIO's
  deliberately opaque description. They now log what is safe: a server
  error's SQLSTATE and kind (Hangar's `DatabaseError` description) with the
  meaning of the SQLSTATEs a connection meets — `authentication failed`,
  `the database is starting up`, `too many connections` — or, for a
  connection failure, PostgresNIO's error code and the system error.
- **A startup failure names the port that was configured.** A data source
  built from a `PostgresConnection.Configuration` reported port 5432 and
  host `<configured directly>` whatever it had been given.

## [0.19.0] - 2026-09-25

alula-data's share of the Alula diagnostics design.

### Changed

- **Cache annotation errors carry codes.** `@Cacheable`, `@CachePut` and
  `@CacheEvict` report `[ALD-CACHE-1001]` to `[ALD-CACHE-1005]`, each with a
  note linking its page in `Diagnostics/`. `alula explain` points at them too.
- **Migration errors are located at the file, with codes.** The registry
  generator printed `error: [AlulaMigrate] <path>: …`, with the path after the
  severity, so nothing attached the error to the file. It now prints
  `<path>:1:1: error: [ALD-MIGRATE-200x] …`, and a duplicate version points at
  one file with a note at the other. `GeneratorError` gains `issues` (code,
  path, message, related files); `problems` is still each issue as printed.
- A test fails if a code has no page, a page has no code, or no test
  produces a code (8/8).

## [0.18.1] - 2026-09-25

Found running Relay's rolling-restart scenarios (relay/docs/ISSUES.md #36, #37).

### Fixed

- **A timed-out shutdown no longer crashes the process.** `ValkeyPubSubService`
  ran the Valkey client in an ordinary `Task`, which inherits the service's
  task-locals, including swift-service-lifecycle's graceful-shutdown manager.
  `ValkeyClient.run()` wraps itself in `cancelWhenGracefulShutdown`, so the
  pool shut itself down on the service's own shutdown signal, at the same
  moment as the subscription drain rather than after it. When the pool won,
  the subscription's release found its connection already shut down, and
  valkey-swift's state machine trapped (SIGILL). Relay Lab hit it in 5 of 15
  shutdowns that ran past `lifecycle.shutdown-timeout-seconds`; with the pool
  in a detached task, 0 of 30.
- **alula-data builds from a clean checkout.** `AlulaPubSubValkey` and
  `AlulaPubSubPostgres` import `Metrics` for their drop counters but never
  declared it. The 0.17.0 audit fix meant to add it to them, and put two
  copies in `AlulaCache` instead; 0.18.0 removed those duplicates, leaving the
  PubSub targets building only when another target had already made `Metrics`
  visible. `swift build --explicit-target-dependency-import-check error` now
  passes for every alula-data target.

## [0.18.0] - 2026-09-25

Requires alula 0.48.0.

### Added

- **A datasource that cannot start says why.** alula 0.48.0 prints a
  startup failure's `StartupDiagnostic` rather than its reflected form,
  which could carry secrets — and PostgresNIO's `PSQLError` describes
  itself only as a generic "prevent accidental leakage" placeholder, so a
  Postgres pool that failed to start printed nothing useful. Postgres and
  Valkey pools now fail `start()` with `DataSourceStartupError`: the
  datasource, host, port and database, and what came back — the network
  error (`connection refused`, errno), or the server's message and SQLSTATE
  (`28P01` for a wrong password). Never the URL or the password; tests
  check both with a password that must not appear.
- **Readiness sees Valkey-backed sessions and PubSub.**
  `AlulaSessionsValkeyModule` and `AlulaPubSubValkeyModule` contribute a
  `HealthCheck` (`sessions.valkey`, `pubsub.valkey`: a `PING`). Readiness
  answered UP with Valkey gone, while every signed-in request failed and
  realtime became single-node. The rate limiter's store has no check, on
  purpose: it fails open by design, logging each request it could not
  limit, and making readiness depend on it would turn that degraded mode
  into an outage. Found building Relay.

### Fixed

- The documentation build failed: a DocC link to alula's
  `StartupDiagnostic` from AlulaDataCore used double backticks, which only
  resolve within the module.
- `AlulaCache` declared swift-metrics' `Metrics` product three times, and
  every consumer's build warned about it.

## [0.17.0] - 2026-09-25

Requires Hangar 0.10.1, whose Postgres audit fixes — transactions that
refuse to report an aborted commit, typed `DatabaseError`, safe pagination,
chunked batch inserts, and more — every repository here now runs on. See
Hangar's changelog; the breaking parts (server errors are `DatabaseError`,
`Repo.execute` returns `DatabaseRows`) reach code that uses a `Repo`
directly.

### Added

- **Enum types in migrations:** `createEnum`, `addEnumValue(s)` (one
  `ADD VALUE` per value, `IF NOT EXISTS` by default), `renameEnumValue`,
  `dropEnum`, and the column type `.enumeration(_:)`. A value added in a
  transaction cannot be used before it commits (SQLSTATE 55P04), so add it in
  one migration and use it in the next — documented, and tested.

### Fixed

- **An open transaction can no longer reach the next borrower.** Hangar
  sends `BEGIN`/`COMMIT` itself, so the pool could not tell a connection
  mid-transaction from an idle one; its roll-back-before-reuse path had been
  unreachable since transactions moved into Hangar. `DISCARD ALL` failing
  inside a transaction block covered for it by default, but with
  `reset_on_release: false` a connection released mid-transaction went
  straight back to the pool, and the next scope inherited — and could commit
  — the previous scope's work (external audit; reproduced). `withRepo` and
  the read-replica path now hand Hangar 0.10.1's `TransactionObserver` to
  every `Repo`, so the pool knows, whatever the reset setting.
- **PubSub drops are observable.** Both relay adapters ignored what their
  bounded buffer's `yield` returned, so a full buffer dropped messages with
  no trace. Each drop increments `alula.pubsub.dropped` (dimensioned by
  adapter), and a warning with the count is logged at most every ten seconds.
  Dropping stays the contract; losing silently does not.
- **Rename leftovers**: "single-alula" and "mid-alula" read "single-flight"
  and "mid-flight" again, and the dependency snippets in the README and
  guides name current versions (the old ones predate the `alula` names).
- **A `.double` default of NaN or infinity** rendered `nan`/`inf`, which is
  not SQL; it renders `'NaN'`/`'Infinity'`.
- **String literals holding a backslash** are written as `E'…'`, so a
  default or enum label means the same text whatever the server's
  `standard_conforming_strings`.

### Documentation

- **The outbox's guarantee is stated as what it is:** durable, at-least-once
  *invocation* of the bus after the commit — not durable delivery. `publish`
  does not throw, so a distributed adapter that cannot forward a message
  logs and moves on while the outbox job completes.

## [0.16.0] - 2026-09-24

A transactional outbox: the rest of gap #9 on alula's 2026-09-24 audit
(GAPS.md §0).

### Added

- **`Outbox`** (AlulaQueuePostgres) publishes a message to the application's
  `PubSub` if and only if the transaction it was written in commits.
  - `publish(_:to:in:)` writes the message as a job in the caller's
    transaction. The queue worker publishes it once committed.
  - A committed message survives a crash before it is published. A
    rolled-back one is never published.
  - Delivery into the bus is at least once, and each message carries a
    unique `outbox-id` in its metadata. Messages are not ordered.
- **`AlulaOutboxModule`** provides the `Outbox` and registers its handler on
  the `outbox` queue.
- AlulaQueuePostgres now depends on alula's `AlulaPubSub` product.

## [0.15.0] - 2026-09-24

PubSub over Postgres: gap #9 on alula's 2026-09-24 audit (GAPS.md §0).
Running more than one replica used to require Valkey.

### Added

- **`AlulaPubSubPostgres`** (trait `Postgres`): `PostgresPubSubAdapter` and
  `AlulaPubSubPostgresModule` carry PubSub between nodes over
  `LISTEN`/`NOTIFY`.
  - One dedicated listening connection, reconnected automatically.
  - Broadcasts go through the pool.
  - Payloads over Postgres's 8000-byte NOTIFY limit are refused with their
    size.
  - See Docs/pubsub-postgres.md.
- `PostgresDataSource.dedicatedConnection()`: a connection outside the pool,
  for long-lived sessions such as a `LISTEN`.

## [0.14.0] - 2026-09-24

Read replicas: gap #7 on alula's 2026-09-24 audit (GAPS.md §0). Hangar
could route reads to a replica, but alula-data's pool pinned every operation
to one connection and nothing configured a replica.

### Added

- **`datasource.<name>.replica.url`** (plus `replica.pool_size` and
  `replica.fallback`): a second pool for the datasource, run beside the
  primary's.
- **`PostgresDataSource.withReadRepo { repo in … }`** reads from the replica.
  - Opt-in per call, never automatic, so read-your-writes code stays correct.
  - Falls back to the primary when the replica cannot give a connection,
    logged once on the way down and once on the way back.
  - Without a replica it behaves as `withRepo`.
- `PostgresDataSource.replica`.

## [0.13.0] - 2026-09-24

Requires alula 0.38.0.

### Added

- **`AlulaQueuePostgres`** (trait `Postgres`): a durable store for alula's
  job queue.
  - `PostgresQueueStore` claims with one `FOR UPDATE SKIP LOCKED` statement,
    so workers on every replica share a queue without contending.
  - `enqueue(_:in:)` writes a job through a Hangar `Repo`, inside the
    caller's transaction.
  - `schema(table:)` gives the SQL for a migration; the table is not created
    at boot.
  - `AlulaQueuePostgresModule` provides it to `AlulaQueueModule`.
    Configuration: `queue.postgres.table`, default `alula_jobs`.
- A differential test runs every store-contract scenario against both the
  in-memory store and Postgres, plus two Postgres-only tests: 8 concurrent
  claimants never share a job, and a rolled-back transaction leaves no job.

## [0.12.0] - 2026-09-24

Requires alula 0.37.0.

### Fixed

- **A dead datasource reported healthy.** `DataSourceLiveness` described
  itself as "the surface Alula Actuator reads", but nothing read it. The
  Postgres, Valkey and in-memory datasource modules now hold
  `healthChecks: [HealthCheck]`, their pool's ping. The composition root
  collects it into Actuator's readiness probe, so a store that stops
  answering turns `/actuator/health/ready` into `503` and leaves liveness
  alone. Rebuild to regenerate the composition.

### Added

- `DataSourceLiveness.healthCheck`: the probe as a `HealthCheck`, named
  `datasource.<name>` in logs.

## [0.11.0] - 2026-09-23

Requires alula 0.36.0. flight-data is now **alula-data**, following the
framework's rename (alula D45).

### Changed

- **Breaking: every brand spelling is renamed.** Modules, types, products
  and the package become `alula-data`, `AlulaMigrate`, `AlulaDataPostgres`,
  `AlulaSessionsValkey` and so on. The tools become `alula-migrate` and
  `alula-migrate-gen`, and the plugin is `AlulaMigratePlugin`.
- **The default migrations ledger is `alula_migrations`, and an existing
  `flight_migrations` ledger is adopted.** Adoption happens when the
  configured table is the default, it doesn't exist, and `flight_migrations`
  does:
  - `migrate`, `rollback` and `repair` rename the old table in place while
    holding the advisory lock;
  - `status` and the plans read it where it is.

  A custom `migrationsTable` is never touched.
- **What stays the same across the rename.** The checksum domain stays
  `flight-migrate:v1`, and the advisory-lock key stays the bytes of
  `FLIGHTMG`. Recorded checksums still verify, and a 0.10 deploy and a
  0.11 deploy still serialize on the same lock.
- **Breaking: the Valkey key prefixes are `alula-session:`,
  `alula-session-owner:`, `alula-token:`, `alula-rate-limit:` and
  `alula-cache:`.** Existing sessions, one-time tokens and rate-limit windows
  are left behind, so everyone signs in again once.
- **Breaking: the scheduler's default lease table is `alula_job_leases`.**
  Create it in a migration, or pass `table: "flight_job_leases"` to keep the
  old one.

## [0.10.0] - 2026-09-22

Requires flight 0.32.0.

### Added

- **Sign out everywhere, across replicas.** `ValkeySessionStore` is an
  `OwnerIndexedSessionStore`. Each signed-in session's id is kept in a
  `flight-session-owner:<subject>` set, and flight's
  `SessionRuntime.revokeSessions(ownedBy:keeping:)` ends every other
  session one person has. Before deleting a session, it rereads the record
  and checks the owner, so a stale index entry can't end someone else's
  session. The set expires with its sessions (`PEXPIRE NX`, then `GT`).
- **`ValkeyOneTimeTokenStore`**: flight's `OneTimeTokenStore` over
  `SET … PX` and `GETDEL`. Password-reset, verification and magic links
  work exactly once across every replica, and twenty racing redemptions of
  one link get one success. `init(sharing:)` reuses the session store's
  client. Needs Valkey or Redis 6.2+.

## [0.9.0] - 2026-09-22

Requires flight 0.26.1.

### Added

- **`FlightRateLimitValkey`.** The shared store behind flight's new rate
  limiter, so a quota is enforced once across every replica rather than once
  per replica. The whole decision is a single `EVAL`: GCRA's state is one
  timestamp per key, so deciding and recording is a read, a comparison and a
  write of one value, which a Lua script does atomically on the server in one
  round trip — no lock, no `WATCH`/`MULTI` retry, and no window in which two
  replicas both admit a call against the same under-quota key. The script
  uses the server's `TIME`, because a limiter keyed on each client's idea of
  now has as many opinions as there are pods, and it sets a TTL equal to the
  time until the key is back at full, so idle keys are reclaimed without a
  sweeper.

  Nothing here fails open: a failure throws and the caller decides, which is
  what lets flight's middleware serve the request while a login throttle
  refuses. Configuration is `rate-limit.valkey.*`, with a shorter default
  command timeout than the session store's, since a limiter sits in front of
  work the caller wants done. The URL grammar and driver configuration are
  the cache adapter's, reused rather than written a third time.

  The integration suite runs the same scenarios against this store and
  flight's in-memory one and compares the decisions, because two
  implementations of one algorithm are only trustworthy if something checks
  them against each other. It earned that on its first run: flight's GCRA
  was doing its arithmetic in fractional seconds, and against wall-clock
  timestamps near 1.8e15 that lost enough precision to report one permit
  fewer than were free. Fixed in flight 0.26.1, which this release requires.

### Fixed

- **`flight-migrate --version` reported 0.7.1 again.** The constant is
  hand-written, a build plugin cannot see the tag, and it went stale across
  0.8.0 exactly as it had across 0.6.0 and 0.7.0. The test that pins it to
  the changelog caught it, in a suite that only runs with servers up — which
  is why it was not caught at 0.8.0's release.

## [0.8.0] - 2026-09-21

Requires flight 0.23.0.

### Added

- **`FlightSessionsValkey`.** The shared store behind flight's new sessions:
  `ValkeySessionStore` implements `SessionStore` with one key per session
  under `flight-session:` and the TTL as native expiry, and
  `FlightSessionsValkeyModule` provides it as `store: any SessionStore` for
  `FlightSessionsModule` to take in composition. Every failure throws — the
  middleware answers 503 — so unlike the cache adapter there is no breaker
  and no fail-open; the pool's own circuit breaker still bounds a down
  server. Configuration is `sessions.valkey.*`, kebab-case with duration
  strings, and the URL grammar and driver configuration are the cache
  adapter's, reused rather than copied a third time. Docs/sessions-valkey.md
  is the guide.

## [0.7.1] - 2026-09-19

### Fixed

- **`flight-migrate --version` reported 0.5.1.** The constant is hand-written —
  a build plugin cannot see the tag — and went stale across 0.6.0 and 0.7.0.
  A test pins it to the changelog's most recent release, added the last time
  this happened, and it had been failing into a CI job nobody could see.

- **`FlightCacheModule.init` documented two of its three parameters.** DocC
  treats a partially documented parameter list as an error under
  `--warnings-as-errors`, which is the whole docs job; all ten targets build
  clean now.

### Changed

- **macOS builds and the job is required.** It was advisory on the grounds
  that swift-configuration could not compile on Darwin. That is an SDK
  question rather than an upstream dead end: on the `macos-26` image it builds
  with the deployment target untouched. Requires flight 0.21.2, which is the
  first release a Mac can build.

- **flight's CI builds this package on every commit again.** The wiring had
  never once run: a concurrency group that resolves to the caller's cancelled
  the job before it started, a bare checkout cloned the caller rather than
  this package, and the manifest repoint ran `python3`, which the slim Swift
  images do not have.

### Documentation

- Requirements state the build SDK and the deployment target separately,
  because they are different numbers: what you build runs on macOS 15, and
  compiling it on a Mac needs the macOS 26 SDK.
- Install instructions point at 0.7.x rather than 0.6.0.

## [0.7.0] - 2026-09-18

Requires flight 0.21.0, and `Package.swift` says so — this release cannot
resolve against an earlier flight.

### Added

- **Two datasources of one store compose.** This package has documented
  `PostgresDataModule<PrimaryDataSource>` beside `PostgresDataModule<Analytics>`
  since the beginning, and it never worked: flight's composer discarded a
  generic module's type argument, so both instantiations collapsed into one
  binding and the second was never constructed. flight 0.21.0 fixed that and
  supplied the two pieces that resolve the pair:

  ```swift
  struct AppModule: FlightModule {
      static var dependencies: [any FlightModule.Type] {
          [PostgresDataModule<PrimaryDataSource>.self, PostgresDataModule<Analytics>.self]
      }
      // Which one an unqualified `@Inject var pool: PostgresDataSource` means.
      static var defaultProviders: [any FlightModule.Type] {
          [PostgresDataModule<PrimaryDataSource>.self]
      }
  }

  @Service
  final class RollupService: Sendable {
      @Inject var primary: PostgresDataSource
      @Inject(from: PostgresDataModule<Analytics>.self) var analytics: PostgresDataSource
  }
  ```

  Every repository that wants *the* pool is unchanged — a default exists so
  that adding a second one does not make every consumer say which. Modules of
  different stores (`ValkeyDataModule` beside `PostgresDataModule`) need
  neither, because their provided types already differ.

  `@Inject("analytics")` was never this. It was removed in flight 0.20.0
  because the qualifier was dropped before wiring and both properties silently
  received the same pool.

### Changed

- **Breaking.** `FlightCacheModule` takes an optional `adapter: (any Cache)?`
  and no longer discovers one by presence. It used to register an unqualified
  `(any Cache)` whose factory resolved a store registered under
  `FlightCacheModule.storeQualifier`, catching `.notRegistered` to mean
  in-memory — a runtime scan answering a question about how the application was
  composed, with the silent single-node fallback that pattern always has.
  `FlightCacheValkeyModule` now *provides* `cache: any Cache`, and the
  composition root hands it to `FlightCacheModule`; both are listed in
  `modules:`. `flight new` writes the `composedBy:` argument. Both modules
  take their configuration, so a bad URL or LRU bound fails composition rather
  than at `freeze()`, and neither can be built from its type.


- **Breaking.** `FlightPubSubValkeyModule` is now a *dependency* of
  `FlightPubSubModule` rather than a dependent, and takes its configuration:

  ```swift
  // before
  try await Flight.bootstrap(configuration: configuration, modules: [
      FlightPubSubValkeyModule.self,   // pulled in FlightPubSubModule
      AppModule.self,
  ])

  // after — the composition root builds it and hands PubSub the adapter
  try await Flight.run(
      configuration: configuration,
      modules: [FlightPubSubValkeyModule.self, FlightPubSubModule.self, AppModule.self],
      composedBy: flightComposeModules)
  ```

  `flight new` writes that `composedBy:` argument, and the generated
  composition root does the wiring; an application that already passes it
  needs no change beyond adding `FlightPubSubModule` to `modules:`.

  The module is a `struct` taking `init(configuration:)`, exposes the adapter
  as `adapter`, and no longer declares `FlightPubSubModule` in `dependencies`,
  stashes a `Container` during `configure`, or exposes `PubSubRelayService`.
  It provides an adapter; that is the whole contract. `isTypeConstructible` is
  false, so building it from its type throws
  `BootstrapError.moduleRequiresConstruction` naming the fix rather than
  producing a misconfigured module.

  Flight's `FlightPubSubModule` now takes the adapter and owns the relay,
  because it holds both halves the relay needs. Previously PubSub composed by
  *presence* — asking the container at `freeze()` whether an adapter had been
  registered — which made relay ownership this module's responsibility, and an
  adapter author who forgot it got a cluster that relayed nothing, silently.

- `ValkeyPubSubService` runs only the client pool and drains the adapter's
  subscribe loops. The relay-before-pool shutdown ordering it used to arrange
  by hand now falls out of the module graph: this module starts before PubSub,
  and `ServiceGroup` shuts down in reverse start order.

---

## [0.5.1] - 2026-09-08

Documentation only. No source change, and no version requirement change:
this package builds unmodified against flight 0.15.0.

### Fixed

- **`Docs/` had not followed the composition migration.** The DocC catalogs
  were updated when repositories stopped holding connections; the guides were
  not. `data-postgres.md` taught `@Repository(scope: .scoped)` with an
  injected `Repo`, `@Transactional`, `withPostgresScope` and
  `withPostgresTransactions`, and carried a delta table describing transaction
  coordinators that no longer exist. `data-valkey.md` had the same scoped
  shape plus `@Autowired var valkey: ValkeyConnection`.

- **Doc comments in shipped source naming removed APIs.**
  `FlightDataPostgres/Exports.swift` advertised `@Transactional` as part of
  the surface one import covers; `FlightCache/FlightCaches.swift` described
  itself as the analogue of Core's `FlightTransactions`, deleted in flight
  0.13.0; `ValkeyMulti.swift` defined itself against `@Transactional` rather
  than against the Postgres driver's `transaction`, which does exist.

- **The lean-consumer check** resolves flight 0.14.0 and swift-changeset
  0.2.0, matching the 0.5.0 release.

## [0.5.0] - 2026-09-07

Repositories hold the pool, and three defects found by building an
application on this package.

### Breaking

- **A repository holds the pool and leases a connection per operation.** The
  `.scoped` `PostgresConnection`, the `PostgresTransactionCoordinator` and the
  `.scoped` Hangar `Repo` are gone, and so is `@Transactional` (removed in
  flight 0.13.0). `pool.withRepo { repo in … }` is the bracket, and a
  transaction is Hangar's `repo.transaction { }` inside it — its extent
  visible in the code that opens it rather than inferred from an annotation
  and a scope you cannot see. Carries one silent behaviour change: per-request
  pinning gave two queries in one request an incidental consistent snapshot,
  and per-operation leasing drops that outside an explicit bracket.

- **Requires flight 0.14.0, hangar 0.5.0 and swift-changeset 0.2.0.** The
  hangar bump is what makes optimistic locking and nested changesets reachable
  at all — hangar's own cap held the whole stack at changesets 0.1.x.

### Fixed

- **`SIGTERM` during an in-flight request could close the pool underneath it.**
  `PostgresDataModule` now declares `ServiceShutdownPhase.infrastructure`, so
  the pool starts before the services that borrow from it and closes after
  them. Without that ordering the crash was
  "PostgresConnection deinitialized before being closed" and a dropped
  response — on every rolling deploy that restarted under load.
  `PostgresDataSource.shutdown()` additionally waits, bounded, for connections
  that are still checked out, and warns rather than trapping if they never
  come back: ordering cannot cover an embedder driving the pool directly.

- **A failed migration now says why.** `MigrationError` interpolated the
  underlying error, and PostgresNIO redacts its own description, so an
  operator mid-deploy was told which statement failed and then handed
  "Generic description to prevent accidental leakage of sensitive data. For
  debugging details, use `String(reflecting: error)`". The server's diagnostic
  fields — severity, SQLSTATE, message, detail, hint, position — carry no
  bound values and are what was wanted:

      underlying error: ERROR [42P01] relation "no_such_table" does not exist
        position: 13

- **`migrate` no longer warns on every run.** `Runtime.withMigrator` starts
  `client.run()` as a child task and leases from the parent immediately after,
  so PostgresNIO logged "Trying to lease connection from `PostgresClient`, but
  `PostgresClient.run()` hasn't been called yet" on essentially every
  invocation. The lease succeeds — the pool queues it — and there is no
  readiness signal to await, so the pool's own log now goes to `--verbose`
  instead of to everyone.

### Documentation

- What a streamed export costs: `repo.stream` borrows the connection for its
  whole closure, so a client reading a CSV at 20 KB/s holds one for the length
  of the download, and enough of them hold the pool. Three mitigations, in the
  order they are usually worth reaching for.

### Internal

- CI calls flight-cli's template workflow with the commit under review, so a
  breaking change here fails on its own pull request rather than in a new
  user's first ten minutes.

## [0.4.0] - 2026-08-29

A source audit of every product in `Sources/` found two critical defects, a
cluster of moderate bugs, and — behind most of them — one structural cause:
the Postgres and Valkey pools are the same machine, and every fix had been
landing on exactly one of them. This release fixes the defects and removes
the thing that kept manufacturing them.

### Fixed

- **The Postgres pool wedged permanently after a total outage, and `ping()`
  reported it alive.** `replaceBrokenConnections` returned after a single
  failed dial, on the reasoning that the next checkout or release would
  re-trigger replacement. That holds while some connections survive; once an
  outage retires all of them there are no more releases, and a checkout
  finding an empty free list never reached the branch that yields the trigger.
  The pool sat at zero established connections, answering `poolExhausted` and
  blaming the operator's `pool_size`, until the process was restarted — a
  transient outage made permanent. Meanwhile `ping()` swallowed
  `poolExhausted` unconditionally, so the wedged pod reported healthy.

  The Valkey driver had already found this and fixed it with a backoff loop;
  that fix is ported, and the ping swallow is gated on there being connections
  to be busy. Both drivers now have an outage suite, and both are wired into
  `scripts/test.sh` — they were gated on environment variables nothing set, so
  the only coverage of the wedge never ran.

- **`FlightPubSubValkey` accepted `rediss://` and never enabled TLS**, so the
  client sent `AUTH` with the password over plaintext RESP: the credential
  leaked on the very path the operator asked to encrypt. Its URL parsing was
  re-implemented smaller than the cache adapter's and wrong in the ways that
  one had already fixed — no `valkeys://`; a database path segment accepted
  and silently ignored; and `valkey://:secret@host` setting a password with no
  username, which the auth guard then read as "no credentials" and **skipped
  authentication entirely**. It now takes the same shapes and produces the
  same client configuration, timeout hardening included.

- **`migrationsTableExists` could not find its own ledger.** `to_regclass`
  parses its argument as an identifier and was handed the raw configured
  name while the DDL rendered it quoted, so any quote-requiring name — such
  as `--migrations-table Ledger` — made `status()`, `planMigrate()`,
  `rollback()` and `repair()` see an empty ledger forever, while `migrate()`
  worked.

- **`@CachePut` returning nil left the stale value in cache.** It routed
  through the same don't-cache-absence rule `@Cacheable` needs, so the put
  neither overwrote nor removed and the next read served the pre-put value —
  from an annotation whose entire promise is that it always overwrites. A nil
  result now evicts.

- **Every `InMemoryCache` hit was O(n).** The recency order was an
  `OrderedDictionary` refreshed by remove-and-reinsert; that stores keys and
  values in dense arrays, so at the default 10,000-entry bound each hit shifted
  ~10,000 elements twice, under a comment claiming O(1). It is an intrusive
  linked list now, and the perf suite measures a hit at the real bound rather
  than only fresh-key writes at a smaller one.

- **The leaked-transaction recovery path skipped session reset.** A `ROLLBACK`
  undoes the transaction, not the `SET ROLE` that came with it, and repooling
  straight after it handed that role to the next scope — the exact cross-tenant
  read `DISCARD ALL` exists to prevent, on the path most likely to be carrying
  tenant state.

- **The Postgres URL parser percent-decoded credentials twice**, silently
  corrupting any password containing an escape.

- **The Valkey cache's TTL clamp let a negative duration through** to `PX`,
  which tells the server to delete the key. The guard tested `attoseconds > 0`,
  and a negative duration carries its sign in whichever component is non-zero.

- **Derived Valkey hash keys did not escape the separator**, so a String
  primary key containing `:` collided with a composite key — one row's writes
  landing on another's hash.

- **`PostgresJobCoordinator.prune` truncated sub-second ages to zero**, which
  prunes everything older than *now*, including the firing being claimed.

- The PubSub adapter's shutdown ordering was a 50 ms sleep that evaporates
  under cancellation; it waits for the subscribe loop now. `@Transactional`'s
  async `begin()` marked the connection after `BEGIN` rather than before,
  leaving a window where a cancelled task repooled a connection mid-transaction.
  A cancelled waiting checkout spun out the rest of its timeout.

### Added

- **A pool at capacity is a queue, not a wall.** `checkout()` returning
  promptly-or-throwing is a property of the *synchronous* primitive, and it had
  been read as the policy for the whole seam — so `pool_size` was a hard
  concurrency ceiling and the (pool_size + 1)th concurrent request failed
  rather than waiting a few milliseconds for the one ahead of it.

  `checkout(waitingUpTo:)` is now part of the `DataSource` contract with a
  polling default, so every store queues; `withConnection` is defined on it;
  and `datasource.<name>.checkout_timeout_ms` (default 5s) bounds the wait.
  Both drivers override it with a native handoff. The parked-waiter machinery
  lives in `ConnectionWaiters` in core — written once rather than once per
  driver, which is how the twins drifted apart in the first place.

- **Valkey clears session state on release**, matching Postgres:
  `DISCARD`/`UNWATCH`/`SELECT` in one pipelined round trip, under the same
  `datasource.<name>.reset_on_release` key. A scope that ran `SELECT 5` through
  the raw command hatch was handing the next scope the wrong database, and a
  leaked `WATCH` made an unrelated `MULTI` abort for no visible reason.

- **Valkey's `ping()` tolerates a saturated pool**, as Postgres's already did.

- `DataSourceConformance` gained the clauses it was missing — `ping`, a release
  check that means something for pools larger than eight, concurrent-checkout
  safety, and the queueing contract — and **both drivers now actually run it**,
  which is the failure mode its own doc comment says it exists to end.

- `PendingConnections.offering(_:connection:returning:)` replaces binding the
  task-local by hand. The old call site *replaced* the offers dictionary, so a
  nested unit of work on a second datasource erased the outer offer and sent
  that scope down the non-waiting path — failing beside its own reserved
  connection.

- CLI flags for `--lock-timeout`, `--advisory-lock-key` and
  `--fail-on-unknown-applied`; `--version` reports the real version and a test
  pins it to the changelog.

### Changed

- **The PubSub wire format changed.** `WireMessage` was `Codable` with a `Data`
  payload, and `JSONEncoder` renders `Data` as base64 — so a comment claiming
  the payload "crosses as bytes rather than being base64'd" was true only of
  the outer RESP frame, while chat fan-out paid a third more wire and an
  encode/decode on every hop. Frames are now a magic + length-prefixed JSON
  header followed by the payload verbatim. **Nodes must be upgraded together**;
  a node on the old build drops the new frames rather than misreading them.

- `DefaultValue.uuid` is `DefaultValue.generatedUUID`, named for what it
  produces rather than reading as a column type.

- `PostgresJobCoordinator`'s guarantee is documented as **at most once**, and
  the trade is stated: the lease is written before the job runs and `release`
  is a no-op, so a claimant that crashes mid-job consumes the firing. That is
  deliberate — a lease with an expiry runs a long job twice — but it was not
  written down anywhere.

- `Offer.isUnclaimed` is gone. It had no callers and invited the TOCTOU its one
  real consumer correctly avoided. `SingleFlight`'s coalescing instrumentation
  (`inFlightCount`, `coalescedCount`, `waitUntilCoalescing`) is internal rather
  than public — it exists for this package's own concurrency tests, and
  `@testable` reaches it.

- Both drivers throw `DataSourceError.notStarted` instead of shadowing it with
  a driver-local enum; `PostgresDataSourceError` and `ValkeyDataSourceError` are
  gone. A portable error vocabulary is only portable if the drivers use it.

- `PostgresDataSource(name:configuration:…)` takes a
  `PostgresConnection.Configuration` you built yourself — for a unix domain
  socket, or for `verify-ca`/`verify-full` with a CA bundle. Both the URL
  parser's doc comment and the migrate CLI's error message had been
  recommending this escape hatch, which did not exist.

- `@Cacheable(namespace:)` rejects a namespace outside lowercase letters,
  digits, underscores and dots. It becomes the config key
  `cache.namespaces.<name>`, which Flight's environment overrides render as
  `FLIGHT_CACHE_NAMESPACES_…` — so a hyphen produced a variable no shell can
  set and a TTL nobody could configure. The rule was documented and enforced
  nowhere; the macro already requires a literal, so it can check it.

- The `_`-named-parameter diagnostic said to "add it to `excluding:` by its
  external label", but matching is by internal name — so following the advice
  produced a second error. It says to name the parameter.

- The PubSub integration tests republish until delivery instead of sleeping a
  few hundred milliseconds and hoping the subscription had established. For an
  at-most-once transport a retry is the semantics, not a workaround, and a
  sleep long enough to be reliable is one every run pays. The suite is faster
  and no longer has a tuning knob between slow and flaky. The channel default
  is defined once rather than in two places, where a desync makes two nodes
  silently deaf to each other.

- `FakeDatabase` honours `lockTimeout`, so the contended-lock path has tests: a
  configured timeout reaches the acquisition, `nil` passes through as "wait
  indefinitely", and a run that cannot get the lock changes nothing.

## [0.3.1] - 2026-08-25

### Changed

- Requires flight 0.2.2 and hangar 0.2.1. The waiting checkout and the cache's
  unloaded-adapter cross-check need Core's
  `Configuration.requireNoUnloadedAdapter`, added in flight 0.2.2. (Tagged at
  the time without a changelog entry; recorded here so the tags and this file
  agree.)

## [0.3.0] - 2026-08-25

### Added

- **`FlightPubSubValkey` — the first distributed PubSub adapter.**
  `DistributedPubSubAdapter` had been a seam with nothing behind it, and three
  documented features rested on it. Registering this module makes all three
  work across servers, and nothing that publishes or subscribes changes:

  ```swift
  modules: [FlightPubSubValkeyModule.self, AppModule.self]
  ```

  ```yaml
  pubsub:
    valkey:
      url: valkey://localhost:6379
  ```

  - **Channels** — a broadcast reaches sockets on other servers
  - **Presence** — the membership mode has a transport to gossip over
  - **`ClusteredPubSub`** — reachable at all, rather than a type with no adapter

  Every node publishes to and subscribes to one channel; a Flight `Message`
  names its own topic inside the frame, because a channel per topic would mean
  re-subscribing every time a socket joined a room.

  **At-most-once and fire-and-forget**, which is Valkey's pub/sub and is
  stated rather than implied. A node disconnected at the moment of a publish
  does not get that message later. Right for presence diffs, chat fan-out and
  cache invalidation, where the next update supersedes the last; wrong for
  anything that must not be lost.

  Tested against real Valkey with two independent nodes — cross-node
  delivery, byte-exact binary payloads, channel isolation, an undecodable
  frame not killing the relay, and a local subscriber seeing an echoed
  message exactly once.

### Fixed

- **Ordered shutdown in the adapter's service.** Cancelling the client pool
  and the relay together releases a subscription connection that may still be
  initializing, which trips a fatal assertion inside valkey-swift and takes
  the process down during a graceful stop. The relay now stops first. Found by
  a test crashing at teardown; the same race was in the service.

## [0.2.0] - 2026-08-25

### Added

- **`FlightSchedulerPostgres` — makes a scheduled job's `.once` mean once
  across every server.** `FlightScheduler` (flight 0.2.0) runs a job once per
  firing; on more than one server that needs something for the servers to
  contend through, and this is it:

  ```swift
  container.register((any JobCoordinator).self, scope: .singleton) { c in
      PostgresJobCoordinator(dataSource: try c.resolve(PostgresDataSource.self))
  }
  ```

  A lease row rather than an advisory lock, and the reason matters:
  `pg_try_advisory_lock` is **session**-scoped, so with pooled connections a
  claim and its release routinely land on different connections and the
  release silently fails, leaving the lock alive until the session ends.
  Holding one connection for a job's whole duration would trade a correctness
  bug for a pool-exhaustion bug. `INSERT … ON CONFLICT DO NOTHING` is atomic,
  needs no connection affinity, and the row doubles as history — the table
  answers "did last night's billing job run, and on which server".

  Contention is keyed `(job, scheduled_for)`, and the scheduler passes the
  *schedule's* instant rather than a local clock, so two servers a second
  apart still agree which firing they are competing for. Verified with eight
  concurrent claimants electing exactly one, against real Postgres.

  Requires the `Postgres` trait, like every other Postgres-facing target here.

- **DocC catalogues for eight modules**, and a CI job that builds each with
  `--warnings-as-errors`. There was no docs job at all, so the one existing
  catalogue had never been verified.

- **`scripts/test.sh`** — starts throwaway Postgres and Valkey containers,
  runs the whole suite through `CI/run-tests.sh`, tears them down. It waits
  for both servers; it used to wait only for Postgres and let Valkey race the
  Swift build.

- **A macOS build job** (advisory — see known issues).

### Changed

- **Targets are grouped into family directories** — Data, Cache, Migrate,
  Scheduler — mirrored in `Tests/`. Product names are unchanged, so consumers
  see nothing.

### Fixed

- **The integration gate never ran.** CI had neither a Postgres nor a Valkey
  service, so every driver suite skipped on every push — in a package whose
  entire purpose is its drivers. Now armed, with a gate that fails rather
  than skipping; 49 integration tests run per push.
- **Two Valkey suites flushed each other's database.** `FlightCacheValkeyTests`
  and `FlightDataValkeyTests` both call `flushdb`, in two targets, each
  `.serialized` only against itself — so one could wipe the other mid-test.
  The symptom was a key that was set, read back successfully, and then
  reported `pttl == -2`, which reads as "the TTL logic is wrong" and was
  "somebody else emptied the database". Each suite now pins its own database
  index.
- **The process-global cache seam raced across test targets.**
  `FlightCaches` is installed by module assembly and torn down by tests in
  two targets; one suite's `uninstall()` could fire while the other asserted
  `isInstalled`. It passed locally and failed under CI load. Serialized
  through a lock in `FlightCacheTesting`.
- A test located the example migrations by deleting a fixed number of path
  components from `#filePath`, which silently pointed at the wrong directory
  once targets moved. It now walks up to the directory holding `Package.swift`.

### Known issues

- **This package does not build on macOS.** `apple/swift-configuration` 1.2.0
  calls `Data.bytes` in `FileProvider.swift`, which the current Darwin SDK
  does not provide. Tracked upstream as apple/swift-configuration#178 and
  swiftlang/swift#87196, where Apple describes it as an SDK gap affecting
  their own CI — Fluent, Hummingbird and eight Vapor projects fail
  identically. Nothing here can fix it; the macOS job is advisory until
  upstream ships a fix.

## [0.1.2] - 2026-08-24

### Added

- **Bounded advisory-lock acquisition.** A migration run holds a session
  advisory lock so two deploys cannot migrate one database at once. Previously
  a run that could not get the lock waited forever, and a deploy that never
  finishes is harder to diagnose than one that fails.
  `FlightMigrator.Configuration.lockTimeout` now defaults to 30 seconds and
  throws `MigrationError.lockTimeout` with the query to find the lock holder.
  Pass `nil` for the old unbounded behavior.
- DocC catalog with three guides: getting started, migrations that cannot run
  in a transaction, and an operational runbook covering every failure mode and
  its remedy.
- CI running the full suite — including all seven integration tests — against
  a Postgres service container, on Swift 6.0 and 6.2. The job fails rather
  than skips if the database is unreachable.

### Changed

- **`createIndex(concurrently: true)` now defaults to `IF NOT EXISTS`.** A
  failed concurrent build leaves an `INVALID` index occupying the name, and
  because such a migration is not wrapped in a transaction there is nothing to
  roll it back — so a retry previously failed on `relation already exists` and
  could never make progress. Pass `ifNotExists: false` to decline. Behavior
  for non-concurrent indexes is unchanged.
- **Rollback now applies the same integrity checks as a forward migration**,
  including `failOnUnknownApplied`. Reverting is as destructive as applying,
  and a ledger holding versions this binary does not know about means the
  local set and the database disagree either way.
- `MigrationDatabase.acquireAdvisoryLock` takes a `timeout` parameter. Custom
  adapters need updating; `nil` means wait indefinitely.

### Fixed

- **The integration suite no longer deadlocks when two runs share a database.**
  Ledger names and their derived advisory-lock keys are now unique per
  process, so concurrent runs never contend. Verified by running two full
  integration suites simultaneously against one server. Fixture tables are
  still shared, so a dedicated database is still the documented requirement —
  but an accidental overlap now fails in seconds with an actionable message
  instead of blocking indefinitely.

### Documentation

- All internal design-document references removed from source, tests, and
  README.
- Missing parameter documentation on `createIndex` filled in; DocC builds
  warning-free.
