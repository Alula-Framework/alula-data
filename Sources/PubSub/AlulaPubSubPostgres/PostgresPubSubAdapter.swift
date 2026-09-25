import AlulaCore
import AlulaDataPostgres
import AlulaPubSub
import Foundation
import Logging
import Metrics
import PostgresNIO
import ServiceLifecycle
import Synchronization

/// Carries PubSub messages between nodes over Postgres `LISTEN`/`NOTIFY`, so
/// a deployment that already has Postgres can run Channels, Presence and
/// `ClusteredPubSub` across replicas without adding Valkey.
///
/// ```swift
/// await Alula.run(configuration: try .load(), modules: [
///     PostgresDataModule<PrimaryDataSource>.self,
///     AlulaPubSubPostgresModule.self,
///     AlulaPubSubModule.self,
///     AppModule.self,
/// ], composedBy: alulaComposeModules)
/// ```
///
/// ## What it promises, and the limit
///
/// At most once, like every PubSub adapter: a node that is not listening
/// when a message is sent does not get it later. It is a firehose on one
/// channel (`pubsub.postgres.channel`, default `alula_pubsub`), and every
/// node receives every message.
///
/// **A NOTIFY payload is at most 8000 bytes**, a limit in Postgres itself.
/// A message whose encoding is larger is refused when it is broadcast, with
/// the size in the error. `ClusteredPubSub` logs it and still delivers the
/// message on this node. Channels' presence diffs and chat messages fit with
/// room to spare, but a large document does not, and wants a table plus a
/// notification naming its row.
///
/// Broadcasts go through the pool (`SELECT pg_notify`). Listening holds one
/// dedicated connection, outside the pool, and reconnects on its own after
/// `pubsub.postgres.retry-delay-ms` (default 1000) when that connection is
/// lost.
public final class PostgresPubSubAdapter: DistributedPubSubAdapter {
    /// Postgres's own limit on a NOTIFY payload.
    public static let maxPayloadBytes = 7999

    let dataSource: PostgresDataSource
    let channel: String
    let retryDelay: Duration
    let logger: Logger
    private let stream: AsyncStream<Message>
    private let continuation: AsyncStream<Message>.Continuation

    public init(
        dataSource: PostgresDataSource, channel: String = "alula_pubsub",
        retryDelay: Duration = .seconds(1),
        logger: Logger = Logger(label: "alula.pubsub.postgres")
    ) {
        self.dataSource = dataSource
        self.channel = channel
        self.retryDelay = retryDelay
        self.logger = logger
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(10_000))
    }

    struct Wire: Codable {
        let t: String
        let p: String
        let m: [String: String]?
    }

    public func broadcast(_ message: Message) async throws {
        let wire = Wire(
            t: message.topic, p: message.payload.base64EncodedString(),
            m: message.metadata.isEmpty ? nil : message.metadata)
        let payload = String(decoding: try JSONEncoder().encode(wire), as: UTF8.self)
        guard payload.utf8.count <= Self.maxPayloadBytes else {
            throw PostgresPubSubError.payloadTooLarge(
                topic: message.topic, bytes: payload.utf8.count)
        }
        let channel = self.channel
        try await dataSource.withConnection { connection in
            _ = try await connection.query(
                "SELECT pg_notify(\(channel), \(payload))", logger: logger)
        }
    }

    public func incoming() -> AsyncStream<Message> { stream }

    /// Listens until cancelled, reconnecting after `retryDelay` whenever the
    /// dedicated connection is lost.
    func listen() async {
        var announcedLoss = false
        while !Task.isCancelled {
            do {
                let connection = try await dataSource.dedicatedConnection()
                do {
                    if announcedLoss {
                        logger.info("pubsub listener reconnected", metadata: ["channel": "\(channel)"])
                        announcedLoss = false
                    }
                    try await connection.listen(on: channel) { notifications in
                    var drops = PubSubDropReporter(adapter: "postgres", logger: logger)
                    for try await notification in notifications {
                        guard
                            let wire = try? JSONDecoder().decode(
                                Wire.self, from: Data(notification.payload.utf8)),
                            let payload = Data(base64Encoded: wire.p)
                        else {
                            logger.warning(
                                "ignoring a notification that is not a PubSub message",
                                metadata: ["channel": "\(channel)"])
                            continue
                        }
                        drops.record(continuation.yield(Message(topic: wire.t, payload: payload, metadata: wire.m ?? [:])))
                    }
                    }
                } catch {
                    try? await connection.close()
                    throw error
                }
                try? await connection.close()
            } catch {
                if Task.isCancelled { break }
                if !announcedLoss {
                    logger.warning(
                        "pubsub listener lost its connection; messages from other nodes are missed until it reconnects",
                        metadata: ["channel": "\(channel)", "error": "\(error)"])
                    announcedLoss = true
                }
            }
            try? await Task.sleep(for: retryDelay)
        }
        continuation.finish()
    }
}

