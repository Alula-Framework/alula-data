# PubSub over Postgres

`AlulaPubSubPostgres` carries PubSub messages between nodes with Postgres's
own `LISTEN`/`NOTIFY`. A deployment that already runs Postgres can then
cluster Channels, Presence and `ClusteredPubSub` without adding Valkey.

| | |
|---|---|
| **Trait** | `Postgres` |
| **Product** | `AlulaPubSubPostgres` |
| **Module** | `AlulaPubSubPostgresModule.self`, beside a `PostgresDataModule` |

```yaml
pubsub:
  postgres:
    channel: alula_pubsub     # 1–63 letters, digits, underscores
    retry-delay-ms: 1000      # between reconnects of the listener
```

## Postgres or Valkey

| | Postgres | Valkey |
|---|---|---|
| Extra infrastructure | none | a Valkey server |
| Message size | **≤ 8000 bytes** encoded | effectively unlimited |
| Throughput | fine for chat, presence and invalidation traffic | built for high fan-out |
| Delivery | at most once, every node receives everything | same |

Take Postgres until the size limit or the volume says otherwise. The payload
is JSON with the body base64-encoded, so the usable size is about 5.9 KB of
raw payload. A larger broadcast throws `payloadTooLarge` naming the topic and
the size, and the message is still delivered to this node's subscribers.
For large payloads, write a row and notify its id.

## How it runs

- **Broadcasts** are `SELECT pg_notify(channel, payload)` on a pooled
  connection. A transaction that is open when you publish does not delay the
  notification, because it runs on its own connection.
- **Listening** holds one connection outside the pool, since `LISTEN` belongs
  to a session, and keeps it for the life of the process. When it drops, the
  listener logs once, reconnects after `retry-delay-ms`, and logs the
  recovery. Messages sent while it was away are missed, as with any
  at-most-once transport.

## Publishing on commit

A publish inside a transaction goes out at once, whether or not the
transaction later commits. To publish only what commits, use the outbox in
AlulaQueuePostgres. It works with either bus:

```swift
try await repo.transaction { tx in
    let order = try await tx.insert(order)
    try await outbox.publish(OrderPlaced(id: order.id), to: "orders", in: tx)
}
```

The message is written as a job in the same transaction and published by
the queue worker after the commit. List `AlulaOutboxModule` (with
`AlulaQueuePostgresModule` and `AlulaQueueWorkerModule`) and inject
`Outbox`. Delivery into the bus is at least once. Each message carries an
`outbox-id` in its metadata, for subscribers that must not act twice.
