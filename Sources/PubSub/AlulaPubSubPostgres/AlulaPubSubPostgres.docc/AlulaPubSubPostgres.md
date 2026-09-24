# ``AlulaPubSubPostgres``

PubSub between nodes over Postgres `LISTEN`/`NOTIFY`: Channels, Presence and
`ClusteredPubSub` across replicas, with no Valkey.

## Overview

List ``AlulaPubSubPostgresModule`` beside the Postgres datasource, and
`AlulaPubSubModule` takes its adapter:

```swift
await Alula.run(configuration: try .load(), modules: [
    PostgresDataModule<PrimaryDataSource>.self,
    AlulaPubSubPostgresModule.self,
    AlulaPubSubModule.self,
    AppModule.self,
], composedBy: alulaComposeModules)
```

Delivery is at most once, and every node receives every message. A NOTIFY
payload is limited to 8000 bytes by Postgres, so a larger message is refused
at broadcast with its size (``PostgresPubSubError``). It is still delivered on
the node that sent it.

## Topics

- ``AlulaPubSubPostgresModule``
- ``PostgresPubSubAdapter``
- ``PostgresPubSubError``
- ``PostgresPubSubConfigurationError``
