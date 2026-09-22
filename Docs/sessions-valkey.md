# Flight Sessions Valkey

The Valkey/Redis-backed store for flight's sessions: one key per session, TTL
as native expiry. Required for any deployment with more than one replica,
where the in-memory default gives each replica its own sessions and a load
balancer signs users out at random.

This page is about the *store*. What a session is, what a handler does with
one, how the cookie and the TTL behave, and the `sessions.*` keys that
govern them are flight's, in
[flight's sessions guide](https://github.com/Flight-Framework/flight/blob/main/Docs/sessions.md).
The short version: `FlightSessionsModule` (in `FlightWeb`) loads the session
named by the request's cookie, hands it to the handler as `context.session`,
and persists it after the handler returns — and it does that against an
in-memory store unless a module like this one provides a shared one.

```swift
@PostRoute("/login")
func login(_ context: RequestContext, body: LoginForm) async throws -> Response {
    let account = try await accounts.authenticate(body.email, body.password)
    let session = try context.requireSession()
    try session.set("account", account.id)      // any Codable value
    session.regenerate()                          // new id on login, against fixation
    try session.flash("notice", "Welcome back.")  // readable by the next request only
    return .seeOther("/")
}
```

Nothing in that handler changes when this module is added. That is the
point of the seam.

Built on the cache adapter's URL grammar and driver configuration
(`ValkeyCacheURL`, `ValkeyCacheSettings.clientConfiguration()`) rather than
copying them a third time; not built on [Flight Data Valkey](data-valkey.md),
for the same reasons the cache adapter is not.

| Piece | Contents |
|---|---|
| `ValkeySessionStore` | `SessionStore` over `ValkeyClient`: `GET`, `SET … PX`, `UNLINK`. Every failure throws: the middleware answers 503, and there is no breaker and no fail-open. It's also an `OwnerIndexedSessionStore`, so `revokeSessions(ownedBy:)` ("sign out everywhere") works across replicas |
| `ValkeyOneTimeTokenStore` | flight's `OneTimeTokenStore`: `SET … PX` to issue, `GETDEL` to redeem, so a reset or verification link works exactly once even when two requests race. `init(sharing:)` reuses the session store's client |
| `ValkeySessionSettings` | `sessions.valkey.*` — its own root; both timeout phases; pool sizing |
| `FlightSessionsValkeyModule` | Provides `store: any SessionStore`, which `FlightSessionsModule` takes as its store, and runs the client pool as its service in the infrastructure phase |

## Adding this module

| | |
|---|---|
| **Trait** | `Valkey` |
| **Products** | `FlightSessionsValkey` |
| **Module** | `FlightSessionsValkeyModule.self`, beside flight's `FlightSessionsModule.self` |

```swift
// Package.swift
.package(url: "https://github.com/Flight-Framework/flight.git", from: "0.32.0", traits: ["Web"]),
.package(url: "https://github.com/Flight-Framework/flight-data.git", from: "0.10.0", traits: ["Valkey"]),
…
.product(name: "FlightSessionsValkey", package: "flight-data"),
```

```swift
await Flight.run(configuration: try .load(), modules: [
    FlightWebModule<FlightTransport>.self,
    FlightSessionsModule.self,
    FlightSessionsValkeyModule.self,
    AppModule.self,
], composedBy: flightComposeModules)
```

```yaml
sessions:
  valkey:
    url: valkey://localhost:6379
```

Listing the module is the whole change. Configuring the URL *without*
listing it is refused at startup by `FlightSessionsModule`, because a
configuration nobody reads is the failure nobody notices.

## Configuration reference

All keys live under `sessions.valkey.` (env-var form
`FLIGHT_SESSIONS_VALKEY_*`), kebab-case, durations as duration strings.

| key | required | default | meaning |
|---|---|---|---|
| `url` | yes | — | `valkey://`, `redis://`, `valkeys://`, `rediss://`; auth and a database index as the cache adapter accepts them |
| `command-timeout` | no | `1s` | Bounds a command once a connection is leased |
| `unreachable-after` | no | the command timeout | How long the pool keeps trying to connect before failing fast |
| `pool-size` | no | `20` | Maximum connections |
| `min-connections` | no | `1` | Connections kept warm |

A second rather than the cache's quarter-second: a session load is on the
path of every request that carries a cookie and there is nothing to fall
back to, so a slow server costs latency here where it would cost a miss
there. A *down* server is the pool breaker's job either way, and
`unreachable-after` is what makes the first request against one fail in well
under a second rather than after the driver's 60-second default.

## Other backends

`SessionStore` is flight's seam, in the dependency-free `FlightSessions`
product: three methods over opaque bytes, every one of them throwing.

| Store | Where | For |
|---|---|---|
| `InMemorySessionStore` | `FlightSessions`, the default | One replica, development, tests. Bounded by `sessions.memory.max-entries`; lost on restart |
| `ValkeySessionStore` | this module | More than one replica |
| `RecordingSessionStore` | `FlightSessionsTesting` | Asserting what a request did to its session |
| yours | a module of your own | Anything else with a TTL |

A store of your own is a conformance and a module that provides it as
`store: any SessionStore`; `FlightSessionsModule` takes it by type, exactly
as it takes this module's. The guide linked above has the worked example.
`ValkeySessionStore.swift` here is a complete one in eighty lines and is
the shape to copy: native expiry if the backend has it, `expiresAt` read
from the record on load if it does not, and no fail-open.

## Signing out everywhere

Each signed-in session's id is also kept in a set per owner,
`flight-session-owner:<subject>`. `SessionRuntime.revokeSessions(ownedBy:keeping:)`
reads that set. Before ending a session, it rereads the session's own record
and checks the owner is still the one being revoked. A stale entry in the
set therefore can never end someone else's session, and it's pruned on the
way. The set expires no sooner than its newest session. `PEXPIRE NX` gives
it an expiry the first time, and `PEXPIRE GT` only ever extends it, because
`GT` alone treats a key with no expiry as infinite and would never set one.

## One-time links

```swift
let tokens = OneTimeTokens(store: ValkeyOneTimeTokenStore(sharing: sessionStore))
```

Keys are `flight-token:` plus the digest flight's `OneTimeTokens` computes,
never the token itself. Redeeming is one `GETDEL`, which needs Valkey or
Redis 6.2 or later.

## Keys, and sharing one Valkey

Keys are `flight-session:` + the session id's cookie value. The prefix is
fixed. Two applications on the same server and database index share a key
space, though session ids are 256-bit random values, so nothing collides;
what they share is the ability to read each other's sessions if one of them
is handed the other's cookie. Separate them with the URL's database index or
with separate servers, the way the cache adapter's guide says.

## Build status

`./scripts/test.sh` runs everything, integration tests included, against
throwaway servers it starts and cleans up. The integration suite runs
against both a real Valkey 8 and a real Redis 7: round-trips under the
documented key shape, native TTL expiry, overwrite restarting the TTL, a
non-positive TTL deleting rather than storing, idempotent delete, and the
dead-server path throwing in bounded time rather than reading as an empty
session.
