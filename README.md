# Alula Data

Persistence and caching for [Alula](https://github.com/Alula-Framework/alula):
the data-source and cache protocols, an in-memory cache, migrations, and the
PostgreSQL and Valkey drivers.

The abstractions and the drivers live together because they break together —
a change to the `DataSource` contract breaks every adapter at once, and one
package makes that a compile error in CI rather than a discovery weeks later
in whichever adapter nobody rebuilt.

## Traits

The drivers are heavy and mutually irrelevant: an application using the
in-memory cache should never resolve a Postgres driver. SwiftPM does not prune
a package's dependencies by which product you use, but it does prune
dependencies no enabled trait reaches — so the drivers sit behind traits.

| Configuration | Products | Resolves |
| --- | --- | --- |
| (none) | `AlulaCache`, `AlulaCacheTesting`, `AlulaDataCore`, `AlulaDataTesting`, `AlulaMigrateCore` | 10 packages, no driver |
| `traits: ["Postgres"]` | + `AlulaDataPostgres`, `AlulaSchedulerPostgres`, `AlulaQueuePostgres`, `AlulaPubSubPostgres`, `AlulaMigrate`, `AlulaMigrateCLI` | + PostgresNIO, Hangar, ArgumentParser |
| `traits: ["Valkey"]` | + `AlulaCacheValkey`, `AlulaDataValkey`, `AlulaPubSubValkey`, `AlulaSessionsValkey`, `AlulaRateLimitValkey` | + valkey-swift, NIOSSL |

Both are opt-in — name a driver to get it:

```swift
// In-memory cache and the data protocols. No driver resolved at all.
.package(url: "https://github.com/Alula-Framework/alula-data.git", from: "0.25.0")

// With PostgreSQL.
.package(url: "https://github.com/Alula-Framework/alula-data.git",
         from: "0.25.0", traits: ["Postgres"])
```

**Swift 6.3 or later is required**: through 6.2.x, SwiftPM did not resolve a
non-default trait's gated dependencies through a versioned dependency
([#9286](https://github.com/swiftlang/swift-package-manager/issues/9286)).

Taking a gated product without its trait is a compile error naming the trait
you need.

## Products

| Product | What it is |
| --- | --- |
| `AlulaCache` | Cache protocol, in-memory implementation, single-flight coalescing, `@Cacheable`. |
| `AlulaDataCore` | `DataSource`, per-operation connection leasing and queueing, changeset integration. Deliberately **no** shared transaction abstraction — transactions belong to the layer above a driver (Hangar's `repo.transaction { }` for Postgres), on top of the one thing that is genuinely shared. |
| `AlulaMigrateCore` | Migration discovery and ordering, plus the build tool plugin — no driver required. |
| `AlulaDataPostgres` | PostgreSQL data source over PostgresNIO, with Hangar for queries. |
| `AlulaPubSubValkey` | Carries Alula's PubSub between nodes over Valkey, which makes Channels broadcast, Presence membership, and `ClusteredPubSub` work across servers. Requires the `Valkey` trait. |
| `AlulaSchedulerPostgres` | Makes an Alula scheduled job's `.once` mean once across every server, using a Postgres lease row. Requires the `Postgres` trait. |
| `AlulaQueuePostgres` | A durable store for Alula's job queue: claims with `FOR UPDATE SKIP LOCKED`, can enqueue inside your own transaction, and an `Outbox` that publishes to PubSub only on commit. Requires the `Postgres` trait. |
| `AlulaPubSubPostgres` | PubSub between nodes over Postgres `LISTEN`/`NOTIFY` — clustering without Valkey (payloads ≤ 8000 bytes). Requires the `Postgres` trait. |
| `AlulaMigrate` / `AlulaMigrateCLI` | Migration runner and its command line interface. |
| `AlulaCacheValkey` | Distributed cache over Valkey. |
| `AlulaSessionsValkey` | Sessions shared across replicas over Valkey: the store behind alula's `AlulaSessionsModule`. Requires the `Valkey` trait. |
| `AlulaRateLimitValkey` | A rate limit enforced once across every replica rather than once per replica: GCRA as a single `EVAL`. Requires the `Valkey` trait. |
| `AlulaDataValkey` | Valkey data source. |
| `AlulaDataTesting` / `AlulaCacheTesting` | Conformance suites and fakes — including `DataSourceConformance`, the contract every data source must satisfy, and `RecordingCache`. Not part of alula's `AlulaTesting` umbrella, which re-exports only alula's own testing modules: list these in a test target beside it. |

Per-product documentation lives in [Docs/](Docs/).
[Docs/operations.md](Docs/operations.md) is the page for running it in
production: pool behaviour under load and during an outage, what a
transaction guarantees about its connection, what PubSub and the job queue
can lose, and migrations in a deploy. How to test an application
built on Alula — including the cache and data-source fakes this package
ships — is covered in
[alula's testing guide](https://github.com/Alula-Framework/alula/blob/main/Docs/testing.md).

## Building this repository

A root build compiles every target regardless of traits, so it needs them all:

```
swift build --enable-all-traits
swift test  --enable-all-traits
```

A plain `swift build` here fails by design. `CI/check-lean-consumer.sh`
verifies the pruning the only way that proves anything — by building a real
consumer and asserting no gated dependency reached it.

## Requirements

| | Requirement |
| --- | --- |
| Swift | 6.3+ — see [Traits](#traits) for why |
| alula | **0.61.0 or later** (Package.swift's floor) |
| Hangar | 0.14.0 or later (resolved only with the `Postgres` trait) |
| Deployment target | macOS 15+, or Linux |
| Building on macOS | the macOS 26 SDK (Xcode 26) |

Strict concurrency throughout.

The last two rows are different requirements. What you build runs on macOS 15;
*compiling* it on a Mac needs the newer SDK, because alula's configuration
layer resolves to FoundationEssentials only where the SDK provides it. alula
releases before 0.21.2 also call a macOS 26+ API at a macOS 15 deployment
target, so a Mac could not build against them at any SDK; the 0.61.0 floor is
well past that. Verified on `macos-26`, which is what the CI job runs.

## Diagnostics

Errors this package reports at build time or at startup carry a stable code,
and each code has a page in [Diagnostics/](Diagnostics/) saying what it means,
why it is rejected, and how to fix it:

| Code | Reported by | Page |
| --- | --- | --- |
| `ALD-CACHE-1001`–`1005` | the `@Cacheable`, `@CachePut` and `@CacheEvict` macros, at compile time | [1001](Diagnostics/ALD-CACHE-1001.md), [1002](Diagnostics/ALD-CACHE-1002.md), [1003](Diagnostics/ALD-CACHE-1003.md), [1004](Diagnostics/ALD-CACHE-1004.md), [1005](Diagnostics/ALD-CACHE-1005.md) |
| `ALD-MIGRATE-2001`–`2003` | `AlulaMigratePlugin`, when it builds the migrations target | [2001](Diagnostics/ALD-MIGRATE-2001.md), [2002](Diagnostics/ALD-MIGRATE-2002.md), [2003](Diagnostics/ALD-MIGRATE-2003.md) |
| `ALD-DATA-1001` | a data source that cannot connect at startup | [1001](Diagnostics/ALD-DATA-1001.md) |

A migration diagnostic is printed as `path:1:1: error: [ALD-MIGRATE-2001] …`
followed by a `docs:` line with the page's URL, so SwiftPM attaches it to the
file. `alula explain <CODE>` from
[alula-cli](https://github.com/Alula-Framework/alula-cli) prints the link to
an alula-data code's page; the page itself lives here, not in alula.

## Running the tests

```bash
./scripts/test.sh                 # everything, integration tests included
./scripts/test.sh --filter Foo    # arguments pass through to swift test
```

It starts throwaway servers, runs the suite, and removes them — including the
disposable Postgres and Valkey the outage suites are allowed to stop and
restart mid-test, which are separate from the shared ones so that killing a
server does not take the rest of the suite with it.

`swift test --enable-all-traits` on its own runs everything that needs no
server. The integration suites skip without one, and a skipped suite is not a
passing one — what this package proves against real infrastructure is most of
what it is for, which is also why the outage suites are wired into the script
rather than gated on a variable nobody sets.

`ALULA_KEEP_SERVERS=1` leaves the containers up between runs.

## License

MIT. See [LICENSE](LICENSE).
