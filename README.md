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
| `traits: ["Postgres"]` | + `AlulaDataPostgres`, `AlulaMigrate`, `AlulaMigrateCLI` | + PostgresNIO, Hangar, ArgumentParser |
| `traits: ["Valkey"]` | + `AlulaCacheValkey`, `AlulaDataValkey`, `AlulaPubSubValkey`, `AlulaSessionsValkey`, `AlulaRateLimitValkey` | + valkey-swift, NIOSSL |

Both are opt-in — name a driver to get it:

```swift
// In-memory cache and the data protocols. No driver resolved at all.
.package(url: "https://github.com/Alula-Framework/alula-data.git", from: "0.7.0")

// With PostgreSQL.
.package(url: "https://github.com/Alula-Framework/alula-data.git",
         from: "0.7.0", traits: ["Postgres"])
```

**Swift 6.3 or later is required**: through 6.2.x, SwiftPM did not resolve a
non-default trait's gated dependencies through a versioned dependency
([#9286](https://github.com/swiftlang/swift-package-manager/issues/9286)).

Taking a gated product without its trait is a compile error naming the trait
you need.

## Products

| Product | What it is |
| --- | --- |
| `AlulaCache` | Cache protocol, in-memory implementation, single-alula coalescing, `@Cacheable`. |
| `AlulaDataCore` | `DataSource`, per-operation connection leasing and queueing, changeset integration. Deliberately **no** shared transaction abstraction — transactions belong to the layer above a driver (Hangar's `repo.transaction { }` for Postgres), on top of the one thing that is genuinely shared. |
| `AlulaMigrateCore` | Migration discovery and ordering, plus the build tool plugin — no driver required. |
| `AlulaDataPostgres` | PostgreSQL data source over PostgresNIO, with Hangar for queries. |
| `AlulaPubSubValkey` | Carries Alula's PubSub between nodes over Valkey, which makes Channels broadcast, Presence membership, and `ClusteredPubSub` work across servers. Requires the `Valkey` trait. |
| `AlulaSchedulerPostgres` | Makes an Alula scheduled job's `.once` mean once across every server, using a Postgres lease row. Requires the `Postgres` trait. |
| `AlulaMigrate` / `AlulaMigrateCLI` | Migration runner and its command line interface. |
| `AlulaCacheValkey` | Distributed cache over Valkey. |
| `AlulaSessionsValkey` | Sessions shared across replicas over Valkey: the store behind alula's `AlulaSessionsModule`. Requires the `Valkey` trait. |
| `AlulaRateLimitValkey` | A rate limit enforced once across every replica rather than once per replica: GCRA as a single `EVAL`. Requires the `Valkey` trait. |
| `AlulaDataValkey` | Valkey data source. |
| `*Testing` | Conformance suites and fakes — including `DataSourceConformance`, the contract every data source must satisfy. |

Per-product documentation lives in [Docs/](Docs/). How to test an application
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
| alula | **0.21.2 or later** |
| Deployment target | macOS 15+, or Linux |
| Building on macOS | the macOS 26 SDK (Xcode 26) |

Strict concurrency throughout.

The last two rows are different requirements. What you build runs on macOS 15;
*compiling* it on a Mac needs the newer SDK, because alula's configuration
layer resolves to FoundationEssentials only where the SDK provides it. And
alula 0.21.2 is the floor rather than a suggestion: every earlier release
calls a macOS 26+ API at a macOS 15 deployment target, so a Mac could not build
this package against them at any SDK. Verified on `macos-26`, which is what the
CI job runs.

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