public enum PostgresPubSubError: Error, Sendable, Equatable, CustomStringConvertible {
    case payloadTooLarge(topic: String, bytes: Int)

    public var description: String {
        switch self {
        case .payloadTooLarge(let topic, let bytes):
            """
            a PubSub message on \(topic) encodes to \(bytes) bytes, over Postgres's NOTIFY limit \
            of \(PostgresPubSubAdapter.maxPayloadBytes). It was delivered on this node only.
            """
        }
    }
}

/// Provides a ``PostgresPubSubAdapter`` over the Postgres pool, which
/// `AlulaPubSubModule` takes to become clustered.
///
/// ```yaml
/// pubsub:
///   postgres:
///     channel: alula_pubsub    # default
///     retry-delay-ms: 1000     # default
/// ```
public struct AlulaPubSubPostgresModule: AlulaModule {
    public let adapter: any DistributedPubSubAdapter
    private let postgres: PostgresPubSubAdapter

    public init(configuration: Configuration, dataSource: PostgresDataSource) throws {
        let channel =
            try configuration.getIfPresent("pubsub.postgres.channel", as: String.self) ?? "alula_pubsub"
        guard !channel.isEmpty, channel.utf8.count <= 63,
            channel.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
        else {
            throw PostgresPubSubConfigurationError(
                "pubsub.postgres.channel must be 1–63 letters, digits or underscores; it is \(channel)")
        }
        let retry = try configuration.getIfPresent("pubsub.postgres.retry-delay-ms", as: Int.self) ?? 1000
        let adapter = PostgresPubSubAdapter(
            dataSource: dataSource, channel: channel, retryDelay: .milliseconds(max(retry, 10)))
        self.postgres = adapter
        self.adapter = adapter
    }

    public init() {
        preconditionFailure(
            "AlulaPubSubPostgresModule takes its configuration and pool in "
                + "init(configuration:dataSource:), so it cannot be instantiated from its type. "
                + "Pass `composedBy: alulaComposeModules` to Alula.run.")
    }

    public var service: (any Service)? { PostgresPubSubListener(adapter: postgres) }
    public var serviceShutdownPhase: ServiceShutdownPhase { .infrastructure }
}

struct PostgresPubSubListener: Service {
    let adapter: PostgresPubSubAdapter

    func run() async throws {
        await cancelWhenGracefulShutdown {
            await adapter.listen()
        }
    }
}

public struct PostgresPubSubConfigurationError: Error, Sendable, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

/// Counts and reports messages the bounded relay buffer dropped.
///
/// Dropping is the contract — PubSub is at-most-once, and a consumer that
/// falls behind should lose stale updates rather than exhaust memory — but a
/// loss nobody can see is an operational blind spot. Every drop increments
/// `alula.pubsub.dropped` (dimensioned by adapter), and a warning with the
/// running count is logged at most every ten seconds.
struct PubSubDropReporter {
    let adapter: String
    let logger: Logger
    /// The metrics backend; nil means the bootstrapped one, read per drop so
    /// a backend bootstrapped after the adapter started is still reached.
    let metrics: (any MetricsFactory)?
    private var unreported = 0
    private var lastWarning: ContinuousClock.Instant?

    init(adapter: String, logger: Logger, metrics: (any MetricsFactory)? = nil) {
        self.adapter = adapter
        self.logger = logger
        self.metrics = metrics
    }

    mutating func record(_ result: AsyncStream<Message>.Continuation.YieldResult) {
        guard case .dropped = result else { return }
        let dimensions = [("adapter", adapter)]
        if let metrics {
            Counter(label: "alula.pubsub.dropped", dimensions: dimensions, factory: metrics).increment()
        } else {
            Counter(label: "alula.pubsub.dropped", dimensions: dimensions).increment()
        }
        unreported += 1
        let now = ContinuousClock.now
        if let lastWarning, now - lastWarning < .seconds(10) { return }
        logger.warning(
            "pubsub relay buffer full; dropped the oldest messages",
            metadata: ["adapter": .string(adapter), "dropped": .stringConvertible(unreported)])
        unreported = 0
        lastWarning = now
    }
}
