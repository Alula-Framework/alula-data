import AlulaCore
import AlulaDataPostgres
import AlulaPubSub
import AlulaQueue
import Foundation
import Hangar

/// Publishes a message if, and only if, the transaction it was written in
/// commits.
///
/// ```swift
/// try await pool.withRepo { repo in
///     try await repo.transaction { tx in
///         let order = try await tx.insert(Order(…))
///         try await outbox.publish(OrderPlaced(id: order.id), to: "orders", in: tx)
///     }
/// }
/// ```
///
/// Publishing straight to a `PubSub` from inside a transaction gets one of
/// two things wrong. Publish before the commit and a rollback leaves
/// subscribers acting on an order that does not exist. Publish after it and
/// a crash in between loses the message while the order stays. The outbox
/// writes the message as a job row in the same transaction, so it exists
/// exactly when the order does, and the queue worker publishes it to the
/// bus once it can see it.
///
/// What it guarantees, and what it leaves to the bus:
///
/// - **Committed means handed to the bus.** A committed message is passed
///   to `PubSub.publish` by whichever replica's worker claims it, after a
///   crash or a restart too. A rolled-back one never is. The outbox's
///   guarantee ends there: it is durable *invocation* of the bus after the
///   commit, not durable delivery to subscribers.
/// - **At least once into the bus.** A worker that dies after publishing
///   and before recording it leaves the job to be claimed again once its
///   lease expires, so a subscriber can see a message twice. Each message
///   carries a unique `outbox-id` in its metadata for subscribers that must
///   not act twice. The repeats are bounded by the job's attempt limit (the
///   queue's default, ten): a job claimed back after its last attempt is
///   discarded unpublished.
/// - **Not in order.** Workers run jobs concurrently, so two messages
///   written in sequence can be published in either order.
/// - **The bus is still the bus.** Once published, delivery is the
///   `PubSub`'s: at most once, to the subscribers present at the time.
///   `publish` does not throw, so a distributed adapter that fails to
///   forward a message logs it and moves on, and the outbox job still
///   completes. A consumer that needs every event durably — billing, an
///   external system — should consume the queue itself, not the bus.
///   The outbox fixes the gap between the database and the bus, not the
///   bus itself.
///
/// Needs the Postgres job store, `AlulaQueuePostgresModule`, and a queue
/// worker serving the `outbox` queue to be running somewhere — until one
/// does, committed messages wait in the table. List ``AlulaOutboxModule``.
/// See Docs/operations.md.
public struct Outbox: Sendable {
    /// The job an outbox message travels as.
    public struct Envelope: QueuedJob, Equatable {
        /// `alula.outbox`: the job kind the outbox handler is registered for.
        public static var kind: String { "alula.outbox" }
        /// `outbox`: the queue the messages run on.
        public static var queue: String { "outbox" }

        /// The message's `outbox-id`, also in ``metadata``.
        public var id: UUID
        /// The PubSub topic to publish to.
        public var topic: String
        /// The message body, as given to ``Outbox/publish(_:in:)``.
        public var payload: Data
        /// The message's metadata, including `outbox-id`.
        public var metadata: [String: String]
    }

    private let queue: JobQueue
    private let store: PostgresQueueStore
    private let bus: any PubSub
    private let encoder: JSONEncoder

    /// - Parameters:
    ///   - queue: The application's job queue.
    ///   - store: The Postgres store behind it, which is what writes into
    ///     the caller's transaction.
    ///   - bus: Where messages are published once committed.
    public init(queue: JobQueue, store: PostgresQueueStore, bus: any PubSub) {
        self.queue = queue
        self.store = store
        self.bus = bus
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    /// Writes `message` into the transaction `repo` belongs to.
    ///
    /// Nothing is published here. The message is a job row written through
    /// `repo`, so it is published only if that transaction commits, and only
    /// once a worker claims it. Pass the transaction's `tx`: a repo outside
    /// the transaction writes a message that survives its rollback.
    ///
    /// - Returns: The message's `outbox-id`, which subscribers see in its
    ///   metadata.
    @discardableResult
    public func publish(_ message: Message, in repo: Repo) async throws -> UUID {
        let id = UUID()
        var metadata = message.metadata
        metadata["outbox-id"] = id.uuidString
        let envelope = Envelope(
            id: id, topic: message.topic, payload: message.payload, metadata: metadata)
        _ = try await store.enqueue(try queue.prepare(envelope), in: repo)
        return id
    }

    /// Writes `value`, JSON-encoded with ISO 8601 dates, to `topic`.
    @discardableResult
    public func publish(_ value: some Encodable, to topic: String, in repo: Repo) async throws
        -> UUID
    {
        try await publish(Message(topic: topic, payload: try encoder.encode(value)), in: repo)
    }

    /// What the queue worker runs for each committed message.
    ///
    /// Calls `PubSub.publish`, which does not throw, so the job always
    /// completes: a broadcast the bus fails to send is logged by the bus and
    /// not retried.
    public var handler: QueueHandler {
        let bus = bus
        return .handle(Envelope.self) { envelope, _ in
            await bus.publish(
                Message(
                    topic: envelope.topic, payload: envelope.payload,
                    metadata: envelope.metadata))
        }
    }
}

/// Provides ``Outbox`` and registers the handler that publishes its
/// messages.
///
/// ```swift
/// modules: [
///     PostgresDataModule<PrimaryDataSource>.self,
///     AlulaPubSubModule.self,
///     AlulaQueuePostgresModule.self,
///     AlulaQueueWorkerModule.self,
///     AlulaOutboxModule.self,
///     AppModule.self,           // injects `Outbox`
/// ]
/// ```
///
/// Its messages run on the `outbox` queue, which a worker serves once a
/// handler for it is registered, as this module's is.
public struct AlulaOutboxModule: AlulaModule {
    /// The Postgres job store, the job queue, and PubSub.
    public static var dependencies: [any AlulaModule.Type] {
        [AlulaQueuePostgresModule.self, AlulaQueueModule.self, AlulaPubSubModule.self]
    }

    /// The outbox a component injects to publish on commit.
    public let outbox: Outbox
    /// The publishing handler, for the queue worker.
    public let queueHandlers: [QueueHandler]

    /// Called by the composition root with the modules' values.
    ///
    /// - Parameters:
    ///   - jobQueue: The application's job queue.
    ///   - postgresQueueStore: The store `AlulaQueuePostgresModule` provides.
    ///   - bus: The application's PubSub.
    public init(jobQueue: JobQueue, postgresQueueStore: PostgresQueueStore, bus: any PubSub) {
        let outbox = Outbox(queue: jobQueue, store: postgresQueueStore, bus: bus)
        self.outbox = outbox
        self.queueHandlers = [outbox.handler]
    }

    /// Traps. Build the module with ``init(jobQueue:postgresQueueStore:bus:)``,
    /// which `alulaComposeModules` does.
    public init() {
        preconditionFailure(
            "AlulaOutboxModule takes the job queue, the Postgres job store and the bus in "
                + "init(jobQueue:postgresQueueStore:bus:). Pass `composedBy: alulaComposeModules` "
                + "to Alula.run.")
    }
}
