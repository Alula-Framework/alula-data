# ``FlightSessionsValkey``

Sessions shared across replicas, over Valkey or Redis.

## Overview

``ValkeySessionStore`` implements flight's `SessionStore` with one key per
session under the `flight-session:` prefix and the TTL as native expiry, so
the server drops expired sessions itself. ``FlightSessionsValkeyModule``
provides it as `store: any SessionStore`, which `FlightSessionsModule` takes
in composition — listing the module is the whole change from the in-memory
default:

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

What a session is and what a handler does with one is flight's story —
`Session`, `SessionStore` and the in-memory default live in its
`FlightSessions` product, and `context.session` in `FlightWeb`. This module
only changes where the bytes go.

Every failure throws, and the middleware answers 503. There is no breaker
and no fail-open here, unlike the cache adapter: a request can do without
its cache, and it cannot do without its session.

## Topics

### The store

- ``ValkeySessionStore``
- ``FlightSessionsValkeyModule``

### Configuration

- ``ValkeySessionSettings``
- ``ValkeySessionConfigKey``
- ``ValkeySessionConfigurationError``
