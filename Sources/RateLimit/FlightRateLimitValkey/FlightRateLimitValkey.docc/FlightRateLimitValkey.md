# ``FlightRateLimitValkey``

A rate limit enforced once across every replica, rather than once per
replica.

## Overview

``ValkeyRateLimitStore`` implements flight's `RateLimitStore` as a single
`EVAL`. GCRA's state is one timestamp per key, so deciding and recording is
a read, a comparison and a write of one value, and a Lua script does all
three atomically on the server in one round trip. No lock, no
`WATCH`/`MULTI` retry, and no window in which two replicas both see an
under-quota key and both admit a call.

``FlightRateLimitValkeyModule`` provides it as `store: any RateLimitStore`,
which `FlightRateLimitModule` takes in composition. Listing the module is
the whole change:

```swift
await Flight.run(configuration: try .load(), modules: [
    FlightRateLimitModule.self,
    FlightRateLimitValkeyModule.self,
    AppModule.self,
], composedBy: flightComposeModules)
```

```yaml
rate-limit:
  valkey:
    url: valkey://localhost:6379
```

Nothing here fails open. A failure throws and the caller decides what that
means: `RateLimiting` serves the request and says loudly that it is not
enforcing, while a login throttle may prefer to refuse. This adapter's job
is to fail *fast* when the server is unreachable, which the pool's circuit
breaker handles, not to have an opinion about what failing means.

## Topics

### The store

- ``ValkeyRateLimitStore``
- ``FlightRateLimitValkeyModule``

### Configuration

- ``ValkeyRateLimitSettings``
- ``ValkeyRateLimitConfigKey``
- ``ValkeyRateLimitConfigurationError``
