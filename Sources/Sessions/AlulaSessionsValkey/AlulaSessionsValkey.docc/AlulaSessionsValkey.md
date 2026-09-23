# ``AlulaSessionsValkey``

Sessions shared across replicas, over Valkey or Redis.

## Overview

``ValkeySessionStore`` implements alula's `SessionStore` with one key per
session under the `alula-session:` prefix and the TTL as native expiry, so
the server drops expired sessions itself. ``AlulaSessionsValkeyModule``
provides it as `store: any SessionStore`, which `AlulaSessionsModule` takes
in composition — listing the module is the whole change from the in-memory
default:

```swift
await Alula.run(configuration: try .load(), modules: [
    AlulaWebModule<AlulaTransport>.self,
    AlulaSessionsModule.self,
    AlulaSessionsValkeyModule.self,
    AppModule.self,
], composedBy: alulaComposeModules)
```

```yaml
sessions:
  valkey:
    url: valkey://localhost:6379
```

What a session is and what a handler does with one is alula's story —
`Session`, `SessionStore` and the in-memory default live in its
`AlulaSessions` product, and `context.session` in `AlulaWeb`. This module
only changes where the bytes go.

Every failure throws, and the middleware answers 503. There is no breaker
and no fail-open here, unlike the cache adapter: a request can do without
its cache, and it cannot do without its session.

## Topics

### The store

- ``ValkeySessionStore``
- ``AlulaSessionsValkeyModule``

### Configuration

- ``ValkeySessionSettings``
- ``ValkeySessionConfigKey``
- ``ValkeySessionConfigurationError``
