# Alula Rate Limit Valkey

The Valkey/Redis-backed store for alula's rate limiter, so a quota is
enforced once across every replica rather than once per replica.

This page is about the *store*. What a quota is, how a key is chosen, how
the `RateLimiting` middleware answers a refusal and why the algorithm is
GCRA are alula's, in
[alula's rate limiting guide](https://github.com/Alula-Framework/alula/blob/main/Docs/rate-limiting.md).
The short version: `AlulaRateLimitModule` provides a `RateLimiter`,
anything that limits something calls `consume`, and this module changes
only where the state lives.

```swift
let decision = try await limits.consume("login:\(email)", quota: .perMinute(5))
guard decision.isAllowed else { throw SignInError.tooManyAttempts }
```

Nothing in that changes when this module is added. That is the point of the
seam.

| Piece | Contents |
|---|---|
| `ValkeyRateLimitStore` | `RateLimitStore` as a single `EVAL`: GCRA in Lua, on the server's clock, with a TTL so idle keys are reclaimed |
| `ValkeyRateLimitSettings` | `rate-limit.valkey.*` — its own root; both timeout phases; pool sizing; the key prefix |
| `AlulaRateLimitValkeyModule` | Provides `store: any RateLimitStore`, and runs the client pool as its service in the infrastructure phase |

## Adding this module

| | |
|---|---|
| **Trait** | `Valkey` |
| **Products** | `AlulaRateLimitValkey` |
| **Module** | `AlulaRateLimitValkeyModule.self`, beside alula's `AlulaRateLimitModule.self` |

```swift
// Package.swift
.package(url: "https://github.com/Alula-Framework/alula.git", from: "0.47.0", traits: ["Web"]),
.package(url: "https://github.com/Alula-Framework/alula-data.git", from: "0.17.0", traits: ["Valkey"]),
…
.product(name: "AlulaRateLimitValkey", package: "alula-data"),
```

```swift
await Alula.run(configuration: try .load(), modules: [
    AlulaWebModule<AlulaTransport>.self,
    AlulaRateLimitModule.self,
    AlulaRateLimitValkeyModule.self,
    AppModule.self,
], composedBy: alulaComposeModules)
```

```yaml
rate-limit:
  valkey:
    url: valkey://localhost:6379
```

Listing the module is the whole change. Configuring the URL *without*
listing it is refused at startup by `AlulaRateLimitModule`, because a
limiter that enforces per replica while the configuration says otherwise is
a limiter quietly granting four times the quota on four pods.

## Why one EVAL

GCRA's state is a single timestamp per key, so the entire decision is a
read, a comparison and a write of one value. A Lua script performs all three
atomically on the server in one round trip.

That matters more than it sounds. The alternative shapes all have a window
in which two replicas both observe an under-quota key and both admit a call:
a client-side read-then-write has it by construction, and a `WATCH`/`MULTI`
retry loop closes it only by retrying under contention, which is precisely
when a limiter is busiest. A counter with `INCR` avoids the race but gives
you a fixed window, which admits twice the quota across a boundary.

The script reads `TIME` from the server rather than taking a timestamp from
the client, because the server's clock is the only one every replica shares.
It sets a TTL equal to the time until the key is back at full, so idle keys
are reclaimed by the server and nothing needs a sweeper.

It is deliberately the same arithmetic, in the same order, as `GCRA.decide`
in flight, in whole microseconds on both sides. That unit is load-bearing:
Lua numbers are doubles, and subtracting timestamps near 1.8e15 in
fractional seconds leaves enough error to report one permit fewer than are
free. The integration suite runs the same scenarios against this store and
alula's in-memory one and compares the decisions, which is exactly how the
first version of the script was caught doing that.

## Failure is reported, not decided

A failure throws. This store has no fail-open behaviour of its own, unlike
`ValkeyCache`, and that is not an oversight: what an unreachable limiter
means depends on what is being limited. alula's `RateLimiting` middleware
serves the request and logs loudly that it is not enforcing; a login
throttle may well refuse instead. The store's job is to report the fact, and
to be quick about it, which is what the pool's circuit breaker handles.

## Configuration reference

All keys under `rate-limit.valkey.` (env-var form
`ALULA_RATE_LIMIT_VALKEY_*`), kebab-case, durations as duration strings.

| key | required | default | meaning |
|---|---|---|---|
| `url` | yes | — | `valkey://`, `redis://`, `valkeys://`, `rediss://`; auth and a database index as the cache adapter accepts them |
| `command-timeout` | no | `100ms` | Bounds a command once a connection is leased |
| `unreachable-after` | no | the command timeout | How long the pool keeps trying to connect before failing fast |
| `pool-size` | no | `20` | Maximum connections |
| `min-connections` | no | `1` | Connections kept warm |
| `key-prefix` | no | `alula-rate-limit:` | What every key is stored under |

A hundred milliseconds by default, shorter than the session store's second.
A limiter sits in front of work the caller wants done, so every millisecond
it spends is latency added to a request that was going to be allowed anyway.
When it cannot answer in time the middleware fails open, which is
survivable; making the caller wait a second first is not.

`key-prefix` exists here where the cache's prefix is fixed, because rate
limit keys are strings the application chooses rather than structured
namespaces. Two applications sharing a server and a database would otherwise
limit each other's users. Separate prefixes, separate database indexes, or
separate servers all work.

## Build status

`./scripts/test.sh` runs everything, integration tests included, against
throwaway servers it starts and cleans up. The integration suite runs
against both a real Valkey 8 and a real Redis 7: spend-and-recover, the
differential check against alula's in-memory store, a retry storm not
extending its own wait, the key shape and its TTL, key independence, a
zero-cost probe, an unsatisfiable cost, and a dead server throwing in
bounded time rather than quietly allowing.
